import AppKit
import IOKit.ps
import RollerCore

enum Spaces {
    struct DisplaySpace {
        var displayIdentifier: String
        var currentSpace: UInt64
        /// A native full-screen app's space.
        var isFullscreen: Bool
    }

    // Read-only window server calls; they need no permission or SIP changes.
    static let connection: Int32 = Private.mainConnection?() ?? 0

    static func current() -> [DisplaySpace] {
        guard let copy = Private.copyManagedDisplaySpaces,
              let list = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let ident = d["Display Identifier"] as? String,
                  let cur = d["Current Space"] as? [String: Any] else { return nil }
            let id = (cur["id64"] as? NSNumber)?.uint64Value ?? (cur["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let type = (cur["type"] as? NSNumber)?.intValue ?? 0
            return DisplaySpace(displayIdentifier: ident, currentSpace: id, isFullscreen: type == 4)
        }
    }

    /// The Spaces a window is on (usually one).
    static func spaces(for window: CGWindowID) -> [UInt64] {
        let arr = [NSNumber(value: window)] as CFArray
        guard let copy = Private.copySpacesForWindows,
              let res = copy(connection, 0x7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return res.map(\.uint64Value)
    }
}

/// One connected display in Quartz (top-left origin) coordinates.
struct Display: Equatable {
    var id: CGDirectDisplayID
    var uuid: String
    var name: String
    /// The whole display.
    var frame: CGRect
    /// Minus the menu bar and the Dock.
    var visibleFrame: CGRect
    /// Minus the menu bar only.
    var frameBelowMenuBar: CGRect
    var neighbors: DisplayNeighbors = []
    /// Current Space id ("0" if unknown).
    var space: UInt64 = 0
    var spaceIsFullscreen = false
    /// The Mac's own screen (a MacBook or iMac panel).
    var isBuiltin = false

    var facts: DisplayFacts { DisplayFacts(uuid: uuid, isBuiltin: isBuiltin) }

    var stripKey: String { "\(uuid)|\(space)" }

    func workingArea(_ config: Config) -> CGRect {
        let base = config.dockAware ? visibleFrame : frameBelowMenuBar
        return base.insetBy(dx: config.gapOuter, dy: config.gapOuter)
    }

    static func all() -> [Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.height
        func flip(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }

        var displays: [Display] = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            var below = screen.frame
            below.size.height = screen.visibleFrame.maxY - screen.frame.minY
            return Display(id: id, uuid: uuid, name: screen.localizedName,
                           frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame),
                           frameBelowMenuBar: flip(below), isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        let frames = displays.map(\.frame)
        let spaces = Spaces.current()
        for i in displays.indices {
            displays[i].neighbors = DisplayNeighbors.of(displays[i].frame, among: frames)
            if let s = spaces.first(where: { $0.displayIdentifier.caseInsensitiveCompare(displays[i].uuid) == .orderedSame })
                ?? spaces.first(where: { $0.displayIdentifier == "Main" })
                ?? (spaces.count == 1 ? spaces.first : nil) {
                displays[i].space = s.currentSpace
                displays[i].spaceIsFullscreen = s.isFullscreen
            }
        }
        return displays
    }
}

enum Geometry {
    /// Height of the primary screen, used to flip between AppKit and Quartz.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toQuartz(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static var mouseLocation: CGPoint { toQuartz(NSEvent.mouseLocation) }
}

enum Power {
    /// On battery power, or in Low Power Mode.
    static var isSaving: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
