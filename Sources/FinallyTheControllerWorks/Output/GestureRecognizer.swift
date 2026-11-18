// GestureRecognizer.swift
// Air-gesture macros: hold a chosen "gesture button," move the controller to
// draw a shape (a circle, a check, a flick), release — the app matches the
// gyro path against saved templates and fires the bound action.
//
// Holding a button to bookend the motion makes segmentation trivial and
// eliminates false positives from ordinary handling. Matching resamples each
// path to a fixed length, normalizes it (translation + scale invariant), and
// takes the nearest template under a distance threshold — a 1-D adaptation of
// the "$1 recognizer" idea over the 3-axis gyro signal.

import Foundation
import CoreGraphics
import AppKit
import os

/// A stored gesture: normalized template + the action it triggers.
struct AirGesture: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var template: [Double]        // 3*N normalized samples
    var key: KeySpec?             // keystroke action…
    var builtin: String?         // …or a built-in action id
}

enum GestureAction {
    static let builtins: [(id: String, label: String)] = [
        ("screenshot", "Take a screenshot"),
        ("lock", "Lock the screen"),
        ("missionControl", "Mission Control"),
        ("spotlight", "Spotlight search"),
    ]
}

final class GestureRecognizer: @unchecked Sendable {

    static let sampleCount = 24
    static let matchThreshold = 0.55

    private struct SharedConfig {
        var triggerButton: Switch2.Buttons = .gl
        var gestures: [AirGesture] = []
        var recordingName: String?
        var onRecorded: ((AirGesture) -> Void)?
    }

    private let configLock = OSAllocatedUnfairLock<SharedConfig>(initialState: SharedConfig())
    private var capturing: [Int: [SIMD3<Double>]] = [:]   // btQueue-confined
    private var wasHeld: [Int: Bool] = [:]                // btQueue-confined

    /// When set, the next captured path is saved as a template with this
    /// name (via onRecorded) rather than matched.
    var recordingName: String? {
        get { configLock.withLock { $0.recordingName } }
        set { configLock.withLock { $0.recordingName = newValue } }
    }
    var onRecorded: ((AirGesture) -> Void)? {
        get { configLock.withLock { $0.onRecorded } }
        set { configLock.withLock { $0.onRecorded = newValue } }
    }

