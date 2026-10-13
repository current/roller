import CoreGraphics
import Foundation

/// When the strip scrolls to keep the focused column centered.
public enum CenterMode: String, Codable, CaseIterable {
    /// Scroll as little as possible to show the focused column.
    case never
    /// Center when the focused column doesn't fit on screen together with
    /// the previously focused column.
    case onOverflow = "on-overflow"
    /// Always center the focused column.
    case always
}

/// Everything layout needs to know about the display a strip lives on.
/// All rectangles use global top-left-origin coordinates (Quartz / AX).
public struct LayoutParams: Equatable {
    /// The working area: the usable display area inset by the outer gap.
    public var area: CGRect
    /// Gap between columns and between stacked windows.
    public var gap: Double
    /// Height reserved above tabbed columns for the tab bar.
    public var tabBarHeight: Double
    public var centerMode: CenterMode
    /// Learned minimum widths of windows that refuse to get narrower.
    public var minWidths: [WindowID: Double]

    public init(area: CGRect, gap: Double, tabBarHeight: Double = 26, centerMode: CenterMode = .never, minWidths: [WindowID: Double] = [:]) {
        self.area = area
        self.gap = gap
        self.tabBarHeight = tabBarHeight
        self.centerMode = centerMode
        self.minWidths = minWidths
    }
}

public enum Layout {
    /// Width in points of a column. Fractions are chosen so that two 0.5
    /// columns plus one gap exactly fill the working area.
    public static func columnWidth(_ c: Column, _ p: LayoutParams) -> Double {
        let w = (c.width * (Double(p.area.width) + p.gap) - p.gap).rounded()
        let minW = c.windows.compactMap { p.minWidths[$0] }.max() ?? 0
        return max(w, minW, 1)
    }

    /// Converts a width in points back to a column fraction.
    public static func fraction(forWidth w: Double, _ p: LayoutParams) -> Double {
        Column.clampWidth((w + p.gap) / (Double(p.area.width) + p.gap))
    }

    /// Strip-space x and width of every column.
    public static func spans(_ s: Strip, _ p: LayoutParams) -> [(x: Double, w: Double)] {
        var x = 0.0
        return s.columns.map { c in
            let w = columnWidth(c, p)
            defer { x += w + p.gap }
            return (x, w)
        }
    }

    public static func totalWidth(_ s: Strip, _ p: LayoutParams) -> Double {
        guard let last = spans(s, p).last else { return 0 }
        return last.x + last.w
    }

    /// The frames every window would have at the strip's current offset
    /// (or `offset` when given). Frames may lie outside the display; use
    /// `placement` to turn them into frames macOS accepts.
    public static func frames(_ s: Strip, _ p: LayoutParams, offset: Double? = nil) -> [WindowID: CGRect] {
        let off = offset ?? s.offset
        var out: [WindowID: CGRect] = [:]
        let a = p.area
        for (c, span) in zip(s.columns, spans(s, p)) {
            let x = (Double(a.minX) + span.x - off).rounded()
            if c.tabbed {
                let top = Double(a.minY) + p.tabBarHeight
                let h = max(Double(a.height) - p.tabBarHeight, 1)
                for w in c.windows { out[w] = CGRect(x: x, y: top, width: span.w, height: h) }
                continue
            }
            let n = c.windows.count
            let avail = Double(a.height) - p.gap * Double(n - 1)
            var y = Double(a.minY)
            let fractions = c.heightFractions
            for (i, w) in c.windows.enumerated() {
                let h = i == n - 1 ? Double(a.maxY) - y : (avail * fractions[i]).rounded()
                out[w] = CGRect(x: x, y: y, width: span.w, height: max(h, 1))
                y += h + p.gap
            }
        }
        return out
    }

    /// Frame of the tab bar for a tabbed column at the strip's offset.
    public static func tabBarFrame(_ s: Strip, column i: Int, _ p: LayoutParams, offset: Double? = nil) -> CGRect? {
        guard s.columns.indices.contains(i), s.columns[i].tabbed else { return nil }
        let span = spans(s, p)[i]
        let x = Double(p.area.minX) + span.x - (offset ?? s.offset)
        return CGRect(x: x.rounded(), y: Double(p.area.minY), width: span.w, height: p.tabBarHeight - min(p.gap, 6))
    }

