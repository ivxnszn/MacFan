import Foundation
import SwiftUI

enum DashboardDetail: Equatable, Identifiable {
    case cpu
    case peak(Date)
    case fans
    case mode
    case insight(String)

    var id: String {
        switch self {
        case .cpu: "cpu"
        case .peak(let timestamp): "peak-\(timestamp.timeIntervalSinceReferenceDate)"
        case .fans: "fans"
        case .mode: "mode"
        case .insight(let id): "insight-\(id)"
        }
    }
}

// MARK: - Overview summary

struct OverviewStatRow: View, Equatable {
    let history: [TelemetrySample]
    let displayTemperature: SensorReading?
    let fans: [FanReading]
    let mode: FanMode
    let rangeTitle: String
    let temperatureUnit: TemperatureUnit
    let thresholdCelsius: Double
    let onSelect: (DashboardDetail) -> Void

    var body: some View {
        let temperatures = history.compactMap(\.displayTemperatureCelsius)
        let secondsAbove = InsightsEngine.secondsAbove(
            thresholdCelsius,
            history: history,
            now: history.last?.timestamp ?? .now
        )
        let currentTemperature = displayTemperature?.celsius
        let currentBand = ThermalPalette.band(for: currentTemperature)
        let delta = history.first?.displayTemperatureCelsius.flatMap { first in
            currentTemperature.map { $0 - first }
        }

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ThermalSummaryCard(
                    temperature: currentTemperature,
                    sensorName: displayTemperature?.name,
                    band: currentBand,
                    delta: delta,
                    values: temperatures,
                    rangeTitle: rangeTitle,
                    unit: temperatureUnit,
                    action: { onSelect(.cpu) }
                )
                .frame(minWidth: 330)
                .layoutPriority(2)

                CoolingSummaryCard(
                    fans: fans,
                    mode: mode,
                    action: { onSelect(.fans) }
                )
                .frame(minWidth: 270)

                ThermalLoadCard(
                    secondsAbove: secondsAbove,
                    thresholdCelsius: thresholdCelsius,
                    rangeTitle: rangeTitle,
                    unit: temperatureUnit,
                    action: { onSelect(.cpu) }
                )
                .frame(minWidth: 230)
            }
            .frame(minWidth: 860)

            VStack(spacing: 12) {
                ThermalSummaryCard(
                    temperature: currentTemperature,
                    sensorName: displayTemperature?.name,
                    band: currentBand,
                    delta: delta,
                    values: temperatures,
                    rangeTitle: rangeTitle,
                    unit: temperatureUnit,
                    action: { onSelect(.cpu) }
                )
                HStack(spacing: 12) {
                    CoolingSummaryCard(fans: fans, mode: mode, action: { onSelect(.fans) })
                    ThermalLoadCard(
                        secondsAbove: secondsAbove,
                        thresholdCelsius: thresholdCelsius,
                        rangeTitle: rangeTitle,
                        unit: temperatureUnit,
                        action: { onSelect(.cpu) }
                    )
                }
            }
        }
    }

    static func == (lhs: OverviewStatRow, rhs: OverviewStatRow) -> Bool {
        lhs.history == rhs.history &&
        lhs.displayTemperature == rhs.displayTemperature &&
        lhs.fans == rhs.fans &&
        lhs.mode == rhs.mode &&
        lhs.rangeTitle == rhs.rangeTitle &&
        lhs.temperatureUnit == rhs.temperatureUnit &&
        lhs.thresholdCelsius == rhs.thresholdCelsius
    }
}

private struct ThermalSummaryCard: View {
    let temperature: Double?
    let sensorName: String?
    let band: ThermalBand
    let delta: Double?
    let values: [Double]
    let rangeTitle: String
    let unit: TemperatureUnit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("CPU temperature", systemImage: "thermometer.medium")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanSecondary)
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(temperature.map { "\(Int(unit.convert($0).rounded()))°" } ?? "—")
                            .macFanDisplayNumber(42)
                            .foregroundStyle(Color.macFanPrimary)
                            .macFanLiveNumberTransition()
                        Text(band.label)
                            .macFanSubhead()
                            .foregroundStyle(band.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(band.color.opacity(0.11), in: Capsule())
                    }
                    HStack(spacing: 6) {
                        Text(sensorName ?? "Waiting for sensor").macFanCallout()
                        if let delta, abs(delta) >= 0.5 {
                            let displayDelta = unit == .celsius ? delta : delta * 9 / 5
                            Text("\(displayDelta > 0 ? "+" : "")\(Int(displayDelta.rounded()))° vs \(rangeTitle)")
                                .macFanChartTick()
                                .foregroundStyle(delta > 0 ? Color.macFanAmberLight : Color.macFanSky)
                        }
                    }
                    .foregroundStyle(Color.macFanSecondary)
                }
                Spacer(minLength: 8)
                if values.count > 1 {
                    Sparkline(values: Array(values.suffix(60)), color: band.color, lineWidth: 1.7, minimumSpan: 5)
                        .frame(minWidth: 150, idealWidth: 220, maxWidth: 260, minHeight: 52, maxHeight: 52)
                } else {
                    Text("Collecting trend")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanMuted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .macFanCard(padding: MacFanMetrics.cardPadding, radius: MacFanMetrics.radiusL, flatten: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacFanPressableStyle())
        .macFanHoverSpecial()
        .help("Inspect CPU temperature details")
        .accessibilityIdentifier("overview-cpu-detail")
    }
}

