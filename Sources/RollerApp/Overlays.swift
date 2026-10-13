import AppKit
import RollerCore

/// A transparent, click-through panel used for every overlay.
class OverlayPanel: NSPanel {
    init(clickThrough: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone]
        level = .normal
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSColor {
    convenience init(_ c: RGBA) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}

// MARK: - Focus border

final class FocusBorder {
    private let panel = OverlayPanel()
    private let view = BorderView()

    init() { panel.contentView = view }

    func show(around frame: CGRect, window: WindowID, config: Config) {
        let w = config.focusBorderWidth
        view.width = w
        view.radius = config.focusBorderRadius
        view.color = NSColor(RGBA(hex: config.focusBorderColor) ?? RGBA(r: 0.24, g: 0.55, b: 0.99, a: 1))
        panel.setFrame(Geometry.toCocoa(frame.insetBy(dx: -w, dy: -w)), display: false)
        view.needsDisplay = true
        panel.order(.above, relativeTo: Int(window))
    }

    func hide() { panel.orderOut(nil) }

    private final class BorderView: NSView {
        var width: CGFloat = 3
        var radius: CGFloat = 10
        var color: NSColor = .controlAccentColor
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: width / 2, dy: width / 2)
            let path = NSBezierPath(roundedRect: r, xRadius: radius + width / 2, yRadius: radius + width / 2)
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        }
    }
}

// MARK: - Dim inactive windows

final class DimOverlay {
    private var panels: [String: OverlayPanel] = [:]

    /// Dims `display` everywhere below the focused window.
    func show(on display: Display, below window: WindowID, opacity: Double) {
        let panel = panels[display.uuid] ?? {
            let p = OverlayPanel()
            p.backgroundColor = .black
            p.isOpaque = false
            panels[display.uuid] = p
            return p
        }()
        panel.alphaValue = opacity
        panel.setFrame(Geometry.toCocoa(display.frame), display: false)
        panel.order(.below, relativeTo: Int(window))
        for (uuid, p) in panels where uuid != display.uuid { p.orderOut(nil) }
    }

    func hide() { panels.values.forEach { $0.orderOut(nil) } }
}

// MARK: - Minimap

/// A small map of the strip shown at the top of the display while you move.
final class Minimap {
    struct Snapshot {
        var columns: [(x: Double, w: Double, rows: [Double], tabbed: Bool)]
        var focus: Int
        var focusRow: Int
        var viewX: Double
        var viewW: Double
    }

    private let panel = OverlayPanel()
    private let view = MapView()
    private var hideWork: DispatchWorkItem?

    init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            view.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            view.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
        panel.contentView = effect
        panel.level = .statusBar
    }

    func show(_ s: Snapshot, on display: Display) {
        view.snapshot = s
        let width = min(max(display.visibleFrame.width * 0.32, 220), 520)
        let height: CGFloat = 64
        let frame = CGRect(x: display.visibleFrame.midX - width / 2, y: display.visibleFrame.minY + 10, width: width, height: height)
        panel.setFrame(Geometry.toCocoa(frame), display: false)
        view.needsDisplay = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private final class MapView: NSView {
        var snapshot: Snapshot?
        override func draw(_ dirtyRect: NSRect) {
            guard let s = snapshot, let last = s.columns.last else { return }
            let lo = min(0, s.viewX)
            let hi = max(last.x + last.w, s.viewX + s.viewW)
            let span = max(hi - lo, 1)
            let scale = bounds.width / span
            let gap: CGFloat = 2
            for (i, c) in s.columns.enumerated() {
                let x = CGFloat(c.x - lo) * scale
                let w = max(CGFloat(c.w) * scale - gap, 2)
                let focused = i == s.focus
                if c.tabbed || c.rows.count <= 1 {
                    let r = NSRect(x: x, y: 0, width: w, height: bounds.height)
                    fill(r, focused: focused)
                } else {
                    var y = bounds.height
                    for (ri, f) in c.rows.enumerated() {
                        let h = CGFloat(f) * bounds.height
                        let r = NSRect(x: x, y: y - h + (ri == c.rows.count - 1 ? 0 : gap), width: w, height: h - (ri == c.rows.count - 1 ? 0 : gap))
                        fill(r, focused: focused && ri == s.focusRow)
                        y -= h
                    }
                }
            }
            let vx = CGFloat(s.viewX - lo) * scale
            let vw = CGFloat(s.viewW) * scale
            let view = NSBezierPath(roundedRect: NSRect(x: vx - 1, y: -1, width: vw, height: bounds.height + 2).insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            view.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            view.stroke()
        }

        private func fill(_ r: NSRect, focused: Bool) {
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            (focused ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.28)).setFill()
            p.fill()
        }
    }
}

// MARK: - Tab bars

/// The tab bar shown above a tabbed column.
final class TabBar {
    let panel = OverlayPanel(clickThrough: false)
    private let stack = NSStackView()
    var onSelect: ((WindowID) -> Void)?

    init() {
        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    func update(tabs: [(id: WindowID, title: String)], active: Int, frame: CGRect, above window: WindowID) {
        let existing = stack.arrangedSubviews.compactMap { $0 as? TabButton }
        if existing.map(\.windowID) != tabs.map(\.id) {
            existing.forEach { $0.removeFromSuperview() }
            for t in tabs {
                let b = TabButton(windowID: t.id) { [weak self] id in self?.onSelect?(id) }
                stack.addArrangedSubview(b)
            }
        }
        for (i, b) in stack.arrangedSubviews.compactMap({ $0 as? TabButton }).enumerated() {
            b.title = tabs[i].title.isEmpty ? "Untitled" : tabs[i].title
            b.isActive = i == active
        }
        panel.setFrame(Geometry.toCocoa(frame), display: true)
        panel.order(.above, relativeTo: Int(window))
    }

    func close() { panel.orderOut(nil) }

    private final class TabButton: NSButton {
        let windowID: WindowID
        let select: (WindowID) -> Void
        var isActive = false { didSet { updateLook() } }

        init(windowID: WindowID, select: @escaping (WindowID) -> Void) {
            self.windowID = windowID
            self.select = select
            super.init(frame: .zero)
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = 5
            lineBreakMode = .byTruncatingTail
            font = .systemFont(ofSize: 11)
            target = self
            action = #selector(clicked)
            updateLook()
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func clicked() { select(windowID) }

        private func updateLook() {
            layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
            contentTintColor = isActive ? .white : .labelColor
            font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        }
    }
}
