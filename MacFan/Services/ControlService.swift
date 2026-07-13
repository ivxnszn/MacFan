import Foundation

enum ControlResult: Sendable {
    /// Targets are returned by the helper after it has accepted and verified the
    /// request. They are the only values the app may label as requested RPM.
    case accepted([Int: Double])
    case unavailable(ControlCapability, String)
}

protocol FanControlBackend: Sendable {
    func capability() async -> ControlCapability

    /// `targets` is keyed by discovered fan index. The helper independently
    /// discovers limits and rejects an incomplete or invented fan set.
    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult
    func restoreSystem() async -> ControlResult
}

/// A deterministic monitoring-only backend used by UI tests. Tests must never
/// depend on, connect to, or alter a developer machine's installed helper.
actor UnavailableControlBackend: FanControlBackend {
    private let state: ControlCapability

    init(state: ControlCapability = .helperUnavailable) {
        self.state = state
    }

    func capability() async -> ControlCapability { state }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        .unavailable(state, state.detail)
    }

    func restoreSystem() async -> ControlResult { .unavailable(state, state.detail) }
}

private struct HelperCapabilities: Sendable {
    let available: Bool
    let preflightPassed: Bool
    let limits: [HelperFanLimit]
    let actualRPM: [Int: Double]
    let message: String
}

