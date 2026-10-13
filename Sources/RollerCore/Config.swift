import Foundation

/// A per-app window rule. Matches on bundle ID and/or a title regex (searched
/// anywhere in the title), then floats the window or gives it a fixed place.
public struct WindowRule: Equatable, Identifiable, Codable {
    public var id: String { name }
    public var name: String
    public var bundleID: String?
    public var title: String?
    public var floating: Bool
    /// 1-based place on the strip for new windows that match.
    public var slot: Int?

    public init(name: String, bundleID: String? = nil, title: String? = nil, floating: Bool = false, slot: Int? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.title = title
        self.floating = floating
        self.slot = slot
    }

    public var isValidRegex: Bool {
        guard let title, !title.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: title)) != nil
    }

    public func matches(bundleID b: String?, title t: String) -> Bool {
        let hasBundle = !(bundleID ?? "").isEmpty
        let hasTitle = !(title ?? "").isEmpty
        guard hasBundle || hasTitle else { return false }
        if hasBundle {
            guard let b, b.caseInsensitiveCompare(bundleID!) == .orderedSame else { return false }
        }
        if hasTitle {
            guard let re = try? NSRegularExpression(pattern: title!) else { return false }
            let range = NSRange(t.startIndex..., in: t)
            guard re.firstMatch(in: t, range: range) != nil else { return false }
        }
        return true
    }
}

public enum SwipeFingers: Int, CaseIterable, Codable {
    case off = 0, three = 3, four = 4, five = 5
}

/// All user settings. Every field maps to a key in the `[options]` table of
/// `~/.roller.toml`; bindings live in `[bindings]`, rules in `[windows.*]`.
public struct Config: Equatable {
    // Layout
    public var presetColumnWidths: [Double] = [0.25, 0.33, 0.5, 0.66, 0.75]
    /// Width for new windows as a fraction; 0 keeps the window's own width.
    public var defaultColumnWidth: Double = 0
    public var gapInner: Double = 8
    public var gapOuter: Double = 8
    public var centerFocusedColumn: CenterMode = .never
    public var dockAware: Bool = true
    public var widthStep: Double = 0.1
    public var heightStep: Double = 0.1

    // Appearance
    public var focusBorder: Bool = false
    public var focusBorderWidth: Double = 3
    public var focusBorderColor: String = "#3D8BFDFF"
    public var focusBorderRadius: Double = 10
    public var dimInactive: Bool = false
    public var dimInactiveOpacity: Double = 0.25
    public var minimap: Bool = true
    public var tabBarHeight: Double = 26

    // Motion
    public var animationDurationMs: Double = 500
    public var animationDamping: Double = 0.9

    // Mouse & trackpad
    public var focusFollowsMouse: Bool = false
    public var mouseFollowsFocus: Bool = false
    public var swipeGestureFingers: SwipeFingers = .four
    public var swipeNatural: Bool = true
    public var swipeSensitivity: Double = 1.0
    public var dragToReorder: Bool = true

    // App
    public var launchAtLogin: Bool = false
    public var ignoredDisplays: [String] = []
    public var onboardingDone: Bool = false
    /// Look for a newer release on GitHub once a day.
    public var checkForUpdates: Bool = true

    public var rules: [WindowRule] = []
    public var bindings: [Action: [Shortcut]] = Config.defaultBindings

    public init() {}

    public var spring: Spring { Spring(duration: animationDurationMs / 1000, damping: animationDamping) }

    // MARK: Defaults

    public static let defaultBindings: [Action: [Shortcut]] = {
        func s(_ list: String...) -> [Shortcut] { list.compactMap(Shortcut.init(string:)) }
        var b: [Action: [Shortcut]] = [
            .focusLeft: s("ctrl+alt+h", "ctrl+alt+left"),
            .focusDown: s("ctrl+alt+j", "ctrl+alt+down"),
            .focusUp: s("ctrl+alt+k", "ctrl+alt+up"),
            .focusRight: s("ctrl+alt+l", "ctrl+alt+right"),
            .focusFirst: s("ctrl+alt+cmd+left"),
            .focusLast: s("ctrl+alt+cmd+right"),
            .focusPlaceLast: s("ctrl+alt+9"),
            .moveLeft: s("ctrl+alt+shift+h", "ctrl+alt+shift+left"),
            .moveDown: s("ctrl+alt+shift+j", "ctrl+alt+shift+down"),
            .moveUp: s("ctrl+alt+shift+k", "ctrl+alt+shift+up"),
            .moveRight: s("ctrl+alt+shift+l", "ctrl+alt+shift+right"),
            .moveToFirst: s("ctrl+alt+cmd+shift+left"),
            .moveToLast: s("ctrl+alt+cmd+shift+right"),
            .moveToPlaceLast: s("ctrl+alt+shift+9"),
            .cycleWidth: s("ctrl+alt+r"),
            .fullWidth: s("ctrl+alt+f"),
            .centerColumn: s("ctrl+alt+c"),
            .wider: s("ctrl+alt+equal"),
            .narrower: s("ctrl+alt+minus"),
            .taller: s("ctrl+alt+shift+equal"),
            .shorter: s("ctrl+alt+shift+minus"),
            .equalizeHeights: s("ctrl+alt+0"),
            .stackIntoLeft: s("ctrl+alt+rightbracket"),
            .stackIntoRight: s("ctrl+alt+leftbracket"),
            .popOutRight: s("ctrl+alt+shift+rightbracket"),
            .popOutLeft: s("ctrl+alt+shift+leftbracket"),
            .toggleTabbed: s("ctrl+alt+shift+t"),
            .toggleFloat: s("ctrl+alt+t"),
            .sendToNextDisplay: s("ctrl+alt+n"),
            .toggleManager: s("ctrl+alt+q"),
        ]
        let focusPlaces: [Action] = [.focusPlace1, .focusPlace2, .focusPlace3, .focusPlace4, .focusPlace5, .focusPlace6, .focusPlace7, .focusPlace8]
        let movePlaces: [Action] = [.moveToPlace1, .moveToPlace2, .moveToPlace3, .moveToPlace4, .moveToPlace5, .moveToPlace6, .moveToPlace7, .moveToPlace8]
        for n in 1...8 {
            b[focusPlaces[n - 1]] = s("ctrl+alt+\(n)")
            b[movePlaces[n - 1]] = s("ctrl+alt+shift+\(n)")
        }
        return b
    }()

