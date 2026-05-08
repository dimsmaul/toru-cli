import SwiftUI
import AppKit

/// Bridge object so SwiftUI siblings (input bar, hotkeys) can drive the
/// SwiftTerm `TorTerminalView` without owning it directly.
@MainActor
final class ShellBridge: ObservableObject {
    weak var view: TorTerminalView?

    /// Send a user-typed command. Always appends `\n`.
    func send(command: String) {
        guard !command.isEmpty else { return }
        view?.send(txt: command + "\n")
    }

    /// Send raw bytes verbatim (no newline). Used for control codes:
    /// Ctrl+C → `Data([0x03])`, Ctrl+D → `Data([0x04])`, etc.
    func sendRaw(_ data: Data) {
        guard let view = view else { return }
        let bytes = [UInt8](data)
        view.send(data: ArraySlice(bytes))
    }

    /// Forwards to `TorTerminalView.isShellAtPrompt()`.
    func isAtPrompt() -> Bool {
        view?.isShellAtPrompt() ?? true
    }
}

/// Wraps `TorTerminalView` and forwards raw PTY bytes to a `BlockStore`.
/// Polls foreground-process state — when the shell returns to its own
/// prompt, the most recent running block is marked done and the input
/// bar unlocks.
struct TorTerminalContainer: NSViewRepresentable {
    @ObservedObject var themeManager: ThemeManager
    var session: ShellBridge?
    var blockStore: BlockStore?
    var mode: ShellMode?
    var insets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    func makeNSView(context: Context) -> PaddedTerminalHost {
        let host = PaddedTerminalHost(insets: insets)
        host.terminal.applyTheme(themeManager.current)
        host.terminal.startShell()
        session?.view = host.terminal

        let store = blockStore
        let modeBox = mode

        // Poll foreground-process state every 200ms. When the shell is
        // its own foreground group again (no child running), flip the
        // most recent block's `isRunning` to false → input bar unlocks.
        // Going through `BlockStore.markCurrentDone()` (vs `block.markDone`
        // directly) makes the store republish so SwiftUI observers of
        // `blockStore` re-render and pick up the unlocked state.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak terminal = host.terminal] _ in
            guard let terminal = terminal else { return }
            let atPrompt = terminal.isShellAtPrompt()
            MainActor.assumeIsolated {
                if atPrompt {
                    store?.markCurrentDone()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        host.terminal.onPtyBytes = { bytes in
            let raw = String(decoding: bytes, as: UTF8.self)

            let altOn  = raw.contains("\u{1B}[?1049h")
                      || raw.contains("\u{1B}[?1047h")
                      || raw.contains("\u{1B}[?47h")
            let altOff = raw.contains("\u{1B}[?1049l")
                      || raw.contains("\u{1B}[?1047l")
                      || raw.contains("\u{1B}[?47l")

            if altOn || altOff {
                let next = altOn ? true : false
                Task { @MainActor in
                    modeBox?.altScreen = next
                }
            }

            let isAlt = MainActor.assumeIsolated { modeBox?.altScreen ?? false }
            if isAlt { return }

            let clean = AnsiStripper.strip(raw)
            guard !clean.isEmpty else { return }
            Task { @MainActor in
                store?.appendToCurrent(clean)
            }
        }
        return host
    }

    func updateNSView(_ nsView: PaddedTerminalHost, context: Context) {
        nsView.terminal.applyTheme(themeManager.current)
        nsView.contentInsets = insets
        nsView.needsLayout = true
        if session?.view !== nsView.terminal {
            session?.view = nsView.terminal
        }
    }
}

/// AppKit container that lays out a `TorTerminalView` with fixed insets.
final class PaddedTerminalHost: NSView {
    let terminal = TorTerminalView(frame: .zero)
    var contentInsets: NSEdgeInsets

    init(insets: NSEdgeInsets) {
        self.contentInsets = insets
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        addSubview(terminal)
    }

    required init?(coder: NSCoder) {
        self.contentInsets = NSEdgeInsets()
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        terminal.frame = NSRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: max(0, b.width - contentInsets.left - contentInsets.right),
            height: max(0, b.height - contentInsets.top - contentInsets.bottom)
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
        super.mouseDown(with: event)
    }
}
