import XCTest
import SwiftUI
@testable import Toru_CLI

/// Tests the GridEmulator screen state via `render()`'s plain-text
/// projection. Style attributes are an implementation detail and not
/// asserted here.
final class GridEmulatorTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    private func render(_ feedString: String) -> String {
        let g = GridEmulator()
        g.feed(bytes(feedString))
        return plain(g.render())
    }

    // MARK: - Plain text

    func testPlainLinesRender() {
        // GridEmulator follows VT100: LF advances row but does NOT reset
        // the column. Real PTY output uses CRLF (ONLCR), so we mirror
        // that here. Without CR, "b" lands at col 1, "c" at col 2.
        XCTAssertEqual(render("a\r\nb\r\nc"), "a\nb\nc")
    }

    func testCarriageReturnOverwritesFromColumnZero() {
        XCTAssertEqual(render("hello\rWORLD"), "WORLD")
    }

    func testTabExpandsToEightColStop() {
        let out = render("ab\tc")
        XCTAssertEqual(out, "ab      c")
    }

    // MARK: - Cursor movement

    func testCUUMovesCursorUp() {
        // Write line 1, CRLF, line 2, CUU 1, CR, overwrite first cell.
        let out = render("line1\r\nline2\u{1B}[1A\rX")
        XCTAssertEqual(out, "Xine1\nline2")
    }

    func testCUDMovesCursorDownExtendingGrid() {
        let out = render("X\u{1B}[2BY")
        // 'X' at (0,0). CUD 2 → row 2. 'Y' at (2,1).
        // Rendered: "X\n\n Y"
        XCTAssertEqual(out, "X\n\n Y")
    }

    func testCUFAdvancesCursorRight() {
        let out = render("A\u{1B}[3CB")
        // 'A' at (0,0). CUF 3 → col 4. 'B' at (0,4).
        XCTAssertEqual(out, "A   B")
    }

    func testCUBMovesCursorLeftThenOverwrites() {
        let out = render("ABC\u{1B}[2DX")
        // After 'ABC' cursor at col 3. CUB 2 → col 1. 'X' overwrites at col 1.
        XCTAssertEqual(out, "AXC")
    }

    func testCHASetsAbsoluteColumn() {
        let out = render("ABCDE\u{1B}[3GZ")
        // CHA 3 → col 2 (1-based). Overwrite 'C' with 'Z'.
        XCTAssertEqual(out, "ABZDE")
    }

    func testCUPSetsRowAndColumn() {
        let out = render("first\r\nsecond\u{1B}[1;1HX")
        // CUP 1;1 → row 0 col 0. Overwrite 'f' with 'X'.
        XCTAssertEqual(out, "Xirst\nsecond")
    }

    // MARK: - Erase

    func testELToEndOfLine() {
        let out = render("hello\u{1B}[3G\u{1B}[0K")
        // Move to col 3 (zero-based 2), erase to EOL → "he"
        XCTAssertEqual(out, "he")
    }

    func testELEntireLine() {
        let out = render("hello\u{1B}[2K")
        XCTAssertEqual(out, "")
    }

    func testEDFromCursorClearsBelow() {
        let out = render("a\nb\nc\u{1B}[1;1H\u{1B}[0J")
        XCTAssertEqual(out, "")
    }

    func testEDAllClearsGrid() {
        let out = render("anything\u{1B}[2J")
        XCTAssertEqual(out, "")
    }

    // MARK: - SGR is consumed (not emitted as text)

    func testSGRDoesNotAppearInPlainText() {
        let out = render("\u{1B}[31mred\u{1B}[0m plain")
        XCTAssertEqual(out, "red plain")
    }

    func testSGR256AndTruecolorConsumed() {
        let out = render(
            "\u{1B}[38;5;196mA\u{1B}[38;2;10;20;30mB\u{1B}[0mC"
        )
        XCTAssertEqual(out, "ABC")
    }

    // MARK: - UTF-8 multi-byte

    func testUTF8MultibyteRendersAsOneCell() {
        // 'é' = 0xC3 0xA9. Should appear as one character in output.
        let out = render("café")
        XCTAssertEqual(out, "café")
    }

    // MARK: - Reset

    func testResetClearsState() {
        let g = GridEmulator()
        g.feed(bytes("garbage"))
        g.reset()
        g.feed(bytes("fresh"))
        XCTAssertEqual(plain(g.render()), "fresh")
    }

    // MARK: - Private-mode CSI ignored

    func testPrivateModeCSIIsSkipped() {
        // ?1049h with 'h' final — must not write or move cursor.
        let out = render("X\u{1B}[?1049hY")
        XCTAssertEqual(out, "XY")
    }
}
