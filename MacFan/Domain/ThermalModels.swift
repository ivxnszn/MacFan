import Foundation

enum FanMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case system
    case smartBoost
    case max
    case expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .smartBoost: "Smart Boost"
        case .max: "Max"
        case .expert: "Expert"
        }
    }

    var subtitle: String {
        switch self {
        case .system: "macOS decides"
        case .smartBoost: "Heat-aware max"
        case .max: "Full cooling"
        case .expert: "Manual curve"
        }
    }
}

enum ControlCapability: String, Codable, Equatable, Sendable {
    case monitoring
    case helperUnavailable
    case externalController
    case firmwareLimited
    case ready

    var title: String {
        switch self {
        case .monitoring: "Monitoring"
        case .helperUnavailable: "Helper unavailable"
        case .externalController: "External controller"
        case .firmwareLimited: "Firmware limited"
        case .ready: "Control ready"
        }
    }

    var detail: String {
        switch self {
        case .monitoring:
            "Reading sensors locally. Fan control (tweaking speeds) is disabled."
        case .helperUnavailable:
            "The MacFan helper (needed for fan control) is not installed or not responding. Install it to tweak fans."
        case .externalController:
            "Another fan control app’s helper is installed (e.g. Macs Fan Control). MacFan stays in monitoring mode to avoid conflict."
        case .firmwareLimited:
            "Hardware preflight or safety verification failed on this Mac/firmware. Control not available."
        case .ready:
            "Fan control has passed its hardware preflight. Full tweaking available."
        }
    }

    var canControl: Bool { self == .ready }
    var isMonitoringOnly: Bool { !canControl }

    /// Short label used in headers / status: "Monitoring only", "Checking…", or empty for ready.
    var monitorLabel: String {
        switch self {
        case .ready: ""
        case .monitoring: "Checking…"
        default: "Monitoring only"
        }
    }

    /// Precise reason the user is limited to monitoring (no control modes).
    var whyMessage: String {
        switch self {
        case .monitoring:
            "Detecting control availability on this Mac."
        case .helperUnavailable:
            "No MacFan helper installed (or it is stopped/not responding)."
        case .externalController:
            "External fan controller detected (its helper is present)."
        case .firmwareLimited:
            "This Mac’s firmware or hardware safety preflight did not pass."
        case .ready:
            ""
        }
    }

    /// Plain-language meaning of being in this state.
    var whatItMeans: String {
        switch self {
        case .ready:
            "Full control (Smart Boost, Max, Expert) is available. Automatic safety restore on quit."
        default:
            "Temperatures, charts, and history work normally. You cannot tweak fan speeds, Smart Boost, Max, Cool Burst, or manual curves."
        }
    }

    /// Concrete steps to leave monitor-only mode.
    var howToFix: String {
        switch self {
        case .helperUnavailable:
            "Use the Install/Repair helper button below. It runs a local installer in Terminal (one admin password prompt)."
        case .externalController:
            "Quit and uninstall the other fan control app + its helper, then Install/Repair MacFan’s helper."
        case .firmwareLimited:
            "Try Install/Repair helper to re-run preflight. On some Macs/firmware only monitoring is supported."
        case .monitoring:
            "Wait a moment; this state is transient at launch."
        case .ready:
            ""
        }
    }

    /// Button label for the primary fix action.
    var actionLabel: String {
        switch self {
        case .externalController: "Remove other controller & repair"
        default: "Install or repair helper"
        }
    }

    /// Short reason label for badges and status rows.
    var shortReason: String {
        switch self {
        case .helperUnavailable: "No helper"
        case .externalController: "External controller"
        case .firmwareLimited: "Firmware limited"
        case .monitoring: "Detecting…"
        case .ready: "Ready"
        }
    }

    /// SF Symbol name for the capability state.
    var statusIcon: String {
        switch self {
        case .monitoring: "ellipsis.circle"
        case .helperUnavailable: "lock.slash"
        case .externalController: "exclamationmark.triangle"
        case .firmwareLimited: "shield.slash"
        case .ready: "checkmark.shield"
        }
    }
}

