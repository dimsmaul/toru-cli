import SwiftUI
import AppKit
import Darwin

/// Hierarchy:
///   Sidebar (sessions) → TabBar (tabs in active session) → active tab pane
///
/// Sessions are top-level workspaces. Each session contains 1+ tabs; each
/// tab is its own shell. ⌘N adds a session, ⌘T adds a tab to the active
/// session.
struct ContentView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: sessions)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            Group {
                if let session = sessions.activeSession {
                    SessionDetailView(session: session, themeManager: themeManager)
                        .id(session.id)
                } else {
                    Text("No session")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
    }
}

/// Wraps the active `Session` so SwiftUI re-renders when `session.tabs`
/// changes (adding / closing a tab while we're showing this session).
struct SessionDetailView: View {
    @ObservedObject var session: Session
    @ObservedObject var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            if session.tabs.count > 1 {
                TabStripView(session: session)
            }

            if let tab = session.activeTab {
                SessionPaneView(tab: tab, themeManager: themeManager)
                    .id(tab.id)
            } else {
                Text("No tab")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.tint)
                    Text("Toru CLI")
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.newTab()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New tab (⌘T)")
                .keyboardShortcut("t", modifiers: [.command])
            }
        }
    }
}

/// Detail pane for the *active tab* of the active session. Reads
/// `tab.shellBridge` / `tab.blockStore` / `tab.host`.
struct SessionPaneView: View {
    @ObservedObject var tab: TabState
    @ObservedObject var themeManager: ThemeManager

    /// Live cwd for the foreground process of `tab`'s shell, queried via
    /// `tcgetpgrp` + `proc_pidinfo`. Falls back to `$HOME` when the shell
    /// isn't ready yet.
    private static func cwd(for tab: TabState) -> String {
        guard let proc = tab.host.terminal.process, proc.shellPid > 0 else {
            return NSHomeDirectory()
        }
        let fg = tcgetpgrp(proc.childfd)
        let pid = (fg > 0) ? fg : proc.shellPid
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard n == Int32(size) else { return NSHomeDirectory() }
        let pathTuple = info.pvi_cdir.vip_path
        return withUnsafeBytes(of: pathTuple) { raw -> String in
            guard let base = raw.baseAddress else { return NSHomeDirectory() }
            let cstr = base.assumingMemoryBound(to: CChar.self)
            let s = String(cString: cstr)
            return s.isEmpty ? NSHomeDirectory() : s
        }
    }

    private var mode: TerminalMode { tab.shellBridge.terminalMode }

