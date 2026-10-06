// InputVisualizer.swift
// Live input test pad, laid out to match the physical hardware:
//  * Pro Controller 2 / pair in grip: left stick high-left, d-pad low-left,
//    A/B/X/Y diamond high-right, right stick low-center-right, system
//    buttons in the middle.
//  * Single left Joy-Con (upright): stick above d-pad, minus top, capture low.
//  * Single right Joy-Con (upright): diamond above stick, plus top, Home/C low.
//  * Pair held independently: the two upright Joy-Con panels side by side.
// Fed by BridgeEngine.liveStates at ~10 Hz.

import SwiftUI

enum VizLayout {
    case pro            // Pro Controller 2, or linked pair in the grip
    case gameCube
    case joyConLeft
    case joyConRight
    case pairIndependent
}

struct InputVisualizer: View {
    let state: ControllerState?
    var layout: VizLayout = .pro

    var body: some View {
        switch layout {
        case .pro:
            proBody
        case .gameCube:
            gameCubeBody
        case .joyConLeft:
            JoyConLeftPanel(state: state)
        case .joyConRight:
            JoyConRightPanel(state: state)
        case .pairIndependent:
            HStack(alignment: .top, spacing: 28) {
                JoyConLeftPanel(state: state)
                JoyConRightPanel(state: state)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Pro Controller 2 arrangement (traced from the hardware photo).
    private var proBody: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                TriggerBar(label: "ZL", value: state?.leftTrigger ?? 0)
                Chip("L", .l, state)
                StickDot(label: "L", stick: state?.leftStick,
                         pressed: pressed(.lStick, state))
                DpadDiamond(state: state)
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Chip("Cap", .capture, state)
                    Chip("−", .minus, state)
                    Chip("+", .plus, state)
                    Chip("Home", .home, state)
                }
                Spacer().frame(height: 18)
                Chip("C", .c, state)
                Spacer().frame(height: 4)
                HStack(spacing: 8) {
                    Chip("GL", .gl, state)
                    Chip("GR", .gr, state)
                }
            }
            .padding(.top, 26)
            VStack(spacing: 10) {
                TriggerBar(label: "ZR", value: state?.rightTrigger ?? 0)
                Chip("R", .r, state)
                FaceDiamond(state: state)
                StickDot(label: "R", stick: state?.rightStick,
                         pressed: pressed(.rStick, state))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// The GameCube pad has analog L/R triggers plus separate ZL/Z buttons.
    private var gameCubeBody: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                TriggerBar(label: "L", value: state?.leftTrigger ?? 0)
                Chip("ZL", .zl, state)
                Chip("L click", .l, state)
                StickDot(label: "L", stick: state?.leftStick,
                         pressed: pressed(.lStick, state))
                DpadDiamond(state: state)
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Chip("Cap", .capture, state)
                    Chip("−", .minus, state)
                    Chip("+", .plus, state)
                    Chip("Home", .home, state)
                }
                Spacer().frame(height: 18)
            }
            .padding(.top, 26)
            VStack(spacing: 10) {
                TriggerBar(label: "R", value: state?.rightTrigger ?? 0)
                Chip("Z", .zr, state)
                Chip("R click", .r, state)
                FaceDiamond(state: state)
                StickDot(label: "C", stick: state?.rightStick,
                         pressed: pressed(.rStick, state))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Joy-Con panels (upright orientation, per the reference diagram)

private struct JoyConLeftPanel: View {
    let state: ControllerState?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TriggerBar(label: "ZL", value: state?.leftTrigger ?? 0)
                Chip("L", .l, state)
            }
            HStack {
                Spacer()
                Chip("−", .minus, state)
            }
            .frame(width: 120)
            StickDot(label: "", stick: state?.leftStick,
                     pressed: pressed(.lStick, state))
            DpadDiamond(state: state)
            HStack(spacing: 8) {
                Chip("SL", .slL, state)
                Chip("SR", .srL, state)
            }
            HStack {
                Chip("Cap", .capture, state)
                Spacer()
            }
            .frame(width: 120)
        }
    }
}

private struct JoyConRightPanel: View {
    let state: ControllerState?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip("R", .r, state)
                TriggerBar(label: "ZR", value: state?.rightTrigger ?? 0)
            }
            HStack {
                Chip("+", .plus, state)
                Spacer()
            }
            .frame(width: 120)
            FaceDiamond(state: state)
            StickDot(label: "", stick: state?.rightStick,
                     pressed: pressed(.rStick, state))
            HStack(spacing: 8) {
                Chip("SL", .slR, state)
                Chip("SR", .srR, state)
            }
            HStack {
                Spacer()
                Chip("Home", .home, state)
                Chip("C", .c, state)
            }
            .frame(width: 120)
        }
    }
}

// MARK: - Shared parts

private func pressed(_ button: Switch2.Buttons, _ state: ControllerState?) -> Bool {
    state?.buttons.contains(button) ?? false
}

/// Nintendo face diamond: X top, Y left, A right, B bottom.
private struct FaceDiamond: View {
    let state: ControllerState?

    var body: some View {
        ZStack {
            Chip("X", .x, state).offset(y: -24)
            Chip("Y", .y, state).offset(x: -26)
            Chip("A", .a, state).offset(x: 26)
            Chip("B", .b, state).offset(y: 24)
        }
        .frame(width: 84, height: 72)
    }
}

/// D-pad diamond: up top, left left, right right, down bottom.
private struct DpadDiamond: View {
    let state: ControllerState?

    var body: some View {
        ZStack {
            Chip("▲", .dpadUp, state).offset(y: -24)
            Chip("◀", .dpadLeft, state).offset(x: -26)
            Chip("▶", .dpadRight, state).offset(x: 26)
            Chip("▼", .dpadDown, state).offset(y: 24)
        }
        .frame(width: 84, height: 72)
    }
}

private struct Chip: View {
    let label: String
    let mask: Switch2.Buttons
    let state: ControllerState?

    init(_ label: String, _ mask: Switch2.Buttons, _ state: ControllerState?) {
        self.label = label
        self.mask = mask
        self.state = state
    }

    private var isOn: Bool { pressed(mask, state) }

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .rounded).bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Color.accentColor : Color.gray.opacity(0.2)))
            .foregroundStyle(isOn ? .white : .secondary)
    }
}

private struct StickDot: View {
    let label: String
    let stick: (x: Double, y: Double)?
    let pressed: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(pressed ? Color.accentColor : .secondary.opacity(0.4),
                              lineWidth: pressed ? 2 : 1)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                // SwiftUI y grows downward; stick y is up-positive.
                .offset(x: (stick?.x ?? 0) * 24, y: -(stick?.y ?? 0) * 24)
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
    }
}

private struct TriggerBar: View {
    let label: String
    let value: UInt8

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(value) / 255)
                }
            }
            .frame(height: 8)
        }
        .frame(width: 90)
    }
}
