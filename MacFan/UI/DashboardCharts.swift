import SwiftUI

/// An equatable, self-contained chart surface. Live fan/temperature updates no
/// longer ask Charts to rebuild this view unless its history data actually changes.
struct DashboardHistoryCharts: View, Equatable {
    let history: [TelemetrySample]
    private let historyIdentity: ChartHistoryIdentity
    let range: HistoryRange
    let hardwareMaximumRPM: Double
    let temperatureUnit: TemperatureUnit
    let smartBoostThresholdCelsius: Double
    let showsRPMChart: Bool
    let thermalChartStyle: ThermalChartStyle
    let onSelectStyle: (ThermalChartStyle) -> Void
    @Binding var inspectedSample: TelemetrySample?

    // Keep init cheap: SwiftUI may construct an Equatable child before it
    // decides that the child can be skipped. Derived chart data is rebuilt only
    // after history/range identity actually changes.
    @State private var data = ChartData.empty
    @State private var hoveredSample: TelemetrySample?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var styleNamespace

    init(
        history: [TelemetrySample],
        range: HistoryRange,
        hardwareMaximumRPM: Double,
        temperatureUnit: TemperatureUnit,
        smartBoostThresholdCelsius: Double,
        showsRPMChart: Bool,
        thermalChartStyle: ThermalChartStyle = .area,
        onSelectStyle: @escaping (ThermalChartStyle) -> Void = { _ in },
        inspectedSample: Binding<TelemetrySample?>
    ) {
        self.history = history
        self.historyIdentity = ChartHistoryIdentity(history)
        self.range = range
        self.hardwareMaximumRPM = hardwareMaximumRPM
        self.temperatureUnit = temperatureUnit
        self.smartBoostThresholdCelsius = smartBoostThresholdCelsius
        self.showsRPMChart = showsRPMChart
        self.thermalChartStyle = thermalChartStyle
        self.onSelectStyle = onSelectStyle
        self._inspectedSample = inspectedSample
    }

    private var highestTemperature: Double? { data.highestTemperature }
    private var hasMacFanTargets: Bool { data.hasMacFanTargets }
    private var hasFirmwareTargets: Bool { data.hasFirmwareTargets }

    var body: some View {
        VStack(spacing: 16) {
            // Inspector bar retired for thermal chart — floating macFanScrubHUD inside the canvas (pure geo + plotRect) is the single truth
            lightweightTemperatureChart
                .frame(minHeight: 255)
                .macFanCard(padding: MacFanMetrics.cardPadding, radius: MacFanMetrics.radiusL, flatten: false)
            if showsRPMChart {
                lightweightRPMChart
                    .frame(minHeight: 185)
                    .macFanCard(padding: MacFanMetrics.cardPadding, radius: MacFanMetrics.radiusL, flatten: false)
            }
        }
        .onAppear {
            data = ChartData.make(
                history: history,
                range: range,
                hardwareMaximumRPM: hardwareMaximumRPM,
                temperatureUnit: temperatureUnit
            )
        }
        .onChange(of: historyIdentity) { _, _ in
            data = ChartData.make(
                history: history,
                range: range,
                hardwareMaximumRPM: hardwareMaximumRPM,
                temperatureUnit: temperatureUnit
            )
        }
        .onChange(of: range) { _, next in
            inspectedSample = nil
            hoveredSample = nil
            // Live ticks never animate; only a deliberate range switch earns
            // this one-shot compositor cross-fade between cached canvases.
            let nextData = ChartData.make(
                history: history,
                range: next,
                hardwareMaximumRPM: hardwareMaximumRPM,
                temperatureUnit: temperatureUnit
            )
            if reduceMotion {
                data = nextData
            } else {
                withAnimation(.easeOut(duration: 0.24)) { data = nextData }
            }
        }
        .onChange(of: hardwareMaximumRPM) { _, next in
            data = ChartData.make(
                history: history,
                range: range,
                hardwareMaximumRPM: next,
                temperatureUnit: temperatureUnit
            )
        }
        .onChange(of: temperatureUnit) { _, next in
            data = ChartData.make(
                history: history,
                range: range,
                hardwareMaximumRPM: hardwareMaximumRPM,
                temperatureUnit: next
            )
        }
    }

