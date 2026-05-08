import SwiftUI

/// Vertical scroll of `Block` cards. Bottom-anchored like a chat thread:
/// the newest block sits just above the input bar; older blocks scroll up
/// out of view. With `defaultScrollAnchor(.bottom)` SwiftUI keeps the
/// trailing content pinned automatically — no manual `scrollTo` needed.
struct BlockListView: View {
    @ObservedObject var store: BlockStore
    let onRerun: (Block) -> Void
    let onDelete: (Block) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(store.blocks) { block in
                    BlockRowView(block: block, onRerun: onRerun, onDelete: onDelete)
                        .id(block.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }
}
