// Run on a Mac with:
// swiftc Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift \
//   Sources/FinallyTheControllerWorks/Output/VirtualHIDReport.swift \
//   Tests/manual/VirtualHIDReportCheck.swift -o /tmp/VirtualHIDReportCheck
// /tmp/VirtualHIDReportCheck

import Foundation

@main
struct VirtualHIDReportCheck {
    static func main() {
        let report = VirtualHIDReport.encode(
            buttons: [.zr, .zl], leftStick: (0, 0), rightStick: (0, 0),
            leftTrigger: 63, rightTrigger: 127)
        precondition(report.count == 14)
        precondition(report[2] & 0x18 == 0x18)  // Z and ZL
        precondition(report[1] & 0x04 == 0)     // R stays separate
        precondition(report[11] == 63 && report[12] == 127)

        let rReport = VirtualHIDReport.encode(
            buttons: [.r], leftStick: (0, 0), rightStick: (0, 0),
            leftTrigger: 0, rightTrigger: 0)
        precondition(rReport[2] & 0x18 == 0)
        precondition(rReport[1] & 0x04 == 0x04)

        let rumbleOn = Switch2.buildCommand(
            Switch2.Command.vibration, Switch2.Subcommand.vibrationPlayPreset,
            data: Data([1, 0, 0, 0]))
        let rumbleOff = Switch2.buildCommand(
            Switch2.Command.vibration, Switch2.Subcommand.vibrationPlayPreset,
            data: Data([0, 0, 0, 0]))
        precondition(rumbleOn == Data([
            0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00]))
        precondition(rumbleOff[8] == 0x00)
        print("Virtual HID button/trigger and rumble command checks passed")
    }
}
