import AppKit
import SwiftTerm

/// SwiftTerm wrapper.
///
/// Input pipeline (Approach C — local NSEvent monitor):
/// We attach an `NSEvent.addLocalMonitorForEvents` while this view is first
/// responder. The monitor maintains a per-line buffer, runs CommentFilter on
/// Enter, drives ghost-text via AutocompleteEngine, and accepts ghost suffix
/// on Tab / Right Arrow. Pasted input is filtered via NSText paste hook is
/// out of scope for v1; v1 strips at Enter only.
final class TorTerminalView: LocalProcessTerminalView {

    // MARK: - State
    private let sessionId: String = UUID().uuidString
    private var lineBuffer: String = ""
    private let autocomplete = AutocompleteEngine()
    private let tabCompleter = TabCompleter()
    private let history = HistoryDatabase.shared
    private let ghost = GhostTextOverlay()
    private var currentTheme: Theme = ThemeManager.shared.current
    private var keyMonitor: Any?
    private lazy var procDelegate = TorProcessDelegate(owner: self)

    /// External tap on raw PTY bytes. Set by `TorTerminalContainer` so a
    /// SwiftUI `BlockStore` can mirror the shell's output.
    var onPtyBytes: ((ArraySlice<UInt8>) -> Void)?

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    private func configure() {
        processDelegate = procDelegate
        applyTheme(currentTheme)
        addSubview(ghost)
        ghost.isHidden = true
        tabCompleter.warmUp()
        configureFont()
        installKeyMonitor()
    }

    private func configureFont() {
        let size = CGFloat(SettingsStore.shared.fontSize)
        if let f = NSFont(name: SettingsStore.shared.fontName, size: size) ??
                   NSFont(name: "Menlo", size: size) {
            font = f
        }
    }

    func startShell() {
        let shell = PTYBridge.resolveShell()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        FileManager.default.changeCurrentDirectoryPath(home)

        var envDict = PTYBridge.buildEnvironment(shell: shell)
        envDict["HOME"] = home
        envDict["PWD"] = home
        envDict["SHELL"] = shell
        // Don't pre-set COLUMNS / LINES — the dynamic `pinPtySize` push
        // from `SessionState.updateSize(...)` updates the kernel winsize
        // on every layout change, and zsh picks that up. Hard-coding env
        // here would otherwise cause `ls` to honour the stale 80×40 even
        // after the pane is much wider.
        let env = envDict.map { "\($0.key)=\($0.value)" }

        startProcess(executable: shell, args: ["-l"], environment: env, execName: shell)

        // Pin the PTY to 80×40 so column-laying tools (ls, tree, …) stay
        // within the block card's horizontal space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pinPtySize(cols: 80, rows: 40)
        }