    init() {
        reload()
        refreshTrigger()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard, queue: nil) { [weak self] _ in
            self?.refreshTrigger()
        }
    }

    private func refreshTrigger() {
        let name = UserDefaults.standard.string(forKey: "gestureTriggerButton") ?? "GL"
        if let btn = Switch2.button(named: name) {
            configLock.withLock { $0.triggerButton = btn }
        }
    }

    func reload() {
        let list: [AirGesture]
        if let data = UserDefaults.standard.data(forKey: "airGestures"),
           let decoded = try? JSONDecoder().decode([AirGesture].self, from: data) {
            list = decoded
        } else {
            list = []
        }
        configLock.withLock { $0.gestures = list }
    }

    static func save(_ gestures: [AirGesture]) {
        if let data = try? JSONEncoder().encode(gestures) {
            UserDefaults.standard.set(data, forKey: "airGestures")
        }
    }

    /// Feed one player's report. Buffers gyro while the trigger is held;
    /// on release, records or matches.
    func process(player: Int, buttons: Switch2.Buttons, gyro: (Int16, Int16, Int16)) {
        let (trigger, isIdle) = configLock.withLock {
            ($0.triggerButton, $0.gestures.isEmpty && $0.recordingName == nil)
        }
        if isIdle {
            if !capturing.isEmpty || !wasHeld.isEmpty {
                capturing.removeAll(keepingCapacity: true)
                wasHeld.removeAll(keepingCapacity: true)
            }
            return
        }
        let held = buttons.contains(trigger)
        let was = wasHeld[player] ?? false
        wasHeld[player] = held

        if held {
            var buf = capturing[player] ?? []
            buf.append(SIMD3(Double(gyro.0), Double(gyro.1), Double(gyro.2)))
            if buf.count > 400 { buf.removeFirst() }    // safety cap
            capturing[player] = buf
        } else if was {
            // Released — finalize.
            let path = capturing[player] ?? []
            capturing[player] = nil
            finalize(path)
        }
    }

    private func finalize(_ path: [SIMD3<Double>]) {
        guard path.count >= 8 else { return }   // too short to be a gesture
        let template = Self.normalize(Self.resample(path, to: Self.sampleCount))

        let (recName, recCallback, gestures) = configLock.withLock { cfg -> (String?, ((AirGesture) -> Void)?, [AirGesture]) in
            if let name = cfg.recordingName {
                cfg.recordingName = nil
                return (name, cfg.onRecorded, [])
            }
            return (nil, nil, cfg.gestures)
        }

        if let name = recName {
            let gesture = AirGesture(name: name, template: template)
            recCallback?(gesture)
            return
        }
        // Match against saved gestures.
        var best: (AirGesture, Double)?
        for g in gestures where g.template.count == template.count {
            let d = Self.distance(template, g.template)
            if best == nil || d < best!.1 { best = (g, d) }
        }
        if let (g, d) = best, d < Self.matchThreshold {
            bridgeLog(.info, "gesture", "recognized \"\(g.name)\" (distance \(String(format: "%.2f", d)))")
            fire(g)
        }
    }

    // MARK: - Signal processing

    private static func resample(_ path: [SIMD3<Double>], to n: Int) -> [SIMD3<Double>] {
        guard path.count > 1 else { return Array(repeating: path.first ?? .zero, count: n) }
        var out: [SIMD3<Double>] = []
        for i in 0..<n {
            let t = Double(i) / Double(n - 1) * Double(path.count - 1)
            let lo = Int(t.rounded(.down)), hi = min(lo + 1, path.count - 1)
            let frac = t - Double(lo)
            out.append(path[lo] * (1 - frac) + path[hi] * frac)
        }
        return out
    }

    /// Flatten, subtract mean, scale to unit RMS → translation/scale-invariant.
    private static func normalize(_ path: [SIMD3<Double>]) -> [Double] {
        var flat: [Double] = []
        for v in path { flat.append(v.x); flat.append(v.y); flat.append(v.z) }
        let mean = flat.reduce(0, +) / Double(flat.count)
        flat = flat.map { $0 - mean }
        let rms = (flat.map { $0 * $0 }.reduce(0, +) / Double(flat.count)).squareRoot()
        guard rms > 1e-6 else { return flat }
        return flat.map { $0 / rms }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { let d = a[i] - b[i]; sum += d * d }
        return (sum / Double(a.count)).squareRoot()
    }

    // MARK: - Actions

    private func fire(_ g: AirGesture) {
        if let key = g.key {
            guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return }
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil,
                                   virtualKey: CGKeyCode(key.keyCode), keyDown: down) {
                    e.flags = CGEventFlags(rawValue: key.modifiers)
                    e.post(tap: .cghidEventTap)
                }
            }
        } else if let builtin = g.builtin {
            Self.runBuiltin(builtin)
        }
    }

    private static func runBuiltin(_ id: String) {
        switch id {
        case "screenshot":
            run("/usr/sbin/screencapture", ["-x",
                FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Gesture \(Int(Date().timeIntervalSince1970)).png").path])
        case "lock":
            run("/usr/bin/pmset", ["displaysleepnow"])
        case "missionControl":
            run("/usr/bin/open", ["-a", "Mission Control"])
        case "spotlight":
            postHotkey(keyCode: 49, flags: .maskCommand)   // ⌘Space
        default: break
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: path); t.arguments = args
        try? t.run()
    }

    private static func postHotkey(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) {
                e.flags = flags; e.post(tap: .cghidEventTap)
            }
        }
    }
}
