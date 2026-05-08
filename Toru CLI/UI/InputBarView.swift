import SwiftUI
import AppKit

/// Sticky bottom input bar.
///
/// Always submits — there's no hard lock anymore. Behaviour at submit time
/// is decided by the caller (`ContentView`) based on
/// `shellBridge.isAtPrompt()`:
///   - At prompt → caller starts a new block + sends the command.
///   - Child running (claude trust prompt, npm init Q&A, ssh password,
///     read -p, …) → caller forwards the bytes to the running program as
///     stdin without creating a new block.
///
/// A small visual cue distinguishes the two states: prefix and chevron
/// turn orange (`›`) when a child program is running.
struct InputBarView: View {
    @ObservedObject var blockStore: BlockStore
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// True while the most recent block hasn't been marked done. Used
    /// only as a visual cue — the field is still editable.
    private var childRunning: Bool {
        blockStore.blocks.last?.isRunning ?? false
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(childRunning ? "›" : ">")
                .foregroundStyle(childRunning ? Color.orange : Color.teal)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .help(childRunning
                      ? "Child program running — typed text feeds its stdin (⌃C to interrupt)"
                      : "Shell ready — type a command")

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(nsColor: .labelColor))
                .focused($focused)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(submitColor)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .help("Send (⏎)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        // Subtle 2px orange edge on the left when in interactive mode —
        // makes the "stdin to running program" state obvious at a glance.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.orange.opacity(childRunning ? 0.85 : 0))
                .frame(width: 2)
        }
        .animation(.easeInOut(duration: 0.2), value: childRunning)
        .onAppear { focused = true }
        // Refocus the field when the running command finishes — saves
        // the user from having to click back into the input.
        .onChange(of: childRunning) { _, running in
            if !running {
                focused = true
            }
        }
    }

    private var placeholder: String {
        childRunning ? "Reply to running program…" : "Type a command…"
    }

    private var submitColor: Color {
        if text.isEmpty { return Color.gray }
        return childRunning ? Color.orange : Color.teal
    }

    private func submit() {
        let cmd = text.trimmingCharacters(in: .whitespaces)
        // In interactive mode an empty Enter is meaningful — many TUI
        // prompts accept it as "confirm default selection". In idle mode
        // empty submit is a no-op.
        if cmd.isEmpty && !childRunning { return }
        onSubmit(cmd)
        text = ""
        focused = true
    }
}
