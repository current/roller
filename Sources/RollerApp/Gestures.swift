import AppKit
import RollerCore

/// Follows multi-finger horizontal trackpad swipes through a listen-only
/// event tap. It reads touch positions from gesture events and never blocks
/// or changes them, so macOS still sees every swipe (see Mac Setup).
final class SwipeTracker {
    /// Horizontal movement in trackpad widths (0...1); positive = fingers
    /// moved right.
    var onBegin: (() -> Void)?
    var onMove: ((Double) -> Void)?
    /// Velocity in trackpad widths per second.
    var onEnd: ((Double) -> Void)?

    var fingers = 4

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private enum State {
        case idle
        case deciding(start: CGPoint, last: CGPoint)
        case tracking(last: CGPoint, lastTime: TimeInterval, velocity: Double)
        case ignoring
    }
    private var state: State = .idle

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil, fingers > 0 else { return }
        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.gesture.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SwipeTracker>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                me.handle(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            log("could not create the trackpad event tap")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        finish()
    }

    private func handle(_ cg: CGEvent) {
        guard let ev = NSEvent(cgEvent: cg), ev.type == .gesture else { return }
        let touches = ev.touches(matching: .touching, in: nil)
        guard touches.count == fingers else {
            finish()
            if touches.isEmpty { state = .idle }
            return
        }
        var sum = CGPoint.zero
        for t in touches { sum.x += t.normalizedPosition.x; sum.y += t.normalizedPosition.y }
        let p = CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
        let now = ev.timestamp

        switch state {
        case .idle:
            state = .deciding(start: p, last: p)
        case .deciding(let start, _):
            let dx = p.x - start.x, dy = p.y - start.y
            if hypot(dx, dy) < 0.02 { state = .deciding(start: start, last: p); return }
            if abs(dx) > abs(dy) * 1.2 {
                state = .tracking(last: p, lastTime: now, velocity: 0)
                onBegin?()
                onMove?(Double(dx))
            } else {
                state = .ignoring // vertical: Mission Control, App Exposé
            }
        case .tracking(let last, let lastTime, let velocity):
            let dx = Double(p.x - last.x)
            let dt = max(now - lastTime, 0.001)
            let v = 0.7 * (dx / dt) + 0.3 * velocity
            state = .tracking(last: p, lastTime: now, velocity: v)
            if dx != 0 { onMove?(dx) }
        case .ignoring:
            break
        }
    }

    private func finish() {
        if case .tracking(_, let lastTime, let velocity) = state {
            // A finger lifted after a pause means no fling.
            let idle = ProcessInfo.processInfo.systemUptime - lastTime
            onEnd?(idle > 0.08 ? 0 : velocity)
        }
        if case .idle = state { return }
        state = .ignoring
    }
}
