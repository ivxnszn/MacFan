import Combine
import Foundation

/// UI surfaces that report visibility so the sampler can slow down when
/// nobody is looking and speed up the moment something opens.
enum VisibleSurface: Hashable, Sendable {
    case popover
    case dashboard
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: ThermalSnapshot = .unavailable
    @Published private(set) var capability: ControlCapability = .monitoring
    @Published private(set) var activeMode: FanMode = .system
    @Published private(set) var history: [TelemetrySample] = []
    @Published private(set) var thermalTrail: [TelemetrySample] = []
    @Published var selectedRange: HistoryRange = .hour {
        didSet {
            guard selectedRange != oldValue else { return }
            requestDashboardHistoryReload(force: true)
        }
    }
    @Published var smartBoostPolicy = SmartBoostPolicy() {
        didSet {
            guard smartBoostPolicy != oldValue else { return }
            smartBoost.updatePolicy(smartBoostPolicy)
            // The value shown by the slider and chart must also be the value
            // driving an already-armed Smart mode. Coalescing keeps slider
            // edits from building a helper-command backlog.
            if activeMode == .smartBoost {
                schedulePeriodicControlRuleIfNeeded(force: true)
            }
        }
    }
    @Published private(set) var smartBoostStatus: SmartBoostStatus = .inactive
    @Published var isExpertUnlocked = false
    @Published var expertRPM: [Int: Double] = [:]
    @Published var expertCurves: [Int: FanCurve] = [:]
    @Published var expertUsesCurve = false
    @Published var toast: String?
    /// Non-nil while a mode request is in flight so the UI can show progress.
    /// Verified hardware writes are legitimately slow (the M-series firmware
    /// unlock alone can take ~10 seconds); the interface must say so.
    @Published private(set) var pendingMode: FanMode?
    @Published private(set) var coolBurstUntil: Date?
    /// "Keep cool" preference: when set, MacFan re-arms comfort cooling
    /// automatically once hardware control is available after launch. Persisted
    /// so the machine stays cool across restarts without the owner re-enabling
    /// it. The failsafe is unchanged — this only re-issues the ordinary,
    /// preflighted Smart Boost activation.
    @Published private(set) var keepCoolAtLaunch = false {
        didSet {
            guard keepCoolAtLaunch != oldValue, !usesTestFixture else { return }
            UserDefaults.standard.set(keepCoolAtLaunch, forKey: Self.keepCoolDefaultsKey)
        }
    }
    private static let keepCoolDefaultsKey = "macfan.keepCoolAtLaunch"
    /// Guards against fighting the owner: auto-arm happens at most once per
    /// launch, so manually returning to Auto mid-session sticks.
    private var hasArmedComfortThisLaunch = false
    /// Window visibility, including minimization and full occlusion. Views with
    /// their own expensive samplers can use this to pause without throwing
    /// away transient dashboard state.
    @Published private(set) var isDashboardVisible = false

    /// Session sensor statistics belong to the app process, not to a window.
    /// Keeping this model here preserves min/average/max and trails when the
    /// dashboard is closed, while avoiding any subscription from AppModel to
    /// its high-frequency publications.
    let sensorSession = SensorSessionModel()

    private let telemetry: any ThermalTelemetryProviding
    private let historyStore: HistoryStore
    private let controls: any FanControlBackend
    private let usesTestFixture: Bool
    private let coolBurstDuration: TimeInterval
    private var samplerTask: Task<Void, Never>?
    private var samplerSleepTask: Task<Void, Never>?
    private var samplerSleepToken: UInt = 0
    private var toastTask: Task<Void, Never>?
    private var visibleSurfaces: Set<VisibleSurface> = []
    private var smartBoost = SmartBoostEngine()
    private var lastDashboardHistoryRefresh = Date.distantPast
    private var lastPopoverTrailRefresh = Date.distantPast
    private var lastCapabilityRefresh = Date.distantPast
    private var verifiedMacFanTargets: [Int: Double] = [:]
    private let usesLiveTelemetry: Bool
    private var capabilityRefreshTask: Task<Void, Never>?
    private var capabilityRefreshToken: UInt = 0
    private var periodicControlRuleTask: Task<Void, Never>?
    private var periodicControlRuleToken: UInt = 0
    private var periodicControlRuleNeedsRefresh = false
    private var modeRequestTask: Task<Void, Never>?
    private var coolBurstExpiryTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Never>?
    private var dashboardHistoryReloadTask: Task<Void, Never>?
    private var popoverTrailReloadTask: Task<Void, Never>?
    private var dashboardHistoryRequestToken: UInt = 0
    private var popoverTrailRequestToken: UInt = 0
    /// Invalidates late UI results when a newer control intent supersedes an
    /// in-flight request. The backend serializes hardware commands, so an
    /// emergency System request queues immediately after the active write and
    /// becomes the final command seen by the helper.
    private var controlRequestGeneration: UInt = 0