    // Canvas avoids Swift Charts' per-mark accessibility/layout graph. The
    // charts remain interactive and visually rich, but render as two paths and
    // a small set of dots instead of hundreds of retained chart marks.
    private var lightweightTemperatureChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                fullTemperatureHeader
                compactTemperatureHeader
            }
            LightweightThermalCanvas(
                data: data,
                temperatureUnit: temperatureUnit,
                smartBoostThresholdCelsius: smartBoostThresholdCelsius,
                style: thermalChartStyle,
                hoveredSample: $hoveredSample,
                pinnedSample: inspectedSample
            )
                .onTapGesture(perform: pinHoveredSample)
                .accessibilityLabel("Heat over time chart")
                .accessibilityValue(summary)
        }
    }

    /// Line / Area / Ribbon — the same series, three ways. A pill that matches
    /// the range selector; the style flows into the cached canvas key so
    /// switching re-caches once, never per frame.
    private var styleToggle: some View {
        HStack(spacing: 2) {
            ForEach(ThermalChartStyle.allCases) { style in
                Button { onSelectStyle(style) } label: {
                    Image(systemName: style.symbol)
                        .macFanCaption()
                        .frame(width: 26, height: 22)
                        .background {
                            if thermalChartStyle == style {
                                RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .matchedGeometryEffect(id: "thermal-style-pill", in: styleNamespace)
                            }
                        }
                }
                .buttonStyle(MacFanPressableStyle(pressedScale: 0.9))
                .foregroundStyle(thermalChartStyle == style ? Color.macFanPrimary : Color.macFanMuted)
                .help("\(style.title) view")
                .accessibilityLabel("\(style.title) chart style")
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1) }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: thermalChartStyle)
    }

    private var fullTemperatureHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("CPU temperature", systemImage: "thermometer.medium")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Text(data.coverageLabel)
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
            }
            Spacer(minLength: 8)
            thermalDistributionStrip
            if let average = data.averageTemperature {
                headerMetric("Average", value: temperatureUnit.degrees(average))
            }
            styleToggle
            peakButton
        }
    }

    private var compactTemperatureHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("CPU temperature", systemImage: "thermometer.medium")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Spacer()
                peakButton
            }
            if let low = data.lowestTemperature, let average = data.averageTemperature, let peak = highestTemperature {
                Text("Range \(temperatureUnit.degrees(low))–\(temperatureUnit.degrees(peak))  ·  Average \(temperatureUnit.degrees(average))  ·  \(data.coverageLabel)")
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanSecondary)
            }
        }
    }

    @ViewBuilder
    private var peakButton: some View {
        if let peak = highestTemperature {
            Button {
                inspectedSample = data.peakSample
            } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("PEAK")
                        .macFanLabel(tracking: 0.45)
                        .foregroundStyle(Color.macFanMuted)
                    Text(temperatureUnit.degrees(peak))
                        .macFanNumber(13, weight: .semibold)
                        .foregroundStyle(ThermalPalette.band(for: peak).color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MacFanPressableStyle())
            .help("Inspect the highest recorded CPU temperature")
            .accessibilityLabel("Inspect peak temperature \(temperatureUnit.degreesWithUnit(peak))")
        }
    }

    private func headerMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .macFanLabel(tracking: 0.45)
                .foregroundStyle(Color.macFanMuted)
            Text(value)
                .macFanNumber(13, weight: .medium)
                .foregroundStyle(Color.macFanSecondary)
        }
    }

    @ViewBuilder
    private var thermalDistributionStrip: some View {
        if !data.distributionBins.isEmpty {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(data.distributionBins) { bin in
                        Rectangle()
                            .fill(bin.band.color.opacity(0.84))
                            .frame(width: max(1, proxy.size.width * bin.fraction))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: 72, height: 5)
            .help(data.distributionSummary)
            .accessibilityLabel(data.distributionSummary)
        }
    }

    private var lightweightRPMChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Fan response", systemImage: "fanblades.fill")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Spacer()
                if let response = data.eventMarkers.first {
                    Text("Response \(responseDuration(response.responseSeconds))")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanCyan)
                }
                LegendDot(color: .macFanViolet, text: "actual")
                if hasMacFanTargets { LegendDot(color: .macFanCyan, text: "MacFan target") }
                if hasFirmwareTargets { LegendDot(color: .macFanMuted, text: "SMC target") }
            }
            LightweightRPMCanvas(data: data, hoveredSample: $hoveredSample, pinnedSample: inspectedSample)
                .onTapGesture(perform: pinHoveredSample)
                .accessibilityLabel("Fan response chart")
                .accessibilityValue(rpmSummary)
        }
    }

    private var summary: String {
        guard let peak = highestTemperature else { return "No CPU samples" }
        return "\(history.count) samples. Peak CPU temperature \(temperatureUnit.degreesWithUnit(peak)). Hover to inspect and click to pin a sample."
    }

    private var rpmSummary: String {
        let peak = history.compactMap(\.averageActualRPM).max().map { "\(Int($0.rounded())) RPM" } ?? "unavailable"
        return "\(history.count) fan samples. Peak actual fan speed \(peak)."
    }

    private func pinHoveredSample() {
        let candidate = hoveredSample ?? inspectedSample ?? history.last
        inspectedSample = inspectedSample?.id == candidate?.id ? nil : candidate
    }

    private func responseDuration(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        return rounded < 60 ? "\(rounded)s" : "\(rounded / 60)m \(rounded % 60)s"
    }

    static func == (lhs: DashboardHistoryCharts, rhs: DashboardHistoryCharts) -> Bool {
        lhs.historyIdentity == rhs.historyIdentity && lhs.range == rhs.range && lhs.hardwareMaximumRPM == rhs.hardwareMaximumRPM &&
        lhs.temperatureUnit == rhs.temperatureUnit && lhs.smartBoostThresholdCelsius == rhs.smartBoostThresholdCelsius &&
        lhs.showsRPMChart == rhs.showsRPMChart && lhs.thermalChartStyle == rhs.thermalChartStyle
    }
}

/// History only mutates at its live edge (append or replace the newest bucket).
/// Keeping that identity O(1) avoids walking a 30-day array on every unrelated
/// dashboard publication and every hover update.
private struct ChartHistoryIdentity: Equatable {
    let count: Int
    let first: TelemetrySample?
    let last: TelemetrySample?

    init(_ history: [TelemetrySample]) {
        count = history.count
        first = history.first
        last = history.last
    }
}

struct SegmentedHistorySample: Identifiable, Equatable {
    let sample: TelemetrySample
    let segment: Int
    var id: Date { sample.id }
}

struct ChartEventMarker: Equatable {
    let timestamp: Date
    let responseSeconds: TimeInterval
}

struct ChartBandFraction: Identifiable, Equatable {
    let band: ThermalBand
    let fraction: Double
    var id: ThermalBand { band }
}

private struct ChartAxisScale {
    let lower: Double
    let upper: Double
    let step: Double
}

/// Produces conventional instrument ticks (1, 2, 2.5, 5, 10 × a power of ten)
/// instead of dividing an arbitrary domain and rounding fractional labels. The
/// returned bounds are exact multiples of the chosen step, so every gridline
/// and label represents the value it claims to show.
private func niceAxisScale(
    minimum: Double,
    maximum: Double,
    targetIntervals: Int,
    minimumStep: Double
) -> ChartAxisScale {
    let finiteMinimum = minimum.isFinite ? minimum : 0
    let finiteMaximum = maximum.isFinite ? maximum : finiteMinimum + minimumStep
    let low = min(finiteMinimum, finiteMaximum)
    let high = max(finiteMinimum, finiteMaximum)
    let span = max(high - low, minimumStep)
    let rawStep = max(span / Double(max(targetIntervals, 1)), minimumStep)
    let magnitude = pow(10, Foundation.floor(log10(rawStep)))
    let fraction = rawStep / magnitude
    let niceFraction: Double
    switch fraction {
    case ...1: niceFraction = 1
    case ...2: niceFraction = 2
    case ...2.5: niceFraction = 2.5
    case ...5: niceFraction = 5
    default: niceFraction = 10
    }
    let step = max(minimumStep, niceFraction * magnitude)
    let lower = Foundation.floor(low / step) * step
    var upper = Foundation.ceil(high / step) * step
    if upper <= lower { upper = lower + step }
    return ChartAxisScale(lower: lower, upper: upper, step: step)
}

private func niceTemperatureScale(
    minimumCelsius: Double,
    maximumCelsius: Double,
    unit: TemperatureUnit
) -> ChartAxisScale {
    let displayMinimum = unit.convert(minimumCelsius)
    let displayMaximum = unit.convert(maximumCelsius)
    let displayScale = niceAxisScale(
        minimum: displayMinimum,
        maximum: displayMaximum,
        targetIntervals: 6,
        minimumStep: unit == .celsius ? 5 : 10
    )
    guard unit == .fahrenheit else { return displayScale }
    return ChartAxisScale(
        lower: (displayScale.lower - 32) * 5 / 9,
        upper: (displayScale.upper - 32) * 5 / 9,
        step: displayScale.step * 5 / 9
    )
}

