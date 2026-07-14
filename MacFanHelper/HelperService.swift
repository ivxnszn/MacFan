import Foundation
import IOKit.pwr_mgt
import OSLog

private let helperLog = Logger(subsystem: "local.macfan.helper", category: "control")
// IOMessage.h expresses these as C macros that Swift cannot import.
private let messageCanSystemSleep: natural_t = 0xe0000270
private let messageSystemWillSleep: natural_t = 0xe0000280
private let messageSystemHasPoweredOn: natural_t = 0xe0000300

private final class HelperSession: NSObject, MacFanControlXPC {
    let id = UUID().uuidString
    weak var service: MacFanHelperService?

    init(service: MacFanHelperService) {
        self.service = service
    }

    func capabilities(
        with reply: @escaping (Bool, Bool, [NSNumber], [NSNumber], [NSNumber], [NSNumber], String) -> Void
    ) {
        service?.capabilities(sessionID: id, reply: reply)
            ?? reply(false, false, [], [], [], [], "The helper session ended.")
    }

    func preflight(with reply: @escaping (Bool, String) -> Void) {
        service?.preflight(sessionID: id, reply: reply)
            ?? reply(false, "The helper session ended.")
    }

    func setMode(
        _ mode: String,
        fanIDs: [NSNumber],
        rpms: [NSNumber],
        reply: @escaping (Bool, [NSNumber], [NSNumber], String) -> Void
    ) {
        service?.setMode(mode, sessionID: id, fanIDs: fanIDs, rpms: rpms, reply: reply)
            ?? reply(false, [], [], "The helper session ended.")
    }

    func restoreSystem(with reply: @escaping (Bool, String) -> Void) {
        service?.restoreSystem(sessionID: id, reply: reply)
            ?? reply(false, "The helper session ended.")
    }

    func heartbeat(with reply: @escaping (Bool) -> Void) {
        service?.heartbeat(sessionID: id, reply: reply) ?? reply(false)
    }
}

