import XCTest
@testable import MacFan

final class MacFanTests: XCTestCase {
    func testSmartBoostStartsAtThreshold() {
        var engine = SmartBoostEngine(policy: SmartBoostPolicy(triggerCelsius: 85, cooldownDelta: 10, cooldownHold: 60))
        XCTAssertFalse(engine.update(temperature: 84.9, at: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(engine.update(temperature: 85, at: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(engine.isBoosting)
    }

    func testSmartBoostWaitsForCooldownHold() {
        var engine = SmartBoostEngine(policy: SmartBoostPolicy(triggerCelsius: 85, cooldownDelta: 10, cooldownHold: 60))
        XCTAssertTrue(engine.update(temperature: 90, at: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 30)))
        XCTAssertTrue(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 89)))
        XCTAssertFalse(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 90)))
    }

    func testSmartBoostFailsSafeWhenTemperatureDisappears() {
        var engine = SmartBoostEngine(policy: SmartBoostPolicy(triggerCelsius: 85, cooldownDelta: 10, cooldownHold: 60))
        XCTAssertTrue(engine.update(temperature: 90, at: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(engine.update(temperature: nil, at: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(engine.isBoosting)
    }

    func testSmartBoostCooldownHoldRestartsWhenTemperatureRebounds() {
        var engine = SmartBoostEngine(policy: SmartBoostPolicy(triggerCelsius: 85, cooldownDelta: 10, cooldownHold: 60))
        XCTAssertTrue(engine.update(temperature: 90, at: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 10)))
        XCTAssertTrue(engine.update(temperature: 76, at: Date(timeIntervalSince1970: 50)))
        XCTAssertTrue(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 60)))
        XCTAssertTrue(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 119)))
        XCTAssertFalse(engine.update(temperature: 70, at: Date(timeIntervalSince1970: 120)))
    }

    func testSmartBoostInvalidPolicyFailsSafe() {
        var engine = SmartBoostEngine(policy: SmartBoostPolicy(triggerCelsius: .nan, cooldownDelta: 10, cooldownHold: 60))
        XCTAssertFalse(engine.update(temperature: 90, at: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(engine.isBoosting)
    }

    func testCurveIsClampedAndEndsAtMaximum() {
        let curve = FanCurve(points: [
            FanCurvePoint(temperature: 20, rpm: 100),
            FanCurvePoint(temperature: 97, rpm: 99_999)
        ])
        let safe = curve.validated(minimumRPM: 2_000, maximumRPM: 6_800)
        XCTAssertEqual(safe.points.first?.temperature, 30)
        XCTAssertEqual(safe.points.first?.rpm, 2_000)
        XCTAssertEqual(safe.points.last?.temperature, 95)
        XCTAssertEqual(safe.points.last?.rpm, 6_800)
    }

    func testThermalPaletteBands() {
        XCTAssertEqual(ThermalPalette.band(for: 55), .cool)
        XCTAssertEqual(ThermalPalette.band(for: 56), .indigo)
        XCTAssertEqual(ThermalPalette.band(for: 80), .amber)
        XCTAssertEqual(ThermalPalette.band(for: 85), .hot)
    }

    func testFanReadingNormalizesToHardwareBounds() {
        let fan = FanReading(id: 0, name: "Left", actualRPM: 4_500, minimumRPM: 2_000, maximumRPM: 7_000, firmwareTargetRPM: nil)
        XCTAssertEqual(fan.normalizedActual, 0.5, accuracy: 0.001)
    }

    func testFanMeterSeparatesReportedMaximumFromObservedOverspeed() {
        let fan = FanReading(id: 1, name: "Right", actualRPM: 6_890, minimumRPM: 2_317, maximumRPM: 6_800, firmwareTargetRPM: 6_800)
        XCTAssertTrue(fan.hasObservedOverspeed)
        XCTAssertEqual(fan.displayCeilingRPM, 6_890)
        XCTAssertEqual(fan.normalizedActual, 1, accuracy: 0.001)
    }

    func testCurveInterpolatesAndPinsTopPoint() {
        let curve = FanCurve(points: [
            FanCurvePoint(temperature: 30, rpm: 2_000),
            FanCurvePoint(temperature: 80, rpm: 5_000)
        ])
        XCTAssertEqual(curve.target(at: 55, minimumRPM: 2_000, maximumRPM: 6_800), 3_500, accuracy: 0.001)
        XCTAssertEqual(curve.target(at: 95, minimumRPM: 2_000, maximumRPM: 6_800), 6_800, accuracy: 0.001)
    }

    func testCurveValidationProducesOnlyFiniteBoundedPoints() {
        let curve = FanCurve(points: [
            FanCurvePoint(temperature: .nan, rpm: .nan),
            FanCurvePoint(temperature: -.infinity, rpm: -.infinity),
            FanCurvePoint(temperature: .infinity, rpm: .infinity)
        ])
        let safe = curve.validated(minimumRPM: 2_000, maximumRPM: 6_800)

        XCTAssertFalse(safe.points.isEmpty)
        XCTAssertTrue(safe.points.allSatisfy { $0.temperature.isFinite && $0.rpm.isFinite })
        XCTAssertTrue(safe.points.allSatisfy { (30...95).contains($0.temperature) })
        XCTAssertTrue(safe.points.allSatisfy { (2_000...6_800).contains($0.rpm) })
        XCTAssertEqual(safe.points.last?.temperature, 95)
        XCTAssertEqual(safe.points.last?.rpm, 6_800)
    }

    func testCurveValidationCoalescesDuplicateTemperaturePoints() {
        let curve = FanCurve(points: [
            FanCurvePoint(temperature: 45, rpm: 3_000),
            FanCurvePoint(temperature: 45, rpm: 4_000),
            FanCurvePoint(temperature: 75, rpm: 5_500)
        ])
        let safe = curve.validated(minimumRPM: 2_000, maximumRPM: 6_800)

        let temperatures = safe.points.map(\.temperature)
        XCTAssertEqual(Set(temperatures).count, temperatures.count, "A curve must not contain ambiguous duplicate temperature breakpoints")
        XCTAssertTrue(zip(temperatures, temperatures.dropFirst()).allSatisfy(<))
        XCTAssertEqual(safe.points.first(where: { $0.temperature == 45 })?.rpm, 4_000, "The safer, faster duplicate target should win")
        let rpms = safe.points.map(\.rpm)
        XCTAssertTrue(zip(rpms, rpms.dropFirst()).allSatisfy(<=), "A cooling curve must not slow a fan as temperature rises")
    }

    func testHistoryRollsOldSamplesAndKeepsRecentDataInLongRange() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macfan-history-\(UUID().uuidString).sqlite")
        let store = HistoryStore(fileURL: url)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-26 * 60 * 60)

        await store.record(TelemetrySample(timestamp: old, hottestCelsius: 68, cpuCelsius: 66, gpuCelsius: nil, averageActualRPM: 3_100, averageFirmwareTargetRPM: 3_200, averageMacFanTargetRPM: nil, mode: .system, capability: .monitoring))
        await store.record(TelemetrySample(timestamp: now, hottestCelsius: 72, cpuCelsius: 70, gpuCelsius: nil, averageActualRPM: 4_100, averageFirmwareTargetRPM: 4_200, averageMacFanTargetRPM: 4_300, mode: .expert, capability: .ready))

        let history = await store.samples(for: .week, now: now)
        XCTAssertGreaterThanOrEqual(history.count, 2)
        XCTAssertTrue(history.contains { abs($0.timestamp.timeIntervalSince(old)) < 3_600 })
        XCTAssertTrue(history.contains { abs($0.timestamp.timeIntervalSince(now)) < 900 })

        await store.close()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    func testHistoryPersistsModeCapabilityAndUsesTimestampedTrail() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let old = now.addingTimeInterval(-91 * 60)
        let recent = now.addingTimeInterval(-45 * 60)

        await store.record(TelemetrySample(timestamp: old, hottestCelsius: 61, cpuCelsius: 61, gpuCelsius: nil, averageActualRPM: 2_900, averageFirmwareTargetRPM: nil, averageMacFanTargetRPM: nil, mode: .system, capability: .monitoring))
        await store.record(TelemetrySample(timestamp: recent, hottestCelsius: 84, cpuCelsius: 84, gpuCelsius: nil, averageActualRPM: 6_600, averageFirmwareTargetRPM: 6_700, averageMacFanTargetRPM: 6_700, mode: .max, capability: .ready))

        let trail = await store.thermalTrail(now: now)
        XCTAssertEqual(trail.count, 1)
        XCTAssertEqual(trail.first?.mode, .max)
        XCTAssertEqual(trail.first?.capability, .ready)
        XCTAssertEqual(trail.first?.averageMacFanTargetRPM, 6_700)
        await store.close()
    }

    func testHistoryRollupDoesNotReplacePartialSegmentsOfTheSameHour() async {
        let store = HistoryStore(inMemory: true)
        let hour = floor(1_700_000_000.0 / 3_600) * 3_600
        let first = Date(timeIntervalSince1970: hour + 60)
        let second = Date(timeIntervalSince1970: hour + 3_540)

        await store.record(TelemetrySample(timestamp: first, hottestCelsius: 40, cpuCelsius: 40, gpuCelsius: nil, averageActualRPM: 3_000, averageFirmwareTargetRPM: nil, averageMacFanTargetRPM: nil, mode: .system, capability: .monitoring))
        await store.record(TelemetrySample(timestamp: second, hottestCelsius: 80, cpuCelsius: 60, gpuCelsius: 42, averageActualRPM: 5_000, averageFirmwareTargetRPM: nil, averageMacFanTargetRPM: nil, mode: .max, capability: .ready))

        // Move the rolling cutoff across two different positions inside the old
        // hour, then beyond its end. A partial-hour implementation would replace
        // the first segment with the second and report 80 C instead of 60 C.
        for offset in [hour + 60 + 86_401, hour + 3_540 + 86_401, hour + 3_600 + 86_401] {
            await store.record(TelemetrySample(timestamp: Date(timeIntervalSince1970: offset), hottestCelsius: nil, cpuCelsius: nil, gpuCelsius: nil, averageActualRPM: nil, averageFirmwareTargetRPM: nil, averageMacFanTargetRPM: nil, mode: .system, capability: .monitoring))
        }

        let now = Date(timeIntervalSince1970: hour + 3_600 + 86_401)
        let history = await store.samples(for: .week, now: now)
        let completedHour = history.first { abs($0.timestamp.timeIntervalSince1970 - hour) < 0.5 }
        XCTAssertNotNil(completedHour)
        XCTAssertEqual(completedHour?.hottestCelsius ?? .nan, 60, accuracy: 0.001)
        XCTAssertEqual(completedHour?.cpuCelsius ?? .nan, 50, accuracy: 0.001)
        // Missing GPU readings are ignored rather than treated as 0 °C.
        XCTAssertEqual(completedHour?.gpuCelsius ?? .nan, 42, accuracy: 0.001)
        XCTAssertEqual(completedHour?.averageActualRPM ?? .nan, 4_000, accuracy: 0.001)
        await store.close()
    }
}

