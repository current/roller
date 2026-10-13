import AppKit
import ApplicationServices

/// Listens to one app's Accessibility notifications: windows appearing,
/// closing, moving, resizing, minimizing, focus changes and so on.
final class AppObserver {
    let pid: pid_t
    let app: AXUIElement
    private var observer: AXObserver?
    private var watched: [AXUIElement] = []
    var onEvent: ((String, AXUIElement, pid_t) -> Void)?

    static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]

    init?(pid: pid_t) {
        self.pid = pid
        app = AX.app(pid)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.onEvent?(notification as String, element, me.pid)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = false
        for n in AppObserver.appNotifications {
            if AXObserverAddNotification(obs, app, n as CFString, refcon) == .success { ok = true }
        }
        // Apps that aren't ready yet (still launching) refuse everything;
        // the engine retries later.
        guard ok else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    func watch(_ window: AXUIElement) {
        guard let observer, !watched.contains(where: { CFEqual($0, window) }) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in AppObserver.windowNotifications {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
        watched.append(window)
    }

    func unwatch(_ window: AXUIElement) {
        guard let observer else { return }
        for n in AppObserver.windowNotifications {
            AXObserverRemoveNotification(observer, window, n as CFString)
        }
        watched.removeAll { CFEqual($0, window) }
    }

    func invalidate() {
        guard let observer else { return }
        for w in watched { for n in AppObserver.windowNotifications { AXObserverRemoveNotification(observer, w, n as CFString) } }
        for n in AppObserver.appNotifications { AXObserverRemoveNotification(observer, app, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        watched.removeAll()
        self.observer = nil
    }

    deinit { invalidate() }
}
