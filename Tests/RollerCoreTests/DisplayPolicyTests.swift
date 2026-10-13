import XCTest
@testable import RollerCore

final class DisplayPolicyTests: XCTestCase {
    let laptop = DisplayFacts(uuid: "BUILTIN", isBuiltin: true)
    let monitor = DisplayFacts(uuid: "EXT-1", isBuiltin: false)
    let second = DisplayFacts(uuid: "EXT-2", isBuiltin: false)

    func managed(_ d: DisplayFacts, _ all: [DisplayFacts], _ c: Config) -> Bool {
        DisplayPolicy.isManaged(d, among: all, config: c)
    }

    func testDefaultsManageEverything() {
        let c = Config()
        XCTAssertTrue(managed(laptop, [laptop], c))
        XCTAssertTrue(managed(laptop, [laptop, monitor], c))
        XCTAssertTrue(managed(monitor, [laptop, monitor], c))
    }

    func testLaptopOnTheGo() {
        var c = Config()
        c.builtinDisplay = .alone
        c.externalDisplays = .never
        XCTAssertTrue(managed(laptop, [laptop], c), "on when portable")
        XCTAssertFalse(managed(laptop, [laptop, monitor], c), "off when a monitor is plugged in")
        XCTAssertFalse(managed(monitor, [laptop, monitor], c))
        XCTAssertFalse(managed(monitor, [monitor], c), "lid closed: external is never managed")
    }

    func testDockedSetup() {
        var c = Config()
        c.builtinDisplay = .alone
        c.externalDisplays = .always
        XCTAssertTrue(managed(laptop, [laptop], c))
        XCTAssertFalse(managed(laptop, [laptop, monitor], c))
        XCTAssertTrue(managed(monitor, [laptop, monitor], c))
        XCTAssertTrue(managed(second, [laptop, monitor, second], c))
    }

    func testExternalAloneMeansClamshell() {
        var c = Config()
        c.externalDisplays = .alone
        XCTAssertTrue(managed(monitor, [monitor], c))
        XCTAssertFalse(managed(monitor, [laptop, monitor], c))
    }

    func testOverridesWin() {
        var c = Config()
        c.builtinDisplay = .alone
        c.externalDisplays = .never
        c.displayOverrides["EXT-2"] = .on
        c.displayOverrides["BUILTIN"] = .off
        XCTAssertTrue(managed(second, [laptop, monitor, second], c))
        XCTAssertFalse(managed(monitor, [laptop, monitor, second], c))
        XCTAssertFalse(managed(laptop, [laptop], c))
    }

    func testReasons() {
        var c = Config()
        c.builtinDisplay = .alone
        XCTAssertEqual(DisplayPolicy.reason(laptop, among: [laptop, monitor], config: c),
                       "Built-in display: paused while another display is connected")
        XCTAssertEqual(DisplayPolicy.reason(laptop, among: [laptop], config: c),
                       "Built-in display: managed while it's the only display")
        c.displayOverrides["EXT-1"] = .off
        XCTAssertEqual(DisplayPolicy.reason(monitor, among: [laptop, monitor], config: c), "Switched off for this display")
    }

    func testConfigRoundTripAndLegacyMigration() throws {
        var c = Config.default
        c.builtinDisplay = .alone
        c.externalDisplays = .never
        c.displayOverrides = ["37D8832A-2D66-02CA-B9F7-8F30A301B230": .on, "EXT-1": .off]
        c.notifyDisplayChanges = false
        c.releaseInputWhenIdle = false
        c.pauseForApps = ["com.parallels.desktop.console", "com.microsoft.rdc.macos"]
        c.newWindowPosition = .end
        c.wrapFocus = true
        c.minimapPosition = .bottom
        c.minimapDurationMs = 2000
        c.respectReduceMotion = false
        c.reduceMotionOnBattery = true
        c.showMenuBarIcon = false
        XCTAssertEqual(try Config(toml: c.tomlString()), c)
        XCTAssertEqual(try Config(toml: Config.default.tomlString()), Config.default)

        // Files from before display profiles listed switched-off displays.
        let legacy = try Config(toml: "[options]\nignored_displays = [\"OLD-1\", \"OLD-2\"]\n")
        XCTAssertEqual(legacy.displayOverrides, ["OLD-1": .off, "OLD-2": .off])
        XCTAssertFalse(legacy.tomlString().contains("ignored_displays"))
    }
}
