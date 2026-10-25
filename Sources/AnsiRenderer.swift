import Cocoa

/// Turns text with ANSI escape codes (colors, bold, underline, 256 and true color) into attributed text.
/// Keeps its state between calls, so a color set in one packet carries into the next.
final class AnsiRenderer {
    var font: NSFont { didSet { boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) } }
    private var boldFont: NSFont
    let defaultFG = AnsiRenderer.hex(0xC9D1D9)
    let defaultBG = AnsiRenderer.hex(0x0D1117)

    private var fgColor: NSColor?
    private var fgIndex: Int?
    private var bgColor: NSColor?
    private var bold = false
    private var underline = false
    private var inverse = false
    private var pending = ""

    init(font: NSFont) {
        self.font = font
        self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    // MARK: colors

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func hex(_ v: Int) -> NSColor { return rgb((v >> 16) & 255, (v >> 8) & 255, v & 255) }

    static let palette: [NSColor] = [
        0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ].map { AnsiRenderer.hex($0) }

    static func xterm(_ n: Int) -> NSColor {
        let n = max(0, min(255, n))
        if n < 16 { return palette[n] }
        if n < 232 {
            let i = n - 16
            let levels = [0, 95, 135, 175, 215, 255]
            return rgb(levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
        }
        let v = 8 + (n - 232) * 10
        return rgb(v, v, v)
    }

    // MARK: rendering

    func reset() {
        fgColor = nil
        fgIndex = nil
        bgColor = nil
        bold = false
        underline = false
        inverse = false
    }

    func render(_ input: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var run = ""
        let scalars = Array((pending + input).unicodeScalars)
        pending = ""
        var i = 0

        func flush() {
            if !run.isEmpty {
                out.append(NSAttributedString(string: run, attributes: currentAttributes()))
                run = ""
            }
        }

        while i < scalars.count {
            let s = scalars[i]
            if s == "\u{1B}" {
                if i + 1 >= scalars.count {
                    pending = "\u{1B}"
                    break
                }
                let next = scalars[i + 1]
                if next == "[" { // CSI: ESC [ params final-byte
                    var j = i + 2
                    while j < scalars.count && !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) { j += 1 }
                    if j >= scalars.count {
                        if scalars.count - i < 64 { pending = String(String.UnicodeScalarView(scalars[i...])) }
                        break
                    }
                    if scalars[j] == "m" {
                        flush()
                        applySGR(String(String.UnicodeScalarView(scalars[(i + 2)..<j])))
                    }
                    i = j + 1
                    continue
                } else if next == "]" { // OSC (window title and so on): skip to BEL or ESC
                    var j = i + 2
                    while j < scalars.count && scalars[j] != "\u{07}" && scalars[j] != "\u{1B}" { j += 1 }
                    if j >= scalars.count {
                        if scalars.count - i < 256 { pending = String(String.UnicodeScalarView(scalars[i...])) }
                        break
                    }
                    i = scalars[j] == "\u{07}" ? j + 1 : j + 2
                    continue
                } else {
                    i += 2
                    continue
                }
            } else if s == "\u{07}" {
                NSSound.beep()
                i += 1
                continue
            } else if s == "\u{08}" {
                if !run.isEmpty { run.removeLast() }
                i += 1
                continue
            } else if s.value < 0x20 && s != "\n" && s != "\t" {
                i += 1
                continue
            }
            run.unicodeScalars.append(s)
            i += 1
        }
        flush()
        return out
    }

    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        var f: NSColor = fgColor ?? defaultFG
        if bold {
            if let idx = fgIndex { f = AnsiRenderer.palette[idx + 8] } else if fgColor == nil { f = AnsiRenderer.hex(0xFFFFFF) }
        }
        var b: NSColor? = bgColor
        if inverse {
            let nf = b ?? defaultBG
            b = f
            f = nf
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: bold ? boldFont : font, .foregroundColor: f]
        if let b = b { attrs[.backgroundColor] = b }
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    private func applySGR(_ params: String) {
        var nums: [Int] = params.split(maxSplits: Int.max, omittingEmptySubsequences: false, whereSeparator: { $0 == ";" || $0 == ":" }).map { Int($0) ?? 0 }
        if nums.isEmpty { nums = [0] }
        var i = 0
        while i < nums.count {
            let n = nums[i]
            switch n {
            case 0: reset()
            case 1: bold = true
            case 4: underline = true
            case 7: inverse = true
            case 22: bold = false
            case 24: underline = false
            case 27: inverse = false
            case 30...37:
                fgIndex = n - 30
                fgColor = AnsiRenderer.palette[n - 30]
            case 90...97:
                fgIndex = nil
                fgColor = AnsiRenderer.palette[n - 90 + 8]
            case 39:
                fgIndex = nil
                fgColor = nil
            case 40...47: bgColor = AnsiRenderer.palette[n - 40]
            case 100...107: bgColor = AnsiRenderer.palette[n - 100 + 8]
            case 49: bgColor = nil
            case 38, 48:
                if i + 1 < nums.count {
                    var color: NSColor? = nil
                    if nums[i + 1] == 5 && i + 2 < nums.count {
                        color = AnsiRenderer.xterm(nums[i + 2])
                        i += 2
                    } else if nums[i + 1] == 2 && i + 4 < nums.count {
                        color = AnsiRenderer.rgb(max(0, min(255, nums[i + 2])), max(0, min(255, nums[i + 3])), max(0, min(255, nums[i + 4])))
                        i += 4
                    }
                    if let c = color {
                        if n == 38 {
                            fgColor = c
                            fgIndex = nil
                        } else {
                            bgColor = c
                        }
                    }
                }
            default:
                break
            }
            i += 1
        }
    }
}