    // Delta tracking for record (only persist when meaningful change)
    private var lastRecordedTemp: Double?
    private var lastRecordedRPM: Double?
    private var lastRecordTime = Date.distantPast
    private var lastTelemetryTimestamp = Date.distantPast

    // For expert curve short-circuit
    private var lastCurveTemp: Double?

    convenience init() {
        let usesTestFixture = ProcessInfo.processInfo.environment["MACFAN_UI_TEST_MODE"] == "1"
        if usesTestFixture {
            self.init(
                telemetry: FixtureTelemetryService(),
                historyStore: HistoryStore(inMemory: true),
                controls: UnavailableControlBackend(),
                usesTestFixture: true
            )
        } else {
            self.init(
                telemetry: AppleSMCTelemetryService(),
                historyStore: HistoryStore(),
                controls: LocalHelperControlBackend(),
                usesTestFixture: false
            )
        }
    }

    /// Internal dependency injection keeps control failure paths deterministic
    /// in tests and guarantees UI fixtures never contact a live root helper.
    init(
        telemetry: any ThermalTelemetryProviding,
        historyStore: HistoryStore,
        controls: any FanControlBackend,
        usesTestFixture: Bool = false,
        coolBurstDuration: TimeInterval = 10 * 60
    ) {
        self.telemetry = telemetry
        self.historyStore = historyStore
        self.controls = controls
        self.usesTestFixture = usesTestFixture
        self.usesLiveTelemetry = telemetry is AppleSMCTelemetryService
        self.coolBurstDuration = coolBurstDuration.isFinite && coolBurstDuration >= 0
            ? coolBurstDuration
            : 10 * 60
        if !usesTestFixture {
            keepCoolAtLaunch = UserDefaults.standard.bool(forKey: Self.keepCoolDefaultsKey)
        }
    }

    deinit {
        samplerTask?.cancel()
        samplerSleepTask?.cancel()
        capabilityRefreshTask?.cancel()
        periodicControlRuleTask?.cancel()
        modeRequestTask?.cancel()
        coolBurstExpiryTask?.cancel()
        dashboardHistoryReloadTask?.cancel()
        popoverTrailReloadTask?.cancel()
        toastTask?.cancel()
    }

    func start() {
        guard samplerTask == nil else { return }
        samplerTask = Task { [weak self] in
            if self?.usesTestFixture == true {
                await self?.seedTestHistory()
                self?.requestVisibleHistoryReloads(force: true)
            }
            while !Task.isCancelled {
                await self?.refresh()
                guard !Task.isCancelled else { return }
                guard let sleep = self?.beginSamplerSleep(seconds: self?.samplerInterval ?? 15) else { return }
                await sleep.task.value
                self?.finishSamplerSleep(token: sleep.token)
            }
        }
    }

    func stop() {
        let context = prepareForStop()
        modeRequestTask = Task { [weak self] in
            await self?.performSystemRestore(context)
        }
    }

    /// Used by application termination so macOS does not tear down the XPC
    /// connection until the final System restore has replied (or timed out).
    func stopAndRestore() async {
        let context = prepareForStop()
        await performSystemRestore(context)
    }

    private func prepareForStop() -> SystemRestoreContext {
        samplerTask?.cancel()
        samplerTask = nil
        wakeSampler()
        capabilityRefreshTask?.cancel()
        capabilityRefreshToken &+= 1
        capabilityRefreshTask = nil
        dashboardHistoryRequestToken &+= 1
        popoverTrailRequestToken &+= 1
        dashboardHistoryReloadTask?.cancel()
        dashboardHistoryReloadTask = nil
        popoverTrailReloadTask?.cancel()
        popoverTrailReloadTask = nil

        // A quit request supersedes every pending/rule write. The helper
        // serializes commands, so this restore queues behind any already-entered
        // write and is the final hardware command even if cancellation cannot
        // interrupt that XPC request.
        return beginSystemRestore(silent: true, forceHardware: true)
    }

    /// Adaptive cadence: fast only while someone is actually looking. Active
    /// control modes keep their 3-second responsiveness floor regardless of
    /// visibility — the helper's independent 12-second heartbeat lease and all
    /// failsafe behavior are untouched by this policy.
    var samplerInterval: TimeInterval {
        if activeMode != .system { return 3 }
        if visibleSurfaces.contains(.popover) { return 2 }
        // Long-form charts do not benefit from menu-bar-speed polling. Five
        // seconds keeps them feeling live while reducing the chance that a
        // telemetry/database refresh lands in the middle of a scroll gesture.
        if visibleSurfaces.contains(.dashboard) { return 5 }
        return 15
    }