    // MARK: - Scrolling

    static func isFullyVisible(x: Double, w: Double, offset: Double, viewWidth: Double) -> Bool {
        x >= offset - 0.5 && x + w <= offset + viewWidth + 0.5
    }

    /// Scrolls the strip so the focused column is visible, following the
    /// centering mode.
    public static func revealFocus(_ s: inout Strip, _ p: LayoutParams) {
        let sp = spans(s, p)
        guard sp.indices.contains(s.focus) else { s.offset = 0; return }
        let (x, w) = sp[s.focus]
        let view = Double(p.area.width)
        if w >= view - 0.5 {
            s.offset = x
            return
        }
        switch p.centerMode {
        case .always:
            s.offset = x + w / 2 - view / 2
        case .never:
            s.offset = minimalOffset(x: x, w: w, offset: s.offset, view: view)
        case .onOverflow:
            if isFullyVisible(x: x, w: w, offset: s.offset, viewWidth: view) { return }
            if let prev = s.previousFocus, prev != s.focus, sp.indices.contains(prev) {
                let (px, pw) = sp[prev]
                let lo = min(x, px), hi = max(x + w, px + pw)
                if hi - lo > view {
                    s.offset = x + w / 2 - view / 2
                    return
                }
            }
            s.offset = minimalOffset(x: x, w: w, offset: s.offset, view: view)
        }
    }

    static func minimalOffset(x: Double, w: Double, offset: Double, view: Double) -> Double {
        if x < offset { return x }
        if x + w > offset + view { return x + w - view }
        return offset
    }

    /// Centers the focused column regardless of mode.
    public static func centerFocus(_ s: inout Strip, _ p: LayoutParams) {
        let sp = spans(s, p)
        guard sp.indices.contains(s.focus) else { return }
        let (x, w) = sp[s.focus]
        s.offset = x + w / 2 - Double(p.area.width) / 2
    }

    /// After columns are removed or resized, pulls the view back so no
    /// needless empty space shows (except in always-center mode), then makes
    /// sure the focused column is still in view.
    public static func settle(_ s: inout Strip, _ p: LayoutParams) {
        if p.centerMode != .always {
            let maxOffset = max(0, totalWidth(s, p) - Double(p.area.width))
            s.offset = min(max(s.offset, 0), maxOffset)
        }
        revealFocus(&s, p)
    }

    /// Where a swipe should come to rest. Returns the snapped offset and the
    /// column that becomes focused.
    public static func snap(_ s: Strip, _ p: LayoutParams, projectedOffset: Double) -> (offset: Double, column: Int)? {
        let sp = spans(s, p)
        guard !sp.isEmpty else { return nil }
        let view = Double(p.area.width)
        let maxOffset = max(0, totalWidth(s, p) - view)
        var best: (offset: Double, column: Int, dist: Double)?
        func consider(_ o: Double, _ c: Int) {
            var o = o
            if p.centerMode != .always { o = min(max(o, 0), maxOffset) }
            let d = abs(o - projectedOffset)
            if best == nil || d < best!.dist - 0.01 { best = (o, c, d) }
        }
        for (i, (x, w)) in sp.enumerated() {
            if p.centerMode == .always || w >= view {
                consider(x + w / 2 - view / 2, i)
                if w > view { consider(x, i) }
            } else {
                consider(x, i)
                consider(x + w - view, i)
                if p.centerMode == .onOverflow { consider(x + w / 2 - view / 2, i) }
            }
        }
        guard let b = best else { return nil }
        // Focus a column that ends up fully visible: in the direction of the
        // swipe the newly revealed one, otherwise the snapped column.
        let full = sp.indices.filter { visibleWidth(sp[$0], offset: b.offset, view: view) >= min(sp[$0].w, view) - 0.5 }
        var focus = b.column
        if projectedOffset > s.offset + 0.5, let last = full.last { focus = last }
        else if projectedOffset < s.offset - 0.5, let first = full.first { focus = first }
        else if !full.contains(b.column), let first = full.first { focus = first }
        return (b.offset, focus)
    }

