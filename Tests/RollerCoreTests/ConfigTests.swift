import XCTest
@testable import RollerCore

final class ConfigTests: XCTestCase {
    func testDefaultBindingsMatchTheDocumentedSet() {
        let b = Config.defaultBindings
        func s(_ a: Action) -> [String] { (b[a] ?? []).map(\.string) }
        XCTAssertEqual(s(.focusLeft), ["ctrl+alt+h", "ctrl+alt+left"])
        XCTAssertEqual(s(.focusDown), ["ctrl+alt+j", "ctrl+alt+down"])
        XCTAssertEqual(s(.focusUp), ["ctrl+alt+k", "ctrl+alt+up"])
        XCTAssertEqual(s(.focusRight), ["ctrl+alt+l", "ctrl+alt+right"])
        XCTAssertEqual(s(.focusFirst), ["ctrl+alt+cmd+left"])
        XCTAssertEqual(s(.focusLast), ["ctrl+alt+cmd+right"])
        XCTAssertEqual(s(.focusPlace1), ["ctrl+alt+1"])
        XCTAssertEqual(s(.focusPlace8), ["ctrl+alt+8"])
        XCTAssertEqual(s(.focusPlaceLast), ["ctrl+alt+9"])
        XCTAssertEqual(s(.moveToPlace3), ["ctrl+alt+shift+3"])
        XCTAssertEqual(s(.moveToPlaceLast), ["ctrl+alt+shift+9"])
        XCTAssertEqual(s(.moveLeft), ["ctrl+alt+shift+h", "ctrl+alt+shift+left"])
        XCTAssertEqual(s(.moveToFirst), ["ctrl+alt+shift+cmd+left"])
        XCTAssertEqual(s(.moveToLast), ["ctrl+alt+shift+cmd+right"])
        XCTAssertEqual(s(.cycleWidth), ["ctrl+alt+r"])
        XCTAssertEqual(s(.fullWidth), ["ctrl+alt+f"])
        XCTAssertEqual(s(.centerColumn), ["ctrl+alt+c"])
        XCTAssertEqual(s(.wider), ["ctrl+alt+equal"])
        XCTAssertEqual(s(.narrower), ["ctrl+alt+minus"])
        XCTAssertEqual(s(.taller), ["ctrl+alt+shift+equal"])
        XCTAssertEqual(s(.shorter), ["ctrl+alt+shift+minus"])
        XCTAssertEqual(s(.equalizeHeights), ["ctrl+alt+0"])
        XCTAssertEqual(s(.stackIntoLeft), ["ctrl+alt+rightbracket"])
        XCTAssertEqual(s(.stackIntoRight), ["ctrl+alt+leftbracket"])
        XCTAssertEqual(s(.popOutRight), ["ctrl+alt+shift+rightbracket"])
        XCTAssertEqual(s(.popOutLeft), ["ctrl+alt+shift+leftbracket"])
        XCTAssertEqual(s(.toggleTabbed), ["ctrl+alt+shift+t"])
        XCTAssertEqual(s(.toggleFloat), ["ctrl+alt+t"])
        XCTAssertEqual(s(.sendToNextDisplay), ["ctrl+alt+n"])
        XCTAssertEqual(s(.toggleManager), ["ctrl+alt+q"])
        XCTAssertTrue(Config().conflicts().isEmpty, "defaults must not collide")
    }

    func testDefaultOptions() {
        let c = Config()
        XCTAssertEqual(c.presetColumnWidths, [0.25, 0.33, 0.5, 0.66, 0.75])
        XCTAssertEqual(c.gapInner, 8)
        XCTAssertEqual(c.gapOuter, 8)
        XCTAssertEqual(c.centerFocusedColumn, .never)
        XCTAssertTrue(c.dockAware)
        XCTAssertFalse(c.focusBorder)
        XCTAssertFalse(c.dimInactive)
        XCTAssertFalse(c.focusFollowsMouse)
        XCTAssertFalse(c.mouseFollowsFocus)
        XCTAssertEqual(c.swipeGestureFingers, .four)
        XCTAssertTrue(c.swipeNatural)
        XCTAssertEqual(c.animationDurationMs, 500)
        XCTAssertEqual(c.animationDamping, 0.9)
    }

    func testTOMLRoundTrip() throws {
        var c = Config.default
        c.gapInner = 16
        c.centerFocusedColumn = .onOverflow
        c.presetColumnWidths = [0.33333, 0.5, 0.66667]
        c.ignoredDisplays = ["ABC-123"]
        c.focusBorderColor = "#FF8800CC"
        c.swipeGestureFingers = .three
        c.bindings[.focusLeft] = [Shortcut(string: "ctrl+alt+a")!]
        c.bindings[.toggleFloat] = []
        c.rules.append(WindowRule(name: "term", bundleID: "com.apple.Terminal", slot: 1))
        let text = c.tomlString()
        let back = try Config(toml: text)
        XCTAssertEqual(back, c)
    }

