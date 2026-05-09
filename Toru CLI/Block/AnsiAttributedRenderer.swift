import Foundation
import SwiftUI
import AppKit

/// Streaming SGR (Select Graphic Rendition) parser that converts ANSI
/// terminal output into `AttributedString` runs preserving color, bold,
/// italic, and underline.
///
/// Handled escape sequences:
///   - `ESC[0m` / `ESC[m`           reset
///   - `ESC[1m` bold, `ESC[3m` italic, `ESC[4m` underline
///   - `ESC[30-37m`  fg basic 8 colors
///   - `ESC[90-97m`  fg bright 8 colors
///   - `ESC[40-47m`  bg basic
///   - `ESC[100-107m` bg bright
///   - `ESC[38;5;Nm` / `ESC[48;5;Nm`   256-color
///   - `ESC[38;2;R;G;Bm` / `ESC[48;2;R;G;Bm`  truecolor
///
/// Other CSI sequences (cursor moves, etc.) are dropped. OSC sequences
/// are dropped. BEL / BS / CR are stripped, LF / TAB pass through (tabs
/// expanded to 8-col stops).
final class AnsiAttributedRenderer {

    // MARK: - Style state

    private struct Style {
        var fg: Color? = nil
        var bg: Color? = nil
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false

        func apply(to s: inout AttributedString) {
            if let fg { s.foregroundColor = fg }
            if let bg { s.backgroundColor = bg }
            if bold {
                s.font = .system(size: 12, design: .monospaced).weight(.bold)
            } else {
                s.font = .system(size: 12, design: .monospaced)
            }
            if italic { s.font = (s.font ?? .system(size: 12, design: .monospaced)).italic() }
            if underline { s.underlineStyle = .single }
        }
    }

    private var style = Style()
    private var col: Int = 0

    /// PTY in default `ONLCR` mode emits `\r\n` for every newline. The
    /// streaming renderer used to treat CR and LF as separate newline
    /// emits — that double-spaced every line of `ls`, `cat`, etc. We
    /// now hold off on the CR's newline and merge it with a following
    /// LF. A lone CR (progress bars, e.g. `\r10%\r20%`) still emits a
    /// newline because we can't reposition the cursor inside a flat
    /// `AttributedString`.
    private var pendingCR: Bool = false

    /// Mini terminal-screen emulator running parallel to the streaming
    /// path. We feed every chunk into both — the streamer produces the
    /// live `AttributedString` for `Block.output` while the command
    /// runs (gives the user fast colored feedback even on long-running
    /// commands), and the grid produces the *correct* layout when the
    /// command exits, used to overwrite the streamed output for blocks
    /// that flagged `usedCursorMoves`. Resets per command via
    /// `resetGrid()`.
    let grid = GridEmulator()

    /// Latched `true` whenever a non-SGR CSI final byte goes by — i.e. a
    /// cursor move (`A`/`B`/`C`/`D`/`H`/`f`/`G`/`E`/`F`), an erase
    /// (`J`/`K`), insert/delete-line (`L`/`M`), etc. The streaming path
    /// drops these sequences, so any block that uses them ends up with
    /// a flat-appended transcript that doesn't match what the user saw
    /// (neofetch logo overlap, claude TUI redraws, ascii art).
    /// `BlockStore` checks this between chunks and tags the running
    /// block; `ShellBridge.captureFinalOutput` then knows to replace
    /// the streamed output with a buffer snapshot at finalize. Plain
    /// commands (`ls`, `git status`, `echo`) never set this flag and
    /// keep their colored streamed output untouched.
    private(set) var didSeeCursorMove: Bool = false

    /// Returns the current value and clears the flag in a single read.
    /// Tap callers poll once per chunk so we know which block to tag.
    func consumeCursorMoveFlag() -> Bool {
        let v = didSeeCursorMove
        didSeeCursorMove = false
        return v
    }

    /// Latched `true` when SwiftTerm switches to the alternate screen
    /// buffer via `CSI ?1049h` / `?1047h` / `?47h` — i.e. a TUI took
    /// over the terminal (vim, htop, less, claude code, fzf). The
    /// stream during that time is full of CSI redraws that look like
    /// garbage in a flat transcript, so `BlockStore` clears the block's
    /// output entirely once it sees this flag.
    private(set) var didEnterAltScreen: Bool = false

