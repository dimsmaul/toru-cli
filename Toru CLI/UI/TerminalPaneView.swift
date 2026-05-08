import SwiftUI

/// Detail-pane layout: SwiftTerm terminal on top, slim status bar below.
struct TerminalPaneView: View {
    @ObservedObject var themeManager: ThemeManager
    @State private var showHistorySearch = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                TorTerminalContainer(themeManager: themeManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                TerminalStatusBar()
            }
            .ignoresSafeArea(edges: .bottom)

            if showHistorySearch {
                HistorySearchOverlay(
                    isPresented: $showHistorySearch,
                    onSelect: { _ in /* paste-on-select wired in v1.1 */ }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showHistorySearch)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.tint)
                    Text("Toru CLI")
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showHistorySearch.toggle()
                } label: {
                    Label("History", systemImage: "magnifyingglass")
                }
                .help("History search (⌃R)")
                .keyboardShortcut("r", modifiers: [.control])
            }
        }
    }
}
