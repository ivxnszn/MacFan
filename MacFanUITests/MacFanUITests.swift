import XCTest

final class MacFanUITests: XCTestCase {
    func testAppLaunchesWithoutAControlHelper() {
        let app = XCUIApplication()
        app.launchEnvironment["MACFAN_UI_TEST_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["dashboard-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["control-status-title"].waitForExistence(timeout: 5))
        let maxButton = app.buttons["mode-max"]
        XCTAssertTrue(maxButton.exists)
        XCTAssertTrue(maxButton.isEnabled, "Max should be an explicit preflight attempt, not a dead control")
        let manualButton = app.buttons["mode-expert"]
        XCTAssertTrue(manualButton.exists)
        XCTAssertTrue(manualButton.isEnabled, "Expert should open its unlock confirmation")
        XCTAssertTrue(app.buttons["history-range-day"].exists)
        XCTAssertTrue([XCUIApplication.State.runningForeground, .runningBackground].contains(app.state))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MacFan dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    func testPopoverKeepsPrimaryControlsAndBothFansAboveTheFold() {
        let app = XCUIApplication()
        app.launchEnvironment["MACFAN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["MACFAN_UI_TEST_POPOVER"] = "1"
        app.launch()

        let window = app.windows["MacFan — Popover Preview"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // A preceding UI test can leave Chrome frontmost even though the
        // accessory window exists. Activate the fixture before hit-testing.
        app.activate()
        let systemButton = app.buttons["popover-mode-system"]
        XCTAssertTrue(systemButton.waitForExistence(timeout: 2))
        XCTAssertTrue(systemButton.exists)
        XCTAssertTrue(app.buttons["popover-mode-max"].exists)
        XCTAssertTrue(app.buttons["popover-mode-max"].isEnabled)
        let leftFan = app.otherElements["Left fan fan"]
        let rightFan = app.otherElements["Right fan fan"]
        XCTAssertTrue(leftFan.waitForExistence(timeout: 2))
        XCTAssertTrue(rightFan.waitForExistence(timeout: 2))
        XCTAssertTrue(leftFan.exists)
        XCTAssertTrue(rightFan.exists)
        let dashboardButton = app.buttons["Dashboard"]
        XCTAssertTrue(dashboardButton.isHittable)
        XCTAssertTrue(window.frame.contains(dashboardButton.frame), "The footer must be inside the compact window")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MacFan compact popover"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    func testDashboardProgressiveDisclosureAndEveryTab() {
        let app = XCUIApplication()
        app.launchEnvironment["MACFAN_UI_TEST_MODE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["dashboard-title"].waitForExistence(timeout: 5))

        let cpuDetail = app.buttons["overview-cpu-detail"]
        XCTAssertTrue(cpuDetail.waitForExistence(timeout: 3))
        cpuDetail.tap()
        let recordedRange = app.staticTexts["Recorded range"]
        XCTAssertTrue(recordedRange.waitForExistence(timeout: 2))
        let revealPeak = app.buttons["Reveal highest point"]
        XCTAssertTrue(revealPeak.waitForExistence(timeout: 2))
        revealPeak.tap()
        let inspectorDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: recordedRange
        )
        XCTAssertEqual(XCTWaiter.wait(for: [inspectorDismissed], timeout: 2), .completed,
                       "Revealing evidence should uncover the thermal chart")

        app.buttons["dashboard-tab-Insights"].tap()
        XCTAssertTrue(app.staticTexts["Thermal recap"].waitForExistence(timeout: 4))
        let peakInsight = app.buttons["insight-row-peak"]
        XCTAssertTrue(peakInsight.waitForExistence(timeout: 4))
        peakInsight.tap()
        XCTAssertTrue(app.staticTexts["Why this appears"].waitForExistence(timeout: 2))
        let insightsScreenshot = XCTAttachment(screenshot: app.screenshot())
        insightsScreenshot.name = "MacFan insights and evidence inspector"
        insightsScreenshot.lifetime = .keepAlways
        add(insightsScreenshot)

        app.buttons["dashboard-tab-Sensors"].tap()
        XCTAssertTrue(app.staticTexts["Sensors"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["Search sensors or SMC keys"].waitForExistence(timeout: 3))
        let sensorsScreenshot = XCTAttachment(screenshot: app.screenshot())
        sensorsScreenshot.name = "MacFan sensors"
        sensorsScreenshot.lifetime = .keepAlways
        add(sensorsScreenshot)

        app.buttons["dashboard-tab-System"].tap()
        XCTAssertTrue(app.staticTexts["System"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Session activity"].waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MacFan system and tab navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

}
