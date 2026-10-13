import AppKit
import ApplicationServices

/// Maps an Accessibility window element to its window server number. Private
/// but stable since macOS 10.x and used by every Mac window manager.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility permission prompt.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1.0)
        return el
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var title: String { attribute(kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { attribute(kAXMinimizedAttribute) ?? false }
    var isFullscreen: Bool { attribute("AXFullScreen") ?? false }
    var windows: [AXUIElement] { attribute(kAXWindowsAttribute) ?? [] }
    var focusedWindow: AXUIElement? {
        guard let v: CFTypeRef = attribute(kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }

    var pid: pid_t? {
        var p: pid_t = 0
        guard AXUIElementGetPid(self, &p) == .success else { return nil }
        return p
    }

    var position: CGPoint? {
        guard let v: CFTypeRef = attribute(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v: CFTypeRef = attribute(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return set(kAXPositionAttribute, v)
    }

    @discardableResult
    func setSize(_ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return set(kAXSizeAttribute, v)
    }

    /// True for windows with a disabled zoom button or a fixed size, such as
    /// Calculator. Those float automatically.
    var isFixedSize: Bool {
        if !isSettable(kAXSizeAttribute) { return true }
        if let zoom: CFTypeRef = attribute(kAXZoomButtonAttribute), CFGetTypeID(zoom) == AXUIElementGetTypeID() {
            let enabled: Bool? = (zoom as! AXUIElement).attribute(kAXEnabledAttribute)
            if enabled == false { return true }
        }
        return false
    }

    func raise() {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}
