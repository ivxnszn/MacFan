import XCTest
@testable import MacFan

final class FanControlSafetyTests: XCTestCase {
    private let safeLimits = [
        HelperFanLimit(id: 0, minimumRPM: 2_000, maximumRPM: 6_800),
        HelperFanLimit(id: 1, minimumRPM: 2_200, maximumRPM: 7_000)
    ]

    // MARK: Helper-owned target validation

    func testTargetsAreClampedToHelperDiscoveredLimitsRegardlessOfOrder() throws {
        let targets = try FanTargetValidator.validate(
            expected: safeLimits,
            fanIDs: [1, 0],
            rpms: [99_999, -10]
        )
        XCTAssertEqual(targets, [0: 2_000, 1: 7_000])
    }

    func testMismatchedParallelTargetArraysAreRejected() {
        assertValidationError(.countMismatch) {
            try FanTargetValidator.validate(expected: safeLimits, fanIDs: [0, 1], rpms: [3_000])
        }
    }

    func testDuplicateFanIDIsRejected() {
        assertValidationError(.duplicateFanID(0)) {
            try FanTargetValidator.validate(expected: safeLimits, fanIDs: [0, 0], rpms: [3_000, 4_000])
        }
    }

    func testMissingFanIDIsReported() {
        assertValidationError(.missingFanIDs([1])) {
            try FanTargetValidator.validate(expected: safeLimits, fanIDs: [0], rpms: [3_000])
        }
    }

    func testUnexpectedFanIDIsRejected() {
        assertValidationError(.unexpectedFanID(7)) {
            try FanTargetValidator.validate(expected: safeLimits, fanIDs: [0, 7], rpms: [3_000, 4_000])
        }
    }

    func testEveryNonFiniteRPMIsRejected() {
        for rpm in [Double.nan, .infinity, -.infinity] {
            assertValidationError(.nonFiniteRPM(1)) {
                try FanTargetValidator.validate(expected: safeLimits, fanIDs: [0, 1], rpms: [3_000, rpm])
            }
        }
    }

    func testUnsafeHelperLimitsAreRejectedBeforeTargets() {
        let unsafe = [
            HelperFanLimit(id: -1, minimumRPM: 2_000, maximumRPM: 6_800),
            HelperFanLimit(id: 8, minimumRPM: 2_000, maximumRPM: 6_800),
            HelperFanLimit(id: 0, minimumRPM: 499, maximumRPM: 6_800),
            HelperFanLimit(id: 0, minimumRPM: 2_000, maximumRPM: 20_001),
            HelperFanLimit(id: 0, minimumRPM: 6_800, maximumRPM: 6_800),
            HelperFanLimit(id: 0, minimumRPM: .nan, maximumRPM: 6_800),
            HelperFanLimit(id: 0, minimumRPM: 2_000, maximumRPM: .infinity)
        ]

        for limit in unsafe {
            assertValidationError(.invalidLimit(limit.id)) {
                try FanTargetValidator.validate(expected: [limit], fanIDs: [limit.id], rpms: [3_000])
            }
        }
    }

    func testDuplicateHelperLimitsAreRejected() {
        let duplicate = [
            HelperFanLimit(id: 0, minimumRPM: 2_000, maximumRPM: 6_800),
            HelperFanLimit(id: 0, minimumRPM: 2_000, maximumRPM: 6_800)
        ]
        assertValidationError(.invalidLimit(0)) {
            try FanTargetValidator.validate(expected: duplicate, fanIDs: [0, 0], rpms: [3_000, 3_000])
        }
    }

    // MARK: Watchdog lease

    func testLeaseExpiresExactlyAtItsDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        var lease = ControlLease(ttl: 12)
        lease.activate(sessionID: "owner", at: start)

