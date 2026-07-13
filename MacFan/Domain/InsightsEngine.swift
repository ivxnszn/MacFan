import Foundation

struct Insight: Identifiable, Equatable, Sendable {
    enum Severity: Sendable {
        case info
        case notice
        case warning
    }

    let id: String
    let icon: String
    let title: String
    let detail: String
    let severity: Severity
}

struct FanResponseMatch: Equatable, Sendable {
    let start: TelemetrySample
    let response: TelemetrySample

    var seconds: TimeInterval {
        max(0, response.timestamp.timeIntervalSince(start.timestamp))
    }
}

/// Derives human-readable findings from recorded telemetry. Every statement is
/// grounded in samples the app actually stored — nothing is extrapolated.
enum InsightsEngine {
    static let hotThresholdCelsius: Double = 80

    /// Longest dwell inferred when a legacy sample has no exact coverage.
    /// Current history rows carry successor-confirmed coverage; this cap keeps
    /// old data from turning sleep or an outage into a thermal claim.
    private static let dwellCap: TimeInterval = 30

    static func insights(
        history: [TelemetrySample],
        now: Date,
        uptime: TimeInterval?,
        thermalStateRaw: Int?,
        swapUsedBytes: UInt64?,
        hardwareMaximumRPM: Double?,
        unit: TemperatureUnit = .celsius
    ) -> [Insight] {
        var result: [Insight] = []

        if let throttling = throttlingInsight(thermalStateRaw: thermalStateRaw) { result.append(throttling) }
        if let peak = peakInsight(history: history, unit: unit) { result.append(peak) }
        result.append(timeAboveInsight(history: history, now: now, unit: unit))
        if let response = fanResponseInsight(history: history, hardwareMaximumRPM: hardwareMaximumRPM) { result.append(response) }
        if let control = controlTimeInsight(history: history, now: now) { result.append(control) }
        if let swap = swapInsight(swapUsedBytes: swapUsedBytes) { result.append(swap) }
        if let uptime, uptime > 60 {
            result.append(Insight(
                id: "uptime",
                icon: "clock",
                title: "Uptime \(durationText(uptime))",
                detail: "Time since the last macOS boot.",
                severity: .info
            ))
        }
        return result
    }

    /// Seconds spent at or above the threshold, using per-sample dwell capped
    /// so history gaps are never counted.
    static func secondsAbove(
        _ threshold: Double,
        history: [TelemetrySample],
        now: Date
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for (index, sample) in history.enumerated() {
            if abs(threshold - ThermalPalette.amberMinimum) < 0.001,
               let durations = sample.thermalBandDurations {
                total += max(0, durations[.amber] ?? 0) + max(0, durations[.hot] ?? 0)
                continue
            }
            let hot = (sample.displayMaximumTemperatureCelsius ?? -.infinity) >= threshold
            guard hot else { continue }
            total += observedDwell(for: sample, at: index, history: history, now: now)
        }
        return total
    }

    /// Delay between the first sample crossing the hot threshold and the first
    /// subsequent sample with fans at ≥90% of the hardware maximum.
    static func fanResponseSeconds(
        history: [TelemetrySample],
        hardwareMaximumRPM: Double
    ) -> TimeInterval? {
        fanResponseMatch(history: history, hardwareMaximumRPM: hardwareMaximumRPM)?.seconds
    }

