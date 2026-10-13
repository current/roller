import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RollerCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case layout = "Layout"
    case appearance = "Appearance"
    case input = "Trackpad & Mouse"
    case rules = "Window Rules"
    case displays = "Displays"
    case pausing = "Pausing & Power"
    case shortcuts = "Shortcuts"
    case macSetup = "Mac Setup"
    case help = "Guide"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.3x1"
        case .appearance: return "paintbrush"
        case .input: return "hand.draw"
        case .rules: return "list.bullet.rectangle"
        case .displays: return "display.2"
        case .pausing: return "pause.circle"
        case .shortcuts: return "keyboard"
        case .macSetup: return "checkmark.seal"
        case .help: return "book"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if let err = store.loadError {
                    Text("The configuration file has an error and was not applied — \(err)")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                }
                page
            }
            .navigationTitle(nav.page.rawValue)
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .general: GeneralPage()
        case .layout: LayoutPage()
        case .appearance: AppearancePage()
        case .input: InputPage()
        case .rules: RulesPage()
        case .displays: DisplaysPage()
        case .pausing: PausingPage()
        case .shortcuts: ShortcutsPage()
        case .macSetup: MacSetupPage()
        case .help: GuidePage()
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var status = Engine.shared.status

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle().fill(status == .running ? Color.green : (status == .needsPermission ? .orange : .secondary))
                        .frame(width: 10, height: 10)
                    Text(Engine.shared.statusText.capitalized)
                    Spacer()
                    if status == .running {
                        Button("Stop") { Engine.shared.stop(); refresh() }
                    } else {
                        Button("Start") { Engine.shared.start(); refresh() }
                    }
                    Button("Restart") { Engine.shared.restart(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() } }
                }
                if status == .needsPermission {
                    Text("Roller needs the Accessibility permission to move windows. Turn it on in System Settings › Privacy & Security › Accessibility.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") { NSWorkspace.shared.open(URL(string: MacSetup.accessibilityPrivacyURL)!) }
                }
            } header: { Text("Status") }

            Section {
                Toggle("Launch at login", isOn: $store.config.launchAtLogin)
                Toggle("Show icon in the menu bar", isOn: $store.config.showMenuBarIcon)
                if !store.config.showMenuBarIcon {
                    Text("To get back here with the icon hidden, open Roller again from Applications, or run roller open_settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Check for updates daily", isOn: $store.config.checkForUpdates)
                HStack {
                    Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Updater.shared.check(userInitiated: true) }
                }
            } header: { Text("App") }

            Section {
                HStack {
                    Text(store.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { store.revealInFinder() }
                }
                Text("Every setting here applies instantly and is saved to this TOML file. Editing the file by hand works too; Roller picks up the change.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Engine Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.shared.url]) }
                    Button("Show the Welcome Guide") { AppDelegate.shared?.showOnboarding() }
                }
            } header: { Text("Files") }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() { status = Engine.shared.status }
}

// MARK: - Layout

