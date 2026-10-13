import AppKit

/// Window server functions looked up at runtime, so Roller still launches
/// (with reduced features) if Apple ever removes one. None of them need SIP
/// changes.
enum Private {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ names: String..., as: T.Type) -> T? {
        for name in names {
            if let h = handle, let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(p, to: T.self) } // RTLD_DEFAULT
        }
        return nil
    }

    // Spaces
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    static let mainConnection = sym(skyLight, "SLSMainConnectionID", "CGSMainConnectionID", as: MainConnectionFn.self)
    static let copyManagedDisplaySpaces = sym(skyLight, "SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFn.self)
    static let copySpacesForWindows = sym(skyLight, "SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)

    // Focus
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    static let getProcessForPID = sym(appServices, "GetProcessForPID", as: GetProcessForPIDFn.self)
    static let setFrontProcess = sym(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    static let postEventRecord = sym(skyLight, "SLPSPostEventRecordTo", as: PostEventRecordFn.self)

    /// Brings one specific window to the front and makes it key, without
    /// raising the app's other windows. Falls back to plain activation.
    static func focus(pid: pid_t, window: CGWindowID, element: AXUIElement) {
        var psn = ProcessSerialNumber()
        if let getPSN = getProcessForPID, let front = setFrontProcess, let post = postEventRecord,
           getPSN(pid, &psn) == noErr {
            _ = front(&psn, window, 0x200) // kCPSUserGenerated
            var wid = window
            for kind: UInt8 in [0x01, 0x02] {
                var bytes = [UInt8](repeating: 0, count: 0xF8)
                bytes[0x04] = 0xF8
                bytes[0x08] = kind
                bytes[0x3A] = 0x10
                withUnsafeBytes(of: &wid) { raw in for i in 0..<4 { bytes[0x3C + i] = raw[i] } }
                for i in 0x20..<0x30 { bytes[i] = 0xFF }
                _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
            }
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        }
        element.raise()
    }
}
