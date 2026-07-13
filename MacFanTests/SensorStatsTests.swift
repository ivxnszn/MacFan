import XCTest
@testable import MacFan

final class SensorStatsTests: XCTestCase {
    func testSessionStatsAccumulate() {
        var stats = SensorSessionStats(first: 50)
        stats.observe(70)
        stats.observe(60)
        XCTAssertEqual(stats.minimum, 50)
        XCTAssertEqual(stats.maximum, 70)
        XCTAssertEqual(stats.average, 60, accuracy: 0.001)
        XCTAssertEqual(stats.count, 3)
    }

    func testSessionStatsIgnoresNonFiniteReadings() {
        var stats = SensorSessionStats(first: .nan)
        stats.observe(.infinity)
        stats.observe(42)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.minimum, 42)
        XCTAssertEqual(stats.maximum, 42)
    }

    @MainActor
    func testSessionModelCountsEachTelemetryTimestampOnce() {
        let session = SensorSessionModel()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        session.observe([SensorReading(key: "TC0P", name: "CPU", celsius: 50)], at: timestamp)
        session.observe([SensorReading(key: "TC0P", name: "CPU", celsius: 90)], at: timestamp)
        session.observe([SensorReading(key: "TC0P", name: "CPU", celsius: 60)], at: timestamp.addingTimeInterval(2))

        XCTAssertEqual(session.stats["TC0P"]?.count, 2)
        XCTAssertEqual(session.stats["TC0P"]?.average ?? .nan, 55, accuracy: 0.001)
        XCTAssertEqual(session.trails["TC0P"]?.points.count, 2)
    }

    func testCategoryClassification() {
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "Tp09", name: "CPU performance core 1", celsius: 50)), .cpu)
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "Tg05", name: "GPU cluster", celsius: 50)), .gpu)
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "TB1T", name: "Battery 1", celsius: 30)), .battery)
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "TW0P", name: "Airflow proximity", celsius: 40)), .other)
        XCTAssertTrue(SensorCategory.all.matches(SensorReading(key: "TW0P", name: "Airflow proximity", celsius: 40)))
        XCTAssertFalse(SensorCategory.gpu.matches(SensorReading(key: "TB1T", name: "Battery 1", celsius: 30)))
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "Tg05", name: "Package sensor", celsius: 50)), .gpu)
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "TB1T", name: "Power sensor", celsius: 30)), .battery)
        XCTAssertEqual(SensorCategory.classify(SensorReading(key: "Tp09", name: "Package sensor", celsius: 50)), .cpu)
    }

    func testCSVExportContainsHeaderAndStats() {
        let sensor = SensorReading(key: "Tp01", name: "CPU efficiency core", celsius: 55.25)
        var stats = SensorSessionStats(first: 50)
        stats.observe(60)
        let csv = SensorExport.csv(sensors: [sensor], stats: ["Tp01": stats])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("key,name,category,current_c"))
        XCTAssertTrue(lines[1].contains("Tp01"))
        XCTAssertTrue(lines[1].contains("CPU"))
        XCTAssertTrue(lines[1].contains("55.2"))
        XCTAssertTrue(lines[1].contains("50.0"))
        XCTAssertTrue(lines[1].contains("60.0"))
        XCTAssertTrue(lines[1].hasSuffix("2"))
    }

    func testCSVExportEscapesCommasQuotesAndUsesStableDecimalSeparator() {
        let sensor = SensorReading(key: "T,1", name: "CPU \"package\", left", celsius: 55.25)
        let csv = SensorExport.csv(sensors: [sensor], stats: [:])
        XCTAssertTrue(csv.contains("\"T,1\",\"CPU \"\"package\"\", left\""))
        XCTAssertTrue(csv.contains(",55.2,,,,0"))
    }

    @MainActor
    func testPinnedSensorComparisonIsCappedAndMigratesOlderPreferences() throws {
        let suite = "MacFanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["TZ", "TA", "TM"], forKey: "macfan.sensors.pinned")

        let settings = AppSettings(defaults: defaults, readsLoginItemStatus: false)
        XCTAssertEqual(settings.pinnedSensorKeys, Set(["TA", "TM"]))
        settings.togglePinned("TZ")
        XCTAssertEqual(settings.pinnedSensorKeys.count, 2)
        settings.togglePinned("TA")
        settings.togglePinned("TZ")
        XCTAssertEqual(settings.pinnedSensorKeys, Set(["TM", "TZ"]))
    }
}
