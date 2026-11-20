import AppKit

/// The status shape that grows out of the right side of the camera notch.
///
/// Green dot: you're recognised. Amber ring draining: counting down to the lock. Grey: locked;
/// while paused, a grey ring drains until the pause ends. Red: no camera or not set up.
/// Hover for words, click to pause for 15 minutes (Touch ID) or resume, right-click for more.
private enum K {
    static let dot: CGFloat = 3.5        // dot radius
    static let ring: CGFloat = 5.5       // countdown ring radius
    static let pad: CGFloat = 6          // space around the dot on the floating pill
    static let inner: CGFloat = 1        // gap between the notch edge and the ring
    static let tail: CGFloat = 5         // space right of the dot when attached to the notch
    static let tuck: CGFloat = 2         // the straight left edge sits this far under the notch
    static let fillet: CGFloat = 12      // fillet into the notch's rounded bottom corner
    static let overlap = tuck + fillet   // window starts this far left of the notch edge
    static let ear: CGFloat = 4          // concave flare where the shape meets the top bezel
    static let corner: CGFloat = 6       // bottom-right corner radius
    static let textGap: CGFloat = 6      // between the ring and the text
    static let textPad: CGFloat = 8      // right margin after the text
    static let springK: CGFloat = 320    // hover spring stiffness
    static let springDamp: CGFloat = 24  // under 2*sqrt(K), so it overshoots a little, then settles
    static let pillHeight: CGFloat = 18  // fallback pill on screens without a notch
    static let notchTrim: CGFloat = 0.4525  // full height sits a touch shorter than the notch, to match the camera housing
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
}

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private let green = srgb(0.19, 0.82, 0.35)
private let amber = srgb(1.00, 0.62, 0.04)
private let red = srgb(1.00, 0.27, 0.23)
private let grey = srgb(0.56, 0.56, 0.60)

private struct Geometry {
    var x: CGFloat, y: CGFloat, height: CGFloat, notch: Bool

    static func current() -> Geometry {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? screens.first else {
            return Geometry(x: 0, y: 0, height: K.pillHeight, notch: false)
        }
        let f = screen.frame
        if notched != nil, let right = screen.auxiliaryTopRightArea {
            let h = IslandView.height(notch: screen.safeAreaInsets.top)
            // The area is in global coordinates; tolerate a screen-local rect too.
            let edge = right.minX >= f.minX - 1 && right.minX <= f.maxX + 1 ? right.minX : f.minX + right.minX
            return Geometry(x: edge - K.overlap, y: f.maxY - h, height: h, notch: true)
        }
        let bar = NSStatusBar.system.thickness
        return Geometry(x: f.midX + 60, y: f.maxY - bar + (bar - K.pillHeight) / 2, height: K.pillHeight, notch: false)
    }
}

/// What the island shows. The watcher in the app; a scripted stand-in when rendering screenshots.
protocol IslandStatus: AnyObject {
    var state: Watcher.State { get }
    var absentFor: TimeInterval { get }
    var lockDelay: TimeInterval { get }
    var pauseWindow: (started: Date, until: Date)? { get }
}

extension Watcher: IslandStatus {
    var pauseWindow: (started: Date, until: Date)? { Pause.window }
}

/// What the island and the menu bar icon show for a status: dot colour, words, countdown ring.
struct StatusDisplay: Equatable {
    var color: NSColor
    var label: String
    var fraction: CGFloat?

    init(_ color: NSColor, _ label: String, _ fraction: CGFloat?) {
        self.color = color
        self.label = label
        self.fraction = fraction
    }

    var isGreen: Bool { color == green }
}

extension IslandStatus {
    var display: StatusDisplay {
        switch state {
        case .watching:
            return StatusDisplay(green, "Watching", nil)
        case .typing:
            return StatusDisplay(green, "Typing", nil)
        case .absent:
            let left = max(0, lockDelay - absentFor)
            return StatusDisplay(amber, "Locking in \(Int(left.rounded(.up)))s", CGFloat(left / lockDelay))
        case .unverified:
            let left = max(0, lockDelay - absentFor)
            return StatusDisplay(amber, "Blink to confirm", CGFloat(left / lockDelay))
        case .paused:
            guard let w = pauseWindow else { return StatusDisplay(grey, "Paused", nil) }
            let left = max(0, w.until.timeIntervalSinceNow)
            let label = left >= 60 ? "Paused · \(Int((left / 60).rounded(.up)))m" : "Paused · \(Int(left.rounded(.up)))s"
            return StatusDisplay(grey, label, CGFloat(min(1, left / max(1, w.until.timeIntervalSince(w.started)))))
        case .locked:
            return StatusDisplay(grey, "Locked", nil)
        case .frozen:
            return StatusDisplay(red, "Frozen · look at the camera", nil)
        case .noCamera:
            return StatusDisplay(red, "No camera", nil)
        case .cameraDenied:
            return StatusDisplay(red, "Allow camera access", nil)
        case .notEnrolled:
            return StatusDisplay(red, "Set up Rualock", nil)
        case .enrolling:
            return StatusDisplay(grey, "Learning your face", nil)
        case .starting:
            return StatusDisplay(grey, "Starting…", nil)
        }
    }
}