    @State private var searchQuery: String = ""
    @State private var showSearch: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
            }

            // Block list = finalized history only. The currently-running
            // block is hidden here and rendered inside the bottom
            // `ActiveCellView` instead, so it appears to "detach" into the
            // history list when the command exits.
            BlockListView(
                blockStore: tab.blockStore,
                isLocked: false,
                searchQuery: showSearch ? searchQuery : "",
                showRunning: false,
                onRerun: rerun,
                onDelete: deleteBlock
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom morphing cell: TextField → live SwiftTerm → snapshot
            // back into the block list above when the command exits.
            ActiveCellView(
                tab: tab,
                blockStore: tab.blockStore,
                shellBridge: tab.shellBridge,
                onSubmit: handleSubmit,
                onCtrlC: { tab.shellBridge.sendRaw(Data([0x03])) },
                cwdProvider: { Self.cwd(for: tab) }
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .background(
            GeometryReader { geo -> Color in
                let size = geo.size
                Task { @MainActor in
                    tab.updateSize(width: size.width, height: size.height)
                }
                return Color.clear
            }
        )
        .onAppear {
            tab.ensureStarted(themeManager: themeManager)
        }
        .onChange(of: mode) { _, new in
            handleModeChange(new)
        }
        .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
            if press.modifiers.contains(.control) && mode != .idle {
                tab.shellBridge.sendRaw(Data([0x03]))
                return .handled
            }
            return .ignored
        }
        .background(hotkeyOverlay)
    }

    @ViewBuilder
    private var hotkeyOverlay: some View {
        Group {
            Button(action: clearBlocks) { EmptyView() }
                .keyboardShortcut("k", modifiers: [.command])
            Button(action: clearBlocks) { EmptyView() }
                .keyboardShortcut("l", modifiers: [.command])
            Button(action: newConversation) { EmptyView() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button(action: toggleSearch) { EmptyView() }
                .keyboardShortcut("f", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search blocks…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($searchFocused)
                .onSubmit { /* keep open; just commit query */ }
                .onKeyPress(.escape, phases: .down) { _ in
                    closeSearch()
                    return .handled
                }
            if !searchQuery.isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close search (⎋)")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var matchCountLabel: String {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return "" }
        let count = tab.blockStore.blocks.filter { block in
            block.command.lowercased().contains(q) ||
            String(block.output.characters).lowercased().contains(q)
        }.count
        return "\(count) match\(count == 1 ? "" : "es")"
    }

    private func toggleSearch() {
        DispatchQueue.main.async {
            if showSearch {
                closeSearch()
            } else {
                showSearch = true
                searchFocused = true
            }
        }
    }

    private func closeSearch() {
        DispatchQueue.main.async {
            showSearch = false
            searchQuery = ""
        }
    }

    // MARK: - Submit

    private func handleSubmit(_ cmd: String) {
        DispatchQueue.main.async {
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)

            HistoryDatabase.shared.record(
                rawInput: cmd,
                executed: trimmed,
                directory: NSHomeDirectory(),
                sessionId: tab.id.uuidString
            )

            if trimmed == "clear" || trimmed == "cls" {
                withAnimation(.easeOut(duration: 0.15)) {
                    tab.blockStore.clearAll()
                }
                tab.shellBridge.send(command: cmd)
                return
            }

            let baseline = tab.host.terminal.absoluteCursorRow
            tab.blockStore.startBlock(command: cmd, startCursorRow: baseline)
            tab.shellBridge.activeCommand = trimmed
            // Tab title reflects the running command so a multi-tab
            // setup is scannable (e.g. `bun start`, `npm run dev`).
            // Restored to `defaultTitle` in `handleModeChange` when the
            // shell returns to its prompt.
            tab.title = trimmed.isEmpty ? tab.defaultTitle : trimmed
            // Wipe the GridEmulator before the new command's output
            // starts streaming. Without this, the previous command's
            // grid state leaks into this block's render at finalize
            // (e.g. `ls` output appearing at the top of `neofetch`).
            tab.renderer.resetGrid()
            tab.shellBridge.send(command: cmd)
            // Quick one-shot recompute so commands taking >~50ms swap
            // into the live terminal surface without waiting a full
            // poll interval. Instant commands (`ls`, `cd`) have already
            // returned to the prompt by the nudge tick — they stay in
            // `.idle`, which is what kills the previous flash glitch.
            tab.shellBridge.nudgePoll()
        }
    }

    // MARK: - Mode / window title

    private func handleModeChange(_ new: TerminalMode) {
        DispatchQueue.main.async {
            switch new {
            case .running:
                if let v = tab.shellBridge.view {
                    v.window?.makeFirstResponder(v)
                    if let prog = tab.shellBridge.activeCommand {
                        v.window?.title = "Toru — \(prog)"
                    }
                }
            case .idle:
                tab.shellBridge.view?.window?.title = "Toru"
                // Restore the tab's permanent title once the running
                // command exits.
                tab.title = tab.defaultTitle
            }
        }
    }

    // MARK: - Hotkey actions

    private func clearBlocks() {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                tab.blockStore.clearAll()
            }
        }
    }

    private func newConversation() {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                tab.blockStore.clearAll()
            }
            tab.shellBridge.activeCommand = nil
        }
    }

    // MARK: - Block actions

    private func rerun(_ block: Block) {
        guard mode == .idle else { return }
        let cmd = block.command
        DispatchQueue.main.async {
            let baseline = tab.host.terminal.absoluteCursorRow
            tab.blockStore.startBlock(command: cmd, startCursorRow: baseline)
            tab.shellBridge.activeCommand = cmd
            tab.title = cmd.isEmpty ? tab.defaultTitle : cmd
            // Fresh grid for this command. Streamed renderer state
            // (SGR style, parser FSM) carries over intentionally — it
            // tracks the *terminal*, not a single block.
            tab.renderer.resetGrid()
            tab.shellBridge.send(command: cmd)
            tab.shellBridge.nudgePoll()
        }
    }

    private func deleteBlock(_ block: Block) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                tab.blockStore.remove(block)
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