    /// Matches a near-maximum fan event only to the same, recent heat episode.
    /// A cooldown, telemetry gap, or five-minute timeout ends the episode so a
    /// later unrelated fan event can never be described as its response.
    static func fanResponseMatch(
        history: [TelemetrySample],
        hardwareMaximumRPM: Double,
        thresholdCelsius: Double = hotThresholdCelsius,
        responseWindow: TimeInterval = 5 * 60
    ) -> FanResponseMatch? {
        guard hardwareMaximumRPM > 0, responseWindow > 0 else { return nil }
        let ordered = history.sorted { $0.timestamp < $1.timestamp }
        let shortDeltas = zip(ordered, ordered.dropFirst())
            .map { pair in pair.1.timestamp.timeIntervalSince(pair.0.timestamp) }
            .filter { $0 > 0 && $0 <= responseWindow }
            .sorted()
        let typicalDelta = shortDeltas.isEmpty ? responseWindow : shortDeltas[shortDeltas.count / 2]
        let maximumObservationGap = min(responseWindow, max(30, typicalDelta * 3))

        var start: TelemetrySample?
        var previous: TelemetrySample?
        var waitForCooldown = false
        for sample in ordered {
            if let previous,
               sample.timestamp.timeIntervalSince(previous.timestamp) > maximumObservationGap {
                start = nil
                waitForCooldown = false
            }

            let temperature = sample.displayMaximumTemperatureCelsius ?? -.infinity
            if temperature < thresholdCelsius - 5 {
                start = nil
                waitForCooldown = false
            }
            if let activeStart = start,
               sample.timestamp.timeIntervalSince(activeStart.timestamp) > responseWindow {
                start = nil
                waitForCooldown = true
            }
            if start == nil, !waitForCooldown, temperature >= thresholdCelsius {
                start = sample
            }

            if let start,
               sample.timestamp.timeIntervalSince(start.timestamp) <= responseWindow,
               let rpm = sample.maxRPM ?? sample.averageActualRPM,
               rpm >= hardwareMaximumRPM * 0.9 {
                return FanResponseMatch(start: start, response: sample)
            }
            previous = sample
        }
        return nil
    }

    private static func throttlingInsight(thermalStateRaw: Int?) -> Insight? {
        guard let thermalStateRaw else { return nil }
        if thermalStateRaw >= 2 {
            return Insight(
                id: "throttling",
                icon: "exclamationmark.triangle.fill",
                title: "macOS is reporting thermal pressure",
                detail: "The system is limiting performance right now (state: \(thermalStateRaw == 3 ? "Critical" : "Serious")).",
                severity: .warning
            )
        }
        return Insight(
            id: "throttling",
            icon: "checkmark.seal",
            title: thermalStateRaw == 1 ? "Mild thermal pressure" : "Thermal pressure nominal",
            detail: thermalStateRaw == 1
                ? "macOS reports a fair thermal state; performance is not yet limited."
                : "macOS reports a nominal thermal state right now.",
            severity: thermalStateRaw == 1 ? .notice : .info
        )
    }

    private static func peakInsight(history: [TelemetrySample], unit: TemperatureUnit) -> Insight? {
        let peak = history.max {
            ($0.displayMaximumTemperatureCelsius ?? -.infinity) < ($1.displayMaximumTemperatureCelsius ?? -.infinity)
        }
        guard let peak, let celsius = peak.displayMaximumTemperatureCelsius else { return nil }
        let time = peak.timestamp.formatted(date: .omitted, time: .shortened)
        return Insight(
            id: "peak",
            icon: "flame",
            title: "Peak \(unit.degreesWithUnit(celsius)) at \(time)",
            detail: celsius >= hotThresholdCelsius
                ? "The hottest recorded moment in the last 24 hours crossed the \(unit.degreesWithUnit(hotThresholdCelsius)) line."
                : "The hottest recorded moment in the last 24 hours stayed under \(unit.degreesWithUnit(hotThresholdCelsius)).",
            severity: celsius >= hotThresholdCelsius ? .notice : .info
        )
    }

    private static func timeAboveInsight(history: [TelemetrySample], now: Date, unit: TemperatureUnit) -> Insight {
        let seconds = secondsAbove(hotThresholdCelsius, history: history, now: now)
        if seconds < 1 {
            return Insight(
                id: "time-above",
                icon: "thermometer.low",
                title: "No time above \(unit.degreesWithUnit(hotThresholdCelsius))",
                detail: "In the recorded last 24 hours the CPU never held \(unit.degreesWithUnit(hotThresholdCelsius)) or more.",
                severity: .info
            )
        }
        return Insight(
            id: "time-above",
            icon: "thermometer.high",
            title: "\(durationText(seconds)) above \(unit.degreesWithUnit(hotThresholdCelsius))",
            detail: "Total recorded time at or above \(unit.degreesWithUnit(hotThresholdCelsius)) in the last 24 hours.",
            severity: .notice
        )
    }