/// The app-level actions, shared by the island and the menu bar icon.
protocol IslandActions: AnyObject {
    func showEnrollment()
    func showSettings()
    func quit()
    func pause(minutes: Double)
    func resume()
    func makeMenu() -> NSMenu
}

final class IslandView: NSView {
    private let watcher: IslandStatus
    weak var actions: IslandActions?
    /// Drives the breathing glow; replaceable so screenshots are deterministic.
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var hover = false { didSet { if hover != oldValue { onHoverChange?() } } }
    var onHoverChange: (() -> Void)?
    var notch = true

    init(watcher: IslandStatus, height: CGFloat) {
        self.watcher = watcher
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: height))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: state

    private func status() -> StatusDisplay { watcher.display }

    private var ringLeft: CGFloat { notch ? K.overlap + K.inner : 2 + K.pad - 1 }

    var compactWidth: CGFloat {
        notch ? K.overlap + K.inner + 2 * K.ring + K.tail + K.ear : 2 + 2 * (K.pad + K.ring) - 2
    }

    private var textX: CGFloat { ringLeft + 2 * K.ring + K.textGap }

    var expandedWidth: CGFloat {
        let label = status().label
        if label != measured.label {  // measuring text is the costly part of a frame; labels rarely change
            measured = (label, (label as NSString).size(withAttributes: [.font: K.font]).width)
        }
        return textX + measured.width + K.textPad + (notch ? K.ear : 0)
    }

    private var measured: (label: String, width: CGFloat) = ("", 0)

    var targetWidth: CGFloat { hover ? expandedWidth : compactWidth }

    /// How far the window starts left of the notch edge (the part tucked under the notch).
    static let notchOverlap = K.overlap

    /// The shortest the light can be: the countdown ring and a point above and below it.
    static let minHeight = 2 * (K.ring + K.inner)

    /// The tallest it can be beside a notch this tall: a touch shorter, to match the camera housing.
    static func maxHeight(notch: CGFloat) -> CGFloat { notch - K.notchTrim }

    /// The tallest on this Mac's notch (or a typical notch if no screen has one), for the Settings slider.
    static var maxHeightHere: CGFloat {
        maxHeight(notch: NSScreen.screens.map(\.safeAreaInsets.top).max().flatMap { $0 > 0 ? $0 : nil } ?? 32)
    }

    /// The light's height beside a notch, from `Prefs.islandHeight`, between `minHeight` and the notch.
    static func height(notch: CGFloat, preferred: CGFloat = CGFloat(Prefs.islandHeight)) -> CGFloat {
        min(maxHeight(notch: notch), max(minHeight, preferred))
    }

    /// One step of the hover spring: a little overshoot, then it settles, like the Dynamic Island.
    static func spring(width: inout CGFloat, velocity: inout CGFloat, target: CGFloat, dt: CGFloat) {
        let force = K.springK * (target - width) - K.springDamp * velocity
        velocity += force * dt
        width += velocity * dt
        if abs(target - width) < 0.05 && abs(velocity) < 0.05 {
            width = target
            velocity = 0
        }
    }

    /// 0 when compact, 1 when fully open; drives the text fade and slide.
    private var reveal: CGFloat {
        if !hover && bounds.width <= compactWidth + 0.5 { return 0 }
        var t = (bounds.width - compactWidth) / max(1, expandedWidth - compactWidth)
        t = min(1, max(0, t))
        t = min(1, max(0, (t - 0.35) / 0.65))  // text starts once the shape is about a third open
        return t * t * (3 - 2 * t)
    }

    private func shape() -> NSBezierPath {
        let w = bounds.width, h = bounds.height
        guard notch else { return NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2) }
        // Square on the notch side, flared into the top bezel, rounded at the bottom right,
        // so it reads as the notch growing sideways. Bottom-left, a fillet fills the wedge the
        // notch's rounded corner leaves; the rest under the notch is hidden by the hardware.
        let p = NSBezierPath()
        let e = K.ear, c = K.corner
        p.move(to: NSPoint(x: K.fillet, y: h))
        p.line(to: NSPoint(x: w, y: h))
        p.curve(to: NSPoint(x: w - e, y: h - e), controlPoint1: NSPoint(x: w - e * 0.45, y: h), controlPoint2: NSPoint(x: w - e, y: h - e * 0.45))
        p.line(to: NSPoint(x: w - e, y: c))
        p.curve(to: NSPoint(x: w - e - c, y: 0), controlPoint1: NSPoint(x: w - e, y: c * 0.45), controlPoint2: NSPoint(x: w - e - c * 0.45, y: 0))
        p.line(to: NSPoint(x: 0, y: 0))
        p.appendArc(withCenter: NSPoint(x: 0, y: K.fillet), radius: K.fillet, startAngle: 270, endAngle: 360, clockwise: false)
        p.close()
        return p
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        shape().fill()

        let d = status()
        let color = d.color, label = d.label, fraction = d.fraction
        let cx = ringLeft + K.ring, cy = bounds.height / 2

        if let fraction {  // countdown ring
            let track = NSBezierPath()
            track.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: K.ring, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: K.ring, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2
            color.setStroke()
            arc.stroke()
        } else if d.isGreen {  // soft breathing glow
            let glow = 0.18 + 0.12 * sin(clock() * 2.2)
            color.withAlphaComponent(glow).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - K.ring, y: cy - K.ring, width: 2 * K.ring, height: 2 * K.ring)).fill()
        }

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - K.dot, y: cy - K.dot, width: 2 * K.dot, height: 2 * K.dot)).fill()

        let r = reveal
        if r > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            shape().addClip()  // the text never spills past the shape while it grows or shrinks
            let attrs: [NSAttributedString.Key: Any] = [.font: K.font, .foregroundColor: NSColor(white: 1, alpha: r)]
            let s = label as NSString
            let th = s.size(withAttributes: attrs).height
            s.draw(at: NSPoint(x: textX - 6 * (1 - r), y: (bounds.height - th) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func mouseDown(with event: NSEvent) {
        switch watcher.state {
        case .notEnrolled, .enrolling: actions?.showEnrollment()
        case .cameraDenied: System.openCameraPrivacySettings()
        case .paused: actions?.resume()
        default: actions?.pause(minutes: 15)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = actions?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Owns the panel and runs the 60 Hz spring animation.
final class IslandController {
    let view: IslandView
    private let panel: NSPanel
    private var width: CGFloat
    private var velocity: CGFloat = 0
    private var last = CACurrentMediaTime()
    private var timer: Timer?
    private var geometry = Geometry.current()
    private var geometryAt: CFTimeInterval = 0

    init(watcher: Watcher) {
        let g = Geometry.current()
        view = IslandView(watcher: watcher, height: g.height)
        view.notch = g.notch
        width = view.compactWidth
        panel = NSPanel(
            contentRect: NSRect(x: g.x, y: g.y, width: width, height: g.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)  // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    /// Show or hide the light next to the camera. Hidden, it costs nothing: the animation timer stops.
    func setVisible(_ visible: Bool) {
        geometryAt = 0  // re-read the size now, in case it just changed in Settings
        if visible {
            guard timer == nil else { return }
            panel.orderFrontRegardless()
            view.onHoverChange = { [weak self] in self?.run(at: 60) }
            run(at: 15)
        } else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }

    /// 60 Hz while the shape springs open or closed, 15 Hz otherwise (the glow and the ring move slowly).
    private func run(at hz: Double) {
        if let timer, abs(timer.timeInterval - 1 / hz) < 1e-6 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / hz, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        last = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 15, now - last))
        last = now

        if now - geometryAt > 1 {  // follows display changes, checked once a second
            geometry = Geometry.current()
            geometryAt = now
        }
        let g = geometry
        view.notch = g.notch

        let target = view.targetWidth
        IslandView.spring(width: &width, velocity: &velocity, target: target, dt: dt)
        let animating = width != target || velocity != 0

        let f = panel.frame
        if abs(f.width - width) > 0.01 || abs(f.minX - g.x) > 0.01 || abs(f.minY - g.y) > 0.01 || abs(f.height - g.height) > 0.01 {
            panel.setFrame(NSRect(x: g.x, y: g.y, width: width, height: g.height), display: true)
        }
        view.needsDisplay = true
        run(at: animating ? 60 : 15)
    }
}
