import SwiftUI

/// Revamped premium recap-focused Insights (ThermalBriefCard + supporting summaries).
/// Purposeful: key stats (exposure, episodes, swing, cool ratio), dual mini-viz (temp+fan effort),
/// actionable recommendations, beautiful Canvas + DesignSystem components (RecapMetric, MiniPercentGauge).
/// Uses full MacFanMetrics, macFanCard, grain, consistent glance hierarchy. Aligns with premium
/// requirements (lightweight, 144Hz Canvas, data-hacked from InsightsEngine, not clunky).
/// Complements revamped Overview recaps (ThermalSummaryCard etc).
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
                unit: settings.temperatureUnit,
                hardwareMaximumRPM: model.snapshot.fans.map(\.maximumRPM).max()
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
        .task(id: model.isDashboardVisible) {
            guard model.isDashboardVisible else { return }
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
    let hardwareMaximumRPM: Double?

    // Derived metrics (lightweight; recomputed on 30s refresh cycle). Richer set for purposeful recap value.
    private var peak: Double? { history.compactMap(\.displayMaximumTemperatureCelsius).max() }
    private var minTemp: Double? { history.compactMap(\.displayMinimumTemperatureCelsius).min() }
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
    private var coverageFraction: Double {
        let window: TimeInterval = 24 * 3600
        return min(1.0, max(0, coverage / window))
    }
    private var avgTemp: Double? { InsightsEngine.averageTemperature(history: history) }
    private var bandFracs: [ThermalBand: Double] { InsightsEngine.bandDistribution(history: history) }
    private var responseInfo: (label: String, severity: Insight.Severity, detail: String) {
        InsightsEngine.responseCorrelationLabel(
            history: history,
            hardwareMaximumRPM: hardwareMaximumRPM
        )
    }
    private var recentValues: [Double] {
        Array(history.suffix(32).compactMap(\.displayTemperatureCelsius))
    }
    private var recentFanEffort: [Double] {
        Array(history.suffix(24).compactMap { s in
            guard let rpm = s.averageActualRPM, let maxR = hardwareMaximumRPM, maxR > 5 else { return nil }
            return min(1.0, max(0.0, rpm / maxR))
        })
    }
    private var hotSeconds: TimeInterval {
        InsightsEngine.secondsAbove(InsightsEngine.hotThresholdCelsius, history: history, now: .now)
    }
    private var swing: Double? { InsightsEngine.temperatureSwing(history: history) }
    private var hotEpisodes: Int { InsightsEngine.hotEpisodeCount(history: history) }
    private var coolPct: Double { InsightsEngine.coolFraction(history: history) }

    private var recommendation: (icon: String, text: String, tint: Color)? {
        let corr = responseInfo
        if hotSeconds > 600 {
            return ("exclamationmark.triangle", "High exposure: enable Smart Boost or check airflow for sustained loads.", .macFanCoral)
        } else if corr.label.contains("Delayed") || corr.label.contains("Limited") {
            return ("fanblades", "Fans slow to respond — consider Smart mode or vent cleaning.", .macFanAmber)
        } else if hotEpisodes >= 3 && hotSeconds > 120 {
            return ("chart.line.uptrend.xyaxis", "Multiple spikes: review app usage or switch to proactive Smart control.", .macFanAmber)
        } else if coolPct > 0.75 {
            return ("leaf", "Excellent baseline — most time spent cool or balanced.", .macFanMint)
        } else if let s = swing, s > 18 {
            return ("arrow.up.and.down", "Large temp swings — Smart Boost can smooth response.", .macFanVioletLight)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Premium scannable header — purposeful title + metrics at a glance
            HStack(alignment: .firstTextBaseline, spacing: MacFanMetrics.spacingS) {
                Label("Thermal recap", systemImage: "sparkles")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Text("\(findings) insights")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                    if coverage > 60 {
                        Text("· \(Int(coverageFraction * 100))% coverage")
                            .macFanChartTick()
                            .foregroundStyle(Color.macFanMuted)
                    }
                    Text("24h local")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted.opacity(0.8))
                }
            }

            // Hero glance: NOW (hero), PEAK, AVG + swing, inline dual mini trend viz
            HStack(alignment: .top, spacing: MacFanMetrics.spacingL) {
                // Current — largest, purposeful
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW").macFanSectionLabel()
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(currentTemperature.map { unit.degreesWithUnit($0) } ?? "—")
                            .macFanNumber(30, weight: .semibold)
                            .foregroundStyle(currentBand.color)
                            .macFanLiveNumberTransition()
                        Text(currentBand.label)
                            .macFanCaption()
                            .foregroundStyle(currentBand.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(currentBand.color.opacity(0.13), in: Capsule())
                    }
                }

                // Peak + context
                VStack(alignment: .leading, spacing: 3) {
                    Text("PEAK").macFanSectionLabel()
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text(peak.map { unit.degreesWithUnit($0) } ?? "—")
                            .macFanNumber(22, weight: .semibold)
                            .foregroundStyle(peak.map { ThermalPalette.band(for: $0).color } ?? .macFanMuted)
                            .macFanLiveNumberTransition()
                        if let p = peak {
                            Text(ThermalPalette.band(for: p).label.lowercased())
                                .macFanChartTick()
                                .foregroundStyle(ThermalPalette.band(for: p).color.opacity(0.85))
                        }
                    }
                }

                // Avg + stability swing (new key stat for purposeful monitoring)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AVG").macFanSectionLabel()
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text(avgTemp.map { unit.degreesWithUnit($0) } ?? "—")
                            .macFanNumber(18, weight: .semibold)
                            .foregroundStyle(Color.macFanIndigo)
                            .macFanLiveNumberTransition()
                    }
                    if let sw = swing {
                        Text("swing \(unit.degreesWithUnit(sw))")
                            .macFanChartTick()
                            .foregroundStyle(Color.macFanMuted)
                    }
                }

                Spacer(minLength: 4)

                // Dual mini trend vizs (temp + normalized fan effort). Purposeful: see thermal vs cooling behavior at a glance.
                if !recentValues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TREND").macFanSectionLabel()
                        Sparkline(values: recentValues, color: currentBand.color, lineWidth: 1.7, minimumSpan: 4)
                            .frame(width: 86, height: 24)
                            .background(Color.white.opacity(0.018), in: Capsule())
                        if !recentFanEffort.isEmpty {
                            Sparkline(values: recentFanEffort, color: .macFanCyan, lineWidth: 1.3, minimumSpan: 0.15)
                                .frame(width: 86, height: 16)
                                .background(Color.white.opacity(0.012), in: Capsule())
                            Text("fan effort")
                                .macFanChartTick()
                                .foregroundStyle(Color.macFanMuted.opacity(0.75))
                        }
                    }
                }

                // Response — now using new RecapMetric style + badge
                let corr = responseInfo
                let corrTint = corr.severity == .warning ? Color.macFanCoral : (corr.severity == .notice ? Color.macFanAmber : Color.macFanSky)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("RESPONSE").macFanSectionLabel()
                    Text(corr.label)
                        .macFanNumber(14, weight: .semibold)
                        .foregroundStyle(corrTint)
                        .lineLimit(1)
                    Text(corr.detail)
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 158, alignment: .trailing)
                }
            }

            // Key stats row — using DesignSystem RecapMetric for clean, consistent, not clunky presentation.
            // Added purposeful stats: exposure, episodes, cool % (actionable health).
            HStack(spacing: MacFanMetrics.spacing) {
                RecapMetric(
                    label: "RECORDED",
                    value: coverage > 0 ? InsightsEngine.durationText(coverage) : "—",
                    tint: .macFanVioletLight,
                    icon: "clock"
                )
                RecapMetric(
                    label: "HOT EXPOSURE",
                    value: hotSeconds > 0 ? InsightsEngine.durationText(hotSeconds) : "0s",
                    tint: .macFanAmber,
                    icon: "flame"
                )
                RecapMetric(
                    label: "HOT EPISODES",
                    value: hotEpisodes > 0 ? "\(hotEpisodes)" : "0",
                    tint: .macFanCoral,
                    icon: "waveform.path.ecg",
                    sublabel: hotEpisodes > 2 ? "frequent" : nil
                )
                RecapMetric(
                    label: "COOL RATIO",
                    value: String(format: "%.0f%%", coolPct * 100),
                    tint: coolPct > 0.7 ? .macFanMint : .macFanSky,
                    icon: "thermometer.low"
                )

                Spacer(minLength: 8)

                // Enhanced visual: Band distribution + % gauge side-by-side (mini chart value)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DISTRIBUTION").macFanSectionLabel()
                    HStack(spacing: 8) {
                        MiniBandDistributionCanvas(bandFracs: bandFracs)
                            .frame(width: 138, height: 12)
                        MiniPercentGauge(fraction: coolPct, tint: .macFanMint, label: nil, height: 10)
                            .frame(width: 52)
                    }
                }
            }

            // Actionable info row — the purposeful heart of the revamp. Adds real value beyond raw stats.
            if let rec = recommendation {
                HStack(spacing: 8) {
                    Image(systemName: rec.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(rec.tint)
                    Text(rec.text)
                        .macFanBody()
                        .foregroundStyle(Color.macFanPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(rec.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                        .stroke(rec.tint.opacity(0.18), lineWidth: 0.5)
                )
            }
        }
        .padding(MacFanMetrics.cardPaddingL)
        .macFanCard(padding: 0, radius: MacFanMetrics.radiusL, flatten: true)
        .overlay(alignment: .topLeading) {
            // Premium grain using the canonical GrainOverlay (consistent across app)
            GrainOverlay(opacity: 0.007, density: 110, dotSize: 0.38)
                .clipShape(RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous))
                .allowsHitTesting(false)
        }
    }
}