struct LayoutPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var newPreset = ""

    var body: some View {
        Form {
            Section {
                ForEach(Array(store.config.presetColumnWidths.enumerated()), id: \.offset) { i, w in
                    HStack {
                        Text("\(Int((w * 100).rounded()))%")
                            .monospacedDigit()
                        WidthBar(fraction: w)
                        Spacer()
                        Button {
                            store.config.presetColumnWidths.remove(at: i)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(store.config.presetColumnWidths.count <= 1)
                    }
                }
                HStack {
                    TextField("Add a width in %", text: $newPreset)
                        .onSubmit(addPreset)
                    Button("Add", action: addPreset).disabled(Double(newPreset) == nil)
                    Button("Reset") { store.config.presetColumnWidths = Config().presetColumnWidths }
                }
            } header: { Text("Preset widths") } footer: {
                Text("⌃⌥R cycles the focused column through these widths, as fractions of the screen.")
            }

            Section {
                Picker("New windows", selection: $store.config.defaultColumnWidth) {
                    Text("Keep their own width").tag(0.0)
                    ForEach(store.config.presetColumnWidths, id: \.self) { w in
                        Text("\(Int((w * 100).rounded()))% of the screen").tag(w)
                    }
                    if store.config.defaultColumnWidth > 0 && !store.config.presetColumnWidths.contains(store.config.defaultColumnWidth) {
                        Text("\(Int((store.config.defaultColumnWidth * 100).rounded()))%").tag(store.config.defaultColumnWidth)
                    }
                }
                Picker("New windows open", selection: $store.config.newWindowPosition) {
                    Text("Next to the focused window").tag(NewWindowPosition.next)
                    Text("At the end of the strip").tag(NewWindowPosition.end)
                    Text("At the start of the strip").tag(NewWindowPosition.start)
                }
                Toggle("Wrap around when focusing past either end", isOn: $store.config.wrapFocus)
                Picker("Center the focused column", selection: $store.config.centerFocusedColumn) {
                    Text("Never").tag(CenterMode.never)
                    Text("On overflow").tag(CenterMode.onOverflow)
                    Text("Always").tag(CenterMode.always)
                }
                Text(centerHelp).font(.callout).foregroundStyle(.secondary)
            } header: { Text("Columns") }

            Section {
                SliderRow(title: "Gap between windows", value: $store.config.gapInner, range: 0...64, step: 1, unit: "pt")
                SliderRow(title: "Gap at screen edges", value: $store.config.gapOuter, range: 0...64, step: 1, unit: "pt")
                Toggle("Leave room for the Dock", isOn: $store.config.dockAware)
            } header: { Text("Gaps") } footer: {
                Text("macOS never lets a window leave the screen completely, so a sliver of a hidden window can show in a bottom corner. A gap of 0 at the screen edges tucks almost all of it away.")
            }

            Section {
                SliderRow(title: "Wider / narrower step", value: Binding(get: { store.config.widthStep * 100 }, set: { store.config.widthStep = $0 / 100 }), range: 1...50, step: 1, unit: "%")
                SliderRow(title: "Taller / shorter step", value: Binding(get: { store.config.heightStep * 100 }, set: { store.config.heightStep = $0 / 100 }), range: 1...50, step: 1, unit: "%")
            } header: { Text("Resize steps") }
        }
        .formStyle(.grouped)
    }

    private var centerHelp: String {
        switch store.config.centerFocusedColumn {
        case .never: return "The strip scrolls only as far as needed to show the focused column."
        case .onOverflow: return "Centers the focused column when it doesn't fit on screen next to the previously focused one."
        case .always: return "The focused column is always in the middle of the screen."
        }
    }

    private func addPreset() {
        guard let v = Double(newPreset.replacingOccurrences(of: "%", with: "")), v > 0 else { return }
        let f = Column.clampWidth(v > 1 ? v / 100 : v)
        if !store.config.presetColumnWidths.contains(where: { abs($0 - f) < 0.001 }) {
            store.config.presetColumnWidths.append(f)
            store.config.presetColumnWidths.sort()
        }
        newPreset = ""
    }
}

