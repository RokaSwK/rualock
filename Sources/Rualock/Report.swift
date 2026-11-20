import Foundation

/// `Rualock --report [days]`: a summary of the diagnostics, to see why locks happen and tune the rules.
enum Report {
    static func run(days: Int) -> Int32 {
        let dir = Diagnostics.shared.dir
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let locks = load(dir, "locks", since), events = load(dir, "events", since), samples = load(dir, "samples", since)
        print("Rualock diagnostics, last \(days) day(s), from \(dir.path)\n")
        if samples.isEmpty && events.isEmpty {
            print("No data yet. Diagnostics are recorded while Rualock watches (Settings › Diagnostics).")
            return 0
        }

        // Locks
        let real = locks.filter { !($0["dryRun"] as? Bool ?? false) }
        let falseLocks = real.filter { $0["suspectedFalse"] as? Bool ?? false }
        print("LOCKS: \(real.count) (\(falseLocks.count) probably false: unlocked within \(Int(Diagnostics.falseLockWindow)) s)")
        for (reason, group) in Dictionary(grouping: real, by: { $0["reason"] as? String ?? "?" }).sorted(by: { $0.value.count > $1.value.count }) {
            let f = group.filter { $0["suspectedFalse"] as? Bool ?? false }.count
            print("  \(reason): \(group.count), \(f) probably false")
        }
        let dry = locks.count - real.count
        if dry > 0 { print("  (+ \(dry) dry-run \"would lock\")") }

        if !falseLocks.isEmpty {
            print("\nTHE 10 s BEFORE EACH PROBABLE FALSE LOCK")
            for lock in falseLocks.suffix(15) {
                let at = lock["lockedAt"] as? Double ?? 0
                let before = (lock["before"] as? [[String: Any]] ?? []).filter { ($0["t"] as? Double ?? 0) >= at - 10 }
                let frames = before.filter { $0["event"] == nil }
                let noFace = frames.filter { ($0["faces"] as? Int ?? 0) == 0 }.count
                let unmatched = frames.filter { ($0["faces"] as? Int ?? 0) > 0 && !($0["matched"] as? Bool ?? false) }.count
                let waiting = frames.filter { ($0["seen"] as? String) == "unverified" }.count
                let scores = frames.compactMap { $0["score"] as? Double }.sorted()
                let names = before.compactMap { $0["event"] as? String }
                let typed = frames.filter { ($0["idle"] as? Double ?? 99) < 3 }.count
                print(String(format: "  %@  %@, unlocked after %.0f s: %d frames, %d%% no face, %d%% face not matched, %d%% waiting for a blink, typing in %d%%, scores %@",
                             time(at), lock["reason"] as? String ?? "?", lock["unlockedAfter"] as? Double ?? 0, frames.count,
                             pct(noFace, frames.count), pct(unmatched, frames.count), pct(waiting, frames.count), pct(typed, frames.count),
                             scores.isEmpty ? "none" : String(format: "%.2f-%.2f (median %.2f)", scores.first!, scores.last!, scores[scores.count / 2])))
                let counts = Dictionary(grouping: names, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted()
                if !counts.isEmpty { print("      events: \(counts.joined(separator: ", "))") }
            }
        }

        // Events
        print("\nEVENTS")
        func tally(_ name: String, by key: String) {
            let group = events.filter { ($0["event"] as? String) == name }
            guard !group.isEmpty else { return }
            let parts = Dictionary(grouping: group, by: { "\($0[key] ?? "?")" }).map { "\($0.key) \($0.value.count)" }.sorted()
            print("  \(name) (\(group.count)) by \(key): \(parts.joined(separator: ", "))")
        }
        tally("track_new", by: "reason")
        tally("verified", by: "by")
        tally("unmatched", by: "wasVerified")
        tally("typing_end", by: "why")
        tally("screen_locked", by: "byRualock")
        tally("unlock", by: "suspectedFalse")
        let closures = events.filter { ($0["event"] as? String) == "eyes_closed" }
        if !closures.isEmpty {
            let d = closures.compactMap { $0["seconds"] as? Double }.sorted()
            let counted = closures.filter { $0["counted"] as? Bool ?? false }.count
            print(String(format: "  eyes_closed (%d): %d counted as blinks; duration p25 %.2f s, median %.2f s, p75 %.2f s, p90 %.2f s",
                         closures.count, counted, q(d, 0.25), q(d, 0.5), q(d, 0.75), q(d, 0.9)))
        }
        let tolerated = events.filter { ($0["event"] as? String) == "miss_tolerated" }.count
        if tolerated > 0 { print("  miss_tolerated: \(tolerated)") }
        let typingStarts = events.filter { ($0["event"] as? String) == "typing_start" }.count
        if typingStarts > 0 { print("  typing_start: \(typingStarts) (typing kept you present without your face)") }

        // Samples
        let frames = samples.filter { $0["rec"] as? Bool ?? true }
        print(String(format: "\nFRAMES: %d recognition frames (about %.1f h watched)", frames.count, Double(frames.count) / 4 / 3600))
        let states = Dictionary(grouping: frames, by: { $0["state"] as? String ?? "?" }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        print("  state: " + states.map { "\($0.0) \(pct($0.1, frames.count))%" }.joined(separator: ", "))
        let mine = frames.compactMap { s -> Double? in (s["matched"] as? Bool ?? false) ? s["score"] as? Double : nil }.sorted()
        if !mine.isEmpty {
            print(String(format: "  your match score: p5 %.2f, p25 %.2f, median %.2f, p75 %.2f (threshold %.3f)",
                         q(mine, 0.05), q(mine, 0.25), q(mine, 0.5), q(mine, 0.75), Double(Prefs.threshold)))
        }
        let others = frames.compactMap { s -> Double? in (s["matched"] as? Bool ?? true) ? nil : s["score"] as? Double }.sorted()
        if !others.isEmpty {
            print(String(format: "  unmatched faces' score: median %.2f, p95 %.2f, max %.2f", q(others, 0.5), q(others, 0.95), others.last!))
        }
        let typingNoFace = frames.filter { ($0["faces"] as? Int ?? 0) == 0 && ($0["idle"] as? Double ?? 99) < 1 }.count
        print("  frames with no face while you were typing: \(pct(typingNoFace, frames.count))%")
        return 0
    }

    private static func load(_ dir: URL, _ kind: String, _ since: Double) -> [[String: Any]] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(kind + "-") && $0.hasSuffix(".jsonl") }.sorted()
        var out: [[String: Any]] = []
        for name in files {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if (obj["t"] as? Double ?? obj["lockedAt"] as? Double ?? 0) >= since { out.append(obj) }
            }
        }
        return out
    }

    private static func pct(_ n: Int, _ of: Int) -> Int { of == 0 ? 0 : Int((Double(n) / Double(of) * 100).rounded()) }
    private static func q(_ sorted: [Double], _ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private static func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