    private static func fanResponseInsight(history: [TelemetrySample], hardwareMaximumRPM: Double?) -> Insight? {
        guard let hardwareMaximumRPM, hardwareMaximumRPM > 0 else { return nil }
        let sawSpike = history.contains { ($0.displayMaximumTemperatureCelsius ?? -.infinity) >= hotThresholdCelsius }
        guard sawSpike else { return nil }
        if let delay = fanResponseSeconds(history: history, hardwareMaximumRPM: hardwareMaximumRPM) {
            return Insight(
                id: "fan-response",
                icon: "fanblades",
                title: "Fans hit near-max \(durationText(delay)) after the spike",
                detail: "Delay between first crossing \(Int(hotThresholdCelsius))°C and fans reaching 90% of their maximum.",
                severity: delay > 120 ? .notice : .info
            )
        }
        return Insight(
            id: "fan-response",
            icon: "fanblades",
            title: "No near-maximum fan event observed",
            detail: "CPU crossed \(Int(hotThresholdCelsius))°C, but recorded fan speed stayed under 90% of maximum. A brief episode may not need full speed.",
            severity: .info
        )
    }

    private static func controlTimeInsight(history: [TelemetrySample], now: Date) -> Insight? {
        var total: TimeInterval = 0
        for (index, sample) in history.enumerated() {
            if let durations = sample.modeDurations {
                total += durations.reduce(0) { partial, entry in
                    entry.key == .system ? partial : partial + max(0, entry.value)
                }
            } else if sample.mode != .system {
                total += observedDwell(for: sample, at: index, history: history, now: now)
            }
        }
        guard total >= 1 else { return nil }
        return Insight(
            id: "control-time",
            icon: "wind",
            title: "MacFan controlled the fans for \(durationText(total))",
            detail: "Recorded time in Smart, Max or Manual mode over the last 24 hours.",
            severity: .info
        )
    }

