import XCTest
@testable import RollerCore

final class StripTests: XCTestCase {
    func makeStrip(_ n: Int, width: Double = 0.5) -> Strip {
        var s = Strip()
        for i in 1...n { s.insert(WindowID(i), width: width) }
        return s
    }

    func testInsertGoesRightOfFocusAndTakesFocus() {
        var s = makeStrip(3)
        XCTAssertEqual(s.allWindows, [1, 2, 3])
        XCTAssertEqual(s.focusedWindow, 3)
        s.focusFirst()
        s.insert(9, width: 0.5)
        XCTAssertEqual(s.allWindows, [1, 9, 2, 3])
        XCTAssertEqual(s.focusedWindow, 9)
    }

    func testInsertWithoutFocusKeepsFocusedWindow() {
        var s = makeStrip(3)
        s.focusPlace(2)
        s.insert(9, width: 0.5, at: 0, focus: false)
        XCTAssertEqual(s.allWindows, [9, 1, 2, 3])
        XCTAssertEqual(s.focusedWindow, 2)
    }

    func testRemoveFocusesLeftNeighbour() {
        var s = makeStrip(4)
        s.focusPlace(3)
        s.remove(3)
        XCTAssertEqual(s.allWindows, [1, 2, 4])
        XCTAssertEqual(s.focusedWindow, 2)
        s.focusFirst()
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 2)
        s.remove(4)
        s.remove(2)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.focusedWindow)
    }

    func testRemoveLeftOfFocusKeepsFocusedWindow() {
        var s = makeStrip(4)
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 4)
    }

    func testFocusMovement() {
        var s = makeStrip(3)
        XCTAssertFalse(s.focusColumn(by: 1))
        XCTAssertTrue(s.focusColumn(by: -1))
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.focusFirst())
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertTrue(s.focusLast())
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertTrue(s.focusPlace(1))
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertTrue(s.focusPlace(nil))
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertFalse(s.focusPlace(8))
    }

    func testMoveColumns() {
        var s = makeStrip(4)
        s.moveColumn(by: -1)
        XCTAssertEqual(s.allWindows, [1, 2, 4, 3])
        XCTAssertEqual(s.focusedWindow, 4)
        s.moveToFirst()
        XCTAssertEqual(s.allWindows, [4, 1, 2, 3])
        s.moveToLast()
        XCTAssertEqual(s.allWindows, [1, 2, 3, 4])
        s.moveToPlace(2)
        XCTAssertEqual(s.allWindows, [1, 4, 2, 3])
        XCTAssertEqual(s.focus, 1)
    }

    func testStackAndPopOut() {
        var s = makeStrip(3)
        // Focus is on 3; stack it into the left column (2).
        XCTAssertTrue(s.stack(into: -1))
        XCTAssertEqual(s.columns.count, 2)
        XCTAssertEqual(s.columns[1].windows, [2, 3])
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertEqual(s.columns[1].heights.count, 2)

        // Reorder inside the stack.
        XCTAssertTrue(s.moveRow(by: -1))
        XCTAssertEqual(s.columns[1].windows, [3, 2])
        XCTAssertTrue(s.focusRow(by: 1))
        XCTAssertEqual(s.focusedWindow, 2)

        // Pop out to the right.
        XCTAssertTrue(s.popOut(1))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
        XCTAssertEqual(s.focusedWindow, 2)

        // Stack into the right column from the first column.
        s.focusFirst()
        XCTAssertTrue(s.stack(into: 1))
        XCTAssertEqual(s.columns.map(\.windows), [[3, 1], [2]])
        XCTAssertEqual(s.focus, 0)
        XCTAssertEqual(s.focusedWindow, 1)

        // Pop out to the left.
        XCTAssertTrue(s.popOut(-1))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertFalse(s.popOut(1), "a lone window can't pop out")
    }

    func testRemovingFromStackKeepsColumn() {
        var s = makeStrip(2)
        s.stack(into: -1)
        s.remove(2)
        XCTAssertEqual(s.columns.map(\.windows), [[1]])
        XCTAssertEqual(s.columns[0].heights, [1])
        XCTAssertEqual(s.focusedWindow, 1)
    }

    func testWidths() {
        var s = makeStrip(1, width: 0.5)
        let presets = [0.25, 0.33, 0.5, 0.66, 0.75]
        s.cycleWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 0.66)
        s.cycleWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 0.75)
        s.cycleWidth(presets: presets)
        XCTAssertEqual(s.columns[0].width, 0.25)

        s.toggleFullWidth()
        XCTAssertEqual(s.columns[0].width, 1)
        s.toggleFullWidth()
        XCTAssertEqual(s.columns[0].width, 0.25)

        s.resizeWidth(by: 0.1)
        XCTAssertEqual(s.columns[0].width, 0.35, accuracy: 1e-9)
        s.resizeWidth(by: 5)
        XCTAssertEqual(s.columns[0].width, 1)
        s.resizeWidth(by: -5)
        XCTAssertEqual(s.columns[0].width, Column.minWidth)
    }

    func testHeights() {
        var s = makeStrip(3)
        s.stack(into: -1)  // [[1], [2, 3]]
        s.focusRow(by: -1) // focus 2
        s.stack(into: -1)  // [[1, 2], [3]]
        s.focusColumn(by: 1)
        s.stack(into: -1)  // [[1, 2, 3]]
        XCTAssertEqual(s.columns.count, 1)
        XCTAssertEqual(s.columns[0].windows, [1, 2, 3])
        XCTAssertTrue(s.resizeHeight(by: 0.1))
        let f = s.columns[0].heightFractions
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(f[2], 1.0 / 3 + 0.1, accuracy: 1e-9)
        XCTAssertTrue(s.equalizeHeights())
        XCTAssertEqual(s.columns[0].heightFractions[0], 1.0 / 3, accuracy: 1e-9)
        XCTAssertFalse(s.equalizeHeights())
        for _ in 0..<20 { s.resizeHeight(by: 0.1) }
        XCTAssertEqual(s.columns[0].heightFractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(s.columns[0].heightFractions.min()!, 0.0999)
    }

    func testMoveWindowFromStackForDragReorder() {
        var s = makeStrip(3)
        s.stack(into: -1) // [[1], [2, 3]]
        XCTAssertTrue(s.moveWindow(3, toColumnIndex: 0))
        XCTAssertEqual(s.columns.map(\.windows), [[3], [1], [2]])
        XCTAssertTrue(s.moveWindow(3, toColumnIndex: 2))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
    }

    func testCodableRoundTrip() throws {
        var s = makeStrip(3)
        s.stack(into: -1)
        s.toggleTabbed()
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Strip.self, from: data), s)
    }

    func testSessionRestoreMatchesByIDThenTitle() {
        let saved = SavedStrip(key: "d|1", columns: [
            SavedColumn(windows: [SavedWindow(id: 10, bundleID: "a", title: "One")], heights: [1], width: 0.5, tabbed: false),
            SavedColumn(windows: [SavedWindow(id: 11, bundleID: "b", title: "Two"), SavedWindow(id: 12, bundleID: "c", title: "Gone")],
                        heights: [2, 1], width: 0.66, tabbed: true),
        ], focus: 1)
        // Window 11 restarted with a new number (21); 12 no longer exists.
        let live: [WindowID: (String, String)] = [10: ("a", "One"), 21: ("b", "Two")]
        let s = SavedSession.restore(saved) { sw in
            if live[sw.id] != nil { return sw.id }
            return live.first { $0.value == (sw.bundleID ?? "", sw.title) }?.key
        }
        XCTAssertEqual(s.columns.map(\.windows), [[10], [21]])
        XCTAssertEqual(s.columns[1].width, 0.66)
        XCTAssertTrue(s.columns[1].tabbed)
        XCTAssertEqual(s.columns[1].heights, [2])
        XCTAssertEqual(s.focus, 1)
    }
}