private func chartAxisTicks(lower: Double, upper: Double, step: Double) -> [Double] {
    guard lower.isFinite, upper.isFinite, step.isFinite, step > 0, upper > lower else { return [] }
    let intervalCount = min(max(Int(((upper - lower) / step).rounded()), 1), 12)
    return (0...intervalCount).map { lower + Double($0) * step }
}

struct ChartData: Equatable {
    let renderToken = UUID()
    var samples: [SegmentedHistorySample] = []
    var highestTemperature: Double?
    var lowestTemperature: Double?
    var averageTemperature: Double?
    var hasTemperatureBand = false
    var peakSample: TelemetrySample?
    var temperatureFloor: Double = 20
    var temperatureCeiling: Double = 80
    var temperatureTickStep: Double = 10
    var rpmCeiling: Double = 1_000
    var rpmTickStep: Double = 250
    var hasMacFanTargets = false
    var hasFirmwareTargets = false
    var domainStart = Date.now.addingTimeInterval(-HistoryRange.day.interval)
    var domainEnd = Date.now
    var usesCalendarDates = false
    var inspectionTolerance: TimeInterval = 30
    var recordedCoverageSeconds: TimeInterval = 0
    var coverageFraction: Double = 0
    var eventMarkers: [ChartEventMarker] = []
    var distributionBins: [ChartBandFraction] = []

    static let empty = ChartData()

    var temperatureTicks: [Double] {
        chartAxisTicks(lower: temperatureFloor, upper: temperatureCeiling, step: temperatureTickStep)
    }

    var rpmTicks: [Double] {
        chartAxisTicks(lower: 0, upper: rpmCeiling, step: rpmTickStep)
    }

    var xAxisFormat: Date.FormatStyle {
        usesCalendarDates ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
    }

    var coverageLabel: String {
        guard recordedCoverageSeconds > 0 else { return "Collecting recorded coverage" }
        let percent = Int((coverageFraction * 100).rounded())
        let duration: String
        if recordedCoverageSeconds >= 86_400 {
            duration = "\(Int((recordedCoverageSeconds / 86_400).rounded()))d"
        } else if recordedCoverageSeconds >= 3_600 {
            duration = "\(Int((recordedCoverageSeconds / 3_600).rounded()))h"
        } else if recordedCoverageSeconds >= 60 {
            duration = "\(Int((recordedCoverageSeconds / 60).rounded()))m"
        } else {
            duration = "\(Int(recordedCoverageSeconds.rounded()))s"
        }
        return "\(percent)% recorded · \(duration)"
    }

    var distributionSummary: String {
        guard !distributionBins.isEmpty else { return "Thermal distribution unavailable" }
        return distributionBins
            .map { "\($0.band.label) \(Int(($0.fraction * 100).rounded())) percent" }
            .joined(separator: ", ")
    }

    static func make(
        history: [TelemetrySample],
        range: HistoryRange,
        hardwareMaximumRPM: Double,
        temperatureUnit: TemperatureUnit = .celsius
    ) -> ChartData {
        var result = ChartData()
        let gap = range.gapThreshold
        var segment = 0
        var previous: Date?
        var breaksTemperatureSeries = false
        result.samples = history.map { sample in
            if let previous, sample.timestamp.timeIntervalSince(previous) > gap { segment += 1 }
            if sample.displayTemperatureCelsius == nil {
                breaksTemperatureSeries = true
            } else if breaksTemperatureSeries {
                segment += 1
                breaksTemperatureSeries = false
            }
            previous = sample.timestamp
            return SegmentedHistorySample(sample: sample, segment: segment)
        }

        func observedDuration(at index: Int) -> TimeInterval {
            if let exact = history[index].recordedCoverageSeconds { return max(0, exact) }
            guard index + 1 < history.count else { return 0 }
            let inferred = history[index + 1].timestamp.timeIntervalSince(history[index].timestamp)
            return inferred > 0 && inferred <= gap ? inferred : 0
        }

        let temperatures = history.compactMap(\.displayTemperatureCelsius)
        result.highestTemperature = history.compactMap(\.displayMaximumTemperatureCelsius).max()
        result.lowestTemperature = history.compactMap(\.displayMinimumTemperatureCelsius).min()

        var weightedTemperature = 0.0
        var temperatureWeight = 0.0
        var coverage = 0.0
        for (index, sample) in history.enumerated() {
            let duration = observedDuration(at: index)
            coverage += duration
            if let temperature = sample.displayTemperatureCelsius, duration > 0 {
                weightedTemperature += temperature * duration
                temperatureWeight += duration
            }
        }
        result.recordedCoverageSeconds = min(coverage, range.interval)
        result.coverageFraction = range.interval > 0 ? min(result.recordedCoverageSeconds / range.interval, 1) : 0
        result.averageTemperature = temperatureWeight > 0
            ? weightedTemperature / temperatureWeight
            : (temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count))

        if let match = InsightsEngine.fanResponseMatch(history: history, hardwareMaximumRPM: hardwareMaximumRPM) {
            result.eventMarkers = [ChartEventMarker(timestamp: match.start.timestamp, responseSeconds: match.seconds)]
        }

        var bandDurations: [ThermalBand: TimeInterval] = [:]
        for (index, sample) in history.enumerated() {
            if let exact = sample.thermalBandDurations {
                for (band, duration) in exact where band != .muted && duration > 0 {
                    bandDurations[band, default: 0] += duration
                }
            } else if let temperature = sample.displayTemperatureCelsius {
                let duration = observedDuration(at: index)
                if duration > 0 {
                    bandDurations[ThermalPalette.band(for: temperature), default: 0] += duration
                }
            }
        }
        let totalBandDuration = bandDurations.values.reduce(0, +)
        if totalBandDuration > 0 {
            result.distributionBins = [ThermalBand.cool, .indigo, .violet, .amber, .hot].compactMap { band in
                let fraction = (bandDurations[band] ?? 0) / totalBandDuration
                return fraction > 0 ? ChartBandFraction(band: band, fraction: fraction) : nil
            }
        }

        result.hasTemperatureBand = history.contains { sample in
            guard let low = sample.displayMinimumTemperatureCelsius,
                  let high = sample.displayMaximumTemperatureCelsius else { return false }
            return high - low >= 0.1
        }
        result.peakSample = history.max {
            ($0.displayMaximumTemperatureCelsius ?? -.infinity) < ($1.displayMaximumTemperatureCelsius ?? -.infinity)
        }
        let low = result.lowestTemperature ?? 30
        let peak = result.highestTemperature ?? 75
        let temperatureScale = niceTemperatureScale(
            minimumCelsius: low - 6,
            maximumCelsius: peak + 6,
            unit: temperatureUnit
        )
        result.temperatureFloor = temperatureScale.lower
        result.temperatureCeiling = temperatureScale.upper
        result.temperatureTickStep = temperatureScale.step

