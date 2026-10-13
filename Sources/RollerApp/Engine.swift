import AppKit
import RollerCore

/// A window Roller knows about.
final class ManagedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    var title: String
    /// Off the strip, free to move.
    var floating = false
    var minimized = false
    var appHidden = false
    var fullscreen = false
    /// Lives on a display Roller is switched off for.
    var onIgnoredDisplay = false

    init(id: WindowID, element: AXUIElement, pid: pid_t, bundleID: String?, title: String) {
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
    }

    var saved: SavedWindow { SavedWindow(id: id, bundleID: bundleID, title: title) }
}

/// The window manager: keeps one strip per display and Space, reacts to
/// windows and input, and lays everything out.
final class Engine {
    static let shared = Engine()

    enum Status: Equatable {
        case stopped
        case running
        case needsPermission
    }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?

    var config: Config = .default
    private(set) var displays: [Display] = []
    private(set) var strips: [String: Strip] = [:]
    private(set) var windows: [WindowID: ManagedWindow] = [:]
    private var observers: [pid_t: AppObserver] = [:]
    private var minWidths: [WindowID: Double] = [:]

    let animator = Animator()
    private let swipe = SwipeTracker()
    private let border = FocusBorder()
    private let dim = DimOverlay()
    private let minimap = Minimap()
    private var tabBars: [WindowID: TabBar] = [:]
    private let session = SessionStore()

    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private var reconcileTimer: Timer?
    private var permissionTimer: Timer?

    /// The window Roller last saw or made focused.
    private var lastFocused: WindowID?
    /// Don't scroll when this window gains focus (focus follows mouse).
    private var noRevealFor: WindowID?
    /// Keeps a background app's new window from stealing focus.
    private var stealGuard: (newWindow: WindowID, keep: WindowID, until: Date)?
    private var recentLaunches: [pid_t: Date] = [:]
    private var fights: [WindowID: [Date]] = [:]
    private var pendingRestore: [String: SavedStrip] = [:]
    private var pendingFloating: [SavedWindow] = []

    // Swipe state
    private var swipeKey: String?
    private var swipeVelocityScale = 0.0

    // Mouse drag state
    private var mouseDown = false
    private var dragWindow: WindowID?
    private var dragResized = false
    private var lastHover: (WindowID, Date)?
    private var hoverWork: DispatchWorkItem?

    private init() {
        animator.onFrame = { [weak self] in self?.updateDecorations() }
        animator.onSettle = { [weak self] in self?.updateDecorations() }
        animator.applier.onSizeMismatch = { [weak self] id, asked, actual in self?.sizeMismatch(id, asked: asked, actual: actual) }
        swipe.onBegin = { [weak self] in self?.swipeBegan() }
        swipe.onMove = { [weak self] dx in self?.swipeMoved(dx) }
        swipe.onEnd = { [weak self] v in self?.swipeEnded(velocity: v) }
    }

    // MARK: - Lifecycle

    func start() {
        guard status != .running else { return }
        guard AX.isTrusted else {
            status = .needsPermission
            AX.requestTrust()
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                if AX.isTrusted { t.invalidate(); self?.start() }
            }
            registerHotkeys()
            return
        }
        permissionTimer?.invalidate()
        log("starting")
        status = .running
        applyMotionSettings()

        let restored = session.load()
        pendingRestore = Dictionary(restored?.strips.map { ($0.key, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        pendingFloating = restored?.floating ?? []

        displays = Display.all()
        for app in NSWorkspace.shared.runningApplications { addApp(app) }
        scan(initial: true)
        for key in visibleKeys { relayout(key, animated: false, reveal: true) }

        installWorkspaceObservers()
        installMouseMonitors()
        registerHotkeys()
        swipe.fingers = config.swipeGestureFingers.rawValue
        swipe.start()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reconcile() }
        syncFocus()
    }

    /// Stops managing windows. Every hidden window is brought back on
    /// screen so nothing stays parked in a corner.
    func stop() {
        guard status == .running else {
            if status == .needsPermission { status = .stopped; permissionTimer?.invalidate() }
            return
        }
        log("stopping")
        session.save(snapshot())
        revealHiddenWindows()
        reconcileTimer?.invalidate()
        swipe.stop()
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        workspaceObservers.removeAll()
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
        observers.values.forEach { $0.invalidate() }
        observers.removeAll()
        windows.removeAll()
        strips.removeAll()
        tabBars.values.forEach { $0.close() }
        tabBars.removeAll()
        border.hide()
        dim.hide()
        minimap.hide()
        status = .stopped
        registerHotkeys()
    }

    /// Tears everything down and starts again (menu › Restart).
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
    }

    func applicationWillTerminate() {
        if status == .running {
            session.save(snapshot())
            revealHiddenWindows()
        }
    }

    private func revealHiddenWindows() {
        for id in animator.hidden { bringOnScreen(id) }
    }

    /// Moves a parked window back into view on its display.
    private func bringOnScreen(_ id: WindowID) {
        guard animator.hidden.contains(id), let w = windows[id], let virtual = animator.current[id] else { return }
        let display = displays.first(where: { $0.frame.intersects(virtual) }) ?? displayFor(frame: virtual)
        let area = display.workingArea(config)
        var f = virtual
        f.origin.x = min(max(f.minX, area.minX), max(area.minX, area.maxX - f.width))
        f.origin.y = min(max(f.minY, area.minY), max(area.minY, area.maxY - f.height))
        w.element.setPosition(f.origin)
        animator.forget(id)
    }

