import AppKit

/// Looks for a newer release on GitHub. It sends nothing about you or your
/// Mac; it only reads the public "latest release" page.
final class Updater {
    static let shared = Updater()
    static let repository = "current/roller"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var timer: Timer?
    private let lastCheckKey = "lastUpdateCheck"

    func scheduleDailyCheck() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86_400 { check(userInitiated: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (json?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                guard let tag, let page else {
                    if userInitiated {
                        self.alert("Couldn't check for updates", error?.localizedDescription ?? "No releases were found.")
                    }
                    return
                }
                if Updater.isNewer(tag, than: Updater.currentVersion) {
                    let a = NSAlert()
                    a.messageText = "Roller \(tag) is available"
                    a.informativeText = "You have \(Updater.currentVersion). Download the new version from GitHub?"
                    a.addButton(withTitle: "Download")
                    a.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
                } else if userInitiated {
                    self.alert("Roller is up to date", "Version \(Updater.currentVersion) is the newest.")
                }
            }
        }.resume()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
