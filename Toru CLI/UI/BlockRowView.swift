import SwiftUI
import AppKit

/// One block rendered as a Warp-style card: command header, thin divider,
/// monospaced output, hover-only ellipsis menu, animated bottom strip
/// while running.
struct BlockRowView: View {
    @ObservedObject var block: Block
    let onRerun: (Block) -> Void
    let onDelete: (Block) -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !block.output.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                outputBody
            }
            if block.isRunning {
                runningStrip
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy command") { copy(block.command) }
            Button("Copy output")  { copy(block.output) }
            Button("Copy both")    { copy(combined()) }
            Divider()
            Button("Re-run") { onRerun(block) }
            Divider()
            Button("Delete", role: .destructive) { onDelete(block) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(">")
                .foregroundStyle(Color.teal)
                .font(.system(size: 13, design: .monospaced))
            Text(block.command)
                .font(.system(size: 13, design: .monospaced).weight(.semibold))
                .foregroundStyle(commandColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            statusIndicator
            ellipsisMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(commandFailed ? Color.red.opacity(0.15) : Color.clear)
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if block.isRunning {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        Menu {
            Button("Copy command") { copy(block.command) }
            Button("Copy output")  { copy(block.output) }
            Button("Copy both")    { copy(combined()) }
            Divider()
            Button("Re-run") { onRerun(block) }
            Divider()
            Button("Delete", role: .destructive) { onDelete(block) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
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

    private var outputBody: some View {
        // Replace runs of 2+ spaces (column padding from `ls`, `tree`,
        // `git status`, …) with NBSPs so SwiftUI keeps them at wrap
        // boundaries. Single spaces stay regular so word wrap still
        // works on prose output.
        Text(preserveColumnPadding(block.output))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.85))
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func preserveColumnPadding(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var run = 0
        for c in s {
            if c == " " {
                run += 1
            } else {
                flushSpaces(run, into: &out)
                run = 0
                if c == "\t" {
                    out.append(String(repeating: "\u{00A0}", count: 4))
                } else {
                    out.append(c)
                }
            }
        }
        flushSpaces(run, into: &out)
        return out
    }

    private func flushSpaces(_ run: Int, into out: inout String) {
        if run <= 0 { return }
        if run == 1 {
            out.append(" ")
        } else {
            out.append(String(repeating: "\u{00A0}", count: run))
        }
    }

    // MARK: - Running indicator

    private var runningStrip: some View {
        Rectangle()
            .fill(Color.teal.opacity(pulse ? 0.4 : 0.15))
            .frame(height: 2)
            .padding(.top, 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    // MARK: - Helpers

    private var commandFailed: Bool {
        if let code = block.exitCode { return code != 0 }
        return false
    }

    private var commandColor: Color {
        commandFailed ? Color.red.opacity(0.9) : Color(nsColor: .labelColor)
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func combined() -> String {
        "> \(block.command)\n\(block.output)"
    }
}
