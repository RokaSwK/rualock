import AppKit
import AVFoundation

/// The watch-and-lock loop. Runs a 4 Hz tick on the main thread; face checks run on the camera's queue.
final class Watcher {
    enum State: Equatable {
        case starting, watching, typing, absent, unverified, paused, locked, noCamera, cameraDenied, notEnrolled, enrolling
    }

    /// What the latest frames showed.
    private enum Seen { case you, unverified, nobody }

    /// Extra time to blink when a matching face appears after a gap (looking back, after a pause).
    static let blinkGrace: TimeInterval = 10
    /// After an unlock, the first matching face within this long is trusted without a blink.
    static let unlockTrust: TimeInterval = 10
    /// Recognition runs at most this often; blink tracking runs on every frame.
    private static let recognitionInterval: CFTimeInterval = 0.25
    /// Frames checked per second while watching (all the camera sends); blinks last 0.1-0.3 s.
    static let watchFPS: Double = 10

    private(set) var state: State = .starting
    /// Seconds since your face was last seen (only meaningful while `absent` or `unverified`).
    private(set) var absentFor: TimeInterval = 0
    /// The current countdown length: the lock delay, plus the blink grace while a matching face
    /// that hasn't blinked is in view.
    private(set) var lockDelay: TimeInterval = Prefs.lockDelay
    var enrolled: [[Float]] { embeddings }

    let camera = Camera()
    private let engine: FaceEngine
    private var embeddings: [[Float]] = Enrollment.load()
    private var enrollSink: ((Int, [[Float]]) -> Void)?

    /// When your confirmed face was last in view.
    private var lastSeen = Date()
    /// Your confirmed face, or keyboard and mouse input carrying straight on from it.
    private var chain = PresenceChain(at: Date())
    private var presence: Date { chain.presence }
    private var typing: Bool { chain.typing }
    private var lockIssued = false
    private var lastFrame = Date()
    private var lastTick = Date()
    private var seen: Seen?
    private var track = FaceTrack()
    private var trustUntil: Date?
    private var wasLocked = false
    private var askedForCamera = false
    private var timer: Timer?

    // Touched only on the camera's video queue (fps is shared, behind the lock).
    private var lastProcessed: CFTimeInterval = 0
    private var lastRecognised: CFTimeInterval = 0
    private var fps: Double = Watcher.watchFPS
    /// Check every frame for blinks (a matching face still has to prove it's live); otherwise only
    /// the recognition frames, a few a second.
    private var blinkMode = false
    private let fpsLock = NSLock()

    init(engine: FaceEngine) {
        self.engine = engine
        camera.onFrame = { [weak self] buffer in self?.frame(buffer) }
        FaceTrack.log = { Diagnostics.shared.event($0, $1) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.resetClock()
            Diagnostics.shared.event("wake")
        }
    }

    func start() {
        trustUntil = Date().addingTimeInterval(Self.unlockTrust)  // launched at login, or by you
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let mode = Prefs.dryRun ? " (dry run)" : ""
        let blink = Prefs.requireBlink ? ", blink required" : ""
        note("watching; locking after \(Int(Prefs.lockDelay))s away\(blink)\(mode)")
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        Diagnostics.shared.event("start", [
            "version": version, "lockDelay": Prefs.lockDelay, "threshold": Double(Prefs.threshold),
            "requireBlink": Prefs.requireBlink, "dryRun": Prefs.dryRun, "samples": embeddings.count,
        ])
        tick()
    }

    // MARK: enrolment

    /// Route frames to `sink` (face count, embeddings) instead of the lock logic.
    func beginEnrollment(_ sink: @escaping (Int, [[Float]]) -> Void) {
        enrollSink = sink
        setFPS(8)
        state = .enrolling
        camera.start()
        lastFrame = Date()
    }

    func endEnrollment(saving samples: [[Float]]?) {
        enrollSink = nil
        setFPS(Self.watchFPS)
        if let samples, !samples.isEmpty {
            do {
                try Enrollment.save(samples)
                embeddings = samples
                note("saved \(samples.count) face samples")
            } catch {
                note("could not save enrolment: \(error.localizedDescription)")
            }
        }
        if let samples, !samples.isEmpty { Diagnostics.shared.event("enrolled", ["samples": samples.count]) }
        resetClock()
        seen = nil
        track = FaceTrack()
        state = .starting
        tick()
    }