    // MARK: - Configuration

    func apply(_ new: Config) {
        let old = config
        config = new
        applyMotionSettings()
        guard status == .running || status == .needsPermission else {
            registerHotkeys()
            return
        }
        if old.bindings != new.bindings { registerHotkeys() }
        if old.swipeGestureFingers != new.swipeGestureFingers {
            swipe.stop()
            swipe.fingers = new.swipeGestureFingers.rawValue
            swipe.start()
        }
        guard status == .running else { return }
        if old.ignoredDisplays != new.ignoredDisplays || old.rules != new.rules {
            rebuildForRules()
        }
        for key in visibleKeys { relayout(key, animated: true, reveal: true) }
        updateDecorations()
    }

    private func applyMotionSettings() {
        animator.spring = config.spring
    }

    func registerHotkeys() {
        Hotkeys.shared.handler = { [weak self] action in _ = self?.perform(action) }
        if status == .running {
            Hotkeys.shared.register(config.bindings)
        } else {
            Hotkeys.shared.register(config.bindings, only: [.toggleManager, .start])
        }
    }

    /// Re-checks every window against the rules and ignored displays.
    private func rebuildForRules() {
        for w in windows.values {
            let shouldFloat = rule(for: w)?.floating == true
            let onIgnored = config.ignoredDisplays.contains(displayFor(window: w).uuid)
            if (shouldFloat || onIgnored) && stripKey(of: w.id) != nil {
                bringOnScreen(w.id)
                removeFromStrips(w.id)
                w.floating = shouldFloat
                w.onIgnoredDisplay = onIgnored
            } else if !shouldFloat && !onIgnored && w.onIgnoredDisplay {
                w.onIgnoredDisplay = false
                if !w.floating { place(w, focus: false) }
            }
        }
    }

    // MARK: - Apps and windows

    private func addApp(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != getpid(), observers[app.processIdentifier] == nil else { return }
        guard let obs = AppObserver(pid: app.processIdentifier) else { return }
        obs.onEvent = { [weak self] n, el, pid in self?.axEvent(n, el, pid) }
        observers[app.processIdentifier] = obs
    }

    private func removeApp(pid: pid_t) {
        observers[pid]?.invalidate()
        observers[pid] = nil
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        var touched = Set<String>()
        for id in gone {
            if let k = stripKey(of: id) { touched.insert(k) }
            forget(id)
        }
        for k in touched { relayout(k, animated: true, reveal: true) }
    }

    private func forget(_ id: WindowID) {
        removeFromStrips(id)
        if let w = windows[id] { observers[w.pid]?.unwatch(w.element) }
        windows[id] = nil
        minWidths[id] = nil
        fights[id] = nil
        animator.forget(id)
        tabBars[id]?.close()
        tabBars[id] = nil
        if lastFocused == id { lastFocused = nil }
    }

