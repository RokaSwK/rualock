import AppKit

final class SettingsWindowController: NSWindowController {
    private let delay = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "Start Rualock when you log in", target: nil, action: nil)
    private let island = NSButton(checkboxWithTitle: "Status light next to the camera", target: nil, action: nil)
    private let islandSize = NSPopUpButton()
    private let menuBar = NSButton(checkboxWithTitle: "Icon in the menu bar", target: nil, action: nil)
    private let diagnostics = NSButton(checkboxWithTitle: "Record diagnostics for tuning (numbers only, stays on this Mac)", target: nil, action: nil)
    private let action = NSPopUpButton()
    private let blink = NSButton(checkboxWithTitle: "Require a blink, so a photo can't stand in for you", target: nil, action: nil)
    private let onReenroll: () -> Void
    private let onDisplayChange: () -> Void

    init(onReenroll: @escaping () -> Void, onDisplayChange: @escaping () -> Void) {
        self.onReenroll = onReenroll
        self.onDisplayChange = onDisplayChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Rualock Settings"
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        for s in Prefs.lockDelays { delay.addItem(withTitle: "\(Int(s)) seconds") }
        delay.target = self
        delay.action = #selector(delayChanged)
        action.addItems(withTitles: ["Lock the Mac", "Freeze the screen until I'm back (prank)"])
        action.target = self
        action.action = #selector(actionChanged)
        login.target = self
        login.action = #selector(loginChanged)
        blink.target = self
        blink.action = #selector(blinkChanged)
        diagnostics.target = self
        diagnostics.action = #selector(diagnosticsChanged)
        let showDiagnostics = NSButton(title: "Show in Finder", target: self, action: #selector(showDiagnosticsFolder))
        for b in [island, menuBar] {
            b.target = self
            b.action = #selector(displayChanged)
        }
        islandSize.addItems(withTitles: IslandSize.allCases.map(\.title))
        islandSize.target = self
        islandSize.action = #selector(islandSizeChanged)
        let reenroll = NSButton(title: "Re-enrol Face…", target: self, action: #selector(reenrollClicked))

        let grid = NSGridView(views: [
            [label("When you leave:"), action],
            [label("After:"), delay],
            [label("Security:"), blink],
            [label("Show:"), island],
            [NSGridCell.emptyContentView, menuBar],
            [label("Light height:"), islandSize],
            [label("General:"), login],
            [label("Face:"), reenroll],
            [label("Diagnostics:"), diagnostics],
            [NSGridCell.emptyContentView, showDiagnostics],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let footer = NSTextField(labelWithString: "Rualock \(version)")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [grid, footer])
        stack.orientation = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    func present() {
        delay.selectItem(at: Prefs.lockDelays.firstIndex(of: Prefs.lockDelay) ?? 1)
        login.state = System.startsAtLogin ? .on : .off
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func delayChanged() {
        Prefs.lockDelay = Prefs.lockDelays[delay.indexOfSelectedItem]
        note("lock delay set to \(Int(Prefs.lockDelay))s")
    }

    /// Match the checkboxes to the preferences. One of the two must stay on, or you'd have no way back
    /// to the menu short of opening the app again.
    func refresh() {
        diagnostics.state = Prefs.recordDiagnostics ? .on : .off
        blink.state = Prefs.requireBlink ? .on : .off
        action.selectItem(at: Prefs.freezeInstead ? 1 : 0)
        action.toolTip = "Freeze covers the screen with an invisible window: it looks unlocked, but clicks and keys do nothing until Rualock sees your face again (blink to confirm). Locking and unlocking the Mac (⌃⌘Q) also lifts it. It's a prank, not a lock."
        island.state = Prefs.showIsland ? .on : .off
        menuBar.state = Prefs.showMenuBarIcon ? .on : .off
        island.isEnabled = Prefs.showMenuBarIcon
        menuBar.isEnabled = Prefs.showIsland
        islandSize.selectItem(at: IslandSize.allCases.firstIndex(of: Prefs.islandSize) ?? 1)
        islandSize.isEnabled = Prefs.showIsland
    }

    @objc private func diagnosticsChanged() {
        Prefs.recordDiagnostics = diagnostics.state == .on
        note("diagnostics \(Prefs.recordDiagnostics ? "on" : "off")")
    }

    @objc private func showDiagnosticsFolder() {
        try? FileManager.default.createDirectory(at: Diagnostics.shared.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.dir])
    }

    /// Turning the blink check off weakens protection, so it needs Touch ID like pausing does.
    @objc private func blinkChanged() {
        if blink.state == .on {
            Prefs.requireBlink = true
            note("blink check on")
            return
        }
        blink.state = .on
        System.authenticate("turn off the blink check in Rualock") { [weak self] ok in
            guard ok else { return }
            Prefs.requireBlink = false
            note("blink check off")
            self?.refresh()
        }
    }

    /// Freezing is weaker than locking, so switching to it needs Touch ID, like turning off the blink check.
    @objc private func actionChanged() {
        guard action.indexOfSelectedItem == 1 else {
            Prefs.freezeInstead = false
            note("when you leave: lock")
            return
        }
        guard !Prefs.freezeInstead else { return }
        action.selectItem(at: 0)
        System.authenticate("freeze the screen instead of locking it") { [weak self] ok in
            guard ok else { return }
            Prefs.freezeInstead = true
            note("when you leave: freeze (prank)")
            self?.refresh()
        }
    }

    @objc private func displayChanged() {
        Prefs.showIsland = island.state == .on
        Prefs.showMenuBarIcon = menuBar.state == .on
        note("show: status light \(Prefs.showIsland ? "on" : "off"), menu bar icon \(Prefs.showMenuBarIcon ? "on" : "off")")
        onDisplayChange()
    }

    @objc private func islandSizeChanged() {
        Prefs.islandSize = IslandSize.allCases[islandSize.indexOfSelectedItem]
        note("status light height: \(Prefs.islandSize.rawValue)")
        onDisplayChange()
    }

    @objc private func loginChanged() {
        System.startsAtLogin = login.state == .on
        login.state = System.startsAtLogin ? .on : .off
    }

    @objc private func reenrollClicked() {
        close()
        onReenroll()
    }
}
