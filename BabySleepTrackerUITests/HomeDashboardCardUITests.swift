import XCTest

@MainActor
final class HomeDashboardCardUITests: XCTestCase {
    private func launch(_ scenario: String = "missing", large: Bool = false, failure: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1" // Existing offline LLM test agent.
        app.launchEnvironment["HOME_CARD_UI_TESTS"] = "1"
        app.launchEnvironment["HOME_CARD_RESET"] = "1"
        app.launchEnvironment["HOME_CARD_SCENARIO"] = scenario
        if failure { app.launchEnvironment["HOME_WAKE_SAVE_FAIL"] = "1" }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["home.wake.add"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }
    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TEST-ONLY-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func disappears(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 5), .completed)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable && app.windows.firstMatch.frame.contains(element.frame) { return }
            app.swipeUp()
        }
        XCTFail("Control could not be fully revealed")
    }
    private func tapVisibleRecordingCard(_ card: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            let window = app.windows.firstMatch.frame
            // Exclude the floating tab controls from the usable scroll viewport.
            let bottom = app.buttons["recording.addSleep"].frame.minY
            let viewport = CGRect(x: window.minX + 16, y: window.minY + 44,
                                  width: window.width - 32, height: max(0, bottom - window.minY - 44))
            if card.exists && card.isHittable {
                let frame = card.frame
                let visible = frame.intersection(viewport)
                // At maximum Dynamic Type the card can exceed the SE viewport.
                // Its visible portion remains a real button; navigation below must succeed.
                if !visible.isNull && visible.width >= 44 && visible.height >= 44 {
                    card.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: visible.midX - frame.minX, dy: visible.midY - frame.minY)).tap()
                    return
                }
            }
            if card.exists && card.frame.midY < viewport.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTFail("Recording card has no visible, hittable 44-point tap area within eight scroll gestures.")
    }
    func testWakeSaveHidesAndPersistsAcrossRelaunch() {
        let app = launch()
        screenshot("wake-visible", app: app)
        app.buttons["home.wake.add"].tap()
        XCTAssertTrue(app.navigationBars["Today's Wake-up"].waitForExistence(timeout: 5))
        app.buttons["home.wake.save"].tap()
        disappears(app.navigationBars["Today's Wake-up"])
        disappears(app.buttons["home.wake.add"])
        screenshot("wake-hidden-after-save", app: app)
        app.terminate()
        app.launchEnvironment["HOME_CARD_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["TEST FIXTURE — NOT A PREDICTION"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.wake.add"].exists)
    }
    func testFailedSaveKeepsEditorAndWakeCard() {
        let app = launch(failure: true)
        app.buttons["home.wake.add"].tap()
        app.buttons["home.wake.save"].tap()
        XCTAssertTrue(app.alerts["Could not save wake time"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Today's Wake-up"].exists)
        app.buttons["home.wake.cancel"].tap()
        disappears(app.navigationBars["Today's Wake-up"])
        XCTAssertTrue(app.buttons["home.wake.add"].exists)
    }
    func testLikelyNapAndNightVisualFixtures() {
        for (scenario, label) in [("first-nap", "Likely next sleep"), ("night", "Likely next sleep")] {
            let app = launch(scenario)
            let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            XCTAssertTrue(summary.label.contains(label), summary.label)
            XCTAssertTrue(summary.label.localizedCaseInsensitiveContains("estimated"))
            screenshot(scenario, app: app)
            app.terminate()
        }
    }
    func testConfirmedNapPreservesAddBreakNavigation() {
        let app = launch("confirmed-nap")
        let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Sleeping now"))
        screenshot("confirmed-ongoing", app: app)
        app.buttons["sleep.current.addBreak"].tap()
        XCTAssertTrue(app.navigationBars["Add Awake Break"].waitForExistence(timeout: 5))
    }
    func testLargeDynamicTypeAndExistingRecordDestination() {
        let app = launch(large: true)
        screenshot("large-dynamic-type", app: app)
        let wake = app.buttons["home.wake.add"]
        reveal(wake, app: app)
        screenshot("large-dynamic-type-wake", app: app)
        wake.tap()
        XCTAssertTrue(app.navigationBars["Today's Wake-up"].waitForExistence(timeout: 5))
        app.buttons["home.wake.cancel"].tap()
        disappears(app.navigationBars["Today's Wake-up"])
        // The former next-sleep card keeps its existing Add Sleep destination.
        app.swipeDown()
        app.swipeDown()
        let add = app.buttons["hero.addNap"]
        tapVisibleRecordingCard(add, app: app)
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
    }
}
