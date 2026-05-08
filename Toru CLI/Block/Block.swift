import Foundation
import SwiftUI

/// One command + accumulated stripped-text output. Output mutations are
/// coalesced through a single 60fps `objectWillChange.send()` so the
/// SwiftUI list isn't rebuilt on every byte.
@MainActor
final class Block: Identifiable, ObservableObject {
    let id = UUID()
    let command: String
    let startedAt = Date()

    private(set) var output: String = ""

    /// `true` while bytes are still arriving for this block. Flipped to
    /// `false` when a new command is submitted (treating the previous
    /// block as done) or when the user explicitly clears.
    @Published var isRunning: Bool = true

    /// Optional exit code. Detection is best-effort; nil means unknown
    /// (also rendered as "ok").
    @Published var exitCode: Int? = nil

    private var notifyScheduled = false

    init(command: String) {
        self.command = command
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
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

/// Ordered list of blocks for the active session.
@MainActor
final class BlockStore: ObservableObject {
    @Published private(set) var blocks: [Block] = []

    /// Start a new block. Marks the previous block as done (since
    /// commands are sequential in this build).
    func startBlock(command: String) {
        blocks.last?.markDone()
        blocks.append(Block(command: command))
    }

    func appendToCurrent(_ chunk: String) {
        blocks.last?.append(chunk)
    }

    /// Echo the user's interactive reply into the currently running
    /// block so the back-and-forth (claude trust prompt, npm init Q&A,
    /// ssh password, …) is visible in the card history. No-op when no
    /// block is running.
    func appendReplyToCurrent(_ text: String) {
        guard let last = blocks.last, last.isRunning else { return }
        last.append("\n› \(text)\n")
    }

    func remove(_ block: Block) {
        blocks.removeAll { $0.id == block.id }
    }

    func clear() {
        blocks.removeAll()
    }

    /// Mark the most recent block as done. Republishes the store so
    /// SwiftUI views observing `BlockStore` (e.g. `InputBarView` checking
    /// `blocks.last?.isRunning`) re-render and reflect the unlocked state.
    /// Without this, mutations on the inner `Block` only fire its own
    /// `objectWillChange` and the parent observers don't see the change.
    func markCurrentDone(exitCode: Int? = nil) {
        guard let cur = blocks.last, cur.isRunning else { return }
        cur.markDone(exitCode: exitCode)
        objectWillChange.send()
    }
}