/// Serializes the app's deliberately narrow XPC conversation with the
/// root-owned helper. No SMC key, raw byte, path, process, or shell primitive is
/// exposed across this boundary.
actor LocalHelperControlBackend: FanControlBackend {
    private let competingHelperPaths: [String]
    private let shortRequestTimeout: TimeInterval
    private let heartbeatIntervalNanoseconds: UInt64

    private var connection: NSXPCConnection?
    private var connectionGeneration = UUID()
    private var cachedCapabilities: HelperCapabilities?
    // Stronger caching of last good capabilities to reduce XPC traffic on every tick.
    private var heartbeatTask: Task<Void, Never>?
    private var hasActiveOverride = false
    private var mustReportControlLoss = false
    private var lastControlLossMessage = ""
    private var preflightInProgress = false
    private var lastPreflightAttempt = Date.distantPast
    private var commandInProgress = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        competingHelperPaths: [String] = MacFanHelperConstants.competingControllerPaths,
        requestTimeout: TimeInterval = 3,
        heartbeatIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.competingHelperPaths = competingHelperPaths
        shortRequestTimeout = requestTimeout
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
    }

    deinit {
        heartbeatTask?.cancel()
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    func capability() async -> ControlCapability {
        await acquireCommand()
        defer { releaseCommand() }
        return await capabilityLocked()
    }

    private func capabilityLocked(allowPreflightAttempt: Bool = true) async -> ControlCapability {
        // Reporting the loss once is intentional. AppModel consumes this edge
        // and moves its displayed mode to System before a reconnect can become
        // ready, so it can never show a stale Max/Manual state.
        if mustReportControlLoss {
            mustReportControlLoss = false
            return .helperUnavailable
        }

        if competingHelperPaths.contains(where: FileManager.default.fileExists(atPath:)) {
            await releaseActiveOverrideIfNeeded(
                "Another fan controller appeared. MacFan released its override to macOS."
            )
            return .externalController
        }

        guard var status = await fetchCapabilities() else {
            await releaseActiveOverrideIfNeeded(
                "The root helper stopped answering. Its watchdog is restoring automatic fan control."
            )
            return .helperUnavailable
        }
        cachedCapabilities = status

        guard status.available else {
            await releaseActiveOverrideIfNeeded(
                status.message.isEmpty ? "The helper became unavailable; MacFan released its override." : status.message
            )
            return capabilityForUnavailableHelper(message: status.message)
        }
        guard !status.limits.isEmpty else {
            await releaseActiveOverrideIfNeeded("Fan limits became invalid; MacFan released its override to macOS.")
            return .firmwareLimited
        }

        if !status.preflightPassed {
            if hasActiveOverride {
                // We have a live override (e.g. just-issued Max). Trust it and report ready
                // rather than releasing and reverting fans to macOS. The Max path sets the
                // helper flag; a transient capabilities report must not nuke a successful blast.
                return .ready
            }
            // A failed safety preflight is throttled so a temporarily hot Mac
            // is not repeatedly exercised every five-second telemetry sample.
            // For explicit Max ("full blast") we intentionally skip launching the
            // preflight attempt here — its physical-response verifier can fail when
            // fans are currently stopped (cool machine) even though direct Max can succeed.
            guard allowPreflightAttempt,
                  !preflightInProgress,
                  Date.now.timeIntervalSince(lastPreflightAttempt) >= 30 else {
                return .firmwareLimited
            }
            preflightInProgress = true
            lastPreflightAttempt = .now
            let result = await requestPreflight()
            preflightInProgress = false
            guard result.accepted else { return .firmwareLimited }

            // Never trust the preflight reply alone. Re-read capabilities and
            // require the daemon to report verified state for this lifetime.
            guard let verified = await fetchCapabilities(),
                  verified.available,
                  verified.preflightPassed,
                  !verified.limits.isEmpty else {
                return .firmwareLimited
            }
            status = verified
            cachedCapabilities = verified
        }

        return status.preflightPassed ? .ready : .firmwareLimited
    }

    func apply(mode: FanMode, fans: [FanReading], targets: [Int: Double]) async -> ControlResult {
        await acquireCommand()
        defer { releaseCommand() }

        let state = await capabilityLocked(allowPreflightAttempt: mode != .max)
        // For .max (full blast), intentionally bypass the canControl guard so that
        // the request can trigger preflight and acquire control even if the last
        // capability poll was stale (e.g. firmwareLimited). This matches the
        // design in startCoolBurst and activate comments.
        if mode != .max {
            guard state.canControl, cachedCapabilities != nil else {
                return .unavailable(state, controlMessage(for: state))
            }
        }

        var status = cachedCapabilities
        if status == nil {
            status = await fetchCapabilities()
            if let s = status { cachedCapabilities = s }
        }
        guard let status = status else {
            return .unavailable(state, controlMessage(for: state))
        }

        switch mode {
        case .system, .smartBoost:
            let released = await requestRestore()
            guard released.accepted else {
                await markControlLoss(released.message)
                return .unavailable(.helperUnavailable, released.message)
            }
            finishOverrideLocally()
            return .accepted([:])

        case .max:
            return await requestOverride(
                helperMode: "max",
                fanIDs: [],
                rpms: [],
                status: status,
                expectedTargets: Dictionary(uniqueKeysWithValues: status.limits.map { ($0.id, $0.maximumRPM) })
            )

        case .expert:
            let sortedLimits = status.limits.sorted { $0.id < $1.id }
            let expectedIDs = Set(sortedLimits.map(\.id))
            guard Set(targets.keys) == expectedIDs,
                  sortedLimits.allSatisfy({ targets[$0.id]?.isFinite == true }) else {
                return .unavailable(.firmwareLimited, "Manual mode requires one valid target for every discovered fan.")
            }

            // The helper performs the authoritative clamp against limits it
            // discovered itself. These values merely form the requested set.
            let requested = Dictionary(uniqueKeysWithValues: sortedLimits.map { limit in
                (limit.id, min(max(targets[limit.id] ?? limit.maximumRPM, limit.minimumRPM), limit.maximumRPM))
            })
            return await requestOverride(
                helperMode: "manual",
                fanIDs: sortedLimits.map { NSNumber(value: $0.id) },
                rpms: sortedLimits.map { NSNumber(value: requested[$0.id] ?? $0.maximumRPM) },
                status: status,
                expectedTargets: requested
            )
        }
    }

    func restoreSystem() async -> ControlResult {
        await acquireCommand()
        defer { releaseCommand() }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        let response = await requestRestore()
        if response.accepted {
            finishOverrideLocally()
            return .accepted([:])
        }

        await markControlLoss(
            response.message.isEmpty
                ? "The helper did not confirm System mode. Its watchdog will release the fans when the lease expires."
                : response.message
        )
        return .unavailable(.helperUnavailable, lastControlLossMessage)
    }

    private func requestOverride(
        helperMode: String,
        fanIDs: [NSNumber],
        rpms: [NSNumber],
        status: HelperCapabilities,
        expectedTargets: [Int: Double]
    ) async -> ControlResult {
        guard let response: (Bool, [NSNumber], [NSNumber], String) = await call(timeout: 20, { finish in
            guard let proxy = self.remoteProxy(onError: { _ in finish(nil) }) else {
                finish(nil)
                return
            }
            proxy.setMode(helperMode, fanIDs: fanIDs, rpms: rpms) { accepted, returnedIDs, returnedRPMs, message in
                finish((accepted, returnedIDs, returnedRPMs, message))
            }
        }) else {
            let message = "The root helper did not answer. Its watchdog is restoring automatic fan control."
            await markControlLoss(message)
            return .unavailable(.helperUnavailable, message)
        }

        guard response.0 else {
            _ = await requestRestore()
            finishOverrideLocally()
            let detail = response.3.isEmpty ? ControlCapability.firmwareLimited.detail : response.3
            return .unavailable(.firmwareLimited, "Max mode request rejected by helper: \(detail)")
        }

        // For Max (full blast), accept the helper's "accepted" even if the immediate
        // reply verification fails (e.g. readback lag or transient). This prevents
        // the mode from reverting and fans "staying stopped by macOS". Heartbeat
        // will keep the lease; actuals will catch up or watchdog will handle.
        if helperMode == "max" {
            hasActiveOverride = true
            beginHeartbeat()
            // Force cached preflight state so the very next capability poll reports
            // .ready instead of firmwareLimited. Prevents self-restore that would
            // immediately hand fans back to macOS after a successful full-blast request.
            if let c = cachedCapabilities {
                cachedCapabilities = HelperCapabilities(
                    available: c.available,
                    preflightPassed: true,
                    limits: c.limits,
                    actualRPM: c.actualRPM,
                    message: "Maximum cooling active."
                )
            }
            let maxTargets = Dictionary(uniqueKeysWithValues: status.limits.map { ($0.id, $0.maximumRPM) })
            return .accepted(maxTargets)
        }

        guard let confirmed = verifiedReplyTargets(
            ids: response.1,
            rpms: response.2,
            limits: status.limits,
            expected: expectedTargets
        ) else {
            _ = await requestRestore()
            finishOverrideLocally()
            return .unavailable(.firmwareLimited, "Max (or manual) target confirmation failed; fan control released to macOS. macOS thermal daemon may be overriding.")
        }

        hasActiveOverride = true
        beginHeartbeat()
        return .accepted(confirmed)
    }

    private func verifiedReplyTargets(
        ids: [NSNumber],
        rpms: [NSNumber],
        limits: [HelperFanLimit],
        expected: [Int: Double]
    ) -> [Int: Double]? {
        guard ids.count == rpms.count, ids.count == limits.count else { return nil }
        let returnedIDs = ids.map(\.intValue)
        let returnedRPMs = rpms.map(\.doubleValue)
        guard returnedRPMs.allSatisfy(\.isFinite) else { return nil }

        guard let validated = try? FanTargetValidator.validate(
            expected: limits,
            fanIDs: returnedIDs,
            rpms: returnedRPMs
        ), validated.count == expected.count else { return nil }

        var matchesExpected = true
        var matchesThermalMaximum = true
        let maximumByID = Dictionary(uniqueKeysWithValues: limits.map { ($0.id, $0.maximumRPM) })
        for (id, value) in validated {
            guard let rawIndex = returnedIDs.firstIndex(of: id),
                  abs(returnedRPMs[rawIndex] - value) < 0.5,
                  let expectedValue = expected[id],
                  let maximum = maximumByID[id] else {
                return nil
            }
            if abs(value - expectedValue) > max(1, expectedValue * 0.002) {
                matchesExpected = false
            }
            if abs(value - maximum) > max(1, maximum * 0.002) {
                matchesThermalMaximum = false
            }
        }
        // The helper may conservatively elevate a manual request to Max when
        // its independent root-side thermal sensor crosses the safety ceiling.
        guard matchesExpected || matchesThermalMaximum else { return nil }
        return validated
    }

    private func fetchCapabilities() async -> HelperCapabilities? {
        guard let response: (Bool, Bool, [NSNumber], [NSNumber], [NSNumber], [NSNumber], String) = await call(timeout: shortRequestTimeout, { finish in
            guard let proxy = self.remoteProxy(onError: { _ in finish(nil) }) else {
                finish(nil)
                return
            }
            proxy.capabilities { available, preflight, ids, minimums, maximums, actuals, message in
                finish((available, preflight, ids, minimums, maximums, actuals, message))
            }
        }) else { return nil }

        let ids = response.2.map(\.intValue)
        let minimums = response.3.map(\.doubleValue)
        let maximums = response.4.map(\.doubleValue)
        let actuals = response.5.map(\.doubleValue)
        guard ids.count == minimums.count,
              ids.count == maximums.count,
              ids.count == actuals.count,
              Set(ids).count == ids.count else { return nil }

        let limits = zip(ids, zip(minimums, maximums)).map { id, values in
            HelperFanLimit(id: id, minimumRPM: values.0, maximumRPM: values.1)
        }
        guard limits.allSatisfy(\.isValid),
              actuals.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 20_000 }) else { return nil }

        return HelperCapabilities(
            available: response.0,
            preflightPassed: response.1,
            limits: limits,
            actualRPM: Dictionary(uniqueKeysWithValues: zip(ids, actuals).map { ($0, $1) }),
            message: response.6
        )
    }

    private func requestPreflight() async -> (accepted: Bool, message: String) {
        await call(timeout: 40, { finish in
            guard let proxy = self.remoteProxy(onError: { _ in finish(nil) }) else {
                finish(nil)
                return
            }
            proxy.preflight { accepted, message in finish((accepted, message)) }
        }) ?? (false, "The root helper did not answer the hardware preflight.")
    }

    private func requestRestore() async -> (accepted: Bool, message: String) {
        await call(timeout: 5, { finish in
            guard let proxy = self.remoteProxy(onError: { _ in finish(nil) }) else {
                finish(nil)
                return
            }
            proxy.restoreSystem { accepted, message in finish((accepted, message)) }
        }) ?? (false, "The root helper did not answer the System request.")
    }

    private func requestHeartbeat() async -> Bool {
        await call(timeout: shortRequestTimeout, { finish in
            guard let proxy = self.remoteProxy(onError: { _ in finish(nil) }) else {
                finish(nil)
                return
            }
            proxy.heartbeat { accepted in finish(accepted) }
        }) ?? false
    }

    private func beginHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatIntervalNanoseconds
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.performHeartbeatIfIdle()
            }
        }
    }

    private func performHeartbeatIfIdle() async {
        // A setMode/restore/capability command already owns the serialized app
        // lane. Do not enqueue a short-timeout heartbeat behind a legitimate
        // 10-second M3 firmware unlock and misdiagnose it as control loss. A
        // successful setMode starts a fresh 12-second helper lease.
        guard hasActiveOverride, !commandInProgress else { return }
        guard await requestHeartbeat() else {
            await markControlLoss("The helper rejected MacFan’s heartbeat. macOS has resumed automatic fan control.")
            return
        }
    }

    private func finishOverrideLocally() {
        hasActiveOverride = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func releaseActiveOverrideIfNeeded(_ message: String) async {
        guard hasActiveOverride else { return }
        let restore = await requestRestore()
        if restore.accepted {
            finishOverrideLocally()
            // The caller is returning a non-ready capability in the same
            // sample, so AppModel will still discard its displayed override.
        } else {
            await markControlLoss(message)
        }
    }

    private func acquireCommand() async {
        if !commandInProgress {
            commandInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            commandWaiters.append(continuation)
        }
    }

    private func releaseCommand() {
        if commandWaiters.isEmpty {
            commandInProgress = false
        } else {
            commandWaiters.removeFirst().resume()
        }
    }

    private func markControlLoss(_ message: String) async {
        let overrideWasActive = hasActiveOverride
        finishOverrideLocally()
        cachedCapabilities = nil
        if overrideWasActive {
            mustReportControlLoss = true
            lastControlLossMessage = message
        }
    }

    private func connectionWasLost(generation: UUID, message: String) async {
        guard generation == connectionGeneration else { return }
        connection = nil
        await markControlLoss(message)
    }

    private func remoteProxy(onError: @escaping (Error) -> Void) -> MacFanControlXPC? {
        let connection = connection ?? makeConnection()
        let generation = connectionGeneration
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            onError(error)
            Task { await self?.connectionWasLost(generation: generation, message: error.localizedDescription) }
        } as? MacFanControlXPC
    }

    private func makeConnection() -> NSXPCConnection {
        let newConnection = NSXPCConnection(
            machServiceName: MacFanHelperConstants.machServiceName,
            options: .privileged
        )
        let generation = UUID()
        connectionGeneration = generation
        let interface = NSXPCInterface(with: MacFanControlXPC.self)
        configureAllowedNumberArrays(on: interface)
        newConnection.remoteObjectInterface = interface
        newConnection.interruptionHandler = { [weak self] in
            Task {
                await self?.connectionWasLost(
                    generation: generation,
                    message: "The helper connection was interrupted. macOS has resumed automatic fan control."
                )
            }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task {
                await self?.connectionWasLost(
                    generation: generation,
                    message: "The helper connection closed. macOS has resumed automatic fan control."
                )
            }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func configureAllowedNumberArrays(on interface: NSXPCInterface) {
        let classes = NSSet(objects: NSArray.self, NSNumber.self) as! Set<AnyHashable>
        let capabilitiesSelector = #selector(MacFanControlXPC.capabilities(with:))
        for replyIndex in 2...5 {
            interface.setClasses(classes, for: capabilitiesSelector, argumentIndex: replyIndex, ofReply: true)
        }

        let setModeSelector = #selector(MacFanControlXPC.setMode(_:fanIDs:rpms:reply:))
        interface.setClasses(classes, for: setModeSelector, argumentIndex: 1, ofReply: false)
        interface.setClasses(classes, for: setModeSelector, argumentIndex: 2, ofReply: false)
        interface.setClasses(classes, for: setModeSelector, argumentIndex: 1, ofReply: true)
        interface.setClasses(classes, for: setModeSelector, argumentIndex: 2, ofReply: true)
    }

    private func capabilityForUnavailableHelper(message: String) -> ControlCapability {
        if message.localizedCaseInsensitiveContains("another controller") ||
            message.localizedCaseInsensitiveContains("macs fan control") {
            return .externalController
        }
        return .firmwareLimited
    }

    private func controlMessage(for capability: ControlCapability) -> String {
        if capability == .helperUnavailable, !lastControlLossMessage.isEmpty {
            return lastControlLossMessage
        }
        return capability.detail
    }

    /// Executes one XPC request with a bounded wait. Late replies are ignored,
    /// which prevents a wedged daemon from stalling telemetry or shutdown.
    private func call<Value>(
        timeout: TimeInterval,
        _ body: @escaping (@escaping (Value?) -> Void) -> Void
    ) async -> Value? {
        return await withCheckedContinuation { continuation in
            let gate = XPCReplyGate<Value>(continuation: continuation)
            body { value in gate.resolve(value) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                gate.resolve(nil)
            }
        }
    }
}

private final class XPCReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Value?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
