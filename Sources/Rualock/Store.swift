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

    /// Cosine similarity needed to count a face as yours: the strictness setting, unless overridden
    /// with `defaults write com.rualock.mac matchThreshold`.
    static var threshold: Float {
        let v = d.float(forKey: "matchThreshold")
        return v > 0 ? v : matchStrictness.threshold
    }

    static var matchStrictness: MatchStrictness {
        get { d.string(forKey: "matchStrictness").flatMap(MatchStrictness.init) ?? .standard }
        set { d.set(newValue.rawValue, forKey: "matchStrictness") }
    }

    static let typingLimits: [Double] = [0, 30, 90, 180]

    /// How long keyboard and mouse use can keep you present without your face (0: never). See `PresenceChain`.
    static var typingLimit: Double {
        get { d.object(forKey: "typingLimit") as? Double ?? 90 }
        set { d.set(newValue, forKey: "typingLimit") }
    }

    static let blinkGraces: [Double] = [5, 10, 20]

    /// Extra seconds before locking while a face that matches you hasn't blinked yet.
    static var blinkGrace: Double {
        get { let v = d.double(forKey: "blinkGrace"); return v > 0 ? v : 10 }
        set { d.set(newValue, forKey: "blinkGrace") }
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

    /// The status light's look: a preset, or `.custom` with the values below. Changing any value makes
    /// it custom, starting from the preset you were on.
    static var islandStyle: IslandStyle {
        get {
            if let s = d.string(forKey: "islandStyle").flatMap(IslandStyle.init) { return s }
            // Sizes set before there were presets: keep them.
            return ["islandHeight", "islandDot", "islandText"].contains { d.object(forKey: $0) != nil } ? .custom : .standard
        }
        set {
            if newValue == .custom, islandStyle != .custom, let look = islandStyle.look {
                for (key, value) in look.values { d.set(value, forKey: key) }  // start from what you saw
            }
            d.set(newValue.rawValue, forKey: "islandStyle")
        }
    }

    private static func look(_ key: String, _ value: KeyPath<IslandLook, Double>, in range: ClosedRange<Double>? = nil) -> Double {
        if let look = islandStyle.look { return look[keyPath: value] }
        let v = d.object(forKey: key) as? Double ?? IslandLook.standard[keyPath: value]
        return range.map { v.clamped(to: $0) } ?? v
    }

    private static func setLook(_ key: String, _ value: Double) {
        islandStyle = .custom
        d.set(value, forKey: key)
    }

    /// How tall the status light is beside the notch, in points; taller values are capped at the notch.
    static var islandHeight: Double {
        get { look("islandHeight", \.height) }
        set { setLook("islandHeight", newValue) }
    }

    /// Radius of the status light's dot, in points; the countdown ring around it scales with it.
    static let islandDotSizes: ClosedRange<Double> = 2 ... 8
    static var islandDot: Double {
        get { look("islandDot", \.dot, in: islandDotSizes) }
        set { setLook("islandDot", newValue) }
    }

    /// Size of the status light's words ("Watching", "Locking in 3s"), in points.
    static let islandTextSizes: ClosedRange<Double> = 8 ... 16
    static var islandText: Double {
        get { look("islandText", \.text, in: islandTextSizes) }
        set { setLook("islandText", newValue) }
    }

    /// Radius of the light's outer bottom corner, in points.
    static let islandCornerSizes: ClosedRange<Double> = 0 ... 16
    static var islandCorner: Double {
        get { look("islandCorner", \.corner, in: islandCornerSizes) }
        set { setLook("islandCorner", newValue) }
    }

    /// The concave curve where the light's top meets the screen's top edge, in points.
    static let islandFlareSizes: ClosedRange<Double> = 0 ... 10
    static var islandEar: Double {
        get { look("islandEar", \.ear, in: islandFlareSizes) }
        set { setLook("islandEar", newValue) }
    }

    /// The concave curve where the light's bottom meets the notch's side, in points. Only shows while
    /// the light is shorter than the notch.
    static var islandJoin: Double {
        get { look("islandJoin", \.join, in: islandFlareSizes) }
        set { setLook("islandJoin", newValue) }
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

/// How closely a face must match your enrolment. Your own scores are mostly 0.6-0.8; other people's
/// mostly under 0.3.
enum MatchStrictness: String, CaseIterable {
    case relaxed, standard, strict

    var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }

    var threshold: Float {
        switch self {
        case .relaxed: return 0.30
        case .standard: return 0.363  // OpenCV's recommended value for SFace
        case .strict: return 0.45
        }
    }
}

/// Presets for the status light. Heights over the notch's are capped to it, so `.notch` is always full height.
enum IslandStyle: String, CaseIterable {
    case compact, standard, large, notch, custom

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        case .notch: return "Notch height"
        case .custom: return "Custom"
        }
    }

    var look: IslandLook? {
        switch self {
        case .compact: return IslandLook(height: 17, dot: 3, text: 9, corner: 6, ear: 3, join: 3)
        case .standard: return .standard
        case .large: return IslandLook(height: 26, dot: 4.5, text: 12, corner: 10, ear: 5, join: 5)
        case .notch: return IslandLook(height: 100, dot: 5, text: 11.5, corner: 9, ear: 6, join: 0)
        case .custom: return nil
        }
    }
}

/// Sizes of the status light, in points. See `Prefs.islandHeight` and the rest.
struct IslandLook {
    var height, dot, text, corner, ear, join: Double

    static let standard = IslandLook(height: 21, dot: 3.5, text: 10, corner: 8, ear: 4, join: 4)

    var values: [(String, Double)] {
        [("islandHeight", height), ("islandDot", dot), ("islandText", text), ("islandCorner", corner), ("islandEar", ear), ("islandJoin", join)]
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
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