    private static func swapInsight(swapUsedBytes: UInt64?) -> Insight? {
        guard let swapUsedBytes, swapUsedBytes > 512 * 1_024 * 1_024 else { return nil }
        let gigabytes = Double(swapUsedBytes) / 1_073_741_824
        return Insight(
            id: "swap",
            icon: "memorychip",
            title: String(format: "%.1f GB of swap in use", gigabytes),
            detail: "Sustained swap use can add background I/O and heat.",
            severity: gigabytes > 4 ? .warning : .notice
        )
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min" }
        let hours = total / 3_600
        if hours < 24 { return "\(hours) h \((total % 3_600) / 60) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }

    private static func observedDwell(
        for sample: TelemetrySample,
        at index: Int,
        history: [TelemetrySample],
        now: Date
    ) -> TimeInterval {
        if let coverage = sample.recordedCoverageSeconds { return max(0, coverage) }
        let next = index + 1 < history.count ? history[index + 1].timestamp : now
        return min(max(next.timeIntervalSince(sample.timestamp), 0), dwellCap)
    }

    // MARK: - Data hacking helpers for premium recaps (past agent ideas: band durations, response lag, coverage-weighted stats)
    /// Coverage-weighted average temperature from recorded samples. Uses display CPU temp.
    static func averageTemperature(history: [TelemetrySample]) -> Double? {
        var weightedSum: Double = 0
        var totalCoverage: TimeInterval = 0
        for (index, sample) in history.enumerated() {
            guard let temp = sample.displayTemperatureCelsius else { continue }
            let cov = sample.recordedCoverageSeconds ?? observedDwell(for: sample, at: index, history: history, now: .now)
            guard cov > 0 else { continue }
            weightedSum += temp * cov
            totalCoverage += cov
        }
        guard totalCoverage > 0 else { return nil }
        return weightedSum / totalCoverage
    }

    /// Fraction of recorded time spent in each thermal band. Prefers exact bandDurations when present.
    static func bandDistribution(history: [TelemetrySample]) -> [ThermalBand: Double] {
        var totals: [ThermalBand: TimeInterval] = [:]
        var total: TimeInterval = 0
        for (index, sample) in history.enumerated() {
            if let bandDurs = sample.thermalBandDurations {
                for (band, dur) in bandDurs {
                    totals[band, default: 0] += max(0, dur)
                    total += max(0, dur)
                }
            } else if let temp = sample.displayTemperatureCelsius {
                let cov = sample.recordedCoverageSeconds ?? observedDwell(for: sample, at: index, history: history, now: .now)
                guard cov > 0 else { continue }
                let band = ThermalPalette.band(for: temp)
                totals[band, default: 0] += cov
                total += cov
            }
        }
        guard total > 0 else { return [:] }
        return totals.mapValues { $0 / total }
    }

    /// Simple response correlation score derived from observed fan matches vs heat episodes.
    /// Returns label + severity hint for UI to map to color. Reuses existing fanResponseMatch logic (data hacking for recap).
    static func responseCorrelationLabel(history: [TelemetrySample], hardwareMaximumRPM: Double?) -> (label: String, severity: Insight.Severity, detail: String) {
        guard let maxRPM = hardwareMaximumRPM, maxRPM > 0 else {
            return ("No fan data", .info, "Fan telemetry unavailable for correlation")
        }
        let hotEpisodes = history.filter { ($0.displayMaximumTemperatureCelsius ?? -.infinity) >= hotThresholdCelsius }
        guard !hotEpisodes.isEmpty else {
            return ("Stable cool", .info, "No elevated episodes — excellent baseline")
        }
        if let match = fanResponseMatch(history: history, hardwareMaximumRPM: maxRPM) {
            let lag = match.seconds
            if lag < 45 {
                return ("Fast response", .info, "Fans reached 90% max within \(durationText(lag)) of heat")
            } else if lag < 180 {
                return ("Responsive", .notice, "Lag \(durationText(lag)) — within healthy window")
            } else {
                return ("Delayed response", .notice, "Lag \(durationText(lag)) — consider Smart mode")
            }
        }
        return ("Limited response", .info, "Heat crossed threshold but no near-max fan observed")
    }

    // MARK: - Additional lightweight helpers for richer premium recaps (swing, stability, actionable context)

    /// Observed temperature swing (max - min display CPU) across the history window. Uses extrema when present.
    static func temperatureSwing(history: [TelemetrySample]) -> Double? {
        let mins = history.compactMap(\.displayMinimumTemperatureCelsius)
        let maxs = history.compactMap(\.displayMaximumTemperatureCelsius)
        guard let overallMin = mins.min(), let overallMax = maxs.max(), overallMax > overallMin else { return nil }
        return overallMax - overallMin
    }

    /// Rough count of distinct hot episodes (transitions into >= hot threshold after a cool period). Caps at small number for glance.
    static func hotEpisodeCount(history: [TelemetrySample], threshold: Double = hotThresholdCelsius) -> Int {
        var count = 0
        var inHot = false
        for sample in history.sorted(by: { $0.timestamp < $1.timestamp }) {
            let t = sample.displayMaximumTemperatureCelsius ?? -.infinity
            if t >= threshold {
                if !inHot {
                    count += 1
                    inHot = true
                }
            } else if t < threshold - 3 {
                inHot = false
            }
        }
        return min(count, 9)
    }

    /// Fraction of time considered "cool" (below indigo) for actionable % context.
    static func coolFraction(history: [TelemetrySample]) -> Double {
        let fracs = bandDistribution(history: history)
        let cool = fracs[.cool] ?? 0
        let indigo = fracs[.indigo] ?? 0
        return min(1, cool + indigo * 0.6) // partial credit for balanced
    }
}
