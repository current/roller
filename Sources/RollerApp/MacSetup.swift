import AppKit
import RollerCore

/// Checks the macOS settings that decide whether every feature works. It
/// only reads settings; the user changes them in System Settings.
enum MacSetup {
    enum State { case ok, warning, info }

    struct Check: Identifiable {
        let id: String
        let title: String
        let detail: String
        let state: State
        let settingsURL: String?
    }

    static let otherWindowManagers: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.MrKai77.Loop": "Loop",
        "com.manytricks.Moom": "Moom",
        "com.divisiblebyzero.Spectacle": "Spectacle",
        "com.mizage.Divvy": "Divvy",
        "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace",
        "org.hammerspoon.Hammerspoon": "Hammerspoon",
        "co.highlyopinionated.swish": "Swish",
    ]

    /// Matched by executable or app name, for tools without a stable bundle ID.
    static let otherWindowManagerNames = ["yabai", "AeroSpace", "paneru", "komorebi", "OmniWM", "GlazeWM", "OneMenu", "ChainYourMac"]

    private static func pref(_ key: String, _ domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    private static func int(_ key: String, _ domains: [String]) -> Int? {
        for d in domains { if let v = pref(key, d) as? NSNumber { return v.intValue } }
        return nil
    }

    private static func bool(_ key: String, _ domain: String) -> Bool? {
        (pref(key, domain) as? NSNumber)?.boolValue
    }

    static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    static let trackpadURL = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    static let desktopURL = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    static let accessibilityPrivacyURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let pointerURL = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

    static func run(fingers: SwipeFingers) -> [Check] {
        var checks: [Check] = []

        checks.append(Check(
            id: "ax", title: "Accessibility permission",
            detail: AX.isTrusted ? "Roller can move and resize windows."
                : "Turn Roller on in Privacy & Security › Accessibility. If it is already on, remove it with – and add it again.",
            state: AX.isTrusted ? .ok : .warning, settingsURL: accessibilityPrivacyURL))

        // 2 = swipe between full-screen apps; 1 (three fingers only) = swipe between pages; 0 = off.
        let three = int("TrackpadThreeFingerHorizSwipeGesture", trackpadDomains) ?? 2
        let four = int("TrackpadFourFingerHorizSwipeGesture", trackpadDomains) ?? 2
        let threeDrag = int("TrackpadThreeFingerDrag", trackpadDomains) ?? 0
        switch fingers {
        case .off:
            checks.append(Check(id: "swipe", title: "Trackpad swipe", detail: "Swipe to scroll the strip is off. Use the keyboard, or pick 3 or 4 fingers in Trackpad & Mouse.", state: .info, settingsURL: nil))
        case .four, .five:
            let clash = four == 2 || three == 2
            checks.append(Check(
                id: "swipe", title: "Free up the \(fingers.rawValue)-finger swipe",
                detail: clash
                    ? "macOS also uses this swipe to switch desktops. In Trackpad › More Gestures, set “Swipe between full-screen applications” to Off. Switch desktops with ⌃← / ⌃→ instead."
                    : "macOS doesn't use this swipe; the strip gets it.",
                state: clash ? .warning : .ok, settingsURL: trackpadURL))
        case .three:
            let clash = three != 0
            checks.append(Check(
                id: "swipe", title: "Free up the 3-finger swipe",
                detail: clash
                    ? (three == 1
                        ? "“Swipe between pages” uses three fingers. Set it to “Scroll left or right with two fingers”."
                        : "“Swipe between full-screen applications” uses three fingers. Set it to four fingers.")
                    : "macOS doesn't use this swipe; the strip gets it.",
                state: clash ? .warning : .ok, settingsURL: trackpadURL))
            checks.append(Check(
                id: "drag", title: "Three Finger Drag",
                detail: threeDrag != 0 ? "Three Finger Drag is on, so a 3-finger swipe drags windows. Use 4 fingers for the strip, or turn it off in Accessibility › Pointer Control › Trackpad Options." : "Off, so it doesn't compete with the swipe.",
                state: threeDrag != 0 ? .warning : .ok, settingsURL: pointerURL))
        }

        let mru = bool("mru-spaces", "com.apple.dock") ?? true
        checks.append(Check(
            id: "mru", title: "Keep Spaces in order",
            detail: mru ? "Turn off “Automatically rearrange Spaces based on most recent use” in Desktop & Dock › Mission Control, so each strip stays where you left it."
                : "Spaces keep a fixed order.",
            state: mru ? .warning : .ok, settingsURL: desktopURL))

        let spans = bool("spans-displays", "com.apple.spaces") ?? false
        if NSScreen.screens.count > 1 || spans {
            checks.append(Check(
                id: "spans", title: "Displays have separate Spaces",
                detail: spans ? "Turn on “Displays have separate Spaces” in Desktop & Dock › Mission Control, then log out, so each display gets its own strip."
                    : "Each display has its own strip.",
                state: spans ? .warning : .ok, settingsURL: desktopURL))
        }

        let stage = bool("GloballyEnabled", "com.apple.WindowManager") ?? false
        checks.append(Check(
            id: "stage", title: "Stage Manager",
            detail: stage ? "Stage Manager moves and resizes windows too. Turn it off in Desktop & Dock." : "Off.",
            state: stage ? .warning : .ok, settingsURL: desktopURL))

        if #available(macOS 15, *) {
            let edge = bool("EnableTilingByEdgeDrag", "com.apple.WindowManager") ?? true
            let top = bool("EnableTopTilingByEdgeDrag", "com.apple.WindowManager") ?? true
            let opt = bool("EnableTilingOptionAccelerator", "com.apple.WindowManager") ?? true
            let on = [edge ? "drag to screen edges" : nil, top ? "drag to the menu bar" : nil, opt ? "hold ⌥ while dragging" : nil].compactMap { $0 }
            checks.append(Check(
                id: "tiling", title: "macOS window tiling",
                detail: on.isEmpty ? "Off, so dragging a window reorders the strip."
                    : "macOS tiling (\(on.joined(separator: ", "))) resizes windows when you drag them. Turn these off in Desktop & Dock › Windows.",
                state: on.isEmpty ? .ok : .warning, settingsURL: desktopURL))
        }

        var others = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.flatMap { otherWindowManagers[$0] }
        }
        let names = Set(NSWorkspace.shared.runningApplications.flatMap { [$0.executableURL?.lastPathComponent, $0.localizedName].compactMap { $0 } })
        others += otherWindowManagerNames.filter { names.contains($0) && !others.contains($0) }
        checks.append(Check(
            id: "others", title: "Other window apps",
            detail: others.isEmpty ? "None running." : "\(Set(others).sorted().joined(separator: ", ")) also move windows. Quit it so the two don't fight.",
            state: others.isEmpty ? .ok : .warning, settingsURL: nil))

        return checks
    }
}