        // Hand the live shell PID to SessionMonitor so the status bar can
        // poll cwd / runtime / git from a real process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let pid = self.process.shellPid
            if pid > 0 {
                Task { @MainActor in SessionMonitor.shared.attach(pid: pid) }
            }
        }

        // (Previously: sent ^L 250ms after spawn to wipe the cosmetic
        // "zsh: can't set tty pgrp" line. Removed — with ZLE off the ^L
        // ends up prepended to the first command in zsh's line buffer.
        // The tty-pgrp warning is now filtered out by AnsiStripper's
        // line-level pass instead.)
    }

    // MARK: - Theme
    func applyTheme(_ theme: Theme) {
        currentTheme = theme
        // Transparent native bg lets the parent NSVisualEffectView shine through.
        nativeBackgroundColor = .clear
        nativeForegroundColor = theme.foregroundColor

        let cs = theme.ansiColors
        if cs.count == 16 {
            installColors(cs.map {
                Color(red:   UInt16($0.redComponent   * 65535),
                      green: UInt16($0.greenComponent * 65535),
                      blue:  UInt16($0.blueComponent  * 65535))
            })
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    // MARK: - Key intercept (NSEvent local monitor)
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only intercept when our window is key and we are (or contain) first responder.
            guard event.window === self.window,
                  self.window?.firstResponder === self || self.containsResponder(self.window?.firstResponder)
            else { return event }
            return self.handleKey(event)
        }
    }

    private func containsResponder(_ r: NSResponder?) -> Bool {
        var cur = r
        while let c = cur {
            if c === self { return true }
            cur = c.nextResponder
        }
        return false
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let chars = event.charactersIgnoringModifiers ?? ""

        // Enter / Return — record history (PTY still receives, normal behavior)
        if event.keyCode == 36 || chars == "\r" || chars == "\n" {
            executeCurrentLine()
            lineBuffer.removeAll()
            ghost.isHidden = true
            autocomplete.reset()
            return event
        }

        // Tab or Right-Arrow → accept ghost text (consume, send suffix)
        if (event.keyCode == 48 || event.keyCode == 124),
           !ghost.isHidden, let suffix = ghost.suffix, !suffix.isEmpty {
            send(txt: suffix)
            lineBuffer += suffix
            ghost.isHidden = true
            return nil
        }

        // Escape — dismiss ghost (let PTY also see it)
        if event.keyCode == 53 {
            ghost.isHidden = true
            return event
        }

        // Backspace
        if event.keyCode == 51 {
            if !lineBuffer.isEmpty { lineBuffer.removeLast() }
            autocomplete.onBackspace()
            ghost.isHidden = true
            return event
        }

        // Printable ASCII
        let isPrintable = chars.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        if isPrintable && !chars.isEmpty {
            lineBuffer += chars
            autocomplete.onCharInput()
            DispatchQueue.main.async { [weak self] in self?.updateGhost() }
        }
        return event
    }

    private func updateGhost() {
        guard SettingsStore.shared.ghostTextEnabled else {
            ghost.isHidden = true; return
        }
        guard let suffix = autocomplete.suggest(for: lineBuffer) else {
            ghost.isHidden = true; return
        }
        ghost.show(suffix: suffix, font: font, color: .tertiaryLabelColor, anchor: caretPoint())
    }

    private func caretPoint() -> CGPoint {
        let charWidth = font.maximumAdvancement.width
        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let cols = CGFloat(lineBuffer.count)
        let x = cols * charWidth + 6
        let y = max(2, bounds.height - lineHeight - 4)
        return CGPoint(x: x, y: y)
    }

    private func executeCurrentLine() {
        let raw = lineBuffer
        guard let executed = CommentFilter.filter(raw) else { return }
        history.record(rawInput: raw, executed: executed,
                       directory: NSHomeDirectory(),
                       sessionId: sessionId)
    }

    // MARK: - PTY tap

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let tap = onPtyBytes {
            let copy = Array(slice)
            DispatchQueue.main.async {
                tap(ArraySlice(copy))
            }
        }
    }

    // MARK: - Foreground process detection

    /// `true` when the shell itself is the foreground process group of the
    /// PTY (i.e. sitting at a prompt waiting for the next command).
    /// `false` while a child program is running and reading stdin
    /// (e.g. `npm init` Q&A, `claude`, `vim`, `ssh` password prompt).
    func isShellAtPrompt() -> Bool {
        guard process != nil, process.childfd >= 0, process.shellPid > 0 else {
            return true
        }
        let fg = tcgetpgrp(process.childfd)
        return fg <= 0 || fg == process.shellPid
    }

    /// `true` when the foreground program has put the tty into raw mode —
    /// i.e. cleared `ICANON` so it can read individual keystrokes instead
    /// of line-buffered input. This is the canonical "I am a TUI" signal:
    /// vim, htop, less, claude, opencode, ssh password prompt, npm init's
    /// readline, etc. all flip ICANON off. Plain commands like `ls`,
    /// `cat`, `node -v` leave it on. Pairs with `isShellAtPrompt()`:
    /// the latter means "any child", this means "child wanting raw I/O".
    func childInRawMode() -> Bool {
        guard process != nil, process.childfd >= 0 else { return false }
        var attrs = termios()
        guard tcgetattr(process.childfd, &attrs) == 0 else { return false }
        return (attrs.c_lflag & UInt(ICANON)) == 0
    }

    // MARK: - Hidden-view size pinning

    /// Floor for accepting NSView frame changes from SwiftUI. When
    /// `ActiveCellView` parks SwiftTerm at `1x1` for the inline-block
    /// path (TUI not active — only keyboard / PTY plumbing needed), the
    /// resulting `setFrameSize(1,1)` would cascade through SwiftTerm's
    /// `processSizeChange` → `terminal.resize(0, 0)` and leave the
    /// shell with a 0-column buffer. Anything written next renders one
    /// character per row instead of normal text.
    ///
    /// We intercept those degenerate sizes here and keep SwiftTerm's
    /// frame at whatever it previously was. `pinPtySize` continues to
    /// drive cols/rows from the pane GeometryReader, which is the
    /// authoritative size source anyway.
    private static let minAcceptedFrame: CGFloat = 24

    public override func setFrameSize(_ newSize: NSSize) {
        if newSize.width < Self.minAcceptedFrame ||
           newSize.height < Self.minAcceptedFrame {
            return
        }
        super.setFrameSize(newSize)
    }

    /// Force the underlying SwiftTerm `Terminal` and the kernel-level PTY
    /// winsize to a sensible cols/rows. The NSView itself stays 0×0.
    func pinPtySize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        getTerminal().resize(cols: cols, rows: rows)
        if process != nil, process.childfd >= 0 {
            var ws = winsize(ws_row: UInt16(rows),
                             ws_col: UInt16(cols),
                             ws_xpixel: 0, ws_ypixel: 0)
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: process.childfd,
                windowSize: &ws
            )
        }
    }

    // MARK: - Layout metrics (used by ActiveCellView for content-driven height)

    /// Approximate point height of one terminal row, derived from the
    /// current monospaced font's default line height. Same metric SwiftTerm
    /// uses internally to lay out rows.
    var rowHeightPoints: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// `true` when the foreground program has switched to the alternate
    /// screen buffer (vim, htop, less, fzf, …). The bottom cell expands to
    /// its full cap when this is set so the TUI has room to render.
    var isAlternateScreen: Bool {
        getTerminal().isCurrentBufferAlternate
    }

    /// Best-effort absolute row index of the cursor in scrollback +
    /// active screen, computed as `yDisp + y`. Walks monotonically while
    /// the auto-follow viewport is at the bottom (it always is during an
    /// active command), so `current - baselineAtCommandStart + 1` is the
    /// number of rows the running command has consumed.
    var absoluteCursorRow: Int {
        let buf = getTerminal().buffer
        return buf.yDisp + buf.y
    }

    /// Plain-text snapshot of the current buffer between `startRow`
    /// (absolute) and the cursor's current absolute row, with the
    /// echoed command line skipped and trailing whitespace/blank rows
    /// trimmed.
    ///
    /// Used by `ShellBridge` when finalizing a block so cursor-positioned
    /// output (neofetch, claude, ascii art that overwrites earlier
    /// rows) reflects the on-screen state instead of the raw streamed
    /// bytes — `AnsiAttributedRenderer` drops CSI cursor moves, which
    /// makes the streamed transcript look corrupted for these programs.
    /// SwiftTerm's buffer is the authoritative rendered state.
    func captureOutput(fromAbsoluteRow startRow: Int) -> String {
        let term = getTerminal()
        let endRow = term.buffer.yDisp + term.buffer.y
        guard endRow >= startRow else { return "" }
        let cols = max(1, term.cols)
        let start = Position(col: 0, row: max(0, startRow))
        let end = Position(col: cols - 1, row: endRow)
        var text = term.getText(start: start, end: end)
        // First line is the prompt-with-typed-command — the block
        // header already renders the command, so drop it.
        if let firstNL = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNL)...])
        }
        while let last = text.last, last.isNewline || last == " " {
            text.removeLast()
        }
        return text
    }

    // Note: SwiftTerm's `sizeChanged(source:newCols:newRows:)` is not
    // `open`, so we can't override it. Since the NSView stays 0×0 the
    // delegate only fires once with cols=0/rows=0 at startup; our
    // post-startup `pinPtySize(220, 50)` runs immediately afterwards and
    // becomes the steady-state size.

    fileprivate func updateWindowTitle(_ title: String) {
        window?.title = title.isEmpty ? "Toru CLI" : title
    }
}

final class TorProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TorTerminalView?
    init(owner: TorTerminalView) { self.owner = owner }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.updateWindowTitle(title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
