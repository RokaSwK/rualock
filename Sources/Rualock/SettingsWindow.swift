import AppKit

final class SettingsWindowController: NSWindowController {
    private let delay = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "Start Rualock when you log in", target: nil, action: nil)
    private let island = NSButton(checkboxWithTitle: "Status light next to the camera", target: nil, action: nil)
    private let menuBar = NSButton(checkboxWithTitle: "Icon in the menu bar", target: nil, action: nil)
    private let diagnostics = NSButton(checkboxWithTitle: "Record diagnostics for tuning (numbers only, stays on this Mac)", target: nil, action: nil)
    private let blink = NSButton(checkboxWithTitle: "Require a blink, so a photo can't stand in for you", target: nil, action: nil)
    private let onReenroll: () -> Void
    private let onDisplayChange: () -> Void

    init(onReenroll: @escaping () -> Void, onDisplayChange: @escaping () -> Void) {
        self.onReenroll = onReenroll
        self.onDisplayChange = onDisplayChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
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
        let reenroll = NSButton(title: "Re-enrol Face…", target: self, action: #selector(reenrollClicked))

        let grid = NSGridView(views: [
            [label("Lock after you leave:"), delay],
            [label("Security:"), blink],
            [label("Show:"), island],
            [NSGridCell.emptyContentView, menuBar],
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
        island.state = Prefs.showIsland ? .on : .off
        menuBar.state = Prefs.showMenuBarIcon ? .on : .off
        island.isEnabled = Prefs.showMenuBarIcon
        menuBar.isEnabled = Prefs.showIsland
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

    @objc private func displayChanged() {
        Prefs.showIsland = island.state == .on
        Prefs.showMenuBarIcon = menuBar.state == .on
        note("show: status light \(Prefs.showIsland ? "on" : "off"), menu bar icon \(Prefs.showMenuBarIcon ? "on" : "off")")
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