    func testParsesTheDocumentedExample() throws {
        let text = """
        [options]
        preset_column_widths = [0.33333, 0.5, 0.66667]   # three presets
        gap_inner = 16
        gap_outer = 16
        center_focused_column = "never"                  # or "on-overflow" / "always"
        focus_follows_mouse = false
        mouse_follows_focus = false
        swipe_gesture_fingers = 4
        focus_border = true

        [bindings]
        cycle_width = "ctrl+alt+w"
        focus-left = ["ctrl+alt+a", "⌃⌥←"]

        [windows.pip]
        title = "Picture.*(in)?.*[Pp]icture"
        floating = true

        [windows.settings]
        title = ".*"
        bundle_id = "com.apple.systempreferences"
        floating = true
        """
        let c = try Config(toml: text)
        XCTAssertEqual(c.presetColumnWidths, [0.33333, 0.5, 0.66667])
        XCTAssertEqual(c.gapInner, 16)
        XCTAssertTrue(c.focusBorder)
        XCTAssertEqual(c.bindings[.cycleWidth]?.map(\.string), ["ctrl+alt+w"])
        XCTAssertEqual(c.bindings[.focusLeft]?.map(\.string), ["ctrl+alt+a", "ctrl+alt+left"])
        // Untouched bindings keep their defaults.
        XCTAssertEqual(c.bindings[.fullWidth]?.map(\.string), ["ctrl+alt+f"])
        XCTAssertEqual(c.rules.count, 2)
        let pip = c.rules.first { $0.name == "pip" }!
        XCTAssertTrue(pip.matches(bundleID: "com.apple.Safari", title: "Picture in Picture"))
        XCTAssertFalse(pip.matches(bundleID: "com.apple.Safari", title: "Inbox"))
        let settings = c.rules.first { $0.name == "settings" }!
        XCTAssertTrue(settings.matches(bundleID: "com.apple.systempreferences", title: "Wi-Fi"))
        XCTAssertFalse(settings.matches(bundleID: "com.apple.Terminal", title: "Wi-Fi"))
    }

    func testValuesAreClamped() throws {
        let c = try Config(toml: "[options]\ngap_inner = 500\nanimation_damping = 3\nfocus_border_color = \"nope\"\n")
        XCTAssertEqual(c.gapInner, 64)
        XCTAssertEqual(c.animationDamping, 1)
        XCTAssertEqual(c.focusBorderColor, Config().focusBorderColor)
    }

    func testTOMLErrors() {
        XCTAssertThrowsError(try TOML.parse("a = "))
        XCTAssertThrowsError(try TOML.parse("a = \"unterminated"))
        XCTAssertThrowsError(try TOML.parse("a = 1\na = 2"))
        XCTAssertThrowsError(try TOML.parse("[t]\nx = [1, 2"))
    }

    func testTOMLValues() throws {
        let doc = try TOML.parse("""
        # comment
        s = "a \\"q\\" \\u00e9"
        l = 'C:\\path'
        i = -1_000
        f = 2.5e1
        b = true
        arr = [
          1,
          2, # trailing comma
        ]
        inline = { x = 1, "y z" = "w" }
        [a."b c"]
        k = false
        """)
        XCTAssertEqual(doc["s"], .string("a \"q\" é"))
        XCTAssertEqual(doc["l"], .string("C:\\path"))
        XCTAssertEqual(doc["i"], .integer(-1000))
        XCTAssertEqual(doc["f"], .float(25))
        XCTAssertEqual(doc["b"], .bool(true))
        XCTAssertEqual(doc["arr"], .array([.integer(1), .integer(2)]))
        XCTAssertEqual(doc["inline"]?.table?["y z"], .string("w"))
        XCTAssertEqual(doc["a"]?.table?["b c"]?.table?["k"], .bool(false))
    }

    func testShortcutParsing() {
        XCTAssertEqual(Shortcut(string: "ctrl+alt+h"), Shortcut(keyCode: 4, modifiers: [.control, .option]))
        XCTAssertEqual(Shortcut(string: "Control+Option+Shift+["), Shortcut(keyCode: 33, modifiers: [.control, .option, .shift]))
        XCTAssertEqual(Shortcut(string: "⌃⌥⌘→"), Shortcut(keyCode: 124, modifiers: [.control, .option, .command]))
        XCTAssertEqual(Shortcut(string: "ctrl+alt+="), Shortcut(keyCode: 24, modifiers: [.control, .option]))
        XCTAssertEqual(Shortcut(string: "ctrl+alt+-")?.string, "ctrl+alt+minus")
        XCTAssertEqual(Shortcut(string: "cmd+kc:200")?.keyCode, 200)
        XCTAssertNil(Shortcut(string: "ctrl+alt+"))
        XCTAssertNil(Shortcut(string: "hyper+h"))
        XCTAssertNil(Shortcut(string: "ctrl+alt+nokey"))
    }

    func testActionNames() {
        XCTAssertEqual(Action(name: "focus_left"), .focusLeft)
        XCTAssertEqual(Action(name: "focus-left"), .focusLeft)
        XCTAssertEqual(Action(name: "focusLeft"), .focusLeft)
        XCTAssertEqual(Action(name: "focus_place_9"), .focusPlaceLast)
        XCTAssertNil(Action(name: "explode"))
        for a in Action.allCases {
            XCTAssertEqual(Action(name: a.rawValue), a)
            XCTAssertFalse(a.title.isEmpty)
            XCTAssertFalse(a.help.isEmpty)
        }
    }

    func testColorParsing() {
        XCTAssertEqual(RGBA(hex: "#FF0000")?.hex, "#FF0000FF")
        XCTAssertEqual(RGBA(hex: "00ff0080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBA(hex: "#12345"))
    }
}
