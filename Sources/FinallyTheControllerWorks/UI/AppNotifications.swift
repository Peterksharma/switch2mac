// AppNotifications.swift
// Global configuration keys + the notification manager: low-battery alerts,
// connect/disconnect toasts, and idle-sleep announcements.

import Foundation
import Combine
import UserNotifications

/// Global app configuration, UserDefaults-backed. Sliders/toggles in the
/// dashboard's Configuration section write these; the engine and the
/// notification manager read them.
enum AppConfig {
    static let notifyEnabledKey = "notifyEnabled"              // Bool, default true
    static let notifyConnectionsKey = "notifyConnections"      // Bool, default true
    static let lowBatteryThresholdKey = "lowBatteryThreshold"  // Double 0-1, default 0.15
    static let idleSleepMinutesKey = "idleSleepMinutes"        // Double, 0 = never, default 15
    static let networkGamepadEnabledKey = "networkGamepadEnabled"        // Bool, default false
    static let networkGamepadBasePortKey = "networkGamepadBasePort"      // Int, default 55400

    static var notifyEnabled: Bool {
        UserDefaults.standard.object(forKey: notifyEnabledKey) as? Bool ?? true
    }
    static var notifyConnections: Bool {
        UserDefaults.standard.object(forKey: notifyConnectionsKey) as? Bool ?? true
    }
    static var lowBatteryThreshold: Double {
        UserDefaults.standard.object(forKey: lowBatteryThresholdKey) as? Double ?? 0.15
    }
    static var networkGamepadEnabled: Bool {
        UserDefaults.standard.object(forKey: networkGamepadEnabledKey) as? Bool ?? false
    }
    /// Network gamepad base UDP port; player N uses base + N - 1
    /// (RetroArch's `network_remote_base_port`).
    static var networkGamepadBasePort: Int {
        let port = UserDefaults.standard.object(forKey: networkGamepadBasePortKey) as? Int ?? 55400
        return min(max(port, 1024), 65535 - BridgeEngine.maxPlayers)
    }
    static var idleSleepMinutes: Double {
        UserDefaults.standard.object(forKey: idleSleepMinutesKey) as? Double ?? 15
    }
}

/// Watches the engine's published controller list and raises system
/// notifications on the transitions the user cares about.
///
/// Invariant: at most one low-battery alert per controller per connection
/// (resets when the controller reconnects).
/// Engine posts this (any thread) when it puts a controller to sleep.
let controllerSleptNotification = Notification.Name("ftcw.controllerSlept")
/// Engine posts this (any thread) after an NFC tag read completes.
/// userInfo: "uid" (String), "text" (String?), "bytes" (Int).
let nfcTagReadNotification = Notification.Name("ftcw.nfcTagRead")

@MainActor
final class NotificationManager: ObservableObject {

    /// How long to wait for a first battery reading before announcing a
    /// connection anyway (without the battery figure).
    private static let batteryWaitSeconds: TimeInterval = 10
    /// How long a sleep marker suppresses connect/disconnect toasts for its
    /// unit. Idle-sleep teardown (including a pair dissolving half by half)
    /// completes well within this window; a genuine wake-and-reconnect later
    /// than this still gets its connect toast.
    private static let sleepGraceSeconds: TimeInterval = 30

    private var cancellable: AnyCancellable?
    private var previous: [String: ControllerStatus] = [:]   // keyed by serial
    private var lowBatteryNotified: Set<String> = []
    /// Serials whose connect toast is deferred until battery loads;
    /// the value is the give-up-waiting fallback work item.
    private var pendingConnect: [String: DispatchWorkItem] = [:]
    /// Physical unit serials the engine put to sleep, with when. A merged
    /// pair's logical serial is "L+R" while the engine sleeps each HALF, so
    /// suppression must match on units, not whole logical serials.
    private var recentlySlept: [String: Date] = [:]