        let reportedRPMCeiling = max(
            history.compactMap(\.averageActualRPM).max() ?? 0,
            history.compactMap(\.averageFirmwareTargetRPM).max() ?? 0,
            history.compactMap(\.averageMacFanTargetRPM).max() ?? 0,
            hardwareMaximumRPM,
            1_000
        ) * 1.05
        let rpmScale = niceAxisScale(
            minimum: 0,
            maximum: reportedRPMCeiling,
            targetIntervals: 4,
            minimumStep: 250
        )
        result.rpmCeiling = rpmScale.upper
        result.rpmTickStep = rpmScale.step
        result.hasMacFanTargets = history.contains { $0.averageMacFanTargetRPM != nil }
        result.hasFirmwareTargets = history.contains { $0.averageFirmwareTargetRPM != nil }
        let now = Date.now
        result.domainEnd = max(history.last?.timestamp ?? now, now)
        result.domainStart = result.domainEnd.addingTimeInterval(-range.interval)
        result.usesCalendarDates = range == .week || range == .month
        result.inspectionTolerance = max(TimeInterval(range.displayBucketSeconds) * 1.25, 15)
        return result
    }
}

// MARK: - Lightweight chart surfaces

/// Keeps a costly static Canvas render intact while a lightweight hover layer
/// changes above it. The renderer closure is intentionally excluded from
/// equality; `key` must contain every value used by that renderer.
private struct StableChartCanvas<Key: Equatable>: View, Equatable {
    let key: Key
    let renderer: (inout GraphicsContext, CGSize) -> Void

    var body: some View {
        Canvas(rendersAsynchronously: true, renderer: renderer)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

private struct ThermalCanvasKey: Equatable {
    let renderToken: UUID
    let unit: TemperatureUnit
    let threshold: Double
    let style: ThermalChartStyle

    init(data: ChartData, unit: TemperatureUnit, threshold: Double, style: ThermalChartStyle) {
        renderToken = data.renderToken
        self.unit = unit
        self.threshold = threshold
        self.style = style
    }
}

private struct RPMCanvasKey: Equatable {
    let renderToken: UUID

    init(data: ChartData) {
        renderToken = data.renderToken
    }
}

/// A small, retained-free chart renderer. Swift Charts is excellent for rich
/// exploratory charts, but its per-mark view graph is unnecessarily expensive
/// for a live menu-bar utility. These canvases draw the same information in a
/// single render pass and only publish a new inspection sample when the cursor
/// crosses to a different point.
struct LightweightThermalCanvas: View {
    let data: ChartData
    let temperatureUnit: TemperatureUnit
    let smartBoostThresholdCelsius: Double
    var style: ThermalChartStyle = .area
    @Binding var hoveredSample: TelemetrySample?
    let pinnedSample: TelemetrySample?

    private var inspectedSample: TelemetrySample? { hoveredSample ?? pinnedSample }

    private let left: CGFloat = 42
    private let right: CGFloat = 12
    private let top: CGFloat = 10
    private let bottom: CGFloat = 28

    var body: some View {
        // The static canvas depends only on data/unit/threshold, so hover moves
        // never touch it. All live inspection (rule, lollipop callout, dot) is
        // drawn into the tiny overlay canvas, which redraws only when the
        // inspected sample actually changes — never per pointer event.
        ZStack {
            StableChartCanvas(key: ThermalCanvasKey(data: data, unit: temperatureUnit, threshold: smartBoostThresholdCelsius, style: style)) {
                context, size in
                drawStatic(&context, size: size)
            }
            .equatable()
            .id(data.domainStart)
            .transition(.opacity)

            if let inspectedSample {
                Canvas { context, size in drawInspection(&context, size: size, sample: inspectedSample) }
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 205)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        updateInspection(phase: phase, width: proxy.size.width)
                    }
            }
        }
    }

