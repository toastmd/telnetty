import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, TelnetConnectionDelegate {
    private let defaults = UserDefaults.standard
    private var window: NSWindow!
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let bookmarksButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let inputField = NSTextField()
    private let secureField = NSSecureTextField()
    private var textView: NSTextView!
    private var scrollView: NSScrollView!

    private let connection = TelnetConnection()
    private var renderer: AnsiRenderer!
    private var bookmarks: [Bookmark] = []
    private var history: [String] = []
    private var historyIndex = 0
    private var connected = false
    private var fontSize: CGFloat = 13
    private var pendingURL: URL?

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = CGFloat(defaults.double(forKey: "fontSize"))
        fontSize = saved >= 9 ? saved : 13
        renderer = AnsiRenderer(font: makeFont(fontSize))
        bookmarks = BookmarkStore.load()
        connection.delegate = self
        buildMenu()
        buildWindow()
        rebuildBookmarks()
        hostField.stringValue = defaults.string(forKey: "lastHost") ?? ""
        let lastPort = defaults.integer(forKey: "lastPort")
        portField.stringValue = lastPort > 0 ? String(lastPort) : "23"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        appendSystem("Telnetty " + version + ": type a host and port above, or pick a bookmark, then press Connect.")
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL {
            pendingURL = nil
            connectTo(url: url)
        } else {
            window.makeFirstResponder(hostField)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }

    func applicationWillTerminate(_ notification: Notification) { connection.disconnect() }

    /// Lets Telnetty open telnet://host:port links.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingURL = url } else { connectTo(url: url) }
    }

    private func connectTo(url: URL) {
        guard let host = url.host, !host.isEmpty else { return }
        hostField.stringValue = host
        portField.stringValue = String(url.port ?? 23)
        startConnection()
    }

    private func makeFont(_ size: CGFloat) -> NSFont {
        return NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Telnetty"
        window.minSize = NSSize(width: 560, height: 360)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TelnettyMainWindow")
        guard let content = window.contentView else { return }

        hostField.placeholderString = "host name or IP address"
        hostField.target = self
        hostField.action = #selector(toggleConnection)
        portField.placeholderString = "23"
        portField.target = self
        portField.action = #selector(toggleConnection)
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = ""
        bookmarksButton.pullsDown = true

        let topBar = NSStackView(views: [bookmarksButton, hostField, portField, connectButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        hostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.backgroundColor = renderer.defaultBG
        textView.insertionPointColor = renderer.defaultFG
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.font = renderer.font
        textView.textColor = renderer.defaultFG
        scrollView.backgroundColor = renderer.defaultBG
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        for f in [inputField, secureField] as [NSTextField] {
            f.placeholderString = "type here and press Return"
            f.font = renderer.font
            f.delegate = self
            f.target = self
            f.action = #selector(sendLine)
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        secureField.placeholderString = "the server is asking for a hidden entry (password)"
        secureField.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topBar)
        content.addSubview(scrollView)
        content.addSubview(inputField)
        content.addSubview(secureField)
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
            inputField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            inputField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            inputField.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            secureField.leadingAnchor.constraint(equalTo: inputField.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: inputField.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: inputField.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: inputField.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResize(_ notification: Notification) { reportWindowSize() }

    private func reportWindowSize() {
        guard let tv = textView, let sv = scrollView else { return }
        let cw = ("M" as NSString).size(withAttributes: [.font: renderer.font]).width
        let lh = tv.layoutManager?.defaultLineHeight(for: renderer.font) ?? (fontSize * 1.3)
        let usableW = sv.contentSize.width - tv.textContainerInset.width * 2
        let usableH = sv.contentSize.height - tv.textContainerInset.height * 2
        if cw > 0 && lh > 0 { connection.updateWindowSize(cols: Int(usableW / cw), rows: Int(usableH / lh)) }
    }

    // MARK: menu

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    /// An item whose action goes to a given object (target) or, with nil, along the responder chain (copy, paste, minimize...).
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject?) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
    }

    private func buildMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        addItem(appMenu, "About Telnetty", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp)
        appMenu.addItem(.separator())
        addItem(appMenu, "Hide Telnetty", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        appMenu.addItem(.separator())
        addItem(appMenu, "Quit Telnetty", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let fileItem = NSMenuItem()
        bar.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        addItem(file, "Connect or Disconnect", #selector(toggleConnection), "k")
        addItem(file, "Save Bookmark…", #selector(saveBookmark), "d")
        file.addItem(.separator())
        addItem(file, "Save Transcript…", #selector(saveTranscript), "s")
        addItem(file, "Clear Screen", #selector(clearScreen), "l")

        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        addItem(edit, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
        addItem(edit, "Paste", #selector(NSText.paste(_:)), "v", target: nil)
        addItem(edit, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)

        let viewItem = NSMenuItem()
        bar.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        addItem(view, "Bigger Text", #selector(biggerText), "=")
        addItem(view, "Smaller Text", #selector(smallerText), "-")
        addItem(view, "Default Text Size", #selector(defaultText), "0")

        let winItem = NSMenuItem()
        bar.addItem(winItem)
        let win = NSMenu(title: "Window")
        winItem.submenu = win
        addItem(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        addItem(win, "Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil)
        NSApp.windowsMenu = win

        NSApp.mainMenu = bar
    }

    // MARK: bookmarks

    private func rebuildBookmarks() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bookmarks", action: nil, keyEquivalent: "") // the pull-down's own title
        for (i, b) in bookmarks.enumerated() {
            let item = NSMenuItem(title: "\(b.name)   \(b.host):\(b.port)", action: #selector(pickBookmark(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save Current as Bookmark…", action: #selector(saveBookmark), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !bookmarks.isEmpty {
            let del = NSMenuItem(title: "Delete Bookmark", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, b) in bookmarks.enumerated() {
                let item = NSMenuItem(title: b.name, action: #selector(deleteBookmark(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                sub.addItem(item)
            }
            del.submenu = sub
            menu.addItem(del)
        }
        bookmarksButton.menu = menu
    }

    @objc private func pickBookmark(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < bookmarks.count else { return }
        let b = bookmarks[sender.tag]
        hostField.stringValue = b.host
        portField.stringValue = String(b.port)
        startConnection()
    }

    @objc private func deleteBookmark(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < bookmarks.count else { return }
        bookmarks.remove(at: sender.tag)
        BookmarkStore.save(bookmarks)
        rebuildBookmarks()
    }

    @objc private func saveBookmark() {
        let (host, port) = currentTarget()
        guard !host.isEmpty else {
            appendSystem("Enter a host first, then save it as a bookmark.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save bookmark"
        alert.informativeText = "Name for \(host):\(port)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = host
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            bookmarks.append(Bookmark(name: name.isEmpty ? host : name, host: host, port: port))
            BookmarkStore.save(bookmarks)
            rebuildBookmarks()
        }
    }

    // MARK: connecting

    /// Host and port from the two fields. "host:port" or "host port" typed into the host box also works.
    private func currentTarget() -> (String, Int) {
        var host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 23
        let parts = host.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
        if parts.count == 2, let p = Int(parts[1]) {
            host = parts[0]
            port = p
            hostField.stringValue = host
            portField.stringValue = String(p)
        }
        if port < 1 || port > 65535 { port = 23 }
        return (host, port)
    }

    @objc private func toggleConnection() {
        if connected || connection.isOpen {
            connection.disconnect()
            telnetDidDisconnect(connection, reason: nil)
        } else {
            startConnection()
        }
    }

    private func startConnection() {
        let (host, port) = currentTarget()
        guard !host.isEmpty else {
            appendSystem("Enter a host name or IP address first.")
            window.makeFirstResponder(hostField)
            return
        }
        defaults.set(host, forKey: "lastHost")
        defaults.set(port, forKey: "lastPort")
        renderer.reset()
        statusLabel.stringValue = "Connecting to \(host):\(port)…"
        connectButton.title = "Cancel"
        appendSystem("Connecting to \(host) port \(port)…")
        connection.connect(host: host, port: UInt16(port))
    }

    // MARK: TelnetConnectionDelegate

    func telnetDidConnect(_ c: TelnetConnection) {
        connected = true
        connectButton.title = "Disconnect"
        statusLabel.stringValue = "Connected to \(c.host):\(c.port)"
        window.title = "Telnetty: \(c.host):\(c.port)"
        appendSystem("Connected. Escape character is not needed: just type.")
        showInput(secure: false)
        reportWindowSize()
    }

    func telnetDidDisconnect(_ c: TelnetConnection, reason: String?) {
        let wasConnected = connected
        connected = false
        connectButton.title = "Connect"
        statusLabel.stringValue = "Not connected"
        window.title = "Telnetty"
        showInput(secure: false)
        var message = "Cancelled."
        if wasConnected {
            message = "Disconnected."
            if let r = reason { message += " (" + r + ")" }
        } else if let r = reason {
            message = "Could not connect: " + r
        }
        appendSystem(message)
    }

    func telnet(_ c: TelnetConnection, didReceiveText text: String) {
        append(renderer.render(text))
    }

    func telnet(_ c: TelnetConnection, serverEchoChanged on: Bool) {
        showInput(secure: on) // the server echoing usually means a password prompt
    }

    private func showInput(secure: Bool) {
        inputField.isHidden = secure
        secureField.isHidden = !secure
        secureField.stringValue = ""
        window.makeFirstResponder(secure ? secureField : inputField)
    }

    // MARK: input

    @objc private func sendLine(_ sender: Any?) {
        let secure = !secureField.isHidden
        let field: NSTextField = secure ? secureField : inputField
        let text = field.stringValue
        field.stringValue = ""
        guard connected else {
            if hostField.stringValue.isEmpty { return }
            startConnection()
            return
        }
        connection.send(line: text)
        if !secure {
            if !text.isEmpty && history.last != text { history.append(text) }
            if history.count > 500 { history.removeFirst(history.count - 500) }
            historyIndex = history.count
            append(NSAttributedString(string: "› " + text + "\n", attributes: [.font: renderer.font, .foregroundColor: AnsiRenderer.hex(0x6E7681)])) // local echo, dimmed
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === inputField {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                stepHistory(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                stepHistory(1)
                return true
            }
        }
        return false
    }

    private func stepHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        historyIndex = max(0, min(history.count, historyIndex + delta))
        inputField.stringValue = historyIndex < history.count ? history[historyIndex] : ""
        if let editor = inputField.currentEditor() { editor.selectedRange = NSRange(location: (inputField.stringValue as NSString).length, length: 0) }
    }

    // MARK: output

    private func isAtBottom() -> Bool {
        guard let sv = scrollView, let tv = textView else { return true }
        return sv.contentView.bounds.maxY >= tv.frame.height - 40
    }

    private func append(_ text: NSAttributedString) {
        guard let storage = textView.textStorage else { return }
        let stick = isAtBottom()
        storage.append(text)
        if storage.length > 500_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 350_000)) }
        if stick { textView.scrollToEndOfDocument(nil) }
    }

    private func appendSystem(_ message: String) {
        guard textView != nil else { return }
        let text = NSAttributedString(string: "[\(message)]\n", attributes: [.font: renderer.font, .foregroundColor: AnsiRenderer.hex(0x58A6FF)])
        append(text)
    }

    @objc private func clearScreen() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    @objc private func saveTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Telnetty-transcript.txt"
        let text = textView.string
        panel.begin { response in
            if response == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: text size

    @objc private func biggerText() { setFontSize(fontSize + 1) }
    @objc private func smallerText() { setFontSize(fontSize - 1) }
    @objc private func defaultText() { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = max(9, min(32, size))
        defaults.set(Double(fontSize), forKey: "fontSize")
        renderer.font = makeFont(fontSize)
        textView.font = renderer.font
        inputField.font = renderer.font
        secureField.font = renderer.font
        if let storage = textView.textStorage, storage.length > 0 {
            let newSize = fontSize
            var runs: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                if let f = value as? NSFont { runs.append((range, f)) }
            }
            storage.beginEditing()
            for (range, f) in runs { storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: newSize), range: range) }
            storage.endEditing()
        }
        reportWindowSize()
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
