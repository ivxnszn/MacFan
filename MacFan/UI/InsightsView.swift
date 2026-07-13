import SwiftUI

/// A concise thermal brief. Claims are derived from recorded telemetry and
/// every row can reveal the sample (or system observation) behind it.
struct InsightsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var insights: [Insight] = []
    @State private var history: [TelemetrySample] = []
    @State private var isLoading = true
    private let sampler = SystemUsageSampler()
    let onSelect: (Insight, TelemetrySample?) -> Void

    init(onSelect: @escaping (Insight, TelemetrySample?) -> Void = { _, _ in }) {
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ThermalBriefCard(
                currentTemperature: model.snapshot.displayTemperature?.celsius,
                history: history,
                findings: insights.count,
                unit: settings.temperatureUnit
            )

            if isLoading && insights.isEmpty {
                ProgressView("Reading recorded evidence…")
                    .controlSize(.small)
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .macFanCard(padding: 18, radius: 16)
            } else if insights.isEmpty {
                ContentUnavailableView(
                    "More history needed",
                    systemImage: "waveform.path.ecg",
                    description: Text("Keep MacFan running locally and this brief will fill with observed peaks, cooling response, and control time.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
                .macFanCard(padding: 18, radius: 16)
            } else {
                ForEach(groups, id: \.title) { group in
                    InsightSection(
                        title: group.title,
                        subtitle: group.subtitle,
                        insights: group.items,
                        evidence: evidence(for:),
                        onSelect: onSelect
                    )
                }
            }

            Label("Computed locally from recorded telemetry — no cloud or analytics", systemImage: "lock.shield")
                .macFanCallout()
                .foregroundStyle(Color.macFanMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private var groups: [(title: String, subtitle: String, items: [Insight])] {
        let thermalIDs: Set<String> = ["peak", "time-above", "fan-response"]
        let nowIDs: Set<String> = ["throttling", "swap"]
        let activityIDs: Set<String> = ["control-time", "uptime"]
        return [
            ("Right now", "Live macOS context", insights.filter { nowIDs.contains($0.id) }),
            ("Thermal record", "Peaks, exposure, and cooling response", insights.filter { thermalIDs.contains($0.id) }),
            ("Activity", "MacFan control and host context", insights.filter { activityIDs.contains($0.id) })
        ].filter { !$0.items.isEmpty }
    }

    private func evidence(for insight: Insight) -> TelemetrySample? {
        switch insight.id {
        case "peak":
            history.max {
                ($0.displayMaximumTemperatureCelsius ?? -.infinity) < ($1.displayMaximumTemperatureCelsius ?? -.infinity)
            }
        case "time-above":
            history.first { ($0.displayMaximumTemperatureCelsius ?? -.infinity) >= ThermalPalette.amberMinimum }
                ?? history.last
        case "fan-response":
            InsightsEngine.fanResponseMatch(
                history: history,
                hardwareMaximumRPM: model.snapshot.fans.map(\.maximumRPM).max() ?? 0
            )?.response ?? history.first {
                ($0.displayMaximumTemperatureCelsius ?? -.infinity) >= InsightsEngine.hotThresholdCelsius
            }
        case "control-time":
            history.first { $0.mode != .system }
        default:
            history.last
        }
    }

    private func refresh() async {
        let nextHistory = await model.dailyHistory()
        let usage = await sampler.sample()
        guard !Task.isCancelled else { return }
        let nextInsights = InsightsEngine.insights(
            history: nextHistory,
            now: .now,
            uptime: usage.uptime,
            thermalStateRaw: usage.thermalStateRaw,
            swapUsedBytes: usage.swapUsedBytes,
            hardwareMaximumRPM: model.snapshot.fans.map(\.maximumRPM).max(),
            unit: settings.temperatureUnit
        )
        if nextHistory != history { history = nextHistory }
        if nextInsights != insights { insights = nextInsights }
        isLoading = false
    }
}

private struct ThermalBriefCard: View {
    let currentTemperature: Double?
    let history: [TelemetrySample]
    let findings: Int
    let unit: TemperatureUnit

    private var peak: Double? { history.compactMap(\.displayMaximumTemperatureCelsius).max() }
    private var currentBand: ThermalBand { ThermalPalette.band(for: currentTemperature) }
    private var coverage: TimeInterval {
        history.enumerated().reduce(0) { total, entry in
            let index = entry.offset
            let sample = entry.element
            if let exact = sample.recordedCoverageSeconds { return total + max(0, exact) }
            guard index + 1 < history.count else { return total }
            return total + min(max(history[index + 1].timestamp.timeIntervalSince(sample.timestamp), 0), 30)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) { content }
            VStack(alignment: .leading, spacing: 18) { content }
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .macFanCard(padding: 18, radius: 18, flatten: false)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Thermal brief", systemImage: "sparkles")
                .macFanHeadline()
                .foregroundStyle(Color.macFanPrimary)
            Text("A calm summary of what MacFan actually observed.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
        }
        Spacer(minLength: 12)
        BriefMetric(
            label: "Now",
            value: currentTemperature.map { unit.degreesWithUnit($0) } ?? "—",
            tint: currentBand.color
        )
        BriefMetric(
            label: "24h peak",
            value: peak.map { unit.degreesWithUnit($0) } ?? "—",
            tint: peak.map { ThermalPalette.band(for: $0).color } ?? .macFanMuted
        )
        BriefMetric(
            label: "Recorded",
            value: coverage > 0 ? InsightsEngine.durationText(coverage) : "—",
            tint: .macFanVioletLight
        )
        BriefMetric(label: "Findings", value: "\(findings)", tint: .macFanSky)
    }
}

private struct BriefMetric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).macFanSectionLabel()
            Text(value)
                .macFanNumber(20, weight: .semibold)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 84, alignment: .leading)
    }
}

private struct InsightSection: View {
    let title: String
    let subtitle: String
    let insights: [Insight]
    let evidence: (Insight) -> TelemetrySample?
    let onSelect: (Insight, TelemetrySample?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                Text(subtitle).macFanCallout().foregroundStyle(Color.macFanMuted)
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                    InsightRow(insight: insight) { onSelect(insight, evidence(insight)) }
                    if index < insights.count - 1 {
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 58)
                    }
                }
            }
            .macFanCard(padding: 0, radius: 16)
        }
    }
}

private struct InsightRow: View {
    let insight: Insight
    let action: () -> Void

    private var tint: Color {
        switch insight.severity {
        case .info: .macFanBlue
        case .notice: .macFanAmber
        case .warning: .macFanCoral
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: insight.icon)
                    .macFanHeadline()
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(insight.title)
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanPrimary)
                    Text(insight.detail)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("Evidence")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                    Image(systemName: "chevron.right")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanVioletLight)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacFanPressableStyle())
        .accessibilityIdentifier("insight-row-\(insight.id)")
        .accessibilityLabel(insight.title)
        .accessibilityValue(insight.detail)
        .accessibilityHint("Shows the evidence behind this finding")
    }
}