// BriefMetric retired in favor of shared RecapMetric (DesignSystem) for consistent premium recap UIs across Insights + Overview.

/// Mini Canvas for beautiful, lightweight thermal band distribution.
/// Uses exact fractions from engine. Renders as crisp segmented capsule. Used with MiniPercentGauge for richer recap viz.
private struct MiniBandDistributionCanvas: View {
    let bandFracs: [ThermalBand: Double]

    private let orderedBands: [ThermalBand] = [.cool, .indigo, .violet, .amber, .hot]

    var body: some View {
        Canvas { context, size in
            guard size.width > 4, size.height > 2 else { return }
            let total = bandFracs.values.reduce(0, +)
            guard total > 0.0001 else {
                // Fallback empty state bar
                let r = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                context.fill(Path(roundedRect: r, cornerSize: CGSize(width: size.height/2, height: size.height/2)), with: .color(Color.white.opacity(0.06)))
                return
            }

            var x: CGFloat = 0
            let h = size.height
            let r = h / 2

            for band in orderedBands {
                let frac = bandFracs[band] ?? 0
                guard frac > 0.001 else { continue }
                let w = max(1.5, size.width * CGFloat(frac))
                let rect = CGRect(x: x, y: 0, width: w, height: h)
                let path = Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r))
                context.fill(path, with: .color(band.color.opacity(0.88)))

                // Delicate inner highlight for premium depth (lightweight)
                if w > 6 {
                    let inner = rect.insetBy(dx: 0.5, dy: 0.5)
                    context.stroke(Path(roundedRect: inner, cornerSize: CGSize(width: r*0.7, height: r*0.7)), with: .color(.white.opacity(0.12)), lineWidth: 0.6)
                }
                x += w
            }

            // Subtle outer stroke for definition
            let outer = Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: h), cornerSize: CGSize(width: r, height: r))
            context.stroke(outer, with: .color(Color.white.opacity(0.15)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
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
