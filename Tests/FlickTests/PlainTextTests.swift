import XCTest
@testable import InboxCore

/// The regression these guard: agents answer in markdown because their usual
/// home is a terminal that renders it. A notification banner renders none of
/// it, so `**Done!**` used to arrive with its asterisks showing.
final class PlainTextTests: XCTestCase {
    func testInlineMarkersGo() {
        XCTAssertEqual(PlainText.fromMarkdown("**Done!**"), "Done!")
        XCTAssertEqual(PlainText.fromMarkdown("run `swift build` first"), "run swift build first")
        XCTAssertEqual(PlainText.fromMarkdown("~~dropped~~"), "dropped")
        XCTAssertEqual(PlainText.fromMarkdown("*emphasis* here"), "emphasis here")
    }

    /// Stripping underscores would eat the ones in real identifiers, which is
    /// exactly the sort of thing these messages are about.
    func testUnderscoresSurvive() {
        XCTAssertEqual(PlainText.fromMarkdown("edited __init__.py"), "edited __init__.py")
        XCTAssertEqual(PlainText.fromMarkdown("MAX_RETRY_COUNT is 3"), "MAX_RETRY_COUNT is 3")
    }

    func testLinksCollapseToTheirLabel() {
        XCTAssertEqual(PlainText.fromMarkdown("see [the docs](https://example.com)"), "see the docs")
        XCTAssertEqual(PlainText.fromMarkdown("![diagram](a.png)"), "diagram")
        XCTAssertEqual(PlainText.fromMarkdown("<https://example.com>"), "https://example.com")
    }

    func testBlockStructure() {
        XCTAssertEqual(PlainText.fromMarkdown("## Summary\nAll good"), "Summary\nAll good")
        XCTAssertEqual(PlainText.fromMarkdown("> quoted line"), "quoted line")
        XCTAssertEqual(PlainText.fromMarkdown("- one\n- two"), "• one\n• two")
        XCTAssertEqual(PlainText.fromMarkdown("1. first\n2. second"), "1. first\n2. second")
        XCTAssertEqual(PlainText.fromMarkdown("above\n\n---\n\nbelow"), "above\n\nbelow")
    }

    /// The code inside a fence is usually the substance of the message, so the
    /// fence goes and the code stays.
    func testFencesGoAndCodeStays() {
        let input = "Here:\n```swift\nlet x = 1\n```\ndone"
        XCTAssertEqual(PlainText.fromMarkdown(input), "Here:\n\nlet x = 1\n\ndone")
    }

    func testBlankLineRunsCollapse() {
        XCTAssertEqual(PlainText.fromMarkdown("a\n\n\n\n\nb"), "a\n\nb")
    }

    /// A banner treats a newline as the end of the message, so a summary whose
    /// first line is "Done." would otherwise arrive saying nothing useful.
    func testSingleLineFlattensNewlines() {
        XCTAssertEqual(PlainText.singleLine("Done.\n\nRewrote the parser."),
                       "Done. Rewrote the parser.")
        XCTAssertFalse(PlainText.singleLine("- one\n- two").contains("\n"))
    }

    func testTruncationBreaksOnAWord() {
        let text = "the quick brown fox jumps over the lazy dog"
        let cut = PlainText.truncate(text, limit: 20)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 21)
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(PlainText.truncate("short", limit: 40), "short")
        XCTAssertEqual(PlainText.fromMarkdown("plain sentence"), "plain sentence")
    }
}