    func attach(to engine: BridgeEngine) {
        cancellable = engine.$controllers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] controllers in
                self?.diff(controllers)
            }
        NotificationCenter.default.addObserver(
            forName: controllerSleptNotification, object: nil, queue: .main
        ) { [weak self] note in
            let name = note.userInfo?["name"] as? String ?? "Controller"
            let serial = note.userInfo?["serial"] as? String
            Task { @MainActor in
                guard let self else { return }
                if let serial { self.recentlySlept[serial] = Date() }
                // Sleep is a connection-lifecycle event: same toggles apply.
                guard AppConfig.notifyEnabled, AppConfig.notifyConnections else { return }
                self.post(
                    title: "\(name) went to sleep",
                    body: "No input for a while — press any button to reconnect.")
            }
        }
        NotificationCenter.default.addObserver(
            forName: nfcTagReadNotification, object: nil, queue: .main
        ) { [weak self] note in
            let uid = note.userInfo?["uid"] as? String ?? "?"
            let text = note.userInfo?["text"] as? String
            let bytes = note.userInfo?["bytes"] as? Int ?? 0
            Task { @MainActor in
                guard AppConfig.notifyEnabled else { return }
                self?.post(
                    title: text.map { "NFC tag read: “\($0)”" } ?? "NFC tag read",
                    body: "UID \(uid) · \(bytes) bytes"
                          + (text == nil ? " (no NDEF text record)" : ""))
            }
        }
    }

    private func diff(_ controllers: [ControllerStatus]) {
        let current = Dictionary(uniqueKeysWithValues:
            controllers.map { ($0.serial, $0) })
        defer { previous = current }

        // Per-connection bookkeeping must run even while notifications are
        // disabled — otherwise a deferred connect toast could fire for a
        // controller that already left, and stale dedupe state could suppress
        // a future legitimate alert.
        var vanishedWhilePending: Set<String> = []
        for serial in Array(pendingConnect.keys) where current[serial] == nil {
            pendingConnect.removeValue(forKey: serial)?.cancel()
            vanishedWhilePending.insert(serial)
        }
        for serial in current.keys where previous[serial] == nil {
            lowBatteryNotified.remove(serial)
        }

        guard AppConfig.notifyEnabled else { return }

        let threshold = Int(AppConfig.lowBatteryThreshold * 100)
        for (serial, status) in current {
            let name = ControllerSettings.shared.displayName(
                forSerial: serial, modelName: status.name)
            if previous[serial] == nil {
                // A "new" controller whose unit just slept is the tail of a
                // pair dissolving (the surviving half republishes standalone)
                // — not a user-visible connection.
                if AppConfig.notifyConnections, !sleptRecently(serial) {
                    if status.batteryMillivolts > 0 {
                        postConnect(status, name: name)
                    } else {
                        // Battery hasn't reported yet — hold the toast so it
                        // can include a real percentage, with a fallback in
                        // case the reading never arrives.
                        deferConnect(serial: serial, name: name, player: status.player)
                    }
                }
            } else if status.batteryMillivolts > 0, pendingConnect[serial] != nil {
                // Battery finally reported: release the held toast. The order
                // matters — the dictionary must only be mutated on THIS path,
                // because battery-less republishes hit this else-if too and
                // must leave the pending entry (and its fallback) intact.
                pendingConnect.removeValue(forKey: serial)?.cancel()
                if AppConfig.notifyConnections { postConnect(status, name: name) }
            }
            // Low battery: fire once per connection, only on a real reading.
            if status.batteryMillivolts > 0,
               status.batteryPercent <= threshold,
               !lowBatteryNotified.contains(serial) {
                lowBatteryNotified.insert(serial)
                post(title: "\(name) battery low",
                     body: "\(status.batteryPercent)% remaining — plug it in soon.")
            }
        }
        for (serial, status) in previous where current[serial] == nil {
            // A connect that was never announced needs no farewell.
            if vanishedWhilePending.contains(serial) { continue }
            // The sleep toast already covered this disconnect (for a pair,
            // per half — the logical "L+R" id matches on its units).
            if sleptRecently(serial) {
                consumeSleepMarkers(for: serial, current: current)
                continue
            }
            guard AppConfig.notifyConnections else { continue }
            let name = ControllerSettings.shared.displayName(
                forSerial: serial, modelName: status.name)
            post(title: "\(name) disconnected",
                 body: "Press any button to reconnect.")
        }
    }

    // MARK: - Sleep-marker bookkeeping

    /// Physical unit serials of a logical controller ("L+R" for a merged
    /// pair, the serial itself otherwise).
    private func units(of serial: String) -> [String] {
        serial.split(separator: "+").map(String.init)
    }

    /// True while any unit of this logical controller has a live sleep
    /// marker. Expired markers are purged first, so a controller that wakes
    /// after the grace window still announces its reconnection.
    private func sleptRecently(_ serial: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.sleepGraceSeconds)
        recentlySlept = recentlySlept.filter { $0.value > cutoff }
        return units(of: serial).contains { recentlySlept[$0] != nil }
    }

    /// Consume markers for units that are no longer part of ANY connected
    /// controller. A marker must outlive a dissolving pair's card ("L+R"
    /// vanishing while the surviving half republishes standalone) so that
    /// the survivor's own later disconnect is suppressed too.
    private func consumeSleepMarkers(for serial: String,
                                     current: [String: ControllerStatus]) {
        for unit in units(of: serial) {
            let stillConnected = current.keys.contains { units(of: $0).contains(unit) }
            if !stillConnected { recentlySlept.removeValue(forKey: unit) }
        }
    }

    private func postConnect(_ status: ControllerStatus, name: String) {
        let slot = status.player >= 0 ? "Player \(status.player + 1)" : nil
        let battery = status.batteryMillivolts > 0
            ? "battery \(status.batteryPercent)%" : nil
        post(title: "\(name) connected",
             body: [slot, battery].compactMap { $0 }.joined(separator: " · "))
    }

    private func deferConnect(serial: String, name: String, player: Int) {
        pendingConnect[serial]?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.pendingConnect.removeValue(forKey: serial) != nil else { return }
            guard AppConfig.notifyEnabled, AppConfig.notifyConnections else { return }
            let slot = player >= 0 ? "Player \(player + 1)" : ""
            self.post(title: "\(name) connected", body: slot)
        }
        pendingConnect[serial] = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.batteryWaitSeconds, execute: fallback)
    }

    // MARK: - Posting & authorization

    private enum AuthState { case undetermined, requesting, granted, denied }
    private var authState: AuthState = .undetermined
    /// Alerts that arrived while the permission prompt was unresolved. A
    /// request added while authorization is .notDetermined is silently
    /// dropped by the system, so the very toast that TRIGGERED the prompt
    /// would be lost without this buffer.
    private var queuedAlerts: [(title: String, body: String)] = []

    /// Post an alert, requesting permission lazily on first use — a
    /// contextual prompt lands far better than one at first launch,
    /// competing with the onboarding window.
    private func post(title: String, body: String) {
        switch authState {
        case .granted:
            add(title: title, body: body)
        case .denied:
            break
        case .requesting:
            if queuedAlerts.count < 8 { queuedAlerts.append((title, body)) }
        case .undetermined:
            authState = .requesting
            queuedAlerts.append((title, body))
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in
                        self.authState = granted ? .granted : .denied
                        if granted {
                            for alert in self.queuedAlerts {
                                self.add(title: alert.title, body: alert.body)
                            }
                        } else {
                            bridgeLog(.warning, "notify",
                                      "notification permission denied — alerts disabled "
                                      + "(enable in System Settings > Notifications)")
                        }
                        self.queuedAlerts.removeAll()
                    }
                }
        }
    }

    private func add(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