private struct CoolingSummaryCard: View {
    let fans: [FanReading]
    let mode: FanMode
    let action: () -> Void

    private var averageRPM: Double? {
        fans.isEmpty ? nil : fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
    }

    private var effort: Double {
        fans.isEmpty ? 0 : fans.map(\.normalizedActual).reduce(0, +) / Double(fans.count)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Cooling", systemImage: "fanblades.fill")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanSecondary)
                    Spacer()
                    Text(mode.uiTitle)
                        .macFanSubhead()
                        .foregroundStyle(mode.uiAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(mode.uiAccent.opacity(0.11), in: Capsule())
                }
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text((averageRPM ?? 0) < 1 ? "Idle" : "\(Int((averageRPM ?? 0).rounded()))")
                        .macFanDisplayNumber((averageRPM ?? 0) < 1 ? 30 : 34)
                        .foregroundStyle(Color.macFanPrimary)
                        .macFanLiveNumberTransition()
                    if (averageRPM ?? 0) >= 1 {
                        Text("RPM").macFanCallout().foregroundStyle(Color.macFanSecondary)
                    }
                }
                .animation(.easeOut(duration: 0.22), value: averageRPM ?? 0)
                // Mini effort gauge + purposeful key stat (recap alignment)
                MiniPercentGauge(fraction: effort, tint: .macFanViolet, label: nil, height: 5)
                HStack(spacing: 10) {
                    Text(fans.isEmpty ? "Waiting for fan telemetry" : "\(Int((effort * 100).rounded()))% effort · \(fans.count) fans")
                        .macFanBody()
                        .foregroundStyle(Color.macFanPrimary)
                    if let avg = averageRPM, avg > 10 {
                        RecapMetric(label: "AVG", value: "\(Int(avg)) RPM", tint: .macFanVioletLight)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .macFanCard(padding: MacFanMetrics.cardPadding, radius: MacFanMetrics.radiusL, flatten: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacFanPressableStyle())
        .macFanHoverSpecial()
        .help("Inspect fan and control details")
        .accessibilityIdentifier("overview-fans-detail")
    }
}

/// Live thermal-stress glance: exposure time + actionable context for the selected range.
/// Purposeful recap enhancement: uses RecapMetric + MiniPercentGauge for visual punch,
/// episode-aware hint when possible. Consistent with revamped ThermalBriefCard premium style.
private struct ThermalLoadCard: View {
    let secondsAbove: TimeInterval
    let thresholdCelsius: Double
    let rangeTitle: String
    let unit: TemperatureUnit
    let action: () -> Void

    private var isHot: Bool { secondsAbove >= 1 }
    private var tint: Color { isHot ? .macFanAmber : .macFanMint }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Thermal load", systemImage: isHot ? "flame.fill" : "checkmark.seal.fill")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanSecondary)
                    Spacer()
                    Text(rangeTitle).macFanCallout().foregroundStyle(Color.macFanMuted)
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(isHot ? InsightsEngine.durationText(secondsAbove) : "Clear")
                        .macFanDisplayNumber(34)
                        .foregroundStyle(tint)
                        .macFanLiveNumberTransition()
                    if isHot {
                        RecapMetric(label: "THRESHOLD", value: unit.degreesWithUnit(thresholdCelsius), tint: .macFanAmber)
                    }
                }
                Text(isHot
                     ? "above Smart threshold · \(rangeTitle)"
                     : "below Smart threshold · \(rangeTitle)")
                    .macFanBody()
                    .foregroundStyle(Color.macFanPrimary)