    // MARK: loop

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick) > 5 { resetClock() }  // woke from sleep or stalled: not absence
        lastTick = now

        if enrollSink != nil {
            state = .enrolling
            return
        }

        let locked = System.screenLocked
        if locked {
            if !wasLocked { Diagnostics.shared.event("screen_locked", ["byRualock": lockIssued]) }
            wasLocked = true
        } else if wasLocked {  // just unlocked: the face in front of the camera is you
            wasLocked = false
            lockIssued = false
            trustUntil = now.addingTimeInterval(Self.unlockTrust)
            Diagnostics.shared.unlocked()
        }
        if locked && Pause.active {  // a pause ends when you lock, so logging back in resumes watching
            Pause.clear()
            note("screen locked: pause ended")
            Diagnostics.shared.event("pause_ended", ["by": "lock"])
        }

        if embeddings.isEmpty {
            idle(.notEnrolled)
            return
        }
        if locked || Pause.active {
            idle(locked ? .locked : .paused)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            if !askedForCamera {
                askedForCamera = true
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
            idle(.cameraDenied)
            return
        default:
            idle(.cameraDenied)
            return
        }

        if !camera.running {
            guard camera.start() else {
                idle(.noCamera)
                return
            }
            lastFrame = now
            resetClock()
            seen = nil
            track = FaceTrack()
        }

        // The camera failing must never lock you out: no frames means no countdown.
        if now.timeIntervalSince(lastFrame) > 4 {
            if state != .noCamera {
                note("camera stopped sending frames; reopening")
                Diagnostics.shared.event("camera_stalled")
            }
            state = .noCamera
            absentFor = 0
            resetClock()
            camera.reset()
            return
        }

        followInput(now)
        lockDelay = Prefs.lockDelay + (seen == .unverified ? Self.blinkGrace : 0)
        absentFor = now.timeIntervalSince(presence)
        if absentFor >= lockDelay {
            let reason = seen == .unverified ? "no blink" : now.timeIntervalSince(lastSeen) > absentFor + 0.5 ? "input stopped" : "face gone"
            let info: [String: Any] = [
                "absentFor": absentFor, "lockDelay": lockDelay, "sinceFace": now.timeIntervalSince(lastSeen),
                "inputIdle": System.inputIdle, "seen": "\(seen.map { "\($0)" } ?? "none")", "track": track.why,
                "trackVerified": track.verified, "trackMatched": track.matched, "dryRun": Prefs.dryRun,
            ]
            Diagnostics.shared.locked(reason: reason, info)
            if Prefs.dryRun {
                note("would lock: \(reason) (dry run)")
            } else {
                note("\(reason) for \(Int(absentFor))s: locking")
                lockIssued = true
                System.lockScreen()
            }
            resetClock()
            absentFor = 0
            state = Prefs.dryRun ? .watching : .locked
            return
        }
        switch seen {
        case .none: state = .starting
        case .you: state = .watching
        case .unverified: state = typing ? .typing : .unverified
        case .nobody: state = typing ? .typing : .absent
        }
    }

    /// Let keyboard and mouse input carry on from your confirmed face (see `PresenceChain`).
    private func followInput(_ now: Date) {
        let idle = System.inputIdle
        let change = chain.update(now: now, faceInView: seen == .you, faceAt: lastSeen, lastInput: now.addingTimeInterval(-idle))
        switch change {
        case "start"?: Diagnostics.shared.event("typing_start", ["sinceFace": now.timeIntervalSince(lastSeen)])
        case let why?: Diagnostics.shared.event("typing_end", ["why": why, "idle": idle, "sinceFace": now.timeIntervalSince(lastSeen)])
        case nil: break
        }
    }

    /// Start the countdown afresh: after an unlock, a pause, waking, or a camera restart.
    private func resetClock() {
        lastSeen = Date()
        chain = PresenceChain(at: lastSeen)
    }

    private func idle(_ s: State) {
        state = s
        absentFor = 0
        camera.stop()
        resetClock()  // grace period once unlocked or resumed
        seen = nil
        track = FaceTrack()
        setBlinkMode(false)
    }

    private func setFPS(_ value: Double) {
        fpsLock.lock()
        fps = value
        fpsLock.unlock()
    }

    // MARK: frames (video queue)

    private func frame(_ buffer: CVPixelBuffer) {
        fpsLock.lock()
        let rate = fps
        fpsLock.unlock()
        let t = CACurrentMediaTime()
        guard t - lastProcessed >= 1 / rate - 0.01 else { return }
        lastProcessed = t
        // Landmarks (for blinks) on every frame; the recognition model a few times a second.
        fpsLock.lock()
        let everyFrame = blinkMode || rate < Self.watchFPS
        fpsLock.unlock()
        let recognise = rate < Self.watchFPS || t - lastRecognised >= Self.recognitionInterval
        guard recognise || everyFrame else { return }
        if recognise { lastRecognised = t }
        let (count, faces) = engine.analyze(buffer, embed: recognise)
        DispatchQueue.main.async { [weak self] in self?.handle(count: count, faces: faces, at: t, recognised: recognise) }
    }

    private func handle(count: Int, faces: [FaceEngine.Face], at t: CFTimeInterval, recognised: Bool) {
        let now = Date()
        lastFrame = now
        if let sink = enrollSink {
            sink(count, faces.compactMap(\.embedding))
            return
        }
        let face = track.update(faces, at: t, detected: recognised)
        var score: Float?
        if let face, recognised {
            let threshold = Prefs.threshold
            let best = { (f: FaceEngine.Face) -> Float? in
                f.embedding.map { e in self.embeddings.map { FaceEngine.similarity($0, e) }.max() ?? 0 }
            }
            score = best(face)
            if (score ?? 0) < threshold, let you = faces.first(where: { (best($0) ?? 0) >= threshold }) {
                track.restart(with: you, at: t)  // you're in view, but the tracked face is someone else's
                track.setMatched(true)
                score = best(you)
            } else {
                track.setMatched((score ?? 0) >= threshold)
            }
        }
        defer { record(count: count, face: face, score: score, recognised: recognised) }

        guard face != nil else {
            // Nobody in view. A face missing for a frame or two (often during a blink) keeps its state.
            if t - track.lastSeen > FaceTrack.maxGap || seen == nil {
                seen = .nobody
                setBlinkMode(false)
            }
            return
        }
        guard track.matched else {
            seen = .nobody
            setBlinkMode(false)
            return
        }
        if !track.verified, let until = trustUntil, now < until {
            track.trust()
            trustUntil = nil
        }
        if !Prefs.requireBlink || track.verified {
            seen = .you
            lastSeen = now
            setBlinkMode(false)
        } else {
            seen = .unverified
            setBlinkMode(true)
        }
    }

    /// One diagnostics sample per handled frame (4 a second, 10 while waiting for a blink).
    private func record(count: Int, face: FaceEngine.Face?, score: Float?, recognised: Bool) {
        var r: [String: Any] = [
            "state": "\(state)", "seen": seen.map { "\($0)" } ?? "none", "faces": count, "rec": recognised,
            "verified": track.verified, "matched": track.matched, "why": track.why, "blinkMode": blinkModeOn,
            "idle": System.inputIdle, "absent": absentFor, "delay": lockDelay, "typing": typing,
        ]
        if let score { r["score"] = Double(score) }
        if let face {
            r["size"] = Double(face.box.width)
            if let o = face.openness { r["eyes"] = o }
            if let m = face.mouthOpen { r["mouthOpen"] = m }
            if let m = face.mouthWidth { r["mouthWidth"] = m }
        }
        Diagnostics.shared.sample(r)
    }

    private var blinkModeOn: Bool {
        fpsLock.lock()
        defer { fpsLock.unlock() }
        return blinkMode
    }

    private func setBlinkMode(_ on: Bool) {
        fpsLock.lock()
        blinkMode = on
        fpsLock.unlock()
    }
}