        XCTAssertTrue(lease.hasActiveOverride)
        XCTAssertFalse(lease.isExpired(at: start.addingTimeInterval(11.999)))
        XCTAssertTrue(lease.isExpired(at: start.addingTimeInterval(12)))
    }

    func testHeartbeatExtendsOnlyTheOwningSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        var wrongOwnerLease = ControlLease(ttl: 12)
        wrongOwnerLease.activate(sessionID: "owner", at: start)

        XCTAssertFalse(wrongOwnerLease.heartbeat(sessionID: "intruder", at: start.addingTimeInterval(10)))
        XCTAssertTrue(wrongOwnerLease.isExpired(at: start.addingTimeInterval(12)))

        var ownerLease = ControlLease(ttl: 12)
        ownerLease.activate(sessionID: "owner", at: start)
        XCTAssertTrue(ownerLease.heartbeat(sessionID: "owner", at: start.addingTimeInterval(10)))
        XCTAssertFalse(ownerLease.isExpired(at: start.addingTimeInterval(21.999)))
        XCTAssertTrue(ownerLease.isExpired(at: start.addingTimeInterval(22)))
    }

    func testExpiredLeaseCannotBeRevivedByALateHeartbeat() {
        let start = Date(timeIntervalSince1970: 1_000)
        var lease = ControlLease(ttl: 12)
        lease.activate(sessionID: "owner", at: start)

        XCTAssertFalse(lease.heartbeat(sessionID: "owner", at: start.addingTimeInterval(12)))
        XCTAssertTrue(lease.isExpired(at: start.addingTimeInterval(12)))
    }

    func testDisconnectClearsOnlyTheOwningSession() {
        var lease = ControlLease(ttl: 12)
        lease.activate(sessionID: "owner", at: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(lease.disconnect(sessionID: "intruder"))
        XCTAssertEqual(lease.activeSessionID, "owner")
        XCTAssertTrue(lease.disconnect(sessionID: "owner"))
        XCTAssertFalse(lease.hasActiveOverride)
        XCTAssertNil(lease.activeSessionID)
        XCTAssertNil(lease.deadline)
    }

    func testUnsafeLeaseDurationsCannotDisableTheWatchdog() {
        XCTAssertEqual(ControlLease(ttl: -1).ttl, 3)
        XCTAssertEqual(ControlLease(ttl: 99).ttl, 30)
        XCTAssertEqual(ControlLease(ttl: .nan).ttl, 12)
        XCTAssertEqual(ControlLease(ttl: .infinity).ttl, 12)
        XCTAssertEqual(ControlLease(ttl: -.infinity).ttl, 12)
    }

    // MARK: Hardware-response preflight

    func testPreflightAcceptsMatchingTargetWhenFanIsAlreadyThere() {
        XCTAssertTrue(PreflightResponseVerifier.confirmed(
            before: 6_700,
            after: 6_760,
            target: 6_800,
            targetReadback: 6_800,
            limit: safeLimits[0]
        ))
    }

    func testPreflightAcceptsMaterialMovementTowardConfirmedTarget() {
        XCTAssertTrue(PreflightResponseVerifier.confirmed(
            before: 2_400,
            after: 4_000,
            target: 6_800,
            targetReadback: 6_790,
            limit: safeLimits[0]
        ))
    }

    func testPreflightRejectsInsufficientOrWrongDirectionMovement() {
        let limit = safeLimits[0]
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 2_450, target: 6_800, targetReadback: 6_800, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 3_000, after: 2_500, target: 6_800, targetReadback: 6_800, limit: limit))
    }

    func testPreflightRejectsReadbackMismatchAndUnsafeTarget() {
        let limit = safeLimits[0]
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 4_500, target: 6_800, targetReadback: 5_000, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 4_500, target: 7_000, targetReadback: 7_000, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 4_500, target: 1_000, targetReadback: 1_000, limit: limit))
    }

    func testPreflightRejectsEveryNonFiniteInputAndInvalidLimit() {
        let limit = safeLimits[0]
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: .nan, after: 4_500, target: 6_800, targetReadback: 6_800, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: .infinity, target: 6_800, targetReadback: 6_800, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 4_500, target: .nan, targetReadback: 6_800, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(before: 2_400, after: 4_500, target: 6_800, targetReadback: -.infinity, limit: limit))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(
            before: 2_400,
            after: 4_500,
            target: 6_800,
            targetReadback: 6_800,
            limit: HelperFanLimit(id: 0, minimumRPM: 6_800, maximumRPM: 6_800)
        ))
    }

    func testPreflightRejectsPhysicallyInvalidNegativeTelemetry() {
        XCTAssertFalse(PreflightResponseVerifier.confirmed(
            before: -100,
            after: 4_500,
            target: 6_800,
            targetReadback: 6_800,
            limit: safeLimits[0]
        ))
        XCTAssertFalse(PreflightResponseVerifier.confirmed(
            before: 2_400,
            after: -100,
            target: 6_800,
            targetReadback: 6_800,
            limit: safeLimits[0]
        ))
    }

    private func assertValidationError(
        _ expected: FanTargetValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Any
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? FanTargetValidationError, expected, file: file, line: line)
        }
    }
}
