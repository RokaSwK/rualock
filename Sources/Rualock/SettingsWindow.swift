import AppKit
import AVFoundation
import SwiftUI

/// Rualock Settings, laid out like System Settings: a grouped form in sections.
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

    init(onReenroll: @escaping () -> Void, onDisplayChange: @escaping () -> Void) {
        model = SettingsModel(onReenroll: onReenroll, onDisplayChange: onDisplayChange)
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Rualock Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 520, height: 780))
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.contentMaxSize = NSSize(width: 520, height: 1200)
        super.init(window: window)
        model.closeWindow = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Match the controls to the preferences (they can change from the menu bar icon, too).
    func refresh() { model.reload() }
}

/// The settings as the form shows them. Writes go straight to `Prefs`; the ones that weaken
/// protection (freezing instead of locking, no blink check) need Touch ID first.
final class SettingsModel: ObservableObject {
    @Published var freeze = Prefs.freezeInstead
    @Published var blink = Prefs.requireBlink
    @Published var showIsland = Prefs.showIsland
    @Published var showMenuBar = Prefs.showMenuBarIcon
    @Published var startsAtLogin = System.startsAtLogin
    @Published var diagnostics = Prefs.recordDiagnostics
    @Published var lockDelay = Prefs.lockDelay
    @Published var height = Prefs.islandHeight
    @Published var dot = Prefs.islandDot
    @Published var text = Prefs.islandText
    @Published var style = Prefs.islandStyle
    @Published var corner = Prefs.islandCorner
    @Published var ear = Prefs.islandEar
    @Published var join = Prefs.islandJoin
    @Published var advanced = false
    @Published var canBlockAll = InputBlocker.allowed
    @Published var cameraAllowed = SettingsModel.cameraAuthorized

    let onReenroll: () -> Void
    let onDisplayChange: () -> Void
    var closeWindow: () -> Void = {}

    init(onReenroll: @escaping () -> Void, onDisplayChange: @escaping () -> Void) {
        self.onReenroll = onReenroll
        self.onDisplayChange = onDisplayChange
    }

    func reload() {
        freeze = Prefs.freezeInstead
        blink = Prefs.requireBlink
        showIsland = Prefs.showIsland
        showMenuBar = Prefs.showMenuBarIcon
        startsAtLogin = System.startsAtLogin
        diagnostics = Prefs.recordDiagnostics
        lockDelay = Prefs.lockDelay
        height = Prefs.islandHeight
        dot = Prefs.islandDot
        text = Prefs.islandText
        style = Prefs.islandStyle
        corner = Prefs.islandCorner
        ear = Prefs.islandEar
        join = Prefs.islandJoin
        canBlockAll = InputBlocker.allowed
        cameraAllowed = Self.cameraAuthorized
    }

    static var cameraAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Permissions are granted in System Settings: pick up changes while this window is open.
    func pollPermissions() {
        if canBlockAll != InputBlocker.allowed { canBlockAll = InputBlocker.allowed }
        if cameraAllowed != Self.cameraAuthorized { cameraAllowed = Self.cameraAuthorized }
    }

    /// The light can't be shorter than its ring, so a bigger dot raises the minimum height.
    var heightRange: ClosedRange<Double> {
        let lo = Double(IslandView.minHeight)
        return lo ... max(lo + 0.5, Double(IslandView.maxHeightHere))
    }

    var shownHeight: Double { height.clamped(to: heightRange) }

    // MARK: writes

    func setFreeze(_ on: Bool) {
        guard on else {
            Prefs.freezeInstead = false
            freeze = false
            note("when you leave: lock")
            return
        }
        guard !Prefs.freezeInstead else { return }
        objectWillChange.send()  // the picker stays on "Lock" until Touch ID succeeds
        System.authenticate("freeze the screen instead of locking it") { [weak self] ok in
            guard ok else { return }
            Prefs.freezeInstead = true
            self?.freeze = true
            note("when you leave: freeze (prank)")
            // Freezing blocks everything only with Accessibility access: ask for it straight away.
            if !InputBlocker.allowed { InputBlocker.requestAccess(openPane: false) }
        }
    }

