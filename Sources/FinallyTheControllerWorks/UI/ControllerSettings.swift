// ControllerSettings.swift
// Per-controller preferences (custom name, rumble strength), keyed by the
// controller's serial number so they survive reconnects, slot shuffles, and
// app restarts. Backed by UserDefaults.

import Foundation
import Combine
import os

/// Pre-parsed, thread-safe snapshot of one controller's settings for the
/// ~66 Hz Bluetooth hot path (avoids UserDefaults dictionary bridging and
/// string lookups per input report).
struct ControllerConfigSnapshot: Sendable {
    struct KeyMap: Sendable {
        var entries: [(button: Switch2.Buttons, spec: KeySpec)] = []
        var mask: Switch2.Buttons = []
    }

    var name: String = ""
    var rumble: Double = 1.0
    var deadzone: Double = 0.0
    var stickCenterL: (Double, Double)?
    var stickCenterR: (Double, Double)?
    var triggerThreshold: Double = 0.0
    var invertLX: Bool = false
    var invertLY: Bool = false
    var invertRX: Bool = false
    var invertRY: Bool = false
    var ledPattern: Int = 0
    var captureScreenshot: Bool = false
    var mouseEnabled: Bool = false
    var mouseSensitivity: Double = 1.0
    var buttonRemap: [(from: Switch2.Buttons, to: Switch2.Buttons)] = []
    var globalKeyMap = KeyMap()
    var appKeyMaps: [String: KeyMap] = [:]
}

final class ControllerSettings: ObservableObject {
    static let shared = ControllerSettings()

    /// Posted after a custom name changes so the engine can re-announce
    /// controller names to games.
    static let namesChangedNotification = Notification.Name("ftcw.namesChanged")

    private static let defaultsKey = "controllerSettings"

    /// serial -> {"name": String, "rumble": Double}
    @Published private var store: [String: [String: Any]]
    private let snapshotLock = OSAllocatedUnfairLock<[String: ControllerConfigSnapshot]>(initialState: [:])

