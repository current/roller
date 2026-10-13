import Foundation

/// A window server window number (`CGWindowID`).
public typealias WindowID = UInt32

/// One column on the strip. A column holds one window, or several stacked
/// vertically (a *stack*), optionally shown as tabs.
public struct Column: Codable, Equatable {
    /// Windows from top to bottom.
    public var windows: [WindowID]
    /// Relative height weights, one per window.
    public var heights: [Double]
    /// Width as a fraction of the working area (0.05 ... 1.0).
    public var width: Double
    /// Show the stack as tabs: every window gets the full column height.
    public var tabbed: Bool
    /// Index of the active window (focused row, or visible tab).
    public var active: Int
    /// Width to return to when full width is toggled off.
    public var savedWidth: Double?

    public init(windows: [WindowID], width: Double, tabbed: Bool = false) {
        self.windows = windows
        self.heights = Array(repeating: 1, count: windows.count)
        self.width = Column.clampWidth(width)
        self.tabbed = tabbed
        self.active = 0
        self.savedWidth = nil
    }

    public var activeWindow: WindowID? {
        windows.indices.contains(active) ? windows[active] : windows.first
    }

    public static let minWidth = 0.05
    public static func clampWidth(_ w: Double) -> Double {
        guard w.isFinite else { return 0.5 }
        return min(1, max(minWidth, w))
    }

    /// Height fractions that sum to 1.
    public var heightFractions: [Double] {
        let sum = heights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / Double(max(heights.count, 1)), count: heights.count) }
        return heights.map { $0 / sum }
    }

    mutating func normalize() {
        if heights.count != windows.count {
            heights = Array(repeating: 1, count: windows.count)
        }
        if windows.isEmpty { active = 0 } else { active = min(max(active, 0), windows.count - 1) }
    }
}

/// The endless horizontal strip of one display (and one macOS Space).
public struct Strip: Codable, Equatable {
    public var columns: [Column]
    /// Index of the focused column.
    public var focus: Int
    /// Horizontal scroll position: strip x coordinate shown at the left edge
    /// of the working area, in points.
    public var offset: Double
    /// The previously focused column, used by the on-overflow centering mode.
    public var previousFocus: Int?

    public init(columns: [Column] = [], focus: Int = 0, offset: Double = 0) {
        self.columns = columns
        self.focus = focus
        self.offset = offset
        self.previousFocus = nil
    }

    public var isEmpty: Bool { columns.isEmpty }
    public var allWindows: [WindowID] { columns.flatMap(\.windows) }

    public var focusedColumn: Column? {
        columns.indices.contains(focus) ? columns[focus] : nil
    }

    public var focusedWindow: WindowID? { focusedColumn?.activeWindow }

    public func contains(_ w: WindowID) -> Bool { locate(w) != nil }

    /// Column and row of a window.
    public func locate(_ w: WindowID) -> (column: Int, row: Int)? {
        for (ci, c) in columns.enumerated() {
            if let ri = c.windows.firstIndex(of: w) { return (ci, ri) }
        }
        return nil
    }

    // MARK: - Focus

    mutating func setFocus(_ i: Int) {
        guard !columns.isEmpty else { focus = 0; return }
        let n = min(max(i, 0), columns.count - 1)
        if n != focus { previousFocus = focus }
        focus = n
    }

    /// Focuses a specific window. Returns false when it isn't on this strip.
    @discardableResult
    public mutating func focus(window w: WindowID) -> Bool {
        guard let (c, r) = locate(w) else { return false }
        setFocus(c)
        columns[c].active = r
        return true
    }

    /// Moves focus left (-1) or right (+1).
    @discardableResult
    public mutating func focusColumn(by delta: Int) -> Bool {
        guard !columns.isEmpty else { return false }
        let target = focus + delta
        guard columns.indices.contains(target) else { return false }
        setFocus(target)
        return true
    }

