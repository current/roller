import AppKit
import SwiftUI
import RollerCore

struct ShortcutsPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var filter = ""

    var body: some View {
        let conflicts = store.config.conflicts()
        VStack(spacing: 0) {
            HStack {
                TextField("Search actions", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Restore Defaults") { store.config.bindings = Config.defaultBindings }
            }
            .padding([.horizontal, .top])
            Form {
                ForEach(Action.Group.allCases, id: \.self) { group in
                    let actions = Action.allCases.filter { $0.group == group && matches($0) }
                    if !actions.isEmpty {
                        Section(group.rawValue) {
                            ForEach(actions, id: \.self) { action in
                                ShortcutRow(action: action, conflicts: conflicts)
                            }
                        }
                    }
                }
                Section {
                    Text("Every action can have several shortcuts. Defaults use ⌃⌥ (Control-Option) so plain ⌥ stays free for typing accents and jumping by word. Shortcuts follow physical keys, and are shown with your keyboard layout's characters.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func matches(_ a: Action) -> Bool {
        filter.isEmpty || a.title.localizedCaseInsensitiveContains(filter) || a.rawValue.contains(filter.lowercased())
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var store: ConfigStore
    let action: Action
    let conflicts: [Shortcut: [Action]]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(action.rawValue).font(.caption).foregroundStyle(.secondary).monospaced()
            }
            Spacer()
            ForEach(store.config.bindings[action] ?? [], id: \.self) { s in
                ShortcutChip(shortcut: s, conflict: conflicts[s] != nil) {
                    store.config.bindings[action]?.removeAll { $0 == s }
                }
                .help(conflicts[s].map { "Also bound to: " + $0.filter { $0 != action }.map(\.title).joined(separator: ", ") } ?? "")
            }
            ShortcutRecorder { s in
                var list = store.config.bindings[action] ?? []
                if !list.contains(s) { list.append(s) }
                store.config.bindings[action] = list
            }
        }
    }
}

struct ShortcutChip: View {
    let shortcut: Shortcut
    let conflict: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(KeyDisplay.string(shortcut)).font(.system(.body, design: .rounded)).monospacedDigit()
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(conflict ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15)))
    }
}

/// Records one key combination. Global shortcuts are paused meanwhile, so
/// pressing an existing combo records it instead of running it.
struct ShortcutRecorder: View {
    let onRecord: (Shortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            if recording {
                Text("Type shortcut…").foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "plus")
            }
        }
        .help("Add a shortcut. Press Esc to cancel.")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Hotkeys.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            let f = event.modifierFlags
            var m: Shortcut.Modifiers = []
            if f.contains(.control) { m.insert(.control) }
            if f.contains(.option) { m.insert(.option) }
            if f.contains(.shift) { m.insert(.shift) }
            if f.contains(.command) { m.insert(.command) }
            let isFunctionKey = KeyCodes.symbol(forCode: UInt32(event.keyCode))?.hasPrefix("F") == true
            // Plain keys and Shift-only combos would break typing.
            guard !m.subtracting(.shift).isEmpty || isFunctionKey else {
                NSSound.beep()
                return nil
            }
            onRecord(Shortcut(keyCode: UInt32(event.keyCode), modifiers: m))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Hotkeys.shared.suspended = false
    }
}

// MARK: - Guide

struct GuidePage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    Text("Your windows on an endless strip").font(.title2.bold())
                    Text("Every window is a column on a horizontal strip that runs past the edges of the screen. A new window opens next to the focused one and nothing else is resized; the strip just gets longer. Move along it with the keyboard or a trackpad swipe, and the focused column glides into view.")
                    Text("Columns can hold several windows stacked on top of each other, or show them as tabs. Each display, and each macOS Space, has its own strip. Column order, widths, stacks and tabs are saved and come back after a restart.")
                }
                .fixedSize(horizontal: false, vertical: true)

                ForEach(Action.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.rawValue).font(.headline)
                        ForEach(Action.allCases.filter { $0.group == group && !isPlace($0) }, id: \.self) { a in
                            HStack(alignment: .firstTextBaseline) {
                                Text(keys(a)).monospaced().frame(width: 170, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.title).bold()
                                    Text(a.help).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if group == .focus {
                            Text("⌃⌥1 … ⌃⌥8 jump to the window at that place on the strip and ⌃⌥9 to the last one, like browser tabs. Add ⇧ to move the focused window there instead.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Mouse and trackpad").font(.headline)
                    Text("Swipe left or right with \(store.config.swipeGestureFingers == .off ? "3 or 4" : "\(store.config.swipeGestureFingers.rawValue)") fingers to scroll the strip; it settles on the nearest column. Drag a window by its title bar onto another column to reorder. Resize a window with the mouse and its column keeps that width.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Automation").font(.headline)
                    Text("Every action has a name (shown under it on the Shortcuts page) that works as a URL and on the command line:")
                    Text("open -g roller://focus_left\nroller cycle_width\nroller list").monospaced().textSelection(.enabled)
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    Text("The roller command is inside the app at Roller.app/Contents/Resources/bin/roller. Raycast script commands are in the project's raycast folder.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func isPlace(_ a: Action) -> Bool {
        if case .some = a.place { return true }
        return false
    }

    private func keys(_ a: Action) -> String {
        let list = store.config.bindings[a] ?? []
        return list.isEmpty ? "—" : list.map(KeyDisplay.string).joined(separator: "  ")
    }
}