                // Premium MiniPercentGauge (DesignSystem) for purposeful visual recap
                MiniPercentGauge(
                    fraction: min(1.0, max(0, secondsAbove / 1800)),
                    tint: tint,
                    label: nil,
                    height: 6
                )

                HStack {
                    Text("Inspect heat curve").macFanSubhead()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.macFanVioletLight)
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .macFanCard(padding: MacFanMetrics.cardPadding, radius: MacFanMetrics.radiusL, flatten: true)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.22), value: secondsAbove)
        }
        .buttonStyle(MacFanPressableStyle())
        .macFanHoverSpecial()
        .help("Time held above the Smart Boost threshold")
        .accessibilityIdentifier("overview-thermal-load")
    }
}

// MARK: - Range-aware overview insights

struct InlineOverviewInsights: View {
    let history: [TelemetrySample]
    let thresholdCelsius: Double
    let hardwareMaximumRPM: Double
    let temperatureUnit: TemperatureUnit
    let onSelect: (TelemetrySample) -> Void

    private var peak: TelemetrySample? {
        history.max { ($0.displayMaximumTemperatureCelsius ?? -.infinity) < ($1.displayMaximumTemperatureCelsius ?? -.infinity) }
    }

    private var firstHotSample: TelemetrySample? {
        history.first { ($0.displayTemperatureCelsius ?? -.infinity) >= thresholdCelsius }
    }

    private var fanResponse: FanResponseMatch? {
        InsightsEngine.fanResponseMatch(
            history: history,
            hardwareMaximumRPM: hardwareMaximumRPM,
            thresholdCelsius: thresholdCelsius
        )
    }

    var body: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("What changed", systemImage: "sparkles")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text("Selected range")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanMuted)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { insightChips }
                    VStack(spacing: 8) { insightChips }
                }
            }
        }
    }

    @ViewBuilder
    private var insightChips: some View {
        if let peak, let temperature = peak.displayMaximumTemperatureCelsius {
            OverviewInsightChip(
                icon: "thermometer.high",
                title: "Peak \(temperatureUnit.degreesWithUnit(temperature))",
                detail: peak.timestamp.formatted(date: .omitted, time: .shortened),
                tint: ThermalPalette.band(for: temperature).color
            ) { onSelect(peak) }
        }

        let seconds = InsightsEngine.secondsAbove(
            thresholdCelsius,
            history: history,
            now: history.last?.timestamp ?? .now
        )
        OverviewInsightChip(
            icon: seconds > 0 ? "flame.fill" : "checkmark.seal.fill",
            title: seconds > 0 ? "Above Smart for \(InsightsEngine.durationText(seconds))" : "Below Smart threshold",
            detail: "Threshold \(temperatureUnit.degreesWithUnit(thresholdCelsius))",
            tint: seconds > 0 ? .macFanAmber : .macFanMint
        ) {
            if let firstHotSample { onSelect(firstHotSample) }
        }

        if let fanResponse {
            OverviewInsightChip(
                icon: "fanblades.fill",
                title: "Fan response \(InsightsEngine.durationText(fanResponse.seconds))",
                detail: "Reached 90% of maximum",
                tint: .macFanVioletLight
            ) { onSelect(fanResponse.response) }
        } else if firstHotSample != nil {
            OverviewInsightChip(
                icon: "waveform.path.ecg",
                title: "No near-maximum response observed",
                detail: "The elevated episode may have been brief",
                tint: .macFanBlue
            ) { if let sample = history.last { onSelect(sample) } }
        } else {
            OverviewInsightChip(
                icon: "checkmark.seal.fill",
                title: "No elevated episode",
                detail: "CPU stayed below the Smart threshold",
                tint: .macFanMint
            ) { if let sample = history.last { onSelect(sample) } }
        }

        // Data-hacked correlation recap (reused from revamped brief; scannable + actionable)
        let corr = InsightsEngine.responseCorrelationLabel(history: history, hardwareMaximumRPM: hardwareMaximumRPM)
        let corrTint: Color = corr.severity == .warning ? .macFanCoral : (corr.severity == .notice ? .macFanAmber : .macFanSky)
        OverviewInsightChip(
            icon: "link",
            title: corr.label,
            detail: corr.detail,
            tint: corrTint
        ) {
            if let s = history.last { onSelect(s) }
        }
    }
}

private struct OverviewInsightChip: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .macFanSubhead()
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                    Text(detail).macFanCallout().foregroundStyle(Color.macFanSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 0.5) }
        }
        .buttonStyle(MacFanPressableStyle())
        .help("Show this point on the chart")
    }
}

