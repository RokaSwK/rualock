import AppKit

/// The menu bar icon: the same dot and countdown ring as the island, with the app's menu.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let status: IslandStatus
    private weak var actions: IslandActions?
    private var item: NSStatusItem?
    private var header: NSMenuItem?
    private var shown: StatusDisplay?
    private var timer: Timer?
    private var visibility: NSKeyValueObservation?
    /// Called when you ⌘-drag the icon out of the menu bar.
    var onRemoved: (() -> Void)?

    init(status: IslandStatus, actions: IslandActions) {
        self.status = status
        self.actions = actions
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.behavior = .removalAllowed
            item.isVisible = true  // macOS remembers an earlier ⌘-drag removal; switching it on means show it
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            visibility = item.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
                guard !item.isVisible else { return }
                DispatchQueue.main.async { self?.onRemoved?() }
            }
            shown = nil
            refresh()
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)  // keeps updating while the menu is open
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            visibility = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }
    }

    private func refresh() {
        let d = status.display
        header?.title = "Rualock: \(d.label)"
        // Redraw only when something visible changed (the ring moves in 1/48 steps).
        var key = d
        key.fraction = d.fraction.map { ($0 * 48).rounded() / 48 }
        guard key != shown, let button = item?.button else { return }
        shown = key
        button.image = Self.icon(key)
        button.toolTip = "Rualock: \(d.label)"
        button.setAccessibilityLabel("Rualock: \(d.label)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let built = actions?.makeMenu() else { return }
        menu.removeAllItems()
        let head = NSMenuItem(title: "Rualock: \(status.display.label)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
        header = head
    }

    func menuDidClose(_ menu: NSMenu) { header = nil }

    var button: NSStatusBarButton? { item?.button }

    func cancelMenu() { item?.menu?.cancelTracking() }

    /// An 18 pt image: a dot in the status colour inside a ring; the ring drains while counting down.
    static func icon(_ d: StatusDisplay) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY), r: CGFloat = 6.5
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.6
            if let f = d.fraction {
                d.color.withAlphaComponent(0.3).setStroke()
                ring.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                d.color.setStroke()
                arc.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.45).setStroke()
                ring.stroke()
            }
            d.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The app menu, shared by the menu bar icon, the island's right-click and the screenshot renderer.
/// Every item calls `menuCommand(_:)` on the target with its `Command` as the tag.
enum AppMenu {
    enum Command: Int {
        case enroll = 1, camera, resume, pause15, pause60, lock, settings, quit
    }

    static func build(state: Watcher.State, paused: Bool, enrolled: Bool, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        let action = NSSelectorFromString("menuCommand:")
        func add(_ title: String, _ command: Command, _ key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.target = target
            item.tag = command.rawValue
            menu.addItem(item)
        }
        switch state {
        case .notEnrolled: add("Set Up Your Face…", .enroll)
        case .cameraDenied: add("Allow Camera Access…", .camera)
        default: break
        }
        if paused {
            add("Resume", .resume)
        } else {
            add("Pause for 15 Minutes", .pause15, enabled: enrolled)
            add("Pause for 1 Hour", .pause60, enabled: enrolled)
        }
        add("Lock Now", .lock)
        menu.addItem(.separator())
        add("Settings…", .settings, ",")
        menu.addItem(.separator())
        add("Quit Rualock", .quit, "q")
        return menu
    }
}