    /// Looks at every window of every app; adds new ones, notices windows
    /// moved to another Space, and builds strips on first sight.
    private func scan(initial: Bool) {
        if !initial { reassignSpaces() }
        var fresh: [String: [(ManagedWindow, CGRect)]] = [:]
        for (pid, obs) in observers {
            for el in obs.app.windows {
                guard let id = el.windowID else { continue }
                if let known = windows[id] {
                    // A window the user moved to another Space through
                    // Mission Control changes strip.
                    if let key = stripKey(of: id), let display = display(forKey: key), let frame = el.frame {
                        let spaces = Spaces.spaces(for: id)
                        if !spaces.isEmpty && !spaces.contains(display.space) && displays.contains(where: { spaces.contains($0.space) }) {
                            removeFromStrips(id)
                            fresh[stripKeyFor(frame: frame, window: known), default: []].append((known, frame))
                        }
                    }
                    continue
                }
                guard let (w, frame) = candidate(el, pid: pid) else { continue }
                if w.floating || w.onIgnoredDisplay { continue }
                fresh[stripKeyFor(frame: frame, window: w), default: []].append((w, frame))
            }
        }
        for (key, list) in fresh {
            var strip = strips[key] ?? Strip()
            let byID = Dictionary(list.map { ($0.0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var used = Set<WindowID>()
            if strip.isEmpty, let saved = pendingRestore.removeValue(forKey: key) {
                strip = SavedSession.restore(saved) { sw in
                    if byID[sw.id] != nil, !used.contains(sw.id) { used.insert(sw.id); return sw.id }
                    if let match = list.first(where: { !used.contains($0.0.id) && $0.0.bundleID == sw.bundleID && $0.0.title == sw.title }) {
                        used.insert(match.0.id)
                        return match.0.id
                    }
                    return nil
                }
                log("restored \(strip.allWindows.count) windows on \(key)")
            }
            // On start, everything else keeps its on-screen left-to-right
            // order. Later, new windows open next to the focused column.
            let rest = list.filter { !used.contains($0.0.id) }.sorted { $0.1.minX < $1.1.minX }
            let p = display(forKey: key).map(params) ?? nil
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var focusNew: WindowID?
            for (w, frame) in rest {
                let width = initialWidth(frame: frame, params: p)
                if let slot = rule(for: w)?.slot {
                    strip.insert(w.id, width: width, at: slot - 1, focus: false)
                } else if initial {
                    strip.insert(w.id, width: width, at: strip.columns.count, focus: false)
                } else {
                    let takeFocus = w.pid == frontPid
                    strip.insert(w.id, width: width, focus: takeFocus)
                    if takeFocus { focusNew = w.id }
                }
            }
            for (w, frame) in list { animator.seed(w.id, frame: frame) }
            strip.normalize()
            strips[key] = strip
            if !initial {
                relayout(key, animated: true, reveal: true)
                if let focusNew { focusWindow(focusNew) }
            }
        }
    }

    /// Moves windows the user sent to another Space (Mission Control, or a
    /// window menu) onto that Space's strip.
    private func reassignSpaces() {
        for key in visibleKeys {
            guard let display = display(forKey: key), let strip = strips[key] else { continue }
            var changed = false
            for id in strip.allWindows {
                let spaces = Spaces.spaces(for: id)
                guard !spaces.isEmpty, !spaces.contains(display.space), let w = windows[id] else { continue }
                let target = displays.first(where: { spaces.contains($0.space) }).map(\.stripKey) ?? "\(display.uuid)|\(spaces[0])"
                guard target != key else { continue }
                let width = strips[key]?.locate(id).map { strips[key]!.columns[$0.column].width } ?? 0.5
                removeFromStrips(id)
                var t = strips[target] ?? Strip()
                t.insert(w.id, width: width, at: t.columns.count, focus: false)
                strips[target] = t
                changed = true
                log("window \(id) moved to another Space")
            }
            if changed { relayout(key, animated: true, reveal: true) }
        }
    }

    /// Decides whether an Accessibility element is a window Roller should
    /// know about, and registers it.
    private func candidate(_ el: AXUIElement, pid: pid_t) -> (ManagedWindow, CGRect)? {
        guard el.role == kAXWindowRole as String,
              el.subrole == kAXStandardWindowSubrole as String,
              let id = el.windowID, windows[id] == nil,
              let frame = el.frame else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        let w = ManagedWindow(id: id, element: el, pid: pid, bundleID: app.bundleIdentifier, title: el.title)
        observers[pid]?.watch(el)
        windows[id] = w
        if el.isMinimized { w.minimized = true; return nil }
        if el.isFullscreen { w.fullscreen = true; return nil }
        if el.isFixedSize || rule(for: w)?.floating == true || pendingFloating.contains(where: { $0.id == id }) {
            w.floating = true
        }
        if config.ignoredDisplays.contains(displayFor(frame: frame).uuid) { w.onIgnoredDisplay = true }
        return (w, frame)
    }

    private func rule(for w: ManagedWindow) -> WindowRule? {
        config.rules.first { $0.matches(bundleID: w.bundleID, title: w.title) }
    }

    private func initialWidth(frame: CGRect, params p: LayoutParams?) -> Double {
        if config.defaultColumnWidth > 0 { return config.defaultColumnWidth }
        guard let p else { return 0.5 }
        return Layout.fraction(forWidth: Double(frame.width), p)
    }

    /// Puts a (new, unminimized, unhidden or unfloated) window on a strip.
    private func place(_ w: ManagedWindow, focus: Bool, at index: Int? = nil) {
        guard let frame = w.element.frame else { return }
        let key = stripKeyFor(frame: frame, window: w)
        guard let display = display(forKey: key) else { return }
        var strip = strips[key] ?? Strip()
        guard !strip.contains(w.id) else { return }
        let p = params(display)
        let slot = rule(for: w)?.slot.map { $0 - 1 }
        strip.insert(w.id, width: initialWidth(frame: frame, params: p), at: index ?? slot, focus: focus)
        animator.seed(w.id, frame: frame)
        strips[key] = strip
        relayout(key, animated: true, reveal: focus)
        if focus { focusWindow(w.id) }
    }

    private func newWindow(_ el: AXUIElement, pid: pid_t) {
        guard status == .running, let (w, _) = candidate(el, pid: pid) else { return }
        log("new window \(w.id) \(w.bundleID ?? "?") \"\(w.title)\"\(w.floating ? " (floating)" : "")")
        guard !w.floating, !w.onIgnoredDisplay else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let launchedRecently = recentLaunches[pid].map { Date().timeIntervalSince($0) < 5 } ?? false
        let takeFocus = front || launchedRecently
        if !takeFocus, let keep = lastFocused {
            stealGuard = (w.id, keep, Date().addingTimeInterval(1.5))
        }
        place(w, focus: takeFocus)
    }

    // MARK: - Accessibility events

    private func axEvent(_ n: String, _ el: AXUIElement, _ pid: pid_t) {
        guard status == .running else { return }
        switch n {
        case kAXWindowCreatedNotification:
            // Give the window a moment to finish setting itself up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.newWindow(el, pid: pid)
                // Some windows only become standard windows a little later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.newWindow(el, pid: pid) }
            }
        case kAXUIElementDestroyedNotification:
            guard let w = window(for: el, pid: pid) else { return }
            windowClosed(w)
        case kAXFocusedWindowChangedNotification:
            syncFocus()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let w = window(for: el, pid: pid) else { return }
            windowMovedOrResized(w, resized: n == kAXWindowResizedNotification)
        case kAXWindowMiniaturizedNotification:
            guard let w = window(for: el, pid: pid) else { return }
            w.minimized = true
            removeAndRelayout(w.id)
        case kAXWindowDeminiaturizedNotification:
            guard let w = window(for: el, pid: pid) else { return }
            w.minimized = false
            if !w.floating && !w.onIgnoredDisplay { place(w, focus: true) }
        case kAXApplicationHiddenNotification:
            for w in windows.values where w.pid == pid {
                w.appHidden = true
                removeAndRelayout(w.id)
            }
        case kAXApplicationShownNotification:
            for w in windows.values where w.pid == pid && w.appHidden {
                w.appHidden = false
                if !w.floating && !w.minimized && !w.onIgnoredDisplay { place(w, focus: false) }
            }
            syncFocus()
        case kAXTitleChangedNotification:
            guard let w = window(for: el, pid: pid) else { return }
            w.title = el.title
            updateTabBars()
        default:
            break
        }
    }

    private func window(for el: AXUIElement, pid: pid_t) -> ManagedWindow? {
        if let id = el.windowID, let w = windows[id] { return w }
        return windows.values.first { $0.pid == pid && CFEqual($0.element, el) }
    }

    private func windowClosed(_ w: ManagedWindow) {
        let key = stripKey(of: w.id)
        let wasFocused = lastFocused == w.id
        log("window closed \(w.id)")
        forget(w.id)
        guard let key else { return }
        relayout(key, animated: true, reveal: true)
        // Focus the neighbour that took its place, like on Linux.
        if wasFocused, let next = strips[key]?.focusedWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusWindow(next) }
        }
    }