    private func drawStatic(_ context: inout GraphicsContext, size: CGSize) {
        let plot = plotRect(size)
        guard plot.width > 1, plot.height > 1 else { return }
        let samples = data.samples.compactMap { entry -> (SegmentedHistorySample, Double)? in
            guard let temperature = entry.sample.displayTemperatureCelsius else { return nil }
            return (entry, temperature)
        }
        // Axes render even with no data, so a fresh install shows a chart
        // awaiting samples rather than a bare card.
        drawGrid(&context, plot: plot, size: size)
        guard !samples.isEmpty else {
            drawEmptyState(&context, size: size, plot: plot)
            return
        }

        let domain = data.temperatureCeiling - data.temperatureFloor
        let firstDate = data.domainStart
        let span = max(data.domainEnd.timeIntervalSince(firstDate), 1)
        func point(_ entry: SegmentedHistorySample, _ value: Double) -> CGPoint {
            let x = plot.minX + CGFloat(entry.sample.timestamp.timeIntervalSince(firstDate) / span) * plot.width
            let rawY = plot.maxY - CGFloat((value - data.temperatureFloor) / max(domain, 1)) * plot.height
            return CGPoint(x: x, y: min(max(rawY, plot.minY), plot.maxY))
        }

        drawThresholds(&context, plot: plot)
        if data.hasTemperatureBand { drawBand(&context, point: point) }

        // Segments buffer their points so each run can be emitted as one
        // monotone curve; the clamped interpolation never overshoots samples.
        var segmentPoints: [CGPoint] = []
        var currentSegment: Int?
        let showSparseMarkers = samples.count <= 80

        func finishSegment() {
            defer { segmentPoints.removeAll(keepingCapacity: true) }
            guard segmentPoints.count > 1 else { return }
            var path = Path()
            if segmentPoints.count >= 3 && segmentPoints.count <= 200 {
                addMonotoneCurve(segmentPoints, to: &path)
            } else {
                path.move(to: segmentPoints[0])
                for p in segmentPoints.dropFirst() { path.addLine(to: p) }
            }
            switch style {
            case .line:
                // Just the smoothed spectrum line; sparse dots below add texture.
                context.stroke(path, with: thermalStroke(in: plot), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            case .area:
                var area = path
                area.addLine(to: CGPoint(x: segmentPoints[segmentPoints.count - 1].x, y: plot.maxY))
                area.addLine(to: CGPoint(x: segmentPoints[0].x, y: plot.maxY))
                area.closeSubpath()
                context.fill(area, with: thermalAreaShading(in: plot))
                context.stroke(path, with: thermalStroke(in: plot), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            case .ribbon:
                // A bold heat ribbon: the full spectrum fills the column under
                // the curve, with a quiet bright center line reading the value.
                var area = path
                area.addLine(to: CGPoint(x: segmentPoints[segmentPoints.count - 1].x, y: plot.maxY))
                area.addLine(to: CGPoint(x: segmentPoints[0].x, y: plot.maxY))
                area.closeSubpath()
                context.drawLayer { layer in
                    layer.opacity = 0.5
                    layer.fill(area, with: thermalStroke(in: plot))
                }
                context.stroke(path, with: .color(Color.macFanPrimary.opacity(0.34)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }

        for (entry, temperature) in samples {
            let p = point(entry, temperature)
            if currentSegment != entry.segment {
                finishSegment()
                currentSegment = entry.segment
            }
            segmentPoints.append(p)
            if showSparseMarkers {
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                    with: .color(ThermalPalette.band(for: temperature).color.opacity(0.92))
                )
            }
        }
        finishSegment()

        // Fan-response episodes from InsightsEngine: a quiet tick at the axis,
        // not a full-height rule — the chart stays about temperature.
        for marker in data.eventMarkers {
            let mx = plot.minX + CGFloat(marker.timestamp.timeIntervalSince(data.domainStart) / span) * plot.width
            guard mx >= plot.minX, mx <= plot.maxX else { continue }
            var tick = Path()
            tick.move(to: CGPoint(x: mx, y: plot.maxY))
            tick.addLine(to: CGPoint(x: mx, y: plot.maxY - 6))
            context.stroke(tick, with: .color(Color.macFanCyan.opacity(0.72)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // A precise dot and value label mark the recorded CPU maximum.
        if let peak = data.peakSample, let temperature = peak.displayMaximumTemperatureCelsius {
            let p = point(SegmentedHistorySample(sample: peak, segment: 0), temperature)
            let band = ThermalPalette.band(for: temperature).color
            let dot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            context.fill(dot, with: .color(band))
            context.stroke(dot, with: .color(Color.macFanCanvas), lineWidth: 1.5)
            if samples.count >= 2 {
                let thresholdY = plot.maxY - CGFloat((smartBoostThresholdCelsius - data.temperatureFloor) / max(domain, 1)) * plot.height
                let above = max(p.y - 13, plot.minY + 7)
                let labelY = abs(above - thresholdY) < 14 ? min(p.y + 14, plot.maxY - 7) : above
                let labelX = min(max(p.x, plot.minX + 18), plot.maxX - 18)
                context.draw(
                    Text(temperatureUnit.degrees(temperature)).font(.macFanChartValue).foregroundStyle(band),
                    at: CGPoint(x: labelX, y: labelY),
                    anchor: .center
                )
            }
        }

        // Live edge marker: white-rimmed dot on the most recent sample.
        if let last = samples.last {
            let p = point(last.0, last.1)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)), with: .color(Color.macFanPrimary.opacity(0.16)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(Color.macFanPrimary.opacity(0.9)))
        }
    }

    /// Apple Health-style lollipop: the callout floats at the plot top,
    /// clamped to the edges, with the rule running down to a rimmed dot on the
    /// line. Pinned samples (no live hover) render a solid rule so the state
    /// is readable at a glance; Escape clears the pin.
    private func drawInspection(_ context: inout GraphicsContext, size: CGSize, sample: TelemetrySample) {
        guard let temperature = sample.displayTemperatureCelsius else { return }
        let plot = plotRect(size)
        let span = max(data.domainEnd.timeIntervalSince(data.domainStart), 1)
        let x = plot.minX + CGFloat(sample.timestamp.timeIntervalSince(data.domainStart) / span) * plot.width
        let domain = max(data.temperatureCeiling - data.temperatureFloor, 1)
        let rawY = plot.maxY - CGFloat((temperature - data.temperatureFloor) / domain) * plot.height
        let point = CGPoint(x: x, y: min(max(rawY, plot.minY), plot.maxY))
        let band = ThermalPalette.band(for: temperature).color
        let isPinnedOnly = hoveredSample == nil && pinnedSample?.id == sample.id

        let showsDate = data.domainEnd.timeIntervalSince(data.domainStart) > 24 * 3_600 + 1
        let timeText = context.resolve(
            Text("\(sample.timestamp.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened)) · \(sample.mode.uiTitle)")
                .font(.macFanChartTick)
                .foregroundStyle(Color.macFanSecondary)
        )
        var valueString = temperatureUnit.degreesWithUnit(temperature)
        if let low = sample.displayMinimumTemperatureCelsius,
           let high = sample.displayMaximumTemperatureCelsius,
           high - low >= 0.5 {
            valueString += "  ·  \(temperatureUnit.degrees(low))–\(temperatureUnit.degrees(high)) range"
        }
        if let rpm = sample.averageActualRPM { valueString += "  ·  \(Int(rpm.rounded())) RPM" }
        let valueText = context.resolve(
            Text(valueString)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.macFanPrimary)
        )
        // Pinning is the "go deeper" gesture: a pinned point earns a third
        // line — change since the previous sample and the fan target then in
        // force. Hover stays a lean two lines.
        var detailText: GraphicsContext.ResolvedText?
        var detailSize: CGSize = .zero
        if isPinnedOnly, let idx = data.samples.firstIndex(where: { $0.sample.id == sample.id }), idx > 0,
           let previous = data.samples[idx - 1].sample.displayTemperatureCelsius {
            let delta = temperature - previous
            let displayDelta = temperatureUnit == .celsius ? delta : delta * 9 / 5
            let target = sample.averageMacFanTargetRPM.map { "target \(Int($0.rounded())) RPM" }
                ?? sample.averageFirmwareTargetRPM.map { "SMC \(Int($0.rounded())) RPM" }
                ?? "fans on Auto"
            let deltaColor: Color = delta > 0.3 ? .macFanCoral : (delta < -0.3 ? .macFanSky : .macFanMuted)
            detailText = context.resolve(
                Text("\(String(format: "%+.1f", displayDelta))° since previous  ·  \(target)")
                    .font(.macFanChartTick)
                    .foregroundStyle(deltaColor)
            )
            detailSize = detailText!.measure(in: CGSize(width: 260, height: 40))
        }

        let timeSize = timeText.measure(in: CGSize(width: 260, height: 40))
        let valueSize = valueText.measure(in: CGSize(width: 260, height: 40))
        let boxWidth = max(timeSize.width, valueSize.width, detailSize.width) + 18
        let boxHeight: CGFloat = detailText == nil ? 37 : 52
        let boxX = min(max(point.x - boxWidth / 2, plot.minX + 2), plot.maxX - boxWidth - 2)
        let box = CGRect(x: boxX, y: plot.minY + 2, width: boxWidth, height: boxHeight)

        var rule = Path()
        rule.move(to: CGPoint(x: point.x, y: box.maxY + 1))
        rule.addLine(to: CGPoint(x: point.x, y: plot.maxY))
        if isPinnedOnly {
            context.stroke(rule, with: .color(Color.white.opacity(0.5)), lineWidth: 1)
        } else {
            context.stroke(rule, with: .color(Color.macFanPrimary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        let boxPath = Path(roundedRect: box, cornerRadius: 8, style: .continuous)
        context.fill(boxPath, with: .color(Color.macFanRaised.opacity(0.97)))
        context.stroke(boxPath, with: .color(Color.white.opacity(isPinnedOnly ? 0.16 : 0.10)), lineWidth: 0.5)
        context.draw(timeText, at: CGPoint(x: box.midX, y: box.minY + 11), anchor: .center)
        context.draw(valueText, at: CGPoint(x: box.midX, y: box.minY + 26), anchor: .center)
        if let detailText {
            context.draw(detailText, at: CGPoint(x: box.midX, y: box.minY + 41), anchor: .center)
        }

        let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        context.fill(dot, with: .color(band))
        context.stroke(dot, with: .color(Color.white.opacity(0.92)), lineWidth: 1.5)
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: max(1, size.width - left - right), height: max(1, size.height - top - bottom))
    }

    /// Shaded min–max envelope from the aggregated buckets, drawn per segment
    /// so it breaks across the same gaps as the average line.
    private func drawBand(_ context: inout GraphicsContext, point: (SegmentedHistorySample, Double) -> CGPoint) {
        var segments: [Int: [(top: CGPoint, bottom: CGPoint)]] = [:]
        for entry in data.samples {
            guard let low = entry.sample.displayMinimumTemperatureCelsius,
                  let high = entry.sample.displayMaximumTemperatureCelsius else { continue }
            segments[entry.segment, default: []].append((point(entry, high), point(entry, low)))
        }
        for pairs in segments.values where pairs.count > 1 {
            var band = Path()
            band.move(to: pairs[0].top)
            for pair in pairs.dropFirst() { band.addLine(to: pair.top) }
            for pair in pairs.reversed() { band.addLine(to: pair.bottom) }
            band.closeSubpath()
            context.fill(band, with: .color(Color.macFanViolet.opacity(0.055))) // softer elegant band like premium charts
        }
    }

    private func drawThresholds(_ context: inout GraphicsContext, plot: CGRect) {
        guard data.temperatureCeiling >= smartBoostThresholdCelsius else { return }
        let domain = max(data.temperatureCeiling - data.temperatureFloor, 1)
        let y = plot.maxY - CGFloat((smartBoostThresholdCelsius - data.temperatureFloor) / domain) * plot.height
        guard y > plot.minY else { return }
        // Quiet danger-zone wash above the Smart line so "hot territory"
        // reads at a glance without shouting.
        let zone = CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: max(y - plot.minY, 0))
        if zone.height > 1 {
            context.fill(Path(zone), with: .linearGradient(
                Gradient(colors: [Color.macFanCoral.opacity(0.02), Color.macFanAmber.opacity(0.05)]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: y)
            ))
        }
        var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(Color.macFanAmber.opacity(0.36)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        context.draw(
            Text("Smart \(temperatureUnit.degrees(smartBoostThresholdCelsius))").font(.macFanChartTick).foregroundStyle(Color.macFanAmberLight),
            at: CGPoint(x: plot.maxX - 4, y: y - 7),
            anchor: .trailing
        )
    }

    private func drawGrid(_ context: inout GraphicsContext, plot: CGRect, size: CGSize) {
        let domain = max(data.temperatureCeiling - data.temperatureFloor, 1)
        for (index, value) in data.temperatureTicks.enumerated() {
            let fraction = CGFloat((value - data.temperatureFloor) / domain)
            let y = plot.maxY - fraction * plot.height
            var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(Color.white.opacity(index == 0 ? 0.11 : 0.05)), lineWidth: 1)
            context.draw(Text(temperatureUnit.degrees(value)).font(.macFanChartAxis).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }
        drawTimeLabels(&context, plot: plot)
    }

    private func drawTimeLabels(_ context: inout GraphicsContext, plot: CGRect) {
        drawChartTimeAxis(&context, plot: plot, domainStart: data.domainStart, domainEnd: data.domainEnd, format: data.xAxisFormat)
    }

    private func drawEmptyState(_ context: inout GraphicsContext, size: CGSize, plot: CGRect) {
        drawChartPlaceholder(
            &context,
            plot: plot,
            waveColor: Color.macFanViolet.opacity(0.10),
            title: "Collecting thermal samples…",
            subtitle: "The heat curve appears within a minute"
        )
    }

    /// Area fill that inherits the thermal story: the fill under a hot spike
    /// warms exactly where the line does, fading to nothing at the baseline.
    /// One designed coolors ramp (hot → cool) shared by the temperature stroke,
    /// its area fill and the RPM energy line, so both charts read as a single
    /// instrument. The 78° orchid bridge removes the muddy violet→amber jump.
    static let thermalSpectrum: [(celsius: Double, color: Color)] = [
        (96, Color(red: 1.000, green: 0.231, blue: 0.278)),  // critical red  #FF3B47
        (90, Color(red: 1.000, green: 0.361, blue: 0.341)),  // coral         #FF5C57
        (84, Color(red: 0.961, green: 0.651, blue: 0.137)),  // amber         #F5A623
        (78, Color(red: 0.663, green: 0.392, blue: 0.863)),  // orchid bridge #A964DC
        (70, Color(red: 0.431, green: 0.475, blue: 0.961)),  // indigo        #6E79F5
        (58, Color(red: 0.200, green: 0.710, blue: 0.945)),  // sky           #33B5F1
        (44, Color(red: 0.122, green: 0.769, blue: 0.831))   // teal          #1FC4D4
    ]
    private static let thermalAreaOpacity: [Double] = [0.18, 0.16, 0.13, 0.11, 0.09, 0.06, 0.0]

    private func thermalAreaShading(in plot: CGRect) -> GraphicsContext.Shading {
        let domain = max(data.temperatureCeiling - data.temperatureFloor, 1)
        func location(_ celsius: Double) -> CGFloat {
            min(max(CGFloat((data.temperatureCeiling - celsius) / domain), 0), 1)
        }
        let stops = zip(Self.thermalSpectrum, Self.thermalAreaOpacity)
            .map { Gradient.Stop(color: $0.0.color.opacity($0.1), location: location($0.0.celsius)) }
            .sorted { $0.location < $1.location }
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        )
    }

    private func thermalStroke(in plot: CGRect) -> GraphicsContext.Shading {
        let domain = max(data.temperatureCeiling - data.temperatureFloor, 1)
        func location(_ celsius: Double) -> CGFloat {
            min(max(CGFloat((data.temperatureCeiling - celsius) / domain), 0), 1)
        }
        let stops = Self.thermalSpectrum
            .map { Gradient.Stop(color: $0.color, location: location($0.celsius)) }
            .sorted { $0.location < $1.location }
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        )
    }

    private func updateInspection(phase: HoverPhase, width: CGFloat) {
        switch phase {
        case .ended:
            if hoveredSample != nil { hoveredSample = nil }
        case .active(let location):
            guard location.x >= left, location.x <= width - right else {
                if hoveredSample != nil { hoveredSample = nil }
                return
            }
            let first = data.domainStart
            let last = data.domainEnd
            let span = max(last.timeIntervalSince(first), 1)
            let normalized = max(0, min(1, Double(location.x - left) / max(Double(width - left - right), 1)))
            let date = first.addingTimeInterval(span * normalized)
            let nearest = chartNearestSample(to: date, in: data.samples, maximumDistance: data.inspectionTolerance)
            if nearest?.id != hoveredSample?.id { hoveredSample = nearest }
        }
    }
}

struct LightweightRPMCanvas: View {
    let data: ChartData
    @Binding var hoveredSample: TelemetrySample?
    let pinnedSample: TelemetrySample?

    private var inspectedSample: TelemetrySample? { hoveredSample ?? pinnedSample }

    private let left: CGFloat = 48
    private let right: CGFloat = 12
    private let top: CGFloat = 10
    private let bottom: CGFloat = 28

    var body: some View {
        // Same architecture as the thermal canvas: the expensive render is
        // keyed on data only; hover work never touches it.
        ZStack {
            StableChartCanvas(key: RPMCanvasKey(data: data)) { context, size in drawStatic(&context, size: size) }
                .equatable()
                .id(data.domainStart)
                .transition(.opacity)
            if let inspectedSample {
                Canvas { context, size in drawInspection(&context, size: size, sample: inspectedSample) }
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 150)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .ended:
                            if hoveredSample != nil { hoveredSample = nil }
                        case .active(let location):
                            guard location.x >= left, location.x <= proxy.size.width - right else {
                                if hoveredSample != nil { hoveredSample = nil }
                                return
                            }
                            let first = data.domainStart
                            let last = data.domainEnd
                            let span = max(last.timeIntervalSince(first), 1)
                            let usableWidth = max(1, proxy.size.width - left - right)
                            let normalized = max(0, min(1, Double(location.x - left) / Double(usableWidth)))
                            let date = first.addingTimeInterval(span * normalized)
                            let nearest = chartNearestSample(to: date, in: data.samples, maximumDistance: data.inspectionTolerance)
                            if nearest?.id != hoveredSample?.id { hoveredSample = nearest }
                        }
                    }
            }
        }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: max(1, size.width - left - right), height: max(1, size.height - top - bottom))
    }