    /// Rules every install starts with.
    public static let defaultRules: [WindowRule] = [
        WindowRule(name: "pip", title: "Picture.*(in)?.*[Pp]icture", floating: true),
    ]

    public static var `default`: Config {
        var c = Config()
        c.rules = defaultRules
        return c
    }

    /// Finds which actions share a shortcut.
    public func conflicts() -> [Shortcut: [Action]] {
        var seen: [Shortcut: [Action]] = [:]
        for (a, list) in bindings { for s in list { seen[s, default: []].append(a) } }
        return seen.filter { $0.value.count > 1 }
    }

    /// Ensures every value is in its allowed range.
    public mutating func clamp() {
        presetColumnWidths = presetColumnWidths.map(Column.clampWidth).filter { $0 > 0 }
        if presetColumnWidths.isEmpty { presetColumnWidths = Config().presetColumnWidths }
        defaultColumnWidth = defaultColumnWidth <= 0 ? 0 : Column.clampWidth(defaultColumnWidth)
        gapInner = min(max(gapInner, 0), 64)
        gapOuter = min(max(gapOuter, 0), 64)
        widthStep = min(max(widthStep, 0.01), 0.5)
        heightStep = min(max(heightStep, 0.01), 0.5)
        focusBorderWidth = min(max(focusBorderWidth, 1), 20)
        focusBorderRadius = min(max(focusBorderRadius, 0), 40)
        dimInactiveOpacity = min(max(dimInactiveOpacity, 0.05), 0.9)
        tabBarHeight = min(max(tabBarHeight, 16), 48)
        animationDurationMs = min(max(animationDurationMs, 0), 2000)
        animationDamping = min(max(animationDamping, 0.1), 1)
        swipeSensitivity = min(max(swipeSensitivity, 0.1), 5)
        if RGBA(hex: focusBorderColor) == nil { focusBorderColor = Config().focusBorderColor }
    }
}

// MARK: - TOML mapping

extension Config {
    public init(toml text: String) throws {
        let doc = try TOML.parse(text)
        var c = Config()
        c.rules = []
        let o = doc["options"]?.table ?? [:]

        func d(_ k: String, _ v: inout Double) { if let x = o[k]?.double { v = x } }
        func b(_ k: String, _ v: inout Bool) { if let x = o[k]?.bool { v = x } }
        func s(_ k: String, _ v: inout String) { if let x = o[k]?.string { v = x } }

        if let arr = o["preset_column_widths"]?.array { c.presetColumnWidths = arr.compactMap(\.double) }
        d("default_column_width", &c.defaultColumnWidth)
        d("gap_inner", &c.gapInner)
        d("gap_outer", &c.gapOuter)
        if let m = o["center_focused_column"]?.string, let mode = CenterMode(rawValue: m) { c.centerFocusedColumn = mode }
        b("dock_aware", &c.dockAware)
        d("width_step", &c.widthStep)
        d("height_step", &c.heightStep)
        b("focus_border", &c.focusBorder)
        d("focus_border_width", &c.focusBorderWidth)
        s("focus_border_color", &c.focusBorderColor)
        d("focus_border_radius", &c.focusBorderRadius)
        b("dim_inactive", &c.dimInactive)
        d("dim_inactive_opacity", &c.dimInactiveOpacity)
        b("minimap", &c.minimap)
        d("tab_bar_height", &c.tabBarHeight)
        d("animation_duration_ms", &c.animationDurationMs)
        d("animation_damping", &c.animationDamping)
        b("focus_follows_mouse", &c.focusFollowsMouse)
        b("mouse_follows_focus", &c.mouseFollowsFocus)
        if let f = o["swipe_gesture_fingers"]?.int, let v = SwipeFingers(rawValue: f) { c.swipeGestureFingers = v }
        b("swipe_natural", &c.swipeNatural)
        d("swipe_sensitivity", &c.swipeSensitivity)
        b("drag_to_reorder", &c.dragToReorder)
        b("launch_at_login", &c.launchAtLogin)
        b("onboarding_done", &c.onboardingDone)
        b("check_for_updates", &c.checkForUpdates)
        if let arr = o["ignored_displays"]?.array { c.ignoredDisplays = arr.compactMap(\.string) }

        if let binds = doc["bindings"]?.table {
            for (name, value) in binds {
                guard let action = Action(name: name) else { continue }
                let strings: [String]
                if let one = value.string { strings = [one] } else { strings = value.array?.compactMap(\.string) ?? [] }
                c.bindings[action] = strings.compactMap(Shortcut.init(string:))
            }
        }

        if let windows = doc["windows"]?.table {
            for name in windows.keys.sorted() {
                guard let t = windows[name]?.table else { continue }
                c.rules.append(WindowRule(
                    name: name,
                    bundleID: t["bundle_id"]?.string,
                    title: t["title"]?.string,
                    floating: t["floating"]?.bool ?? false,
                    slot: t["slot"]?.int))
            }
        }
        c.clamp()
        self = c
    }

