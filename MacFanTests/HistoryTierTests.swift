import SQLite3
import XCTest
@testable import MacFan

/// Multi-resolution retention: rollup tiers, peak preservation, legacy
/// migration, pruning bounds and gap segmentation.
final class HistoryTierTests: XCTestCase {
    private func sample(
        at timestamp: Date,
        temperature: Double?,
        cpuTemperature: Double? = nil,
        rpm: Double? = nil,
        firmwareTarget: Double? = nil,
        macFanTarget: Double? = nil,
        mode: FanMode = .system,
        capability: ControlCapability = .monitoring
    ) -> TelemetrySample {
        TelemetrySample(
            timestamp: timestamp,
            hottestCelsius: temperature,
            cpuCelsius: cpuTemperature ?? temperature,
            gpuCelsius: nil,
            averageActualRPM: rpm,
            averageFirmwareTargetRPM: firmwareTarget,
            averageMacFanTargetRPM: macFanTarget,
            mode: mode,
            capability: capability
        )
    }

    func testRawRangeQueriesPreserveBucketExtremes() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Both land in the same 30-second 1H display bucket.
        let base = Date(timeIntervalSince1970: floor(1_700_000_000 / 30) * 30 - 600)
        await store.record(sample(at: base, temperature: 50, rpm: 2_000))
        await store.record(sample(at: base.addingTimeInterval(10), temperature: 70, rpm: 4_000))

