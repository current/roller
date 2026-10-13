import AppKit
import CoreVideo
import RollerCore

/// Sends window frames to other apps through Accessibility on a background
/// queue. Requests for the same window are coalesced, so a slow app only
/// ever receives the newest frame and never falls behind the animation.
final class FrameApplier {
    struct Request {
        var element: AXUIElement
        var pid: pid_t
        var frame: CGRect
        var setSize: Bool
        var readBack: Bool
    }

    private let queue = DispatchQueue(label: "roller.ax", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [WindowID: Request] = [:]
    private var order: [WindowID] = []
    private var scheduled = false

    /// Called on the main queue with the size a window actually took, when it
    /// differs from what was asked (apps may enforce a minimum size).
    var onSizeMismatch: ((WindowID, CGSize, CGSize) -> Void)?

    func submit(_ id: WindowID, _ r: Request) {
        lock.lock()
        if var old = pending[id] {
            old.frame = r.frame
            old.setSize = old.setSize || r.setSize
            old.readBack = old.readBack || r.readBack
            pending[id] = old
        } else {
            pending[id] = r
            order.append(id)
        }
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        let batch = order.compactMap { id in pending[id].map { (id, $0) } }
        pending.removeAll()
        order.removeAll()
        scheduled = false
        lock.unlock()

        // Group by app so AXEnhancedUserInterface (set by some apps for
        // VoiceOver; it makes them animate every move) is toggled once.
        var byPid: [pid_t: [(WindowID, Request)]] = [:]
        for item in batch { byPid[item.1.pid, default: []].append(item) }
        for (pid, items) in byPid {
            let app = AX.app(pid)
            let enhanced: Bool = app.attribute("AXEnhancedUserInterface") ?? false
            if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
            for (id, r) in items {
                apply(id, r)
            }
            if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
        }
    }

    private func apply(_ id: WindowID, _ r: Request) {
        let el = r.element
        if r.setSize {
            // Position, size, position: macOS limits a window's size by how
            // much room is left on its current screen.
            el.setPosition(r.frame.origin)
            el.setSize(r.frame.size)
            el.setPosition(r.frame.origin)
        } else {
            el.setPosition(r.frame.origin)
        }
        if r.readBack, let actual = el.size {
            let asked = r.frame.size
            if abs(actual.width - asked.width) > 2 || abs(actual.height - asked.height) > 2 {
                DispatchQueue.main.async { [weak self] in self?.onSizeMismatch?(id, asked, actual) }
            }
        }
    }
}

/// Animates windows toward target frames with a spring, one step per display
/// refresh. Frames here are "virtual": they may lie off screen, and are
/// turned into frames macOS accepts by `Placer` right before applying.
final class Animator {
    struct Target {
        var element: AXUIElement
        var pid: pid_t
        var frame: CGRect
        var display: CGRect
        var neighbors: DisplayNeighbors
    }

    private struct Item {
        var target: Target
        var from: CGRect
        var sizeApplied: Bool
    }

    let applier = FrameApplier()
    var spring = Spring(duration: 0.5, damping: 0.9)

    /// Last virtual frame shown for each window.
    private(set) var current: [WindowID: CGRect] = [:]
    /// Last frame actually sent to each window (after placement).
    private(set) var applied: [WindowID: CGRect] = [:]
    private(set) var hidden: Set<WindowID> = []
    private var items: [WindowID: Item] = [:]
    private var startTime: CFTimeInterval = 0
    private var link: CVDisplayLink?
    private var tickPending = false
    private let tickLock = NSLock()

    /// When each window was last moved by Roller (to tell our own moves
    /// from the user's).
    private(set) var lastSet: [WindowID: CFTimeInterval] = [:]

    /// Called after every step with the frames shown at that moment.
    var onFrame: (() -> Void)?
    /// Called when an animation comes to rest.
    var onSettle: (() -> Void)?

    var isAnimating: Bool { !items.isEmpty }

