// NetworkGamepadSink.swift
// Optional sink: publishes controller state as "network gamepad" datagrams
// over localhost UDP, one port per player (base port + slot, default
// 55400-55403), for programs that accept a remote gamepad over the network
// instead of reading input devices — RetroArch's Network Gamepad (Remote
// RetroPad) is the one this was built for, and it has no SDL input path on
// macOS, so the SDL bridge can't reach it. Off by default; toggled in
// Configuration.
//
// Wire format is the libretro remote protocol (RetroArch
// input/input_driver.h `struct remote_message`, 20 bytes, native
// little-endian):
//   i32 port | i32 device | i32 index | i32 id | u16 state | 2 pad
//   device 1 (JOYPAD): id = RetroPad button, state 0/1
//   device 5 (ANALOG): index 0 = left stick, 1 = right; id 0 = X, 1 = Y;
//                      state = Int16, +Y down
// The receiver reads ONE datagram per player per frame and drops the rest,
// so this sink sends diffs only, paced at 60/s per player, button edges
// before analog drift, and re-asserts held state every 2 s (a receiver
// launched mid-hold converges; zeros match its initial state). The
// protocol is one-way: no rumble.

import Foundation
import Darwin

final class NetworkGamepadSink: ControllerOutputSink, @unchecked Sendable {

    private static let sendInterval: TimeInterval = 1.0 / 60.0
    private static let refreshInterval: TimeInterval = 2.0
    /// Quantize axes so centre jitter doesn't eat the per-frame send budget.
    private static let analogQuantum: Int32 = 512

    private static let retroDeviceJoypad: Int32 = 1
    private static let retroDeviceAnalog: Int32 = 5
    private static let retroPadL2 = 12
    private static let retroPadR2 = 13

    /// Switch 2 button → RetroPad id (libretro.h RETRO_DEVICE_ID_JOYPAD_*).
    /// Home/Capture/C/GL/GR have no RetroPad slot; the remapper covers those.
    private static let buttonMap: [(Switch2.Buttons, Int)] = [
        (.b, 0), (.y, 1), (.minus, 2), (.plus, 3),
        (.dpadUp, 4), (.dpadDown, 5), (.dpadLeft, 6), (.dpadRight, 7),
        (.a, 8), (.x, 9), (.l, 10), (.r, 11), (.zl, 12), (.zr, 13),
        (.lStick, 14), (.rStick, 15),
    ]

    var onRumble: ((Int, Double, Double) -> Void)?

    private final class Player {
        var wantButtons: UInt16 = 0
        var sentButtons: UInt16 = 0
        var wantAxes = [Int16](repeating: 0, count: 4)   // LX LY RX RY
        var sentAxes = [Int16](repeating: 0, count: 4)
        var nextSendAt: TimeInterval = 0
        var lastRefreshAt: TimeInterval = 0
        /// Held state still to re-assert after the last refresh. Kept apart
        /// from sent*, which must stay the true model of what the receiver
        /// holds — clearing sent-bits to force a resend is how a release got
        /// skipped and a direction stayed stuck.
        var refreshButtons: UInt16 = 0
        var refreshAxes = [Bool](repeating: false, count: 4)
        var announced = false

        var reassertButtons: UInt16 { refreshButtons & wantButtons }
        var reassertAxis: Int? {
            (0..<4).first { refreshAxes[$0] && wantAxes[$0] != 0 }
        }
        var hasPending: Bool {
            wantButtons != sentButtons || wantAxes != sentAxes
                || reassertButtons != 0 || reassertAxis != nil
        }
        var isHeld: Bool {
            wantButtons != 0 || wantAxes.contains { $0 != 0 }
        }
    }

    private let queue = DispatchQueue(label: "com.petersharma.ftcw.netpad")
    private let players = (0..<BridgeEngine.maxPlayers).map { _ in Player() }
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var lastSendErrorAt: TimeInterval = 0

    init() {
        queue.async { [weak self] in self?.openSocket() }
    }

    deinit {
        timer?.cancel()
        if fd >= 0 { close(fd) }
    }