    private func removeAndRelayout(_ id: WindowID) {
        guard let key = stripKey(of: id) else { return }
        removeFromStrips(id)
        relayout(key, animated: true, reveal: true)
    }

    private func windowMovedOrResized(_ w: ManagedWindow, resized: Bool) {
        if resized, w.element.isFullscreen {
            // Native full screen: leave it alone until it comes back.
            if !w.fullscreen {
                w.fullscreen = true
                removeAndRelayout(w.id)
            }
            return
        }
        if w.fullscreen {
            w.fullscreen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.windows[w.id] != nil, !w.floating else { return }
                self.place(w, focus: true)
            }
            return
        }
        guard let key = stripKey(of: w.id) else { return }
        if mouseDown {
            // The user is dragging or resizing it; handled on mouse up.
            if !animator.recentlySet(w.id, within: 0.15) {
                dragWindow = w.id
                if resized { dragResized = true }
            }
            return
        }
        guard !animator.recentlySet(w.id) else { return }
        // An app that keeps putting its window back where it wants it wins:
        // the window floats instead of fighting forever.
        let now = Date()
        fights[w.id] = (fights[w.id] ?? []).filter { now.timeIntervalSince($0) < 5 } + [now]
        if fights[w.id]!.count > 6 {
            fights[w.id] = nil
            log("window \(w.id) keeps moving itself; floating it")
            w.floating = true
            bringOnScreen(w.id)
            removeAndRelayout(w.id)
            return
        }
        // The app moved its own window: put it back where it belongs.
        animator.invalidate(w.id)
        if let f = w.element.frame { animator.seed(w.id, frame: f) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.relayout(key, animated: false, reveal: false)
        }
    }

    private func sizeMismatch(_ id: WindowID, asked: CGSize, actual: CGSize) {
        guard let key = stripKey(of: id) else { return }
        if actual.width > asked.width + 2 {
            // The app has a minimum width; lay the column out around it.
            let old = minWidths[id] ?? 0
            guard actual.width > old + 1 else { return }
            minWidths[id] = Double(actual.width)
            log("window \(id) needs at least \(Int(actual.width)) points")
            relayout(key, animated: true, reveal: false)
        }
    }

    // MARK: - Focus

    /// Brings Roller's view in line with the window macOS says is focused.
    func syncFocus() {
        guard status == .running, let front = NSWorkspace.shared.frontmostApplication else { return }
        let app = AX.app(front.processIdentifier)
        guard let el = app.focusedWindow, let id = el.windowID else { return }
        if windows[id] == nil, observers[front.processIdentifier] != nil {
            newWindow(el, pid: front.processIdentifier)
        }
        if let g = stealGuard {
            if Date() > g.until {
                stealGuard = nil
            } else if g.newWindow == id, windows[g.keep] != nil {
                // A background app tried to take focus with a new window.
                stealGuard = nil
                focusWindow(g.keep)
                return
            }
        }
        lastFocused = id
        if let key = stripKey(of: id), var strip = strips[key] {
            if strip.focusedWindow != id {
                strip.focus(window: id)
                strips[key] = strip
                let reveal = noRevealFor != id
                relayout(key, animated: true, reveal: reveal)
            }
        }
        noRevealFor = nil
        updateDecorations()
    }

    /// Focuses a window (raising it and its app).
    func focusWindow(_ id: WindowID, warpMouse: Bool = false) {
        guard let w = windows[id] else { return }
        lastFocused = id
        Private.focus(pid: w.pid, window: id, element: w.element)
        if warpMouse && config.mouseFollowsFocus, let key = stripKey(of: id),
           let display = display(forKey: key), let strip = strips[key],
           let f = Layout.frames(strip, params(display))[id] {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
        }
        updateDecorations()
    }

    var focusedWindowID: WindowID? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = AX.app(front.processIdentifier).focusedWindow?.windowID, windows[id] != nil {
            return id
        }
        return lastFocused
    }

    // MARK: - Strips and displays

    private var visibleKeys: [String] {
        displays.filter { !config.ignoredDisplays.contains($0.uuid) && !$0.spaceIsFullscreen }.map(\.stripKey)
    }

    func stripKey(of id: WindowID) -> String? {
        strips.first(where: { $0.value.contains(id) })?.key
    }

    private func removeFromStrips(_ id: WindowID) {
        for (k, var s) in strips where s.contains(id) {
            s.remove(id)
            strips[k] = s
        }
    }

    func display(forKey key: String) -> Display? {
        displays.first { $0.stripKey == key }
    }

    private func displayFor(frame: CGRect) -> Display {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let d = displays.first(where: { $0.frame.contains(center) }) { return d }
        let best = displays.max { a, b in
            a.frame.intersection(frame).width * a.frame.intersection(frame).height <
            b.frame.intersection(frame).width * b.frame.intersection(frame).height
        }
        return best ?? displays.first ?? Display(id: 0, uuid: "none", name: "", frame: frame, visibleFrame: frame, frameBelowMenuBar: frame)
    }

    private func displayFor(window w: ManagedWindow) -> Display {
        if let key = stripKey(of: w.id), let d = display(forKey: key) { return d }
        return displayFor(frame: w.element.frame ?? .zero)
    }

    private func stripKeyFor(frame: CGRect, window: ManagedWindow) -> String {
        var display = displayFor(frame: frame)
        // Prefer the Space the window server says the window is on.
        let spaces = Spaces.spaces(for: window.id)
        if let s = spaces.first, !spaces.contains(display.space) {
            if let other = displays.first(where: { spaces.contains($0.space) }) { display = other }
            else { return "\(display.uuid)|\(s)" }
        }
        return display.stripKey
    }

    private var displayUnderMouse: Display? {
        let m = Geometry.mouseLocation
        return displays.first { $0.frame.contains(m) } ?? displays.first
    }

    func params(_ display: Display) -> LayoutParams {
        LayoutParams(area: display.workingArea(config), gap: config.gapInner, tabBarHeight: config.tabBarHeight,
                     centerMode: config.centerFocusedColumn, minWidths: minWidths)
    }

    /// The strip actions apply to: the one holding the focused window, else
    /// the one under the mouse.
    private var activeKey: String? {
        if let id = focusedWindowID, let key = stripKey(of: id), visibleKeys.contains(key) { return key }
        if let d = displayUnderMouse, visibleKeys.contains(d.stripKey) { return d.stripKey }
        return visibleKeys.first
    }

    /// Lays out one strip. With `reveal`, scrolls to show the focused column.
    func relayout(_ key: String, animated: Bool, reveal: Bool) {
        guard let display = display(forKey: key), var strip = strips[key], visibleKeys.contains(key) else { return }
        let p = params(display)
        if reveal { Layout.settle(&strip, p) }
        strips[key] = strip
        var targets: [WindowID: Animator.Target] = [:]
        for (id, frame) in Layout.frames(strip, p) {
            guard let w = windows[id] else { continue }
            targets[id] = .init(element: w.element, pid: w.pid, frame: frame, display: display.frame, neighbors: display.neighbors)
        }
        animator.move(targets, animated: animated)
        updateTabBars()
        session.scheduleSave { [weak self] in self?.snapshot() }
    }

    private func relayoutAll(animated: Bool) {
        for key in visibleKeys { relayout(key, animated: animated, reveal: true) }
    }

    // MARK: - Workspace notifications

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recentLaunches[app.processIdentifier] = Date()
            // Apps take a moment before they answer Accessibility.
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.status == .running else { return }
                    self.addApp(app)
                    self.scan(initial: false)
                }
            }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recentLaunches[app.processIdentifier] = nil
            self?.removeApp(pid: app.processIdentifier)
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.addApp(app) }
            self?.syncFocus()
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spacesChanged()
        })
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.displaysChanged() }
        })
    }

    private func spacesChanged() {
        guard status == .running else { return }
        displays = Display.all()
        scan(initial: false)
        relayoutAll(animated: false)
        syncFocus()
    }

    private func displaysChanged() {
        guard status == .running else { return }
        let oldUUIDs = Set(displays.map(\.uuid))
        displays = Display.all()
        let live = Set(displays.map(\.uuid))
        // Windows from a display that went away join the main display's strip.
        if let main = displays.first, oldUUIDs != live {
            for (key, strip) in strips where !live.contains(String(key.split(separator: "|").first ?? "")) {
                var target = strips[main.stripKey] ?? Strip()
                for c in strip.columns {
                    for id in c.windows { target.insert(id, width: c.width, at: target.columns.count, focus: false) }
                }
                strips[main.stripKey] = target
                strips[key] = nil
            }
        }
        minWidths.removeAll()
        relayoutAll(animated: false)
    }

    /// Periodic self-healing: picks up windows and apps whose notifications
    /// were missed and drops windows that no longer exist.
    private func reconcile() {
        guard status == .running else { return }
        guard AX.isTrusted else {
            log("Accessibility permission was revoked")
            stop()
            status = .needsPermission
            start()
            return
        }
        for app in NSWorkspace.shared.runningApplications where observers[app.processIdentifier] == nil {
            addApp(app)
        }
        for pid in observers.keys where NSRunningApplication(processIdentifier: pid) == nil {
            removeApp(pid: pid)
        }
        let alive = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        if !alive.isEmpty {
            for id in Array(windows.keys) where !alive.contains(id) {
                let key = stripKey(of: id)
                forget(id)
                if let key { relayout(key, animated: true, reveal: true) }
            }
        }
        // Full-screen windows that came back without telling us.
        for w in windows.values where w.fullscreen && !w.element.isFullscreen && !w.minimized {
            w.fullscreen = false
            if !w.floating { place(w, focus: false) }
        }
        let newDisplays = Display.all()
        if newDisplays != displays {
            displays = newDisplays
            relayoutAll(animated: false)
        }
        scan(initial: false)
    }

    // MARK: - Actions

    /// Runs an action. Returns a short status line (for the CLI).
    @discardableResult
    func perform(_ action: Action) -> String {
        switch action {
        case .toggleManager:
            if status == .running { stop() } else { start() }
            return statusText
        case .start:
            start(); return statusText
        case .stop:
            stop(); return statusText
        case .reloadConfig:
            ConfigStore.shared.load(); return "ok"
        case .openSettings:
            AppDelegate.shared?.openSettings(); return "ok"
        default:
            break
        }
        guard status == .running else { return "error: Roller is not running" }

        if action == .toggleFloat { return toggleFloat() }
        if action == .sendToNextDisplay { return sendToNextDisplay() }
        if action == .focusNextDisplay { return focusNextDisplay() }

        guard let key = activeKey, var strip = strips[key], let display = display(forKey: key) else {
            return "error: no strip"
        }
        let p = params(display)
        let before = strip.focusedWindow
        var reveal = true
        var changed = true

        switch action {
        case .focusLeft: changed = strip.focusColumn(by: -1)
        case .focusRight: changed = strip.focusColumn(by: 1)
        case .focusUp: changed = strip.focusRow(by: -1)
        case .focusDown: changed = strip.focusRow(by: 1)
        case .focusFirst: changed = strip.focusFirst()
        case .focusLast: changed = strip.focusLast()
        case .moveLeft: changed = strip.moveColumn(by: -1)
        case .moveRight: changed = strip.moveColumn(by: 1)
        case .moveUp: changed = strip.moveRow(by: -1)
        case .moveDown: changed = strip.moveRow(by: 1)
        case .moveToFirst: changed = strip.moveToFirst()
        case .moveToLast: changed = strip.moveToLast()
        case .cycleWidth: changed = strip.cycleWidth(presets: config.presetColumnWidths)
        case .fullWidth: changed = strip.toggleFullWidth()
        case .centerColumn:
            Layout.centerFocus(&strip, p)
            reveal = false
        case .wider: changed = strip.resizeWidth(by: config.widthStep)
        case .narrower:
            if let id = strip.focusedWindow { minWidths[id] = nil }
            changed = strip.resizeWidth(by: -config.widthStep)
        case .taller: changed = strip.resizeHeight(by: config.heightStep)
        case .shorter: changed = strip.resizeHeight(by: -config.heightStep)
        case .equalizeHeights: changed = strip.equalizeHeights()
        case .stackIntoLeft: changed = strip.stack(into: -1)
        case .stackIntoRight: changed = strip.stack(into: 1)
        case .popOutRight: changed = strip.popOut(1)
        case .popOutLeft: changed = strip.popOut(-1)
        case .toggleTabbed: changed = strip.toggleTabbed()
        default:
            if let place = action.place {
                changed = action.group == .focus ? strip.focusPlace(place) : strip.moveToPlace(place)
            }
        }
        strips[key] = strip
        relayout(key, animated: true, reveal: reveal)
        if let after = strips[key]?.focusedWindow, after != before || action.group == .focus || action.group == .stacks {
            focusWindow(after, warpMouse: after != before)
        }
        showMinimap(key)
        return changed ? "ok" : "ok (nothing to do)"
    }

    private func toggleFloat() -> String {
        guard let id = focusedWindowID, let w = windows[id] else { return "error: no focused window" }
        if let key = stripKey(of: id) {
            removeFromStrips(id)
            w.floating = true
            relayout(key, animated: true, reveal: true)
            // Float it in the middle of the screen at a comfortable size.
            if let display = display(forKey: key), let f = animator.current[id] {
                let area = display.workingArea(config)
                let size = CGSize(width: min(f.width, area.width * 0.7), height: min(f.height, area.height * 0.8))
                let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
                animator.forget(id)
                w.element.setSize(frame.size)
                w.element.setPosition(frame.origin)
                w.element.setSize(frame.size)
            }
            focusWindow(id)
            return "floating"
        }
        w.floating = false
        place(w, focus: true)
        return "tiled"
    }

    private var sortedDisplays: [Display] {
        displays.filter { !config.ignoredDisplays.contains($0.uuid) }
            .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    private func nextDisplay(after key: String) -> Display? {
        let list = sortedDisplays
        guard list.count > 1, let i = list.firstIndex(where: { $0.stripKey == key }) else { return nil }
        return list[(i + 1) % list.count]
    }

    private func sendToNextDisplay() -> String {
        guard let id = focusedWindowID, let w = windows[id], let key = stripKey(of: id),
              let target = nextDisplay(after: key), var from = strips[key] else { return "error: nothing to send" }
        let width = from.locate(id).map { from.columns[$0.column].width } ?? 0.5
        from.remove(id)
        strips[key] = from
        var to = strips[target.stripKey] ?? Strip()
        to.insert(id, width: width)
        strips[target.stripKey] = to
        // Start the slide from the edge of the new display.
        if let f = animator.current[id] {
            animator.seed(id, frame: f)
        }
        relayout(key, animated: true, reveal: true)
        relayout(target.stripKey, animated: true, reveal: true)
        focusWindow(w.id, warpMouse: true)
        showMinimap(target.stripKey)
        return "ok"
    }

    private func focusNextDisplay() -> String {
        let key = activeKey ?? ""
        guard let target = nextDisplay(after: key) ?? sortedDisplays.first(where: { $0.stripKey != key }) else { return "error: one display" }
        if let id = strips[target.stripKey]?.focusedWindow {
            focusWindow(id, warpMouse: true)
        } else {
            CGWarpMouseCursorPosition(CGPoint(x: target.frame.midX, y: target.frame.midY))
        }
        return "ok"
    }

    var statusText: String {
        switch status {
        case .running: return "running"
        case .stopped: return "stopped"
        case .needsPermission: return "needs Accessibility permission"
        }
    }

    /// JSON description of every strip (for `roller list`).
    func listJSON() -> String {
        var out: [[String: Any]] = []
        for (key, strip) in strips.sorted(by: { $0.key < $1.key }) {
            let display = display(forKey: key)
            out.append([
                "key": key,
                "display": display?.name ?? "(other Space)",
                "visible": visibleKeys.contains(key),
                "focus": strip.focus,
                "offset": strip.offset,
                "columns": strip.columns.map { c in
                    [
                        "width": c.width,
                        "tabbed": c.tabbed,
                        "windows": c.windows.map { id in
                            ["id": id, "app": windows[id]?.bundleID ?? "", "title": windows[id]?.title ?? ""] as [String: Any]
                        },
                    ] as [String: Any]
                },
            ])
        }
        let floating = windows.values.filter(\.floating).map { ["id": $0.id, "app": $0.bundleID ?? "", "title": $0.title] as [String: Any] }
        let obj: [String: Any] = ["status": statusText, "strips": out, "floating": floating]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Trackpad swipe

    private func swipeBegan() {
        guard status == .running, let d = displayUnderMouse, visibleKeys.contains(d.stripKey), strips[d.stripKey]?.isEmpty == false else {
            swipeKey = nil
            return
        }
        swipeKey = d.stripKey
        // How many points one trackpad width moves the strip.
        swipeVelocityScale = Double(d.workingArea(config).width) * 1.6 * config.swipeSensitivity
    }

    private func swipeMoved(_ dx: Double) {
        guard let key = swipeKey, var strip = strips[key], let display = display(forKey: key) else { return }
        let p = params(display)
        let delta = dx * swipeVelocityScale * (config.swipeNatural ? -1 : 1)
        // Rubber band past the ends.
        let maxOffset = max(0, Layout.totalWidth(strip, p) - Double(p.area.width))
        var next = strip.offset + delta
        if next < 0 && delta < 0 { next = strip.offset + delta * 0.3 }
        if next > maxOffset && delta > 0 { next = strip.offset + delta * 0.3 }
        strip.offset = next
        strips[key] = strip
        relayout(key, animated: false, reveal: false)
        showMinimap(key)
    }

    private func swipeEnded(velocity: Double) {
        guard let key = swipeKey, var strip = strips[key], let display = display(forKey: key) else { return }
        swipeKey = nil
        let p = params(display)
        let v = velocity * swipeVelocityScale * (config.swipeNatural ? -1 : 1)
        let projected = strip.offset + v * 0.18
        guard let snap = Layout.snap(strip, p, projectedOffset: projected) else { return }
        strip.offset = snap.offset
        let changedFocus = strip.focus != snap.column
        if changedFocus {
            strip.previousFocus = strip.focus
            strip.focus = snap.column
        }
        strips[key] = strip
        relayout(key, animated: true, reveal: false)
        if let id = strip.focusedWindow, changedFocus || lastFocused != id {
            noRevealFor = id
            focusWindow(id)
        }
        showMinimap(key)
    }

    // MARK: - Mouse: drag to reorder, resize, focus follows mouse

    private func installMouseMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.mouseDown = true
            self?.dragWindow = nil
            self?.dragResized = false
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.mouseUp()
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.mouseMoved()
        }) { mouseMonitors.append(m) }
    }

    private func mouseUp() {
        mouseDown = false
        guard let id = dragWindow, let w = windows[id], let key = stripKey(of: id) else { return }
        dragWindow = nil
        let resized = dragResized
        dragResized = false
        // Let the last move notification arrive first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let frame = w.element.frame else { return }
            if resized {
                self.userResized(id, key: key, frame: frame)
            } else {
                self.userMoved(id, key: key, frame: frame)
            }
        }
    }

    /// Widths you set with the mouse are widths that stay.
    private func userResized(_ id: WindowID, key: String, frame: CGRect) {
        guard var strip = strips[key], let display = display(forKey: key), let (c, _) = strip.locate(id) else { return }
        let p = params(display)
        minWidths[id] = nil
        strip.setWidth(Layout.fraction(forWidth: Double(frame.width), p), column: c)
        if strip.columns[c].windows.count > 1 && !strip.columns[c].tabbed {
            let n = Double(strip.columns[c].windows.count)
            let avail = Double(p.area.height) - p.gap * (n - 1)
            strip.setHeightFraction(Double(frame.height) / avail, window: id)
        }
        strip.focus(window: id)
        strips[key] = strip
        animator.invalidate(id)
        animator.seed(id, frame: frame)
        relayout(key, animated: true, reveal: true)
    }

    /// Drag to reorder: drop a window onto another column to move it there.
    private func userMoved(_ id: WindowID, key: String, frame: CGRect) {
        animator.invalidate(id)
        animator.forget(id)
        animator.seed(id, frame: frame)
        guard config.dragToReorder else {
            relayout(key, animated: true, reveal: false)
            return
        }
        let mouse = Geometry.mouseLocation
        let targetDisplay = displays.first { $0.frame.contains(mouse) }
        if let td = targetDisplay, td.stripKey != key, visibleKeys.contains(td.stripKey),
           var from = strips[key] {
            // Dropped on another display: join that strip where it landed.
            let width = from.locate(id).map { from.columns[$0.column].width } ?? 0.5
            from.remove(id)
            strips[key] = from
            var to = strips[td.stripKey] ?? Strip()
            let idx = Layout.columnIndex(atScreenX: Double(mouse.x), to, params(td)).map { $0 + 1 } ?? 0
            to.insert(id, width: width, at: idx)
            strips[td.stripKey] = to
            relayout(key, animated: true, reveal: true)
            relayout(td.stripKey, animated: true, reveal: true)
            return
        }
        guard var strip = strips[key], let display = display(forKey: key) else { return }
        let p = params(display)
        if let target = Layout.columnIndex(atScreenX: Double(mouse.x), strip, p),
           let (c, _) = strip.locate(id), target != c || strip.columns[c].windows.count > 1 {
            if target == c {
                strip.focus(window: id)
            } else {
                strip.moveWindow(id, toColumnIndex: target)
            }
        } else {
            strip.focus(window: id)
        }
        strips[key] = strip
        relayout(key, animated: true, reveal: true)
    }

    private func mouseMoved() {
        guard config.focusFollowsMouse, status == .running, !mouseDown, swipeKey == nil, !animator.isAnimating else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.focusUnderMouse() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func focusUnderMouse() {
        let m = Geometry.mouseLocation
        // Topmost normal-level window under the pointer.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(m) else { continue }
            let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() { return }
            guard windows[id] != nil, stripKey(of: id) != nil, !animator.hidden.contains(id), id != focusedWindowID else { return }
            noRevealFor = id
            focusWindow(id)
            return
        }
    }

    // MARK: - Decorations

    private func updateDecorations() {
        guard status == .running else { return }
        let id = lastFocused
        var frame: CGRect?
        if let id, let w = windows[id] {
            if stripKey(of: id) != nil {
                frame = animator.hidden.contains(id) ? nil : animator.applied[id]
            } else if w.floating, !animator.isAnimating {
                frame = w.element.frame
            }
        }
        if config.focusBorder, let id, let frame {
            border.show(around: frame, window: id, config: config)
        } else {
            border.hide()
        }
        if config.dimInactive, let id, let frame {
            let d = displayFor(frame: frame)
            dim.show(on: d, below: id, opacity: config.dimInactiveOpacity)
        } else {
            dim.hide()
        }
        updateTabBars()
    }

    private func updateTabBars() {
        var keep = Set<WindowID>()
        if status == .running {
            for key in visibleKeys {
                guard let strip = strips[key] else { continue }
                for c in strip.columns where c.tabbed {
                    guard let first = c.windows.first, let active = c.activeWindow,
                          !animator.hidden.contains(active), let f = animator.applied[active] else { continue }
                    keep.insert(first)
                    let bar = tabBars[first] ?? {
                        let b = TabBar()
                        b.onSelect = { [weak self] id in self?.selectTab(id) }
                        tabBars[first] = b
                        return b
                    }()
                    let h = config.tabBarHeight - min(config.gapInner, 6)
                    let barFrame = CGRect(x: f.minX, y: f.minY - config.tabBarHeight, width: f.width, height: h)
                    bar.update(tabs: c.windows.map { ($0, windows[$0]?.title ?? "") }, active: c.active,
                               frame: barFrame, above: active)
                }
            }
        }
        for (k, bar) in tabBars where !keep.contains(k) {
            bar.close()
            tabBars[k] = nil
        }
    }

    private func selectTab(_ id: WindowID) {
        guard let key = stripKey(of: id), var strip = strips[key] else { return }
        strip.focus(window: id)
        strips[key] = strip
        relayout(key, animated: true, reveal: true)
        focusWindow(id)
    }

    private func showMinimap(_ key: String) {
        guard config.minimap, let strip = strips[key], !strip.isEmpty, let display = display(forKey: key) else { return }
        let p = params(display)
        let spans = Layout.spans(strip, p)
        let cols = zip(strip.columns, spans).map { c, s in (x: s.x, w: s.w, rows: c.heightFractions, tabbed: c.tabbed) }
        minimap.show(.init(columns: cols, focus: strip.focus, focusRow: strip.focusedColumn?.active ?? 0,
                           viewX: strip.offset, viewW: Double(p.area.width)), on: display)
    }

    // MARK: - Session

    private func snapshot() -> SavedSession {
        let saved = strips.map { key, strip in
            SavedStrip(key: key, columns: strip.columns.map { c in
                SavedColumn(windows: c.windows.compactMap { windows[$0]?.saved }, heights: c.heights, width: c.width, tabbed: c.tabbed)
            }, focus: strip.focus)
        }
        // Strips on Spaces we haven't visited since starting keep their saved layout.
        let unvisited = pendingRestore.filter { strips[$0.key] == nil }.map(\.value)
        let floating = windows.values.filter(\.floating).map(\.saved)
        return SavedSession(strips: saved + unvisited, floating: floating)
    }
}

/// Saves column order, widths, stacks and tabs so they survive a restart.
final class SessionStore {
    private var work: DispatchWorkItem?
    private var url: URL { IPC.supportDirectory.appendingPathComponent("session.json") }

    func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    func scheduleSave(_ make: @escaping () -> SavedSession?) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in if let s = make() { self?.save(s) } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func save(_ s: SavedSession) {
        do {
            try FileManager.default.createDirectory(at: IPC.supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(s)
            try data.write(to: url, options: .atomic)
        } catch {
            log("could not save session: \(error)")
        }
    }
}
