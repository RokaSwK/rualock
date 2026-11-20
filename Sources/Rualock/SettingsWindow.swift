import AppKit
import AVFoundation
import SwiftUI

/// Rualock Settings, laid out like System Settings: a sidebar of panes with coloured icons, the
/// pane's name in the toolbar, and each pane a grouped form.
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

    init(onReenroll: @escaping () -> Void, onDisplayChange: @escaping () -> Void) {
        model = SettingsModel(onReenroll: onReenroll, onDisplayChange: onDisplayChange)
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.title, .toolbars]  // the pane's title and the sidebar go in the toolbar
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Rualock"
        window.setContentSize(NSSize(width: 760, height: 580))
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.setFrameAutosaveName("RualockSettings")
        super.init(window: window)
        model.closeWindow = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Match the controls to the preferences (they can change from the menu bar icon, too).
    func refresh() { model.reload() }

    func select(_ pane: SettingsPane) { model.pane = pane }
}

/// The panes in the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, light, permissions, diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .light: return "Status Light"
        case .permissions: return "Permissions"
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "lock.fill"
        case .light: return "circle.fill"
        case .permissions: return "hand.raised.fill"
        case .diagnostics: return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .blue
        case .light: return .green
        case .permissions: return .indigo
        case .diagnostics: return .gray
        }
    }
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
    @Published var pane: SettingsPane? = .general
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

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    IconTile(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = model.pane ?? .general
            Group {
                switch pane {
                case .general: GeneralPane(model: model)
                case .light: StatusLightPane(model: model)
                case .permissions: PermissionsPane(model: model)
                case .diagnostics: DiagnosticsPane(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        // Permissions are granted in System Settings: notice when they change.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in model.pollPermissions() }
    }
}

private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: get, set: set)
}

/// A white symbol on a rounded, coloured square, like the icons in System Settings.
private struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// "Allowed" with a tick, or a button that asks for the permission.
@ViewBuilder
private func permission(_ granted: Bool, action: @escaping () -> Void) -> some View {
    if granted {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    } else {
        Button("Allow…", action: action)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rualock").font(.title2.weight(.semibold))
                        Text("Locks your Mac the moment you walk away.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

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
                        permission(model.canBlockAll) { InputBlocker.requestAccess() }
                    } label: {
                        Text("Block all input")
                        Text(model.canBlockAll
                             ? "Keys, clicks, the cursor, gestures and system shortcuts all stop."
                             : "Needs Accessibility access. Without it, only clicks and typing stop.")
                    }
                }
            } footer: {
                if model.freeze {
                    Text("The screen looks unlocked, but nothing responds until Rualock sees your face and a blink. To get in without it, press ⌃⌘Q to lock, then unlock as usual. A prank, not a lock.")
                        .settingsFooter()
                }
            }

            Section("Security") {
                Toggle(isOn: bind({ model.blink }, model.setBlink)) {
                    Text("Require a blink")
                    Text("So a photo can't stand in for you. Turning it off needs Touch ID.")
                }
                LabeledContent {
                    Button("Re-enrol…", action: model.reenroll)
                } label: {
                    Text("Your face")
                    Text("Learn your face again, for new glasses or lighting.")
                }
            }

            Section {
                Toggle("Open at login", isOn: bind({ model.startsAtLogin }, model.setStartsAtLogin))
            } footer: {
                Text("Rualock \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .settingsFooter()
            }
        }
    }
}

private struct StatusLightPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                IslandPreview(look: [model.shownHeight, model.dot, model.text, model.corner, model.ear, model.join])
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("Next to the camera", isOn: bind({ model.showIsland }, { model.setShow(island: $0) }))
                    .disabled(!model.showMenuBar)
                Toggle("In the menu bar", isOn: bind({ model.showMenuBar }, { model.setShow(menuBar: $0) }))
                    .disabled(!model.showIsland)
            } header: {
                Text("Show")
            } footer: {
                Text("At least one stays on, so you can always reach Rualock's menu.").settingsFooter()
            }

            Section {
                Picker("Style", selection: bind({ model.style }, model.setStyle)) {
                    ForEach(IslandStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Look")
            }

            Section {
                let atNotch = model.shownHeight >= model.heightRange.upperBound - 0.25
                SizeSlider("Height", value: model.shownHeight, range: model.heightRange, set: model.setHeight,
                           label: atNotch ? "Notch" : points(model.shownHeight))
                SizeSlider("Dot", value: model.dot, range: Prefs.islandDotSizes, set: model.setDot, label: points(model.dot))
                SizeSlider("Text", value: model.text, range: Prefs.islandTextSizes, set: model.setText, label: points(model.text))
                SizeSlider("Corner radius", value: model.corner, range: Prefs.islandCornerSizes, set: model.setCorner, label: points(model.corner))
                SizeSlider("Top flare", value: model.ear, range: Prefs.islandFlareSizes, set: model.setEar, label: points(model.ear))
                SizeSlider("Notch join", value: model.join, range: Prefs.islandFlareSizes, set: model.setJoin, label: points(model.join))
                    .disabled(atNotch)
            } header: {
                Text("Fine-tune")
            } footer: {
                Text("Corner radius rounds the outer bottom corner. Top flare curves the light into the top of the screen; Notch join curves it into the side of the notch below (only while it's shorter than the notch). Moving a slider switches the style to Custom.")
                    .settingsFooter()
            }
        }
        .disabled(!model.showIsland)
    }

    private func points(_ v: Double) -> String { String(format: "%g pt", v) }
}

