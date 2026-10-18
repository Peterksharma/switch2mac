// Switch2Protocol.swift
// The Nintendo Switch 2 controller BLE protocol: identifiers, GATT UUIDs,
// command framing, and input-report parsing.
//
// Protocol knowledge distilled from the community reverse-engineering effort
// (trevlars/switch2-controllers-linux, MIT; Nadeflore/switch2-controllers;
// the bitaxislabs BLE writeup), ported from our proven Python bridge.
//
// This file is transport-agnostic: no Bluetooth imports, fully unit-testable.

import Foundation

enum Switch2 {

    // MARK: - Identification

    /// BLE advertising manufacturer-data company id used by Switch 2 pads.
    static let nintendoCompanyID: UInt16 = 0x0553
    static let nintendoVendorID: UInt16 = 0x057E

    enum Model: UInt16, CaseIterable {
        case joyCon2Right = 0x2066
        case joyCon2Left = 0x2067
        case proController2 = 0x2069
        case nsoGameCube = 0x2073

        var displayName: String {
            switch self {
            case .joyCon2Right: return "Joy-Con 2 (R)"
            case .joyCon2Left: return "Joy-Con 2 (L)"
            case .proController2: return "Pro Controller 2"
            case .nsoGameCube: return "NSO GameCube Controller"
            }
        }

        /// Only the GameCube pad reports true analog triggers; the others
        /// report ZL/ZR as digital buttons.
        var hasAnalogTriggers: Bool { self == .nsoGameCube }

        /// Two-stick models. Joy-Cons have ONE stick: its calibration lives
        /// in the unit's stick-1 slots, but its live data reports in the
        /// field matching its handedness (left unit → first stick field,
        /// right unit → second).
        var hasSecondStick: Bool { self == .proController2 || self == .nsoGameCube }

        /// The GameCube pad has no HD-rumble actuator (writing its motor
        /// characteristic powers it off) — it plays built-in presets instead.
        var hasHDRumble: Bool { self != .nsoGameCube }
    }

    // MARK: - GATT characteristics

