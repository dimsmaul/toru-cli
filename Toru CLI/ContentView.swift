import SwiftUI
import AppKit

/// Layout:
///   ┌────────────┬──────────────────────────────┐
///   │ Sidebar    │ BlockListView                │
///   │ (Sessions) │  (cards)                     │
///   │            ├──────────────────────────────┤
///   │            │ InputBarView (locked while a │
///   │            │ command is still running)    │
///   └────────────┴──────────────────────────────┘
///
/// SwiftTerm is always present at full size — visible only when the shell
/// enters alt-screen (vim, htop, claude TUI, …). Input lock + Ctrl+C
/// covers everything else.
struct ContentView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    @StateObject private var shellBridge = ShellBridge()
    @StateObject private var blockStore = BlockStore()
    @StateObject private var mode = ShellMode()

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: sessions)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            ZStack(alignment: .bottom) {
                // SwiftTerm full-size, visible whenever the shell is in
                // alt-screen OR an interactive child has been running >800ms.
                // Renders properly with cursor positioning, accepts raw
                // keystrokes natively (arrows, Esc, Tab, …).
                TorTerminalContainer(
                    themeManager: themeManager,
                    session: shellBridge,
                    blockStore: blockStore,
                    mode: mode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(mode.fullscreenTerminal ? 1 : 0)
                .allowsHitTesting(mode.fullscreenTerminal)

                if !mode.fullscreenTerminal {
                    VStack(spacing: 0) {
                        BlockListView(
                            store: blockStore,
                            onRerun: rerun,
                            onDelete: deleteBlock
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        InputBarView(blockStore: blockStore) { cmd in
                            DispatchQueue.main.async {
                                if shellBridge.isAtPrompt() {
                                    blockStore.startBlock(command: cmd)
                                } else {
                                    blockStore.appendReplyToCurrent(cmd)
                                }
                                shellBridge.send(command: cmd)
                            }
                        }
                        .frame(height: 44)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: mode.fullscreenTerminal)
            .onChange(of: mode.fullscreenTerminal) { _, full in
                if full {
                    // Push focus into SwiftTerm so arrow / Esc / Tab go
                    // straight to the running TUI program.
                    DispatchQueue.main.async {
                        if let v = shellBridge.view {
                            v.window?.makeFirstResponder(v)
                        }
                    }
                }
            }
            // Global Ctrl+C → ETX byte to PTY. Only fires when a child
            // program is actually running. Works in both block mode and
            // fullscreen mode.
            .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                let running = blockStore.blocks.last?.isRunning ?? false
                if press.modifiers.contains(.control) && running {
                    shellBridge.sendRaw(Data([0x03]))
                    return .handled
                }
                return .ignored
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
    }

    private func rerun(_ block: Block) {
        let cmd = block.command
        DispatchQueue.main.async {
            // Only re-run from a clean prompt; otherwise submission would
            // feed the still-running program rather than starting fresh.
            guard shellBridge.isAtPrompt() else { return }
            blockStore.startBlock(command: cmd)
            shellBridge.send(command: cmd)
        }
    }

    private func deleteBlock(_ block: Block) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                blockStore.remove(block)
            }
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
        .environmentObject(ThemeManager.shared)
        .environmentObject(SettingsStore.shared)
        .frame(width: 900, height: 600)
}
