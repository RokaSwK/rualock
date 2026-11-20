import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, IslandActions {
    private var watcher: Watcher!
    private var island: IslandController!
    private var menuBar: MenuBarController!
    private var authenticating = false
    private var enroll: EnrollWindowController?
    private var settings: SettingsWindowController?
    private var allowQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            // Opening Rualock again (from Finder, Spotlight, Launchpad) brings up its Settings.
            DistributedNotificationCenter.default().postNotificationName(Self.showSettingsNote, object: nil, deliverImmediately: true)
            note("already running; showing its settings")
            allowQuit = true
            NSApp.terminate(nil)
            return
        }

        let engine: FaceEngine
        do {
            engine = try FaceEngine()
        } catch {
            note("could not load the face model: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Rualock is damaged"
            alert.informativeText = "The face model could not be loaded. Reinstall Rualock.\n\n\(error.localizedDescription)"
            alert.runModal()
            allowQuit = true
            NSApp.terminate(nil)
            return
        }

        // Logging out, restarting and shutting down must never be blocked by the Touch ID guard on Quit.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) {
            [weak self] _ in self?.allowQuit = true
        }

        watcher = Watcher(engine: engine)
        island = IslandController(watcher: watcher)
        island.view.actions = self
        menuBar = MenuBarController(status: watcher, actions: self)
        menuBar.onRemoved = { [weak self] in  // ⌘-dragged out of the menu bar
            Prefs.showMenuBarIcon = false
            if !Prefs.showIsland { Prefs.showIsland = true }
            self?.applyDisplay()
        }
        applyDisplay()
        watcher.start()

        DistributedNotificationCenter.default().addObserver(forName: Self.showSettingsNote, object: nil, queue: .main) {
            [weak self] _ in self?.showSettings()
        }

        if !Prefs.didOfferLoginItem {  // on by default; switch off in Settings
            Prefs.didOfferLoginItem = true
            System.startsAtLogin = true
        }
        if watcher.enrolled.isEmpty { showEnrollment() }
    }

    func showEnrollment() {
        if let enroll {
            enroll.present()
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            let c = EnrollWindowController(watcher: self.watcher)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
                self?.enroll = nil
            }
            self.enroll = c
            c.present()
        }
        // Replacing an existing face turns protection over to someone else, so it needs Touch ID.
        if watcher.enrolled.isEmpty {
            open()
        } else {
            System.authenticate("re-enrol your face in Rualock") { ok in if ok { open() } }
        }
    }

    static let showSettingsNote = Notification.Name("com.rualock.mac.showSettings")

    /// Show the light next to the camera and/or the menu bar icon, as set in Settings.
    func applyDisplay() {
        island.setVisible(Prefs.showIsland)
        menuBar.setVisible(Prefs.showMenuBarIcon)
        settings?.refresh()
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(
                onReenroll: { [weak self] in self?.showEnrollment() },
                onDisplayChange: { [weak self] in self?.applyDisplay() }
            )
        }
        settings?.present()
    }

    // MARK: actions

    /// Pausing turns protection off, so it needs Touch ID (or the Mac password).
    func pause(minutes: Double) {
        guard !authenticating, !watcher.enrolled.isEmpty else { return }
        authenticating = true
        let what = minutes == 1 ? "1 minute" : "\(Int(minutes)) minutes"
        System.authenticate("pause Rualock for \(what)") { [weak self] ok in
            self?.authenticating = false
            if ok { Pause.start(minutes: minutes) }
        }
    }

    func resume() {
        Pause.clear()
        note("resumed")
    }

    /// The menu used by the menu bar icon and by right-clicking the light next to the camera.
    func makeMenu() -> NSMenu {
        AppMenu.build(state: watcher.state, paused: Pause.active, enrolled: !watcher.enrolled.isEmpty, target: self)
    }

    @objc func menuCommand(_ sender: NSMenuItem) {
        switch AppMenu.Command(rawValue: sender.tag) {
        case .enroll: showEnrollment()
        case .camera: System.openCameraPrivacySettings()
        case .resume: resume()
        case .pause15: pause(minutes: 15)
        case .pause60: pause(minutes: 60)
        case .lock: System.lockScreen()
        case .settings: showSettings()
        case .quit: quit()
        case nil: break
        }
    }

    /// Quitting turns protection off, so it needs Touch ID too.
    func quit() {
        System.authenticate("quit Rualock") { [weak self] ok in
            guard ok else { return }
            note("quit")
            self?.allowQuit = true
            NSApp.terminate(nil)
        }
    }

    /// Opening Rualock while it's running (Finder, Spotlight, Launchpad) brings up its Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowQuit ? .terminateNow : .terminateCancel
    }
}

// `Rualock --embed image.png` prints the embedding of the largest face, for checking the pipeline.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--embed" {
    exit(SelfTest.embed(path: CommandLine.arguments[2]))
}

let app = NSApplication.shared
// `Rualock --screenshots dir` renders the README images and GIFs into dir, then quits.
let delegate: NSApplicationDelegate = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--screenshots"
    ? Screenshots(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
