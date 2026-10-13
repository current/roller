import AppKit
import RollerCore

/// Serves `roller` CLI commands on a Unix socket only the user can open.
final class IPCServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "roller.ipc")

    func start() {
        let path = IPC.socketPath
        try? FileManager.default.createDirectory(at: IPC.supportDirectory, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = IPC.address(path) else { log("ipc: cannot create socket"); return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { log("ipc: bind failed: \(String(cString: strerror(errno)))"); close(fd); fd = -1; return }
        chmod(path, 0o600)
        listen(fd, 8)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(IPC.socketPath)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1024)
        while data.count < 4096 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(UInt8(ascii: "\n")) { break }
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = DispatchQueue.main.sync { Automation.run(line) }
        let bytes = Array((reply + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        close(client)
    }
}

enum Automation {
    /// Runs a command from the CLI or a URL. Returns the reply text.
    static func run(_ command: String) -> String {
        let name = command.split(separator: " ").first.map(String.init) ?? ""
        switch name {
        case "status": return Engine.shared.statusText
        case "list": return Engine.shared.listJSON()
        default:
            guard let action = Action(name: name) else { return "error: unknown command '\(name)'" }
            return Engine.shared.perform(action)
        }
    }

    /// Handles `roller://focus_left` and `roller://action/focus_left`.
    static func handle(url: URL) {
        guard url.scheme?.lowercased() == "roller" else { return }
        var parts = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        if parts.first == "action" || parts.first == "run" { parts.removeFirst() }
        guard let name = parts.first else { return }
        let reply = run(name)
        log("url \(url.absoluteString): \(reply)")
    }
}