    private func openSocket() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            bridgeLog(.error, "netpad", "socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {}
    func controllerName(slot: Int, name: String) {}

    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            guard let self, let p = self.players[safe: slot] else { return }
            p.wantButtons = 0
            p.wantAxes = [0, 0, 0, 0]
            self.ensurePumping()
        }
    }

    func controllerState(slot: Int, state: ControllerState) {
        guard AppConfig.networkGamepadEnabled else { return }
        queue.async { [weak self] in
            guard let self, let p = self.players[safe: slot] else { return }
            var buttons: UInt16 = 0
            for (button, id) in Self.buttonMap where state.buttons.contains(button) {
                buttons |= 1 << id
            }
            // GameCube-style analog triggers report in lt/rt without ZL/ZR.
            if state.leftTrigger >= 128 { buttons |= 1 << Self.retroPadL2 }
            if state.rightTrigger >= 128 { buttons |= 1 << Self.retroPadR2 }
            p.wantButtons = buttons
            p.wantAxes = [
                Self.axis(state.leftStick.x),
                Self.axis(-state.leftStick.y),    // +Y up here, +Y down in RetroPad
                Self.axis(state.rightStick.x),
                Self.axis(-state.rightStick.y),
            ]
            self.ensurePumping()
        }
    }

    private static func axis(_ value: Double) -> Int16 {
        let raw = Int32(max(-1, min(1, value)) * 32767)
        return Int16(raw / analogQuantum * analogQuantum)
    }

    // MARK: Pump (queue-confined)

    /// The timer only runs while something is pending or held, so an idle
    /// or disabled sink costs nothing.
    private func ensurePumping() {
        guard timer == nil, fd >= 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.sendInterval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    private func pump() {
        let enabled = AppConfig.networkGamepadEnabled
        let basePort = AppConfig.networkGamepadBasePort
        let now = CFAbsoluteTimeGetCurrent()
        var busy = false

        for (slot, p) in players.enumerated() {
            if !enabled {
                // Toggled off mid-hold: release everything, then go quiet.
                p.wantButtons = 0
                p.wantAxes = [0, 0, 0, 0]
                p.announced = false
            } else if now - p.lastRefreshAt >= Self.refreshInterval {
                p.lastRefreshAt = now
                p.refreshButtons = p.wantButtons
                p.refreshAxes = p.wantAxes.map { $0 != 0 }
            }

            busy = busy || p.hasPending || p.isHeld
            guard now >= p.nextSendAt, p.hasPending else { continue }

            // Priority: button edges, analog changes, then re-asserts. Only
            // record a message as delivered once sendto accepts it; a
            // transient failure (ENOBUFS etc.) would otherwise drop a button
            // release for good, since only diffs are ever sent.
            let port = UInt16(clamping: basePort + slot)
            let diff = p.wantButtons ^ p.sentButtons
            let axis = (0..<4).max { a, b in
                abs(Int(p.wantAxes[a]) - Int(p.sentAxes[a]))
                    < abs(Int(p.wantAxes[b]) - Int(p.sentAxes[b]))
            }!
            if diff != 0 {
                let id = diff.trailingZeroBitCount
                let pressed = (p.wantButtons >> id) & 1
                guard send(Self.message(slot: slot, device: Self.retroDeviceJoypad,
                                        index: 0, id: Int32(id), state: pressed),
                           port: port, now: now) else { continue }
                p.sentButtons ^= 1 << id
                p.refreshButtons &= ~(UInt16(1) << id)   // an edge supersedes it
            } else if p.wantAxes[axis] != p.sentAxes[axis] {
                guard send(Self.message(slot: slot, device: Self.retroDeviceAnalog,
                                        index: Int32(axis / 2), id: Int32(axis % 2),
                                        state: UInt16(bitPattern: p.wantAxes[axis])),
                           port: port, now: now) else { continue }
                p.sentAxes[axis] = p.wantAxes[axis]
                p.refreshAxes[axis] = false
            } else if p.reassertButtons != 0 {
                let id = p.reassertButtons.trailingZeroBitCount
                guard send(Self.message(slot: slot, device: Self.retroDeviceJoypad,
                                        index: 0, id: Int32(id), state: 1),
                           port: port, now: now) else { continue }
                p.refreshButtons &= ~(UInt16(1) << id)
            } else if let held = p.reassertAxis {
                guard send(Self.message(slot: slot, device: Self.retroDeviceAnalog,
                                        index: Int32(held / 2), id: Int32(held % 2),
                                        state: UInt16(bitPattern: p.wantAxes[held])),
                           port: port, now: now) else { continue }
                p.refreshAxes[held] = false
            } else {
                continue
            }
            p.nextSendAt = now + Self.sendInterval
            if !p.announced {
                p.announced = true
                bridgeLog(.info, "netpad",
                          "player \(slot + 1) → udp://127.0.0.1:\(port) (network gamepad)")
            }
        }

        if !busy {
            timer?.cancel()
            timer = nil
        }
    }

    private static func message(slot: Int, device: Int32, index: Int32,
                                id: Int32, state: UInt16) -> [UInt8] {
        var d = [UInt8]()
        d.reserveCapacity(20)
        for v in [Int32(slot), device, index, id] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: state.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [0, 0])
        return d
    }

    /// True once the kernel accepted the datagram. Failures are logged at
    /// most once a second; the caller retries on the next tick.
    private func send(_ bytes: [UInt8], port: UInt16, now: TimeInterval) -> Bool {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // 127.0.0.1
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(fd, buf.baseAddress, buf.count, 0,
                           destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent == bytes.count { return true }
        if now - lastSendErrorAt >= 1.0 {
            lastSendErrorAt = now
            bridgeLog(.warning, "netpad",
                      "sendto 127.0.0.1:\(port) failed, retrying: \(String(cString: strerror(errno)))")
        }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
