// SensorDashboard.swift
// The "hidden sensors" panel: exposes readings no other controller software
// surfaces — IMU die temperature and the battery's live voltage / charge
// current — with a rolling voltage sparkline and an estimated runtime.

import SwiftUI

struct SensorDashboard: View {
    let state: ControllerState?
    let serial: String

    @StateObject private var history = SensorHistory()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Gauge(title: "Temperature",
                      value: state.map { String(format: "%.1f °C", $0.temperatureC) } ?? "—",
                      warn: (state?.temperatureC ?? 0) > 40,
                      systemImage: "thermometer")
                Gauge(title: "Voltage",
                      value: state.map { String(format: "%.2f V", Double($0.batteryMillivolts) / 1000) } ?? "—",
                      warn: false, systemImage: "bolt")
                Gauge(title: chargeTitle,
                      value: currentText,
                      warn: false, systemImage: chargeIcon)
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voltage trend").font(.caption2).foregroundStyle(.tertiary)
                    Sparkline(values: history.voltages)
                        .frame(width: 200, height: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated runtime").font(.caption2).foregroundStyle(.tertiary)
                    Text(history.runtimeEstimate)
                        .font(.system(.body, design: .rounded).bold())
                }
            }
        }
        .onChange(of: sampleKey) { _, _ in
            if let s = state { history.record(s) }
        }
    }

    private var sampleKey: String {
        guard let s = state else { return "-" }
        return "\(s.batteryMillivolts),\(Int(s.temperatureC * 10)),\(s.batteryCurrent)"
    }

    private var isCharging: Bool {
        state?.powerInfo?.charging ?? ((state?.batteryCurrent ?? 0) > 20)
    }

    private var chargeTitle: String { isCharging ? "Charging" : "Current" }
    private var chargeIcon: String { isCharging ? "battery.100.bolt" : "minus.plus.batteryblock" }

    private var currentText: String {
        guard let c = state?.batteryCurrent else { return "—" }
        // Raw units are device-specific; show sign + magnitude as an index.
        return isCharging ? "+\(c)" : "\(c)"
    }
}

/// Rolling sensor history for the sparkline and runtime estimate.
@MainActor
final class SensorHistory: ObservableObject {
    @Published private(set) var voltages: [Double] = []
    @Published private(set) var runtimeEstimate = "measuring…"

    private var lastSampleAt = Date.distantPast
    private var firstSample: (date: Date, mv: Double)?
    private static let maxPoints = 120

    func record(_ state: ControllerState) {
        // One sample per ~2 s keeps the trend readable over a session.
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) > 2 else { return }
        lastSampleAt = now

        let mv = Double(state.batteryMillivolts)
        guard mv > 0 else { return }
        voltages.append(mv)
        if voltages.count > Self.maxPoints { voltages.removeFirst() }

        if firstSample == nil { firstSample = (now, mv) }
        estimateRuntime(now: now, current: mv,
                        charging: state.powerInfo?.charging ?? (state.batteryCurrent > 20))
    }

    private func estimateRuntime(now: Date, current mv: Double, charging: Bool) {
        guard let first = firstSample else { return }
        let elapsed = now.timeIntervalSince(first.date)
        let drop = first.mv - mv            // discharge: positive
        guard elapsed > 60 else { runtimeEstimate = "measuring…"; return }
        if charging { runtimeEstimate = "charging"; return }
        guard drop > 5 else { runtimeEstimate = "≈ steady"; return }
        // Linear extrapolation down to 3300 mV (empty).
        let ratePerSec = drop / elapsed
        let remaining = (mv - 3300) / ratePerSec
        guard remaining > 0 else { runtimeEstimate = "low"; return }
        let hours = Int(remaining) / 3600
        let mins = (Int(remaining) % 3600) / 60
        runtimeEstimate = hours > 0 ? "≈ \(hours)h \(mins)m" : "≈ \(mins)m"
    }
}

private struct Gauge: View {
    let title: String
    let value: String
    let warn: Bool
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(warn ? .orange : .primary)
        }
        .frame(minWidth: 90, alignment: .leading)
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 1)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                Text("collecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
