// DashboardView.swift
// The main window: connection status, per-controller cards, and the live log.

import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var engine: BridgeEngine

    @AppStorage("showLogs") private var showLogs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if engine.controllers.isEmpty {
                    emptyState
                } else {
                    controllerList
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $showConfig) {
                ConfigurationSection()
            } label: {
                Label("Configuration", systemImage: "gearshape")
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            DisclosureGroup(isExpanded: $showLogs) {
                LogView()
            } label: {
                Label("Logs", systemImage: "text.alignleft")
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @AppStorage("showConfig") private var showConfig = false

    private var header: some View {
        HStack {
            Image(systemName: engine.controllers.isEmpty
                  ? "gamecontroller" : "gamecontroller.fill")
                .font(.title2)
            Text(engine.engineState.rawValue)
                .font(.headline)
            Spacer()
            Text("\(engine.controllers.count) connected")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    /// The empty state must reflect WHY nothing is connected: pairing
    /// instructions are useless (and misleading) while Bluetooth is off or
    /// the app was denied Bluetooth access.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            switch engine.engineState {
            case .off:
                Text("Bluetooth is off")
                    .font(.title3)
                Text("Turn on Bluetooth to connect your controllers.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Open Bluetooth Settings…") { AppInfo.openBluetoothSettings() }
            case .unauthorized:
                Text("Bluetooth permission needed")
                    .font(.title3)
                Text("This app talks to controllers over Bluetooth, but access "
                     + "was denied. Allow it under Privacy & Security > Bluetooth.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Open Privacy Settings…") {
                    AppInfo.openPrivacySettings(anchor: "Privacy_Bluetooth")
                }
            default:
                Text("No controllers connected")
                    .font(.title3)
                Text("Press any button on a paired controller to wake it, or hold "
                     + "the Sync button (next to the USB-C port) until the player "
                     + "LEDs sweep to pair a new one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Open Bluetooth Settings…") { AppInfo.openBluetoothSettings() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    private var controllerList: some View {
        VStack(spacing: 8) {
            ForEach(engine.controllers) { controller in
                card(for: controller)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func card(for controller: ControllerStatus) -> some View {
        let serial = controller.serial
        let player = controller.player
        ControllerCard(
            status: controller,
            pairing: pairingInfo(for: controller),
            live: player >= 0 ? engine.liveStates[player] : nil,
            findRSSI: engine.findingSerial == serial ? engine.findRSSI : nil,
            onTestRumble: { engine.testRumble(player: player) },
            onNFCProbe: { engine.nfcProbe(serial: serial) },
            onAudioCapture: { engine.audioCapture(serial: serial) },
            onAudioTone: { engine.audioToneTest(serial: serial) },
            onAudioPlayTone: { engine.audioPlayTone(serial: serial) },
            onHapticMelody: { engine.hapticMelody(serial: serial) },
            onDisconnect: { engine.disconnect(serial: serial) },
            onForget: { engine.forget(serial: serial) },
            onFind: { engine.findController(serial: serial) },
            isFinding: engine.findingSerial == serial,
            onLedChanged: { engine.refreshLEDs(serial: serial) },
            info: engine.info(serial: serial))
    }

    /// Grip context for a card. A merged pair offers Unlink; a lone Joy-Con
    /// offers every connected, unlinked opposite-side unit as a link
    /// candidate, each with an identify buzzer so the user can tell
    /// physically identical units apart.
    private func pairingInfo(for status: ControllerStatus) -> ControllerCard.Pairing? {
        if status.isJoyConPair {
            return .init(candidates: [], linked: true,
                         link: { _ in },
                         unlink: { engine.unlink(serial: status.serial) },
                         identify: { engine.identify(serial: $0) })
        }
        let counterpartModel: Switch2.Model
        switch status.model {
        case .joyCon2Right: counterpartModel = .joyCon2Left
        case .joyCon2Left: counterpartModel = .joyCon2Right
        default: return nil
        }
        let candidates = engine.controllers
            .filter { $0.model == counterpartModel && !$0.isJoyConPair }
            .map { c in
                ControllerCard.Pairing.Candidate(
                    serial: c.serial,
                    name: ControllerSettings.shared.displayName(
                        forSerial: c.serial, modelName: c.name))
            }
        guard !candidates.isEmpty else { return nil }
        let mySerial = status.serial
        let myModel = status.model
        return .init(candidates: candidates, linked: false,
                     link: { otherSerial in
                         if myModel == .joyCon2Left {
                             engine.link(leftSerial: mySerial, rightSerial: otherSerial)
                         } else {
                             engine.link(leftSerial: otherSerial, rightSerial: mySerial)
                         }
                     },
                     unlink: { engine.unlink(serial: mySerial) },
                     identify: { engine.identify(serial: $0) })
    }
}

struct ControllerCard: View {
    /// Grip-mode pairing context for Joy-Con cards.
    struct Pairing {
        struct Candidate: Identifiable {
            let serial: String
            let name: String
            var id: String { serial }
        }
        let candidates: [Candidate]     // opposite-side units available to link
        let linked: Bool                // true on a merged pair card
        let link: (String) -> Void      // link with candidate serial
        let unlink: () -> Void
        let identify: (String) -> Void  // buzz a candidate by serial
    }

    let status: ControllerStatus
    var pairing: Pairing?
    var live: ControllerState?
    var findRSSI: Int?
    var onTestRumble: () -> Void = {}
    var onNFCProbe: () -> Void = {}
    var onAudioCapture: () -> Void = {}
    var onAudioTone: () -> Void = {}
    var onAudioPlayTone: () -> Void = {}
    var onHapticMelody: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onForget: () -> Void = {}
    var onFind: () -> Void = {}
    var isFinding: Bool = false
    var onLedChanged: () -> Void = {}
    var info: Switch2.ControllerInfo? = nil

    @ObservedObject private var settings = ControllerSettings.shared
    @State private var expanded = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var confirmForget = false
    /// Starts optimistic (caption hidden); the real preflight runs when the
    /// Lights & buttons group appears and when the toggle changes — a TCC
    /// call in the @State initializer would re-run on every 10 Hz card
    /// re-render just to be discarded.
    @State private var screenRecordingOK = true

    private func saveName() {
        settings.setCustomName(nameDraft, forSerial: status.serial)
        editingName = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(status.player >= 0 ? "P\(status.player + 1)" : "—")
                    .font(.system(.title2, design: .rounded).bold())
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.tint.opacity(0.15)))
                    .help(status.player >= 0 ? "Player \(status.player + 1)"
                          : "Connected, but all 4 player slots are in use")

                VStack(alignment: .leading, spacing: 2) {
                    if editingName {
                        HStack(spacing: 6) {
                            TextField(status.name, text: $nameDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                                .onSubmit { saveName() }
                            Button("Save") { saveName() }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(settings.displayName(forSerial: status.serial,
                                                      modelName: status.name))
                                .font(.headline)
                            Button {
                                nameDraft = settings.customName(forSerial: status.serial)
                                editingName = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Rename this controller")
                        }
                    }
                    Text(status.name)
                        .font(.caption)
                        .foregroundStyle(modelColor)
                    Text("Serial \(status.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button(isFinding ? "Stop finding" : "Find") { onFind() }
                        .controlSize(.small)
                        .help("Flash LEDs + buzz + proximity to locate this controller")
                    Button("Disconnect") { onDisconnect() }
                        .controlSize(.small)
                        .help("Disconnect now — any button press reconnects it")
                    Button("Forget…") { confirmForget = true }
                        .controlSize(.small)
                        .help("Disconnect and erase this controller's name, mappings, and settings")
                        .confirmationDialog(
                            "Forget \(settings.displayName(forSerial: status.serial, modelName: status.name))?",
                            isPresented: $confirmForget, titleVisibility: .visible
                        ) {
                            Button("Forget Controller", role: .destructive) { onForget() }
                        } message: {
                            Text("Its custom name, button and keyboard mappings, and "
                                 + "calibration will be erased. It can reconnect any "
                                 + "time, but starts fresh.")
                        }
                }
                VStack(alignment: .trailing, spacing: 4) {
                    // No phantom "0%": the percentage is only meaningful once
                    // a real voltage reading has arrived.
                    if status.batteryMillivolts > 0 {
                        Label("\(status.batteryPercent)%", systemImage: batteryIcon)
                    } else {
                        Label("—", systemImage: "battery.50percent")
                            .foregroundStyle(.secondary)
                            .help("Waiting for the first battery reading")
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Controller options")
            }
            .padding(10)

            if let rssi = findRSSI {
                // Proximity meter: closer = stronger signal = fuller/greener bar.
                let frac = min(1.0, max(0.0, Double(rssi + 90) / 60.0))
                VStack(spacing: 2) {
                    HStack {
                        Text("🔦 Finding — follow the buzzing; bar fills as you get closer")
                            .font(.caption)
                        Spacer()
                        Text("\(rssi) dBm").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(frac > 0.66 ? Color.green : frac > 0.33 ? Color.yellow : Color.orange)
                                .frame(width: geo.size.width * frac)
                        }
                    }
                    .frame(height: 10)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            if expanded {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 10) {
                    if let pairing {
                        if pairing.linked {
                            HStack(alignment: .top, spacing: 12) {
                                Picker("Held", selection: boolBinding(
                                    get: { settings.holdStyle(forSerial: status.serial) == "grip" },
                                    set: { settings.setHoldStyle($0 ? "grip" : "independent",
                                                                 forSerial: status.serial) })) {
                                    Text("In controller grip").tag(true)
                                    Text("Independently held").tag(false)
                                }
                                .pickerStyle(.radioGroup)
                                .help("How you're physically holding the pair — affects the input-test layout and future motion features")
                                Spacer()
                                Button("Unlink") { pairing.unlink() }
                                    .help("Split back into two standalone Joy-Cons")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Standalone — link into a grip with:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(pairing.candidates) { candidate in
                                    HStack(spacing: 10) {
                                        Button {
                                            pairing.identify(candidate.serial)
                                        } label: {
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                        }
                                        .help("Buzz this Joy-Con so you can tell which one it is")
                                        Text(candidate.name)
                                        Text(candidate.serial)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                        Button("Link") { pairing.link(candidate.serial) }
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Text("Rumble")
                        Slider(value: rumbleBinding, in: 0...1, step: 0.05)
                        Text("\(Int(settings.rumbleIntensity(forSerial: status.serial) * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Button("Test") { onTestRumble() }
                            .help("Play a short rumble pulse at this controller's strength")
                    }
                    if AppInfo.showPreReleaseFeatures {
                        DisclosureGroup("Keyboard mapping") {
                            KeyboardMappingView(serial: status.serial)
                        }
                    }
                    DisclosureGroup("Input test") {
                        VStack(spacing: 10) {
                            InputVisualizer(state: live, layout: vizLayout)
                            Divider()
                            MotionVisualizer(state: live, serial: status.serial)
                        }
                        .padding(.top, 6)
                    }
                    DisclosureGroup("Sensors & battery") {
                        SensorDashboard(state: live, serial: status.serial)
                            .padding(.top, 6)
                    }
                    DisclosureGroup("Lights & buttons") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Text("Player LEDs")
                                Picker("", selection: ledBinding) {
                                    Text("Auto (player #)").tag(0)
                                    Text("● ○ ○ ○").tag(1)
                                    Text("● ● ○ ○").tag(3)
                                    Text("● ● ● ○").tag(7)
                                    Text("● ● ● ●").tag(15)
                                }
                                .labelsHidden()
                                .frame(width: 160)
                            }
                            Toggle("Capture button takes a screenshot", isOn: boolBinding(
                                get: { settings.captureScreenshot(forSerial: status.serial) },
                                set: { on in
                                    settings.setCaptureScreenshot(on, forSerial: status.serial)
                                    // Without Screen Recording permission the
                                    // captures are silently blank — ask now,
                                    // while the user's intent is clear.
                                    if on && !CGPreflightScreenCaptureAccess() {
                                        CGRequestScreenCaptureAccess()
                                    }
                                    screenRecordingOK = CGPreflightScreenCaptureAccess()
                                }))
                                .toggleStyle(.checkbox)
                            if settings.captureScreenshot(forSerial: status.serial)
                                && !screenRecordingOK {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Label("Screenshots need Screen Recording permission "
                                          + "— they'll be blank without it.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Open System Settings") {
                                        AppInfo.openPrivacySettings(anchor: "Privacy_ScreenCapture")
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.top, 6)
                        .onAppear {
                            screenRecordingOK = CGPreflightScreenCaptureAccess()
                        }
                    }
                    if status.model == .joyCon2Left || status.model == .joyCon2Right {
                        DisclosureGroup("Mouse mode") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Lay the Joy-Con flat on a table like a mouse "
                                     + "(optical sensor down). SL clicks left, SR "
                                     + "clicks right. Needs Accessibility permission "
                                     + "the first time.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Toggle("Use as mouse", isOn: boolBinding(
                                    get: { settings.mouseEnabled(forSerial: status.serial) },
                                    set: { settings.setMouseEnabled($0, forSerial: status.serial) }))
                                    .toggleStyle(.switch)
                                HStack(spacing: 12) {
                                    Text("Sensitivity")
                                    Slider(value: boolDoubleBinding(
                                        get: { settings.mouseSensitivity(forSerial: status.serial) },
                                        set: { settings.setMouseSensitivity($0, forSerial: status.serial) }),
                                        in: 0.2...4.0)
                                    Text(String(format: "%.1f×",
                                                settings.mouseSensitivity(forSerial: status.serial)))
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                    DisclosureGroup("Button mapping") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Each physical button can act as any other. "
                                     + "Changed rows are highlighted.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset to default") {
                                    settings.resetButtonMap(forSerial: status.serial)
                                }
                            }
                            let map = settings.buttonMap(forSerial: status.serial)
                            ForEach(Switch2.namedButtons, id: \.name) { entry in
                                HStack {
                                    Text(entry.name)
                                        .frame(width: 130, alignment: .leading)
                                        .foregroundStyle(map[entry.name] != nil
                                                         ? Color.accentColor : .primary)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.tertiary)
                                    Picker("", selection: Binding(
                                        get: { map[entry.name] ?? entry.name },
                                        set: { settings.setButtonMapping(
                                            physical: entry.name, output: $0,
                                            forSerial: status.serial) })) {
                                        ForEach(Switch2.namedButtons, id: \.name) { target in
                                            Text(target.name).tag(target.name)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 170)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    // Deep, rarely-touched settings live one level down so the
                    // everyday card stays approachable.
                    DisclosureGroup("Advanced") {
                        VStack(spacing: 10) {
                            DisclosureGroup("Deadzone") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("The deadzone is the area around the stick's "
                                         + "center where input is ignored. If a character "
                                         + "or camera drifts on its own, raise this until "
                                         + "the drift stops — the stick's full range is "
                                         + "rescaled so you still reach maximum tilt.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 12) {
                                        Slider(value: deadzoneBinding, in: 0...0.25, step: 0.01)
                                        Text("\(Int(settings.deadzone(forSerial: status.serial) * 100))%")
                                            .monospacedDigit()
                                            .frame(width: 44, alignment: .trailing)
                                            .foregroundStyle(.secondary)
                                    }
                                    Divider()
                                    HStack {
                                        Text("Stick drift").frame(width: 90, alignment: .leading)
                                        Button("Recenter sticks now") { recenterSticks() }
                                            .help("Let go of the sticks, then click — captures the resting position as the new center")
                                        Button("Reset") {
                                            settings.setStickCenterOffset(l: (0, 0), r: (0, 0),
                                                                          forSerial: status.serial)
                                        }
                                    }
                                    HStack(spacing: 12) {
                                        Text("Trigger threshold").frame(width: 120, alignment: .leading)
                                        Slider(value: triggerBinding, in: 0...0.9, step: 0.05)
                                            .help("How far ZL/ZR must travel before registering (analog triggers)")
                                        Text("\(Int(settings.triggerThreshold(forSerial: status.serial) * 100))%")
                                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.top, 6)
                            }
                            DisclosureGroup("Invert axes") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle("Invert all axes", isOn: boolBinding(
                                        get: { settings.invertsAll(forSerial: status.serial) },
                                        set: { settings.setInvertAll($0, forSerial: status.serial) }))
                                    Divider()
                                    ForEach(ControllerSettings.StickAxis.allCases, id: \.rawValue) { axis in
                                        Toggle("Invert \(axis.label.lowercased())", isOn: boolBinding(
                                            get: { settings.invert(axis, forSerial: status.serial) },
                                            set: { settings.setInvert(axis, $0, forSerial: status.serial) }))
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.top, 6)
                            }
                            DisclosureGroup("Controller info") {
                                VStack(alignment: .leading, spacing: 4) {
                                    infoRow("Model", status.name)
                                    infoRow("Serial", status.serial)
                                    if let info {
                                        infoRow("Vendor / Product",
                                                String(format: "%04X / %04X", info.vendorID, info.productID))
                                        HStack(spacing: 8) {
                                            Text("Colors").frame(width: 130, alignment: .leading)
                                                .foregroundStyle(.secondary)
                                            colorSwatch(info.bodyColor)
                                            colorSwatch(info.buttonColor)
                                        }
                                    }
                                }
                                .font(.caption)
                                .padding(.top, 6)
                            }
                            if AppInfo.showPreReleaseFeatures,
                               status.model == .proController2, !status.isJoyConPair {
                                DisclosureGroup("Experiments") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Frontier features — results appear in the Logs "
                                             + "section below.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 10) {
                                            Button("Read NFC tag") { onNFCProbe() }
                                                .help("Detects an amiibo or NTAG on the touchpoint and dumps it; NDEF text is decoded")
                                            Button("Capture audio 30 s") { onAudioCapture() }
                                                .help("Records the headset-audio lane to ~/Documents. Plug in a headset WITH a mic and speak to capture real codec data. Buttons freeze during capture.")
                                            Button("Play tone (real-time)") { onAudioPlayTone() }
                                                .help("4 s of 440 Hz at the full configured PCM rate with backpressure — the honest test of the output format")
                                            Button("Format probe (4 phases)") { onAudioTone() }
                                                .help("Raw PCM, legacy rate, idle-frame mimic, then a frequency sweep — run once bare and once with headphones plugged in")
                                            Button("Haptic melody") { onHapticMelody() }
                                                .help("A little tune on the actuators via the documented rumble lane — no audio experiment, should always work")
                                        }
                                    }
                                    .padding(.top, 6)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var rumbleBinding: Binding<Double> {
        Binding(
            get: { settings.rumbleIntensity(forSerial: status.serial) },
            set: { settings.setRumbleIntensity($0, forSerial: status.serial) }
        )
    }

    /// Input-test arrangement matching the physical hardware and, for a
    /// pair, how the user says they're holding it.
    private var vizLayout: VizLayout {
        if status.isJoyConPair {
            return settings.holdStyle(forSerial: status.serial) == "grip"
                ? .pro : .pairIndependent
        }
        switch status.model {
        case .joyCon2Left: return .joyConLeft
        case .joyCon2Right: return .joyConRight
        default: return .pro
        }
    }

    private var ledBinding: Binding<Int> {
        Binding(
            get: { settings.ledPattern(forSerial: status.serial) },
            set: { settings.setLedPattern($0, forSerial: status.serial); onLedChanged() }
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }

    private func colorSwatch(_ rgb: (UInt8, UInt8, UInt8)) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255))
            .frame(width: 22, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3)))
    }

    private var deadzoneBinding: Binding<Double> {
        Binding(
            get: { settings.deadzone(forSerial: status.serial) },
            set: { settings.setDeadzone($0, forSerial: status.serial) }
        )
    }

    private func boolBinding(get: @escaping () -> Bool,
                             set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    private func boolDoubleBinding(get: @escaping () -> Double,
                                   set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    private var triggerBinding: Binding<Double> {
        Binding(
            get: { settings.triggerThreshold(forSerial: status.serial) },
            set: { settings.setTriggerThreshold($0, forSerial: status.serial) }
        )
    }

    /// Capture the current resting stick position and fold it into the
    /// stored center offset (live values are already offset-adjusted, so
    /// the new offset is old + current).
    private func recenterSticks() {
        guard let live else { return }
        let old = settings.stickCenterOffset(forSerial: status.serial)
        settings.setStickCenterOffset(
            l: (old.l.0 + live.leftStick.x, old.l.1 + live.leftStick.y),
            r: (old.r.0 + live.rightStick.x, old.r.1 + live.rightStick.y),
            forSerial: status.serial)
    }

    /// Joy-Con accent colors on the model line: neon red for the right
    /// unit, neon blue for the left — matching the hardware.
    private var modelColor: Color {
        switch status.model {
        case .joyCon2Right: return Color(red: 1.00, green: 0.24, blue: 0.16)
        case .joyCon2Left: return Color(red: 0.04, green: 0.73, blue: 0.90)
        default: return .secondary
        }
    }

    private var batteryIcon: String {
        switch status.batteryPercent {
        case 0..<15: return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct ConfigurationSection: View {
    @AppStorage(AppConfig.notifyEnabledKey) private var notifyEnabled = true
    @AppStorage(AppConfig.notifyConnectionsKey) private var notifyConnections = true
    @AppStorage(AppConfig.lowBatteryThresholdKey) private var lowBattery = 0.15
    @AppStorage(AppConfig.idleSleepMinutesKey) private var idleMinutes = 15.0
    @AppStorage(AppConfig.networkGamepadEnabledKey) private var networkGamepadEnabled = false
    @AppStorage(AppConfig.networkGamepadBasePortKey) private var networkGamepadBasePort = 55400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Notifications", isOn: $notifyEnabled)
            Toggle("Notify on connect / disconnect", isOn: $notifyConnections)
                .disabled(!notifyEnabled)
                .padding(.leading, 18)
            HStack(spacing: 12) {
                Text("Low-battery alert at")
                Slider(value: $lowBattery, in: 0.05...0.5, step: 0.05)
                    .disabled(!notifyEnabled)
                Text("\(Int(lowBattery * 100))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Sleep idle controllers after")
                Slider(value: $idleMinutes, in: 0...60, step: 5)
                Text(idleMinutes == 0 ? "Never" : "\(Int(idleMinutes)) min")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            Text("A sleeping controller reconnects the moment any button is pressed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Network gamepad output (RetroArch)", isOn: $networkGamepadEnabled)
            HStack(spacing: 12) {
                Text("Base port")
                TextField("55400", value: $networkGamepadBasePort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(!networkGamepadEnabled)
                Text("players 1–4 on \(String(networkGamepadBasePort))–\(String(networkGamepadBasePort + 3))")
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 18)
            Text("Sends each player's state over local UDP to programs that accept a "
                 + "network gamepad — no SDL library needed; no rumble. "
                 + "RetroArch: Settings → Network → Network Gamepad, same base port.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 10) {
                Text("Settings backup")
                Button("Export…") { exportSettings() }
                Button("Import…") { importSettings() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Software update feed URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://…/appcast.json", text: $updateFeed)
                    .textFieldStyle(.roundedBorder)
                Text("The app checks this once a day and can update itself. Leave blank to disable.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8)
    }

    @AppStorage(Updater.feedURLKey) private var updateFeed = ""

    private func exportSettings() {
        guard let data = SettingsTransfer.export() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FinallyControllers.ftcw"
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? data.write(to: url) }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.begin { resp in
            if resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
                _ = SettingsTransfer.import(data)
            }
        }
    }
}

struct LogView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var minLevel: LogLevel = .info
    @State private var autoScroll = true
    /// User-adjustable panel height (drag the grab bar above the list).
    @AppStorage("logPanelHeight") private var panelHeight = 220.0
    @State private var dragStartHeight: Double?

    private var visibleEntries: [LogEntry] {
        store.entries.filter { $0.level.sortRank >= minLevel.sortRank }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Picker("", selection: $minLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Toggle("Follow", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Export…") { exportLog() }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            // Grab bar: drag up/down to resize the log panel.
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.35))
                .frame(width: 48, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStartHeight ?? panelHeight
                            dragStartHeight = start
                            // The panel sits at the bottom: dragging the bar
                            // up (negative y) makes the panel taller.
                            panelHeight = min(600, max(100, start - value.translation.height))
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleEntries) { entry in
                            LogLine(entry: entry)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: store.entries.count) { _, _ in
                    if autoScroll, let last = visibleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .frame(height: panelHeight)
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ftcw-diagnostics.log"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: LogStore.shared.logFileURL, to: dest)
        }
    }
}

struct LogLine: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.date))
                .foregroundStyle(.secondary)
            Text(entry.level.rawValue)
                .foregroundStyle(levelColor)
                .frame(width: 44, alignment: .leading)
            Text(entry.message)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .id(entry.id)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
