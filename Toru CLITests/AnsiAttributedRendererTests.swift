import XCTest
import SwiftUI
@testable import Toru_CLI

/// Black-box tests for `AnsiAttributedRenderer.feed`. We assert on the
/// plain-text projection of the output (`String(result.characters)`) plus
/// the latched cursor-move / alt-screen flags, since per-run color
/// attributes are an implementation detail that's tedious to compare
/// across Swift releases.
final class AnsiAttributedRendererTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    // MARK: - Plain text

    func testPlainAsciiPassesThrough() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("hello world\n"))
        XCTAssertEqual(plain(out), "hello world\n")
    }

    func testCRLFCollapsedToSingleNewline() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("a\r\nb\r\n"))
        XCTAssertEqual(plain(out), "a\nb\n")
    }

    func testLoneCREmitsNewline() {
        // Progress-bar style — flat AttributedString can't reposition the
        // cursor, so lone CR is emitted as LF to keep frames separated.
        // A trailing CR is held until the next byte forces flush; we add
        // a final byte to drain pendingCR within a single feed.
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("10%\r20%\rX"))
        XCTAssertEqual(plain(out), "10%\n20%\nX")
    }

    func testTabExpandsToNextEightColStop() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("ab\tc"))
        XCTAssertEqual(plain(out), "ab      c")
    }

    func testBackspaceAndBellAreDropped() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("ab\u{07}\u{08}c"))
        XCTAssertEqual(plain(out), "abc")
    }

    // MARK: - SGR

    func testSGRSequencesAreStrippedFromText() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("\u{1B}[31mred\u{1B}[0m plain"))
        XCTAssertEqual(plain(out), "red plain")
    }

    func testSGR256AndTruecolorParseWithoutLeakingParams() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes(
            "\u{1B}[38;5;196mA\u{1B}[38;2;10;20;30mB\u{1B}[0mC"
        ))
        XCTAssertEqual(plain(out), "ABC")
    }

    // MARK: - Cursor-move latch

    func testCursorMoveFlagLatchesOnNonSGRCSI() {
        let r = AnsiAttributedRenderer()
        XCTAssertFalse(r.consumeCursorMoveFlag())
        _ = r.feed(bytes("\u{1B}[2A"))  // CUU
        XCTAssertTrue(r.consumeCursorMoveFlag())
        XCTAssertFalse(r.consumeCursorMoveFlag(),
                       "consume should clear the flag")
    }

    func testCursorMoveFlagNotSetByPureSGR() {
        let r = AnsiAttributedRenderer()
        _ = r.feed(bytes("\u{1B}[31mhi\u{1B}[0m"))
        XCTAssertFalse(r.consumeCursorMoveFlag())
    }

    // MARK: - Alt-screen latch

    func testAltScreenLatchOn1049() {
        let r = AnsiAttributedRenderer()
        _ = r.feed(bytes("\u{1B}[?1049h"))
        XCTAssertTrue(r.consumeAltScreenFlag())
        XCTAssertFalse(r.consumeAltScreenFlag())
    }

    func testAltScreenLatchOn47AndDoesNotMarkCursorMove() {
        let r = AnsiAttributedRenderer()
        _ = r.feed(bytes("\u{1B}[?47h"))
        XCTAssertTrue(r.consumeAltScreenFlag())
        XCTAssertFalse(r.consumeCursorMoveFlag(),
                       "private-mode set should latch altScreen, not cursorMove")
    }

    // MARK: - OSC

    func testOSCIsStripped() {
        let r = AnsiAttributedRenderer()
        let out = r.feed(bytes("\u{1B}]0;window title\u{07}body"))
        XCTAssertEqual(plain(out), "body")
    }

    // MARK: - Chunk boundaries

    func testEscapeSplitAcrossFeedCallsParsesCorrectly() {
        let r = AnsiAttributedRenderer()
        let first  = r.feed(bytes("hi\u{1B}["))
        let second = r.feed(bytes("31mred"))
        XCTAssertEqual(plain(first), "hi")
        XCTAssertEqual(plain(second), "red")
    }
}
