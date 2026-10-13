import Foundation

/// The Unix socket the app listens on for `roller` CLI commands. Requests
/// are one line of text; the reply is text, and the server closes the
/// connection when done.
public enum IPC {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Roller", isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent("roller.sock").path
    }

    /// Fills a `sockaddr_un` for `path`. Returns nil when the path is too long.
    public static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Sends one command and returns the reply. Used by the CLI.
    public static func send(_ command: String, path: String = socketPath, timeout: TimeInterval = 5) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        defer { close(fd) }
        guard var addr = address(path) else { throw IPCError.pathTooLong }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { throw IPCError.notRunning }
        let data = Array((command + "\n").utf8)
        var sent = 0
        while sent < data.count {
            let n = data[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw IPCError.system("write", errno) }
            sent += n
        }
        var reply = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        return String(decoding: reply, as: UTF8.self)
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case notRunning
    case pathTooLong
    case system(String, Int32)

    public var description: String {
        switch self {
        case .notRunning: return "Roller is not running."
        case .pathTooLong: return "The socket path is too long."
        case .system(let call, let e): return "\(call) failed: \(String(cString: strerror(e)))"
        }
    }
}

/// What session restore saves for one window, so it can be found again
/// after Roller restarts (same window number) or after the app restarts
/// (same app and title).
public struct SavedWindow: Codable, Equatable {
    public var id: WindowID
    public var bundleID: String?
    public var title: String
    public init(id: WindowID, bundleID: String?, title: String) {
        self.id = id; self.bundleID = bundleID; self.title = title
    }
}

public struct SavedColumn: Codable, Equatable {
    public var windows: [SavedWindow]
    public var heights: [Double]
    public var width: Double
    public var tabbed: Bool
    public init(windows: [SavedWindow], heights: [Double], width: Double, tabbed: Bool) {
        self.windows = windows; self.heights = heights; self.width = width; self.tabbed = tabbed
    }
}

public struct SavedStrip: Codable, Equatable {
    /// "<display uuid>|<space id>"
    public var key: String
    public var columns: [SavedColumn]
    public var focus: Int
    public init(key: String, columns: [SavedColumn], focus: Int) {
        self.key = key; self.columns = columns; self.focus = focus
    }
}

public struct SavedSession: Codable, Equatable {
    public var version = 1
    public var strips: [SavedStrip]
    public var floating: [SavedWindow]
    public init(strips: [SavedStrip], floating: [SavedWindow]) {
        self.strips = strips; self.floating = floating
    }
}

extension SavedSession {
    /// Rebuilds a strip from saved columns, given a resolver that maps a saved
    /// window to a live window ID (or nil when it no longer exists). Each
    /// live window is used at most once.
    public static func restore(_ saved: SavedStrip, resolve: (SavedWindow) -> WindowID?) -> Strip {
        var used = Set<WindowID>()
        var columns: [Column] = []
        for sc in saved.columns {
            var ws: [WindowID] = []
            var hs: [Double] = []
            for (i, sw) in sc.windows.enumerated() {
                guard let id = resolve(sw), !used.contains(id) else { continue }
                used.insert(id)
                ws.append(id)
                hs.append(sc.heights.indices.contains(i) ? sc.heights[i] : 1)
            }
            guard !ws.isEmpty else { continue }
            var c = Column(windows: ws, width: sc.width, tabbed: sc.tabbed)
            c.heights = hs
            columns.append(c)
        }
        var s = Strip(columns: columns, focus: saved.focus)
        s.normalize()
        return s
    }
}
