// FTCWApp.swift
// "Finally the Controller Works" — app entry point.
//
// Menu-bar resident: launching the app starts the bridge; closing the
// dashboard window leaves it running; quitting from the menu stops
// everything (controllers drop within seconds once keep-alives cease).

import SwiftUI
import ServiceManagement

@main
struct FTCWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: appDelegate.engine, updater: appDelegate.updater)
        } label: {
            MenuBarIcon(engine: appDelegate.engine)
        }

        Window("Finally the Controller Works", id: "dashboard") {
            DashboardView(engine: appDelegate.engine)
                .frame(minWidth: 560, minHeight: 480)
        }
        .defaultSize(width: 680, height: 620)

        Window("Reaction Draft", id: "reaction-game") {
            ReactionGameView(game: appDelegate.game, engine: appDelegate.engine)
        }
        .defaultSize(width: 480, height: 460)

        Window("Sensor Challenges", id: "challenges") {
            ChallengeView(coordinator: appDelegate.challenges, engine: appDelegate.engine)
        }
        .defaultSize(width: 500, height: 480)

        Window("Air Gestures", id: "gestures") {
            GesturesView(engine: appDelegate.engine)
        }
        .defaultSize(width: 500, height: 480)

        Window("About", id: "about") { AboutView() }
            .windowResizability(.contentSize)

        Window("Software Update", id: "update") { UpdaterView(updater: appDelegate.updater) }
            .windowResizability(.contentSize)

        // First-run welcome tour. A scene (not a hand-built NSWindow) so the
        // dismiss environment action works and the menu can reopen it later.
        // Presented automatically only until the user has seen it once.
        Window("Welcome", id: "welcome") { OnboardingView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(
                UserDefaults.standard.bool(forKey: "onboardingSeen")
                ? .suppressed : .presented)
    }
}

/// The always-visible menu-bar glyph. A separate view so @ObservedObject
/// keeps it in sync with connects/disconnects — reading the engine directly
/// in the MenuBarExtra label closure would never be invalidated.
struct MenuBarIcon: View {
    @ObservedObject var engine: BridgeEngine

    var body: some View {
        Image(systemName: engine.controllers.isEmpty
              ? "gamecontroller" : "gamecontroller.fill")
            .accessibilityLabel(engine.controllers.isEmpty
                ? "Finally the Controller Works — no controllers connected"
                : "Finally the Controller Works — \(engine.controllers.count) connected")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = BridgeEngine()
    let game = ReactionGame()
    let challenges = ChallengeCoordinator()
    let updater = Updater()
    private let notifications = NotificationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridgeLog(.info, "app", "Finally the Controller Works — starting bridge")
        engine.addSink(UDPHub())
        engine.addSink(NetworkGamepadSink())
        engine.addSink(VirtualHIDSink())
        notifications.attach(to: engine)
        // Daily auto-update check (only if a feed URL is configured); results
        // surface as an "Update Available" item in the menu-bar dropdown.
        updater.checkOnLaunchIfDue()
    }
}

struct MenuContent: View {
    @ObservedObject var engine: BridgeEngine
    @ObservedObject var updater: Updater
    @ObservedObject private var settings = ControllerSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Open a window scene and bring the app forward — a menu-bar app's
    /// windows otherwise open behind whatever app is frontmost.
    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }

    var body: some View {
        Text(engine.engineState.rawValue)

        if engine.controllers.isEmpty {
            switch engine.engineState {
            case .off:
                Text("Turn on Bluetooth to connect controllers.")
                Button("Open Bluetooth Settings…") { AppInfo.openBluetoothSettings() }
            case .unauthorized:
                Text("Bluetooth permission was denied.")
                Button("Open Privacy Settings…") {
                    AppInfo.openPrivacySettings(anchor: "Privacy_Bluetooth")
                }
            default:
                Text("Press any button on a paired controller,\n"
                     + "or hold Sync (next to USB-C) to pair a new one.")
            }
        } else {
            ForEach(engine.controllers) { c in
                // Battery is only trustworthy once a real voltage reading has
                // arrived — omit it rather than show a phantom "0%".
                let battery = c.batteryMillivolts > 0 ? " — \(c.batteryPercent)%" : ""
                Text("\(c.player >= 0 ? "P\(c.player + 1)" : "—")  \(settings.displayName(forSerial: c.serial, modelName: c.name))\(battery)")
            }
        }

        // A found (or already-downloaded) update stays one click away even
        // after the update window is closed.
        if case .available(let entry) = updater.state {
            Divider()
            Button("Update Available: v\(entry.version)…") { show("update") }
        } else if case .readyToInstall(let entry) = updater.state {
            Divider()
            Button("Update Ready to Install: v\(entry.version)…") { show("update") }
        }

        Divider()

        Button("Open Dashboard") { show("dashboard") }

        // Hidden for the beta (AppInfo.showPreReleaseFeatures documents
        // the defaults key that brings them back).
        if AppInfo.showPreReleaseFeatures {
            Button("Reaction Draft (party game)") { show("reaction-game") }

            Button("Sensor Challenges") { show("challenges") }

            Button("Air Gestures") { show("gestures") }
        }

        Divider()

        Button("Check for Updates…") { show("update") }

        Button("Buy me a coffee ☕") {
            AppInfo.openBuyMeACoffee()
        }

        Button("Welcome Guide") { show("welcome") }

        Button("About") { show("about") }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    bridgeLog(.error, "app", "launch-at-login change failed: \(error.localizedDescription)")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        Divider()

        Button("Quit") {
            bridgeLog(.info, "app", "quitting — controllers will disconnect")
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
