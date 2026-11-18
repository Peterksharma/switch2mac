// MouseController.swift
// Joy-Con 2 optical mouse → macOS pointer.
//
// The sensor (feature bit 0x10) streams absolute, free-running 16-bit
// counters in every input report; deltas are wrapping differences between
// consecutive reports. Surface contact is judged from the lift-distance and
// surface-quality fields (thresholds from Switch2Connect, verified against
// jc2mouse). SL clicks left, SR clicks right.
//
// Posting synthetic mouse events requires macOS Accessibility permission
// (System Settings > Privacy & Security > Accessibility); we preflight and
// request it once when the feature is first enabled.
//
// Threading: handle() is called on the Bluetooth queue per physical unit
// report; CGEvent posting is thread-safe.

import Foundation
import CoreGraphics
import AppKit
import os

final class MouseController: @unchecked Sendable {

    private struct UnitState {
        var lastX: UInt16 = 0
        var lastY: UInt16 = 0
        var primed = false          // first sample only seeds the counters
        var residualX: Double = 0   // sub-pixel remainders
        var residualY: Double = 0
        var leftDown = false
        var rightDown = false
    }

    private var units: [String: UnitState] = [:]
    private var permissionChecked = false
    private var permissionGranted = false
    private let displayBoundsLock = OSAllocatedUnfairLock<CGRect>(initialState: .null)

    init() {
        let refreshBounds = { [weak self] in
            let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            self?.displayBoundsLock.withLock { $0 = union }
        }
        DispatchQueue.main.async { refreshBounds() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
            refreshBounds()
        }
    }

    /// Wrapping signed difference of two mod-2^16 counters.
    private static func wrapDiff(_ current: UInt16, _ previous: UInt16) -> Int {
        (Int(current) &- Int(previous) &+ 0x8000) & 0xFFFF - 0x8000
    }

    /// On-surface heuristic (Switch2Connect defaults).
    private static func isTracking(_ state: ControllerState) -> Bool {
        state.liftDistance != 0 && state.liftDistance < 1000
            && state.surfaceQuality < 4000
    }

    func handle(serial: String, model: Switch2.Model, state: ControllerState) {
        guard model == .joyCon2Left || model == .joyCon2Right else { return }
        guard let config = ControllerSettings.configSnapshot(forSerial: serial),
              config.mouseEnabled else {
            if units[serial] != nil { units.removeValue(forKey: serial) }
            return
        }
        guard ensurePermission() else { return }

        var unit = units[serial] ?? UnitState()
        defer { units[serial] = unit }

        // Clicks come from the side buttons (the "rail" buttons that are
        // exposed when the Joy-Con is held flat like a mouse).
        let sl = model == .joyCon2Left ? state.buttons.contains(.slL)
                                       : state.buttons.contains(.slR)
        let sr = model == .joyCon2Left ? state.buttons.contains(.srL)
                                       : state.buttons.contains(.srR)
        updateButton(&unit.leftDown, pressed: sl, isLeft: true)
        updateButton(&unit.rightDown, pressed: sr, isLeft: false)

        guard unit.primed else {
            unit.lastX = state.mouseX
            unit.lastY = state.mouseY
            unit.primed = true
            return
        }
        let dxRaw = Self.wrapDiff(state.mouseX, unit.lastX)
        let dyRaw = Self.wrapDiff(state.mouseY, unit.lastY)
        unit.lastX = state.mouseX
        unit.lastY = state.mouseY

        guard Self.isTracking(state), dxRaw != 0 || dyRaw != 0 else { return }

        let sensitivity = config.mouseSensitivity
        let scale = 0.35 * sensitivity   // counts → points; tuned live
        var dx = Double(dxRaw) * scale + unit.residualX
        var dy = Double(dyRaw) * scale + unit.residualY
        let moveX = dx.rounded(.towardZero)
        let moveY = dy.rounded(.towardZero)
        unit.residualX = dx - moveX
        unit.residualY = dy - moveY
        dx = moveX
        dy = moveY
        guard dx != 0 || dy != 0 else { return }

        postMove(dx: dx, dy: dy, leftDown: unit.leftDown)
    }

    // MARK: - Event posting

    private func postMove(dx: Double, dy: Double, leftDown: Bool) {
        let current = CGEvent(source: nil)?.location ?? .zero
        var target = CGPoint(x: current.x + dx, y: current.y + dy)
        // Clamp to the union of displays so the cursor never vanishes.
        let bounds = displayBoundsLock.withLock { $0 }
        if !bounds.isNull {
            // NSScreen frames are bottom-left origin; CGEvent is top-left.
            let maxY = bounds.height
            target.x = min(max(target.x, bounds.minX), bounds.maxX - 1)
            target.y = min(max(target.y, 0), maxY - 1)
        }
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: target, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            event.post(tap: .cghidEventTap)
        }
    }

    private func updateButton(_ held: inout Bool, pressed: Bool, isLeft: Bool) {
        guard pressed != held else { return }
        held = pressed
        guard permissionGranted else { return }
        let position = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType = isLeft
            ? (pressed ? .leftMouseDown : .leftMouseUp)
            : (pressed ? .rightMouseDown : .rightMouseUp)
        let button: CGMouseButton = isLeft ? .left : .right
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: position, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func ensurePermission() -> Bool {
        if permissionChecked { return permissionGranted }
        permissionChecked = true
        permissionGranted = CGPreflightPostEventAccess()
        if !permissionGranted {
            permissionGranted = CGRequestPostEventAccess()
            if !permissionGranted {
                bridgeLog(.warning, "mouse",
                          "Accessibility permission needed for mouse mode — "
                          + "grant it in System Settings > Privacy & Security > "
                          + "Accessibility, then toggle mouse mode again")
            }
        }
        if permissionGranted {
            bridgeLog(.info, "mouse", "mouse mode ready")
        }
        return permissionGranted
    }
}
