import Foundation

/// Every command Roller understands. The raw value is the name used in the
/// config file, the `roller://` URL scheme and the `roller` CLI.
public enum Action: String, CaseIterable, Codable, Hashable {
    // Focus
    case focusLeft = "focus_left"
    case focusRight = "focus_right"
    case focusUp = "focus_up"
    case focusDown = "focus_down"
    case focusFirst = "focus_first"
    case focusLast = "focus_last"
    case focusPlace1 = "focus_place_1"
    case focusPlace2 = "focus_place_2"
    case focusPlace3 = "focus_place_3"
    case focusPlace4 = "focus_place_4"
    case focusPlace5 = "focus_place_5"
    case focusPlace6 = "focus_place_6"
    case focusPlace7 = "focus_place_7"
    case focusPlace8 = "focus_place_8"
    case focusPlaceLast = "focus_place_last"
    case focusNextDisplay = "focus_next_display"

    // Move
    case moveLeft = "move_left"
    case moveRight = "move_right"
    case moveUp = "move_up"
    case moveDown = "move_down"
    case moveToFirst = "move_to_first"
    case moveToLast = "move_to_last"
    case moveToPlace1 = "move_to_place_1"
    case moveToPlace2 = "move_to_place_2"
    case moveToPlace3 = "move_to_place_3"
    case moveToPlace4 = "move_to_place_4"
    case moveToPlace5 = "move_to_place_5"
    case moveToPlace6 = "move_to_place_6"
    case moveToPlace7 = "move_to_place_7"
    case moveToPlace8 = "move_to_place_8"
    case moveToPlaceLast = "move_to_place_last"
    case sendToNextDisplay = "send_to_next_display"

    // Size
    case cycleWidth = "cycle_width"
    case fullWidth = "full_width"
    case centerColumn = "center_column"
    case wider = "wider"
    case narrower = "narrower"
    case taller = "taller"
    case shorter = "shorter"
    case equalizeHeights = "equalize_heights"

    // Stacks
    case stackIntoLeft = "stack_into_left"
    case stackIntoRight = "stack_into_right"
    case popOutRight = "pop_out_right"
    case popOutLeft = "pop_out_left"
    case toggleTabbed = "toggle_tabbed"

    // Windows and app
    case toggleFloat = "toggle_float"
    case toggleManager = "toggle_manager"
    case start = "start"
    case stop = "stop"
    case reloadConfig = "reload_config"
    case openSettings = "open_settings"

    /// Accepts `focus_left`, `focus-left` and `focusLeft`.
    public init?(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var snake = ""
        for ch in trimmed {
            if ch == "-" || ch == " " { snake.append("_") }
            else if ch.isUppercase { snake.append("_"); snake.append(contentsOf: ch.lowercased()) }
            else { snake.append(ch) }
        }
        let aliases: [String: Action] = [
            "focus_place_9": .focusPlaceLast,
            "move_to_place_9": .moveToPlaceLast,
            "float": .toggleFloat,
            "tabbed": .toggleTabbed,
            "center": .centerColumn,
            "toggle": .toggleManager,
            "reload": .reloadConfig,
            "settings": .openSettings,
        ]
        if let a = Action(rawValue: snake) ?? aliases[snake] { self = a } else { return nil }
    }

    public enum Group: String, CaseIterable {
        case focus = "Focus"
        case move = "Move"
        case size = "Size"
        case stacks = "Stacks & Tabs"
        case app = "Windows & App"
    }

