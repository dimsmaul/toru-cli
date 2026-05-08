import Foundation

/// Shared UI mode flags driven by what the shell is currently doing.
@MainActor
final class ShellMode: ObservableObject {
    /// `true` when the shell is in alt-screen (vim, htop, claude TUI, …).
    @Published var altScreen: Bool = false

    /// `true` when a child process has been the foreground process group of
    /// the PTY for at least the debounce interval. Brief commands (ls,
    /// echo, node -v) finish before the debounce fires and never flip the
    /// flag, so the UI doesn't flicker for them.
    @Published private(set) var interactive: Bool = false

    /// Combined flag the UI uses: either an explicit alt-screen TUI or a
    /// long-running interactive child program.
    var fullscreenTerminal: Bool { altScreen || interactive }

    private var pendingTask: Task<Void, Never>?
    private let debounce: Duration = .milliseconds(800)

    /// Called by the poll loop with the latest "is child foreground" check.
    /// Off→On is debounced (must stay true for `debounce`); On→Off is
    /// immediate.
    func setInteractiveCandidate(_ value: Bool) {
        pendingTask?.cancel()
        pendingTask = nil

        if !value {
            if interactive { interactive = false }
            return
        }
        if interactive { return }

        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(400))
            if Task.isCancelled { return }
            self?.interactive = true
        }
    }
}
