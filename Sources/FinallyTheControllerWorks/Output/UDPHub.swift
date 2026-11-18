// UDPHub.swift
// Compatibility sink: re-broadcasts controller state on localhost UDP, one
// port per slot (24800 + slot), exactly like the original Python bridge —
// so the patched-SDL path (Gopher64-Both et al.) keeps working unchanged.
//
// Wire protocol (little-endian, must match SDL_s2udpjoystick.c):
//   State  out (44 bytes): "S2B1" | u32 seq | u32 buttons
//          | f32 lx,ly,rx,ry | u8 lt,rt | u16 battery_mv
//          | i16 gyro[3] | i16 accel[3]
//   Rumble in  (6 bytes):  "S2R1" | u8 strong | u8 weak
//   Any inbound datagram registers its sender as a subscriber (30 s TTL).

import Foundation
import Darwin
import os

final class UDPHub: ControllerOutputSink, @unchecked Sendable {

    private static let basePort: UInt16 = 24800
    private static let peerTTL: TimeInterval = 30

    var onRumble: ((Int, Double, Double) -> Void)?

    private final class SlotSocket {
        let fd: Int32
        var peers: [SockAddr: TimeInterval] = [:]
        var seq: UInt32 = 0
        var name: String = ""
        var readSource: DispatchSourceRead?
        /// Reusable 44-byte state packet buffer ("S2B1" header prefilled).
        var stateBuf: [UInt8] = {
            var b = [UInt8](repeating: 0, count: 44)
            b[0] = 0x53; b[1] = 0x32; b[2] = 0x42; b[3] = 0x31
            return b
        }()
        init(fd: Int32) { self.fd = fd }
    }

    /// Hashable wrapper for a peer sockaddr_in.
    private struct SockAddr: Hashable {
        let addr: UInt32   // network byte order
        let port: UInt16   // network byte order
    }

    private var slots: [Int: SlotSocket] = [:]
    private let queue = DispatchQueue(label: "com.petersharma.ftcw.udphub")
    /// Bitmask of slots with ≥1 active peer, so controllerState skips queue hops when idle.
    private let activePeerMask = OSAllocatedUnfairLock<UInt8>(initialState: 0)

    init() {
        queue.async { [weak self] in self?.openSockets() }
    }