final class BatteryTelemetryRulesTests: XCTestCase {
    func testPowerSourceStateDistinguishesAdapterIdle() {
        XCTAssertEqual(BatteryTelemetryRules.flowState(charging: true, onExternalPower: true), .charging)
        XCTAssertEqual(BatteryTelemetryRules.flowState(charging: false, onExternalPower: true), .connectedIdle)
        XCTAssertEqual(BatteryTelemetryRules.flowState(charging: false, onExternalPower: false), .discharging)
        XCTAssertEqual(BatteryTelemetryRules.flowState(charging: false, onExternalPower: nil), .unknown)
    }

    func testSignedBatteryFlowUsesSemanticDirection() {
        XCTAssertEqual(BatteryTelemetryRules.signedWatts(42.5, state: .charging), 42.5)
        XCTAssertEqual(BatteryTelemetryRules.signedWatts(12, state: .discharging), -12)
        XCTAssertEqual(BatteryTelemetryRules.signedWatts(0.1, state: .connectedIdle), 0)
        XCTAssertNil(BatteryTelemetryRules.signedWatts(3, state: .connectedIdle))
        XCTAssertNil(BatteryTelemetryRules.signedWatts(3, state: .unknown))
    }

    func testBatteryTimeRejectsSentinelsAndUnreasonableValues() {
        XCTAssertNil(BatteryTelemetryRules.validMinutes(nil))
        XCTAssertNil(BatteryTelemetryRules.validMinutes(-1))
        XCTAssertNil(BatteryTelemetryRules.validMinutes(0))
        XCTAssertNil(BatteryTelemetryRules.validMinutes(48 * 60 + 1))
        XCTAssertEqual(BatteryTelemetryRules.validMinutes(96), 96)
    }

