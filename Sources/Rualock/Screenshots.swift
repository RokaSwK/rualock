import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Rualock --screenshots dir`: renders the README images. The island is drawn into a mock menu bar
/// from scripted states (no camera involved); the windows are opened briefly and captured.
final class Screenshots: NSObject, NSApplicationDelegate, IslandActions {
    private final class Scripted: IslandStatus {
        var state: Watcher.State = .watching
        var absentFor: TimeInterval = 0
        var lockDelay: TimeInterval = 8
        var pauseWindow: (started: Date, until: Date)?
    }

    private let dir: URL
    private let status = Scripted()
    private let size = CGSize(width: 760, height: 80)
    private let bar: CGFloat = 32
    private let notchWidth: CGFloat = 190
    /// The island's window height in the mock menu bar: the light plus its flare into the notch.
    private var islandHeight: CGFloat {
        let h = IslandView.height(notch: bar)
        return h + IslandView.join(notch: bar, height: h)
    }
    private lazy var view: IslandView = {
        let v = IslandView(watcher: status, height: islandHeight)
        v.notch = true
        v.join = IslandView.join(notch: bar, height: IslandView.height(notch: bar))
        return v
    }()
    private var keep: [NSWindowController] = []

    init(directory: URL) {
        dir = directory
        // Render with default settings whatever yours are (the argument domain wins, and isn't saved).
        UserDefaults.standard.setVolatileDomain([
            "lockDelay": 8.0, "requireBlink": true, "showIsland": true, "showMenuBarIcon": true, "recordDiagnostics": true, "islandStyle": "standard", "freezeInstead": false,
        ], forName: UserDefaults.argumentDomain)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stills()
        hoverGIF()
        countdownGIF()
        windows()
    }

    // MARK: island

    private func stills() {
        view.clock = { 0.35 }
        func still(_ name: String, hover: Bool, _ setup: () -> Void) {
            setup()
            view.hover = hover
            png(scene(width: view.targetWidth, scale: 2), name)
        }
        still("watching", hover: false) { status.state = .watching }
        still("watching-hover", hover: true) { status.state = .watching }
        still("locking-hover", hover: true) { status.state = .absent; status.absentFor = 5.2 }
        still("blink-hover", hover: true) { status.state = .unverified; status.lockDelay = 18; status.absentFor = 5 }
        status.lockDelay = 8
        still("paused-hover", hover: true) {
            status.state = .paused
            status.pauseWindow = (Date().addingTimeInterval(-180), Date().addingTimeInterval(12 * 60 - 1))
        }
        still("no-camera-hover", hover: true) { status.state = .noCamera }
    }

    /// Hover: the shape springs open, the text fades in, then it closes again.
    private func hoverGIF() {
        status.state = .watching
        var width = view.compactWidth, velocity: CGFloat = 0
        var frames: [CGImage] = []
        for i in 0 ..< 102 {
            let t = Double(i) / 30
            view.hover = t >= 0.5 && t < 2.1
            view.clock = { t }
            for _ in 0 ..< 2 { IslandView.spring(width: &width, velocity: &velocity, target: view.targetWidth, dt: 1.0 / 60) }
            frames.append(scene(width: width, scale: 2))
        }
        gif(frames, delay: 1.0 / 30, "hover")
    }

    /// Walk away: green, then the amber ring drains for 8 seconds (shown at 2x), then locked.
    private func countdownGIF() {
        view.hover = false
        var frames: [CGImage] = []
        let fps = 20.0
        for i in 0 ..< Int(7.0 * fps) {
            let t = Double(i) / fps
            view.clock = { t }
            switch t {
            case ..<1.2:
                status.state = .watching
            case ..<5.2:
                status.state = .absent
                status.absentFor = (t - 1.2) * 2
            default:
                status.state = .locked
            }
            frames.append(scene(width: view.compactWidth, scale: 2))
        }
        gif(frames, delay: 1 / fps, "countdown")
    }

    /// A slice of a Mac screen: wallpaper, menu bar, the notch and the island growing out of it.
    private func scene(width: CGFloat, scale: CGFloat) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext

        // Wallpaper and the translucent menu bar.
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.22, blue: 0.52, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.40, blue: 0.48, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.66, blue: 0.42, alpha: 1),
        ])!.draw(in: NSRect(origin: .zero, size: size), angle: -12)
        NSColor(white: 0, alpha: 0.22).setFill()
        NSRect(x: 0, y: size.height - bar, width: size.width, height: bar).fill()

        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        let white = NSColor(white: 1, alpha: 0.95)
        func text(_ s: String, _ x: CGFloat, _ f: NSFont) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: white]
            let sz = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: x, y: size.height - bar / 2 - sz.height / 2), withAttributes: attrs)
            return x + sz.width
        }
        func symbol(_ name: String, _ x: CGFloat, _ pt: CGFloat) -> CGFloat {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pt, weight: .regular).applying(.init(paletteColors: [white]))) else { return x }
            let r = NSRect(x: x, y: size.height - bar / 2 - img.size.height / 2, width: img.size.width, height: img.size.height)
            img.draw(in: r)
            return r.maxX
        }
        var x = symbol("apple.logo", 18, 15) + 20
        x = text("Finder", x, bold) + 20
        for item in ["File", "Edit", "View", "Go"] { x = text(item, x, font) + 20 }
        let clock = "Fri 20 Nov  9:41"
        let clockW = (clock as NSString).size(withAttributes: [.font: font]).width
        var rx = size.width - 18 - clockW
        _ = text(clock, rx, font)
        rx -= 50
        _ = symbol("battery.100percent", rx, 13)
        rx -= 30
        _ = symbol("wifi", rx, 13)

        // The island, then the notch on top of it, as the hardware hides what's under the notch.
        let notchRight = size.width / 2 + notchWidth / 2
        view.frame = NSRect(x: 0, y: 0, width: width, height: islandHeight)
        cg.saveGState()
        cg.translateBy(x: notchRight - IslandView.notchOverlap, y: size.height - view.frame.height)
        view.draw(view.bounds)
        cg.restoreGState()
        NSColor.black.setFill()
        let r: CGFloat = 10
        let notch = NSBezierPath()
        let left = size.width / 2 - notchWidth / 2, top = size.height, bottom = size.height - bar
        notch.move(to: NSPoint(x: left, y: top))
        notch.line(to: NSPoint(x: left, y: bottom + r))
        notch.appendArc(withCenter: NSPoint(x: left + r, y: bottom + r), radius: r, startAngle: 180, endAngle: 270)
        notch.line(to: NSPoint(x: notchRight - r, y: bottom))
        notch.appendArc(withCenter: NSPoint(x: notchRight - r, y: bottom + r), radius: r, startAngle: 270, endAngle: 360)
        notch.line(to: NSPoint(x: notchRight, y: top))
        notch.close()
        notch.fill()
        // The camera lens.
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width / 2 - 4, y: size.height - bar / 2 - 4, width: 8, height: 8)).fill()

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // MARK: windows

    private func windows() {
        guard let engine = try? FaceEngine() else { finish(); return }
        let setup = EnrollWindowController(watcher: Watcher(engine: engine))
        let settings = SettingsWindowController(onReenroll: {}, onDisplayChange: {})
        keep = [setup, settings]
        setup.showForScreenshot(done: false)
        setup.present()
        after(1.0) {
            self.capture(setup.window, "setup")
            setup.showForScreenshot(done: true)
            self.after(0.6) {
                self.capture(setup.window, "setup-done")
                setup.close()
                settings.present()
                self.after(0.8) {
                    self.capture(settings.window, "settings")
                    settings.close()
                    self.menuBarShot()
                }
            }
        }
    }

    // The menu bar icon with its menu open. Run with the real app quit, so only one icon shows.
    private var menuBar: MenuBarController?

    private func menuBarShot() {
        status.state = .watching
        let bar = MenuBarController(status: status, actions: self)
        menuBar = bar
        bar.setVisible(true)
        after(0.8) {
            guard let button = bar.button, let window = button.window, let screen = window.screen ?? NSScreen.main,
                  let primary = NSScreen.screens.first else { return self.finish() }
            let f = window.frame
            let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let rect = CGRect(x: f.minX - 14, y: primary.frame.maxY - screen.frame.maxY, width: 236, height: 226)
            // A plain backdrop under the (translucent) menu, so other windows don't show through.
            let backdrop = NSWindow(
                contentRect: NSRect(x: rect.minX - 20, y: screen.frame.maxY - rect.height - 20, width: rect.width + 40, height: rect.height + 20 - barHeight),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            backdrop.backgroundColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
            backdrop.level = .floating
            backdrop.orderFrontRegardless()
            let path = self.dir.appendingPathComponent("menu.png")
            let iconRight = f.maxX - rect.minX + 4
            let done = DispatchGroup()
            done.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path.path]
                try? p.run()
                p.waitUntilExit()
                self.maskNeighbours(path, from: iconRight, barHeight: barHeight)
                done.leave()
                DispatchQueue.main.async { bar.cancelMenu() }
            }
            button.performClick(nil)  // opens the menu; returns once tracking ends
            done.notify(queue: .main) {
                backdrop.orderOut(nil)
                bar.setVisible(false)
                self.finish()
            }
        }
    }

    /// Paint over the other apps' menu bar icons right of ours with the bar's own background.
    private func maskNeighbours(_ url: URL, from x: CGFloat, barHeight: CGFloat) {
        guard let src = NSImage(contentsOf: url), let rep = src.representations.first else { return }
        let px = CGFloat(rep.pixelsWide) / src.size.width
        let w = rep.pixelsWide, h = rep.pixelsHigh
        // Find where the menu bar ends by walking down the left edge until the colour changes.
        var barHeight = barHeight
        if let bits = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()), let top = bits.colorAt(x: 1, y: 1) {
            for y in 2 ..< bits.pixelsHigh {
                guard let c = bits.colorAt(x: 1, y: y) else { break }
                if abs(c.brightnessComponent - top.brightnessComponent) > 0.15 {
                    barHeight = CGFloat(y) / px
                    break
                }
            }
        }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        out.size = src.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let full = NSRect(origin: .zero, size: src.size)
        src.draw(in: full)
        let strip = NSRect(x: x, y: src.size.height - barHeight, width: src.size.width - x, height: barHeight)
        let sample = NSRect(x: 1, y: src.size.height - barHeight, width: 1 / px, height: barHeight)
        src.draw(in: strip, from: sample, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    func showEnrollment() {}
    func showSettings() {}
    func quit() {}
    func pause(minutes: Double) {}
    func resume() {}
    @objc func menuCommand(_ sender: NSMenuItem) {}
    func makeMenu() -> NSMenu { AppMenu.build(state: .watching, paused: false, enrolled: true, target: self) }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    private func capture(_ window: NSWindow?, _ name: String) {
        guard let window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l\(window.windowNumber)", dir.appendingPathComponent("\(name).png").path]
        try? p.run()
        p.waitUntilExit()
    }

    private func finish() {
        print("rendered into \(dir.path)")
        NSApp.terminate(nil)
    }

    // MARK: files

    private func png(_ image: CGImage, _ name: String) {
        let url = dir.appendingPathComponent("\(name).png")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    private func gif(_ frames: [CGImage], delay: Double, _ name: String) {
        let url = dir.appendingPathComponent("\(name).gif")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(d, f, props) }
        CGImageDestinationFinalize(d)
    }
}