/// A slider that changes the light as you drag, with its value beside it.
private struct SizeSlider: View {
    let title: String, value: Double, range: ClosedRange<Double>, set: (Double) -> Void, label: String

    init(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void, label: String) {
        (self.title, self.value, self.range, self.set, self.label) = (title, value, range, set, label)
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: bind({ value }, set), in: range) { editing in
                    if !editing { note("status light \(title.lowercased()): \(label)") }
                }
                .labelsHidden()
                .frame(width: 220)
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    permission(model.cameraAllowed, action: System.openCameraPrivacySettings)
                } label: {
                    Label {
                        Text("Camera")
                        Text("To see your face. Rualock doesn't work without it.")
                    } icon: {
                        IconTile(symbol: "video.fill", tint: .green)
                    }
                }
                LabeledContent {
                    permission(model.canBlockAll) { InputBlocker.requestAccess() }
                } label: {
                    Label {
                        Text("Accessibility")
                        Text("Lets freeze mode block all input: keys, clicks, the cursor, gestures and shortcuts.")
                    } icon: {
                        IconTile(symbol: "accessibility", tint: .blue)
                    }
                }
            } footer: {
                Text("Allow… opens Privacy & Security in System Settings. Turn Rualock on there, and this page updates by itself.")
                    .settingsFooter()
            }
        }
    }
}

private struct DiagnosticsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: bind({ model.diagnostics }, model.setDiagnostics)) {
                    Text("Record diagnostics for tuning")
                    Text("Numbers only, kept on this Mac for 14 days. No images, no face data.")
                }
                LabeledContent("Diagnostics folder") {
                    Button("Show in Finder", action: model.showDiagnosticsFolder)
                }
            } footer: {
                Text("Run Rualock with --report to summarise why it locked and how often a lock was probably false.")
                    .settingsFooter()
            }
        }
    }
}

/// The status light as it looks beside the notch, with your current sizes, opened as on hover.
private struct IslandPreview: NSViewRepresentable {
    /// The sizes it's drawn with; any change redraws it. (The light reads them from `Prefs` itself.)
    let look: [Double]

    func makeNSView(context: Context) -> PreviewCanvas { PreviewCanvas() }

    func updateNSView(_ canvas: PreviewCanvas, context: Context) {
        canvas.needsLayout = true
        canvas.island.needsDisplay = true
    }
}

private final class PreviewStatus: IslandStatus {
    var state: Watcher.State = .watching
    var absentFor: TimeInterval = 0
    var lockDelay: TimeInterval = 8
    var pauseWindow: (started: Date, until: Date)? = nil
}

/// A strip of desktop and menu bar with a notch, and the light growing out of it, at twice its real
/// size so the corners are easy to see.
final class PreviewCanvas: NSView {
    private static let zoom: CGFloat = 2

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(NSSize(width: newSize.width / Self.zoom, height: newSize.height / Self.zoom))
    }

    private let status = PreviewStatus()
    let island: IslandView
    private let notchView = NotchShape()
    private static let notchWidth: CGFloat = 110

    /// This Mac's notch height, or a typical one.
    private var notchHeight: CGFloat { NSScreen.screens.map(\.safeAreaInsets.top).max().flatMap { $0 > 0 ? $0 : nil } ?? 32 }

    override init(frame: NSRect) {
        island = IslandView(watcher: status, height: 21)
        super.init(frame: frame)
        island.notch = true
        island.hover = true
        island.clock = { 0.7 }  // a still frame of the glow
        addSubview(island)
        addSubview(notchView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = notchHeight
        let h = IslandView.height(notch: top), j = IslandView.join(notch: top, height: h)
        let notchLeft = bounds.midX - Self.notchWidth / 2 - 50
        let notchRight = notchLeft + Self.notchWidth
        notchView.frame = NSRect(x: notchLeft, y: bounds.maxY - top, width: Self.notchWidth, height: top)
        island.join = j
        island.frame = NSRect(x: notchRight - IslandView.notchOverlap, y: bounds.maxY - h - j,
                              width: island.expandedWidth, height: h + j)
        island.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.2, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.75, green: 0.36, blue: 0.42, alpha: 1)])?
            .draw(in: bounds, angle: 0)
        NSColor(white: 0, alpha: 0.18).setFill()
        NSRect(x: 0, y: bounds.maxY - notchHeight, width: bounds.width, height: notchHeight).fill()  // the menu bar
    }
}

/// The camera housing: black, with rounded bottom corners.
private final class NotchShape: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r: CGFloat = 10, b = bounds
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX, y: b.maxY))
        p.line(to: NSPoint(x: b.maxX, y: b.maxY))
        p.line(to: NSPoint(x: b.maxX, y: b.minY + r))
        p.curve(to: NSPoint(x: b.maxX - r, y: b.minY), controlPoint1: NSPoint(x: b.maxX, y: b.minY + r * 0.45), controlPoint2: NSPoint(x: b.maxX - r * 0.45, y: b.minY))
        p.line(to: NSPoint(x: b.minX + r, y: b.minY))
        p.curve(to: NSPoint(x: b.minX, y: b.minY + r), controlPoint1: NSPoint(x: b.minX + r * 0.45, y: b.minY), controlPoint2: NSPoint(x: b.minX, y: b.minY + r * 0.45))
        p.close()
        NSColor.black.setFill()
        p.fill()
    }
}

private extension View {
    func settingsFooter() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