    func testBatteryTimeMatchesTheConfirmedEnergyDirection() {
        XCTAssertEqual(BatteryTelemetryRules.remainingMinutes(state: .charging, timeToFull: 45, timeToEmpty: 300), 45)
        XCTAssertEqual(BatteryTelemetryRules.remainingMinutes(state: .discharging, timeToFull: 45, timeToEmpty: 300), 300)
        XCTAssertNil(BatteryTelemetryRules.remainingMinutes(state: .connectedIdle, timeToFull: 45, timeToEmpty: 300))
        XCTAssertNil(BatteryTelemetryRules.remainingMinutes(state: .unknown, timeToFull: 45, timeToEmpty: 300))
    }

    func testHealthRequiresRealCapacityData() {
        XCTAssertNil(BatteryTelemetryRules.healthPercent(nominalCapacity: nil, designCapacity: nil))
        XCTAssertNil(BatteryTelemetryRules.healthPercent(nominalCapacity: 5_000, designCapacity: 0))
        XCTAssertEqual(
            BatteryTelemetryRules.healthPercent(nominalCapacity: 5_400, designCapacity: 6_000) ?? -1,
            90,
            accuracy: 0.001
        )
    }
}

final class BatterySessionRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(offset: TimeInterval, state: BatteryFlowState = .charging) -> BatterySessionPoint {
        BatterySessionPoint(
            timestamp: base.addingTimeInterval(offset),
            percent: 50,
            signedWatts: state == .charging ? 20 : -10,
            flowState: state,
            temperatureCelsius: 31
        )
    }

    func testContinuousSamplesStayInOneSegment() {
        XCTAssertFalse(BatterySessionRules.shouldStartNewSegment(previous: point(offset: 0), next: point(offset: 5)))
    }

    func testHiddenWindowGapStartsANewSegment() {
        XCTAssertTrue(BatterySessionRules.shouldStartNewSegment(previous: point(offset: 0), next: point(offset: 20)))
    }

    func testEnergyDirectionChangeStartsANewSegment() {
        XCTAssertTrue(BatterySessionRules.shouldStartNewSegment(
            previous: point(offset: 0, state: .charging),
            next: point(offset: 5, state: .discharging)
        ))
    }
}

