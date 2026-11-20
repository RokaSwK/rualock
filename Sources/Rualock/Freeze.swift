import AppKit

/// The prank alternative to locking: an invisible window over every screen that swallows the
/// keyboard and mouse. The screen looks unlocked, but nothing responds. `Watcher` lifts it when it sees
/// your face again (with the usual blink check), or when the Mac is locked (and then unlocked).
///
/// This is a prank, not a lock. It stops clicks, typing, ⌘-Tab, Force Quit and the power-button dialog,
/// but system gestures (Mission Control, swiping between spaces) and Spotlight still work, so a
/// determined person could get past it. Locking is the safe option.
final class FreezeOverlay {
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var savedOptions: NSApplication.PresentationOptions = []

    var active: Bool { !windows.isEmpty }

    func show() {
        guard !active else { return }
        buildWindows()
        // Everything sent to Rualock while frozen is dropped, except ⌃⌘Q, which locks for real: the way
        // out when your face can't be seen (lock, then unlock with your password or Touch ID).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            if event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "q",
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command] {
                note("⌃⌘Q while frozen: locking")
                System.lockScreen()
            }
            return nil
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            // Something else came to the front (Spotlight launching an app): take the keyboard back.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app != NSRunningApplication.current { self?.takeFocus() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, self.active else { return }
            self.windows.forEach { $0.orderOut(nil) }
            self.windows = []
            self.buildWindows()
            self.takeFocus()
        })
        savedOptions = NSApp.presentationOptions
        takeFocus()
        // ⌘-Tab, Force Quit and the power-button dialog off while Rualock is in front. Turning off app
        // switching needs the Dock hidden, so it auto-hides until the freeze lifts.
        NSApp.presentationOptions = [.autoHideDock, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication]
    }

    func hide() {
        guard active else { return }
        NSApp.presentationOptions = savedOptions
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func buildWindows() {
        for screen in NSScreen.screens {
            let w = FreezeWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // Not quite clear: a fully clear window lets clicks through to what's behind it.
            w.backgroundColor = NSColor(white: 0, alpha: 0.002)
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.isMovable = false
            w.level = .screenSaver  // above the menu bar, the Dock and the status light
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private func takeFocus() {
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }
}

/// Borderless windows can't take the keyboard by default; this one has to, so keys go nowhere.
private final class FreezeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