    private func drawStatic(_ context: inout GraphicsContext, size: CGSize) {
        let plot = plotRect(size)
        for (index, rpmValue) in data.rpmTicks.enumerated() {
            let fraction = CGFloat(rpmValue / max(data.rpmCeiling, 1))
            let yy = plot.maxY - fraction * plot.height
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: yy))
            line.addLine(to: CGPoint(x: plot.maxX, y: yy))
            context.stroke(line, with: .color(Color.white.opacity(index == 0 ? 0.11 : 0.05)), lineWidth: 1)
            let label = rpmValue >= 1_000
                ? String(format: "%.1fk", rpmValue / 1_000).replacingOccurrences(of: ".0k", with: "k")
                : "\(Int(rpmValue.rounded()))"
            context.draw(
                Text(label).font(.macFanChartAxis).foregroundStyle(Color.macFanMuted.opacity(0.92)),
                at: CGPoint(x: plot.minX - 8, y: yy),
                anchor: .trailing
            )
        }
        drawChartTimeAxis(&context, plot: plot, domainStart: data.domainStart, domainEnd: data.domainEnd, format: data.xAxisFormat)

        let entries = data.samples
        guard !entries.isEmpty else {
            drawChartPlaceholder(
                &context,
                plot: plot,
                waveColor: Color.macFanCyan.opacity(0.10),
                title: "Waiting for fan telemetry…",
                subtitle: "Actual speed and targets plot here"
            )
            return
        }
        let first = data.domainStart
        let span = max(data.domainEnd.timeIntervalSince(first), 1)
        func x(_ date: Date) -> CGFloat { plot.minX + CGFloat(date.timeIntervalSince(first) / span) * plot.width }
        func y(_ rpm: Double) -> CGFloat {
            min(max(plot.maxY - CGFloat(rpm / max(data.rpmCeiling, 1)) * plot.height, plot.minY), plot.maxY)
        }

        // The actual line carries the fan-energy identity: it is the cool→violet
        // subrange of the shared thermal spectrum (violet #7466F1 at high effort
        // → indigo → cyan #1EC1DF at idle), so a glance reads both charts as one
        // instrument. High RPM borrows the "warm" hue; idle stays cool.
        let energyShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                Color(red: 0.455, green: 0.400, blue: 0.945),
                Color(red: 0.431, green: 0.475, blue: 0.961),
                Color(red: 0.118, green: 0.755, blue: 0.875)
            ]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        )
        drawSeries(&context, entries: entries, keyPath: \.sample.averageActualRPM, color: .macFanViolet, width: 2.0, x: x, y: y, fillArea: true, shading: energyShading, smoothed: true)
        if data.hasMacFanTargets {
            drawSeries(&context, entries: entries, keyPath: \.sample.averageMacFanTargetRPM, color: .macFanCyan.opacity(0.75), width: 1.5, x: x, y: y)
        }
        if data.hasFirmwareTargets {
            drawSeries(&context, entries: entries, keyPath: \.sample.averageFirmwareTargetRPM, color: .macFanMuted, width: 1.0, x: x, y: y, dashed: true)
        }
    }

    private func drawInspection(_ context: inout GraphicsContext, size: CGSize, sample: TelemetrySample) {
        guard let rpm = sample.averageActualRPM else { return }
        let plot = plotRect(size)
        let span = max(data.domainEnd.timeIntervalSince(data.domainStart), 1)
        let x = plot.minX + CGFloat(sample.timestamp.timeIntervalSince(data.domainStart) / span) * plot.width
        let y = min(max(plot.maxY - CGFloat(rpm / max(data.rpmCeiling, 1)) * plot.height, plot.minY), plot.maxY)
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: plot.minY))
        rule.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(rule, with: .color(Color.macFanPrimary.opacity(0.32)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let dot = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
        context.fill(dot, with: .color(Color.macFanViolet))
        context.stroke(dot, with: .color(Color.white.opacity(0.92)), lineWidth: 1.5)

        // Compact value tag beside the dot — the RPM chart's half of the
        // synchronized crosshair, flipping sides near the trailing edge.
        let tag = context.resolve(
            Text("\(Int(rpm.rounded())) RPM")
                .font(.macFanChartValue)
                .monospacedDigit()
                .foregroundStyle(Color.macFanVioletLight)
        )
        let tagSize = tag.measure(in: CGSize(width: 140, height: 24))
        let boxWidth = tagSize.width + 12
        let boxHeight = tagSize.height + 6
        let flip = x > plot.maxX - boxWidth - 18
        let boxX = flip ? x - 9 - boxWidth : x + 9
        let boxY = min(max(y - boxHeight / 2, plot.minY + 2), plot.maxY - boxHeight - 2)
        let box = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        let boxPath = Path(roundedRect: box, cornerRadius: 5, style: .continuous)
        context.fill(boxPath, with: .color(Color.macFanRaised.opacity(0.95)))
        context.stroke(boxPath, with: .color(Color.white.opacity(0.08)), lineWidth: 0.5)
        context.draw(tag, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    private func drawSeries(
        _ context: inout GraphicsContext,
        entries: [SegmentedHistorySample],
        keyPath: KeyPath<SegmentedHistorySample, Double?>,
        color: Color,
        width: CGFloat,
        x: (Date) -> CGFloat,
        y: (Double) -> CGFloat,
        fillArea: Bool = false,
        dashed: Bool = false,
        shading: GraphicsContext.Shading? = nil,
        smoothed: Bool = false
    ) {
        var segmentPoints: [CGPoint] = []

        func flush() {
            defer { segmentPoints.removeAll(keepingCapacity: true) }
            guard segmentPoints.count > 1 else { return }
            var path = Path()
            if smoothed && segmentPoints.count >= 3 && segmentPoints.count <= 200 {
                addMonotoneCurve(segmentPoints, to: &path)
            } else {
                path.move(to: segmentPoints[0])
                for p in segmentPoints.dropFirst() { path.addLine(to: p) }
            }
            if fillArea {
                var area = path
                area.addLine(to: CGPoint(x: segmentPoints[segmentPoints.count - 1].x, y: y(0)))
                area.addLine(to: CGPoint(x: segmentPoints[0].x, y: y(0)))
                area.closeSubpath()
                let bounds = area.boundingRect
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.11), color.opacity(0)]),
                    startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
                ))
            }
            context.stroke(
                path,
                with: shading ?? .color(color.opacity(0.88)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 4] : [])
            )
        }

        var segment: Int?
        for entry in entries {
            guard let value = entry[keyPath: keyPath] else {
                // A missing target means System/Auto, not a line segment that
                // should bridge to the next override period.
                flush()
                segment = nil
                continue
            }
            let point = CGPoint(x: x(entry.sample.timestamp), y: y(value))
            if segment != entry.segment {
                flush()
                segment = entry.segment
            }
            segmentPoints.append(point)
        }
        flush()
    }
}