final class DashboardChartDataTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func chartSample(
        offset: TimeInterval,
        cpu: Double,
        hottest: Double? = nil,
        rpm: Double? = nil,
        minCPU: Double? = nil,
        maxCPU: Double? = nil,
        coverage: TimeInterval? = nil,
        bands: [ThermalBand: TimeInterval]? = nil
    ) -> TelemetrySample {
        TelemetrySample(
            timestamp: base.addingTimeInterval(offset),
            hottestCelsius: hottest ?? cpu,
            cpuCelsius: cpu,
            gpuCelsius: hottest,
            averageActualRPM: rpm,
            averageFirmwareTargetRPM: nil,
            minCPUCelsius: minCPU,
            maxCPUCelsius: maxCPU,
            recordedCoverageSeconds: coverage,
            thermalBandDurations: bands,
            averageMacFanTargetRPM: nil,
            mode: .system,
            capability: .monitoring
        )
    }

    func testChartCPUEnvelopeDoesNotUseHotterNonCPUSensor() {
        let history = [
            chartSample(offset: 0, cpu: 60, hottest: 96, minCPU: 52, maxCPU: 73, coverage: 30),
            chartSample(offset: 30, cpu: 58, hottest: 94, minCPU: 55, maxCPU: 64, coverage: 30)
        ]
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)

        XCTAssertEqual(data.lowestTemperature, 52)
        XCTAssertEqual(data.highestTemperature, 73)
        XCTAssertEqual(data.peakSample?.timestamp, history[0].timestamp)
        XCTAssertTrue(data.hasTemperatureBand)
    }

    func testChartAverageIsWeightedByRecordedCoverage() {
        let history = [
            chartSample(offset: 0, cpu: 40, coverage: 10),
            chartSample(offset: 10, cpu: 80, coverage: 30)
        ]
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)

        XCTAssertEqual(data.averageTemperature ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(data.recordedCoverageSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(data.coverageFraction, 40 / 3_600, accuracy: 0.000_001)
    }

    func testChartDistributionUsesExactCanonicalBandDurations() {
        let history = [
            chartSample(offset: 0, cpu: 50, coverage: 15, bands: [.cool: 10, .hot: 5]),
            chartSample(offset: 15, cpu: 72, coverage: 15, bands: [.violet: 15])
        ]
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)
        let fractions = Dictionary(uniqueKeysWithValues: data.distributionBins.map { ($0.band, $0.fraction) })

        XCTAssertEqual(fractions[.cool] ?? -1, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(fractions[.violet] ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(fractions[.hot] ?? -1, 1.0 / 6.0, accuracy: 0.001)
        XCTAssertNil(fractions[.amber])
    }

    func testChartFallbackDoesNotCountTelemetryGapAsCoverage() {
        let history = [
            chartSample(offset: 0, cpu: 82),
            chartSample(offset: 600, cpu: 45)
        ]
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)

        XCTAssertEqual(data.recordedCoverageSeconds, 0)
        XCTAssertTrue(data.distributionBins.isEmpty)
        XCTAssertNotEqual(data.samples[0].segment, data.samples[1].segment)
    }

    func testChartAddsOnlyRecordedFanResponseMatch() {
        var history = [
            chartSample(offset: 0, cpu: 82, rpm: 3_000),
            chartSample(offset: 10, cpu: 84, rpm: 6_500)
        ]
        for index in 2..<25 {
            history.append(chartSample(offset: Double(index * 10), cpu: index > 20 ? 83 : 65, rpm: 3_000))
        }
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)

        XCTAssertEqual(data.eventMarkers.count, 1)
        XCTAssertEqual(data.eventMarkers.first?.responseSeconds ?? -1, 10, accuracy: 0.001)
    }

    func testChartAxesUseCleanHumanIntervals() {
        let history = [
            chartSample(offset: 0, cpu: 48, rpm: 3_100),
            chartSample(offset: 30, cpu: 63, rpm: 3_500)
        ]
        let data = ChartData.make(history: history, range: .hour, hardwareMaximumRPM: 6_800)

        XCTAssertEqual(data.temperatureTicks, [40, 45, 50, 55, 60, 65, 70])
        XCTAssertEqual(data.rpmTicks, [0, 2_000, 4_000, 6_000, 8_000])
        XCTAssertEqual(data.temperatureTickStep, 5)
        XCTAssertEqual(data.rpmTickStep, 2_000)
    }

    func testFahrenheitChartAxesRemainCleanInTheDisplayedUnit() {
        let history = [
            chartSample(offset: 0, cpu: 48),
            chartSample(offset: 30, cpu: 63)
        ]
        let data = ChartData.make(
            history: history,
            range: .hour,
            hardwareMaximumRPM: 6_800,
            temperatureUnit: .fahrenheit
        )
        let displayedTicks = data.temperatureTicks.map { Int(TemperatureUnit.fahrenheit.convert($0).rounded()) }

        XCTAssertEqual(displayedTicks, [100, 110, 120, 130, 140, 150, 160])
    }
}
