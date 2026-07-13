import XCTest
@testable import MacFan

@MainActor
final class AppModelControlTests: XCTestCase {
    func testSlowCapabilityNeverBlocksLiveTelemetryPublicationOrDuplicatesWork() async {
        let fixture = makeFixture(temperature: 60)
        let backend = BlockingCapabilityBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await backend.waitUntilCapabilityStarts()
        XCTAssertEqual(model.snapshot.cpu?.celsius ?? .nan, 60, accuracy: 0.001)
        XCTAssertEqual(model.capability, .monitoring)

        await fixture.telemetry.update(
            temperature: 74,
            timestamp: fixture.timestamp.addingTimeInterval(10)
        )
        await model.refresh()
        XCTAssertEqual(model.snapshot.cpu?.celsius ?? .nan, 74, accuracy: 0.001)
        let capabilityCalls = await backend.capabilityCallCount()
        XCTAssertEqual(capabilityCalls, 1, "Only one slow capability preflight may exist")

        await backend.releaseCapability()
        await waitForReady(model)
        _ = await model.dailyHistory()
        await store.close()
    }

    func testUnavailableApplyNeverMarksModeActive() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend(
            applyResults: [.unavailable(.firmwareLimited, "Firmware declined the request")]
        )
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.activate(.max)
        await waitForApplyCount(1, backend: backend)
        await waitForPendingModeToClear(model)

