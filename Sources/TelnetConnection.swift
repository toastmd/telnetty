import Foundation
import Network

// Telnet command and option bytes (RFC 854 and friends)
private let IAC: UInt8 = 255
private let DONT: UInt8 = 254
private let DO: UInt8 = 253
private let WONT: UInt8 = 252
private let WILL: UInt8 = 251
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let OPT_ECHO: UInt8 = 1
private let OPT_SGA: UInt8 = 3
private let OPT_TTYPE: UInt8 = 24
private let OPT_NAWS: UInt8 = 31

protocol TelnetConnectionDelegate: AnyObject {
    func telnetDidConnect(_ c: TelnetConnection)
    func telnetDidDisconnect(_ c: TelnetConnection, reason: String?)
    func telnet(_ c: TelnetConnection, didReceiveText text: String)
    func telnet(_ c: TelnetConnection, serverEchoChanged on: Bool)
}

/// A telnet connection: raw TCP plus the telnet protocol (option negotiation, terminal type, window size).
final class TelnetConnection {
    weak var delegate: TelnetConnectionDelegate?
    private(set) var host = ""
    private(set) var port: UInt16 = 23
    var terminalType = "xterm-256color"

    private var conn: NWConnection?
    private enum ParseState { case data, iac, option, sb, sbIac }
    private var state: ParseState = .data
    private var pendingCommand: UInt8 = 0
    private var sbBuffer: [UInt8] = []
    private var textBuffer: [UInt8] = []
    private var utf8Tail: [UInt8] = []
    private var willSent = Set<UInt8>()
    private var doSent = Set<UInt8>()
    private var remoteEcho = false
    private var cols = 80
    private var rows = 24

    var isOpen: Bool { return conn != nil }

