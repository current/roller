import AppKit
import Combine
import RollerCore

/// Owns the configuration: the settings UI edits `config`, changes apply at
/// once and are written to the TOML file; edits made to the file by hand are
/// picked up live.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet {
            guard !applyingFromDisk, config != oldValue else { return }
            onChange?(config)
            scheduleSave()
        }
    }
    @Published private(set) var loadError: String?

    var onChange: ((Config) -> Void)?

    private(set) var url: URL
    private var applyingFromDisk = false
    private var saveWork: DispatchWorkItem?
    private var lastWritten: String?
    private var lastModified: Date?
    private var watchTimer: Timer?

    private init() {
        url = Config.filePath()
        config = .default
        load()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkForEdits() }
    }

    func load() {
        url = Config.filePath()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // First run: write the defaults so the file is there to edit.
            loadError = nil
            save()
            return
        }
        lastModified = modificationDate()
        lastWritten = text
        do {
            let parsed = try Config(toml: text)
            applyingFromDisk = true
            config = parsed
            applyingFromDisk = false
            loadError = nil
            onChange?(parsed)
        } catch {
            loadError = "\(url.lastPathComponent): \(error)"
            log("config error: \(error)")
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func checkForEdits() {
        guard let m = modificationDate(), m != lastModified else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8), text != lastWritten else {
            lastModified = m
            return
        }
        log("config file changed on disk, reloading")
        load()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func save() {
        let text = config.tomlString()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastWritten = text
            lastModified = modificationDate()
        } catch {
            log("could not write config: \(error)")
        }
    }

    func revealInFinder() {
        save()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
