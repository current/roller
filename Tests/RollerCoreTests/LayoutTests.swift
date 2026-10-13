import XCTest
@testable import RollerCore

final class LayoutTests: XCTestCase {
    // A 1000 x 800 working area at (10, 40) with 10-point gaps.
    let area = CGRect(x: 10, y: 40, width: 1000, height: 800)

    func params(_ mode: CenterMode = .never) -> LayoutParams {
        LayoutParams(area: area, gap: 10, tabBarHeight: 26, centerMode: mode)
    }

    func strip(_ widths: [Double]) -> Strip {
        var s = Strip()
        for (i, w) in widths.enumerated() { s.insert(WindowID(i + 1), width: w, at: s.columns.count) }
        s.focus = 0
        return s
    }

    func testTwoHalvesFillTheArea() {
        let s = strip([0.5, 0.5])
        let f = Layout.frames(s, params())
        XCTAssertEqual(f[1], CGRect(x: 10, y: 40, width: 495, height: 800))
        XCTAssertEqual(f[2], CGRect(x: 515, y: 40, width: 495, height: 800))
        XCTAssertEqual(f[2]!.maxX, area.maxX)
    }

    func testFullWidthEqualsArea() {
        let s = strip([1])
        XCTAssertEqual(Layout.frames(s, params())[1], area)
    }

    func testFractionRoundTrip() {
        let p = params()
        for w in [0.25, 0.33, 0.5, 0.66, 0.75, 1.0] {
            let c = Column(windows: [1], width: w)
            XCTAssertEqual(Layout.fraction(forWidth: Layout.columnWidth(c, p), p), w, accuracy: 0.002)
        }
    }

    func testMinimumWidthIsRespected() {
        var p = params()
        p.minWidths = [1: 700]
        let s = strip([0.5, 0.5])
        let f = Layout.frames(s, p)
        XCTAssertEqual(f[1]!.width, 700)
        XCTAssertEqual(f[2]!.minX, 10 + 700 + 10)
    }

    func testStackedHeightsTileWithGaps() {
        var s = strip([0.5, 0.5])
        s.focus = 1
        s.stack(into: -1)
        let f = Layout.frames(s, params())
        XCTAssertEqual(f[1]!.minY, 40)
        XCTAssertEqual(f[2]!.minY, f[1]!.maxY + 10)
        XCTAssertEqual(f[2]!.maxY, area.maxY)
        XCTAssertEqual(f[1]!.height + f[2]!.height + 10, 800)
    }

    func testTabbedColumnLeavesRoomForTabBar() {
        var s = strip([0.5, 0.5])
        s.focus = 1
        s.stack(into: -1)
        s.toggleTabbed()
        let f = Layout.frames(s, params())
        XCTAssertEqual(f[1], f[2])
        XCTAssertEqual(f[1]!.minY, 40 + 26)
        XCTAssertEqual(f[1]!.maxY, area.maxY)
        let bar = Layout.tabBarFrame(s, column: 0, params())!
        XCTAssertEqual(bar.minY, 40)
        XCTAssertLessThan(bar.maxY, f[1]!.minY)
    }

    func testNeverModeScrollsMinimally() {
        var s = strip([0.5, 0.5, 0.5, 0.5])
        let p = params(.never)
        s.focusColumn(by: 1)
        Layout.revealFocus(&s, p)
        XCTAssertEqual(s.offset, 0, "second half column is already visible")
        s.focusColumn(by: 1)
        Layout.revealFocus(&s, p)
        // Third column right edge aligns with the area's right edge.
        let f = Layout.frames(s, p)
        XCTAssertEqual(f[3]!.maxX, area.maxX)
        s.focusFirst()
        Layout.revealFocus(&s, p)
        XCTAssertEqual(Layout.frames(s, p)[1]!.minX, area.minX)
    }

    func testAlwaysModeCenters() {
        var s = strip([0.33, 0.33, 0.33])
        let p = params(.always)
        s.focusColumn(by: 1)
        Layout.revealFocus(&s, p)
        let f = Layout.frames(s, p)[2]!
        XCTAssertEqual(f.midX, area.midX, accuracy: 1)
    }

    func testOnOverflowCentersOnlyWhenPairDoesNotFit() {
        let p = params(.onOverflow)
        // Two narrow columns fit together: minimal scroll.
        var s = strip([0.33, 0.33, 0.33, 0.33])
        s.focusPlace(4)
        s.previousFocus = 2
        Layout.revealFocus(&s, p)
        XCTAssertEqual(Layout.frames(s, p)[4]!.maxX, area.maxX)

        // Two wide columns don't fit together: center.
        var w = strip([0.75, 0.75, 0.75])
        w.focusColumn(by: 1)
        Layout.revealFocus(&w, p)
        XCTAssertEqual(Layout.frames(w, p)[2]!.midX, area.midX, accuracy: 1)
    }

