import XCTest
@testable import MacFan

/// The sampler's adaptive cadence: slow while hidden, fast while visible, and
/// a hard 3-second responsiveness floor whenever MacFan controls the fans.
@MainActor
final class AdaptiveSamplingTests: XCTestCase {
    private func makeModel(controls: any FanControlBackend) -> AppModel {
        let cpu = SensorReading(key: "TC0P", name: "CPU thermal", celsius: 60)
        let snapshot = ThermalSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            hottest: cpu,
            cpu: cpu,
            gpu: nil,
            fans: [FanReading(id: 0, name: "Fan", actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_800, firmwareTargetRPM: nil)],
            sensors: [cpu],
            sourceStatus: "Deterministic unit test"
        )
        return AppModel(
            telemetry: StaticTestTelemetry(snapshot: snapshot),
            historyStore: HistoryStore(inMemory: true),
            controls: controls
        )
    }

    func testHiddenAppSamplesSlowly() {
        let model = makeModel(controls: AlwaysReadyBackend())
        XCTAssertEqual(model.samplerInterval, 15)
    }

    func testVisibleSurfacesSpeedUpSampling() {
        let model = makeModel(controls: AlwaysReadyBackend())

        model.surfaceDidShow(.dashboard)
        XCTAssertEqual(model.samplerInterval, 5)
        XCTAssertTrue(model.isDashboardVisible)

        model.surfaceDidShow(.popover)
        XCTAssertEqual(model.samplerInterval, 2, "The popover expects the snappiest updates")

        model.surfaceDidHide(.popover)
        XCTAssertEqual(model.samplerInterval, 5)

        model.surfaceDidHide(.dashboard)
        XCTAssertEqual(model.samplerInterval, 15)
        XCTAssertFalse(model.isDashboardVisible)
    }

    func testRecordingHeartbeatPreventsPhantomGaps() {
        // Meaningful change records.
        XCTAssertTrue(AppModel.shouldRecord(tempDelta: 0.5, rpmDelta: 0, mode: .system, sinceLastRecord: 5))
        XCTAssertTrue(AppModel.shouldRecord(tempDelta: 0, rpmDelta: 50, mode: .system, sinceLastRecord: 5))
        // Active control always records.
        XCTAssertTrue(AppModel.shouldRecord(tempDelta: 0, rpmDelta: 0, mode: .max, sinceLastRecord: 5))
        // Steady machine: skip briefly, but never longer than the heartbeat —
        // otherwise charts render steady periods as sleep gaps.
        XCTAssertFalse(AppModel.shouldRecord(tempDelta: 0.05, rpmDelta: 5, mode: .system, sinceLastRecord: 10))
        XCTAssertTrue(AppModel.shouldRecord(tempDelta: 0.05, rpmDelta: 5, mode: .system, sinceLastRecord: 30))
    }

    func testActiveControlModeKeepsResponsivenessFloorWhileHidden() async {
        let model = makeModel(controls: AlwaysReadyBackend())
        await model.refresh()
        for _ in 0..<100 where model.capability != .ready {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.activate(.max)
        for _ in 0..<100 where model.activeMode != .max {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.activeMode, .max)
        XCTAssertEqual(model.samplerInterval, 3, "Control modes must never fall back to the idle cadence")
    }

    func testStoppingCancelsAnInFlightRefreshBeforeItPublishes() async {
        let telemetry = BlockingTestTelemetry(snapshot: testSnapshot(at: .now))
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: telemetry, historyStore: store, controls: AlwaysReadyBackend())

        model.start()
        await telemetry.waitUntilSnapshotStarts()
        model.stop()
        await telemetry.releaseSnapshot()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(model.snapshot.cpu, "A stopped sampler must not publish a late telemetry reply")
        let refreshCallCount = await telemetry.snapshotCallCount()
        XCTAssertEqual(refreshCallCount, 1)
        await store.close()
    }

    func testStoppingCancelsStoredSleepWithoutRestartingSampler() async {
        let telemetry = CountingTestTelemetry(snapshot: testSnapshot(at: .now))
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: telemetry, historyStore: store, controls: AlwaysReadyBackend())

        model.start()
        for _ in 0..<100 where model.snapshot.cpu == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.snapshot.cpu)
        model.stop()
        // A visibility wake after stop must not resurrect the cancelled loop.
        model.surfaceDidShow(.dashboard)
        try? await Task.sleep(nanoseconds: 40_000_000)

        let sleepingCallCount = await telemetry.snapshotCallCount()
        XCTAssertEqual(sleepingCallCount, 1)
        _ = await model.dailyHistory()
        await store.close()
    }

    func testSurfaceOpenAndRangeChangeForceIndependentCorrectReloads() async {
        let now = Date.now
        let store = HistoryStore(inMemory: true)
        await store.record(historySample(at: now.addingTimeInterval(-2 * 60 * 60), temperature: 54))
        await store.record(historySample(at: now.addingTimeInterval(-10 * 60), temperature: 64))
        let model = AppModel(
            telemetry: StaticTestTelemetry(snapshot: testSnapshot(at: now)),
            historyStore: store,
            controls: AlwaysReadyBackend()
        )

        model.surfaceDidShow(.dashboard)
        for _ in 0..<100 where model.history.count != 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.history.count, 1)
        XCTAssertTrue(model.thermalTrail.isEmpty, "Dashboard reloads must not query/publish the popover trail")

        model.surfaceDidShow(.popover)
        for _ in 0..<100 where model.thermalTrail.count != 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.thermalTrail.count, 1)

        model.selectedRange = .sixHours
        for _ in 0..<100 where model.history.count != 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.history.count, 2, "Changing range must replace any stale in-flight 1H result")

        model.surfaceDidHide(.dashboard)
        XCTAssertFalse(model.isDashboardVisible)
        model.surfaceDidHide(.popover)
        await store.close()
    }

    private func testSnapshot(at timestamp: Date) -> ThermalSnapshot {
        let cpu = SensorReading(key: "TC0P", name: "CPU thermal", celsius: 60)
        return ThermalSnapshot(
            timestamp: timestamp,
            hottest: cpu,
            cpu: cpu,
            gpu: nil,
            fans: [FanReading(id: 0, name: "Fan", actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_800, firmwareTargetRPM: nil)],
            sensors: [cpu],
            sourceStatus: "Deterministic unit test"
        )
    }

    private func historySample(at timestamp: Date, temperature: Double) -> TelemetrySample {
        TelemetrySample(
            timestamp: timestamp,
            hottestCelsius: temperature,
            cpuCelsius: temperature,
            gpuCelsius: nil,
            averageActualRPM: 3_000,
            averageFirmwareTargetRPM: nil,
            averageMacFanTargetRPM: nil,
            mode: .system,
            capability: .monitoring
        )
    }
}

