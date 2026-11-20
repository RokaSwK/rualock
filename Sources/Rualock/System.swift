import AppKit
import CoreGraphics
import LocalAuthentication
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "com.rualock.mac", category: "app")
private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rualock.log")
private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Logs to the unified log (Console.app) and to ~/Library/Logs/Rualock.log.
func note(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    let line = "\(stamp.string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

enum System {
    /// Locks the screen the way Control-Command-Q does. Uses the private `SACLockScreenImmediate`;
    /// if a future macOS removes it, falls back to sleeping the display, which locks when
    /// "Require password immediately" is on.
    static func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Lock.self)()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    /// Seconds since the last keyboard, mouse or trackpad input in this login session. No permission needed.
    static var inputIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Touch ID, falling back to the Mac password. `done` runs on the main thread.
    static func authenticate(_ reason: String, done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            note("authentication unavailable: \(error?.localizedDescription ?? "unknown")")
            done(false)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    static var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                note("login item: \(error.localizedDescription)")
            }
        }
    }

    static func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
}