    func setLockDelay(_ seconds: Double) {
        Prefs.lockDelay = seconds
        lockDelay = seconds
        note("lock delay set to \(Int(seconds))s")
    }

    /// Turning the blink check off weakens protection, so it needs Touch ID like pausing does.
    func setBlink(_ on: Bool) {
        guard !on else {
            Prefs.requireBlink = true
            blink = true
            note("blink check on")
            return
        }
        objectWillChange.send()
        System.authenticate("turn off the blink check in Rualock") { [weak self] ok in
            guard ok else { return }
            Prefs.requireBlink = false
            self?.blink = false
            note("blink check off")
        }
    }

    /// One of the two must stay on, or you'd have no way back to the menu short of opening the app again.
    func setShow(island: Bool? = nil, menuBar: Bool? = nil) {
        if let island { Prefs.showIsland = island }
        if let menuBar { Prefs.showMenuBarIcon = menuBar }
        if !Prefs.showIsland && !Prefs.showMenuBarIcon { Prefs.showIsland = true }
        showIsland = Prefs.showIsland
        showMenuBar = Prefs.showMenuBarIcon
        note("show: status light \(showIsland ? "on" : "off"), menu bar icon \(showMenuBar ? "on" : "off")")
        onDisplayChange()
    }

    /// A preset sets every size at once; moving any slider makes the style Custom.
    func setStyle(_ s: IslandStyle) {
        Prefs.islandStyle = s
        reload()
        onDisplayChange()
        note("status light style: \(s.rawValue)")
    }

    /// Writes one size (rounded to `step`), which makes the style Custom.
    private func setSize(_ v: Double, step: Double, _ write: (Double) -> Void) {
        write((v / step).rounded() * step)
        reload()
        onDisplayChange()
    }

    func setHeight(_ v: Double) { setSize(v, step: 0.5) { Prefs.islandHeight = $0 } }
    func setDot(_ v: Double) { setSize(v, step: 0.25) { Prefs.islandDot = $0 } }
    func setText(_ v: Double) { setSize(v, step: 0.5) { Prefs.islandText = $0 } }
    func setCorner(_ v: Double) { setSize(v, step: 0.5) { Prefs.islandCorner = $0 } }
    func setEar(_ v: Double) { setSize(v, step: 0.5) { Prefs.islandEar = $0 } }
    func setJoin(_ v: Double) { setSize(v, step: 0.5) { Prefs.islandJoin = $0 } }

    func setStartsAtLogin(_ on: Bool) {
        System.startsAtLogin = on
        startsAtLogin = System.startsAtLogin
    }

    func setDiagnostics(_ on: Bool) {
        Prefs.recordDiagnostics = on
        diagnostics = on
        note("diagnostics \(on ? "on" : "off")")
    }

