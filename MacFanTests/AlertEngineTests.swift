import XCTest
@testable import MacFan

final class AlertEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testHeatAlertRequiresSustainedDuration() {
        var engine = AlertEngine(thresholdCelsius: 85, sustainDuration: 60, hysteresis: 5, cooldown: 900)
        XCTAssertTrue(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base).isEmpty)
        XCTAssertTrue(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(30)).isEmpty)
        let events = engine.update(temperature: 91, capability: .ready, activeMode: .system, at: base.addingTimeInterval(60))
        XCTAssertEqual(events, [AlertEngine.Event(kind: .sustainedHeat(celsius: 91))])
    }

    func testDipBelowThresholdResetsTheSustainClock() {
        var engine = AlertEngine(thresholdCelsius: 85, sustainDuration: 60, hysteresis: 5, cooldown: 900)
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base)
        _ = engine.update(temperature: 70, capability: .ready, activeMode: .system, at: base.addingTimeInterval(30))
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(40))
        XCTAssertTrue(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(60)).isEmpty,
                      "20 seconds of continuous heat is not 60")
    }

    func testHysteresisAndCooldownPreventRepeatAlerts() {
        var engine = AlertEngine(thresholdCelsius: 85, sustainDuration: 60, hysteresis: 5, cooldown: 900)
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base)
        XCTAssertFalse(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(60)).isEmpty)
        // Still hot 10 minutes later — no repeat while not rearmed.
        XCTAssertTrue(engine.update(temperature: 92, capability: .ready, activeMode: .system, at: base.addingTimeInterval(660)).isEmpty)
        // Dips to 82° — above threshold-minus-hysteresis, so still armed off.
        _ = engine.update(temperature: 82, capability: .ready, activeMode: .system, at: base.addingTimeInterval(700))
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(710))
        XCTAssertTrue(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(770)).isEmpty)
        // Cools to 79° (rearm) and cooldown passes → next sustained run fires.
        _ = engine.update(temperature: 79, capability: .ready, activeMode: .system, at: base.addingTimeInterval(800))
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(1_000))
        let events = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(1_060))
        XCTAssertFalse(events.isEmpty)
    }

    func testControlLossAlertsOnceWhileActivelyControlling() {
        var engine = AlertEngine()
        _ = engine.update(temperature: 60, capability: .ready, activeMode: .max, at: base)
        let events = engine.update(temperature: 60, capability: .helperUnavailable, activeMode: .system, at: base.addingTimeInterval(10))
        XCTAssertEqual(events, [AlertEngine.Event(kind: .controlLost)])
        XCTAssertTrue(engine.update(temperature: 60, capability: .helperUnavailable, activeMode: .system, at: base.addingTimeInterval(20)).isEmpty,
                      "One loss produces one alert")
    }

    func testNoControlLossAlertWhenNeverControlling() {
        var engine = AlertEngine()
        _ = engine.update(temperature: 60, capability: .monitoring, activeMode: .system, at: base)
        XCTAssertTrue(engine.update(temperature: 60, capability: .helperUnavailable, activeMode: .system, at: base.addingTimeInterval(10)).isEmpty)
    }

    func testMissingTemperatureResetsSustainWithoutCrashing() {
        var engine = AlertEngine(thresholdCelsius: 85, sustainDuration: 60, hysteresis: 5, cooldown: 900)
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base)
        _ = engine.update(temperature: nil, capability: .ready, activeMode: .system, at: base.addingTimeInterval(30))
        _ = engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(40))
        XCTAssertTrue(engine.update(temperature: 90, capability: .ready, activeMode: .system, at: base.addingTimeInterval(70)).isEmpty)
    }
}
