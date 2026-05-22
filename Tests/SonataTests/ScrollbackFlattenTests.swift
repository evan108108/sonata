import XCTest
@testable import Sonata

// Tests for InteractiveSessionTab.flattenForReplay — the sanitizer that turns a
// captured terminal byte stream into a flat, colored transcript for scrollback
// replay. Raw replay of an interactive shell's cursor/erase control codes wipes
// history at a different terminal size; this keeps text + newlines + SGR color
// and drops cursor-movement / erase / OSC sequences.
final class ScrollbackFlattenTests: XCTestCase {

    private func flat(_ s: String) -> String {
        String(decoding: InteractiveSessionTab.flattenForReplay(Array(s.utf8)), as: UTF8.self)
    }

    func testPlainTextAndWhitespaceKept() {
        XCTAssertEqual(flat("hello\nworld\n"), "hello\nworld\n")
        XCTAssertEqual(flat("a\tb\r\n"), "a\tb\r\n")
    }

    func testSGRColorKept() {
        let s = "\u{1b}[31mred\u{1b}[0m\u{1b}[1;38;5;208morange\u{1b}[0m"
        XCTAssertEqual(flat(s), s)
    }

    func testCursorMovesStripped() {
        XCTAssertEqual(flat("a\u{1b}[2Ab\u{1b}[1;5Hc"), "abc")
    }

    func testEraseSequencesStripped() {
        XCTAssertEqual(flat("x\u{1b}[Jy\u{1b}[2Kz\u{1b}[3J!"), "xyz!")
    }

    func testOSCTitleStripped() {
        XCTAssertEqual(flat("\u{1b}]0;my title\u{07}prompt"), "prompt")   // BEL-terminated
        XCTAssertEqual(flat("\u{1b}]0;t\u{1b}\\after"), "after")          // ST-terminated
    }

    func testStrayControlCharsDropped() {
        XCTAssertEqual(flat("a\u{7f}b\u{08}c\u{07}"), "abc")
    }

    func testRealisticPromptRedraw() {
        let input = "\u{1b}[32mevan@mac\u{1b}[0m % ls\u{1b}[K\r\nfile1\nfile2\n\u{1b}[Aprompt"
        XCTAssertEqual(flat(input), "\u{1b}[32mevan@mac\u{1b}[0m % ls\r\nfile1\nfile2\nprompt")
    }
}
