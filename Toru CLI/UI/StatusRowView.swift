import SwiftUI
import AppKit
import Darwin

/// Slim chip strip rendered above the input bar:
///   [runtime version]  [path]  [git branch]
///
/// - **Runtime**: detected from project marker files in cwd (package.json
///   → node, Cargo.toml → rust, go.mod → go, mix.exs → elixir,
///   composer.json → php, requirements.txt / pyproject.toml → python,
///   Gemfile → ruby). Falls back to `node --version` when nothing matches.
/// - **Path**: full pretty path from $HOME → `~/...`.
/// - **Git branch**: shown when cwd is inside a git repo, else hidden.
///
/// All probing is done by `SessionMonitor.shared`. This view just binds
/// chips to its published state and re-attaches the singleton to the
/// active tab's shell pid on appear.
struct StatusRowView: View {
    @ObservedObject var tab: TabState
    @ObservedObject private var monitor = SessionMonitor.shared

    var body: some View {
        HStack(spacing: 10) {
            chip(displayedRuntime, color: Color.teal)
            chip(prettyPath(monitor.cwd), color: Color(nsColor: .labelColor).opacity(0.85))
            if !monitor.branch.isEmpty {
                chip("git:(\(monitor.branch)\(monitor.dirty ? " ●" : ""))",
                     color: Color.purple.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(height: 24)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .onAppear { attachMonitor() }
        .onChange(of: tab.id) { _, _ in attachMonitor() }
    }

    private var displayedRuntime: String {
        monitor.runtime.isEmpty ? "node" : monitor.runtime
    }

    private func attachMonitor() {
        guard let proc = tab.host.terminal.process, proc.shellPid > 0 else { return }
        SessionMonitor.shared.attach(pid: proc.shellPid)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func prettyPath(_ path: String) -> String {
        guard !path.isEmpty else { return "~" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