struct WidthBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(width: 140, height: 10)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var format: String = "%.0f"

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(String(format: format, value) + (unit.isEmpty ? "" : " \(unit)"))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Focus border", isOn: $store.config.focusBorder)
                if store.config.focusBorder {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: NSColor(RGBA(hex: store.config.focusBorderColor) ?? RGBA(r: 0, g: 0.5, b: 1, a: 1))) },
                        set: { c in
                            let ns = NSColor(c).usingColorSpace(.sRGB) ?? .systemBlue
                            store.config.focusBorderColor = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent).hex
                        }), supportsOpacity: true)
                    SliderRow(title: "Width", value: $store.config.focusBorderWidth, range: 1...20, step: 1, unit: "pt")
                    SliderRow(title: "Corner radius", value: $store.config.focusBorderRadius, range: 0...40, step: 1, unit: "pt")
                }
                Toggle("Dim inactive windows", isOn: $store.config.dimInactive)
                if store.config.dimInactive {
                    SliderRow(title: "Dimming", value: Binding(get: { store.config.dimInactiveOpacity * 100 }, set: { store.config.dimInactiveOpacity = $0 / 100 }), range: 5...90, step: 1, unit: "%")
                }
            } header: { Text("Focus") } footer: { Text("Both are off by default.") }

            Section {
                Toggle("Show the strip minimap while navigating", isOn: $store.config.minimap)
                if store.config.minimap {
                    Picker("Minimap position", selection: $store.config.minimapPosition) {
                        Text("Top of the screen").tag(MinimapPosition.top)
                        Text("Bottom of the screen").tag(MinimapPosition.bottom)
                    }
                    SliderRow(title: "Minimap stays for", value: $store.config.minimapDurationMs, range: 300...5000, step: 100, unit: "ms")
                }
                SliderRow(title: "Tab bar height", value: $store.config.tabBarHeight, range: 16...48, step: 1, unit: "pt")
            } header: { Text("Overlays") }

            Section {
                SliderRow(title: "Duration", value: $store.config.animationDurationMs, range: 0...1500, step: 10, unit: "ms")
                SliderRow(title: "Damping", value: $store.config.animationDamping, range: 0.1...1, step: 0.05, unit: "", format: "%.2f")
                Toggle("Follow the macOS Reduce motion setting", isOn: $store.config.respectReduceMotion)
                Toggle("Turn animation off on battery or in Low Power Mode", isOn: $store.config.reduceMotionOnBattery)
            } header: { Text("Motion") } footer: {
                Text("A spring synced to your display's refresh rate. 0 ms turns animation off. Damping 1.0 settles without overshoot; lower values bounce.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Trackpad & mouse

struct InputPage: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        Form {
            Section {
                Picker("Swipe to scroll the strip", selection: $store.config.swipeGestureFingers) {
                    Text("Off").tag(SwipeFingers.off)
                    Text("3 fingers").tag(SwipeFingers.three)
                    Text("4 fingers").tag(SwipeFingers.four)
                    Text("5 fingers").tag(SwipeFingers.five)
                }
                Toggle("Natural direction (content follows your fingers)", isOn: $store.config.swipeNatural)
                SliderRow(title: "Speed", value: $store.config.swipeSensitivity, range: 0.25...3, step: 0.05, unit: "×", format: "%.2f")
                Button("Check macOS trackpad settings…") { nav.page = .macSetup }
            } header: { Text("Trackpad") } footer: {
                Text("The strip follows your fingers and settles on the nearest column. macOS must not use the same swipe for switching desktops; Mac Setup checks that for you.")
            }

            Section {
                Toggle("Drag a window onto another column to reorder", isOn: $store.config.dragToReorder)
                Toggle("Focus follows mouse", isOn: $store.config.focusFollowsMouse)
                Toggle("Mouse follows focus", isOn: $store.config.mouseFollowsFocus)
            } header: { Text("Mouse") } footer: {
                Text("Resizing a window with the mouse sets its column's width. Focus follows mouse and mouse follows focus are off by default.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window rules

struct RulesPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules match an app (by bundle ID) and/or a window title (a regular expression), then make the window float or give it a fixed place on the strip. Fixed-size windows like Calculator, dialogs and Roller's own windows already float.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($store.config.rules) { $rule in
                    RuleRow(rule: $rule).tag(rule.name)
                }
                .onDelete { store.config.rules.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Menu("Add Rule for App") {
                    ForEach(runningApps, id: \.0) { id, name in
                        Button(name) { addRule(bundleID: id, name: name) }
                    }
                    Divider()
                    Button("Choose an App…") { chooseApp() }
                }
                .fixedSize()
                Button("Add Title Rule") { addRule(bundleID: nil, name: "title") }
                Spacer()
                Button("Remove") {
                    store.config.rules.removeAll { $0.name == selection }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
        .padding()
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func uniqueName(_ base: String) -> String {
        let clean = base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var name = String(clean).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "rule" }
        var n = name, i = 2
        while store.config.rules.contains(where: { $0.name == n }) { n = "\(name)-\(i)"; i += 1 }
        return n
    }

    private func addRule(bundleID: String?, name: String) {
        let rule = WindowRule(name: uniqueName(name), bundleID: bundleID, title: bundleID == nil ? ".*" : nil, floating: true)
        store.config.rules.append(rule)
        selection = rule.name
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
        addRule(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
    }
}

struct RuleRow: View {
    @Binding var rule: WindowRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rule.name).font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { rule.floating ? 0 : 1 }, set: { rule.floating = $0 == 0; if rule.floating { rule.slot = nil } else if rule.slot == nil { rule.slot = 1 } })) {
                    Text("Float").tag(0)
                    Text("Fixed place").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                if !rule.floating {
                    Stepper("Place \(rule.slot ?? 1)", value: Binding(get: { rule.slot ?? 1 }, set: { rule.slot = max(1, $0) }), in: 1...99)
                        .fixedSize()
                }
            }
            HStack {
                TextField("Bundle ID (any app if empty)", text: Binding(get: { rule.bundleID ?? "" }, set: { rule.bundleID = $0.isEmpty ? nil : $0 }))
                TextField("Title regex (any title if empty)", text: Binding(get: { rule.title ?? "" }, set: { rule.title = $0.isEmpty ? nil : $0 }))
                    .foregroundStyle(rule.isValidRegex ? Color.primary : Color.red)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Displays

/// Ready-made display profiles.
private struct DisplayPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let builtin: DisplayMode
    let external: DisplayMode

    static let all: [DisplayPreset] = [
        .init(id: "everywhere", title: "Everywhere", detail: "Every display, all the time.", builtin: .always, external: .always),
        .init(id: "onthego", title: "Laptop on the go", detail: "Only the built-in screen, and only while no monitor is connected. Plug in a display and Roller steps aside.", builtin: .alone, external: .never),
        .init(id: "docked", title: "Monitors when docked", detail: "External displays always; the built-in screen only when it's on its own.", builtin: .alone, external: .always),
        .init(id: "external", title: "External displays only", detail: "Never the built-in screen.", builtin: .never, external: .always),
        .init(id: "builtin", title: "Built-in screen only", detail: "Never external displays.", builtin: .always, external: .never),
    ]
}

struct DisplaysPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var displays = Display.all()

    var body: some View {
        let facts = displays.map(\.facts)
        Form {
            Section {
                ForEach(DisplayPreset.all) { preset in
                    let selected = store.config.builtinDisplay == preset.builtin && store.config.externalDisplays == preset.external
                    Button {
                        store.config.builtinDisplay = preset.builtin
                        store.config.externalDisplays = preset.external
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                Text(preset.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("Quick setup") }

            Section {
                Picker("Built-in display", selection: $store.config.builtinDisplay) {
                    Text("Always").tag(DisplayMode.always)
                    Text("Only when no other display is connected").tag(DisplayMode.alone)
                    Text("Never").tag(DisplayMode.never)
                }
                Picker("External displays", selection: $store.config.externalDisplays) {
                    Text("Always").tag(DisplayMode.always)
                    Text("Only when it's the only display (lid closed)").tag(DisplayMode.alone)
                    Text("Never").tag(DisplayMode.never)
                }
                Toggle("Show a notice when a display change turns Roller on or off", isOn: $store.config.notifyDisplayChanges)
                Toggle("Free the shortcuts and the swipe while no display is managed", isOn: $store.config.releaseInputWhenIdle)
            } header: { Text("Display profile") } footer: {
                Text("Roller checks this every time a display is connected or disconnected. On a display it stops managing, hidden windows come back into view and stay where they are; the strip is remembered and returns when the display is managed again.")
            }

            Section {
                ForEach(displays, id: \.uuid) { d in
                    let managed = DisplayPolicy.isManaged(d.facts, among: facts, config: store.config)
                    HStack(alignment: .top) {
                        Circle().fill(managed ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 9, height: 9).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(d.name)
                                Text(d.isBuiltin ? "Built-in" : "External")
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                            Text("\(Int(d.frame.width)) × \(Int(d.frame.height)) · " + DisplayPolicy.reason(d.facts, among: facts, config: store.config))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.config.displayOverrides[d.uuid].map { $0.rawValue } ?? "auto" },
                            set: { store.config.displayOverrides[d.uuid] = DisplayOverride(rawValue: $0) })) {
                            Text("Follow profile").tag("auto")
                            Text("Always on").tag(DisplayOverride.on.rawValue)
                            Text("Always off").tag(DisplayOverride.off.rawValue)
                        }
                        .fixedSize()
                    }
                }
            } header: { Text("Connected now") } footer: {
                Text("An override wins over the profile for that one display, e.g. to keep Roller off a presentation screen or a portrait monitor. Displays are remembered by their ID, so the setting comes back when you reconnect it.")
            }

            let remembered = store.config.displayOverrides.keys.filter { uuid in !displays.contains { $0.uuid == uuid } }.sorted()
            if !remembered.isEmpty {
                Section {
                    ForEach(remembered, id: \.self) { uuid in
                        HStack {
                            Text(uuid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Text(store.config.displayOverrides[uuid] == .on ? "Always on" : "Always off").foregroundStyle(.secondary)
                            Button("Forget") { store.config.displayOverrides[uuid] = nil }
                        }
                    }
                } header: { Text("Overrides for displays not connected") }
            }

            Section {
                Text("Each managed display has its own strip, and each macOS Space too. When displays sit side by side, a window can only slide halfway off toward the neighbour before it hides; arranging displays above or below each other in System Settings › Displays avoids that.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Display.all()
        }
    }
}

// MARK: - Pausing & power

struct PausingPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                if store.config.pauseForApps.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach(store.config.pauseForApps, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Text(id)
                        }
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.config.pauseForApps.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.0) { id, name in
                            Button(name) { add(id) }
                        }
                    }
                    .fixedSize()
                    Button("Choose an App…", action: chooseApp)
                }
            } header: { Text("Pause while these apps are in front") } footer: {
                Text("Roller's shortcuts, trackpad swipe and focus follows mouse pause while one of these apps is active, so its own ⌃⌥ shortcuts and gestures work. Good for games, virtual machines and remote desktops. Windows stay on the strip.")
            }

            Section {
                Toggle("Free the shortcuts and the swipe while no display is managed", isOn: $store.config.releaseInputWhenIdle)
                Toggle("Turn animation off on battery or in Low Power Mode", isOn: $store.config.reduceMotionOnBattery)
                Toggle("Follow the macOS Reduce motion setting", isOn: $store.config.respectReduceMotion)
            } header: { Text("Idle and power") }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !store.config.pauseForApps.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func add(_ id: String) {
        if !store.config.pauseForApps.contains(id) { store.config.pauseForApps.append(id) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        add(id)
    }
}

// MARK: - Mac Setup

struct MacSetupPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var checks: [MacSetup.Check] = []

    var body: some View {
        Form {
            Section {
                ForEach(checks) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.state == .ok ? "checkmark.circle.fill" : (c.state == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                            .foregroundStyle(c.state == .ok ? Color.green : (c.state == .warning ? Color.orange : Color.secondary))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title).font(.headline)
                            Text(c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let s = c.settingsURL, c.state != .ok {
                            Button("Open") { NSWorkspace.shared.open(URL(string: s)!) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("These macOS settings decide whether every feature works") } footer: {
                Text("Roller only reads these settings. Each item turns green as you fix it. If macOS still switches desktops after you change a trackpad setting, log out and back in.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() { checks = MacSetup.run(fingers: store.config.swipeGestureFingers) }
}