    /// Moves focus up (-1) or down (+1) inside a stack, or between tabs.
    @discardableResult
    public mutating func focusRow(by delta: Int) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let target = columns[focus].active + delta
        guard columns[focus].windows.indices.contains(target) else { return false }
        columns[focus].active = target
        return true
    }

    @discardableResult
    public mutating func focusFirst() -> Bool {
        guard !columns.isEmpty, focus != 0 else { return false }
        setFocus(0)
        return true
    }

    @discardableResult
    public mutating func focusLast() -> Bool {
        guard !columns.isEmpty, focus != columns.count - 1 else { return false }
        setFocus(columns.count - 1)
        return true
    }

    /// Focuses place `n` (1-based) like browser tabs. `nil` means the last column.
    @discardableResult
    public mutating func focusPlace(_ n: Int?) -> Bool {
        guard !columns.isEmpty else { return false }
        let target = n.map { $0 - 1 } ?? columns.count - 1
        guard columns.indices.contains(target), target != focus else { return false }
        setFocus(target)
        return true
    }

    // MARK: - Inserting and removing

    /// Adds a window as a new column. By default it goes right after the
    /// focused column. Returns the new column's index.
    @discardableResult
    public mutating func insert(_ w: WindowID, width: Double, at index: Int? = nil, focus takeFocus: Bool = true) -> Int {
        let column = Column(windows: [w], width: width)
        let idx: Int
        if let index { idx = min(max(index, 0), columns.count) } else { idx = columns.isEmpty ? 0 : focus + 1 }
        columns.insert(column, at: idx)
        if columns.count == 1 {
            focus = 0
        } else if takeFocus {
            if idx <= focus { focus += 1 } // keep previousFocus pointing at the same column
            setFocus(idx)
        } else if idx <= focus {
            focus += 1
            if let p = previousFocus, p >= idx { previousFocus = p + 1 }
        }
        return idx
    }

    /// Removes a window. Returns true when it was on the strip.
    @discardableResult
    public mutating func remove(_ w: WindowID) -> Bool {
        guard let (c, r) = locate(w) else { return false }
        columns[c].windows.remove(at: r)
        columns[c].heights.remove(at: r)
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            previousFocus = nil
            if columns.isEmpty {
                focus = 0
            } else if c < focus {
                focus -= 1
            } else if c == focus {
                // Focus the column we most likely came from: the one to the left.
                focus = max(0, min(c - 1, columns.count - 1))
            }
        } else {
            if columns[c].active > r || columns[c].active >= columns[c].windows.count {
                columns[c].active = max(0, columns[c].active - 1)
            }
            columns[c].normalize()
        }
        return true
    }

    // MARK: - Moving

    /// Swaps the focused column with its neighbour (-1 left, +1 right).
    @discardableResult
    public mutating func moveColumn(by delta: Int) -> Bool {
        let target = focus + delta
        guard columns.indices.contains(focus), columns.indices.contains(target) else { return false }
        columns.swapAt(focus, target)
        focus = target
        previousFocus = nil
        return true
    }

    /// Moves the focused column to index `target` (0-based).
    @discardableResult
    public mutating func moveColumn(to target: Int) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let t = min(max(target, 0), columns.count - 1)
        guard t != focus else { return false }
        let c = columns.remove(at: focus)
        columns.insert(c, at: t)
        focus = t
        previousFocus = nil
        return true
    }

    @discardableResult
    public mutating func moveToFirst() -> Bool { moveColumn(to: 0) }
    @discardableResult
    public mutating func moveToLast() -> Bool { moveColumn(to: columns.count - 1) }

    /// Moves the focused column to place `n` (1-based); `nil` means last.
    @discardableResult
    public mutating func moveToPlace(_ n: Int?) -> Bool {
        guard !columns.isEmpty else { return false }
        return moveColumn(to: n.map { $0 - 1 } ?? columns.count - 1)
    }

    /// Reorders the focused window inside its stack (-1 up, +1 down).
    @discardableResult
    public mutating func moveRow(by delta: Int) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        var c = columns[focus]
        let r = c.active, t = r + delta
        guard c.windows.indices.contains(t) else { return false }
        c.windows.swapAt(r, t)
        c.heights.swapAt(r, t)
        c.active = t
        columns[focus] = c
        return true
    }

    /// Moves a column (by the window it contains) to a strip index; used by
    /// drag to reorder. A window that sits in a stack is popped out first.
    @discardableResult
    public mutating func moveWindow(_ w: WindowID, toColumnIndex target: Int) -> Bool {
        guard let (c, r) = locate(w) else { return false }
        if columns[c].windows.count > 1 {
            let width = columns[c].width
            columns[c].windows.remove(at: r)
            columns[c].heights.remove(at: r)
            columns[c].active = min(columns[c].active, columns[c].windows.count - 1)
            let t = min(max(target, 0), columns.count)
            columns.insert(Column(windows: [w], width: width), at: t)
            focus = t
            previousFocus = nil
            return true
        }
        focus = c
        return moveColumn(to: target)
    }

    // MARK: - Stacks

    /// Moves the focused window into the column on its left (-1) or right (+1),
    /// at the bottom of that stack.
    @discardableResult
    public mutating func stack(into delta: Int) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let target = focus + delta
        guard columns.indices.contains(target) else { return false }
        let source = focus
        let row = columns[source].active
        let w = columns[source].windows[row]
        let h = columns[source].heights[row]

        columns[source].windows.remove(at: row)
        columns[source].heights.remove(at: row)
        let avgHeight = columns[target].heights.reduce(0, +) / Double(max(columns[target].heights.count, 1))
        columns[target].windows.append(w)
        columns[target].heights.append(columns[source].windows.isEmpty ? avgHeight : max(h, 0.1))
        columns[target].active = columns[target].windows.count - 1

        var newFocus = target
        if columns[source].windows.isEmpty {
            columns.remove(at: source)
            if source < target { newFocus -= 1 }
        } else {
            columns[source].normalize()
        }
        focus = newFocus
        previousFocus = nil
        return true
    }

    /// Takes the focused window out of its stack into a new column on its
    /// right (+1) or left (-1). Does nothing for a lone window.
    @discardableResult
    public mutating func popOut(_ direction: Int) -> Bool {
        guard columns.indices.contains(focus), columns[focus].windows.count > 1 else { return false }
        let row = columns[focus].active
        let w = columns[focus].windows.remove(at: row)
        columns[focus].heights.remove(at: row)
        columns[focus].normalize()
        let width = columns[focus].width
        let idx = direction > 0 ? focus + 1 : focus
        columns.insert(Column(windows: [w], width: width), at: idx)
        focus = idx
        previousFocus = nil
        return true
    }

    @discardableResult
    public mutating func toggleTabbed() -> Bool {
        guard columns.indices.contains(focus) else { return false }
        columns[focus].tabbed.toggle()
        return true
    }

    // MARK: - Sizes

    /// Cycles the focused column through the preset widths.
    @discardableResult
    public mutating func cycleWidth(presets: [Double]) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let sorted = presets.map(Column.clampWidth).sorted()
        guard !sorted.isEmpty else { return false }
        let current = columns[focus].width
        let next = sorted.first(where: { $0 > current + 0.005 }) ?? sorted[0]
        columns[focus].width = next
        columns[focus].savedWidth = nil
        return true
    }

    /// Toggles the focused column between full width and its previous width.
    @discardableResult
    public mutating func toggleFullWidth() -> Bool {
        guard columns.indices.contains(focus) else { return false }
        var c = columns[focus]
        if c.width >= 0.999, let saved = c.savedWidth {
            c.width = saved
            c.savedWidth = nil
        } else if c.width < 0.999 {
            c.savedWidth = c.width
            c.width = 1
        } else {
            return false
        }
        columns[focus] = c
        return true
    }

    /// Makes the focused column wider (positive) or narrower (negative).
    @discardableResult
    public mutating func resizeWidth(by step: Double) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let old = columns[focus].width
        let new = Column.clampWidth(((old + step) * 1000).rounded() / 1000)
        guard abs(new - old) > 0.0001 else { return false }
        columns[focus].width = new
        columns[focus].savedWidth = nil
        return true
    }

    /// Sets the focused column width directly (fraction).
    @discardableResult
    public mutating func setWidth(_ w: Double, column: Int? = nil) -> Bool {
        let i = column ?? focus
        guard columns.indices.contains(i) else { return false }
        let new = Column.clampWidth(w)
        guard abs(new - columns[i].width) > 0.0001 else { return false }
        columns[i].width = new
        columns[i].savedWidth = nil
        return true
    }

    /// Makes the focused window in a stack taller (positive) or shorter.
    /// `step` is a fraction of the column height.
    @discardableResult
    public mutating func resizeHeight(by step: Double) -> Bool {
        guard columns.indices.contains(focus) else { return false }
        var c = columns[focus]
        let n = c.windows.count
        guard n > 1, !c.tabbed else { return false }
        let minFraction = min(0.1, 1 / Double(n))
        var f = c.heightFractions
        let a = c.active
        let maxFraction = 1 - minFraction * Double(n - 1)
        let newA = min(max(f[a] + step, minFraction), maxFraction)
        guard abs(newA - f[a]) > 0.0001 else { return false }
        let othersOld = 1 - f[a]
        let othersNew = 1 - newA
        for i in 0..<n where i != a {
            f[i] = othersOld > 0 ? f[i] / othersOld * othersNew : othersNew / Double(n - 1)
            f[i] = max(f[i], minFraction * 0.999)
        }
        f[a] = newA
        c.heights = f
        columns[focus] = c
        return true
    }

    @discardableResult
    public mutating func equalizeHeights() -> Bool {
        guard columns.indices.contains(focus) else { return false }
        let n = columns[focus].windows.count
        let eq = Array(repeating: 1.0, count: n)
        let old = columns[focus].heightFractions
        guard old.contains(where: { abs($0 - 1 / Double(n)) > 0.0001 }) else { return false }
        columns[focus].heights = eq
        return true
    }

    /// Sets the height fraction of one window, rescaling the others (used
    /// when the user resizes a stacked window with the mouse).
    @discardableResult
    public mutating func setHeightFraction(_ fraction: Double, window w: WindowID) -> Bool {
        guard let (c, r) = locate(w), columns[c].windows.count > 1 else { return false }
        let n = columns[c].windows.count
        let minFraction = min(0.1, 1 / Double(n))
        var f = columns[c].heightFractions
        let target = min(max(fraction, minFraction), 1 - minFraction * Double(n - 1))
        let othersOld = 1 - f[r], othersNew = 1 - target
        for i in 0..<n where i != r {
            f[i] = othersOld > 0 ? f[i] / othersOld * othersNew : othersNew / Double(n - 1)
        }
        f[r] = target
        columns[c].heights = f
        return true
    }

    /// Repairs indices after external edits (e.g. a restored session).
    public mutating func normalize() {
        columns.removeAll { $0.windows.isEmpty }
        for i in columns.indices { columns[i].normalize() }
        if columns.isEmpty { focus = 0 } else { focus = min(max(focus, 0), columns.count - 1) }
        if let p = previousFocus, !columns.indices.contains(p) { previousFocus = nil }
        if !offset.isFinite { offset = 0 }
    }
}
