import AppKit
import Combine
import ServiceManagement
import SwiftUI
import RollerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let ipc = IPCServer()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    let navigation = SettingsNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        log("Roller \(Updater.currentVersion) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:_:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        let store = ConfigStore.shared
        // The login item can be removed in System Settings; reflect that.
        if store.config.launchAtLogin != LoginItem.isEnabled { store.config.launchAtLogin = LoginItem.isEnabled }
        let engine = Engine.shared
        engine.config = store.config
        store.onChange = { config in
            Engine.shared.apply(config)
            LoginItem.sync(config.launchAtLogin)
        }
        engine.onStatusChange = { [weak self] _ in self?.updateStatusIcon() }

        setUpStatusItem()
        ipc.start()

        if store.config.onboardingDone {
            engine.start()
        } else {
            showOnboarding()
        }
        if store.config.checkForUpdates { Updater.shared.scheduleDailyCheck() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.applicationWillTerminate()
        ipc.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s) else { return }
        Automation.handle(url: url)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let running = Engine.shared.status == .running
        let image = NSImage(systemSymbolName: running ? "rectangle.split.3x1.fill" : "rectangle.split.3x1",
                            accessibilityDescription: "Roller")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = !running
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = Engine.shared
        let state: String
        switch engine.status {
        case .running: state = "Running"
        case .stopped: state = "Stopped"
        case .needsPermission: state = "Needs Accessibility permission"
        }
        let header = NSMenuItem(title: "Roller — \(state)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if engine.status == .running {
            menu.addItem(item("Stop", #selector(stopEngine)))
        } else {
            menu.addItem(item("Start", #selector(startEngine)))
        }
        menu.addItem(item("Restart", #selector(restartEngine)))
        if engine.status == .needsPermission {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Roller", #selector(openSettingsAction), key: ","))
        menu.addItem(item("Mac Setup…", #selector(openMacSetup)))
        menu.addItem(item("Shortcuts…", #selector(openShortcuts)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Open Configuration", #selector(openConfiguration)))
        menu.addItem(item("Reveal Engine Log", #selector(revealLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Roller", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func startEngine() { Engine.shared.start() }
    @objc private func stopEngine() { Engine.shared.stop() }
    @objc private func restartEngine() { Engine.shared.restart() }
    @objc private func openAccessibility() { NSWorkspace.shared.open(URL(string: MacSetup.accessibilityPrivacyURL)!) }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func openMacSetup() { openSettings(page: .macSetup) }
    @objc private func openShortcuts() { openSettings(page: .shortcuts) }
    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true) }
    @objc private func openConfiguration() { ConfigStore.shared.revealInFinder() }
    @objc private func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([Log.shared.url]) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Windows

    func openSettings(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(ConfigStore.shared)
                .environmentObject(navigation))
            let w = NSWindow(contentViewController: host)
            w.title = "Roller"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 820, height: 600))
            w.minSize = NSSize(width: 700, height: 460)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in
                self?.finishOnboarding()
            }.environmentObject(ConfigStore.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to Roller"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        ConfigStore.shared.config.onboardingDone = true
        onboardingWindow?.close()
        Engine.shared.start()
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === onboardingWindow, !ConfigStore.shared.config.onboardingDone {
            // Closing the guide still starts Roller; it can be reopened from Help.
            ConfigStore.shared.config.onboardingDone = true
            Engine.shared.start()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let open = [self.settingsWindow, self.onboardingWindow].contains { $0?.isVisible == true }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// Launch at login through the system's login items (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func sync(_ wanted: Bool) {
        guard wanted != isEnabled else { return }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("launch at login: \(error)")
        }
    }
}
