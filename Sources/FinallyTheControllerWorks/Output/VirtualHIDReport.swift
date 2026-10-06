// The 14-byte input report shared by the virtual HID descriptor and its
// source-side checks. This encoder has no CoreHID dependency.

import Foundation

enum VirtualHIDReport {
    static func encode(buttons: Switch2.Buttons,
                       leftStick: (x: Double, y: Double),
                       rightStick: (x: Double, y: Double),
                       leftTrigger: UInt8,
                       rightTrigger: UInt8) -> Data {
        var bits: UInt32 = 0
        func set(_ index: Int, _ on: Bool) { if on { bits |= 1 << index } }
        set(0, buttons.contains(.b)); set(1, buttons.contains(.a))
        set(2, buttons.contains(.y)); set(3, buttons.contains(.x))
        set(4, buttons.contains(.minus)); set(5, buttons.contains(.home))
        set(6, buttons.contains(.plus)); set(7, buttons.contains(.lStick))
        set(8, buttons.contains(.rStick)); set(9, buttons.contains(.l))
        set(10, buttons.contains(.r)); set(15, buttons.contains(.capture))
        set(16, buttons.contains(.gr)); set(17, buttons.contains(.gl))
        set(18, buttons.contains(.c)); set(19, buttons.contains(.zr))
        set(20, buttons.contains(.zl))

        func axis(_ v: Double) -> Int16 {
            Int16(max(-32768, min(32767, v * 32767)))
        }

        var report = Data(capacity: 14)
        report.append(UInt8(bits & 0xFF))
        report.append(UInt8((bits >> 8) & 0xFF))
        report.append(UInt8((bits >> 16) & 0xFF))
        for value in [axis(leftStick.x), axis(-leftStick.y),
                      axis(rightStick.x), axis(-rightStick.y)] {
            withUnsafeBytes(of: value.littleEndian) { report.append(contentsOf: $0) }
        }
        report.append(leftTrigger)
        report.append(rightTrigger)
        report.append(hatValue(buttons))
        return report
    }

    /// Hat: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW, 8=released.
    private static func hatValue(_ buttons: Switch2.Buttons) -> UInt8 {
        let up = buttons.contains(.dpadUp), down = buttons.contains(.dpadDown)
        let left = buttons.contains(.dpadLeft), right = buttons.contains(.dpadRight)
        switch (up, right, down, left) {
        case (true, false, false, false): return 0
        case (true, true, false, false): return 1
        case (false, true, false, false): return 2
        case (false, true, true, false): return 3
        case (false, false, true, false): return 4
        case (false, false, true, true): return 5
        case (false, false, false, true): return 6
        case (true, false, false, true): return 7
        default: return 8
        }
    }
}