    public var group: Group {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast,
             .focusPlace1, .focusPlace2, .focusPlace3, .focusPlace4, .focusPlace5,
             .focusPlace6, .focusPlace7, .focusPlace8, .focusPlaceLast, .focusNextDisplay:
            return .focus
        case .moveLeft, .moveRight, .moveUp, .moveDown, .moveToFirst, .moveToLast,
             .moveToPlace1, .moveToPlace2, .moveToPlace3, .moveToPlace4, .moveToPlace5,
             .moveToPlace6, .moveToPlace7, .moveToPlace8, .moveToPlaceLast, .sendToNextDisplay:
            return .move
        case .cycleWidth, .fullWidth, .centerColumn, .wider, .narrower, .taller, .shorter, .equalizeHeights:
            return .size
        case .stackIntoLeft, .stackIntoRight, .popOutRight, .popOutLeft, .toggleTabbed:
            return .stacks
        case .toggleFloat, .toggleManager, .start, .stop, .reloadConfig, .openSettings:
            return .app
        }
    }

    /// Place number for the place actions (nil = last).
    public var place: Int?? {
        switch self {
        case .focusPlace1, .moveToPlace1: return .some(1)
        case .focusPlace2, .moveToPlace2: return .some(2)
        case .focusPlace3, .moveToPlace3: return .some(3)
        case .focusPlace4, .moveToPlace4: return .some(4)
        case .focusPlace5, .moveToPlace5: return .some(5)
        case .focusPlace6, .moveToPlace6: return .some(6)
        case .focusPlace7, .moveToPlace7: return .some(7)
        case .focusPlace8, .moveToPlace8: return .some(8)
        case .focusPlaceLast, .moveToPlaceLast: return .some(nil)
        default: return .none
        }
    }

    public var title: String {
        switch self {
        case .focusLeft: return "Focus left"
        case .focusRight: return "Focus right"
        case .focusUp: return "Focus up (in a stack)"
        case .focusDown: return "Focus down (in a stack)"
        case .focusFirst: return "Focus the first window"
        case .focusLast: return "Focus the last window"
        case .focusPlaceLast: return "Focus the last place"
        case .focusNextDisplay: return "Focus the next display"
        case .moveLeft: return "Move left"
        case .moveRight: return "Move right"
        case .moveUp: return "Move up (in a stack)"
        case .moveDown: return "Move down (in a stack)"
        case .moveToFirst: return "Move to the first spot"
        case .moveToLast: return "Move to the last spot"
        case .moveToPlaceLast: return "Move to the last place"
        case .sendToNextDisplay: return "Send to the next display"
        case .cycleWidth: return "Cycle preset widths"
        case .fullWidth: return "Full width"
        case .centerColumn: return "Center column"
        case .wider: return "Wider"
        case .narrower: return "Narrower"
        case .taller: return "Taller (in a stack)"
        case .shorter: return "Shorter (in a stack)"
        case .equalizeHeights: return "Equalize heights"
        case .stackIntoLeft: return "Stack into the left column"
        case .stackIntoRight: return "Stack into the right column"
        case .popOutRight: return "Pop out of the stack (right)"
        case .popOutLeft: return "Pop out of the stack (left)"
        case .toggleTabbed: return "Tabbed column"
        case .toggleFloat: return "Float / unfloat"
        case .toggleManager: return "Stop / start Roller"
        case .start: return "Start Roller"
        case .stop: return "Stop Roller"
        case .reloadConfig: return "Reload configuration"
        case .openSettings: return "Open settings"
        default:
            if let p = place, let n = p {
                return group == .focus ? "Focus place \(n)" : "Move to place \(n)"
            }
            return rawValue
        }
    }

    public var help: String {
        switch self {
        case .focusLeft, .focusRight: return "Focus the neighbouring column; the strip scrolls to show it."
        case .focusUp, .focusDown: return "Move focus between windows stacked in one column, or between tabs."
        case .focusFirst, .focusLast: return "Jump to the start or end of the strip."
        case .focusNextDisplay: return "Focus the strip on the next display."
        case .moveLeft, .moveRight: return "Swap the focused column with its neighbour."
        case .moveUp, .moveDown: return "Reorder the focused window inside its stack."
        case .moveToFirst, .moveToLast: return "Send the focused column to the start or end of the strip."
        case .sendToNextDisplay: return "Move the focused window to the strip on the next display."
        case .cycleWidth: return "Step the focused column through the preset widths."
        case .fullWidth: return "Toggle the focused column between full width and its previous width."
        case .centerColumn: return "Scroll the strip so the focused column is centered."
        case .wider, .narrower: return "Change the focused column's width by one step."
        case .taller, .shorter: return "Give the focused window in a stack more or less of the column's height."
        case .equalizeHeights: return "Give every window in the stack the same height."
        case .stackIntoLeft: return "Move the focused window into the column on its left."
        case .stackIntoRight: return "Move the focused window into the column on its right."
        case .popOutRight, .popOutLeft: return "Take the focused window out of its stack into its own column."
        case .toggleTabbed: return "Show the stack as tabs, each window at full column height."
        case .toggleFloat: return "Take the focused window off the strip so it floats freely, or put it back."
        case .toggleManager: return "Stop Roller (windows stay where they are) or start it again."
        case .start, .stop: return "Start or stop managing windows."
        case .reloadConfig: return "Re-read the configuration file."
        case .openSettings: return "Open the settings window."
        default:
            return group == .focus
                ? "Jump to the window at this place on the strip, like browser tabs."
                : "Move the focused column to this place on the strip."
        }
    }
}
