import AppKit
import AVFoundation

/// The watch-and-lock loop. Runs a 4 Hz tick on the main thread; face checks run on the camera's queue.
final class Watcher {
    enum State: Equatable {
        case starting, watching, absent, paused, locked, noCamera, cameraDenied, notEnrolled, enrolling
    }

    private(set) var state: State = .starting
    /// Seconds since your face was last seen (only meaningful while `absent`).
    private(set) var absentFor: TimeInterval = 0
    var lockDelay: TimeInterval { Prefs.lockDelay }
    var enrolled: [[Float]] { embeddings }

    let camera = Camera()
    private let engine: FaceEngine
    private var embeddings: [[Float]] = Enrollment.load()
    private var enrollSink: ((Int, [[Float]]) -> Void)?

    private var lastSeen = Date()
    private var lastFrame = Date()
    private var lastTick = Date()
    private var lastResultPresent: Bool?
    private var askedForCamera = false
    private var timer: Timer?

    // Touched only on the camera's video queue (fps is shared, behind the lock).
    private var lastProcessed: CFTimeInterval = 0
    private var fps: Double = 4
    private let fpsLock = NSLock()

    init(engine: FaceEngine) {
        self.engine = engine
        camera.onFrame = { [weak self] buffer in self?.frame(buffer) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.lastSeen = Date()
        }
    }

    func start() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let mode = Prefs.dryRun ? " (dry run)" : ""
        note("watching; locking after \(Int(lockDelay))s away\(mode)")
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
        setFPS(4)
        if let samples, !samples.isEmpty {
            do {
                try Enrollment.save(samples)
                embeddings = samples
                note("saved \(samples.count) face samples")
            } catch {
                note("could not save enrolment: \(error.localizedDescription)")
            }
        }
        lastSeen = Date()
        lastResultPresent = nil
        state = .starting
        tick()
    }

    // MARK: loop

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick) > 5 { lastSeen = now }  // woke from sleep or stalled: not absence
        lastTick = now

        if enrollSink != nil {
            state = .enrolling
            return
        }

        let locked = System.screenLocked
        if locked && Pause.active {  // a pause ends when you lock, so logging back in resumes watching
            Pause.clear()
            note("screen locked: pause ended")
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
            lastSeen = now
            lastResultPresent = nil
        }

        // The camera failing must never lock you out: no frames means no countdown.
        if now.timeIntervalSince(lastFrame) > 4 {
            if state != .noCamera { note("camera stopped sending frames; reopening") }
            state = .noCamera
            absentFor = 0
            lastSeen = now
            camera.reset()
            return
        }

        absentFor = now.timeIntervalSince(lastSeen)
        if absentFor >= lockDelay {
            if Prefs.dryRun {
                note("would lock (dry run)")
            } else {
                note("face gone for \(Int(absentFor))s: locking")
                System.lockScreen()
            }
            lastSeen = now
            absentFor = 0
            state = Prefs.dryRun ? .watching : .locked
            return
        }
        switch lastResultPresent {
        case .none: state = .starting
        case .some(true): state = .watching
        case .some(false): state = .absent
        }
    }

    private func idle(_ s: State) {
        state = s
        absentFor = 0
        camera.stop()
        lastSeen = Date()  // grace period once unlocked or resumed
        lastResultPresent = nil
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
        let (count, found) = engine.embeddings(in: buffer)
        DispatchQueue.main.async { [weak self] in self?.handle(count: count, found: found) }
    }

    private func handle(count: Int, found: [[Float]]) {
        let now = Date()
        lastFrame = now
        if let sink = enrollSink {
            sink(count, found)
            return
        }
        let threshold = Prefs.threshold
        let present = found.contains { face in
            embeddings.contains { FaceEngine.similarity($0, face) >= threshold }
        }
        if present { lastSeen = now }
        lastResultPresent = present
    }
}
