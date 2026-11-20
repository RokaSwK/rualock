import Foundation

/// Local diagnostics for tuning Rualock on real use. Numbers only: no images and no face embeddings.
/// Everything stays in ~/Library/Application Support/Rualock/Diagnostics and is kept for 14 days.
///
/// - `samples-YYYY-MM-DD.jsonl`: one line per recognition frame (4 a second while watching): faces
///   seen, match score, eye openness, mouth shape, keyboard/mouse idle time, state, countdown.
/// - `events-YYYY-MM-DD.jsonl`: every decision: new face track and why, verification and how,
///   tolerated misses, eye closures, typing keeping you present, locks, unlocks, pauses.
/// - `locks-YYYY-MM-DD.jsonl`: each lock with the 30 seconds of samples and events before it, and how soon you
///   unlocked. Unlocking within 15 seconds marks it as a probable false lock.
///
/// `Rualock --report` summarises these files.
final class Diagnostics {
    static let shared = Diagnostics()
    static let falseLockWindow: TimeInterval = 15
    static let keepDays = 14
    private static let context: TimeInterval = 30

    let dir: URL
    private let queue = DispatchQueue(label: "rualock.diagnostics", qos: .utility)
    private var handles: [String: FileHandle] = [:]  // on `queue`
    private var recent: [[String: Any]] = []          // main thread: the last 30 s
    private var pendingLock: (at: Date, record: [String: Any])?

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rualock/Diagnostics")
        queue.async { [dir] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            Self.prune(dir)
        }
    }

    private var enabled: Bool { Prefs.recordDiagnostics }

    /// One recognition frame. Call on the main thread.
    func sample(_ fields: [String: Any]) {
        guard enabled else { return }
        var r = fields
        r["t"] = Date().timeIntervalSince1970
        remember(r)
        write("samples", r)
    }

    /// A decision or something that happened. Call on the main thread.
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        var r = fields
        r["t"] = Date().timeIntervalSince1970
        r["event"] = name
        remember(r)
        write("events", r)
    }

    /// Rualock locked the screen. The record is written when you unlock, with how long that took.
    func locked(reason: String, _ fields: [String: Any]) {
        guard enabled else { return }
        var f = fields
        f["reason"] = reason
        event("lock", f)
        var record = f
        record["lockedAt"] = Date().timeIntervalSince1970
        record["before"] = recent
        if fields["dryRun"] as? Bool ?? false {  // nothing to unlock: keep it now
            write("locks", record)
            return
        }
        pendingLock = (Date(), record)
    }

    /// The screen was unlocked. Completes the pending lock record, if Rualock caused the lock.
    func unlocked() {
        let pending = pendingLock
        pendingLock = nil  // consumed even when recording is off, so it can't attach to a later unlock
        guard enabled else { return }
        guard let pending else {
            event("unlock", ["byRualock": false])
            return
        }
        let after = Date().timeIntervalSince(pending.at)
        let suspected = after <= Self.falseLockWindow
        event("unlock", ["byRualock": true, "after": after, "suspectedFalse": suspected])
        var record = pending.record
        record["unlockedAfter"] = after
        record["suspectedFalse"] = suspected
        write("locks", record)
        if suspected { note(String(format: "unlocked %.0f s after a lock (%@): probably a false lock", after, record["reason"] as? String ?? "?")) }
    }

    private func remember(_ r: [String: Any]) {
        recent.append(r)
        let cutoff = Date().timeIntervalSince1970 - Self.context
        if let first = recent.firstIndex(where: { ($0["t"] as? Double ?? 0) >= cutoff }), first > 0 {
            recent.removeFirst(first)
        }
    }

    private func write(_ kind: String, _ record: [String: Any], daily: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: Self.rounded(record), options: [.sortedKeys]) else { return }
        queue.async { [dir] in
            let name = daily ? "\(kind)-\(Self.day()).jsonl" : "\(kind).jsonl"
            if self.handles[name] == nil {
                // A new day: close yesterday's files.
                for (n, h) in self.handles where n.hasPrefix(kind + "-") {
                    try? h.close()
                    self.handles[n] = nil
                }
                Self.prune(dir)  // also on day rollover, for a watcher that runs for weeks
                let url = dir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                self.handles[name] = try? FileHandle(forWritingTo: url)
                _ = try? self.handles[name]?.seekToEnd()
            }
            do {
                try self.handles[name]?.write(contentsOf: data + Data("\n".utf8))
            } catch {  // a full disk must never take the watcher down: drop this file and retry next time
                try? self.handles[name]?.close()
                self.handles[name] = nil
            }
        }
    }

    /// Doubles to 3 decimals, so the files stay small.
    private static func rounded(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? NSDecimalNumber(string: String(format: "%.3f", d)) : 0
        case let f as Float: return rounded(Double(f))
        case let c as CGFloat: return rounded(Double(c))
        case let dict as [String: Any]: return dict.mapValues { rounded($0) }
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n
        case let list as [Any]: return list.map { rounded($0) }
        default: return value
        }
    }

    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func prune(_ dir: URL) {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.lastPathComponent.contains("-20") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