    func consumeAltScreenFlag() -> Bool {
        let v = didEnterAltScreen
        didEnterAltScreen = false
        return v
    }

    // MARK: - Parser state machine

    private enum State { case text, esc, csi, osc }
    private var state: State = .text
    private var paramBuf: [UInt8] = []

    /// Pending text bytes that haven't been emitted yet (gathered before
    /// a control byte forces a flush).
    private var pendingText = Data()

    // MARK: - Public API

    /// Feed a chunk of raw PTY bytes; returns an AttributedString
    /// containing all the styled text from this chunk. Also feeds the
    /// same bytes through the parallel `GridEmulator` so we have a
    /// correct-layout copy ready when the block finalizes.
    func feed(_ bytes: [UInt8]) -> AttributedString {
        grid.feed(bytes)
        var out = AttributedString()
        for b in bytes {
            switch state {
            case .text: handleText(b, into: &out)
            case .esc:  handleEsc(b)
            case .csi:  handleCsi(b, into: &out)
            case .osc:  handleOsc(b)
            }
        }
        flushPending(into: &out)
        return out
    }

    /// Resets the grid emulator's screen + cursor for a fresh command.
    /// Called from `handleSubmit` / `rerun` before sending bytes so the
    /// new command's output starts at row 0 of an empty grid.
    func resetGrid() {
        grid.reset()
    }

    // MARK: - Byte handlers

    private func handleText(_ b: UInt8, into out: inout AttributedString) {
        // Resolve any pending CR. If the next byte is LF, the pair was
        // a single CRLF and we drop the CR-induced newline. Otherwise
        // it was a lone CR (progress-bar reset) — emit one newline
        // before processing `b`.
        if pendingCR {
            if b == 0x0A {
                pendingText.append(0x0A)
                col = 0
                pendingCR = false
                return
            }
            pendingText.append(0x0A)
            col = 0
            pendingCR = false
        }

        switch b {
        case 0x1B:  // ESC
            flushPending(into: &out)
            state = .esc
        case 0x0A:  // LF (lone — pendingCR was false above)
            pendingText.append(0x0A)
            col = 0
        case 0x0D:  // CR — defer; merge with following LF or emit on
                    // any other byte. Stops PTY's `ONLCR` (\n → \r\n)
                    // from doubling newlines for every line of output.
            pendingCR = true
        case 0x09:  // TAB → expand to next 8-col stop
            let spaces = 8 - (col % 8)
            for _ in 0..<spaces { pendingText.append(0x20) }
            col += spaces
        case 0x07, 0x08:  // BEL / BS — drop
            break
        default:
            pendingText.append(b)
            // Advance column on printable bytes (rough, not UTF-8 aware
            // for combining marks but adequate for tab-stop expansion).
            if b >= 0x20 { col += 1 }
        }
    }

    private func handleEsc(_ b: UInt8) {
        switch b {
        case 0x5B:  // [
            state = .csi
            paramBuf.removeAll(keepingCapacity: true)
        case 0x5D:  // ]
            state = .osc
        default:
            // Two-byte ESC sequence we don't care about — drop.
            state = .text
        }
    }

    private func handleCsi(_ b: UInt8, into out: inout AttributedString) {
        // CSI: params 0x30-0x3F + intermediates 0x20-0x2F + final 0x40-0x7E.
        if b >= 0x30 && b <= 0x3F {
            paramBuf.append(b)
            return
        }
        if b >= 0x40 && b <= 0x7E {
            // Final byte. Only act on 'm' (SGR); drop everything else,
            // but latch flags for sequences callers care about.
            if b == 0x6D {  // 'm'
                applySGR(parseParams(paramBuf))
            } else if b == 0x68 {  // 'h' — Set Mode (DECSET when private)
                let p = String(bytes: paramBuf, encoding: .ascii) ?? ""
                if p == "?1049" || p == "?1047" || p == "?47" {
                    didEnterAltScreen = true
                } else {
                    didSeeCursorMove = true
                }
            } else {
                didSeeCursorMove = true
            }
            state = .text
            paramBuf.removeAll(keepingCapacity: true)
            _ = out  // unused — flush happens via pendingText path
        }
    }

