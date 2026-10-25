# Telnetty

A small, fast telnet client for macOS (11 Big Sur or newer, Apple silicon and Intel), with a real installer.

## Build and install (2 minutes)

You need a Mac with Apple's command line tools (a one-time `xcode-select --install`). You do **not** need the full Xcode app.

```bash
cd Telnetty
./build.sh
```

That produces, in `build/`:

| File | What it is |
|---|---|
| `Telnetty-1.0.0.pkg` | **The installer.** Double-click it, click Continue, and Telnetty lands in /Applications. |
| `Telnetty-1.0.0.dmg` | Disk image: drag Telnetty onto Applications. |
| `Telnetty.app` | The app itself, a universal binary. |

Because you built it on your own Mac, macOS will open it without any warning. To remove it later, run `./uninstall.sh`.

### Sharing it with other people

Apps downloaded from the internet are checked by Gatekeeper. An unsigned build opens with a right-click, Open (or System Settings, Privacy & Security, Open Anyway). For a no-warning download you need an Apple Developer ID ($99 a year):

```bash
DEV_ID_APP="Developer ID Application: Your Name (TEAMID)" \
DEV_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" ./build.sh
xcrun notarytool submit build/Telnetty-1.0.0.pkg --keychain-profile "notary" --wait
xcrun stapler staple build/Telnetty-1.0.0.pkg
```

## Using Telnetty

Type a host and port at the top and press Return (or Connect). `host:port` or `host port` typed in the host box works too.

| Feature | How |
|---|---|
| Bookmarks | The Bookmarks menu at the top left. Save Current as Bookmark, pick one to connect, or delete one. (Two public examples come built in; they may be offline.) |
| Command history | Up and Down arrows in the input line |
| Passwords | When the server turns off echo, the input line becomes a hidden entry |
| Colors | ANSI 16, 256 and true color, bold, underline, inverse |
| Text size | View menu: Cmd + (bigger), Cmd - (smaller), Cmd 0 (default). Remembered. |
| Transcript | File, Save Transcript (Cmd S) |
| Clear screen | Cmd L |
| Connect or disconnect | Cmd K |
| telnet:// links | Telnetty registers itself for `telnet://` links; macOS may ask which app to use the first time |

Under the hood: raw TCP through Apple's Network framework, the telnet protocol (echo, suppress go-ahead, terminal type `xterm-256color`, window size updates on resize), UTF-8 with a Latin-1 fallback.

**Telnet is not encrypted.** Everything you type, passwords included, crosses the network as plain text. Use it with services you trust.

## Project layout

```
Sources/TelnetConnection.swift   connection and telnet protocol
Sources/AnsiRenderer.swift       ANSI colors to attributed text
Sources/Bookmarks.swift          saved connections
Sources/main.swift               window, menus and input
Resources/                       Info.plist, icon, installer text
build.sh                         builds the .app, .pkg and .dmg
```

MIT licensed.