struct SupportingAnalyticsRow: View, Equatable {
    let history: [TelemetrySample]
    let range: HistoryRange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supporting analytics")
                .macFanHeadline()
                .foregroundStyle(Color.macFanPrimary)

            HStack(spacing: MacFanMetrics.spacing) {
                // Thermal band distribution (more chart)
                AnalyticsCard(title: "Thermal bands", content: {
                    BandDistributionView(history: history, range: range)
                })

                // Mode breakdown (more chart)
                AnalyticsCard(title: "Control modes", content: {
                    ModeBreakdownView(history: history, range: range)
                })

                AnalyticsCard(title: "Recorded coverage", content: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int((recordedCoverage * 100).rounded()))% of selected range")
                            .macFanNumber(13, weight: .semibold)
                            .foregroundStyle(Color.macFanPrimary)
                        Text("\(max(history.count - 1, 0)) recorded plot intervals")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                    }
                })
            }
        }
        .padding(.top, MacFanMetrics.spacingS)
    }

    private var recordedCoverage: Double {
        guard range.interval > 0 else { return 0 }
        return min(recordedHistoryDuration(history, range: range) / range.interval, 1)
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .macFanLabel(tracking: 0.3)
                .foregroundStyle(Color.macFanMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macFanCard(padding: 14, radius: 12)
    }
}

private struct BandDistributionView: View {
    let history: [TelemetrySample]
    let range: HistoryRange

    var body: some View {
        let durations = recordedHistoryDurations(
            history,
            range: range,
            exact: \TelemetrySample.thermalBandDurations
        ) { sample in
            sample.displayTemperatureCelsius.map { ThermalPalette.band(for: $0) }
        }
        let total = durations.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach([ThermalBand.cool, .indigo, .violet, .amber, .hot], id: \.self) { band in
                        let fraction = total > 0 ? (durations[band] ?? 0) / total : 0
                        if fraction > 0 {
                            Rectangle()
                                .fill(band.color.opacity(0.85))
                                .frame(width: max(1, proxy.size.width * fraction))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 8) {
                ForEach([ThermalBand.cool, .indigo, .violet, .amber, .hot], id: \.self) { band in
                    let fraction = total > 0 ? (durations[band] ?? 0) / total : 0
                    if fraction >= 0.01 {
                        HStack(spacing: 4) {
                            Circle().fill(band.color).frame(width: 5, height: 5)
                            Text("\(band.label) \(Int((fraction * 100).rounded()))%")
                                .macFanChartTick()
                                .foregroundStyle(Color.macFanSecondary)
                        }
                    }
                }
            }
        }
    }

}

private struct ModeBreakdownView: View {
    let history: [TelemetrySample]
    let range: HistoryRange

    var body: some View {
        let durations = recordedHistoryDurations(
            history,
            range: range,
            exact: \TelemetrySample.modeDurations
        ) { Optional($0.mode) }
        let total = durations.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach([FanMode.system, .smartBoost, .max, .expert], id: \.self) { mode in
                        let fraction = total > 0 ? (durations[mode] ?? 0) / total : 0
                        if fraction > 0 {
                            Rectangle()
                                .fill(mode.uiAccent.opacity(0.82))
                                .frame(width: max(1, proxy.size.width * fraction))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach([FanMode.system, .smartBoost, .max, .expert], id: \.self) { mode in
                    let fraction = total > 0 ? (durations[mode] ?? 0) / total : 0
                    if fraction >= 0.01 {
                        Text("\(mode.uiTitle) \(Int((fraction * 100).rounded()))%")
                            .macFanChartTick()
                            .foregroundStyle(Color.macFanSecondary)
                    }
                }
            }
        }
    }

}

private func recordedHistoryDuration(_ history: [TelemetrySample], range: HistoryRange) -> TimeInterval {
    guard !history.isEmpty else { return 0 }
    var result: TimeInterval = 0
    for (index, sample) in history.enumerated() {
        if let exact = sample.recordedCoverageSeconds {
            result += max(0, exact)
        } else if index + 1 < history.count {
            let inferred = history[index + 1].timestamp.timeIntervalSince(sample.timestamp)
            if inferred > 0, inferred <= range.gapThreshold { result += inferred }
        }
    }
    return result
}

