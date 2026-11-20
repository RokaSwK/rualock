import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, IslandActions {
    private var watcher: Watcher!
    private var island: IslandController!
    private var enroll: EnrollWindowController?
    private var settings: SettingsWindowController?
    private var allowQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            note("already running; exiting")
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
        island.show()
        watcher.start()

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

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController { [weak self] in self?.showEnrollment() }
        }
        settings?.present()
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
