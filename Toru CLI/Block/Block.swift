import Foundation
import SwiftUI

/// One command + its attributed output. Output is an `AttributedString`
/// so per-run color attributes from the ANSI renderer are preserved when
/// SwiftUI's `Text` renders it.
@MainActor
final class Block: Identifiable, ObservableObject {
    let id = UUID()
    let command: String
    let startedAt = Date()

    /// Absolute cursor row in the terminal (`yDisp + y`) at the moment
    /// this command was submitted. Used as the zero point for content-
    /// driven height growth in `ActiveCellView` — `currentRow - this + 1`
    /// = visible rows the running command has consumed.
    let startCursorRow: Int

    @Published var output: AttributedString = AttributedString()
    @Published var isRunning: Bool = true
    @Published var exitCode: Int? = nil

    /// `true` once the streaming renderer reports that this command
    /// emitted CSI cursor moves / clears (neofetch, ascii art, fancy
    /// progress bars). Used by `ShellBridge.applyGridSnapshotIfNeeded`
    /// to swap streamed output for grid-rendered output at finalize.
    @Published var usedCursorMoves: Bool = false

    /// `true` once the foreground program switched to the alternate
    /// screen buffer (vim, htop, less, claude code, fzf). Drives a UI
    /// switch in `ActiveCellView` from inline block render to a full
    /// SwiftTerm surface so the TUI has a place to draw, and tells
    /// `BlockStore.markCurrentDone` to replace the (garbage) streamed
    /// transcript with a `(interactive session)` marker.
    @Published var usedAlternateScreen: Bool = false

    private var notifyScheduled = false

    init(command: String,
         output: AttributedString = AttributedString(),
         isRunning: Bool = true,
         startCursorRow: Int = 0) {
        self.command = command
        self.output = output
        self.isRunning = isRunning
        self.startCursorRow = startCursorRow
    }

    func append(_ chunk: AttributedString) {
        guard !chunk.characters.isEmpty else { return }
        output.append(chunk)
        scheduleNotify()
    }

    func markDone(exitCode: Int? = nil) {
        guard isRunning else { return }
        isRunning = false
        self.exitCode = exitCode
    }

    private func scheduleNotify() {
        if notifyScheduled { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0/60.0) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.objectWillChange.send()
        }
    }
}

@MainActor
final class BlockStore: ObservableObject {
    @Published private(set) var blocks: [Block] = []

    @Published private(set) var streamTick: Int = 0
    private var streamTickScheduled = false

    func startBlock(command: String, startCursorRow: Int = 0) {
        blocks.append(Block(command: command, startCursorRow: startCursorRow))
    }

    /// Live-append a styled chunk into the most recent running block.
    func appendToCurrent(_ chunk: AttributedString) {
        blocks.last?.append(chunk)
        scheduleStreamTick()
    }

    /// Tags the current running block as having used CSI cursor moves
    /// / clears. Called by the byte-tap whenever the renderer's per-
    /// chunk flag was set.
    func markRunningBlockCursorPositioned() {
        blocks.last?.usedCursorMoves = true
    }

    /// Tags the current running block as a TUI session that used the
    /// alternate screen buffer.
    func markRunningBlockAlternateScreen() {
        blocks.last?.usedAlternateScreen = true
    }

    private func scheduleStreamTick() {
        if streamTickScheduled { return }
        streamTickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.streamTickScheduled = false
            self.streamTick &+= 1
        }
    }

    /// Finalizes the running block.
    ///
    /// Cursor-positioned commands on the *main* screen (neofetch, ascii
    /// art, progress bars) keep their live-streamed colored
    /// `AttributedString` even though the streaming renderer drops CSI
    /// cursor moves — color preservation matters more to the user than
    /// pixel-perfect logo positioning.
    ///
    /// Commands that switched to the *alternate* screen (vim, htop,
    /// less, claude code, fzf) get their output cleared with a small
    /// italic marker — the streamed transcript for those is just
    /// thousands of redraws that look like garbage.
    func markCurrentDone(exitCode: Int? = nil) {
        guard let cur = blocks.last, cur.isRunning else { return }
        if cur.usedAlternateScreen {
            var marker = AttributedString("(interactive session)")
            marker.foregroundColor = .secondary
            marker.font = .system(size: 12, design: .monospaced).italic()
            cur.output = marker
        }
        cur.markDone(exitCode: exitCode)
        objectWillChange.send()
    }

    func remove(_ block: Block) {
        blocks.removeAll { $0.id == block.id }
    }

    func clearAll() {
        blocks.removeAll()
    }

    func clear() { clearAll() }
}