    func connect(host: String, port: UInt16) {
        disconnect()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        self.host = host
        self.port = port
        resetParser()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] newState in
            guard let self = self, let c = c, self.conn === c else { return }
            switch newState {
            case .ready:
                self.delegate?.telnetDidConnect(self)
                self.receiveLoop(c)
            case .failed(let error):
                self.finish(c, reason: error.localizedDescription)
            case .waiting(let error):
                // unreachable host, refused connection, DNS failure: report it instead of waiting forever
                self.finish(c, reason: error.localizedDescription)
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    /// Close the connection (no delegate callback: the caller already knows).
    func disconnect() {
        if let c = conn {
            conn = nil
            c.cancel()
        }
        if remoteEcho { remoteEcho = false }
    }

    private func finish(_ c: NWConnection, reason: String?) {
        guard conn === c else { return }
        conn = nil
        c.cancel()
        flushText()
        delegate?.telnetDidDisconnect(self, reason: reason)
    }

    private func resetParser() {
        state = .data
        pendingCommand = 0
        sbBuffer.removeAll()
        textBuffer.removeAll()
        utf8Tail.removeAll()
        willSent.removeAll()
        doSent.removeAll()
        remoteEcho = false
    }

    // MARK: sending

    /// Send one line of text (a trailing CR LF is added, and 0xFF bytes are escaped).
    func send(line: String) {
        var out: [UInt8] = []
        for b in Array(line.utf8) {
            out.append(b)
            if b == IAC { out.append(IAC) }
        }
        out.append(13)
        out.append(10)
        sendRaw(out)
    }

    private func sendRaw(_ bytes: [UInt8]) {
        guard let c = conn else { return }
        c.send(content: Data(bytes), completion: .contentProcessed({ _ in }))
    }

    func updateWindowSize(cols: Int, rows: Int) {
        let c = max(20, min(cols, 500))
        let r = max(5, min(rows, 500))
        if c == self.cols && r == self.rows { return }
        self.cols = c
        self.rows = r
        if willSent.contains(OPT_NAWS) { sendNAWS() }
    }

    private func sendNAWS() {
        var out: [UInt8] = [IAC, SB, OPT_NAWS]
        for v in [cols >> 8, cols & 255, rows >> 8, rows & 255] {
            let b = UInt8(v)
            out.append(b)
            if b == IAC { out.append(IAC) }
        }
        out.append(IAC)
        out.append(SE)
        sendRaw(out)
    }

    // MARK: receiving

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, self.conn === c else { return }
            if let d = data, !d.isEmpty { self.process([UInt8](d)) }
            if let e = error {
                self.finish(c, reason: e.localizedDescription)
                return
            }
            if isComplete {
                self.finish(c, reason: "The remote host closed the connection.")
                return
            }
            self.receiveLoop(c)
        }
    }

    private func process(_ bytes: [UInt8]) {
        for b in bytes {
            switch state {
            case .data:
                if b == IAC { state = .iac } else { textBuffer.append(b) }
            case .iac:
                if b == IAC {
                    textBuffer.append(IAC)
                    state = .data
                } else if b == DO || b == DONT || b == WILL || b == WONT {
                    pendingCommand = b
                    state = .option
                } else if b == SB {
                    sbBuffer.removeAll()
                    state = .sb
                } else {
                    state = .data // NOP, GA and other single-byte commands: ignored
                }
            case .option:
                handleOption(command: pendingCommand, option: b)
                state = .data
            case .sb:
                if b == IAC { state = .sbIac } else { sbBuffer.append(b) }
            case .sbIac:
                if b == SE {
                    handleSubnegotiation(sbBuffer)
                    state = .data
                } else if b == IAC {
                    sbBuffer.append(IAC)
                    state = .sb
                } else {
                    state = .sb
                }
            }
        }
        flushText()
    }

    private func handleOption(command: UInt8, option: UInt8) {
        if command == DO {
            if option == OPT_TTYPE || option == OPT_NAWS || option == OPT_SGA {
                if !willSent.contains(option) {
                    willSent.insert(option)
                    sendRaw([IAC, WILL, option])
                    if option == OPT_NAWS { sendNAWS() }
                }
            } else {
                sendRaw([IAC, WONT, option]) // refuse anything we do not support
            }
        } else if command == DONT {
            if willSent.contains(option) {
                willSent.remove(option)
                sendRaw([IAC, WONT, option])
            }
        } else if command == WILL {
            if option == OPT_ECHO {
                if !doSent.contains(option) {
                    doSent.insert(option)
                    sendRaw([IAC, DO, option])
                }
                if !remoteEcho {
                    remoteEcho = true
                    delegate?.telnet(self, serverEchoChanged: true)
                }
            } else if option == OPT_SGA {
                if !doSent.contains(option) {
                    doSent.insert(option)
                    sendRaw([IAC, DO, option])
                }
            } else {
                sendRaw([IAC, DONT, option]) // for example MCCP and GMCP: not supported
            }
        } else if command == WONT {
            if option == OPT_ECHO && remoteEcho {
                remoteEcho = false
                doSent.remove(option)
                sendRaw([IAC, DONT, option])
                delegate?.telnet(self, serverEchoChanged: false)
            } else if doSent.contains(option) {
                doSent.remove(option)
                sendRaw([IAC, DONT, option])
            }
        }
    }

    private func handleSubnegotiation(_ data: [UInt8]) {
        // server asks for our terminal type: IAC SB TTYPE SEND IAC SE
        if data.count >= 2 && data[0] == OPT_TTYPE && data[1] == 1 {
            var out: [UInt8] = [IAC, SB, OPT_TTYPE, 0]
            out.append(contentsOf: Array(terminalType.utf8))
            out.append(IAC)
            out.append(SE)
            sendRaw(out)
        }
    }

    /// Decode buffered bytes as UTF-8 (falling back to Latin-1), holding back an incomplete trailing character.
    private func flushText() {
        guard !textBuffer.isEmpty else { return }
        var bytes = utf8Tail + textBuffer
        textBuffer.removeAll()
        utf8Tail.removeAll()
        var hold = 0
        var i = bytes.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { // continuation byte: keep looking for the lead byte
                i -= 1
                back += 1
                continue
            }
            if b >= 0xC0 {
                let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
                if bytes.count - i < need { hold = bytes.count - i }
            }
            break
        }
        if hold > 0 {
            utf8Tail = Array(bytes[(bytes.count - hold)...])
            bytes.removeLast(hold)
        }
        guard !bytes.isEmpty else { return }
        var text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        // telnet sends CR LF; drop CR and NUL so only LF line ends reach the screen
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0.value != 0 }))
        if !text.isEmpty { delegate?.telnet(self, didReceiveText: text) }
    }
}
