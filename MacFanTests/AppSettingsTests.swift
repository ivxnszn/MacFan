import XCTest
@testable import MacFan

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "macfan-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsAreSensible() {
        let settings = AppSettings(defaults: makeDefaults(), readsLoginItemStatus: false)
        XCTAssertEqual(settings.temperatureUnit, .celsius)
        XCTAssertEqual(settings.menuBarFormat, .temperatureAndMode)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showPopoverFanBank)
        XCTAssertTrue(settings.showPopoverTimeline)
        XCTAssertFalse(settings.alertsEnabled)
        XCTAssertEqual(settings.alertThresholdCelsius, 85)
    }

    func testPreferencesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults, readsLoginItemStatus: false)
        first.temperatureUnit = .fahrenheit
        first.menuBarFormat = .temperatureAndRPM
        first.showPopoverTimeline = false
        first.alertsEnabled = true
        first.alertThresholdCelsius = 90

        let second = AppSettings(defaults: defaults, readsLoginItemStatus: false)
        XCTAssertEqual(second.temperatureUnit, .fahrenheit)
        XCTAssertEqual(second.menuBarFormat, .temperatureAndRPM)
        XCTAssertFalse(second.showPopoverTimeline)
        XCTAssertTrue(second.alertsEnabled)
        XCTAssertEqual(second.alertThresholdCelsius, 90)
    }

    func testTemperatureUnitConversion() {
        XCTAssertEqual(TemperatureUnit.celsius.degrees(49.4), "49°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.degrees(100), "212°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.degreesWithUnit(0), "32°F")
    }
}