enum SmartBoostStatus: String, Codable, Equatable, Sendable {
    case inactive
    case armed
    case boosting

    var title: String {
        switch self {
        case .inactive: "Off"
        case .armed: "Armed"
        case .boosting: "Boosting"
        }
    }
}

struct FanReading: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    var name: String
    var actualRPM: Double
    var minimumRPM: Double
    var maximumRPM: Double
    /// `F#Tg` is firmware telemetry. It is not a request made by MacFan.
    var firmwareTargetRPM: Double?

    /// The reported maximum remains the strict safety ceiling for future writes.
    /// Some firmware revisions can momentarily report an actual RPM above it, so
    /// visual meters must have a separate display ceiling.
    var displayCeilingRPM: Double {
        max(maximumRPM, actualRPM, firmwareTargetRPM ?? 0, minimumRPM + 1)
    }

    var normalizedActual: Double {
        guard displayCeilingRPM > minimumRPM else { return 0 }
        return min(max((actualRPM - minimumRPM) / (displayCeilingRPM - minimumRPM), 0), 1)
    }

    var normalizedFirmwareTarget: Double? {
        guard let firmwareTargetRPM, displayCeilingRPM > minimumRPM else { return nil }
        return min(max((firmwareTargetRPM - minimumRPM) / (displayCeilingRPM - minimumRPM), 0), 1)
    }

    var hasObservedOverspeed: Bool { actualRPM > maximumRPM * 1.005 }
    var displayActual: String { "\(Int(actualRPM.rounded()))" }
    var displayFirmwareTarget: String { firmwareTargetRPM.map { "\(Int($0.rounded()))" } ?? "Auto" }
}

struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    let key: String
    var name: String
    var celsius: Double
    var id: String { key }
}

struct TelemetrySample: Identifiable, Codable, Hashable, Sendable {
    var timestamp: Date
    var hottestCelsius: Double?
    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var averageActualRPM: Double?
    /// Firmware-reported fan target (for example `F#Tg`), not a MacFan command.
    var averageFirmwareTargetRPM: Double?
    /// Bucket extremes preserved by history aggregation so short spikes survive
    /// downsampling. Live (unaggregated) samples leave these nil.
    var minCelsius: Double?
    var maxCelsius: Double?
    /// CPU-specific extremes. These intentionally remain separate from
    /// `minCelsius` / `maxCelsius`, which describe the hottest available sensor.
    /// Keeping both prevents a brief CPU spike from disappearing in long-range
    /// history when another die happens to own the headline temperature.
    var minCPUCelsius: Double? = nil
    var maxCPUCelsius: Double? = nil
    var minRPM: Double?
    var maxRPM: Double?
    /// Amount of actually observed time represented by an aggregate. History
    /// caps the contribution of every sample interval, so sleep and telemetry
    /// outages never count as continuous coverage.
    var recordedCoverageSeconds: TimeInterval? = nil
    /// Exact additive durations within `recordedCoverageSeconds`, when supplied
    /// by the history store. Legacy rows leave these values nil rather than
    /// inventing a distribution that was never recorded.
    var modeDurations: [FanMode: TimeInterval]? = nil
    var thermalBandDurations: [ThermalBand: TimeInterval]? = nil
    /// Present only after a future helper verifies a MacFan-issued command.
    var averageMacFanTargetRPM: Double?
    var mode: FanMode
    var capability: ControlCapability

    var id: Date { timestamp }
    var displayTemperatureCelsius: Double? { cpuCelsius ?? hottestCelsius }
    var displayMinimumTemperatureCelsius: Double? {
        cpuCelsius != nil ? (minCPUCelsius ?? cpuCelsius) : (minCelsius ?? hottestCelsius)
    }
    var displayMaximumTemperatureCelsius: Double? {
        cpuCelsius != nil ? (maxCPUCelsius ?? cpuCelsius) : (maxCelsius ?? hottestCelsius)
    }

