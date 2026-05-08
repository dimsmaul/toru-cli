# Toru CLI

A native macOS terminal emulator built in Swift. Lightweight, comment-aware, with fish-style autocomplete — 100% local, no AI, no cloud, no account.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-orange.svg)](#requirements)

![Toru CLI](docs/images/screenshot.png)

## Features

- **Native macOS UI** — SwiftUI + AppKit. NavigationSplitView, native tabs (`NSWindowTabbing`), system accent color, automatic dark/light.
- **Comment skipping** — lines beginning with `#` are visible but not executed. Multi-line blocks are filtered before they reach the shell.
- **Fish-style inline autocomplete** — ghost text driven by your local SQLite history. Press `→` or `Tab` to accept.
- **History fuzzy search** — `Ctrl+R` opens an inline floating search panel.
- **Tab completion** — `$PATH` commands and files in the working directory.
- **Themes** — five built-ins (Dark, Light, Solarized Dark, Tokyo Night, One Dark). Drop a JSON file into Settings → Appearance to import a custom theme.
- **No telemetry, no network calls.** Everything runs locally.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 16+ to build from source
- Swift 5.10+

## Install

Download the latest signed and notarized DMG from the [Releases page](https://github.com/dimsmauls/toru-cli/releases) and drag `Toru CLI.app` to your `Applications` folder.

## Build from source

```bash
git clone https://github.com/dimsmauls/toru-cli.git
cd "toru-cli/Toru CLI"
open "Toru CLI.xcodeproj"
```

Press `⌘R` in Xcode. Or use the command line:

```bash
make build      # debug build
make test       # unit tests (CommentFilter, AutocompleteEngine, HistoryDatabase)
make dmg        # release build + DMG packaging
make notarize   # notarize via xcrun notarytool (requires AC_USERNAME / AC_PASSWORD / AC_TEAM_ID env vars)
```

## Keybindings

| Shortcut       | Action                       |
|----------------|------------------------------|
| `→` / `Tab`    | Accept ghost-text suggestion |
| `Escape`       | Dismiss ghost text / popup   |
| `Ctrl+R`       | History fuzzy search         |
| `Tab`          | Tab completion (when no ghost) |
| `⌘T`           | New tab                      |
| `⌘W`           | Close tab                    |
| `⌘D`           | Split pane horizontal        |
| `⌘⇧D`          | Split pane vertical          |
| `⌘,`           | Settings                     |
| `⌘+` / `⌘-`    | Increase / decrease font size |
| `⌘K`           | Clear terminal buffer        |
| `⌘⇧C` / `⌘⇧V`  | Copy / paste                 |

## Comment syntax

Lines whose first non-whitespace character is `#` are stripped before being sent to the shell.

```
# build for production
bun run build
# upload to cloud
gcloud run deploy
```

Only `bun run build` and `gcloud run deploy` are executed. The comment lines remain visible in the terminal scrollback as italic gray annotations. Inline trailing comments (`bun build # fast`) are not stripped.

## Architecture

```
SwiftUI Layer
  WindowGroup → NavigationSplitView → Toolbar
        │
AppKit Bridge (NSViewRepresentable)
        │
TorTerminalView : LocalProcessTerminalView (SwiftTerm)
        │
Input Pipeline
  CommentFilter → AutocompleteEngine → PTY
        │
Persistence
  HistoryDatabase (GRDB / SQLite)
  ThemeManager
  SettingsStore (UserDefaults)
```

Full design spec: [`docs/superpowers/specs/2026-05-08-toru-cli-design.md`](docs/superpowers/specs/2026-05-08-toru-cli-design.md). Original PRD: [`PRD-MacTerminal.md`](PRD-MacTerminal.md).

## Themes

Built-in: **Dark**, **Light**, **Solarized Dark**, **Tokyo Night**, **One Dark**. Each theme is a JSON file at `Toru CLI/Themes/builtin/`:

```json
{
  "name": "Tokyo Night",
  "background": "#1a1b26",
  "foreground": "#a9b1d6",
  "cursor": "#c0caf5",
  "ansi": ["#15161e", "...", "#c0caf5"]
}
```

Custom themes: drop a JSON file into Settings → Appearance to import.

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Dimas Maulana

## Acknowledgments

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza — VT100 / xterm emulation.
- [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué — SQLite ORM.