    func surfaceDidShow(_ surface: VisibleSurface) {
        setSurface(surface, visible: true)
    }

    func surfaceDidHide(_ surface: VisibleSurface) {
        setSurface(surface, visible: false)
    }

    /// Idempotent because a dashboard window can report both delegate and
    /// occlusion notifications for the same transition.
    func setSurface(_ surface: VisibleSurface, visible: Bool) {
        let changed: Bool
        if visible {
            changed = visibleSurfaces.insert(surface).inserted
        } else {
            changed = visibleSurfaces.remove(surface) != nil
        }

        if surface == .dashboard, isDashboardVisible != visible {
            isDashboardVisible = visible
        }
        guard changed else { return }

        if visible {
            wakeSampler()
            switch surface {
            case .dashboard: requestDashboardHistoryReload(force: true)
            case .popover: requestPopoverTrailReload(force: true)
            }
        } else {
            switch surface {
            case .dashboard:
                dashboardHistoryRequestToken &+= 1
                dashboardHistoryReloadTask?.cancel()
                dashboardHistoryReloadTask = nil
            case .popover:
                popoverTrailRequestToken &+= 1
                popoverTrailReloadTask?.cancel()
                popoverTrailReloadTask = nil
            }
        }
    }

    private func wakeSampler() {
        samplerSleepTask?.cancel()
        samplerSleepTask = nil
    }