/// Shared time axis: five labels at quarter positions with faint vertical
/// gridlines behind the interior three, so time is readable mid-chart. Narrow
/// plots drop the quarter labels rather than colliding.
private func drawChartTimeAxis(
    _ context: inout GraphicsContext,
    plot: CGRect,
    domainStart: Date,
    domainEnd: Date,
    format: Date.FormatStyle
) {
    let span = domainEnd.timeIntervalSince(domainStart)
    let skipInterior = plot.width < 420
    for index in 0...4 {
        if skipInterior && (index == 1 || index == 3) { continue }
        let fraction = CGFloat(index) / 4
        let x = plot.minX + fraction * plot.width
        if index > 0 && index < 4 {
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(Color.white.opacity(0.035)), lineWidth: 1)
        }
        let date = domainStart.addingTimeInterval(span * Double(index) / 4)
        context.draw(
            Text(date.formatted(format)).font(.macFanChartAxis).foregroundStyle(Color.macFanMuted.opacity(0.92)),
            at: CGPoint(x: x, y: plot.maxY + 18),
            anchor: index == 0 ? .leading : (index == 4 ? .trailing : .center)
        )
    }
}

/// Shared premium empty state: the axes stay, a faint dashed placeholder wave
/// suggests the chart to come, and two quiet lines explain the wait. Drawn
/// once into the cached canvas — no shimmer, no timers.
private func drawChartPlaceholder(
    _ context: inout GraphicsContext,
    plot: CGRect,
    waveColor: Color,
    title: String,
    subtitle: String
) {
    var wave = Path()
    let steps = 32
    for index in 0...steps {
        let fraction = Double(index) / Double(steps)
        let x = plot.minX + CGFloat(fraction) * plot.width
        let y = plot.midY + 14 + CGFloat(sin(fraction * .pi * 2.5)) * plot.height * 0.10
        if index == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
    }
    context.stroke(wave, with: .color(waveColor), style: StrokeStyle(lineWidth: 1.5, dash: [2, 5]))
    context.draw(
        Text(title).font(.macFanChartAxis).foregroundStyle(Color.macFanSecondary),
        at: CGPoint(x: plot.midX, y: plot.midY - 18),
        anchor: .center
    )
    context.draw(
        Text(subtitle).font(.macFanChartTick).foregroundStyle(Color.macFanMuted),
        at: CGPoint(x: plot.midX, y: plot.midY - 4),
        anchor: .center
    )
}

/// History is ordered by timestamp. Binary search keeps hover inspection
/// constant-time for the large 7D/30D ranges instead of scanning every bucket.
private func chartNearestSample(
    to date: Date,
    in samples: [SegmentedHistorySample],
    maximumDistance: TimeInterval
) -> TelemetrySample? {
    guard !samples.isEmpty else { return nil }
    var lower = 0
    var upper = samples.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if samples[middle].sample.timestamp < date {
            lower = middle + 1
        } else {
            upper = middle
        }
    }
    let candidates = [lower - 1, lower].filter { samples.indices.contains($0) }
    guard let nearest = candidates.min(by: {
        abs(samples[$0].sample.timestamp.timeIntervalSince(date)) <
        abs(samples[$1].sample.timestamp.timeIntervalSince(date))
    }) else { return nil }
    let distance = abs(samples[nearest].sample.timestamp.timeIntervalSince(date))
    return distance <= maximumDistance ? samples[nearest].sample : nil
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .macFanCaption()
                .foregroundStyle(Color.macFanSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