    static let empty = TelemetrySample(
        timestamp: .now,
        hottestCelsius: nil,
        cpuCelsius: nil,
        gpuCelsius: nil,
        averageActualRPM: nil,
        averageFirmwareTargetRPM: nil,
        averageMacFanTargetRPM: nil,
        mode: .system,
        capability: .monitoring
    )
}

struct ThermalSnapshot: Sendable {
    var timestamp: Date
    var hottest: SensorReading?
    var cpu: SensorReading?
    var gpu: SensorReading?
    var fans: [FanReading]
    var sensors: [SensorReading]
    var sourceStatus: String
    var displayTemperature: SensorReading? { cpu ?? hottest }

    /// UI updates do not need to follow sub-degree sensor noise or single-RPM
    /// tachometer jitter. Raw snapshots are still used for history/control;
    /// this gate only prevents SwiftUI invalidation when the presentation is
    /// visually unchanged.
    func isVisuallyEquivalent(to other: ThermalSnapshot) -> Bool {
        func temperatureBucket(_ value: Double) -> Int { Int((value * 2).rounded()) }
        func sensorMatches(_ lhs: SensorReading?, _ rhs: SensorReading?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                true
            case let (lhs?, rhs?):
                lhs.key == rhs.key &&
                lhs.name == rhs.name &&
                temperatureBucket(lhs.celsius) == temperatureBucket(rhs.celsius)
            default:
                false
            }
        }

        guard sourceStatus == other.sourceStatus,
              sensors.count == other.sensors.count,
              fans.count == other.fans.count,
              sensorMatches(cpu, other.cpu),
              sensorMatches(gpu, other.gpu),
              sensorMatches(hottest, other.hottest) else { return false }

        // Fan discovery order is not a visual change. Stable identity, hardware
        // limits, labels and presentation-bucketed live values are.
        let lhsFans = fans.sorted { $0.id < $1.id }
        let rhsFans = other.fans.sorted { $0.id < $1.id }
        return zip(lhsFans, rhsFans).allSatisfy {
            $0.0.id == $0.1.id &&
            $0.0.name == $0.1.name &&
            $0.0.minimumRPM == $0.1.minimumRPM &&
            $0.0.maximumRPM == $0.1.maximumRPM &&
            Int(($0.0.actualRPM / 25).rounded()) == Int(($0.1.actualRPM / 25).rounded()) &&
            Int((($0.0.firmwareTargetRPM ?? -1) / 25.0).rounded()) == Int((($0.1.firmwareTargetRPM ?? -1) / 25.0).rounded())
        }
    }

    var headlineTitle: String {
        cpu != nil ? "CPU temperature" : "Fallback thermal sensor"
    }

    // Centralized lightweight averages to avoid repeated map/reduce across UI + history
    var averageActualRPM: Double? {
        fans.isEmpty ? nil : fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
    }
    var averageFirmwareTargetRPM: Double? {
        let targets = fans.compactMap(\.firmwareTargetRPM)
        return targets.isEmpty ? nil : targets.reduce(0, +) / Double(targets.count)
    }

    static let unavailable = ThermalSnapshot(
        timestamp: .now,
        hottest: nil,
        cpu: nil,
        gpu: nil,
        fans: [],
        sensors: [],
        sourceStatus: "Looking for Apple SMC telemetry…"
    )

    func sample(mode: FanMode, capability: ControlCapability, verifiedMacFanTargets: [Int: Double] = [:]) -> TelemetrySample {
        let macFanTargets = fans.compactMap { verifiedMacFanTargets[$0.id] }
        let macFanTarget = macFanTargets.isEmpty ? nil : macFanTargets.reduce(0, +) / Double(macFanTargets.count)
        return TelemetrySample(
            timestamp: timestamp,
            hottestCelsius: hottest?.celsius,
            cpuCelsius: cpu?.celsius,
            gpuCelsius: gpu?.celsius,
            averageActualRPM: averageActualRPM,
            averageFirmwareTargetRPM: averageFirmwareTargetRPM,
            averageMacFanTargetRPM: macFanTarget,
            mode: mode,
            capability: capability
        )
    }
}