        let history = await store.samples(for: .hour, now: now)
        let bucket = history.first { $0.minCelsius != nil }
        XCTAssertEqual(bucket?.minCelsius ?? .nan, 50, accuracy: 0.001)
        XCTAssertEqual(bucket?.maxCelsius ?? .nan, 70, accuracy: 0.001)
        XCTAssertEqual(bucket?.hottestCelsius ?? .nan, 60, accuracy: 0.001)
        XCTAssertEqual(bucket?.minCPUCelsius ?? .nan, 50, accuracy: 0.001)
        XCTAssertEqual(bucket?.maxCPUCelsius ?? .nan, 70, accuracy: 0.001)
        XCTAssertEqual(bucket?.minRPM ?? .nan, 2_000, accuracy: 0.001)
        XCTAssertEqual(bucket?.maxRPM ?? .nan, 4_000, accuracy: 0.001)
        await store.close()
    }

    func testTelemetrySampleDecodesPayloadFromBeforeAggregateMetadata() throws {
        let original = sample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            temperature: 64,
            cpuTemperature: 61,
            rpm: 3_200,
            mode: .smartBoost,
            capability: .ready
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "minCPUCelsius")
        object.removeValue(forKey: "maxCPUCelsius")
        object.removeValue(forKey: "recordedCoverageSeconds")
        object.removeValue(forKey: "modeDurations")
        object.removeValue(forKey: "thermalBandDurations")

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TelemetrySample.self, from: legacyPayload)
        XCTAssertEqual(decoded.cpuCelsius, 61)
        XCTAssertEqual(decoded.mode, .smartBoost)
        XCTAssertNil(decoded.minCPUCelsius)
        XCTAssertNil(decoded.recordedCoverageSeconds)
    }

    func testRolledTiersPreserveSpikesInLongRanges() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        // A 30-second spike to 90° inside an otherwise 40° minute must survive
        // aggregation into the week view instead of averaging away.
        await store.record(sample(at: old, temperature: 40, rpm: 2_500, mode: .max, capability: .ready))
        await store.record(sample(at: old.addingTimeInterval(30), temperature: 90, rpm: 6_500, mode: .max, capability: .ready))
        // Trigger the rollup cascade with a fresh sample past the 24 h cutoff.
        await store.record(sample(at: now, temperature: 55))

        let week = await store.samples(for: .week, now: now)
        let rolled = week.first { abs($0.timestamp.timeIntervalSince(old)) < 3_600 }
        XCTAssertNotNil(rolled)
        XCTAssertEqual(rolled?.maxCelsius ?? .nan, 90, accuracy: 0.001)
        XCTAssertEqual(rolled?.minCelsius ?? .nan, 40, accuracy: 0.001)
        XCTAssertEqual(rolled?.hottestCelsius ?? .nan, 65, accuracy: 0.001)
        XCTAssertEqual(rolled?.maxRPM ?? .nan, 6_500, accuracy: 0.001)
        XCTAssertEqual(rolled?.mode, .max, "An active mode must not be shadowed by aggregation")

        let month = await store.samples(for: .month, now: now)
        let monthBucket = month.first { abs($0.timestamp.timeIntervalSince(old)) < 7_200 }
        XCTAssertEqual(monthBucket?.maxCelsius ?? .nan, 90, accuracy: 0.001)
        await store.close()
    }

    func testCPUExtremesAndWeightedAverageSurviveBothLongTiers() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hour = floor(now.addingTimeInterval(-26 * 60 * 60).timeIntervalSince1970 / 3_600) * 3_600

        // Uneven sample counts across minute buckets catch an accidental
        // average-of-averages. The true average is (40 + 80 + 90 + 100) / 4.
        await store.record(sample(at: Date(timeIntervalSince1970: hour + 10), temperature: 60, cpuTemperature: 40))
        await store.record(sample(at: Date(timeIntervalSince1970: hour + 70), temperature: 62, cpuTemperature: 80))
        await store.record(sample(at: Date(timeIntervalSince1970: hour + 80), temperature: 64, cpuTemperature: 90))
        await store.record(sample(at: Date(timeIntervalSince1970: hour + 90), temperature: 66, cpuTemperature: 100))
        await store.record(sample(at: now, temperature: 55, cpuTemperature: 55))

        let weekBucket = await store.samples(for: .week, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - hour) < 3_600 }
        XCTAssertEqual(weekBucket?.minCPUCelsius ?? .nan, 40, accuracy: 0.001)
        XCTAssertEqual(weekBucket?.cpuCelsius ?? .nan, 77.5, accuracy: 0.001)
        XCTAssertEqual(weekBucket?.maxCPUCelsius ?? .nan, 100, accuracy: 0.001)

        let monthBucket = await store.samples(for: .month, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - hour) < 7_200 }
        XCTAssertEqual(monthBucket?.minCPUCelsius ?? .nan, 40, accuracy: 0.001)
        XCTAssertEqual(monthBucket?.cpuCelsius ?? .nan, 77.5, accuracy: 0.001)
        XCTAssertEqual(monthBucket?.maxCPUCelsius ?? .nan, 100, accuracy: 0.001)
        await store.close()
    }

    func testRPMAndNullableTargetsUseObservationWeightedAveragesInBothLongTiers() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hour = floor(now.addingTimeInterval(-26 * 60 * 60).timeIntervalSince1970 / 3_600) * 3_600

        // Uneven counts span separate 1-minute and 5-minute tier buckets, so
        // this catches an average-of-averages in either long-range tier. Null
        // targets are intentionally absent observations, not zero-valued ones.
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 10),
            temperature: 60,
            rpm: 1_000,
            firmwareTarget: 2_000,
            macFanTarget: 3_000
        ))
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 310),
            temperature: 62,
            rpm: 3_000,
            firmwareTarget: nil,
            macFanTarget: 6_000
        ))
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 320),
            temperature: 64,
            rpm: 5_000,
            firmwareTarget: 8_000,
            macFanTarget: nil
        ))
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 330),
            temperature: 66,
            rpm: 7_000,
            firmwareTarget: 10_000,
            macFanTarget: 12_000
        ))
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 610),
            temperature: 68,
            rpm: 9_000
        ))
        await store.record(sample(
            at: Date(timeIntervalSince1970: hour + 620),
            temperature: 70,
            rpm: 9_000
        ))
        await store.record(sample(at: now, temperature: 55, rpm: 2_000))

        let expectedActualRPM = 34_000.0 / 6.0
        let expectedFirmwareTarget = 20_000.0 / 3.0
        let expectedMacFanTarget = 21_000.0 / 3.0

        let weekBucket = await store.samples(for: .week, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - hour) < 3_600 }
        XCTAssertEqual(weekBucket?.averageActualRPM ?? .nan, expectedActualRPM, accuracy: 0.001)
        XCTAssertEqual(weekBucket?.averageFirmwareTargetRPM ?? .nan, expectedFirmwareTarget, accuracy: 0.001)
        XCTAssertEqual(weekBucket?.averageMacFanTargetRPM ?? .nan, expectedMacFanTarget, accuracy: 0.001)

        let monthBucket = await store.samples(for: .month, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - hour) < 7_200 }
        XCTAssertEqual(monthBucket?.averageActualRPM ?? .nan, expectedActualRPM, accuracy: 0.001)
        XCTAssertEqual(monthBucket?.averageFirmwareTargetRPM ?? .nan, expectedFirmwareTarget, accuracy: 0.001)
        XCTAssertEqual(monthBucket?.averageMacFanTargetRPM ?? .nan, expectedMacFanTarget, accuracy: 0.001)
        await store.close()
    }

    func testBucketModeIsLatestObservationNotAlphabeticalOrPriorityBased() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rawBucket = floor(now.addingTimeInterval(-300).timeIntervalSince1970 / 30) * 30
        await store.record(sample(at: Date(timeIntervalSince1970: rawBucket + 1), temperature: 70, mode: .expert, capability: .ready))
        await store.record(sample(at: Date(timeIntervalSince1970: rawBucket + 20), temperature: 60, mode: .system))

        let raw = await store.samples(for: .hour, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - rawBucket) < 0.5 }
        XCTAssertEqual(raw?.mode, .system, "The newest observation must win even when an earlier override existed")

        let oldBucket = floor(now.addingTimeInterval(-26 * 60 * 60).timeIntervalSince1970 / 300) * 300
        await store.record(sample(at: Date(timeIntervalSince1970: oldBucket + 1), temperature: 72, mode: .smartBoost, capability: .ready))
        await store.record(sample(at: Date(timeIntervalSince1970: oldBucket + 20), temperature: 62, mode: .system))
        await store.record(sample(at: now.addingTimeInterval(61), temperature: 55))

        let rolled = await store.samples(for: .week, now: now.addingTimeInterval(61))
            .first { abs($0.timestamp.timeIntervalSince1970 - oldBucket) < 3_600 }
        XCTAssertEqual(rolled?.mode, .system, "Tier rollups must preserve the latest state, not MAX(mode)")
        await store.close()
    }

    func testCoverageAndDurationsCapTelemetryGaps() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldBase = floor(now.addingTimeInterval(-26 * 60 * 60).timeIntervalSince1970 / 300) * 300

        await store.record(sample(at: Date(timeIntervalSince1970: oldBase), temperature: 55, mode: .system))
        await store.record(sample(at: Date(timeIntervalSince1970: oldBase + 10), temperature: 86, mode: .max, capability: .ready))
        // Simulate a long sleep/telemetry outage. It contributes only the fixed
        // 30-second cap, not the full 990-second wall-clock gap.
        await store.record(sample(at: Date(timeIntervalSince1970: oldBase + 1_000), temperature: 72, mode: .system))
        await store.record(sample(at: now, temperature: 60, mode: .system))

        let buckets = await store.samples(for: .week, now: now)
            .filter { $0.timestamp.timeIntervalSince1970 < now.addingTimeInterval(-HistoryRange.day.interval).timeIntervalSince1970 }
        let coverage = buckets.compactMap(\.recordedCoverageSeconds).reduce(0, +)
        XCTAssertEqual(coverage, 70, accuracy: 0.001)
        XCTAssertLessThan(coverage, 100, "A sleep gap must never be inferred as observed coverage")

        let systemDuration = buckets.compactMap { $0.modeDurations?[.system] }.reduce(0, +)
        let maxDuration = buckets.compactMap { $0.modeDurations?[.max] }.reduce(0, +)
        XCTAssertEqual(systemDuration, 40, accuracy: 0.001)
        XCTAssertEqual(maxDuration, 30, accuracy: 0.001)
        XCTAssertEqual(systemDuration + maxDuration, coverage, accuracy: 0.001)

        let coolDuration = buckets.compactMap { $0.thermalBandDurations?[.cool] }.reduce(0, +)
        let hotDuration = buckets.compactMap { $0.thermalBandDurations?[.hot] }.reduce(0, +)
        let violetDuration = buckets.compactMap { $0.thermalBandDurations?[.violet] }.reduce(0, +)
        XCTAssertEqual(coolDuration, 10, accuracy: 0.001)
        XCTAssertEqual(hotDuration, 30, accuracy: 0.001)
        XCTAssertEqual(violetDuration, 30, accuracy: 0.001)
        await store.close()
    }

    func testPruningDropsDataBeyondEveryRetentionWindow() async {
        let store = HistoryStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ancient = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)
        await store.record(sample(at: ancient, temperature: 95))
        await store.record(sample(at: recent, temperature: 65))
        await store.record(sample(at: now, temperature: 55))

        let month = await store.samples(for: .month, now: now)
        XCTAssertFalse(month.contains { abs($0.timestamp.timeIntervalSince(ancient)) < 7_200 },
                       "Data older than 30 days must be pruned")
        XCTAssertTrue(month.contains { abs($0.timestamp.timeIntervalSince(recent)) < 7_200 })
        await store.close()
    }

    func testLegacyHourlyTableMigratesIntoTiers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macfan-legacy-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyHour = floor((now.timeIntervalSince1970 - 2 * 24 * 60 * 60) / 3_600) * 3_600

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let legacySQL = """
            CREATE TABLE hourly (
                bucket REAL PRIMARY KEY NOT NULL,
                average_temp REAL, average_cpu REAL, average_gpu REAL, peak_temp REAL,
                average_actual_rpm REAL, average_requested_rpm REAL,
                average_firmware_target_rpm REAL, average_macfan_target_rpm REAL,
                mode TEXT, capability TEXT
            );
            INSERT INTO hourly VALUES (\(legacyHour), 55, 54, NULL, 88, 3000, NULL, 3100, NULL, 'max', 'ready');
        """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = HistoryStore(fileURL: url)
        let week = await store.samples(for: .week, now: now)
        let migrated = week.first { abs($0.timestamp.timeIntervalSince1970 - legacyHour) < 3_600 }
        XCTAssertNotNil(migrated, "Existing 30-day history must remain visible after the schema upgrade")
        XCTAssertEqual(migrated?.hottestCelsius ?? .nan, 55, accuracy: 0.001)
        XCTAssertEqual(migrated?.maxCelsius ?? .nan, 88, accuracy: 0.001, "The legacy hourly peak must survive migration")
        XCTAssertEqual(migrated?.minCPUCelsius ?? .nan, 54, accuracy: 0.001)
        XCTAssertEqual(migrated?.maxCPUCelsius ?? .nan, 54, accuracy: 0.001,
                       "Unknown legacy CPU extrema must conservatively fall back to the recorded average")
        XCTAssertEqual(migrated?.mode, .max)
        XCTAssertNil(migrated?.recordedCoverageSeconds, "Migration must not invent historical coverage")
        await store.close()
    }

    func testExistingAggregateSchemaMigratesInPlaceAndRemainsReadable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macfan-tier-legacy-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = floor(now.addingTimeInterval(-2 * 24 * 60 * 60).timeIntervalSince1970 / 60) * 60

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE agg60 (
                bucket REAL PRIMARY KEY NOT NULL, sample_count INTEGER,
                temp_min REAL, temp_avg REAL, temp_max REAL, temp_last REAL,
                cpu_avg REAL, gpu_avg REAL,
                rpm_min REAL, rpm_avg REAL, rpm_max REAL, rpm_last REAL,
                firmware_target_avg REAL, macfan_target_avg REAL,
                mode TEXT, capability TEXT
            );
            INSERT INTO agg60 VALUES (
                \(bucket), 4, 50, 60, 84, 62, 61, 58,
                2000, 3000, 5000, 3200, 3300, NULL, 'system', 'ready'
            );
            INSERT INTO agg60 VALUES (
                \(bucket + 60), 1, 52, 62, 82, 64, 61, 59,
                7000, 7000, 7000, 7000, NULL, 5000, 'expert', 'ready'
            );
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = HistoryStore(fileURL: url)
        let migrated = await store.samples(for: .week, now: now)
            .first { abs($0.timestamp.timeIntervalSince1970 - bucket) < 3_600 }
        XCTAssertEqual(migrated?.cpuCelsius ?? .nan, 61, accuracy: 0.001)
        XCTAssertEqual(migrated?.minCPUCelsius ?? .nan, 61, accuracy: 0.001)
        XCTAssertEqual(migrated?.maxCPUCelsius ?? .nan, 61, accuracy: 0.001)
        XCTAssertEqual(migrated?.averageActualRPM ?? .nan, 3_800, accuracy: 0.001)
        XCTAssertEqual(migrated?.averageFirmwareTargetRPM ?? .nan, 3_300, accuracy: 0.001)
        XCTAssertEqual(migrated?.averageMacFanTargetRPM ?? .nan, 5_000, accuracy: 0.001)
        XCTAssertEqual(migrated?.mode, .expert)
        XCTAssertNil(migrated?.recordedCoverageSeconds)
        await store.close()
    }

    func testContiguousSegmentsSplitAtGaps() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [0, 30, 60, 4_000, 4_030].map {
            sample(at: base.addingTimeInterval(TimeInterval($0)), temperature: 50)
        }
        let segments = samples.contiguousSegments(maxGap: 90)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.count, 3)
        XCTAssertEqual(segments.last?.count, 2)
        XCTAssertTrue([TelemetrySample]().contiguousSegments(maxGap: 90).isEmpty)
    }
}