final class MacFanHelperService: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let authenticator: ClientAuthenticator
    private let controlQueue = DispatchQueue(label: "local.macfan.helper.control", qos: .userInitiated)
    private var connections: [String: NSXPCConnection] = [:]
    private var hardware: SMCFanHardwareController?
    private var preflightPassed = false
    private var lease = ControlLease(ttl: 12)
    private var activeTargets: [Int: Double] = [:]
    private var restorePending = false
    private var watchdog: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var rootPowerPort: io_connect_t = 0
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    init(configuration: HelperConfiguration) {
        authenticator = ClientAuthenticator(configuration: configuration)
        listener = NSXPCListener(machServiceName: MacFanHelperConstants.machServiceName)
        super.init()
        listener.delegate = self
    }

    func run() -> Never {
        installTerminationHandlers()
        installPowerObserver()
        startWatchdog()

        controlQueue.sync {
            if competingControllerPresent() {
                helperLog.error("startup restore skipped: competing controller present")
            } else {
                restoreLocked(reason: "helper startup")
            }
        }
        listener.resume()
        helperLog.notice("MacFan helper started")
        RunLoop.current.run()
        fatalError("MacFan helper run loop exited unexpectedly")
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        do {
            try authenticator.validate(connection)
        } catch {
            helperLog.error("XPC caller rejected: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let session = HelperSession(service: self)
        let sessionID = session.id
        let interface = NSXPCInterface(with: MacFanControlXPC.self)
        let numericArrayClasses = NSSet(objects: NSArray.self, NSNumber.self) as! Set<AnyHashable>
        for index in 2...5 {
            interface.setClasses(
                numericArrayClasses,
                for: #selector(MacFanControlXPC.capabilities(with:)),
                argumentIndex: index,
                ofReply: true
            )
        }
        for index in 1...2 {
            interface.setClasses(
                numericArrayClasses,
                for: #selector(MacFanControlXPC.setMode(_:fanIDs:rpms:reply:)),
                argumentIndex: index,
                ofReply: false
            )
            interface.setClasses(
                numericArrayClasses,
                for: #selector(MacFanControlXPC.setMode(_:fanIDs:rpms:reply:)),
                argumentIndex: index,
                ofReply: true
            )
        }
        connection.exportedInterface = interface
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in self?.sessionEnded(sessionID) }
        connection.interruptionHandler = { [weak self] in self?.sessionEnded(sessionID) }
        controlQueue.sync { connections[sessionID] = connection }
        connection.resume()
        helperLog.info("authorized XPC session opened pid=\(connection.processIdentifier)")
        return true
    }

    func capabilities(
        sessionID: String,
        reply: @escaping (Bool, Bool, [NSNumber], [NSNumber], [NSNumber], [NSNumber], String) -> Void
    ) {
        controlQueue.async {
            guard self.connections[sessionID] != nil else {
                reply(false, false, [], [], [], [], "The helper session is no longer active.")
                return
            }
            guard !self.competingControllerPresent() else {
                if self.lease.hasActiveOverride {
                    self.restoreLocked(reason: "competing controller detected by capability check")
                }
                reply(false, false, [], [], [], [], "Macs Fan Control's helper is still installed. Run the replacement installer first.")
                return
            }
            do {
                let hardware = try self.ensureHardware()
                let states = try hardware.states()
                reply(
                    true,
                    self.preflightPassed,
                    states.map { NSNumber(value: $0.limit.id) },
                    states.map { NSNumber(value: $0.limit.minimumRPM) },
                    states.map { NSNumber(value: $0.limit.maximumRPM) },
                    states.map { NSNumber(value: $0.actualRPM) },
                    self.preflightPassed ? "Experimental control verified." : "Ready for one-time hardware preflight."
                )
            } catch {
                reply(false, false, [], [], [], [], error.localizedDescription)
            }
        }
    }

    func preflight(sessionID: String, reply: @escaping (Bool, String) -> Void) {
        controlQueue.async {
            guard self.connections[sessionID] != nil else {
                reply(false, "The helper session is no longer active.")
                return
            }
            guard !self.competingControllerPresent() else {
                reply(false, "Macs Fan Control's helper must be removed before preflight.")
                return
            }
            if self.preflightPassed {
                reply(true, "Hardware control is already verified for this helper session.")
                return
            }
            do {
                let hardware = try self.ensureHardware()
                try hardware.preflight()
                self.lease.clear()
                self.activeTargets = [:]
                self.preflightPassed = true
                helperLog.notice("preflight passed; physical response and Auto restore confirmed")
                reply(true, "Fan response verified and returned to macOS Auto.")
            } catch {
                helperLog.error("preflight failed: \(error.localizedDescription, privacy: .public)")
                self.restoreLocked(reason: "preflight failure")
                reply(false, error.localizedDescription)
            }
        }
    }

    func setMode(
        _ mode: String,
        sessionID: String,
        fanIDs: [NSNumber],
        rpms: [NSNumber],
        reply: @escaping (Bool, [NSNumber], [NSNumber], String) -> Void
    ) {
        controlQueue.async {
            guard self.connections[sessionID] != nil else {
                reply(false, [], [], "The helper session is no longer active.")
                return
            }
            guard self.preflightPassed || mode == "max" else {
                // Allow Max even without prior preflight; first Max will serve as the verification
                // and set the flag if successful. This fixes cases where preflight "response"
                // check fails because fans are stopped by macOS when cool, but user wants full blast.
                reply(false, [], [], "Run the one-time hardware preflight first.")
                return
            }
            guard !self.competingControllerPresent() else {
                self.restoreLocked(reason: "competing controller appeared")
                reply(false, [], [], "Another fan controller is installed.")
                return
            }
            if let owner = self.lease.activeSessionID, owner != sessionID {
                reply(false, [], [], "Another authorized MacFan session currently owns the fans.")
                return
            }

            do {
                let hardware = try self.ensureHardware()
                let requested: [Int: Double]
                switch mode {
                case "max":
                    guard fanIDs.isEmpty, rpms.isEmpty else {
                        throw FanTargetValidationError.countMismatch
                    }
                    requested = hardware.targetsForMaximum()
                case "manual":
                    requested = try FanTargetValidator.validate(
                        expected: hardware.limits,
                        fanIDs: fanIDs.map(\.intValue),
                        rpms: rpms.map(\.doubleValue)
                    )
                default:
                    reply(false, [], [], "Unsupported control mode.")
                    return
                }

                let temperature = try hardware.hottestTemperature()
                let maximums = hardware.targetsForMaximum()
                if temperature >= 92,
                   requested.contains(where: { id, rpm in rpm < (maximums[id] ?? rpm) - 1 }) {
                    self.restoreLocked(reason: "lower manual target rejected at critical temperature")
                    reply(false, [], [], "The Mac is \(Int(temperature.rounded()))°C. Use Max until it cools below 92°C.")
                    return
                }

                try hardware.apply(targets: requested)
                self.lease.activate(sessionID: sessionID)
                self.activeTargets = requested
                if mode == "max" {
                    self.preflightPassed = true
                    // Extra immediate reassert after the verified apply. Helps counters
                    // thermalmonitord reclaim on first lease grant, especially when fans
                    // were previously stopped (0 RPM) under macOS control.
                    hardware.reassert(targets: requested)
                }
                let ids = requested.keys.sorted()
                let message = mode == "max" ? "Maximum cooling is active." : "Manual fan targets are active."
                reply(true, ids.map { NSNumber(value: $0) }, ids.map { NSNumber(value: requested[$0] ?? 0) }, message)
            } catch {
                self.restoreLocked(reason: "control request failure")
                reply(false, [], [], error.localizedDescription)
            }
        }
    }

    func restoreSystem(sessionID: String, reply: @escaping (Bool, String) -> Void) {
        controlQueue.async {
            let restored = self.restoreLocked(reason: "app requested System")
            reply(restored, restored ? "macOS Auto control restored." : HelperSMCError.restoreNotConfirmed.localizedDescription)
        }
    }

    func heartbeat(sessionID: String, reply: @escaping (Bool) -> Void) {
        controlQueue.async {
            let accepted = self.lease.heartbeat(sessionID: sessionID)
            if accepted, let hw = self.hardware, !self.activeTargets.isEmpty {
                // Reassert to counter macOS/thermalmonitord reclaiming manual mode
                // or zeroing targets. Critical for reliable sustained Max.
                hw.reassert(targets: self.activeTargets)
            }
            reply(accepted)
        }
    }

    private func sessionEnded(_ sessionID: String) {
        controlQueue.async {
            self.connections[sessionID] = nil
            if self.lease.disconnect(sessionID: sessionID) {
                self.restoreLocked(reason: "app connection ended")
            }
        }
    }

    private func ensureHardware() throws -> SMCFanHardwareController {
        if let hardware { return hardware }
        let opened = try SMCFanHardwareController()
        hardware = opened
        return opened
    }

    @discardableResult
    private func restoreLocked(reason: String) -> Bool {
        let hadActiveOverride = lease.hasActiveOverride
        let restored: Bool
        if let hardware {
            restored = hardware.restoreSystem()
        } else if let opened = try? SMCFanHardwareController() {
            hardware = opened
            restored = opened.restoreSystem()
        } else {
            // With no open/manual SMC session there is nothing helper-owned to
            // retain. Firmware also reclaims control when the connection dies.
            restored = !hadActiveOverride
        }
        if restored {
            restorePending = false
            lease.clear()
            activeTargets = [:]
        } else {
            // Keep retry state alive until Auto is positively read back. A
            // failed first attempt must never strand manual mode unattended.
            restorePending = true
            hardware = nil
        }
        helperLog.notice("restore System reason=\(reason, privacy: .public) confirmed=\(restored)")
        return restored
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        if restorePending {
            _ = restoreLocked(reason: "retry pending Auto restore")
            return
        }
        guard lease.hasActiveOverride else { return }
        if competingControllerPresent() {
            restoreLocked(reason: "competing controller detected by watchdog")
            return
        }
        if lease.isExpired() {
            restoreLocked(reason: "heartbeat watchdog expired")
            return
        }
        do {
            let hardware = try ensureHardware()
            let states = try hardware.states()
            let temperature = try hardware.hottestTemperature()
            guard states.count == hardware.limits.count,
                  states.allSatisfy({ state in
                      guard state.isManual, state.actualRPM.isFinite,
                            let expected = activeTargets[state.limit.id] else { return false }
                      return abs(state.targetRPM - expected) <= max(60, expected * 0.015)
                  }) else {
                // Lightweight reassert to recover from transient macOS override
                // before immediately restoring. Re-check once; only nuke lease
                // on persistent loss. This is the key fix for Max mode sticking.
                hardware.reassert(targets: activeTargets)
                do {
                    let rechecked = try hardware.states()
                    let stillGood = rechecked.count == hardware.limits.count &&
                        rechecked.allSatisfy({ state in
                            guard state.isManual, state.actualRPM.isFinite,
                                  let expected = activeTargets[state.limit.id] else { return false }
                            return abs(state.targetRPM - expected) <= max(60, expected * 0.015)
                        })
                    if stillGood { return }
                } catch {}
                restoreLocked(reason: "invalid fan telemetry or manual mode lost")
                return
            }
            if temperature >= 92 {
                let maximums = hardware.targetsForMaximum()
                if activeTargets != maximums {
                    restoreLocked(reason: "critical temperature while lower manual target active")
                }
            }
        } catch {
            restoreLocked(reason: "watchdog telemetry failure: \(error.localizedDescription)")
        }
    }

    private func competingControllerPresent() -> Bool {
        MacFanHelperConstants.competingControllerPaths.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: controlQueue)
            source.setEventHandler { [weak self] in
                self?.restoreLocked(reason: "helper termination signal \(signalNumber)")
                exit(EXIT_SUCCESS)
            }
            signalSources.append(source)
            source.resume()
        }
    }

    private func installPowerObserver() {
        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let rootPort = IORegisterForSystemPower(refcon, &notificationPort, macFanPowerCallback, &notifier)
        guard rootPort != 0, let notificationPort else {
            helperLog.error("power observer unavailable; watchdog will restore immediately after wake")
            return
        }
        rootPowerPort = rootPort
        powerNotificationPort = notificationPort
        powerNotifier = notifier
        if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
    }

    fileprivate func handlePowerMessage(_ messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPowerPort, notificationID)
        case messageSystemWillSleep:
            controlQueue.async {
                self.restoreLocked(reason: "system sleep")
                IOAllowPowerChange(self.rootPowerPort, notificationID)
            }
        case messageSystemHasPoweredOn:
            controlQueue.async {
                self.hardware = nil
                self.preflightPassed = false
                self.restoreLocked(reason: "system wake; control preflight invalidated")
            }
        default:
            break
        }
    }
}

private func macFanPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<MacFanHelperService>.fromOpaque(refcon).takeUnretainedValue()
        .handlePowerMessage(messageType, argument: messageArgument)
}
