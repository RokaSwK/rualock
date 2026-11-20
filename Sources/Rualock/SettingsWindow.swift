import AppKit

final class SettingsWindowController: NSWindowController {
    private let delay = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "Start Rualock when you log in", target: nil, action: nil)
    private let onReenroll: () -> Void

    init(onReenroll: @escaping () -> Void) {
        self.onReenroll = onReenroll
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 190),
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
        let reenroll = NSButton(title: "Re-enrol Face…", target: self, action: #selector(reenrollClicked))

        let grid = NSGridView(views: [
            [label("Lock after you leave:"), delay],
            [NSGridCell.emptyContentView, login],
            [label("Face:"), reenroll],
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
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func delayChanged() {
        Prefs.lockDelay = Prefs.lockDelays[delay.indexOfSelectedItem]
        note("lock delay set to \(Int(Prefs.lockDelay))s")
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
