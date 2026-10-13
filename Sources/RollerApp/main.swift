import AppKit

// Single instance: a second launch just opens the first one's settings.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.roller.Roller"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty {
    NSWorkspace.shared.open(URL(string: "roller://open_settings")!)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