    enum GATT {
        static let inputReport = UUID(uuidString: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")!
        static let commandWrite = UUID(uuidString: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")!
        static let commandResponse = UUID(uuidString: "C765A961-D9D8-4D36-A20A-5315B111836A")!
        static let vibrationPro = UUID(uuidString: "CC483F51-9258-427D-A939-630C31F72B05")!
        static let vibrationJoyConR = UUID(uuidString: "FA19B0FB-CD1F-46A7-84A1-BBB09E00C149")!
        static let vibrationJoyConL = UUID(uuidString: "289326CB-A471-485D-A8F4-240C14F18241")!
        /// Pro Controller 2's model-specific input report (0x09). Only its
        /// Power Info byte is used; subscribing suspends `inputReport`.
        static let powerReportPro = UUID(uuidString: "7492866C-EC3E-4619-8258-32755FFCC0F8")!

        static func vibration(for model: Model) -> UUID {
            switch model {
            case .joyCon2Left: return vibrationJoyConL
            case .joyCon2Right: return vibrationJoyConR
            default: return vibrationPro  // Pro 2 and GameCube share it
            }
        }
    }

    // MARK: - Commands

    enum Command {
        static let memory: UInt8 = 0x02
        static let leds: UInt8 = 0x09
        static let vibration: UInt8 = 0x0A
        static let feature: UInt8 = 0x0C
        static let pair: UInt8 = 0x15
    }

    enum Subcommand {
        static let memoryRead: UInt8 = 0x04
        static let ledsSetPlayer: UInt8 = 0x07
        static let vibrationPlayPreset: UInt8 = 0x02
        static let featureInit: UInt8 = 0x02
        static let featureEnable: UInt8 = 0x04
        static let pairSetMAC: UInt8 = 0x01
        static let pairLTK1: UInt8 = 0x04
        static let pairLTK2: UInt8 = 0x02
        static let pairFinish: UInt8 = 0x03
    }

    enum Feature {
        static let motion: UInt8 = 0x04
        static let mouse: UInt8 = 0x10       // optical sensor, Joy-Con 2 only
        static let battery: UInt8 = 0x20     // battery current field
        static let magnetometer: UInt8 = 0x80
        /// Base flags the console always sets alongside motion.
        static let baseline: UInt8 = 0x03

        /// Flags we enable per model. (0xFF causes phantom ZL/ZR on
        /// Joy-Cons per Switch2Connect; mouse bit is Joy-Con-only.)
        static func flags(for model: Model) -> UInt8 {
            switch model {
            case .joyCon2Left, .joyCon2Right:
                return baseline | motion | mouse | battery | magnetometer   // 0xB7
            default:
                return baseline | motion | battery | magnetometer           // 0xA7
            }
        }
    }

    /// Fixed LTK halves the protocol expects during bonding (each prefixed
    /// with 0x00). The controller stores host MAC + this key so a button
    /// press wakes it advertising toward that host.
    static let pairLTK1 = Data([0x00, 0xEA, 0xBD, 0x47, 0x13, 0x89, 0x35, 0x42,
                                0xC6, 0x79, 0xEE, 0x07, 0xF2, 0x53, 0x2C, 0x6C, 0x31])
    static let pairLTK2 = Data([0x00, 0x40, 0xB0, 0x8A, 0x5F, 0xCD, 0x1F, 0x9B,
                                0x41, 0x12, 0x5C, 0xAC, 0xC6, 0x3F, 0x38, 0xA0, 0x73])

    // MARK: - Memory map

    enum Address {
        static let controllerInfo: UInt32 = 0x0001_3000
        static let factoryStick1: UInt32 = 0x0001_30A8
        static let factoryStick2: UInt32 = 0x0001_30E8
        static let userStick1: UInt32 = 0x001F_C042
        static let userStick2: UInt32 = 0x001F_C062
        static let gcTriggers: UInt32 = 0x0001_3140
    }

    /// Player-LED bit patterns matching the console, players 1-8.
    static let ledPatterns: [UInt8] = [0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06]

    // MARK: - Buttons (32-bit LE bitmask, report bytes 4..8)

    struct Buttons: OptionSet, Sendable {
        let rawValue: UInt32
        static let y = Buttons(rawValue: 0x0000_0001)
        static let x = Buttons(rawValue: 0x0000_0002)
        static let b = Buttons(rawValue: 0x0000_0004)
        static let a = Buttons(rawValue: 0x0000_0008)
        static let srR = Buttons(rawValue: 0x0000_0010)
        static let slR = Buttons(rawValue: 0x0000_0020)
        static let r = Buttons(rawValue: 0x0000_0040)
        static let zr = Buttons(rawValue: 0x0000_0080)
        static let minus = Buttons(rawValue: 0x0000_0100)
        static let plus = Buttons(rawValue: 0x0000_0200)
        static let rStick = Buttons(rawValue: 0x0000_0400)
        static let lStick = Buttons(rawValue: 0x0000_0800)
        static let home = Buttons(rawValue: 0x0000_1000)
        static let capture = Buttons(rawValue: 0x0000_2000)
        static let c = Buttons(rawValue: 0x0000_4000)
        static let dpadDown = Buttons(rawValue: 0x0001_0000)
        static let dpadUp = Buttons(rawValue: 0x0002_0000)
        static let dpadRight = Buttons(rawValue: 0x0004_0000)
        static let dpadLeft = Buttons(rawValue: 0x0008_0000)
        static let srL = Buttons(rawValue: 0x0010_0000)
        static let slL = Buttons(rawValue: 0x0020_0000)
        static let l = Buttons(rawValue: 0x0040_0000)
        static let zl = Buttons(rawValue: 0x0080_0000)
        static let gr = Buttons(rawValue: 0x0100_0000)
        static let gl = Buttons(rawValue: 0x0200_0000)
    }

    /// Stable names for every remappable control, in UI display order.
    /// ZL/ZR are bits like everything else (digital triggers derive from
    /// them), so button remapping covers them naturally.
    static let namedButtons: [(name: String, button: Buttons)] = [
        ("A", .a), ("B", .b), ("X", .x), ("Y", .y),
        ("D-pad Up", .dpadUp), ("D-pad Down", .dpadDown),
        ("D-pad Left", .dpadLeft), ("D-pad Right", .dpadRight),
        ("L", .l), ("R", .r), ("ZL", .zl), ("ZR", .zr),
        ("Minus", .minus), ("Plus", .plus),
        ("Home", .home), ("Capture", .capture), ("C", .c),
        ("L-stick click", .lStick), ("R-stick click", .rStick),
        ("GL", .gl), ("GR", .gr),
        ("SL (left unit)", .slL), ("SR (left unit)", .srL),
        ("SL (right unit)", .slR), ("SR (right unit)", .srR),
    ]

    static func button(named name: String) -> Buttons? {
        namedButtons.first { $0.name == name }?.button
    }

    // MARK: - Helpers

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() {
            v = v << 8 | UInt32(data[data.startIndex + offset + i])
        }
        return v
    }

