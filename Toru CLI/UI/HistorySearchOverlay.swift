import SwiftUI

/// Floating history-search sheet. ⬆⬇ to navigate, ⏎ to accept, ⎋ to dismiss.
/// Matches against `HistoryDatabase.search(query:)` (SQLite LIKE, case
/// insensitive contains).
struct HistorySearchOverlay: View {
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var results: [CommandHistory] = []
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool
    var onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($queryFocused)
                    .onChange(of: query) { _, q in refresh(q) }
                    .onSubmit(accept)
                    .onKeyPress(.upArrow) {
                        guard !results.isEmpty else { return .ignored }
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !results.isEmpty else { return .ignored }
                        selectedIndex = min(results.count - 1, selectedIndex + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close (⎋)")
            }
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { idx, r in
                            row(r, selected: idx == selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = idx
                                    accept()
                                }
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: selectedIndex) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(selectedIndex, anchor: .center)
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .frame(width: 520)
        .padding()
        .onAppear {
            // Seed with most-recent commands so the sheet isn't empty.
            results = HistoryDatabase.shared.recent(limit: 8)
            queryFocused = true
        }
    }

    private func row(_ r: CommandHistory, selected: Bool) -> some View {
        HStack {
            Image(systemName: "arrow.uturn.left")
                .foregroundStyle(.tertiary)
            Text(r.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Text(r.executedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    private func refresh(_ q: String) {
        if q.isEmpty {
            results = HistoryDatabase.shared.recent(limit: 8)
        } else {
            results = HistoryDatabase.shared.search(query: q, limit: 8)
        }
        selectedIndex = 0
    }

    private func accept() {
        guard results.indices.contains(selectedIndex) else { return }
        let cmd = results[selectedIndex].command
        onSelect(cmd)
        isPresented = false
    }
}