        XCTAssertEqual(model.activeMode, .system)
        XCTAssertEqual(model.capability, .firmwareLimited)
        XCTAssertEqual(model.toast, "Firmware declined the request")
        await store.close()
    }

    func testOnlyHelperConfirmedTargetsReachHistory() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.activate(.max)
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.max, model: model)
        XCTAssertEqual(model.activeMode, .max)

        let nextTime = fixture.timestamp.addingTimeInterval(10)
        await fixture.telemetry.update(temperature: 62, timestamp: nextTime)
        await model.refresh()
        let history = await model.dailyHistory()
        let controlled = history.last { $0.mode == .max }

        XCTAssertEqual(controlled?.averageMacFanTargetRPM ?? .nan, 6_900, accuracy: 0.001)
        XCTAssertEqual(controlled?.capability, .ready)
        await store.close()
    }

    func testActiveExpertCurveReappliesWhenTemperatureChangesMeaningfully() async {
        let fixture = makeFixture(temperature: 50)
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.unlockExpert()
        model.expertUsesCurve = true
        model.expertCurves = testCurves
        model.activate(.expert)
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.expert, model: model)
        let first = await backend.applications().last?.targets

        await fixture.telemetry.update(
            temperature: 80,
            timestamp: fixture.timestamp.addingTimeInterval(10)
        )
        await model.refresh()
        await waitForApplyCount(2, backend: backend)
        let applications = await backend.applications()
        let second = applications.last?.targets

        XCTAssertEqual(applications.map(\.mode), [.expert, .expert])
        XCTAssertGreaterThan((second?[0] ?? 0) - (first?[0] ?? 0), 25)
        XCTAssertGreaterThan((second?[1] ?? 0) - (first?[1] ?? 0), 25)
        XCTAssertEqual(model.activeMode, .expert)
        await store.close()
    }

    func testExpertCurveApplyFailureRestoresSystemAndClearsActiveMode() async {
        let fixture = makeFixture(temperature: 50)
        let backend = RecordingControlBackend(applyResults: [
            .accepted([0: 3_500, 1: 3_600]),
            .unavailable(.firmwareLimited, "Target readback failed")
        ])
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.unlockExpert()
        model.expertUsesCurve = true
        model.expertCurves = testCurves
        model.activate(.expert)
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.expert, model: model)

        await fixture.telemetry.update(
            temperature: 80,
            timestamp: fixture.timestamp.addingTimeInterval(10)
        )
        await model.refresh()
        await waitForRestoreCount(1, backend: backend)

        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertEqual(model.capability, .firmwareLimited)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertTrue(model.toast?.contains("Target readback failed") == true)
        await store.close()
    }

    func testExpertCurveLossOfTemperatureFailsSafeToSystem() async {
        let fixture = makeFixture(temperature: 50)
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.unlockExpert()
        model.expertUsesCurve = true
        model.expertCurves = testCurves
        model.activate(.expert)
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.expert, model: model)

        await fixture.telemetry.update(
            temperature: nil,
            timestamp: fixture.timestamp.addingTimeInterval(10)
        )
        await model.refresh()
        await waitForRestoreCount(1, backend: backend)

        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertTrue(model.toast?.contains("temperature telemetry was lost") == true)
        await store.close()
    }

    func testUnconfirmedSystemRestoreIsPresentedAsControlLoss() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend(
            restoreResult: .unavailable(.helperUnavailable, "System restore was not confirmed")
        )
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        await model.restoreSystem()

        XCTAssertEqual(model.activeMode, .system)
        XCTAssertEqual(model.capability, .helperUnavailable)
        XCTAssertTrue(model.toast?.localizedCaseInsensitiveContains("not confirmed") == true)
        await store.close()
    }

    func testSystemSupersedesALateOverrideResult() async {
        let fixture = makeFixture()
        let backend = BlockingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.activate(.max)
        await backend.waitUntilApplyStarts()
        XCTAssertEqual(model.pendingMode, .max)

        // Auto is the escape hatch and must never be disabled by a slow
        // firmware write. A later success reply from Max must be ignored.
        model.activate(.system)
        for _ in 0..<100 where model.pendingMode != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertNil(model.pendingMode)

        await backend.releaseApply()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertNil(model.pendingMode)
        await store.close()
    }

    func testImmediateSystemRequestPreventsAnUnscheduledOverrideWrite() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        // Neither call yields. The Max task is queued but Auto becomes the
        // newest intent before it can enter the hardware backend.
        model.activate(.max)
        model.activate(.system)
        for _ in 0..<100 {
            if await backend.restoreCallCount() > 0 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let applications = await backend.applications()
        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(applications.count, 0)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertNil(model.pendingMode)
        await store.close()
    }

    func testSystemSupersedesStalePeriodicExpertRuleResult() async {
        let fixture = makeFixture(temperature: 50)
        let backend = BlockingExpertRuleBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.unlockExpert()
        model.expertUsesCurve = true
        model.expertCurves = testCurves
        model.activate(.expert)
        await backend.waitForApplicationCount(1)
        await waitForMode(.expert, model: model)

        await fixture.telemetry.update(
            temperature: 82,
            timestamp: fixture.timestamp.addingTimeInterval(10)
        )
        await model.refresh()
        await backend.waitUntilPeriodicRuleStarts()

        model.activate(.system)
        await backend.waitForRestoreCount(1)
        XCTAssertEqual(model.activeMode, .system)
        XCTAssertNil(model.pendingMode)

        await backend.releasePeriodicRule()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.activeMode, .system, "A late curve confirmation must never reactivate Manual")
        XCTAssertNil(model.pendingMode)
        _ = await model.dailyHistory()
        await store.close()
    }

    func testExpertRuleCoalescesSeveralSamplesWhileHelperIsBusy() async {
        let fixture = makeFixture(temperature: 50)
        let backend = BlockingExpertRuleBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.unlockExpert()
        model.expertUsesCurve = true
        model.expertCurves = testCurves
        model.activate(.expert)
        await backend.waitForApplicationCount(1)
        await waitForMode(.expert, model: model)

        await fixture.telemetry.update(temperature: 68, timestamp: fixture.timestamp.addingTimeInterval(10))
        await model.refresh()
        await backend.waitUntilPeriodicRuleStarts()
        await fixture.telemetry.update(temperature: 76, timestamp: fixture.timestamp.addingTimeInterval(20))
        await model.refresh()
        await fixture.telemetry.update(temperature: 84, timestamp: fixture.timestamp.addingTimeInterval(30))
        await model.refresh()
        let blockedApplicationCount = await backend.applicationCount()
        XCTAssertEqual(blockedApplicationCount, 2)

        await backend.releasePeriodicRule()
        await backend.waitForApplicationCount(3)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let finalApplicationCount = await backend.applicationCount()
        XCTAssertEqual(finalApplicationCount, 3, "Intermediate temperatures should collapse into one latest-target write")

        await model.restoreSystem(silent: true)
        _ = await model.dailyHistory()
        await store.close()
    }

    func testCoolBurstExpiresWithoutAnotherTelemetryRefresh() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(
            telemetry: fixture.telemetry,
            historyStore: store,
            controls: backend,
            coolBurstDuration: 0.08
        )

        await model.refresh()
        await waitForReady(model)
        model.startCoolBurst()
        await waitForMode(.max, model: model)
        XCTAssertNotNil(model.coolBurstUntil)

        // Deliberately do not call refresh(): expiry must not depend on a
        // responsive telemetry provider.
        await waitForRestoreCount(1, backend: backend)
        await waitForPendingModeToClear(model)

        XCTAssertEqual(model.activeMode, .system)
        XCTAssertNil(model.pendingMode)
        XCTAssertNil(model.coolBurstUntil)
        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(model.toast, "Cool Burst complete — back to System")
        await store.close()
    }

    func testNewerModeIntentCancelsAStaleCoolBurstTimer() async {
        let fixture = makeFixture()
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(
            telemetry: fixture.telemetry,
            historyStore: store,
            controls: backend,
            coolBurstDuration: 0.12
        )

        await model.refresh()
        await waitForReady(model)
        model.startCoolBurst()
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.max, model: model)

        // A regular Max selection is a newer, indefinite intent. The old burst
        // deadline must neither restore Auto nor retain a countdown.
        model.activate(.max)
        await waitForApplyCount(2, backend: backend)
        await waitForPendingModeToClear(model)
        try? await Task.sleep(for: .milliseconds(220))

        XCTAssertEqual(model.activeMode, .max)
        XCTAssertNil(model.coolBurstUntil)
        let restoreCount = await backend.restoreCallCount()
        XCTAssertEqual(restoreCount, 0)

        await model.restoreSystem(silent: true)
        await store.close()
    }

    func testActiveSmartBoostImmediatelyUsesAnEditedTrigger() async {
        let fixture = makeFixture(temperature: 75)
        let backend = RecordingControlBackend()
        let store = HistoryStore(inMemory: true)
        let model = AppModel(telemetry: fixture.telemetry, historyStore: store, controls: backend)

        await model.refresh()
        await waitForReady(model)
        model.activate(.smartBoost)
        await waitForApplyCount(1, backend: backend)
        await waitForMode(.smartBoost, model: model)
        XCTAssertEqual(model.smartBoostStatus, .armed)

        var editedPolicy = model.smartBoostPolicy
        editedPolicy.triggerCelsius = 70
        model.smartBoostPolicy = editedPolicy
        await waitForApplyCount(2, backend: backend)
        await waitForSmartBoostStatus(.boosting, model: model)

        let applications = await backend.applications()
        XCTAssertEqual(applications.map(\.mode), [.smartBoost, .max])
        XCTAssertEqual(model.smartBoostStatus, .boosting)
        XCTAssertEqual(model.activeMode, .smartBoost)

        await model.restoreSystem(silent: true)
        await store.close()
    }

    private var testCurves: [Int: FanCurve] {
        [
            0: FanCurve(points: [
                FanCurvePoint(temperature: 30, rpm: 2_000),
                FanCurvePoint(temperature: 95, rpm: 6_800)
            ]),
            1: FanCurve(points: [
                FanCurvePoint(temperature: 30, rpm: 2_200),
                FanCurvePoint(temperature: 95, rpm: 7_000)
            ])
        ]
    }

    private func makeFixture(temperature: Double = 60) -> (telemetry: MutableTestTelemetry, timestamp: Date) {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        return (MutableTestTelemetry(snapshot: testSnapshot(temperature: temperature, timestamp: timestamp)), timestamp)
    }

    private func waitForApplyCount(_ count: Int, backend: RecordingControlBackend) async {
        for _ in 0..<100 {
            if await backend.applications().count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(count) control request(s)")
    }

    private func waitForReady(_ model: AppModel) async {
        for _ in 0..<100 where model.capability != .ready {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.capability, .ready)
    }

    private func waitForRestoreCount(_ count: Int, backend: RecordingControlBackend) async {
        for _ in 0..<100 {
            if await backend.restoreCallCount() >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(count) restore request(s)")
    }

    private func waitForMode(_ mode: FanMode, model: AppModel) async {
        for _ in 0..<100 where model.activeMode != mode {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.activeMode, mode)
    }

    private func waitForPendingModeToClear(_ model: AppModel) async {
        for _ in 0..<100 where model.pendingMode != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(model.pendingMode)
    }

    private func waitForSmartBoostStatus(_ status: SmartBoostStatus, model: AppModel) async {
        for _ in 0..<100 where model.smartBoostStatus != status {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.smartBoostStatus, status)
    }
}

private struct RecordedControlApplication: Sendable {
    let mode: FanMode
    let targets: [Int: Double]
}

private actor RecordingControlBackend: FanControlBackend {
    private var currentCapability: ControlCapability = .ready
    private var scriptedApplyResults: [ControlResult]
    private var restoreResult: ControlResult
    private var recordedApplications: [RecordedControlApplication] = []
    private var restores = 0

    init(
        applyResults: [ControlResult] = [],
        restoreResult: ControlResult = .accepted([:])
    ) {
        scriptedApplyResults = applyResults
        self.restoreResult = restoreResult
    }

    func capability() async -> ControlCapability { currentCapability }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        recordedApplications.append(RecordedControlApplication(mode: mode, targets: targets))
        if !scriptedApplyResults.isEmpty {
            return scriptedApplyResults.removeFirst()
        }
        switch mode {
        case .max:
            return .accepted(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.maximumRPM) }))
        case .expert:
            return .accepted(targets)
        case .system, .smartBoost:
            return .accepted([:])
        }
    }

    func restoreSystem() async -> ControlResult {
        restores += 1
        return restoreResult
    }

    func applications() -> [RecordedControlApplication] { recordedApplications }
    func restoreCallCount() -> Int { restores }
}