    private func handleOsc(_ b: UInt8) {
        // Drop OSC content; terminate on BEL or ST (ESC \).
        if b == 0x07 { state = .text }
        else if b == 0x1B {
            // Look ahead to consume \. Easier: bounce to .esc; if next
            // byte is \, plain ESC handler drops it. Good enough.
            state = .esc
        }
    }

    // MARK: - SGR

    private func parseParams(_ buf: [UInt8]) -> [Int] {
        guard let s = String(bytes: buf, encoding: .ascii), !s.isEmpty else {
            return [0]
        }
        return s.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:  style = Style()
            case 1:  style.bold = true
            case 3:  style.italic = true
            case 4:  style.underline = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.fg = ansi8Color(p - 30, bright: false)
            case 39: style.fg = nil
            case 40...47: style.bg = ansi8Color(p - 40, bright: false)
            case 49: style.bg = nil
            case 90...97:  style.fg = ansi8Color(p - 90, bright: true)
            case 100...107: style.bg = ansi8Color(p - 100, bright: true)
            case 38, 48:
                // Extended color: 38;5;N or 38;2;R;G;B
                guard i + 1 < params.count else { i += 1; continue }
                let mode = params[i + 1]
                if mode == 5, i + 2 < params.count {
                    let c = xterm256(params[i + 2])
                    if p == 38 { style.fg = c } else { style.bg = c }
                    i += 2
                } else if mode == 2, i + 4 < params.count {
                    let c = Color(red: Double(params[i + 2]) / 255,
                                  green: Double(params[i + 3]) / 255,
                                  blue: Double(params[i + 4]) / 255)
                    if p == 38 { style.fg = c } else { style.bg = c }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - Emit

    private func flushPending(into out: inout AttributedString) {
        guard !pendingText.isEmpty else { return }
        let str = String(data: pendingText, encoding: .utf8)
            ?? String(decoding: pendingText, as: UTF8.self)
        pendingText.removeAll(keepingCapacity: true)
        guard !str.isEmpty else { return }

        var run = AttributedString(str)
        style.apply(to: &run)
        out.append(run)
    }

    // MARK: - Color tables

    private func ansi8Color(_ idx: Int, bright: Bool) -> Color {
        // Indices 0-7 mapped to standard ANSI palette. Bright uses lighter
        // tints (xterm-style).
        let base: [(r: Double, g: Double, b: Double)] = bright
            ? [(0.40, 0.40, 0.40), // bright black
               (1.00, 0.40, 0.40), // bright red
               (0.40, 1.00, 0.40), // bright green
               (1.00, 1.00, 0.40), // bright yellow
               (0.40, 0.65, 1.00), // bright blue
               (1.00, 0.40, 1.00), // bright magenta
               (0.40, 1.00, 1.00), // bright cyan
               (1.00, 1.00, 1.00)] // bright white
            : [(0.10, 0.10, 0.10),
               (0.85, 0.20, 0.20),
               (0.20, 0.75, 0.30),
               (0.85, 0.75, 0.20),
               (0.30, 0.50, 0.85),
               (0.80, 0.30, 0.80),
               (0.20, 0.75, 0.85),
               (0.85, 0.85, 0.85)]
        let safe = max(0, min(7, idx))
        return Color(red: base[safe].r, green: base[safe].g, blue: base[safe].b)
    }

    private func xterm256(_ idx: Int) -> Color {
        let n = max(0, min(255, idx))
        if n < 16 { return ansi8Color(n % 8, bright: n >= 8) }
        if n >= 232 {
            let g = Double(n - 232) * 10.0 / 255.0 + 8.0/255.0
            return Color(red: g, green: g, blue: g)
        }
        let v = n - 16
        let r = (v / 36) % 6
        let g = (v / 6) % 6
        let b = v % 6
        let conv: (Int) -> Double = { $0 == 0 ? 0 : Double(55 + 40 * $0) / 255.0 }
        return Color(red: conv(r), green: conv(g), blue: conv(b))
    }
}