final class ThermalSnapshotPublicationTests: XCTestCase {
    private let cpu = SensorReading(key: "TC0P", name: "CPU Average", celsius: 60)
    private let gpu = SensorReading(key: "TG0P", name: "GPU Average", celsius: 55)
    private let hottest = SensorReading(key: "Tp09", name: "Performance Core", celsius: 64)

    private func snapshot(
        cpu: SensorReading? = nil,
        fans: [FanReading]? = nil,
        sensors: [SensorReading]? = nil
    ) -> ThermalSnapshot {
        ThermalSnapshot(
            timestamp: .now,
            hottest: hottest,
            cpu: cpu ?? self.cpu,
            gpu: gpu,
            fans: fans ?? [
                FanReading(id: 0, name: "Left fan", actualRPM: 3_000, minimumRPM: 2_000, maximumRPM: 6_800, firmwareTargetRPM: 3_100),
                FanReading(id: 1, name: "Right fan", actualRPM: 3_100, minimumRPM: 2_000, maximumRPM: 6_800, firmwareTargetRPM: 3_200)
            ],
            sensors: sensors ?? [self.cpu, gpu, hottest],
            sourceStatus: "Live Apple SMC"
        )
    }

    func testNonHeadlineSensorNoiseAndOrderingDoNotRepublishSnapshot() {
        let first = snapshot(sensors: [cpu, gpu, hottest])
        let changedAuxiliaryReadings = snapshot(sensors: [
            SensorReading(key: "TB0T", name: "Battery", celsius: 48),
            SensorReading(key: "TW0P", name: "Wireless", celsius: 35),
            SensorReading(key: "TN0D", name: "Neural Engine", celsius: 70)
        ])
        XCTAssertTrue(first.isVisuallyEquivalent(to: changedAuxiliaryReadings))

        let reversedFans = snapshot(fans: Array(first.fans.reversed()))
        XCTAssertTrue(first.isVisuallyEquivalent(to: reversedFans))
    }

    func testHeadlineAndFanIdentityChangesRepublishSnapshot() {
        let first = snapshot()
        let hotterCPU = SensorReading(key: cpu.key, name: cpu.name, celsius: 61)
        XCTAssertFalse(first.isVisuallyEquivalent(to: snapshot(cpu: hotterCPU)))

        var renamedFan = first.fans
        renamedFan[0].name = "Primary fan"
        XCTAssertFalse(first.isVisuallyEquivalent(to: snapshot(fans: renamedFan)))

        var changedLimit = first.fans
        changedLimit[0].maximumRPM = 7_000
        XCTAssertFalse(first.isVisuallyEquivalent(to: snapshot(fans: changedLimit)))
    }
}
