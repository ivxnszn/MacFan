import XCTest
@testable import MacFan

final class InsightsEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(offset: TimeInterval, temperature: Double?, rpm: Double? = nil, mode: FanMode = .system) -> TelemetrySample {
        TelemetrySample(
            timestamp: base.addingTimeInterval(offset),
            hottestCelsius: temperature,
            cpuCelsius: temperature,
            gpuCelsius: nil,
            averageActualRPM: rpm,
            averageFirmwareTargetRPM: nil,
            averageMacFanTargetRPM: nil,
            mode: mode,
            capability: .ready
        )
    }

    func testSecondsAboveCountsOnlyHotDwell() {
        let history = [
            sample(offset: 0, temperature: 85),
            sample(offset: 30, temperature: 85),
            sample(offset: 60, temperature: 40)
        ]
        let seconds = InsightsEngine.secondsAbove(80, history: history, now: base.addingTimeInterval(300))
        XCTAssertEqual(seconds, 60, accuracy: 0.001)
    }

    func testSecondsAboveCapsAcrossHistoryGaps() {
        let history = [
            sample(offset: 0, temperature: 85),
            sample(offset: 2 * 3_600, temperature: 40)
        ]
        let seconds = InsightsEngine.secondsAbove(80, history: history, now: base.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(seconds, 30, accuracy: 0.001, "A two-hour hole must not count as two hot hours")
    }

    func testInsightsUseCPUHeadlineInsteadOfHottestDie() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = TelemetrySample(
            timestamp: base,
            hottestCelsius: 96,
            cpuCelsius: 74,
            gpuCelsius: 96,
            averageActualRPM: 3_000,
            averageFirmwareTargetRPM: nil,
            averageMacFanTargetRPM: nil,
            mode: .system,
            capability: .monitoring
        )
        XCTAssertEqual(InsightsEngine.secondsAbove(80, history: [sample], now: base.addingTimeInterval(60)), 0, accuracy: 0.001)
        let insights = InsightsEngine.insights(history: [sample], now: base.addingTimeInterval(60), uptime: nil, thermalStateRaw: nil, swapUsedBytes: nil, hardwareMaximumRPM: nil)
        XCTAssertTrue(insights.contains { $0.id == "peak" && $0.title.contains("74") })
        XCTAssertFalse(insights.contains { $0.id == "time-above" && $0.title.contains("1 min") })
    }

    func testFanResponseLatency() {
        let history = [
            sample(offset: 0, temperature: 60, rpm: 2_500),
            sample(offset: 10, temperature: 82, rpm: 3_000),
            sample(offset: 19, temperature: 84, rpm: 6_500)
        ]
        let delay = InsightsEngine.fanResponseSeconds(history: history, hardwareMaximumRPM: 6_800)
        XCTAssertEqual(delay ?? -1, 9, accuracy: 0.001)
    }

    func testFanResponseNilWhenFansNeverApproachMax() {
        let history = [
            sample(offset: 0, temperature: 82, rpm: 3_000),
            sample(offset: 30, temperature: 84, rpm: 4_000)
        ]
        XCTAssertNil(InsightsEngine.fanResponseSeconds(history: history, hardwareMaximumRPM: 6_800))
    }

    func testFanResponseDoesNotBridgeAHistoryGap() {
        let history = [
            sample(offset: 0, temperature: 84, rpm: 3_000),
            sample(offset: 3_600, temperature: 60, rpm: 6_500)
        ]
        XCTAssertNil(InsightsEngine.fanResponseSeconds(history: history, hardwareMaximumRPM: 6_800))
    }

    func testFanResponseExpiresUntilTheHeatEpisodeCools() {
        let history = [
            sample(offset: 0, temperature: 84, rpm: 3_000),
            sample(offset: 240, temperature: 86, rpm: 4_000),
            sample(offset: 360, temperature: 85, rpm: 6_500)
        ]
        XCTAssertNil(InsightsEngine.fanResponseSeconds(history: history, hardwareMaximumRPM: 6_800))
    }

    func testInsightsOnQuietHistoryAreCalm() {
        let history = [
            sample(offset: 0, temperature: 50, rpm: 2_000),
            sample(offset: 60, temperature: 52, rpm: 2_000)
        ]
        let insights = InsightsEngine.insights(
            history: history,
            now: base.addingTimeInterval(120),
            uptime: 90_000,
            thermalStateRaw: 0,
            swapUsedBytes: 0,
            hardwareMaximumRPM: 6_800
        )
        XCTAssertTrue(insights.contains { $0.id == "time-above" && $0.title.contains("No time above") })
        XCTAssertTrue(insights.contains { $0.id == "throttling" && $0.severity == .info })
        XCTAssertTrue(insights.contains { $0.id == "uptime" && $0.title.contains("1 d 1 h") })
        XCTAssertFalse(insights.contains { $0.id == "fan-response" }, "No spike means no fan-response claim")
        XCTAssertFalse(insights.contains { $0.id == "swap" })
        XCTAssertFalse(insights.contains { $0.id == "control-time" })
    }

    func testControlTimeAndSwapAndThrottlingWarnings() {
        let history = [
            sample(offset: 0, temperature: 82, rpm: 6_500, mode: .max),
            sample(offset: 120, temperature: 60, rpm: 2_500)
        ]
        let insights = InsightsEngine.insights(
            history: history,
            now: base.addingTimeInterval(240),
            uptime: nil,
            thermalStateRaw: 2,
            swapUsedBytes: 5 * 1_073_741_824,
            hardwareMaximumRPM: 6_800
        )
        XCTAssertTrue(insights.contains { $0.id == "throttling" && $0.severity == .warning })
        XCTAssertTrue(insights.contains { $0.id == "control-time" && $0.title.contains("30 s") })
        XCTAssertTrue(insights.contains { $0.id == "swap" && $0.severity == .warning })
        XCTAssertTrue(insights.contains { $0.id == "peak" })
    }

    func testDurationText() {
        XCTAssertEqual(InsightsEngine.durationText(45), "45 s")
        XCTAssertEqual(InsightsEngine.durationText(600), "10 min")
        XCTAssertEqual(InsightsEngine.durationText(2 * 3_600 + 120), "2 h 2 min")
        XCTAssertEqual(InsightsEngine.durationText(26 * 3_600), "1 d 2 h")
    }

    func testExactRollupDurationsOverrideBucketAverage() {
        var rollup = sample(offset: 0, temperature: 72, rpm: 3_000, mode: .system)
        rollup.recordedCoverageSeconds = 300
        rollup.thermalBandDurations = [.violet: 240, .amber: 45, .hot: 15]
        rollup.modeDurations = [.system: 120, .smartBoost: 180]

        XCTAssertEqual(
            InsightsEngine.secondsAbove(80, history: [rollup], now: base.addingTimeInterval(300)),
            60,
            accuracy: 0.001
        )
        let insights = InsightsEngine.insights(
            history: [rollup],
            now: base.addingTimeInterval(300),
            uptime: nil,
            thermalStateRaw: nil,
            swapUsedBytes: nil,
            hardwareMaximumRPM: nil
        )
        XCTAssertTrue(insights.contains { $0.id == "control-time" && $0.title.contains("3 min") })
    }

    func testPeakUsesPreservedCPUExtreme() {
        var rollup = sample(offset: 0, temperature: 68)
        rollup.minCPUCelsius = 62
        rollup.maxCPUCelsius = 87
        let insights = InsightsEngine.insights(
            history: [rollup],
            now: base.addingTimeInterval(300),
            uptime: nil,
            thermalStateRaw: nil,
            swapUsedBytes: nil,
            hardwareMaximumRPM: nil
        )
        XCTAssertTrue(insights.contains { $0.id == "peak" && $0.title.contains("87") })
    }
}
