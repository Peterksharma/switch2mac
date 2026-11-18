// KeyboardMapper.swift
// Turns controller buttons into keyboard keystrokes so the controller works
// in apps and games that have NO controller support (map buttons to WASD,
// arrows, space, etc.). Mappings can be global ("All apps") or scoped to the
// frontmost application's bundle id — a per-app profile that switches
// automatically as you change apps.
//
// A key-mapped button is SUPPRESSED from the gamepad output (so it doesn't
// double-act as both a key and a pad button). Key events are posted via
// CGEvent, which needs the same Accessibility permission as mouse mode.

import Foundation
import CoreGraphics
import AppKit
import os

/// A bound key: virtual keycode + modifier flags + a human label.
struct KeySpec: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt64      // CGEventFlags rawValue
    var label: String

    var asDictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers), "label": label]
    }
    init(keyCode: UInt16, modifiers: UInt64, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    init?(dictionary: [String: Any]) {
        guard let k = dictionary["keyCode"] as? Int,
              let m = dictionary["modifiers"] as? Int,
              let l = dictionary["label"] as? String else { return nil }
        keyCode = UInt16(k); modifiers = UInt64(m); label = l
    }
}

final class KeyboardMapper: @unchecked Sendable {

    /// Frontmost app bundle id, refreshed by a workspace observer.
    private let frontAppLock = OSAllocatedUnfairLock<String>(initialState: "")
    private var lastButtons: [Int: Switch2.Buttons] = [:]    // per player
    private var permissionOK = false
    private var permissionChecked = false
    private var lastPreflightAt: CFAbsoluteTime = 0

    init() {
        let initial = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        frontAppLock.withLock { $0 = initial }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier ?? ""
            self?.frontAppLock.withLock { $0 = bundleID }
        }
    }

    /// Process one player's button state; post key events on edges.
    /// Returns the set of mapped buttons to suppress from gamepad output.
    func process(player: Int, serial: String, buttons: Switch2.Buttons) -> Switch2.Buttons {
        let app = frontAppLock.withLock { $0 }
        let map = Self.activeMap(serial: serial, app: app)
        guard !map.entries.isEmpty else {
            lastButtons[player] = buttons
            return []
        }
        // No Accessibility permission → no keystrokes can be posted. Return
        // empty so the engine does NOT suppress the mapped buttons: they
        // degrade to ordinary gamepad presses instead of going dead.
        guard ensurePermission() else {
            lastButtons[player] = buttons
            return []
        }

        let prev = lastButtons[player] ?? []
        for (b, spec) in map.entries {
            let now = buttons.contains(b), was = prev.contains(b)
            if now && !was { postKey(spec, down: true) }
            else if !now && was { postKey(spec, down: false) }
        }
        lastButtons[player] = buttons
        return map.mask
    }

    // MARK: - Mapping lookup

    /// The effective button→key map for a controller in an app: the app
    /// override if present, else the global map.
    private static func activeMap(serial: String, app: String) -> ControllerConfigSnapshot.KeyMap {
        guard let config = ControllerSettings.configSnapshot(forSerial: serial) else {
            return ControllerConfigSnapshot.KeyMap()
        }
        if !app.isEmpty, let appMap = config.appKeyMaps[app], !appMap.entries.isEmpty {
            return appMap
        }
        return config.globalKeyMap
    }

    // MARK: - Event posting

    private func postKey(_ spec: KeySpec, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(spec.keyCode), keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: spec.modifiers)
        event.post(tap: .cghidEventTap)
    }

    /// True when we may post CGEvents. The system prompt is requested at most
    /// once, but a denial must NOT latch: the user can grant permission in
    /// System Settings mid-session, and re-preflighting is cheap — a one-time
    /// check would leave the feature dead until relaunch.
    private func ensurePermission() -> Bool {
        if permissionOK { return true }
        if !permissionChecked {
            permissionChecked = true
            permissionOK = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
            if !permissionOK {
                bridgeLog(.warning, "keymap",
                          "Accessibility permission needed for keyboard mapping — "
                          + "grant it in System Settings > Privacy & Security > Accessibility")
            }
        } else {
            // process() runs per input report (~66 Hz) on the Bluetooth
            // queue — a TCC round trip at that rate would add jitter to the
            // whole input path, so re-preflight at most every 2 seconds.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPreflightAt >= 2 {
                lastPreflightAt = now
                permissionOK = CGPreflightPostEventAccess()
                if permissionOK {
                    bridgeLog(.info, "keymap",
                              "Accessibility permission granted — keyboard mapping active")
                }
            }
        }
        return permissionOK
    }
}