    func testCenterFocusAction() {
        var s = strip([0.5, 0.5, 0.5])
        let p = params(.never)
        s.focusColumn(by: 1)
        Layout.centerFocus(&s, p)
        XCTAssertEqual(Layout.frames(s, p)[2]!.midX, area.midX, accuracy: 1)
    }

    func testSettleRemovesEmptySpaceInNeverMode() {
        var s = strip([0.5, 0.5, 0.5])
        let p = params(.never)
        s.focusLast()
        Layout.revealFocus(&s, p)
        XCTAssertGreaterThan(s.offset, 0)
        s.remove(3)
        Layout.settle(&s, p)
        XCTAssertEqual(s.offset, 0)
    }

    func testSnapPicksNearestColumnEdge() {
        var s = strip([0.5, 0.5, 0.5, 0.5])
        let p = params(.never)
        // Column 3 starts at 1010 in strip space.
        let snap = Layout.snap(s, p, projectedOffset: 990)!
        XCTAssertEqual(snap.offset, 1010)
        // Swiping toward the end focuses the newly revealed column.
        XCTAssertEqual(snap.column, 3)
        s.offset = snap.offset
        let back = Layout.snap(s, p, projectedOffset: 520)!
        XCTAssertEqual(back.offset, 505)
        XCTAssertEqual(back.column, 1)
        // Beyond the end clamps to the last full view.
        let end = Layout.snap(s, p, projectedOffset: 99_999)!
        XCTAssertEqual(end.offset, Layout.totalWidth(s, p) - 1000)
        XCTAssertEqual(end.column, 3)
        let start = Layout.snap(s, p, projectedOffset: -500)!
        XCTAssertEqual(start.offset, 0)
        XCTAssertEqual(start.column, 0)
    }

    func testColumnIndexAtScreenX() {
        let s = strip([0.5, 0.5, 0.5])
        let p = params()
        XCTAssertEqual(Layout.columnIndex(atScreenX: 20, s, p), 0)
        XCTAssertEqual(Layout.columnIndex(atScreenX: 600, s, p), 1)
        XCTAssertEqual(Layout.columnIndex(atScreenX: 5000, s, p), 2)
    }

    // MARK: Placement

    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testVisibleWindowIsPlacedAsIs() {
        let v = CGRect(x: 1200, y: 30, width: 600, height: 800)
        XCTAssertEqual(Placer.place(v, display: display, neighbors: []), Placement(frame: v, hidden: false))
    }

    func testHiddenWindowsParkInBottomCorners() {
        let right = Placer.place(CGRect(x: 2000, y: 30, width: 600, height: 800), display: display, neighbors: [])
        XCTAssertTrue(right.hidden)
        XCTAssertEqual(right.frame.origin, CGPoint(x: 1439, y: 899))
        let left = Placer.place(CGRect(x: -900, y: 30, width: 600, height: 800), display: display, neighbors: [])
        XCTAssertTrue(left.hidden)
        XCTAssertEqual(left.frame.origin, CGPoint(x: -599, y: 899))
    }

    func testNeighbourDisplayLimitsOverhangToHalf() {
        // Less than half over the right edge: still visible.
        let a = Placer.place(CGRect(x: 1200, y: 30, width: 400, height: 800), display: display, neighbors: [.right])
        XCTAssertFalse(a.hidden)
        // More than half over: hidden, parked on the free (left) side.
        let b = Placer.place(CGRect(x: 1300, y: 30, width: 400, height: 800), display: display, neighbors: [.right])
        XCTAssertTrue(b.hidden)
        XCTAssertEqual(b.frame.minX, -399)
    }

    func testDisplayNeighbors() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let below = CGRect(x: 200, y: 900, width: 1920, height: 1080)
        XCTAssertEqual(DisplayNeighbors.of(main, among: [main, right, below]), [.right, .below])
        XCTAssertEqual(DisplayNeighbors.of(right, among: [main, right]), [.left])
        XCTAssertEqual(DisplayNeighbors.of(below, among: [main, below]), [.above])
    }

    // MARK: Spring

    func testSpringReachesTarget() {
        let critical = Spring(duration: 0.5, damping: 1)
        XCTAssertEqual(critical.value(at: 0), 0)
        XCTAssertEqual(critical.value(at: 0.5), 0.99, accuracy: 0.005)
        XCTAssertTrue(critical.isSettled(at: 2))
        XCTAssertFalse(critical.isSettled(at: 0.1))
        // Critically damped never overshoots.
        for i in 0...200 { XCTAssertLessThanOrEqual(critical.value(at: Double(i) / 100), 1.0000001) }

        let bouncy = Spring(duration: 0.5, damping: 0.5)
        let peak = (0...200).map { bouncy.value(at: Double($0) / 100) }.max()!
        XCTAssertGreaterThan(peak, 1)
        XCTAssertEqual(Spring(duration: 0, damping: 1).value(at: 0), 1)
    }
}
