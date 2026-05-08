import SwiftUI

/// Live status strip rendered below the terminal. Reads from
/// `SessionMonitor.shared`, which polls the running shell's cwd via
/// `proc_pidinfo` and async-detects the runtime + git state.
struct TerminalStatusBar: View {
    @ObservedObject private var monitor = SessionMonitor.shared

    var body: some View {
        HStack(spacing: 12) {
            if !monitor.runtime.isEmpty {
                Text(monitor.runtime)
                    .foregroundStyle(Color.teal)
                    .font(.system(size: 11, design: .monospaced))
            }
            Text(folderLabel)
                .foregroundStyle(.primary)
                .font(.system(size: 11, design: .monospaced))
            if !monitor.branch.isEmpty {
                Text(branchLabel)
                    .foregroundStyle(Color.purple.opacity(0.85))
                    .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var folderLabel: String {
        let p = monitor.cwd
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + String(p.dropFirst(home.count)) }
        return (p as NSString).lastPathComponent
    }

    private var branchLabel: String {
        monitor.branch + (monitor.dirty ? " ●" : "")
    }
}