struct FanCurvePoint: Codable, Hashable, Sendable, Identifiable {
    var temperature: Double
    var rpm: Double
    var id: Double { temperature }
}

struct FanCurve: Codable, Hashable, Sendable {
    var points: [FanCurvePoint]

    func validated(minimumRPM: Double, maximumRPM: Double, thermalCeiling: Double = 95) -> FanCurve {
        let safeMinimum = minimumRPM.isFinite ? max(minimumRPM, 0) : 0
        let safeMaximum = maximumRPM.isFinite ? max(maximumRPM, safeMinimum) : safeMinimum
        let safeCeiling = thermalCeiling.isFinite ? max(thermalCeiling, 30) : 95

        // Treat curve data as untrusted even though it normally originates in our UI.
        // Coalescing after clamping also handles distinct out-of-range points that both
        // land on the 30 C or ceiling breakpoint. At a duplicate temperature, retain
        // the faster value; cooling is the conservative resolution.
        var rpmByTemperature: [Double: Double] = [:]
        for point in points where point.temperature.isFinite && point.rpm.isFinite {
            let temperature = min(max(point.temperature, 30), safeCeiling)
            let rpm = min(max(point.rpm, safeMinimum), safeMaximum)
            rpmByTemperature[temperature] = max(rpmByTemperature[temperature] ?? safeMinimum, rpm)
        }

        var result = rpmByTemperature
            .map { FanCurvePoint(temperature: $0.key, rpm: $0.value) }
            .sorted { $0.temperature < $1.temperature }

        // A cooling curve must never request a slower fan as temperature rises.
        var previousRPM = safeMinimum
        for index in result.indices {
            result[index].rpm = max(result[index].rpm, previousRPM)
            previousRPM = result[index].rpm
        }

        if result.last?.temperature ?? 0 < safeCeiling {
            result.append(FanCurvePoint(temperature: safeCeiling, rpm: safeMaximum))
        } else if !result.isEmpty {
            result[result.count - 1].rpm = safeMaximum
        } else {
            result = [FanCurvePoint(temperature: safeCeiling, rpm: safeMaximum)]
        }
        return FanCurve(points: result)
    }

    func target(at temperature: Double, minimumRPM: Double, maximumRPM: Double, thermalCeiling: Double = 95) -> Double {
        let safe = validated(minimumRPM: minimumRPM, maximumRPM: maximumRPM, thermalCeiling: thermalCeiling).points
        guard let first = safe.first else { return maximumRPM }
        guard temperature > first.temperature else { return first.rpm }

        for (lower, upper) in zip(safe, safe.dropFirst()) where temperature <= upper.temperature {
            let fraction = (temperature - lower.temperature) / max(upper.temperature - lower.temperature, 0.001)
            return lower.rpm + (upper.rpm - lower.rpm) * fraction
        }
        return safe.last?.rpm ?? maximumRPM
    }
}

enum ThermalPalette {
    /// Canonical thermal boundaries shared by UI color mapping and history
    /// classification. Keeping the values here prevents chart bands, insights,
    /// and persisted duration summaries from drifting apart over time.
    static let indigoMinimum = 56.0
    static let violetMinimum = 70.0
    static let amberMinimum = 80.0
    static let hotMinimum = 85.0

    static func band(for celsius: Double?) -> ThermalBand {
        guard let celsius else { return .muted }
        switch celsius {
        case ..<indigoMinimum: return .cool
        case indigoMinimum..<violetMinimum: return .indigo
        case violetMinimum..<amberMinimum: return .violet
        case amberMinimum..<hotMinimum: return .amber
        default: return .hot
        }
    }
}

enum ThermalBand: String, CaseIterable, Codable, Hashable, Sendable {
    case muted, cool, indigo, violet, amber, hot

    var label: String {
        switch self {
        case .muted: "Waiting"
        case .cool: "Cool"
        case .indigo: "Balanced"
        case .violet: "Warm"
        case .amber: "Elevated"
        case .hot: "Hot"
        }
    }
}