    init() {
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.scheduleTick()
                return kCVReturnSuccess
            }
        }
    }

    deinit {
        if let link { CVDisplayLinkStop(link) }
    }

    private func scheduleTick() {
        tickLock.lock()
        let already = tickPending
        tickPending = true
        tickLock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickLock.lock(); self.tickPending = false; self.tickLock.unlock()
            self.tick()
        }
    }

    /// Whether Roller itself moved this window within `window` seconds.
    func recentlySet(_ id: WindowID, within window: CFTimeInterval = 0.6) -> Bool {
        if items[id] != nil { return true }
        guard let t = lastSet[id] else { return false }
        return CACurrentMediaTime() - t < window
    }

    func forget(_ id: WindowID) {
        current[id] = nil
        applied[id] = nil
        items[id] = nil
        hidden.remove(id)
        lastSet[id] = nil
    }

    /// Records where a window is without moving it (e.g. on first sight).
    func seed(_ id: WindowID, frame: CGRect) {
        if current[id] == nil { current[id] = frame }
    }

    /// Moves windows to `targets`. With `animated` false they jump.
    func move(_ targets: [WindowID: Target], animated: Bool) {
        let now = CACurrentMediaTime()
        let springOn = animated && spring.duration > 0
        // Freeze running animations at their current point; the ones that
        // aren't retargeted continue from there.
        var newItems: [WindowID: Item] = [:]
        if !items.isEmpty {
            let p = spring.value(at: now - startTime)
            for (id, item) in items {
                let cur = Lerp.rect(item.from, item.target.frame, p)
                current[id] = cur
                if targets[id] == nil {
                    newItems[id] = Item(target: item.target, from: cur, sizeApplied: item.sizeApplied)
                }
            }
        }
        for (id, t) in targets {
            let from = current[id] ?? t.frame
            let fromPlaced = Placer.place(from, display: t.display, neighbors: t.neighbors)
            let toPlaced = Placer.place(t.frame, display: t.display, neighbors: t.neighbors)
            let unchanged = from.equalTo(t.frame) && applied[id].map { $0.equalTo(toPlaced.frame) } == true
            if unchanged { newItems[id] = nil; continue }
            if !springOn || (fromPlaced.hidden && toPlaced.hidden) {
                // Invisible the whole way, or no animation: jump.
                newItems[id] = nil
                current[id] = t.frame
                send(id, t, frame: t.frame, final: true)
                continue
            }
            // Resize up front and animate the position; resizing other apps'
            // windows every frame is slow and makes them flicker.
            var start = from
            start.size = t.frame.size
            newItems[id] = Item(target: t, from: start, sizeApplied: false)
        }
        items = newItems
        startTime = now
        if items.isEmpty {
            stopLink()
            onFrame?()
            onSettle?()
        } else {
            for (id, item) in items where !item.sizeApplied {
                send(id, item.target, frame: item.from, final: false, setSize: true)
                items[id]?.sizeApplied = true
            }
            startLink()
        }
    }

    private func tick() {
        guard !items.isEmpty else { stopLink(); return }
        let t = CACurrentMediaTime() - startTime
        let done = spring.isSettled(at: t)
        let p = done ? 1 : spring.value(at: t)
        for (id, item) in items {
            let f = done ? item.target.frame : Lerp.rect(item.from, item.target.frame, p)
            current[id] = f
            send(id, item.target, frame: f, final: done)
        }
        if done {
            items.removeAll()
            stopLink()
        }
        onFrame?()
        if done { onSettle?() }
    }

    private func send(_ id: WindowID, _ t: Target, frame virtual: CGRect, final: Bool, setSize: Bool = false) {
        let placed = Placer.place(virtual, display: t.display, neighbors: t.neighbors)
        let rounded = CGRect(x: placed.frame.minX.rounded(), y: placed.frame.minY.rounded(),
                             width: placed.frame.width.rounded(), height: placed.frame.height.rounded())
        if placed.hidden { hidden.insert(id) } else { hidden.remove(id) }
        let sizeChanged = applied[id].map { !$0.size.equalTo(rounded.size) } ?? true
        if !final, !setSize, let prev = applied[id], prev.origin.equalTo(rounded.origin) { return }
        if final, let prev = applied[id], prev.equalTo(rounded) { return }
        applied[id] = rounded
        lastSet[id] = CACurrentMediaTime()
        let resize = setSize || sizeChanged
        applier.submit(id, .init(element: t.element, pid: t.pid, frame: rounded, setSize: resize, readBack: resize))
    }

    /// Forces the next `move` to re-send every frame (after an app moved
    /// its own window, for example).
    func invalidate(_ id: WindowID) { applied[id] = nil }

    private func startLink() {
        guard let link, !CVDisplayLinkIsRunning(link) else { return }
        CVDisplayLinkStart(link)
    }

    private func stopLink() {
        guard let link, CVDisplayLinkIsRunning(link) else { return }
        CVDisplayLinkStop(link)
    }
}
