import SwiftUI
import AppKit

/// Bottom "active cell". Single morphing surface that owns the user's
/// current interaction with the shell:
///
/// - `.idle`  → renders `InputBarView` (TextField + history / completion).
/// - `.running` → renders a compact header (`> command` + cancel) on top
///   of the live `EmbeddedTerminalView`. The cell is anchored to the
///   bottom of the pane and grows upward to its `maxHeight`.
///
/// When the foreground process exits, `ShellBridge.recomputeMode` flips
/// `terminalMode` back to `.idle` and marks the running block done. The
/// running block is filtered out of `BlockListView` until that point, so
/// it visually "detaches" from the cell into the history list (with the
/// row's slide-up insertion transition) at the same moment the cell
/// collapses back into a TextField.
struct ActiveCellView: View {
    @ObservedObject var tab: TabState
    @ObservedObject var blockStore: BlockStore
    @ObservedObject var shellBridge: ShellBridge

    let onSubmit: (String) -> Void
    let onCtrlC: () -> Void
    let cwdProvider: () -> String

    /// Default height of the running terminal surface. Each command
    /// starts here; the user can drag the top-edge handle to override.
    private let defaultRunHeight: CGFloat = 400

    /// Hard floor for manual resizing — keeps the cell from being
    /// dragged so small the prompt becomes unreadable.
    private let dragMinHeight: CGFloat = 60
    /// Hard ceiling — beyond this the cell would push the input bar out
    /// of view. Caller can still scroll history above it.
    private let dragMaxHeight: CGFloat = 800

    private var mode: TerminalMode { shellBridge.terminalMode }

    private var runningBlock: Block? {
        blockStore.blocks.last(where: { $0.isRunning })
    }

    /// Manual override set by dragging the top edge handle. Wins over
    /// `defaultRunHeight` until the next command is submitted, at which
    /// point it resets to `nil`.
    @State private var userHeightOverride: CGFloat? = nil
    @State private var dragStartHeight: CGFloat = 0
    /// `true` while the user is mid-drag. Used to freeze the SwiftTerm
    /// NSView's inner frame (and therefore its `terminal.resize` cycle)
    /// while only the SwiftUI clip mask animates around it.
    @State private var isDragging: Bool = false
    /// The inner SwiftTerm height captured at drag start. SwiftTerm
    /// renders into this fixed frame for the duration of the drag —
    /// the visible portion is changed via `clipped()` on the outer
    /// SwiftUI frame instead. On `onEnded` the freeze is released and
    /// SwiftTerm gets one resize to the final value.
    @State private var frozenInnerHeight: CGFloat = 400

    private var effectiveRunHeight: CGFloat {
        userHeightOverride ?? defaultRunHeight
    }

    /// Frame given to the SwiftTerm `NSView`. Stays at
    /// `frozenInnerHeight` while dragging (so SwiftTerm's
    /// `setFrameSize → processSizeChange → terminal.resize` chain runs
    /// once, not every drag tick); otherwise tracks the visible cell
    /// height.
    private var innerTerminalHeight: CGFloat {
        isDragging ? frozenInnerHeight : effectiveRunHeight
    }


    var body: some View {
        VStack(spacing: 0) {
            if mode == .running {
                dragHandle
                runningHeader
                // SwiftTerm shown for every running command. It's the
                // authoritative live renderer (handles every CSI, real
                // keyboard delivery, true cursor) and there's no good
                // way to half-mount it without breaking input. The
                // history block render stays correct because
                // `ShellBridge.applyGridSnapshotIfNeeded` swaps in the
                // grid emulator's `AttributedString` at finalize.
                EmbeddedTerminalView(host: tab.host)
                    .frame(maxWidth: .infinity)
                    .frame(height: innerTerminalHeight)
                    .frame(height: effectiveRunHeight, alignment: .bottom)
                    .clipped()
            } else {
                StatusRowView(tab: tab)
                    .transition(.opacity)
                InputBarView(
                    onSubmit: onSubmit,
                    onCtrlC: onCtrlC,
                    cwdProvider: cwdProvider
                )
                .frame(height: 44)
                .transition(.opacity)
            }
        }
        .background(
            (mode == .running ? Color.white.opacity(0.04) : Color.clear)
                .animation(.easeInOut(duration: 0.2), value: mode)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
        // No animation on `effectiveRunHeight` — drag has to feel instant.
        // SwiftUI was queuing a 120ms easeOut for every drag tick, which
        // visibly lagged the resize.
        .onChange(of: mode) { _, new in
            // Each fresh run starts back at `defaultRunHeight`. The user
            // re-drags the top handle if they want a custom size for a
            // specific command.
            if new == .running { userHeightOverride = nil }
        }
    }

    /// Top-edge resize affordance shown above the header during `.running`.
    /// Drag UP grows the terminal surface, drag DOWN shrinks it. Sets
    /// `userHeightOverride`, which wins over the auto-grow until the next
    /// command is submitted.
    @ViewBuilder
    private var dragHandle: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.white.opacity(0.22))
                .frame(width: 32, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        // Freeze SwiftTerm's inner frame at the current
                        // height. While `isDragging == true`, only the
                        // outer SwiftUI clip changes — SwiftTerm itself
                        // never receives a size change.
                        frozenInnerHeight = effectiveRunHeight
                        dragStartHeight = effectiveRunHeight
                    }
                    // Cell is anchored bottom; drag up = negative
                    // translation.height = grow.
                    let proposed = dragStartHeight - value.translation.height
                    let clamped = max(dragMinHeight, min(dragMaxHeight, proposed))
                    if userHeightOverride != clamped {
                        userHeightOverride = clamped
                    }
                }
                .onEnded { _ in
                    // Release the freeze. SwiftTerm gets exactly one
                    // size change here (inner frame snaps to outer),
                    // not 120 per second of dragging.
                    isDragging = false
                    dragStartHeight = 0
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }


    @ViewBuilder
    private var runningHeader: some View {
        HStack(spacing: 8) {
            Text(">")
                .foregroundStyle(Color.teal)
                .font(.system(size: 13, design: .monospaced).weight(.semibold))
            Text(runningBlock?.command ?? shellBridge.activeCommand ?? "")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
            Button(action: onCtrlC) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Cancel (⌃C)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 30)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}