private actor BlockingControlBackend: FanControlBackend {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var restores = 0

    func capability() async -> ControlCapability { .ready }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return .accepted(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.maximumRPM) }))
    }

    func restoreSystem() async -> ControlResult {
        restores += 1
        return .accepted([:])
    }

    func waitUntilApplyStarts() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseApply() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func restoreCallCount() -> Int { restores }
}

private actor BlockingCapabilityBackend: FanControlBackend {
    private var capabilityCalls = 0
    private var capabilityStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func capability() async -> ControlCapability {
        capabilityCalls += 1
        capabilityStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return .ready
    }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        .accepted(targets)
    }

    func restoreSystem() async -> ControlResult { .accepted([:]) }

    func waitUntilCapabilityStarts() async {
        if capabilityStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCapability() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func capabilityCallCount() -> Int { capabilityCalls }
}

private actor BlockingExpertRuleBackend: FanControlBackend {
    private var applyCount = 0
    private var periodicRuleStarted = false
    private var periodicStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var periodicReleaseContinuation: CheckedContinuation<Void, Never>?
    private var restores = 0

    func capability() async -> ControlCapability { .ready }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        applyCount += 1
        if applyCount == 2 {
            periodicRuleStarted = true
            periodicStartWaiters.forEach { $0.resume() }
            periodicStartWaiters.removeAll()
            await withCheckedContinuation { periodicReleaseContinuation = $0 }
        }
        return .accepted(targets)
    }

    func restoreSystem() async -> ControlResult {
        restores += 1
        return .accepted([:])
    }

    func waitForApplicationCount(_ expected: Int) async {
        for _ in 0..<100 where applyCount < expected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func applicationCount() -> Int { applyCount }

    func waitUntilPeriodicRuleStarts() async {
        if periodicRuleStarted { return }
        await withCheckedContinuation { periodicStartWaiters.append($0) }
    }

    func releasePeriodicRule() {
        periodicReleaseContinuation?.resume()
        periodicReleaseContinuation = nil
    }

    func waitForRestoreCount(_ expected: Int) async {
        for _ in 0..<100 where restores < expected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor MutableTestTelemetry: ThermalTelemetryProviding {
    private var current: ThermalSnapshot

    init(snapshot: ThermalSnapshot) {
        current = snapshot
    }

    func snapshot() async -> ThermalSnapshot { current }
    func resetAfterWake() async {}

    func update(temperature: Double?, timestamp: Date) {
        current.timestamp = timestamp
        if let temperature {
            let cpu = SensorReading(key: "TC0P", name: "CPU thermal", celsius: temperature)
            let gpu = SensorReading(key: "TG0P", name: "GPU thermal", celsius: temperature - 2)
            current.hottest = cpu
            current.cpu = cpu
            current.gpu = gpu
            current.sensors = [cpu, gpu]
        } else {
            current.hottest = nil
            current.cpu = nil
            current.gpu = nil
            current.sensors = []
        }
    }
}

private func testSnapshot(temperature: Double, timestamp: Date) -> ThermalSnapshot {
    let cpu = SensorReading(key: "TC0P", name: "CPU thermal", celsius: temperature)
    let gpu = SensorReading(key: "TG0P", name: "GPU thermal", celsius: temperature - 2)
    return ThermalSnapshot(
        timestamp: timestamp,
        hottest: cpu,
        cpu: cpu,
        gpu: gpu,
        fans: [
            FanReading(id: 0, name: "Left fan", actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_800, firmwareTargetRPM: nil),
            FanReading(id: 1, name: "Right fan", actualRPM: 3_100, minimumRPM: 2_200, maximumRPM: 7_000, firmwareTargetRPM: nil)
        ],
        sensors: [cpu, gpu],
        sourceStatus: "Deterministic unit test"
    )
}