    static func s16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }

    /// Decode 3 packed bytes into two 12-bit (0...4095) stick axis values.
    static func stickXY(_ data: Data, _ offset: Int) -> (UInt16, UInt16) {
        guard data.count >= offset + 3 else { return (2048, 2048) }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let value = b0 | b1 << 8 | b2 << 16
        return (UInt16(value & 0xFFF), UInt16(value >> 12))
    }

    /// Frame a controller command (the shared 0x91 protocol).
    /// Frame a command. `flag` is header byte 2 — 0x01 in all sniffed
    /// Bluetooth traffic (the default); NFC captures over USB show 0x00,
    /// so experiments can override it to replicate console traffic exactly.
    static func buildCommand(_ command: UInt8, _ subcommand: UInt8,
                             flag: UInt8 = 0x01,
                             data: Data = Data()) -> Data {
        var buf = Data([command, 0x91, flag, subcommand, 0x00,
                        UInt8(data.count), 0x00, 0x00])
        buf.append(data)
        return buf
    }

    /// Payload for a memory read (max 0x4F bytes per read).
    static func memoryReadPayload(length: UInt8, address: UInt32) -> Data {
        var buf = Data([length, 0x7E, 0x00, 0x00])
        withUnsafeBytes(of: address.littleEndian) { buf.append(contentsOf: $0) }
        return buf
    }

    // MARK: - Power info

    /// Power Info byte (offset 1 of the model-specific input report): the
    /// firmware's own battery estimate, the one the console displays.
    /// Bits: [0] external power, [1] charging, [2:5] level.
    struct PowerInfo: Sendable, Equatable {
        let raw: UInt8
        let externalPower: Bool
        let charging: Bool
        /// ndeadly documents 0-9; a fully charged Pro Controller 2 reports 8,
        /// unplugged or on the charger.
        let level: UInt8

        static let fullLevel: UInt8 = 8

        init(_ byte: UInt8) {
            raw = byte
            externalPower = byte & 0x01 != 0
            charging = byte & 0x02 != 0
            level = (byte >> 2) & 0x0F
        }

        var percent: Int {
            min(100, Int(level) * 100 / Int(Self.fullLevel))
        }
    }

    // MARK: - Advertisement parsing

    /// Parse Nintendo manufacturer data (without the company-id prefix, as
    /// CoreBluetooth delivers it keyed by company id... note: CoreBluetooth
    /// actually delivers the FULL manufacturer blob including the 2-byte
    /// company id; callers must strip it first).
    /// Returns nil unless this is a supported Switch 2 controller.
    struct AdvertisementInfo {
        let model: Model
        /// Host MAC the controller will wake for (big-endian integer);
        /// 0 means pairing mode (Sync held).
        let reconnectHost: UInt64
        var isPairing: Bool { reconnectHost == 0 }
    }

    static func parseAdvertisement(manufacturerData manu: Data) -> AdvertisementInfo? {
        // Layout (after 2-byte company id): [0]... vid @3..5, pid @5..7,
        // reconnect host MAC @10..16 — matching the Python bridge offsets
        // into the post-company-id payload.
        guard manu.count >= 16 else { return nil }
        let vid = u16(manu, 3)
        let pid = u16(manu, 5)
        guard vid == nintendoVendorID, let model = Model(rawValue: pid) else {
            return nil
        }
        var host: UInt64 = 0
        for i in 0..<6 {  // bytes 10..16, little-endian per protocol decodeu
            host |= UInt64(manu[manu.startIndex + 10 + i]) << (8 * i)
        }
        return AdvertisementInfo(model: model, reconnectHost: host)
    }