    /// Bind whatever ports are free; retry the rest every 5 s (another bridge
    /// instance may be shutting down, e.g. the old Python one).
    private func openSockets() {
        openMissingSockets()
        if slots.count < BridgeEngine.maxPlayers {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.openSockets()
            }
        } else {
            bridgeLog(.info, "udphub",
                      "SDL-compat hub on udp://127.0.0.1:\(Self.basePort)-\(Self.basePort + UInt16(BridgeEngine.maxPlayers - 1))")
        }
    }

    private func openMissingSockets() {
        for slot in 0..<BridgeEngine.maxPlayers where slots[slot] == nil {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = (Self.basePort + UInt16(slot)).bigEndian
            addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // 127.0.0.1
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                bridgeLog(.warning, "udphub",
                          "port \(Self.basePort + UInt16(slot)) busy (another bridge running?) — will retry")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)

            let slotSocket = SlotSocket(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainSocket(slot: slot)
            }
            source.resume()
            slotSocket.readSource = source
            slots[slot] = slotSocket
        }
    }

    private func drainSocket(slot: Int) {
        guard let s = slots[slot] else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromPtr in
                    recvfrom(s.fd, &buf, buf.count, 0, fromPtr, &fromLen)
                }
            }
            if n < 0 { break }  // EWOULDBLOCK: drained
            let peer = SockAddr(addr: from.sin_addr.s_addr, port: from.sin_port)
            let isNewPeer = s.peers[peer] == nil
            s.peers[peer] = CFAbsoluteTimeGetCurrent()
            if isNewPeer {
                activePeerMask.withLock { $0 |= (1 << slot) }
                if !s.name.isEmpty {
                    // Late joiners get the name before their first state packet.
                    send(Self.namePacket(s.name), to: peer, via: s.fd)
                }
            }
            if n >= 6, buf[0] == 0x53, buf[1] == 0x32, buf[2] == 0x52, buf[3] == 0x31 {  // "S2R1"
                onRumble?(slot, Double(buf[4]) / 255.0, Double(buf[5]) / 255.0)
            }
        }
    }

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {}

    func controllerName(slot: Int, name: String) {
        queue.async { [weak self] in
            guard let self, let s = self.slots[slot], s.name != name else { return }
            s.name = name
            let packet = Self.namePacket(name)
            for peer in s.peers.keys {
                self.send(packet, to: peer, via: s.fd)
            }
        }
    }

    /// "S2N1" + UTF-8 name (truncated to 59 bytes).
    private static func namePacket(_ name: String) -> Data {
        var d = Data([0x53, 0x32, 0x4E, 0x31])  // "S2N1"
        d.append(Data(name.utf8).prefix(59))
        return d
    }

    private func send(_ packet: Data, to peer: SockAddr, via fd: Int32) {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = peer.port
        dest.sin_addr.s_addr = peer.addr
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    sendto(fd, bytes.baseAddress, bytes.count, 0,
                           destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            self?.slots[slot]?.seq = 0
        }
    }

    func controllerState(slot: Int, state: ControllerState) {
        guard slot >= 0, slot < 8 else { return }
        let hasPeers = activePeerMask.withLock { ($0 & (1 << slot)) != 0 }
        guard hasPeers else { return }

        queue.async { [weak self] in
            guard let self, let s = self.slots[slot], !s.peers.isEmpty else { return }
            s.seq &+= 1
            Self.fillStatePacket(&s.stateBuf, seq: s.seq, state: state)
            let now = CFAbsoluteTimeGetCurrent()
            for (peer, seen) in s.peers {
                if now - seen > Self.peerTTL {
                    s.peers.removeValue(forKey: peer)
                    continue
                }
                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = peer.port
                dest.sin_addr.s_addr = peer.addr
                _ = s.stateBuf.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                            sendto(s.fd, bytes.baseAddress, bytes.count, 0,
                                   destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            if s.peers.isEmpty {
                self.activePeerMask.withLock { $0 &= ~(1 << slot) }
            }
        }
    }

    private static func fillStatePacket(_ buf: inout [UInt8], seq: UInt32, state: ControllerState) {
        write(&buf, at: 4, seq.littleEndian)
        write(&buf, at: 8, state.buttons.rawValue.littleEndian)
        write(&buf, at: 12, Float(state.leftStick.x).bitPattern.littleEndian)
        write(&buf, at: 16, Float(state.leftStick.y).bitPattern.littleEndian)
        write(&buf, at: 20, Float(state.rightStick.x).bitPattern.littleEndian)
        write(&buf, at: 24, Float(state.rightStick.y).bitPattern.littleEndian)
        buf[28] = state.leftTrigger
        buf[29] = state.rightTrigger
        write(&buf, at: 30, state.batteryMillivolts.littleEndian)
        write(&buf, at: 32, UInt16(bitPattern: state.gyro.0).littleEndian)
        write(&buf, at: 34, UInt16(bitPattern: state.gyro.1).littleEndian)
        write(&buf, at: 36, UInt16(bitPattern: state.gyro.2).littleEndian)
        write(&buf, at: 38, UInt16(bitPattern: state.accel.0).littleEndian)
        write(&buf, at: 40, UInt16(bitPattern: state.accel.1).littleEndian)
        write(&buf, at: 42, UInt16(bitPattern: state.accel.2).littleEndian)
    }

    private static func write<T: FixedWidthInteger>(_ buf: inout [UInt8], at offset: Int, _ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { src in
            for i in 0..<src.count { buf[offset + i] = src[i] }
        }
    }
}
