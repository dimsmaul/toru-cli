import SwiftUI

struct TerminalSession: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var createdAt: Date = .init()
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [TerminalSession] = [
        TerminalSession(title: "Session 1")
    ]
    @Published var selectedID: UUID?

    init() { selectedID = sessions.first?.id }

    func newSession() {
        // Defer mutations so we never publish during a view-update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let s = TerminalSession(title: "Session \(self.sessions.count + 1)")
            self.sessions.append(s)
            self.selectedID = s.id
        }
    }

    func close(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessions.removeAll { $0.id == id }
            if self.selectedID == id { self.selectedID = self.sessions.first?.id }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedID },
            set: { newValue in
                DispatchQueue.main.async { store.selectedID = newValue }
            }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("Sessions") {
                ForEach(store.sessions) { session in
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundStyle(.tint)
                        Text(session.title)
                        Spacer()
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Close", role: .destructive) {
                            store.close(session.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.newSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session (⌘T)")
            }
        }
    }
}
