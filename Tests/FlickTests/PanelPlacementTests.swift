import XCTest
@testable import FlickApp

/// A 1440x900 display with a 25pt menu bar, in AppKit's bottom-left origin
/// coordinates.
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

final class PanelPlacementTests: XCTestCase {
    private func assertInside(_ frame: CGRect,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX, "off the left edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY, "off the bottom edge", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX, "off the right edge", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY, "under the menu bar", file: file, line: line)
    }

    func testFirstOpenSitsUnderTheMenuBarAtTheRight() {
        let frame = PanelPlacement.anchored(CGRect(x: 0, y: 0, width: 420, height: 300), in: screen)
        assertInside(frame)
        XCTAssertEqual(frame.maxX, screen.maxX - PanelPlacement.inset)
        XCTAssertEqual(frame.maxY, screen.maxY - PanelPlacement.topInset)
    }

    /// The regression: a window keeps its bottom-left corner as it grows, so a
    /// taller inbox pushed its own top off the screen.
    func testGrowingUpwardIsPulledBackDown() {
        let anchored = PanelPlacement.anchored(CGRect(x: 0, y: 0, width: 420, height: 200), in: screen)
        let grown = CGRect(x: anchored.minX, y: anchored.minY, width: 420, height: 600)
        XCTAssertGreaterThan(grown.maxY, screen.maxY, "precondition: it overflows the top")
        assertInside(PanelPlacement.clamped(grown, in: screen))
    }

    func testDraggedOffEachEdgeComesBack() {
        let size = CGSize(width: 420, height: 300)
        for origin in [CGPoint(x: -500, y: 400),      // off the left
                       CGPoint(x: 1400, y: 400),      // off the right
                       CGPoint(x: 400, y: -400),      // below the bottom
                       CGPoint(x: 400, y: 800)] {     // up under the menu bar
            assertInside(PanelPlacement.clamped(CGRect(origin: origin, size: size), in: screen))
        }
    }

    func testFrameFromAnUnpluggedDisplayIsRecovered() {
        let onOtherMonitor = CGRect(x: 3000, y: 1600, width: 420, height: 300)
        assertInside(PanelPlacement.clamped(onOtherMonitor, in: screen))
    }

    func testAlreadyInsideIsLeftAlone() {
        let frame = CGRect(x: 300, y: 300, width: 420, height: 300)
        XCTAssertEqual(PanelPlacement.clamped(frame, in: screen), frame)
    }

    func testPanelTallerThanTheScreenIsCappedAndStaysReachable() {
        let tall = CGRect(x: 100, y: -2000, width: 420, height: 4000)
        let result = PanelPlacement.clamped(tall, in: screen)
        assertInside(result)
        XCTAssertEqual(result.height, screen.height)
    }

    /// The popover is narrower than the panel's minimum and its width belongs
    /// to SwiftUI; clamping must reposition it without resizing it.
    func testClampNeverWidensANarrowWindow() {
        let popover = CGRect(x: 100, y: 800, width: 340, height: 300)
        XCTAssertEqual(PanelPlacement.clamped(popover, in: screen).width, 340)
    }

    func testAnchoredWidensToTheMinimum() {
        let sliver = CGRect(x: 0, y: 0, width: 10, height: 300)
        XCTAssertEqual(PanelPlacement.anchored(sliver, in: screen).width, PanelPlacement.minWidth)
    }

    /// The regression from the user's full-screen space: the auto-hiding menu
    /// bar slid the popover's anchor up, carrying the window's top off-screen.
    func testWindowPushedAboveTheTopComesBackFullyVisible() {
        let offTop = CGRect(x: 990, y: screen.maxY - 250, width: 340, height: 330)
        XCTAssertGreaterThan(offTop.maxY, screen.maxY, "precondition: top is cut off")
        let result = PanelPlacement.clamped(offTop, in: screen)
        XCTAssertEqual(result.maxY, screen.maxY)
        XCTAssertEqual(result.size, offTop.size)
    }

    func testScreenNarrowerThanTheMinimumWidthStillFits() {
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 480)
        assertInside2(PanelPlacement.anchored(CGRect(x: 0, y: 0, width: 420, height: 300), in: tiny), tiny)
    }

    // MARK: - Which display a remembered frame belongs to

    /// Two displays side by side: the built-in at the origin, an external to
    /// its right.
    private let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    /// A closed window reports no screen, so reopening has to recover the
    /// display from the remembered frame — otherwise the panel jumps to
    /// whichever screen the cursor happens to be on.
    func testFrameOnTheExternalDisplayResolvesToIt() {
        let parked = CGRect(x: 2000, y: 400, width: 420, height: 300)
        XCTAssertEqual(PanelPlacement.screenIndex(for: parked, in: [builtIn, external]), 1)
    }

    func testFrameOnTheBuiltInDisplayResolvesToIt() {
        let parked = CGRect(x: 200, y: 400, width: 420, height: 300)
        XCTAssertEqual(PanelPlacement.screenIndex(for: parked, in: [builtIn, external]), 0)
    }

    func testStraddlingFrameResolvesToTheDisplayItOverlapsMost() {
        // 100pt on the built-in, 320pt on the external.
        let straddling = CGRect(x: 1340, y: 400, width: 420, height: 300)
        XCTAssertEqual(PanelPlacement.screenIndex(for: straddling, in: [builtIn, external]), 1)
    }

    func testFrameOnANoLongerConnectedDisplayResolvesToNothing() {
        let orphaned = CGRect(x: 4000, y: 2000, width: 420, height: 300)
        XCTAssertNil(PanelPlacement.screenIndex(for: orphaned, in: [builtIn]))
    }

    private func assertInside2(_ frame: CGRect, _ bounds: CGRect) {
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY)
    }
}
