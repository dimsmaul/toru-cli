import Foundation

/// Removes ANSI escape sequences and prompt-chrome remnants so the result
/// is safe to render in a SwiftUI `Text`.
///
/// Two passes:
///   1. Byte-level escape strip (CSI / OSC / 2-byte ESC + BEL/BS/CR).
///   2. Line-level filter dropping zsh prompt artifacts that survive
///      `stty -echo` + `PROMPT=''` (e.g. the standalone `%` zsh prints
///      to indicate "previous output had no trailing newline").
enum AnsiStripper {
    static func strip(_ input: String) -> String {
        let cleaned = stripEscapes(input)
        return filterPromptChrome(cleaned)
    }

    // MARK: - Pass 1: byte-level escape strip

    private static func stripEscapes(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            switch c {
            case "\u{1B}":
                i = skipEscape(in: input, from: input.index(after: i))
            case "\u{07}", "\u{08}", "\u{0D}":
                i = input.index(after: i)
            default:
                out.append(c)
                i = input.index(after: i)
            }
        }
        return out
    }

    /// `i` points to the byte immediately after `\e`. Returns the index
    /// just after the consumed escape sequence.
    private static func skipEscape(in s: String, from i: String.Index) -> String.Index {
        guard i < s.endIndex else { return i }
        switch s[i] {
        case "[":
            // CSI: terminator byte is 0x40-0x7E.
            var j = s.index(after: i)
            while j < s.endIndex {
                let scalar = s[j].unicodeScalars.first?.value ?? 0
                if scalar >= 0x40 && scalar <= 0x7E { return s.index(after: j) }
                j = s.index(after: j)
            }
            return j
        case "]":
            // OSC: terminated by BEL (0x07) or ST (ESC \).
            var j = s.index(after: i)
            while j < s.endIndex {
                if s[j] == "\u{07}" { return s.index(after: j) }
                if s[j] == "\u{1B}" {
                    let k = s.index(after: j)
                    if k < s.endIndex, s[k] == "\\" { return s.index(after: k) }
                }
                j = s.index(after: j)
            }
            return j
        default:
            return s.index(after: i)
        }
    }

    // MARK: - Pass 2: prompt-chrome line filter

    private static func filterPromptChrome(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        let kept = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // Drop bare prompt remnants.
            if t == ">" || t == "%" || t == "$" || t == "#" { return false }
            if t == "> " || t == "% " || t == "$ " || t == "# " { return false }
            // Drop the cosmetic SwiftTerm/zsh job-control warning that
            // appears once at shell startup.
            if t == "zsh: can't set tty pgrp: operation not permitted" { return false }
            return true
        }
        return kept.joined(separator: "\n")
    }
}