    // MARK: - Controller info block

    struct ControllerInfo: Sendable {
        let serialNumber: String
        let vendorID: UInt16
        let productID: UInt16
        /// Body and button colors (RGB), when present in the info block.
        let bodyColor: (UInt8, UInt8, UInt8)
        let buttonColor: (UInt8, UInt8, UInt8)

        var model: Model? { Model(rawValue: productID) }

        init?(memoryBlock data: Data) {
            guard data.count >= 0x25 else { return nil }
            let serialBytes = data.subdata(in: data.startIndex + 2 ..< data.startIndex + 16)
            serialNumber = String(bytes: serialBytes.prefix(while: { $0 != 0 }),
                                  encoding: .utf8) ?? "?"
            vendorID = Switch2.u16(data, 18)
            productID = Switch2.u16(data, 20)
            func rgb(_ o: Int) -> (UInt8, UInt8, UInt8) {
                let s = data.startIndex
                guard data.count > o + 2 else { return (128, 128, 128) }
                return (data[s + o], data[s + o + 1], data[s + o + 2])
            }
            bodyColor = rgb(0x19)     // colors[0] per protocol map (25..28)
            buttonColor = rgb(0x1C)   // colors[1] (28..31)
        }
    }

    // MARK: - Stick calibration

    struct StickCalibration: Sendable {
        let center: (x: Double, y: Double)
        let maxRange: (x: Double, y: Double)
        let minRange: (x: Double, y: Double)

        init(data: Data) {
            let c = Switch2.stickXY(data, 0)
            let mx = Switch2.stickXY(data, 3)
            let mn = Switch2.stickXY(data, 6)
            center = (Double(c.0), Double(c.1))
            maxRange = (Double(mx.0), Double(mx.1))
            minRange = (Double(mn.0), Double(mn.1))
        }

        /// Map a raw stick pair to -1...1 per axis, with deadzone.
        func apply(_ raw: (UInt16, UInt16), deadzone: Double = 0) -> (Double, Double) {
            func axis(_ value: Double, _ center: Double,
                      _ maxAbs: Double, _ minAbs: Double) -> Double {
                let signed = value - center
                if signed > deadzone {
                    return maxAbs > 0 ? min(signed / maxAbs, 1) : 0
                }
                if signed < -deadzone {
                    return minAbs > 0 ? -min(-signed / minAbs, 1) : 0
                }
                return 0
            }
            return (axis(Double(raw.0), center.x, maxRange.x, minRange.x),
                    axis(Double(raw.1), center.y, maxRange.y, minRange.y))
        }

        /// The user-calibration slots read 0xFFFFFF when empty.
        static func isBlank(_ data: Data) -> Bool {
            data.count >= 3 && data.prefix(3).allSatisfy { $0 == 0xFF }
        }
    }

    // MARK: - Input report (63-byte notification)

    struct InputReport: Sendable {
        let timestamp: UInt32
        let buttons: Buttons
        let leftStickRaw: (UInt16, UInt16)
        let rightStickRaw: (UInt16, UInt16)
        let batteryMillivolts: UInt16
        let gyro: (Int16, Int16, Int16)
        let accel: (Int16, Int16, Int16)
        let leftTriggerRaw: UInt8
        let rightTriggerRaw: UInt8
        /// Optical mouse (Joy-Con 2, feature 0x10): free-running absolute
        /// counters that wrap mod 2^16 — diff consecutive reports for deltas.
        let mouseX: UInt16
        let mouseY: UInt16
        /// Surface quality; low = good tracking (ndeadly: "roughness").
        let surfaceQuality: UInt16
        /// Lift-off distance; 0 = no surface reference.
        let liftDistance: UInt16
        /// Magnetometer (feature 0x80): AK09919, 0.15 µT/LSB.
        let mag: (Int16, Int16, Int16)
        /// Charge state byte (@0x21) and battery current (@0x22, feature
        /// 0x20; signed — positive while charging).
        let chargeState: UInt8
        let batteryCurrent: Int16
        /// IMU die temperature (@0x2E): °C ≈ 25 + raw/127 (Switch2Connect).
        let temperatureRaw: Int16