    static func visibleWidth(_ span: (x: Double, w: Double), offset: Double, view: Double) -> Double {
        max(0, min(span.x + span.w, offset + view) - max(span.x, offset))
    }

    /// Index of the column under a screen x coordinate (clamped to the strip).
    public static func columnIndex(atScreenX sx: Double, _ s: Strip, _ p: LayoutParams) -> Int? {
        let sp = spans(s, p)
        guard !sp.isEmpty else { return nil }
        let x = sx - Double(p.area.minX) + s.offset
        for (i, span) in sp.enumerated() where x < span.x + span.w + p.gap / 2 {
            return i
        }
        return sp.count - 1
    }
}

// MARK: - Placing windows on a real display

/// Which sides of a display touch another display.
public struct DisplayNeighbors: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = DisplayNeighbors(rawValue: 1)
    public static let right = DisplayNeighbors(rawValue: 2)
    public static let below = DisplayNeighbors(rawValue: 4)
    public static let above = DisplayNeighbors(rawValue: 8)

    /// Computes the neighbours of `display` among `all` display frames.
    public static func of(_ display: CGRect, among all: [CGRect]) -> DisplayNeighbors {
        var n: DisplayNeighbors = []
        for other in all where other != display {
            let vOverlap = min(other.maxY, display.maxY) - max(other.minY, display.minY)
            let hOverlap = min(other.maxX, display.maxX) - max(other.minX, display.minX)
            if vOverlap > 0 {
                if abs(other.maxX - display.minX) < 2 { n.insert(.left) }
                if abs(other.minX - display.maxX) < 2 { n.insert(.right) }
            }
            if hOverlap > 0 {
                if abs(other.minY - display.maxY) < 2 { n.insert(.below) }
                if abs(other.maxY - display.minY) < 2 { n.insert(.above) }
            }
        }
        return n
    }
}

public struct Placement: Equatable {
    public var frame: CGRect
    /// True when the window is parked out of sight.
    public var hidden: Bool
}

public enum Placer {
    /// macOS never lets a window leave the screen completely, so hidden
    /// windows are parked in a bottom corner with only a sliver showing.
    public static func place(_ v: CGRect, display d: CGRect, neighbors: DisplayNeighbors, sliver: Double = 1) -> Placement {
        let overlap = min(v.maxX, d.maxX) - max(v.minX, d.minX)
        var hideLeft: Bool? = nil
        if overlap > 0 {
            let leftOver = d.minX - v.minX
            let rightOver = v.maxX - d.maxX
            // Toward another display a window may only slide halfway off;
            // further and it would land on that display.
            if neighbors.contains(.left) && leftOver > v.width / 2 {
                hideLeft = true
            } else if neighbors.contains(.right) && rightOver > v.width / 2 {
                hideLeft = false
            } else {
                return Placement(frame: v, hidden: false)
            }
        } else {
            hideLeft = v.midX < d.midX
        }
        return Placement(frame: park(v, display: d, neighbors: neighbors, left: hideLeft!, sliver: sliver), hidden: true)
    }

    static func park(_ v: CGRect, display d: CGRect, neighbors: DisplayNeighbors, left: Bool, sliver s: Double) -> CGRect {
        let leftX = Double(d.minX) - Double(v.width) + s
        let rightX = Double(d.maxX) - s
        let y = neighbors.contains(.below) ? Double(v.minY) : Double(d.maxY) - s
        let preferLeft = left
        if !neighbors.contains(preferLeft ? .left : .right) {
            return CGRect(x: preferLeft ? leftX : rightX, y: y, width: v.width, height: v.height)
        }
        if !neighbors.contains(preferLeft ? .right : .left) {
            return CGRect(x: preferLeft ? rightX : leftX, y: y, width: v.width, height: v.height)
        }
        if !neighbors.contains(.below) {
            let x = min(max(Double(v.minX), Double(d.minX)), Double(d.maxX) - Double(v.width))
            return CGRect(x: x, y: Double(d.maxY) - s, width: v.width, height: v.height)
        }
        return CGRect(x: preferLeft ? leftX : rightX, y: Double(v.minY), width: v.width, height: v.height)
    }
}
