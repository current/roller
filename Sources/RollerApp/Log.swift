import Foundation

/// The engine log at ~/Library/Logs/Roller/roller.log (Help › Reveal Engine Log).
final class Log {
    static let shared = Log()

    let url: URL
    private let queue = DispatchQueue(label: "roller.log")
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Roller", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("roller.log")
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 2_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [weak self] in
            #if DEBUG
            FileHandle.standardError.write(line.data(using: .utf8)!)
            #endif
            self?.handle?.write(line.data(using: .utf8)!)
        }
    }
}

func log(_ message: @autoclosure () -> String) {
    Log.shared.write(message())
}