        init?(data: Data) {
            guard data.count >= 0x3C else { return nil }
            timestamp = Switch2.u32(data, 0)
            buttons = Buttons(rawValue: Switch2.u32(data, 4))
            leftStickRaw = Switch2.stickXY(data, 10)
            rightStickRaw = Switch2.stickXY(data, 13)
            mouseX = Switch2.u16(data, 0x10)
            mouseY = Switch2.u16(data, 0x12)
            surfaceQuality = Switch2.u16(data, 0x14)
            liftDistance = Switch2.u16(data, 0x16)
            mag = (Switch2.s16(data, 0x19), Switch2.s16(data, 0x1B), Switch2.s16(data, 0x1D))
            batteryMillivolts = Switch2.u16(data, 0x1F)
            chargeState = data.count > 0x21 ? data[data.startIndex + 0x21] : 0
            batteryCurrent = Switch2.s16(data, 0x22)
            temperatureRaw = Switch2.s16(data, 0x2E)
            gyro = (Switch2.s16(data, 0x36), Switch2.s16(data, 0x38), Switch2.s16(data, 0x3A))
            accel = (Switch2.s16(data, 0x30), Switch2.s16(data, 0x32), Switch2.s16(data, 0x34))
            leftTriggerRaw = data.count > 0x3C ? data[data.startIndex + 0x3C] : 0
            rightTriggerRaw = data.count > 0x3D ? data[data.startIndex + 0x3D] : 0
        }
    }

    // MARK: - HD rumble

    /// One HD-rumble waveform sample (packed 5-byte little-endian field).
    struct Vibration: Sendable {
        var lfFreq: UInt16 = 0x0E1
        var lfAmp: UInt16 = 0
        var hfFreq: UInt16 = 0x1E1
        var hfAmp: UInt16 = 0

        /// Resonant low band; drive amplitude only (tuning from the bridge).
        static func waveform(strong: Double, weak: Double) -> Vibration {
            let mag = min(1.0, max(0, strong) + max(0, weak) * 0.5)
            return Vibration(lfFreq: 0x0E1, lfAmp: UInt16(mag * Double(0x3FF)))
        }

        /// A pure tone on the low band of the voice-coil actuator.
        ///
        /// The 9-bit frequency field carries direct Hz (cross-checked with
        /// console USB captures: the idle frame E1 00 10 1E 00 encodes
        /// 225 Hz, and live console traffic shows values like 406/499 Hz),
        /// so the playable range is 1...511 Hz — about the two octaves
        /// around middle C. `amp` maps 0...1 onto the 10-bit amplitude.
        static func tone(freqHz: Int, amp: Double) -> Vibration {
            Vibration(lfFreq: UInt16(min(511, max(1, freqHz))),
                      lfAmp: UInt16(min(1.0, max(0, amp)) * Double(0x3FF)))
        }

        func packed() -> Data {
            var v: UInt64 = 0
            v |= UInt64(lfFreq & 0x1FF)
            v |= UInt64(lfAmp & 0x3FF) << 10
            v |= UInt64(hfFreq & 0x1FF) << 20
            v |= UInt64(hfAmp & 0x3FF) << 30
            var buf = Data()
            withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0.prefix(5)) }
            return buf
        }
    }

    /// Build one motor packet: three identical sub-frame samples per block so
    /// the actuator runs continuously; Pro takes two blocks (L+R motors).
    static func motorPacket(_ vib: Vibration, packetID: UInt8, model: Model) -> Data {
        let header = Data([0x50 + (packetID & 0x0F)])
        let sample = vib.packed()
        var block = header
        block.append(sample); block.append(sample); block.append(sample)
        var payload = Data([0x00])
        payload.append(block)
        if model == .proController2 { payload.append(block) }
        return payload
    }
}