    /// A stored cancellable sleep has a single owner and cannot accidentally
    /// resume a later loop iteration (the continuation implementation could).
    /// Its closure captures no model, avoiding a sleep-duration retain cycle.
    private func beginSamplerSleep(seconds: TimeInterval) -> (token: UInt, task: Task<Void, Never>) {
        samplerSleepTask?.cancel()
        samplerSleepToken &+= 1
        let token = samplerSleepToken
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        }
        samplerSleepTask = task
        return (token, task)
    }

    private func finishSamplerSleep(token: UInt) {
        guard token == samplerSleepToken else { return }
        samplerSleepTask = nil
    }

    func refresh() async {
        let nextSnapshot = await telemetry.snapshot()
        guard !Task.isCancelled, nextSnapshot.timestamp >= lastTelemetryTimestamp else { return }
        lastTelemetryTimestamp = nextSnapshot.timestamp
        sensorSession.observe(nextSnapshot.sensors, at: nextSnapshot.timestamp)
        if !snapshot.isVisuallyEquivalent(to: nextSnapshot) {
            snapshot = nextSnapshot
        }
        // Everything below may involve a slow helper or SQLite. Schedule it
        // after publishing the live snapshot so the menu item and visible
        // temperature never wait behind a firmware preflight or chart query.
        scheduleCapabilityRefreshIfNeeded()
        schedulePeriodicControlRuleIfNeeded()
        enqueueHistoryRecord(for: nextSnapshot)
        requestVisibleHistoryReloads(force: false)
    }

    func activate(_ mode: FanMode) {
        // Returning control to macOS is the escape hatch. It must remain
        // available even while a slower verified Max/Manual write is pending.
        guard mode == .system || pendingMode == nil else { return }
        guard mode != .expert || isExpertUnlocked else {
            presentToast("Unlock Expert controls in the dashboard first")
            return
        }
        guard mode == .system || capability.canControl else {
            presentToast(capability.detail)
            return
        }
        if mode == .system {
            queueSystemRestore(silent: false, forceHardware: false)
            return
        }

        invalidateControlWork(cancelModeRequest: true)
        controlRequestGeneration &+= 1
        let generation = controlRequestGeneration
        pendingMode = mode
        modeRequestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == controlRequestGeneration {
                    pendingMode = nil
                    modeRequestTask = nil
                }
            }
            // Auto may have superseded this request before Swift schedules the
            // task. Never let that stale request reach the hardware backend.
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            let targets = mode == .expert ? expertTargets() : [:]
            let fans = snapshot.fans
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            let result = await controls.apply(mode: mode, fans: fans, targets: targets)
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            switch result {
            case .accepted(let confirmedTargets):
                activeMode = mode
                verifiedMacFanTargets = confirmedTargets
                if mode == .smartBoost {
                    smartBoost = SmartBoostEngine(policy: smartBoostPolicy)
                    smartBoostStatus = .armed
                    schedulePeriodicControlRuleIfNeeded(force: true)
                } else {
                    smartBoostStatus = .inactive
                }
                if mode != .smartBoost { presentToast("\(mode.title) is active") }
            case .unavailable(let newCapability, let message):
                await failSafeAfterControlFailure(
                    capability: newCapability,
                    message: message,
                    expectedGeneration: generation
                )
            }
        }
    }

    /// One-tap "keep my lap cool": apply the comfort policy, remember the
    /// preference so it survives restarts, and engage Smart Boost now (if
    /// control is available; otherwise it re-arms the moment preflight passes).
    func engageComfortCooling() {
        keepCoolAtLaunch = true
        hasArmedComfortThisLaunch = true
        smartBoostPolicy = .comfort
        if capability.canControl {
            activate(.smartBoost)
            presentToast("Keeping your Mac cool — fans ramp at \(Int(SmartBoostPolicy.comfort.triggerCelsius))°C")
        } else {
            presentToast("Comfort cooling armed — starts once control is ready")
        }
    }

    /// Turn comfort cooling off for good: clear the preference and hand the
    /// fans back to macOS.
    func stopComfortCooling() {
        keepCoolAtLaunch = false
        hasArmedComfortThisLaunch = true
        activate(.system)
    }

    /// After launch, once hardware control becomes available, silently restore
    /// comfort cooling if the owner left it on — the "always stays cool"
    /// behavior. Never fights a manual choice: it fires at most once per launch
    /// and only from a clean Auto state.
    private func maybeArmComfortCoolingAfterLaunch() {
        guard keepCoolAtLaunch,
              !hasArmedComfortThisLaunch,
              capability.canControl,
              activeMode == .system,
              pendingMode == nil else { return }
        hasArmedComfortThisLaunch = true
        smartBoostPolicy = .comfort
        activate(.smartBoost)
    }

    func restoreSystem(silent: Bool = false) async {
        let context = beginSystemRestore(silent: silent, forceHardware: false)
        await performSystemRestore(context)
    }

    private struct SystemRestoreContext: Sendable {
        let generation: UInt
        let hadVerifiedControl: Bool
        let shouldAttemptHardwareRestore: Bool
        let silent: Bool
    }

    private func queueSystemRestore(silent: Bool, forceHardware: Bool) {
        let context = beginSystemRestore(silent: silent, forceHardware: forceHardware)
        modeRequestTask = Task { [weak self] in
            await self?.performSystemRestore(context)
        }
    }

    /// Update UI state synchronously before waiting on the helper. Auto is the
    /// escape hatch, and a stale rule is invalidated before it can enter the
    /// backend. The serialized restore then becomes the final hardware command.
    private func beginSystemRestore(
        silent: Bool,
        forceHardware: Bool,
        capabilityOverride: ControlCapability? = nil
    ) -> SystemRestoreContext {
        let hadVerifiedControl = capability.canControl
        let hadPotentialOverride = activeMode != .system
            || pendingMode.map { $0 != .system } == true
            || !verifiedMacFanTargets.isEmpty

        invalidateControlWork(cancelModeRequest: true)
        controlRequestGeneration &+= 1
        let generation = controlRequestGeneration
        pendingMode = .system
        activeMode = .system
        coolBurstUntil = nil
        smartBoost.reset()
        smartBoostStatus = .inactive
        verifiedMacFanTargets = [:]
        lastCurveTemp = nil
        if let capabilityOverride, capability != capabilityOverride {
            capability = capabilityOverride
        }
        return SystemRestoreContext(
            generation: generation,
            hadVerifiedControl: hadVerifiedControl,
            shouldAttemptHardwareRestore: forceHardware || hadVerifiedControl || hadPotentialOverride,
            silent: silent
        )
    }

    private func performSystemRestore(_ context: SystemRestoreContext) async {
        guard context.generation == controlRequestGeneration else { return }
        let restoreResult = context.shouldAttemptHardwareRestore ? await controls.restoreSystem() : nil
        guard context.generation == controlRequestGeneration else { return }

        var restoreFailureMessage: String?
        if case .unavailable(let nextCapability, let message)? = restoreResult {
            if capability != nextCapability { capability = nextCapability }
            restoreFailureMessage = message
        }
        pendingMode = nil
        modeRequestTask = nil
        if !context.silent {
            if case .accepted? = restoreResult {
                presentToast("MacFan released fan control to macOS")
            } else if let restoreFailureMessage {
                presentToast("Auto requested — \(restoreFailureMessage)")
            } else if context.hadVerifiedControl {
                presentToast("Auto requested — the helper watchdog is confirming release")
            } else {
                presentToast("MacFan is monitoring — firmware or another controller owns the fans")
            }
        }
    }

    func startCoolBurst() {
        guard pendingMode == nil else { return }
        guard capability.canControl else {
            presentToast(capability.detail)
            return
        }
        invalidateControlWork(cancelModeRequest: true)
        controlRequestGeneration &+= 1
        let generation = controlRequestGeneration
        pendingMode = .max
        modeRequestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == controlRequestGeneration {
                    pendingMode = nil
                    modeRequestTask = nil
                }
            }
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            let fans = snapshot.fans
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            let result = await controls.apply(mode: .max, fans: fans, targets: [:])
            guard generation == controlRequestGeneration, !Task.isCancelled else { return }
            switch result {
            case .accepted(let confirmedTargets):
                activeMode = .max
                smartBoostStatus = .inactive
                verifiedMacFanTargets = confirmedTargets
                let deadline = Date.now.addingTimeInterval(coolBurstDuration)
                coolBurstUntil = deadline
                scheduleCoolBurstExpiry(at: deadline, expectedGeneration: generation)
                presentToast("Cool Burst engaged for 10 minutes")
            case .unavailable(let newCapability, let message):
                await failSafeAfterControlFailure(
                    capability: newCapability,
                    message: message,
                    expectedGeneration: generation
                )
            }
        }
    }

    func handleSleep() {
        queueSystemRestore(silent: true, forceHardware: true)
    }

    func handleWake() {
        wakeSampler()
        Task { [weak self] in
            guard let self else { return }
            await telemetry.resetAfterWake()
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func unlockExpert() {
        guard capability.canControl else {
            presentToast(capability.detail)
            return
        }
        isExpertUnlocked = true
        for fan in snapshot.fans {
            expertRPM[fan.id] = min(max(fan.actualRPM, fan.minimumRPM), fan.maximumRPM)
            expertCurves[fan.id] = FanCurve(points: [
                FanCurvePoint(temperature: 30, rpm: fan.minimumRPM),
                FanCurvePoint(temperature: 60, rpm: max(fan.minimumRPM, min(fan.actualRPM, fan.maximumRPM))),
                FanCurvePoint(temperature: 80, rpm: max(fan.minimumRPM, fan.maximumRPM * 0.78)),
                FanCurvePoint(temperature: 95, rpm: fan.maximumRPM)
            ]).validated(minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
        }
        presentToast("Expert controls unlocked — hardware limits still apply")
    }

    func clearHistory() {
        let pendingWrite = historyWriteTask
        let store = historyStore
        let purgeTask = Task {
            await pendingWrite?.value
            await store.purgeAll()
        }
        // The purge itself is part of the ordered write chain. Any telemetry
        // arriving while the clear is in flight waits until deletion finishes.
        historyWriteTask = purgeTask
        Task { [weak self] in
            await purgeTask.value
            guard !Task.isCancelled, let self else { return }
            dashboardHistoryRequestToken &+= 1
            popoverTrailRequestToken &+= 1
            dashboardHistoryReloadTask?.cancel()
            dashboardHistoryReloadTask = nil
            popoverTrailReloadTask?.cancel()
            popoverTrailReloadTask = nil
            history = []
            thermalTrail = []
            lastDashboardHistoryRefresh = .now
            lastPopoverTrailRefresh = .now
            presentToast("Local thermal history cleared")
        }
    }

    func reloadHistory() async {
        requestDashboardHistoryReload(force: true, allowHidden: true)
        await dashboardHistoryReloadTask?.value
    }

    /// A fixed 24-hour window for the Insights engine, independent of the
    /// chart range the user selected.
    func dailyHistory() async -> [TelemetrySample] {
        await historyWriteTask?.value
        return await historyStore.samples(for: .day)
    }

    private func enqueueHistoryRecord(for nextSnapshot: ThermalSnapshot) {
        let sample = nextSnapshot.sample(
            mode: activeMode,
            capability: capability,
            verifiedMacFanTargets: verifiedMacFanTargets
        )
        guard let temperature = sample.displayTemperatureCelsius else { return }

        let rpm = sample.averageActualRPM
        let tempDelta = lastRecordedTemp.map { abs($0 - temperature) } ?? 10
        let rpmDelta: Double
        if let lastRecordedRPM, let rpm {
            rpmDelta = abs(lastRecordedRPM - rpm)
        } else {
            rpmDelta = 100
        }
        guard Self.shouldRecord(
            tempDelta: tempDelta,
            rpmDelta: rpmDelta,
            mode: activeMode,
            sinceLastRecord: sample.timestamp.timeIntervalSince(lastRecordTime)
        ) else { return }

        // Advance the debounce state when the row is enqueued, not when SQLite
        // eventually finishes. A slow rollup therefore cannot enqueue duplicate
        // heartbeats. Each task awaits its predecessor to preserve timestamp order.
        lastRecordedTemp = temperature
        lastRecordedRPM = rpm
        lastRecordTime = sample.timestamp
        let previousWrite = historyWriteTask
        let store = historyStore
        historyWriteTask = Task {
            await previousWrite?.value
            await store.record(sample)
        }
    }

    private func requestVisibleHistoryReloads(force: Bool) {
        if visibleSurfaces.contains(.dashboard) {
            requestDashboardHistoryReload(force: force)
        }
        if visibleSurfaces.contains(.popover) {
            requestPopoverTrailReload(force: force)
        }
    }

    private func requestDashboardHistoryReload(force: Bool, allowHidden: Bool = false) {
        guard allowHidden || visibleSurfaces.contains(.dashboard) else { return }
        guard force || Date.now.timeIntervalSince(lastDashboardHistoryRefresh) >= 30 else { return }
        if dashboardHistoryReloadTask != nil, !force { return }

        dashboardHistoryRequestToken &+= 1
        let token = dashboardHistoryRequestToken
        let range = selectedRange
        let pendingWrite = historyWriteTask
        let store = historyStore
        dashboardHistoryReloadTask?.cancel()
        dashboardHistoryReloadTask = Task { [weak self] in
            await pendingWrite?.value
            guard !Task.isCancelled else { return }
            let nextHistory = await store.samples(for: range)
            guard !Task.isCancelled, let self,
                  token == dashboardHistoryRequestToken,
                  range == selectedRange,
                  allowHidden || visibleSurfaces.contains(.dashboard) else { return }
            if history != nextHistory { history = nextHistory }
            lastDashboardHistoryRefresh = .now
            dashboardHistoryReloadTask = nil
        }
    }

    private func requestPopoverTrailReload(force: Bool) {
        guard visibleSurfaces.contains(.popover) else { return }
        guard force || Date.now.timeIntervalSince(lastPopoverTrailRefresh) >= 30 else { return }
        if popoverTrailReloadTask != nil, !force { return }

        popoverTrailRequestToken &+= 1
        let token = popoverTrailRequestToken
        let pendingWrite = historyWriteTask
        let store = historyStore
        popoverTrailReloadTask?.cancel()
        popoverTrailReloadTask = Task { [weak self] in
            await pendingWrite?.value
            guard !Task.isCancelled else { return }
            let nextTrail = await store.thermalTrail()
            guard !Task.isCancelled, let self,
                  token == popoverTrailRequestToken,
                  visibleSurfaces.contains(.popover) else { return }
            if thermalTrail != nextTrail { thermalTrail = nextTrail }
            lastPopoverTrailRefresh = .now
            popoverTrailReloadTask = nil
        }
    }

    private func scheduleCapabilityRefreshIfNeeded(force: Bool = false) {
        guard capabilityRefreshTask == nil else { return }
        let interval: TimeInterval = usesLiveTelemetry ? (activeMode == .system ? 20 : 5) : 0
        guard force
                || capability == .monitoring
                || Date.now.timeIntervalSince(lastCapabilityRefresh) >= interval else { return }

        capabilityRefreshToken &+= 1
        let token = capabilityRefreshToken
        capabilityRefreshTask = Task { [weak self] in
            guard let self else { return }
            let nextCapability = await controls.capability()
            guard !Task.isCancelled else {
                if token == capabilityRefreshToken { capabilityRefreshTask = nil }
                return
            }
            lastCapabilityRefresh = .now
            let hadOrPendingOverride = activeMode != .system
                || pendingMode.map { $0 != .system } == true
                || !verifiedMacFanTargets.isEmpty
            if capability != nextCapability { capability = nextCapability }

            // Re-arm "keep cool" once control is confirmed available.
            maybeArmComfortCoolingAfterLaunch()

            if !nextCapability.canControl, hadOrPendingOverride {
                let context = beginSystemRestore(
                    silent: true,
                    forceHardware: true,
                    capabilityOverride: nextCapability
                )
                await performSystemRestore(context)
            }
            if token == capabilityRefreshToken { capabilityRefreshTask = nil }
        }
    }

    /// Persist a row when something meaningful changed, when MacFan is
    /// actively controlling, or as a 30-second heartbeat. The heartbeat keeps a
    /// perfectly steady machine from producing holes that charts would render
    /// as sleep gaps and that would undercount sustained-heat insights.
    nonisolated static func shouldRecord(
        tempDelta: Double,
        rpmDelta: Double,
        mode: FanMode,
        sinceLastRecord: TimeInterval
    ) -> Bool {
        tempDelta > 0.1 || rpmDelta > 10 || mode != .system || sinceLastRecord >= 30
    }

    var coolBurstRemaining: String? {
        guard let coolBurstUntil else { return nil }
        let remaining = max(0, Int(coolBurstUntil.timeIntervalSinceNow.rounded(.up)))
        return String(format: "%d:%02d remaining", remaining / 60, remaining % 60)
    }

    /// Fraction of the Cool Burst window still remaining (1 → 0), for the
    /// popover's draining countdown ring. Nil when no burst is active.
    var coolBurstFractionRemaining: Double? {
        guard let coolBurstUntil, coolBurstDuration > 0 else { return nil }
        return max(0, min(1, coolBurstUntil.timeIntervalSinceNow / coolBurstDuration))
    }

    func presentToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func invalidateControlWork(cancelModeRequest: Bool) {
        coolBurstExpiryTask?.cancel()
        coolBurstExpiryTask = nil
        coolBurstUntil = nil
        if cancelModeRequest {
            modeRequestTask?.cancel()
            modeRequestTask = nil
        }
        periodicControlRuleToken &+= 1
        periodicControlRuleTask?.cancel()
        periodicControlRuleTask = nil
        periodicControlRuleNeedsRefresh = false
    }

    /// Cool Burst owns its own deadline instead of depending on the telemetry
    /// loop. If an SMC read stalls, Max still expires. The request generation
    /// makes an old timer harmless after any newer mode, Auto, sleep, or quit
    /// intent; `invalidateControlWork` also cancels it eagerly.
    private func scheduleCoolBurstExpiry(at deadline: Date, expectedGeneration: UInt) {
        coolBurstExpiryTask?.cancel()
        let delay = max(0, deadline.timeIntervalSinceNow)
        coolBurstExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  expectedGeneration == controlRequestGeneration,
                  coolBurstUntil == deadline,
                  activeMode == .max else { return }

            // Clear the stored reference before beginSystemRestore invalidates
            // control work, so the firing task never cancels itself midway
            // through the final hardware restore.
            coolBurstExpiryTask = nil
            let context = beginSystemRestore(silent: true, forceHardware: true)
            await performSystemRestore(context)
            guard context.generation == controlRequestGeneration else { return }
            presentToast("Cool Burst complete — back to System")
        }
    }

    /// There is one periodic rule worker regardless of telemetry cadence. If a
    /// slow helper write spans several samples, they collapse into one rerun
    /// against the newest snapshot instead of forming an XPC backlog.
    private func schedulePeriodicControlRuleIfNeeded(force _: Bool = false) {
        let needsRule = activeMode == .smartBoost || (activeMode == .expert && expertUsesCurve)
        guard capability.canControl, needsRule else { return }
        if periodicControlRuleTask != nil {
            periodicControlRuleNeedsRefresh = true
            return
        }

        periodicControlRuleNeedsRefresh = false
        periodicControlRuleToken &+= 1
        let taskToken = periodicControlRuleToken
        let controlGeneration = controlRequestGeneration
        periodicControlRuleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  taskToken == periodicControlRuleToken,
                  controlGeneration == controlRequestGeneration {
                await runPeriodicControlRule(expectedGeneration: controlGeneration)
                guard !Task.isCancelled,
                      taskToken == periodicControlRuleToken,
                      controlGeneration == controlRequestGeneration else { return }
                if periodicControlRuleNeedsRefresh {
                    periodicControlRuleNeedsRefresh = false
                    continue
                }
                periodicControlRuleTask = nil
                return
            }
            if taskToken == periodicControlRuleToken { periodicControlRuleTask = nil }
        }
    }

    private func runPeriodicControlRule(expectedGeneration: UInt) async {
        guard expectedGeneration == controlRequestGeneration else { return }
        switch activeMode {
        case .smartBoost:
            await runSmartBoostRule(expectedGeneration: expectedGeneration)
        case .expert where expertUsesCurve:
            await runExpertCurveRule(expectedGeneration: expectedGeneration)
        case .system, .max, .expert:
            break
        }
    }

    private func runSmartBoostRule(expectedGeneration: UInt) async {
        guard expectedGeneration == controlRequestGeneration,
              activeMode == .smartBoost else { return }
        guard let temperature = snapshot.displayTemperature?.celsius,
              temperature.isFinite else {
            await failSafeAfterControlFailure(
                capability: capability,
                message: "Smart Boost released — temperature telemetry was lost",
                expectedGeneration: expectedGeneration
            )
            return
        }

        let wasBoosting = smartBoost.isBoosting
        let shouldBoost = smartBoost.update(temperature: temperature)
        switch (wasBoosting, shouldBoost) {
        case (false, true):
            let fans = snapshot.fans
            guard expectedGeneration == controlRequestGeneration else { return }
            let result = await controls.apply(mode: .max, fans: fans, targets: [:])
            guard expectedGeneration == controlRequestGeneration,
                  activeMode == .smartBoost else { return }
            switch result {
            case .accepted(let confirmedTargets):
                smartBoostStatus = .boosting
                verifiedMacFanTargets = confirmedTargets
                presentToast("Smart Boost engaged Max")
            case .unavailable(let nextCapability, let message):
                await failSafeAfterControlFailure(
                    capability: nextCapability,
                    message: message,
                    expectedGeneration: expectedGeneration
                )
            }
        case (true, false):
            guard expectedGeneration == controlRequestGeneration else { return }
            let result = await controls.restoreSystem()
            guard expectedGeneration == controlRequestGeneration,
                  activeMode == .smartBoost else { return }
            switch result {
            case .accepted:
                smartBoostStatus = .armed
                verifiedMacFanTargets = [:]
                presentToast("Smart Boost cooled down — armed in System")
            case .unavailable(let nextCapability, let message):
                await failSafeAfterControlFailure(
                    capability: nextCapability,
                    message: message,
                    expectedGeneration: expectedGeneration
                )
            }
        case (false, false):
            if smartBoostStatus != .armed { smartBoostStatus = .armed }
        case (true, true):
            if smartBoostStatus != .boosting { smartBoostStatus = .boosting }
        }
    }

    private func runExpertCurveRule(expectedGeneration: UInt) async {
        guard expectedGeneration == controlRequestGeneration,
              activeMode == .expert,
              expertUsesCurve else { return }
        guard let temperature = snapshot.displayTemperature?.celsius,
              temperature.isFinite,
              !snapshot.fans.isEmpty else {
            await failSafeAfterControlFailure(
                capability: capability,
                message: "Manual curve released — trustworthy temperature telemetry was lost",
                expectedGeneration: expectedGeneration
            )
            return
        }

        let proposed = expertTargets()
        let fanSetChanged = Set(proposed.keys) != Set(verifiedMacFanTargets.keys)
        if !fanSetChanged, let lastCurveTemp, abs(temperature - lastCurveTemp) < 0.5 {
            return
        }
        let meaningfullyChanged = proposed.contains { id, rpm in
            guard let previous = verifiedMacFanTargets[id] else { return true }
            return abs(previous - rpm) >= max(previous * 0.015, 30)
        }
        guard fanSetChanged || meaningfullyChanged else { return }

        let fans = snapshot.fans
        guard expectedGeneration == controlRequestGeneration else { return }
        let result = await controls.apply(mode: .expert, fans: fans, targets: proposed)
        guard expectedGeneration == controlRequestGeneration,
              activeMode == .expert else { return }
        switch result {
        case .accepted(let confirmedTargets):
            verifiedMacFanTargets = confirmedTargets
            lastCurveTemp = temperature
        case .unavailable(let nextCapability, let message):
            await failSafeAfterControlFailure(
                capability: nextCapability,
                message: "Manual curve released — \(message)",
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func failSafeAfterControlFailure(
        capability nextCapability: ControlCapability,
        message: String,
        expectedGeneration: UInt
    ) async {
        guard expectedGeneration == controlRequestGeneration else { return }
        let context = beginSystemRestore(
            silent: true,
            forceHardware: true,
            capabilityOverride: nextCapability
        )
        await performSystemRestore(context)
        guard context.generation == controlRequestGeneration else { return }
        presentToast(message)
    }

    private func expertTargets() -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: snapshot.fans.map { fan in
            let target: Double
            if expertUsesCurve, let temperature = snapshot.displayTemperature?.celsius, let curve = expertCurves[fan.id] {
                target = curve.target(at: temperature, minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
            } else {
                target = expertRPM[fan.id] ?? fan.actualRPM
            }
            return (fan.id, min(max(target, fan.minimumRPM), fan.maximumRPM))
        })
    }

    private func seedTestHistory() async {
        let now = Date.now
        for index in 0..<60 {
            let progress = Double(index) / 59
            let timestamp = now.addingTimeInterval(-Double(59 - index) * 90)
            let temperature = 53 + sin(progress * .pi * 3.4) * 7 + progress * 4
            let actual = 2_900 + temperature * 8
            await historyStore.record(
                TelemetrySample(
                    timestamp: timestamp,
                    hottestCelsius: temperature,
                    cpuCelsius: temperature,
                    gpuCelsius: temperature - 2,
                    averageActualRPM: actual,
                    averageFirmwareTargetRPM: nil,
                    averageMacFanTargetRPM: nil,
                    mode: .system,
                    capability: .externalController
                )
            )
        }
    }

}
