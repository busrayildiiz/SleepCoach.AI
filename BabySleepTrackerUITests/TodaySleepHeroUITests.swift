import XCTest

@MainActor
final class TodaySleepHeroUITests: XCTestCase {
    private func launch(_ scenario: String, live: Bool = false, large: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1" // Existing offline LLM agent.
        app.launchEnvironment["SLEEP_HERO_UI_TESTS"] = "1"
        app.launchEnvironment["SLEEP_HERO_SCENARIO"] = scenario
        if live { app.launchEnvironment["SLEEP_HERO_LIVE_CLOCK"] = "1" }
        if dark { app.launchEnvironment["SLEEP_HERO_DARK"] = "1" }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["TEST FIXTURE — NOT A PREDICTION"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "HERO-TEST-ONLY-\(name)"
        image.lifetime = .keepAlways
        add(image)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            let window = app.windows.firstMatch.frame
            let tab = app.buttons["recording.addSleep"]
            let bottom = tab.exists && tab.isHittable ? tab.frame.minY : window.maxY
            let visible = CGRect(x: window.minX, y: window.minY + 44, width: window.width,
                                 height: max(0, bottom - window.minY - 44))
            if element.exists && element.isHittable && visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            if element.exists && element.frame.midY < visible.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTFail("Hero action is not reachable")
    }
    private func dismissed(_ navigation: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: navigation)], timeout: 5), .completed)
    }
    func testSevenApprovedHeroStatesCapture() {
        let states = [("ready", "Ready to record"), ("napActive", "Sleeping now"),
                      ("napCompleted", "Nap completed"), ("nightActive", "Night sleep in progress"),
                      ("morningConfirmed", "Good morning, Alex!"), ("morningUnconfirmed", "Good morning, Alex!"),
                      ("likelyNext", "Likely next sleep")]
        for (state, title) in states {
            let app = launch(state)
            let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            XCTAssertTrue(summary.label.contains(title), summary.label)
            capture(state, app: app)
            app.terminate()
        }
    }
    func testDarkModeAndActiveNapAtLargeDynamicTypeCapture() {
        let dark = launch("nightActive", dark: true)
        capture("night-dark", app: dark)
        dark.terminate()
        let large = launch("napActive", large: true)
        reveal(large.buttons["hero.endSleep"], app: large)
        XCTAssertTrue(large.buttons["hero.endSleep"].isHittable)
        capture("nap-active-large-type", app: large)
    }
    func testNapEndRequiresSaveAndBreakKeepsParentRoute() {
        let app = launch("napActive", live: true)
        app.buttons["hero.endSleep"].tap()
        XCTAssertTrue(app.navigationBars["Edit Nap"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recording.end.edit"].exists)
        app.buttons["recording.cancel"].tap()
        dismissed(app.navigationBars["Edit Nap"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch.label.contains("Sleeping now"))
        app.buttons["sleep.current.addBreak"].tap()
        XCTAssertTrue(app.navigationBars["Add Awake Break"].waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        dismissed(app.navigationBars["Add Awake Break"])
        app.buttons["hero.endSleep"].tap()
        let save = app.buttons["recording.save"]
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        dismissed(app.navigationBars["Edit Nap"])
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Nap completed"),
            object: app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["hero.endSleep"].exists)
        app.buttons["hero.details"].tap()
        XCTAssertTrue(app.buttons["sleep.addBreak.22222222-2222-2222-2222-222222222222"].waitForExistence(timeout: 5))
    }
    func testPlanActionScrollsToExistingTimelineWithoutInventingNavigation() {
        let app = launch("morningConfirmed")
        let plan = app.buttons["hero.plan"]
        reveal(plan, app: app)
        plan.tap()
        let timeline = app.buttons["View full timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: timeline)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 5), .completed)
    }
    func testMorningPromptAndAccessibleAddNapNavigation() {
        let app = launch("morningUnconfirmed", large: true)
        let confirm = app.buttons["hero.confirmWake"]
        reveal(confirm, app: app)
        capture("morning-large-type", app: app)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Today's Wake-up"].waitForExistence(timeout: 5))
        app.buttons["home.wake.cancel"].tap()
        dismissed(app.navigationBars["Today's Wake-up"])
        XCTAssertTrue(app.buttons["hero.confirmWake"].exists)
        let nap = app.buttons["hero.addNap"]
        reveal(nap, app: app)
        nap.tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
    }
}
