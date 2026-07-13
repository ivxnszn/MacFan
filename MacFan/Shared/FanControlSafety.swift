import Foundation

/// A hardware limit discovered by the privileged helper itself. App-provided
/// fan limits are never trusted for a write.
struct HelperFanLimit: Equatable, Sendable {
    let id: Int
    let minimumRPM: Double
    let maximumRPM: Double

    var isValid: Bool {
        id >= 0 && id < 8 &&
            minimumRPM.isFinite && maximumRPM.isFinite &&
            minimumRPM >= 500 && maximumRPM <= 20_000 &&
            maximumRPM > minimumRPM
    }
}

enum FanTargetValidationError: Error, LocalizedError, Equatable, Sendable {
    case countMismatch
    case duplicateFanID(Int)
    case missingFanIDs([Int])
    case unexpectedFanID(Int)
    case nonFiniteRPM(Int)
    case invalidLimit(Int)

    var errorDescription: String? {
        switch self {
        case .countMismatch:
            "Every fan must have exactly one RPM target."
        case .duplicateFanID(let id):
            "Fan \(id) was supplied more than once."
        case .missingFanIDs(let ids):
            "Targets are missing for fan IDs \(ids.map(String.init).joined(separator: ", "))."
        case .unexpectedFanID(let id):
            "Fan \(id) does not exist on this Mac."
        case .nonFiniteRPM(let id):
            "Fan \(id) has an invalid RPM target."
        case .invalidLimit(let id):
            "Fan \(id) reported unsafe hardware limits."
        }
    }
}

/// Validates a complete fan request and clamps every finite target to limits
/// read by the root helper. Duplicate, omitted, invented, and non-finite
/// targets are rejected rather than guessed.
enum FanTargetValidator {
    static func validate(
        expected limits: [HelperFanLimit],
        fanIDs: [Int],
        rpms: [Double]
    ) throws -> [Int: Double] {
        guard fanIDs.count == rpms.count else {
            throw FanTargetValidationError.countMismatch
        }

        var limitByID: [Int: HelperFanLimit] = [:]
        for limit in limits {
            guard limit.isValid else { throw FanTargetValidationError.invalidLimit(limit.id) }
            guard limitByID.updateValue(limit, forKey: limit.id) == nil else {
                throw FanTargetValidationError.invalidLimit(limit.id)
            }
        }

        var result: [Int: Double] = [:]
        for (id, rpm) in zip(fanIDs, rpms) {
            guard let limit = limitByID[id] else {
                throw FanTargetValidationError.unexpectedFanID(id)
            }
            guard result[id] == nil else {
                throw FanTargetValidationError.duplicateFanID(id)
            }
            guard rpm.isFinite else {
                throw FanTargetValidationError.nonFiniteRPM(id)
            }
            result[id] = min(max(rpm, limit.minimumRPM), limit.maximumRPM)
        }

        let missing = Set(limitByID.keys).subtracting(result.keys).sorted()
        guard missing.isEmpty else { throw FanTargetValidationError.missingFanIDs(missing) }
        return result
    }
}

/// Pure lease state used by the daemon watchdog. Only the connection that
/// owns an override can renew or disconnect it.
struct ControlLease: Equatable, Sendable {
    let ttl: TimeInterval
    private(set) var activeSessionID: String?
    private(set) var deadline: Date?

    init(ttl: TimeInterval = 12) {
        // A lease is the fail-safe. Non-finite or extreme durations must never
        // turn a temporary override into permanent fan ownership.
        self.ttl = ttl.isFinite ? min(max(3, ttl), 30) : 12
    }

    var hasActiveOverride: Bool { activeSessionID != nil }

    mutating func activate(sessionID: String, at date: Date = .now) {
        activeSessionID = sessionID
        deadline = date.addingTimeInterval(ttl)
    }

    @discardableResult
    mutating func heartbeat(sessionID: String, at date: Date = .now) -> Bool {
        guard activeSessionID == sessionID,
              let currentDeadline = deadline,
              date < currentDeadline else { return false }
        self.deadline = date.addingTimeInterval(ttl)
        return true
    }

    @discardableResult
    mutating func disconnect(sessionID: String) -> Bool {
        guard activeSessionID == sessionID else { return false }
        clear()
        return true
    }

    func isExpired(at date: Date = .now) -> Bool {
        guard activeSessionID != nil, let deadline else { return false }
        return date >= deadline
    }

    mutating func clear() {
        activeSessionID = nil
        deadline = nil
    }
}

enum PreflightResponseVerifier {
    /// Confirms the SMC accepted the target and the physical fan either moved
    /// materially toward it or is already within a tight tolerance.
    static func confirmed(
        before: Double,
        after: Double,
        target: Double,
        targetReadback: Double,
        limit: HelperFanLimit
    ) -> Bool {
        let values = [before, after, target, targetReadback]
        guard limit.isValid,
              values.allSatisfy(\.isFinite),
              before >= 0, after >= 0,
              before <= 20_000, after <= 20_000 else { return false }
        guard target >= limit.minimumRPM, target <= limit.maximumRPM else { return false }

        let readbackTolerance = max(60, target * 0.015)
        guard abs(targetReadback - target) <= readbackTolerance else { return false }

        let physicalTolerance = max(140, target * 0.08)
        if abs(after - target) <= physicalTolerance { return true }

        let desiredDelta = abs(target - before)
        guard desiredDelta >= 120 else { return false }
        let movementTowardTarget = abs(target - before) - abs(target - after)
        return movementTowardTarget >= min(120, desiredDelta * 0.25)
    }
}
