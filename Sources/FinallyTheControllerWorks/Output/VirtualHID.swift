// VirtualHID.swift
// The system-wide sink: one CoreHID virtual gamepad per connected controller.
// With this active, ANY app on the Mac — unaltered Gopher64, Steam, ports —
// sees a normal HID gamepad. Requires the com.apple.developer.hid.virtual.device
// entitlement (Apple Developer provisioning); without it, device creation
// fails and we say so once — the UDP/SDL path still works.
//
// Report layout (14 bytes, must match `gamepadDescriptor`):
//   bytes 0-2: 21 buttons (bit i = button i in our fixed order) + 3 pad bits
//   bytes 3-10: X, Y, Z, Rz as signed 16-bit LE (sticks)
//   bytes 11-12: Rx, Ry as unsigned 8-bit (triggers)
//   byte 13: hat switch in low nibble (0-7 clockwise from north, 8 = null)
//
// Button order matches the SDL driver for consistency:
//   0=B 1=A 2=Y 3=X 4=MINUS 5=HOME 6=PLUS 7=LSTICK 8=RSTICK 9=L 10=R
//   11..14 unused here (d-pad goes to the hat) 15=CAPTURE 16=GR 17=GL 18=C
//   19=ZR (the NSO GameCube pad's physical Z button) 20=ZL
//
// Rumble: generic HID gamepads have no standardized output-report rumble on
// macOS, so this sink does not carry rumble; the UDP/SDL path does.

import Foundation
import CoreHID

final class VirtualHIDSink: ControllerOutputSink, @unchecked Sendable {

    var onRumble: ((Int, Double, Double) -> Void)?

    private let queue = DispatchQueue(label: "com.petersharma.ftcw.virtualhid")
    private var devices: [Int: HIDVirtualDevice] = [:]

    /// Slots with a live controller, so a retry never publishes a gamepad for
    /// a controller that walked away in the meantime.
    private var activeSlots: Set<Int> = []

    /// macOS registers an app's embedded provisioning profile lazily: the
    /// very first launch of a freshly installed build can be refused
    /// (IOServiceOpen → kIOReturnNotPermitted) with the entitlement fully in
    /// place, and then succeed seconds later. Observed on the first run of
    /// every newly signed build. So retry instead of concluding the
    /// entitlement is missing, and never latch that conclusion — one early
    /// refusal must not cost the whole session.
    private var attempts = 0
    private var warnedAboutEntitlement = false
    private static let maxAttempts = 4
    private static let retryDelay = DispatchTimeInterval.milliseconds(1500)

    /// Generic gamepad: 21 buttons, two 16-bit stick pairs, two 8-bit
    /// triggers, one hat. Mirrors the probe descriptor that validated the
    /// entitlement path, extended to 21 buttons.
    private static let gamepadDescriptor = Data([
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)
        0x05, 0x09,        //   Usage Page (Button)
        0x19, 0x01,        //   Usage Minimum (1)
        0x29, 0x15,        //   Usage Maximum (21)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x15,        //   Report Count (21)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x75, 0x01,        //   Report Size (1) — pad to 24 bits
        0x95, 0x03,        //   Report Count (3)
        0x81, 0x03,        //   Input (Const)
        0x05, 0x01,        //   Usage Page (Generic Desktop)
        0x09, 0x30,        //   Usage (X)
        0x09, 0x31,        //   Usage (Y)
        0x09, 0x32,        //   Usage (Z)
        0x09, 0x35,        //   Usage (Rz)
        0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
        0x75, 0x10,        //   Report Size (16)
        0x95, 0x04,        //   Report Count (4)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x09, 0x33,        //   Usage (Rx)
        0x09, 0x34,        //   Usage (Ry)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x00,  //   Logical Maximum (255)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x02,        //   Report Count (2)
        0x81, 0x02,        //   Input (Data,Var,Abs)
        0x09, 0x39,        //   Usage (Hat switch)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x07,        //   Logical Maximum (7)
        0x35, 0x00,        //   Physical Minimum (0)
        0x46, 0x3B, 0x01,  //   Physical Maximum (315)
        0x65, 0x14,        //   Unit (Eng Rot: degrees)
        0x75, 0x04,        //   Report Size (4)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x42,        //   Input (Data,Var,Abs,Null)
        0x75, 0x04,        //   Report Size (4) — pad nibble
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x03,        //   Input (Const)
        0xC0               // End Collection
    ])

    // MARK: ControllerOutputSink (called on the Bluetooth queue)

    func controllerConnected(slot: Int, model: Switch2.Model) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeSlots.insert(slot)
            self.attempts = 0          // a fresh round of tries per connect
            self.createDevice(slot: slot, model: model)
        }
    }

    /// Create the virtual gamepad for a slot, retrying a few times before
    /// deciding the entitlement really is absent. Must run on `queue`.
    private func createDevice(slot: Int, model: Switch2.Model) {
        guard devices[slot] == nil, activeSlots.contains(slot) else { return }
        let props = HIDVirtualDevice.Properties(
            descriptor: Self.gamepadDescriptor,
            vendorID: UInt32(Switch2.nintendoVendorID),
            productID: UInt32(model.rawValue),
            transport: nil,
            product: "\(model.displayName) (Finally)",
            manufacturer: "Finally the Controller Works",
            serialNumber: "FTCW-slot\(slot + 1)",
            uniqueID: "com.petersharma.ftcw.slot\(slot + 1)")
        guard let device = HIDVirtualDevice(properties: props) else {
            attempts += 1
            if attempts < Self.maxAttempts {
                bridgeLog(.info, "virtualhid",
                          "slot \(slot + 1): virtual gamepad refused "
                          + "(attempt \(attempts)); retrying")
                queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                    self?.createDevice(slot: slot, model: model)
                }
            } else if !warnedAboutEntitlement {
                warnedAboutEntitlement = true
                bridgeLog(.warning, "virtualhid",
                          "virtual gamepad creation refused — app is missing the "
                          + "com.apple.developer.hid.virtual.device entitlement. "
                          + "Games will see controllers via the SDL path only.")
            }
            return
        }
        devices[slot] = device
        Task {
            await device.activate(delegate: NullHIDDelegate.shared)
            bridgeLog(.info, "virtualhid",
                      "slot \(slot + 1): system-wide virtual gamepad created")
        }
    }

    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            self?.activeSlots.remove(slot)
            if self?.devices.removeValue(forKey: slot) != nil {
                bridgeLog(.info, "virtualhid", "slot \(slot + 1): virtual gamepad removed")
            }
        }
    }

    /// Virtual devices are named at creation; renames apply on next connect.
    func controllerName(slot: Int, name: String) {}

    func controllerState(slot: Int, state: ControllerState) {
        queue.async { [weak self] in
            guard let self, let device = self.devices[slot] else { return }
            let report = VirtualHIDReport.encode(
                buttons: state.buttons,
                leftStick: state.leftStick,
                rightStick: state.rightStick,
                leftTrigger: state.leftTrigger,
                rightTrigger: state.rightTrigger)
            Task {
                try? await device.dispatchInputReport(data: report,
                                                      timestamp: SuspendingClock.now)
            }
        }
    }

}

/// The controller has no meaningful get/set report handling on the virtual
/// device (rumble travels the UDP path), but CoreHID requires a delegate.
final class NullHIDDelegate: HIDVirtualDeviceDelegate {
    static let shared = NullHIDDelegate()

    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        Data()
    }
}
