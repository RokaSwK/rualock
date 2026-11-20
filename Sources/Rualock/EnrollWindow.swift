import AppKit
import AVFoundation

/// Onboarding and re-enrolment: asks for the camera, then collects 30 samples of your face.
final class EnrollWindowController: NSWindowController, NSWindowDelegate {
    private enum Phase { case intro, denied, capturing, done }

    private let watcher: Watcher
    private let needed = 30
    private var samples: [[Float]] = []
    private var lastSample: CFTimeInterval = 0
    private var phase = Phase.intro

    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let stage = NSView()
    private let symbol = NSImageView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var preview: AVCaptureVideoPreviewLayer?

    private static let stageSize: CGFloat = 248
    private static let ringInset: CGFloat = 4
    private static let videoInset: CGFloat = 14

    init(watcher: Watcher) {
        self.watcher = watcher
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Set up Rualock"
        super.init(window: window)
        window.delegate = self
        build()
        show(.intro)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }

        stage.wantsLayer = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        let s = Self.stageSize
        let circle = CGPath(ellipseIn: CGRect(x: Self.ringInset, y: Self.ringInset, width: s - 2 * Self.ringInset, height: s - 2 * Self.ringInset), transform: nil)
        for (layer, alpha) in [(track, 0.15), (ring, 1.0)] {
            layer.path = circle
            layer.fillColor = nil
            layer.lineWidth = 5
            layer.lineCap = .round
            layer.strokeColor = NSColor.systemGreen.withAlphaComponent(alpha).cgColor
            layer.frame = CGRect(x: 0, y: 0, width: s, height: s)
            // start at 12 o'clock, go clockwise
            layer.transform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeRotation(-.pi / 2, 0, 0, 1))
            stage.layer?.addSublayer(layer)
        }
        ring.strokeEnd = 0

        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = .init(pointSize: 96, weight: .thin)
        stage.addSubview(symbol)

        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.alignment = .center
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 330

        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.controlSize = .large
        button.target = self
        button.action = #selector(primary)
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.target = self
        cancel.action = #selector(closeWindow)

        let buttons = NSStackView(views: [cancel, button])
        buttons.spacing = 10
        let stack = NSStackView(views: [stage, heading, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(28, after: stage)
        stack.setCustomSpacing(26, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stage.widthAnchor.constraint(equalToConstant: s),
            stage.heightAnchor.constraint(equalToConstant: s),
            symbol.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            body.widthAnchor.constraint(equalToConstant: 330),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 6),
        ])
    }

    private func show(_ next: Phase) {
        phase = next
        let delay = Int(Prefs.lockDelay)
        switch next {
        case .intro:
            setSymbol("faceid", .secondaryLabelColor)
            heading.stringValue = watcher.enrolled.isEmpty ? "Set up Rualock" : "Re-enrol your face"
            body.stringValue = "Rualock locks your Mac when you walk away. It learns your face here, on this Mac; nothing is uploaded."
            button.title = "Continue"
            cancel.isHidden = watcher.enrolled.isEmpty
        case .denied:
            setSymbol("video.slash", .systemRed)
            heading.stringValue = "Camera access needed"
            body.stringValue = "Allow Rualock in System Settings › Privacy & Security › Camera, then click Try Again."
            button.title = "Try Again"
            cancel.isHidden = false
        case .capturing:
            symbol.isHidden = true
            attachPreview()
            heading.stringValue = "Look at the camera"
            body.stringValue = "Slowly turn your head a little to each side."
            button.title = "Learning…"
            button.isEnabled = false
            cancel.isHidden = false
        case .done:
            detachPreview()
            setSymbol("checkmark.circle.fill", .systemGreen)
            heading.stringValue = "You're set"
            body.stringValue = "The dot beside the camera turns green while Rualock sees you. Walk away and your Mac locks after \(delay) seconds. Click the dot to pause for 15 minutes."
            button.title = "Done"
            button.isEnabled = true
            cancel.isHidden = true
        }
        if next != .capturing { button.isEnabled = true }
        ring.strokeEnd = next == .done ? 1 : CGFloat(samples.count) / CGFloat(needed)
        track.isHidden = next == .intro || next == .denied
        ring.isHidden = track.isHidden
    }

    /// For screenshots: show the first screen, or the finished one.
    func showForScreenshot(done: Bool) {
        if done { samples = Array(repeating: [], count: needed) }
        show(done ? .done : .intro)
    }

    private func setSymbol(_ name: String, _ color: NSColor) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbol.contentTintColor = color
        symbol.isHidden = false
    }

    private func attachPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: watcher.camera.session)
        layer.videoGravity = .resizeAspectFill
        let s = Self.stageSize, i = Self.videoInset
        layer.frame = CGRect(x: i, y: i, width: s - 2 * i, height: s - 2 * i)
        layer.cornerRadius = (s - 2 * i) / 2
        layer.masksToBounds = true
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        stage.layer?.insertSublayer(layer, at: 0)
        preview = layer
    }

    private func detachPreview() {
        preview?.removeFromSuperlayer()
        preview = nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func primary() {
        switch phase {
        case .intro, .denied: requestCamera()
        case .capturing: break
        case .done: close()
        }
    }

    @objc private func closeWindow() { close() }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.startCapture() : self.show(.denied) }
            }
        default:
            if phase == .denied { System.openCameraPrivacySettings() }
            show(.denied)
        }
    }

    private func startCapture() {
        samples = []
        show(.capturing)
        watcher.beginEnrollment { [weak self] count, found in self?.collect(count: count, found: found) }
    }

    private func collect(count: Int, found: [[Float]]) {
        guard phase == .capturing else { return }
        switch count {
        case 0: body.stringValue = "Can't see a face. Sit in front of the camera, in good light."
        case 1: body.stringValue = "Slowly turn your head a little to each side."
        default: body.stringValue = "Only one face, please."
        }
        let now = CACurrentMediaTime()
        guard count == 1, let e = found.first, now - lastSample >= 0.2 else { return }
        lastSample = now
        samples.append(e)
        ring.strokeEnd = CGFloat(samples.count) / CGFloat(needed)
        if samples.count >= needed {
            watcher.endEnrollment(saving: samples)
            show(.done)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if phase == .capturing { watcher.endEnrollment(saving: nil) }
        detachPreview()
        if phase != .done { phase = .intro }
    }
}
