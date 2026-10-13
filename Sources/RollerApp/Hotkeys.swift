import AppKit
import Carbon.HIToolbox
import RollerCore

/// Global shortcuts through Carbon's RegisterEventHotKey. It needs no
/// Input Monitoring permission and only ever sees the registered combos.
final class Hotkeys {
    static let shared = Hotkeys()

    var handler: ((Action) -> Void)?
    /// While recording a shortcut in settings, hotkeys are unregistered so
    /// the recorder sees combos that are already bound.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { unregisterAll() } else { Engine.shared.registerHotkeys() }
        }
    }

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private(set) var failures: [Shortcut] = []

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            Hotkeys.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        guard !suspended, let action = actions[id] else { return }
        handler?(action)
    }

    /// Registers `bindings`. When `only` is given, just those actions are
    /// registered (used while Roller is stopped, to keep the start shortcut).
    func register(_ bindings: [Action: [Shortcut]], only: Set<Action>? = nil) {
        installHandler()
        unregisterAll()
        failures = []
        var seen = Set<Shortcut>()
        for action in Action.allCases {
            if let only, !only.contains(action) { continue }
            for shortcut in bindings[action] ?? [] where !seen.contains(shortcut) {
                seen.insert(shortcut)
                var ref: EventHotKeyRef?
                let id = nextID
                nextID &+= 1
                let status = RegisterEventHotKey(shortcut.keyCode, Hotkeys.carbonModifiers(shortcut.modifiers),
                                                 EventHotKeyID(signature: OSType(0x524F4C52), id: id), // 'ROLR'
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    refs.append(ref)
                    actions[id] = action
                } else {
                    failures.append(shortcut)
                    log("hotkey \(shortcut.string) for \(action.rawValue) could not be registered (\(status)); another app may own it")
                }
            }
        }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    static func carbonModifiers(_ m: Shortcut.Modifiers) -> UInt32 {
        var c: UInt32 = 0
        if m.contains(.command) { c |= UInt32(cmdKey) }
        if m.contains(.option) { c |= UInt32(optionKey) }
        if m.contains(.control) { c |= UInt32(controlKey) }
        if m.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }
}

/// Shows key codes as the characters of the current keyboard layout, so
/// AZERTY, QWERTZ and Dvorak users see their own keys.
enum KeyDisplay {
    static func character(for keyCode: UInt32) -> String {
        if let s = KeyCodes.symbol(forCode: keyCode) { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return KeyCodes.name(forCode: keyCode).uppercased()
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return KeyCodes.name(forCode: keyCode).uppercased() }
        let s = String(utf16CodeUnits: chars, count: length).uppercased()
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? KeyCodes.name(forCode: keyCode).uppercased() : s
    }

    static func string(_ s: Shortcut) -> String {
        s.modifierSymbols + character(for: s.keyCode)
    }
}
