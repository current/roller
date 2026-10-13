import Foundation

/// When Roller manages a kind of display.
public enum DisplayMode: String, Codable, CaseIterable {
    /// Always arrange windows on it.
    case always
    /// Only while it is the only display connected. For the built-in
    /// screen: on the go, but not while docked to a monitor.
    case alone
    /// Never touch it; windows stay where you put them.
    case never
}

/// A per-display override that wins over the display profile.
public enum DisplayOverride: String, Codable, CaseIterable {
    case on, off
}

/// Where a new window joins the strip.
public enum NewWindowPosition: String, Codable, CaseIterable {
    /// Right after the focused column.
    case next
    /// At the end of the strip.
    case end
    /// At the start of the strip.
    case start
}

public enum MinimapPosition: String, Codable, CaseIterable {
    case top, bottom
}

/// A connected display, as far as the display profile cares.
public struct DisplayFacts: Equatable {
    public var uuid: String
    public var isBuiltin: Bool
    public init(uuid: String, isBuiltin: Bool) {
        self.uuid = uuid
        self.isBuiltin = isBuiltin
    }
}

public enum DisplayPolicy {
    /// Whether Roller arranges windows on `display`, given every display
    /// connected right now.
    public static func isManaged(_ display: DisplayFacts, among all: [DisplayFacts], config: Config) -> Bool {
        switch config.displayOverrides[display.uuid] {
        case .on: return true
        case .off: return false
        case nil: break
        }
        let mode = display.isBuiltin ? config.builtinDisplay : config.externalDisplays
        switch mode {
        case .always: return true
        case .never: return false
        case .alone: return all.count <= 1
        }
    }

    /// A one-line description of why a display is (not) managed, for the
    /// settings window and the change notice.
    public static func reason(_ display: DisplayFacts, among all: [DisplayFacts], config: Config) -> String {
        if let o = config.displayOverrides[display.uuid] {
            return o == .on ? "Always on for this display" : "Switched off for this display"
        }
        let kind = display.isBuiltin ? "Built-in display" : "External display"
        switch display.isBuiltin ? config.builtinDisplay : config.externalDisplays {
        case .always: return "\(kind): always managed"
        case .never: return "\(kind): never managed"
        case .alone:
            return all.count <= 1 ? "\(kind): managed while it's the only display"
                                  : "\(kind): paused while another display is connected"
        }
    }
}