    func showDiagnosticsFolder() {
        try? FileManager.default.createDirectory(at: Diagnostics.shared.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.dir])
    }

    func reenroll() {
        closeWindow()
        onReenroll()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: set)
    }

    var body: some View {
        Form {
            Section {
                Picker("When you leave", selection: bind({ model.freeze }, model.setFreeze)) {
                    Text("Lock the Mac").tag(false)
                    Text("Freeze the screen (prank)").tag(true)
                }
                Picker("After", selection: bind({ model.lockDelay }, model.setLockDelay)) {
                    ForEach(Prefs.lockDelays, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                if model.freeze {
                    LabeledContent {
                        if model.canBlockAll {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow Accessibility…") { InputBlocker.requestAccess() }
                        }
                    } label: {
                        Text("Block all input")
                        Text(model.canBlockAll
                             ? "Keys, clicks, the cursor, gestures and system shortcuts all stop."
                             : "Without Accessibility access, only clicks and typing stop; gestures and Spotlight still work.")
                    }
                }
            } footer: {
                if model.freeze {
                    Text("The screen looks unlocked, but nothing responds until Rualock sees your face and a blink. To get in without it, press ⌃⌘Q (or the power button) to lock, then unlock as usual. A prank, not a lock.")
                        .settingsFooter()
                }
            }

            Section {
                Toggle(isOn: bind({ model.blink }, model.setBlink)) {
                    Text("Require a blink")
                    Text("So a photo can't stand in for you. Turning it off needs Touch ID.")
                }
            } header: {
                Text("Security")
            }

            Section {
                Toggle("Next to the camera", isOn: bind({ model.showIsland }, { model.setShow(island: $0) }))
                    .disabled(!model.showMenuBar)
                Toggle("In the menu bar", isOn: bind({ model.showMenuBar }, { model.setShow(menuBar: $0) }))
                    .disabled(!model.showIsland)
                Picker("Style", selection: bind({ model.style }, model.setStyle)) {
                    ForEach(IslandStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.showIsland)
            } header: {
                Text("Status light")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $model.advanced) {
                    sizeSlider("Height", value: model.shownHeight, range: model.heightRange, set: model.setHeight,
                               label: model.shownHeight >= model.heightRange.upperBound - 0.25 ? "Notch" : points(model.shownHeight))
                    sizeSlider("Dot", value: model.dot, range: Prefs.islandDotSizes, set: model.setDot, label: points(model.dot))
                    sizeSlider("Text", value: model.text, range: Prefs.islandTextSizes, set: model.setText, label: points(model.text))
                    sizeSlider("Corner radius", value: model.corner, range: Prefs.islandCornerSizes, set: model.setCorner, label: points(model.corner))
                    sizeSlider("Top flare", value: model.ear, range: Prefs.islandFlareSizes, set: model.setEar, label: points(model.ear))
                    sizeSlider("Notch join", value: model.join, range: Prefs.islandFlareSizes, set: model.setJoin, label: points(model.join))
                        .disabled(!model.showIsland || model.shownHeight >= model.heightRange.upperBound - 0.25)
                }
            } footer: {
                if model.advanced {
                    Text("Corner radius rounds the light's outer bottom corner. Top flare curves it into the top of the screen, and Notch join into the side of the notch below it (only while the light is shorter than the notch). Moving any slider makes the style Custom.")
                        .settingsFooter()
                }
            }

            Section {
                LabeledContent {
                    permission(model.cameraAllowed, "Allow…", action: System.openCameraPrivacySettings)
                } label: {
                    Text("Camera")
                    Text("To see your face. Rualock doesn't work without it.")
                }
                LabeledContent {
                    permission(model.canBlockAll, "Allow…") { InputBlocker.requestAccess() }
                } label: {
                    Text("Accessibility")
                    Text("Lets freeze mode block all input: keys, clicks, the cursor, gestures and shortcuts.")
                }
            } header: {
                Text("Permissions")
            }

            Section {
                Toggle("Start Rualock when you log in", isOn: bind({ model.startsAtLogin }, model.setStartsAtLogin))
                LabeledContent("Your face") {
                    Button("Re-enrol…", action: model.reenroll)
                }
            } header: {
                Text("General")
            }

            Section {
                Toggle(isOn: bind({ model.diagnostics }, model.setDiagnostics)) {
                    Text("Record diagnostics for tuning")
                    Text("Numbers only, kept on this Mac for 14 days.")
                }
                LabeledContent("Diagnostics folder") {
                    Button("Show in Finder", action: model.showDiagnosticsFolder)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Rualock \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .settingsFooter()
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        // Accessibility is granted in System Settings: notice when it changes.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in model.pollPermissions() }
    }

    /// "Allowed" with a tick, or a button that asks for the permission.
    @ViewBuilder
    private func permission(_ granted: Bool, _ title: String, action: @escaping () -> Void) -> some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button(title, action: action)
        }
    }

    private func points(_ v: Double) -> String { String(format: "%g pt", v) }

    /// A slider that changes the light as you drag, with its value beside it.
    private func sizeSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void,
                            label: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: bind({ value }, set), in: range) { editing in
                    if !editing { note("status light \(title.lowercased()): \(label)") }
                }
                .labelsHidden()
                .frame(width: 180)
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .disabled(!model.showIsland)
    }
}

private extension View {
    func settingsFooter() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
