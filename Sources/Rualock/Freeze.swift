import AppKit

/// The prank alternative to locking: an invisible window over every screen that swallows the
/// keyboard and mouse. The screen looks unlocked, but nothing responds. `Watcher` lifts it when it sees
/// your face again (with the usual blink check), or when the Mac is locked (and then unlocked).
///
/// With Accessibility access, an `InputBlocker` also drops every keyboard, mouse, scroll and trackpad
/// event system-wide, so system shortcuts, Spotlight, gestures and even the cursor are frozen too.
/// Without it, only what reaches Rualock's window is stopped (clicks, typing, ⌘-Tab, Force Quit).
/// Either way it's a prank, not a lock: locking is the safe option.
///
/// The ways out: your face; ⌃⌘Q, which locks for real; the power button or closing the lid. The
/// blocker is removed the moment the screen locks, so the password field always works.
final class FreezeOverlay {
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private let blocker = InputBlocker()
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
                self.lockNow()
            }
            return nil
        }
        blocker.onLock = { [weak self] in self?.lockNow() }
        if blocker.start() { note("freeze: all input blocked") } else { note("freeze: no Accessibility access, blocking Rualock's window only") }
        // However the screen gets locked (lid, power button), drop the blocker at once so you can type
        // your password. `Watcher` then lifts the rest of the freeze.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in self?.blocker.stop()
        })
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
        blocker.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        observers = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// ⌃⌘Q: lift the freeze and lock for real; unlocking (password or Touch ID) gets you back in.
    private func lockNow() {
        note("⌃⌘Q while frozen: locking")
        hide()
        System.lockScreen()
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

/// Drops every keyboard, mouse, scroll and trackpad event for the whole login session, with an event
/// tap at the hardware level. Needs Accessibility access. Lets through only:
/// - ⌃⌘Q, which it turns into `onLock`, and
/// - the power key, so pressing it can still lock or sleep the Mac.
/// If Rualock hangs, macOS switches the tap off by itself after a moment, so it can never trap you.
final class InputBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onLock: (() -> Void)?

    static var allowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS to list Rualock under Privacy & Security › Accessibility (macOS shows its own prompt
    /// the first time), and opens that pane unless `openPane` is false.
    static func requestAccess(openPane: Bool = true) {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if openPane { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }

    /// Starts blocking; false if Rualock doesn't have Accessibility access.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.allowed else { return false }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<InputBlocker>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask.max, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }  // still frozen: switch it back on
            return Unmanaged.passUnretained(event)
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 12  // Q
            && event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift]) == [.maskControl, .maskCommand]:
            DispatchQueue.main.async { [weak self] in self?.onLock?() }
            return nil
        default:
            // System-defined events carry the power key (subtype 1) as well as media keys.
            if type.rawValue == 14, NSEvent(cgEvent: event)?.subtype.rawValue == 1 { return Unmanaged.passUnretained(event) }
            return nil
        }
    }
}
