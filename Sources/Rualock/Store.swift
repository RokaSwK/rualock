import Foundation

/// Settings and the pause, kept in UserDefaults (domain com.rualock.mac).
enum Prefs {
    private static let d = UserDefaults.standard

    static let lockDelays: [Double] = [5, 8, 15, 30, 60]

    /// Seconds without your face before the Mac locks.
    static var lockDelay: Double {
        get { let v = d.double(forKey: "lockDelay"); return v > 0 ? min(v, 60) : 8 }
        set { d.set(newValue, forKey: "lockDelay") }
    }

    /// Cosine similarity needed to count a face as yours (OpenCV's recommended value for SFace).
    static var threshold: Float {
        let v = d.float(forKey: "matchThreshold")
        return v > 0 ? v : 0.363
    }

    /// Log "would lock" instead of locking. Set with `-dryRun YES` on the command line.
    static var dryRun: Bool { d.bool(forKey: "dryRun") }

    /// Record numbers for tuning in ~/Library/Application Support/Rualock/Diagnostics. See `Diagnostics`.
    static var recordDiagnostics: Bool {
        get { d.object(forKey: "recordDiagnostics") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordDiagnostics") }
    }

    /// Count a face as yours only once it has blinked, so a photo can't stand in for you.
    static var requireBlink: Bool {
        get { d.object(forKey: "requireBlink") as? Bool ?? true }
        set { d.set(newValue, forKey: "requireBlink") }
    }

    /// Prank mode: instead of locking, freeze the screen behind an invisible window until your face is
    /// back, or the Mac is locked and unlocked. See `FreezeOverlay`.
    static var freezeInstead: Bool {
        get { d.bool(forKey: "freezeInstead") }
        set { d.set(newValue, forKey: "freezeInstead") }
    }

    /// The status light that grows out of the camera notch.
    static var showIsland: Bool {
        get { d.object(forKey: "showIsland") as? Bool ?? true }
        set { d.set(newValue, forKey: "showIsland") }
    }

    /// How tall the status light is beside the notch.
    static var islandSize: IslandSize {
        get { d.string(forKey: "islandSize").flatMap(IslandSize.init) ?? .medium }
        set { d.set(newValue.rawValue, forKey: "islandSize") }
    }

    /// The icon in the menu bar.
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuBarIcon") }
    }

    static var didOfferLoginItem: Bool {
        get { d.bool(forKey: "didOfferLoginItem") }
        set { d.set(newValue, forKey: "didOfferLoginItem") }
    }
}

/// Heights for the status light: the ring with a small, medium or large margin above and below,
/// or as tall as the notch.
enum IslandSize: String, CaseIterable {
    case short, medium, tall, notch

    var title: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .tall: return "Tall"
        case .notch: return "As tall as the notch"
        }
    }
}

enum Pause {
    private static let d = UserDefaults.standard

    /// (started, until) of the current pause, or nil.
    static var window: (started: Date, until: Date)? {
        let until = d.double(forKey: "pauseUntil")
        guard until > Date().timeIntervalSince1970 else { return nil }
        let started = d.double(forKey: "pauseStarted")
        return (Date(timeIntervalSince1970: started > 0 ? started : until - 15 * 60), Date(timeIntervalSince1970: until))
    }

    static var active: Bool { window != nil }

    static func start(minutes: Double) {
        let now = Date().timeIntervalSince1970
        d.set(now, forKey: "pauseStarted")
        d.set(now + minutes * 60, forKey: "pauseUntil")
        note("paused for \(Int(minutes)) min")
    }

    static func clear() {
        d.removeObject(forKey: "pauseUntil")
        d.removeObject(forKey: "pauseStarted")
    }
}

/// Your face embeddings, in ~/Library/Application Support/Rualock, readable only by you.
enum Enrollment {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rualock/face-embeddings.bin")
    }

    static func load() -> [[Float]] {
        guard let data = try? Data(contentsOf: file), data.count % (FaceEngine.dimensions * 4) == 0 else { return [] }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return stride(from: 0, to: floats.count, by: FaceEngine.dimensions).map {
            Array(floats[$0 ..< $0 + FaceEngine.dimensions])
        }
    }

    static func save(_ embeddings: [[Float]]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = embeddings.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