private func recordedHistoryDurations<Key: Hashable>(
    _ history: [TelemetrySample],
    range: HistoryRange,
    exact: KeyPath<TelemetrySample, [Key: TimeInterval]?>,
    key: (TelemetrySample) -> Key?
) -> [Key: TimeInterval] {
    guard !history.isEmpty else { return [:] }
    var result: [Key: TimeInterval] = [:]
    for (index, sample) in history.enumerated() {
        if let exactDurations = sample[keyPath: exact] {
            for (bucket, duration) in exactDurations where duration > 0 {
                result[bucket, default: 0] += duration
            }
            continue
        }
        guard index + 1 < history.count, let bucket = key(sample) else { continue }
        let inferred = history[index + 1].timestamp.timeIntervalSince(sample.timestamp)
        guard inferred > 0, inferred <= range.gapThreshold else { continue }
        result[bucket, default: 0] += inferred
    }
    return result
}

// MARK: - New premium context strip for Overview (specs + health + sensor count)
// Beautifully arranged hardware identity + health. Uses friendly Mac name (no raw model IDs like "Mac15,6").
// Scannable capsules + statlets (P/E cores, GPU cores, proper GHz). Uses DesignSystem. Consistent with SpecsTeaserCard.
struct OverviewContextStrip: View, Equatable {
    let snapshot: ThermalSnapshot
    let usage: SystemUsage?
    let rangeTitle: String

    private var specs: MacSpecs { fetchMacSpecs() }

    var body: some View {
        Button {
            // Future: present beautiful HardwareReport sheet/page with expanded data, Canvas vizs, export.
            // For now keeps glance clean while delivering the "hack the data" teaser.
        } label: {
            HStack(spacing: 12) {
                // Hardware identity (consistent with System tab). Friendly name (no raw "Mac15,6").
                // Scannable capsule + statlets. Tap for future full report.
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanVioletLight)
                    Text(specs.name)
                        .macFanSubhead()
                        .foregroundStyle(Color.macFanPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.macFanSurface, in: Capsule())

                // Clean statlets (beautiful arrangement). Uses P/E + GPU cores when available.
                // GHz formatting fixed; max freq omitted when unavailable (Apple silicon).
                HStack(spacing: 10) {
                    let cLabel: String = (specs.cpuPCores > 0 && specs.cpuECores > 0)
                        ? "\(specs.cpuPCores)P+\(specs.cpuECores)E"
                        : "\(specs.physicalCores)P/\(specs.logicalCores)L"
                    Statlet(value: cLabel, label: "cores", icon: "cpu")
                    Statlet(value: "\(specs.memoryGB) GB", label: "RAM", icon: "memorychip")
                    if let gc = specs.gpuCores, gc > 0 {
                        Statlet(value: "\(gc)c", label: "GPU", icon: "rectangle.3.group")
                    }
                    if let mhz = specs.maxCPUMHz, mhz > 500 {
                        let ghz = Double(mhz) / 1000.0
                        let f = ghz >= 4 ? String(format: "%.0f", ghz) : String(format: "%.1f", ghz)
                        Statlet(value: "\(f) GHz", label: "max", icon: "gauge")
                    }
                }

                Spacer(minLength: 8)

                // Health + discovery (right, calm)
                HStack(spacing: 8) {
                    let pressure = usage?.thermalStateRaw ?? 0
                    let pColor: Color = pressure >= 2 ? .macFanCoral : pressure == 1 ? .macFanAmberLight : .macFanMint
                    Circle().fill(pColor).frame(width: 7, height: 7)
                    Text("\(snapshot.sensors.count)s · \(snapshot.fans.count)f")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanSecondary)
                    if let u = usage, u.uptime > 3600 {
                        Text(SystemUsageView.uptimeText(u.uptime))
                            .macFanChartTick()
                            .foregroundStyle(Color.macFanMuted)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.025), in: Capsule())
            }
        }
        .buttonStyle(MacFanPressableStyle())
        .macFanHoverSpecial()
        .padding(.horizontal, 2)
    }

    static func == (lhs: OverviewContextStrip, rhs: OverviewContextStrip) -> Bool {
        lhs.snapshot.sourceStatus == rhs.snapshot.sourceStatus &&
        lhs.snapshot.sensors.count == rhs.snapshot.sensors.count &&
        lhs.snapshot.fans.count == rhs.snapshot.fans.count &&
        lhs.usage?.thermalStateRaw == rhs.usage?.thermalStateRaw &&
        lhs.rangeTitle == rhs.rangeTitle
    }
}



private struct Statlet: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .macFanCaption()
                .foregroundStyle(Color.macFanBlue)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .macFanNumber(12, weight: .semibold)
                    .foregroundStyle(Color.macFanPrimary)
                Text(label)
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 5))
    }
}