    public func tomlString() -> String {
        var out = """
        # Roller configuration. Every option is also in the settings window,
        # which writes this file for you. Changes here are picked up live.

        [options]

        """
        func line(_ k: String, _ v: TOMLValue, _ comment: String? = nil) {
            out += "\(k) = \(TOML.format(v))"
            if let comment { out += "  # \(comment)" }
            out += "\n"
        }
        line("preset_column_widths", .array(presetColumnWidths.map { .float($0) }), "fractions of the screen, cycled with ⌃⌥R")
        line("default_column_width", .float(defaultColumnWidth), "0 = new windows keep their own width")
        line("gap_inner", .float(gapInner), "points between windows (0-64)")
        line("gap_outer", .float(gapOuter), "points at the screen edges (0-64)")
        line("center_focused_column", .string(centerFocusedColumn.rawValue), "never | on-overflow | always")
        line("dock_aware", .bool(dockAware))
        line("width_step", .float(widthStep))
        line("height_step", .float(heightStep))
        line("focus_border", .bool(focusBorder))
        line("focus_border_width", .float(focusBorderWidth))
        line("focus_border_color", .string(focusBorderColor), "#RRGGBB or #RRGGBBAA")
        line("focus_border_radius", .float(focusBorderRadius))
        line("dim_inactive", .bool(dimInactive))
        line("dim_inactive_opacity", .float(dimInactiveOpacity))
        line("minimap", .bool(minimap))
        line("tab_bar_height", .float(tabBarHeight))
        line("animation_duration_ms", .float(animationDurationMs), "0 turns animation off")
        line("animation_damping", .float(animationDamping), "1.0 = no overshoot, lower bounces")
        line("focus_follows_mouse", .bool(focusFollowsMouse))
        line("mouse_follows_focus", .bool(mouseFollowsFocus))
        line("swipe_gesture_fingers", .integer(swipeGestureFingers.rawValue), "3, 4, 5 or 0 = off")
        line("swipe_natural", .bool(swipeNatural))
        line("swipe_sensitivity", .float(swipeSensitivity))
        line("drag_to_reorder", .bool(dragToReorder))
        line("launch_at_login", .bool(launchAtLogin))
        line("onboarding_done", .bool(onboardingDone))
        line("check_for_updates", .bool(checkForUpdates))
        line("ignored_displays", .array(ignoredDisplays.map { .string($0) }))

        out += "\n[bindings]\n"
        for action in Action.allCases {
            guard let list = bindings[action] else { continue }
            line(action.rawValue, .array(list.map { .string($0.string) }))
        }

        for rule in rules {
            out += "\n[windows.\(TOML.key(rule.name))]\n"
            if let t = rule.title, !t.isEmpty { line("title", .string(t)) }
            if let b = rule.bundleID, !b.isEmpty { line("bundle_id", .string(b)) }
            line("floating", .bool(rule.floating))
            if let slot = rule.slot { line("slot", .integer(slot)) }
        }
        return out
    }

    /// The config file path: `~/.roller.toml`, or an existing
    /// `$XDG_CONFIG_HOME/roller/roller.toml` / `~/.config/roller/roller.toml`.
    public static func filePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let primary = home.appendingPathComponent(".roller.toml")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let xdgBase = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let xdg = xdgBase.appendingPathComponent("roller/roller.toml")
        if FileManager.default.fileExists(atPath: xdg.path) { return xdg }
        return primary
    }
}

/// A colour parsed from `#RRGGBB` or `#RRGGBBAA`.
public struct RGBA: Equatable {
    public var r, g, b, a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let full = h.count == 6 ? (v << 8) | 0xFF : v
        r = Double((full >> 24) & 0xFF) / 255
        g = Double((full >> 16) & 0xFF) / 255
        b = Double((full >> 8) & 0xFF) / 255
        a = Double(full & 0xFF) / 255
    }

    public var hex: String {
        func c(_ x: Double) -> String { String(format: "%02X", Int((min(max(x, 0), 1) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + c(a)
    }
}