private actor AlwaysReadyBackend: FanControlBackend {
    func capability() async -> ControlCapability { .ready }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        switch mode {
        case .max:
            .accepted(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.maximumRPM) }))
        case .expert:
            .accepted(targets)
        case .system, .smartBoost:
            .accepted([:])
        }
    }

    func restoreSystem() async -> ControlResult { .accepted([:]) }
}

private actor StaticTestTelemetry: ThermalTelemetryProviding {
    private let current: ThermalSnapshot

    init(snapshot: ThermalSnapshot) {
        current = snapshot
    }

    func snapshot() async -> ThermalSnapshot { current }
    func resetAfterWake() async {}
}

private actor CountingTestTelemetry: ThermalTelemetryProviding {
    private let current: ThermalSnapshot
    private var calls = 0

    init(snapshot: ThermalSnapshot) { current = snapshot }

    func snapshot() async -> ThermalSnapshot {
        calls += 1
        return current
    }

    func resetAfterWake() async {}
    func snapshotCallCount() -> Int { calls }
}

private actor BlockingTestTelemetry: ThermalTelemetryProviding {
    private let current: ThermalSnapshot
    private var calls = 0
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: ThermalSnapshot) { current = snapshot }

    func snapshot() async -> ThermalSnapshot {
        calls += 1
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return current
    }

    func resetAfterWake() async {}

    func waitUntilSnapshotStarts() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseSnapshot() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshotCallCount() -> Int { calls }
}