    private init() {
        store = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: [String: Any]] ?? [:]
        rebuildCache()
    }

    /// Thread-safe read of the pre-parsed configuration for `serial`.
    static func configSnapshot(forSerial serial: String) -> ControllerConfigSnapshot? {
        shared.snapshotLock.withLock { $0[serial] }
    }

    private func persist() {
        UserDefaults.standard.set(store, forKey: Self.defaultsKey)
        rebuildCache()
    }

    /// Re-read from UserDefaults (after an import overwrote the store).
    func reload() {
        store = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: [String: Any]] ?? [:]
        rebuildCache()
        objectWillChange.send()
    }

    private func rebuildCache() {
        var next: [String: ControllerConfigSnapshot] = [:]
        next.reserveCapacity(store.count)
        for (serial, entry) in store {
            next[serial] = Self.parseSnapshot(entry)
        }
        let snapshot = next
        snapshotLock.withLock { $0 = snapshot }
    }

    private static func parseSnapshot(_ entry: [String: Any]) -> ControllerConfigSnapshot {
        var s = ControllerConfigSnapshot()
        s.name = entry["name"] as? String ?? ""
        s.rumble = entry["rumble"] as? Double ?? 1.0
        s.deadzone = entry["deadzone"] as? Double ?? 0.0
        if let cl = entry["stickCenterL"] as? [Double], cl.count == 2 {
            s.stickCenterL = (cl[0], cl[1])
        }
        if let cr = entry["stickCenterR"] as? [Double], cr.count == 2 {
            s.stickCenterR = (cr[0], cr[1])
        }
        s.triggerThreshold = entry["triggerThreshold"] as? Double ?? 0.0
        s.invertLX = entry["invertLX"] as? Bool ?? false
        s.invertLY = entry["invertLY"] as? Bool ?? false
        s.invertRX = entry["invertRX"] as? Bool ?? false
        s.invertRY = entry["invertRY"] as? Bool ?? false
        s.ledPattern = entry["ledPattern"] as? Int ?? 0
        s.captureScreenshot = entry["captureScreenshot"] as? Bool ?? false
        s.mouseEnabled = entry["mouseEnabled"] as? Bool ?? false
        s.mouseSensitivity = entry["mouseSensitivity"] as? Double ?? 1.0

        if let map = entry["buttonMap"] as? [String: String], !map.isEmpty {
            var pairs: [(from: Switch2.Buttons, to: Switch2.Buttons)] = []
            pairs.reserveCapacity(Switch2.namedButtons.count)
            for (name, button) in Switch2.namedButtons {
                let targetName = map[name] ?? name
                if let target = Switch2.button(named: targetName) {
                    pairs.append((from: button, to: target))
                }
            }
            s.buttonRemap = pairs
        }

        func parseKeyMap(_ raw: Any?) -> ControllerConfigSnapshot.KeyMap {
            guard let dict = raw as? [String: [String: Any]], !dict.isEmpty else {
                return ControllerConfigSnapshot.KeyMap()
            }
            var km = ControllerConfigSnapshot.KeyMap()
            km.entries.reserveCapacity(dict.count)
            for (name, specDict) in dict {
                if let button = Switch2.button(named: name),
                   let spec = KeySpec(dictionary: specDict) {
                    km.entries.append((button: button, spec: spec))
                    km.mask.insert(button)
                }
            }
            return km
        }

        s.globalKeyMap = parseKeyMap(entry["keyMap"])
        if let byApp = entry["keyMapByApp"] as? [String: [String: [String: Any]]] {
            var parsedApps: [String: ControllerConfigSnapshot.KeyMap] = [:]
            for (bundleID, rawMap) in byApp {
                let km = parseKeyMap(rawMap)
                if !km.entries.isEmpty {
                    parsedApps[bundleID] = km
                }
            }
            s.appKeyMaps = parsedApps
        }
        return s
    }

    /// Forget everything stored about a controller (name, mappings, axis
    /// options, mouse mode, hold style).
    func removeSettings(forSerial serial: String) {
        store.removeValue(forKey: serial)
        persist()
        NotificationCenter.default.post(name: Self.namesChangedNotification, object: nil)
    }

    // MARK: Custom name

    func customName(forSerial serial: String) -> String {
        store[serial]?["name"] as? String ?? ""
    }

    /// The name shown in UI: the custom name when set, else the model name.
    func displayName(forSerial serial: String, modelName: String) -> String {
        let custom = customName(forSerial: serial)
        return custom.isEmpty ? modelName : custom
    }

    func setCustomName(_ name: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["name"] = name.trimmingCharacters(in: .whitespaces)
        store[serial] = entry
        persist()
        NotificationCenter.default.post(name: Self.namesChangedNotification, object: nil)
    }

    // MARK: Rumble strength

    func rumbleIntensity(forSerial serial: String) -> Double {
        store[serial]?["rumble"] as? Double ?? 1.0
    }

    func setRumbleIntensity(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["rumble"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Axis options

    func deadzone(forSerial serial: String) -> Double {
        store[serial]?["deadzone"] as? Double ?? 0.0
    }

    func setDeadzone(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["deadzone"] = value
        store[serial] = entry
        persist()
    }

    /// Stick axes that can be inverted, keyed by their UserDefaults name.
    enum StickAxis: String, CaseIterable {
        case leftX = "invertLX"
        case leftY = "invertLY"
        case rightX = "invertRX"
        case rightY = "invertRY"

        var label: String {
            switch self {
            case .leftX: return "Left thumbstick X"
            case .leftY: return "Left thumbstick Y"
            case .rightX: return "Right thumbstick X"
            case .rightY: return "Right thumbstick Y"
            }
        }
    }

    func invert(_ axis: StickAxis, forSerial serial: String) -> Bool {
        store[serial]?[axis.rawValue] as? Bool ?? false
    }

    func setInvert(_ axis: StickAxis, _ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry[axis.rawValue] = value
        store[serial] = entry
        persist()
    }

    // MARK: LED pattern (0 = auto player number; else bits 0..3)

    func ledPattern(forSerial serial: String) -> Int {
        store[serial]?["ledPattern"] as? Int ?? 0
    }

    func setLedPattern(_ value: Int, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["ledPattern"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Capture button → screenshot

    func captureScreenshot(forSerial serial: String) -> Bool {
        store[serial]?["captureScreenshot"] as? Bool ?? false
    }

    func setCaptureScreenshot(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["captureScreenshot"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Magnetometer calibration (hard-iron bias)

    func magBias(forSerial serial: String) -> (x: Double, y: Double, z: Double)? {
        guard let arr = store[serial]?["magBias"] as? [Double], arr.count == 3
        else { return nil }
        return (arr[0], arr[1], arr[2])
    }

    func setMagBias(_ bias: (x: Double, y: Double, z: Double), forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["magBias"] = [bias.x, bias.y, bias.z]
        store[serial] = entry
        persist()
    }

    // MARK: Mouse mode (Joy-Con 2 optical sensor)

    func mouseEnabled(forSerial serial: String) -> Bool {
        store[serial]?["mouseEnabled"] as? Bool ?? false
    }

    func setMouseEnabled(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["mouseEnabled"] = value
        store[serial] = entry
        persist()
    }

    func mouseSensitivity(forSerial serial: String) -> Double {
        store[serial]?["mouseSensitivity"] as? Double ?? 1.0
    }

    func setMouseSensitivity(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["mouseSensitivity"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Keyboard mapping (button → keystroke), global or per-app

    /// Read the key map for a controller, optionally for a specific app
    /// bundle id (nil/"" = the global map).
    func keyMap(forSerial serial: String, app: String?) -> [String: KeySpec] {
        let entry = store[serial] ?? [:]
        let raw: [String: [String: Any]]?
        if let app, !app.isEmpty {
            raw = (entry["keyMapByApp"] as? [String: [String: [String: Any]]])?[app]
        } else {
            raw = entry["keyMap"] as? [String: [String: Any]]
        }
        var out: [String: KeySpec] = [:]
        for (k, v) in raw ?? [:] { if let s = KeySpec(dictionary: v) { out[k] = s } }
        return out
    }

    func setKeyMapping(button: String, key: KeySpec?, forSerial serial: String, app: String?) {
        var entry = store[serial] ?? [:]
        if let app, !app.isEmpty {
            var byApp = entry["keyMapByApp"] as? [String: [String: [String: Any]]] ?? [:]
            var appMap = byApp[app] ?? [:]
            if let key { appMap[button] = key.asDictionary } else { appMap.removeValue(forKey: button) }
            byApp[app] = appMap
            entry["keyMapByApp"] = byApp
        } else {
            var map = entry["keyMap"] as? [String: [String: Any]] ?? [:]
            if let key { map[button] = key.asDictionary } else { map.removeValue(forKey: button) }
            entry["keyMap"] = map
        }
        store[serial] = entry
        persist()
    }

    func clearKeyMap(forSerial serial: String, app: String?) {
        var entry = store[serial] ?? [:]
        if let app, !app.isEmpty {
            var byApp = entry["keyMapByApp"] as? [String: [String: [String: Any]]] ?? [:]
            byApp.removeValue(forKey: app)
            entry["keyMapByApp"] = byApp
        } else {
            entry["keyMap"] = [String: [String: Any]]()
        }
        store[serial] = entry
        persist()
    }

    // MARK: Trigger threshold (0..1 travel before ZL/ZR registers)

    func triggerThreshold(forSerial serial: String) -> Double {
        store[serial]?["triggerThreshold"] as? Double ?? 0.0
    }

    func setTriggerThreshold(_ value: Double, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["triggerThreshold"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Stick center calibration (drift correction offsets, raw units)

    func stickCenterOffset(forSerial serial: String) -> (l: (Double, Double), r: (Double, Double)) {
        let e = store[serial] ?? [:]
        let l = e["stickCenterL"] as? [Double] ?? [0, 0]
        let r = e["stickCenterR"] as? [Double] ?? [0, 0]
        return ((l.first ?? 0, l.count > 1 ? l[1] : 0),
                (r.first ?? 0, r.count > 1 ? r[1] : 0))
    }

    func setStickCenterOffset(l: (Double, Double), r: (Double, Double), forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["stickCenterL"] = [l.0, l.1]
        entry["stickCenterR"] = [r.0, r.1]
        store[serial] = entry
        persist()
    }

    // MARK: Joy-Con pair hold style

    /// How a linked pair is physically held: "grip" (controller grip shell)
    /// or "independent" (one Joy-Con per hand). Affects the input-test
    /// layout now and sensor orientation math later.
    func holdStyle(forSerial serial: String) -> String {
        store[serial]?["holdStyle"] as? String ?? "grip"
    }

    func setHoldStyle(_ value: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["holdStyle"] = value
        store[serial] = entry
        persist()
    }

    // MARK: Button mapping

    /// physical name -> output name; absent key = identity.
    func buttonMap(forSerial serial: String) -> [String: String] {
        store[serial]?["buttonMap"] as? [String: String] ?? [:]
    }

    func setButtonMapping(physical: String, output: String, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        var map = entry["buttonMap"] as? [String: String] ?? [:]
        if output == physical {
            map.removeValue(forKey: physical)   // identity = no entry
        } else {
            map[physical] = output
        }
        entry["buttonMap"] = map
        store[serial] = entry
        persist()
    }

    func resetButtonMap(forSerial serial: String) {
        var entry = store[serial] ?? [:]
        entry["buttonMap"] = [String: String]()
        store[serial] = entry
        persist()
    }

    /// True when every axis is inverted (the "invert all" master state).
    func invertsAll(forSerial serial: String) -> Bool {
        StickAxis.allCases.allSatisfy { invert($0, forSerial: serial) }
    }

    func setInvertAll(_ value: Bool, forSerial serial: String) {
        var entry = store[serial] ?? [:]
        for axis in StickAxis.allCases {
            entry[axis.rawValue] = value
        }
        store[serial] = entry
        persist()
    }
}
