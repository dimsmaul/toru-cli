import SwiftUI
import AppKit

/// One block rendered as a Warp-style card, with two special variants:
///
/// 1. **Marker block** — `command` starts with `"───"`. Renders as a
///    centred italic divider label (e.g. "─── session resumed ───"
///    after exiting full-TUI). No header chrome, no hover, no actions.
///
/// 2. **Locked card** — `isLocked == true`. The user is in
///    `.inlineInteractive` mode: hover ellipsis menu, re-run, delete and
///    text selection are suppressed. A "waiting for input…" pill replaces
///    the spinner. The card border tints orange.
struct BlockRowView: View {
    @ObservedObject var block: Block
    var isLocked: Bool = false
    /// Active search term. When non-empty, occurrences in both the
    /// command and output get a yellow background highlight (case-
    /// insensitive). Empty string disables highlighting.
    var searchQuery: String = ""
    var onRerun: ((Block) -> Void)? = nil
    var onDelete: ((Block) -> Void)? = nil

    @State private var hovering = false

    private var isMarker: Bool { block.command.hasPrefix("───") }

    var body: some View {
        if isMarker {
            markerBody
        } else {
            cardBody
        }
    }

    // MARK: - Marker

    private var markerBody: some View {
        Text(block.command)
            .font(.system(size: 11).italic())
            .foregroundStyle(Color.secondary.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // MARK: - Normal card

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !block.output.characters.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                outputBody
            }

            if block.isRunning {
                Rectangle()
                    .fill(isLocked ? Color.orange.opacity(0.5) : Color.teal.opacity(0.4))
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(cardBorder, lineWidth: 1)
                )
        )
        .onHover { value in
            hovering = isLocked ? false : value
        }
    }

    private var cardFill: Color {
        if commandFailed { return Color.red.opacity(0.10) }
        return Color(nsColor: .windowBackgroundColor).opacity(0.6)
    }

    private var cardBorder: Color {
        if commandFailed { return Color.red.opacity(0.35) }
        if block.isRunning && isLocked { return Color.orange.opacity(0.4) }
        return Color.white.opacity(0.06)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(">")
                .foregroundStyle(Color.teal)
                .font(.system(size: 13, design: .monospaced))

            Group {
                if isLocked {
                    Text(highlightedCommand)
                        .textSelection(.disabled)
                } else {
                    Text(highlightedCommand)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 13, design: .monospaced).weight(.semibold))
            .foregroundStyle(commandColor)

            Spacer()

            // Status / state indicators.
            if block.isRunning && isLocked {
                Text("waiting for input…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            } else if block.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            // Ellipsis menu — only when *not* locked AND not running.
            if !isLocked && !block.isRunning {
                ellipsisMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var ellipsisMenu: some View {
        Menu {
            Button("Copy command") { copy(block.command) }
            Button("Copy output")  { copy(String(block.output.characters)) }
            Button("Copy both")    { copy("> \(block.command)\n\(String(block.output.characters))") }
            Divider()
            Button("Re-run")       { onRerun?(block) }
            Divider()
            Button("Delete", role: .destructive) { onDelete?(block) }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help("Actions")
    }

    // MARK: - Output

    @ViewBuilder
    private var outputBody: some View {
        // `block.output` is an `AttributedString` produced by
        // `AnsiAttributedRenderer` — SGR colors / bold / italic /
        // underline are baked into per-run attributes. Tabs are already
        // expanded inside the renderer.
        Group {
            if isLocked {
                Text(highlightedOutput).textSelection(.disabled)
            } else {
                Text(highlightedOutput).textSelection(.enabled)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var commandFailed: Bool {
        if let code = block.exitCode, code != 0 { return true }
        return false
    }

    private var commandColor: Color {
        commandFailed ? Color.red.opacity(0.9) : Color.primary
    }

    // MARK: - Search highlight

    private var highlightedCommand: AttributedString {
        highlight(AttributedString(block.command), query: searchQuery)
    }

    private var highlightedOutput: AttributedString {
        highlight(block.output, query: searchQuery)
    }

    /// Adds a yellow background to every case-insensitive occurrence of
    /// `query` in `source`. Range mapping uses character offsets, which
    /// match between `String` and `AttributedString` for plain ASCII /
    /// monospaced terminal output (the only flavor we render here).
    private func highlight(_ source: AttributedString, query: String) -> AttributedString {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return source }
        var result = source
        let plain = String(source.characters)
        let lowerPlain = plain.lowercased()
        let lowerQuery = q.lowercased()
        var cursor = lowerPlain.startIndex
        while let range = lowerPlain.range(of: lowerQuery,
                                           range: cursor..<lowerPlain.endIndex) {
            let startOff = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let endOff   = plain.distance(from: plain.startIndex, to: range.upperBound)
            let totalChars = plain.count
            guard endOff <= totalChars else { break }
            let aStart = result.index(result.startIndex,
                                      offsetByCharacters: startOff)
            let aEnd = result.index(result.startIndex,
                                    offsetByCharacters: endOff)
            result[aStart..<aEnd].backgroundColor = Color.yellow.opacity(0.55)
            result[aStart..<aEnd].foregroundColor = Color.black
            cursor = range.upperBound
        }
        return result
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
