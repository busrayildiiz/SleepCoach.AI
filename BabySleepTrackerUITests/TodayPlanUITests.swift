import XCTest

@MainActor
final class TodayPlanUITests: XCTestCase {
    private let parentID = "33333333-3333-3333-3333-333333333333"

    private func launch(_ scenario: String, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1" // Existing offline LLM agent.
        app.launchEnvironment["TODAY_PLAN_UI_TESTS"] = "1"
        app.launchEnvironment["TODAY_PLAN_SCENARIO"] = scenario
        if dark { app.launchEnvironment["TODAY_PLAN_DARK"] = "1" }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["TEST FIXTURE — NOT A PREDICTION"].waitForExistence(timeout: 10))
        reveal(app.buttons["home.plan.details"], app: app)
        return app
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            let window = app.windows.firstMatch.frame
            let tab = app.buttons["recording.addSleep"]
            let bottom = tab.exists ? tab.frame.minY : window.maxY
            let viewport = CGRect(x: window.minX + 8, y: window.minY + 44,
                                  width: window.width - 16, height: max(0, bottom - window.minY - 44))
            if element.exists && viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) && element.isHittable { return }
            let distance = element.exists ? element.frame.midY - viewport.midY : viewport.height
            let step = min(abs(distance), viewport.height * 0.4)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Plan element is not reachable: \(element)\n\(app.debugDescription)")
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "TODAYS-PLAN-TEST-ONLY-\(name)"
        image.lifetime = .keepAlways
        add(image)
    }

    private func event(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "home.plan.event.\(id)").firstMatch
    }

    func testEmptyPlanDoesNotFabricateWakeOrFutureSchedule() {
        let app = launch("empty")
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertTrue(progress.label.contains("0 completed of 0"), progress.label)
        let events = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.plan.event."))
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.element(boundBy: 0).label.contains("Not recorded"))
        XCTAssertTrue(events.element(boundBy: 1).label.contains("Prediction unavailable"))
        capture("no-confirmed-records-unavailable", app: app)
    }

    func testCompletedWakeAndNetNapNavigateToExistingTimeline() {
        let app = launch("completed")
        let nap = event("record:\(parentID)", app: app)
        XCTAssertTrue(nap.label.contains("Done"), nap.label)
        XCTAssertTrue(nap.label.contains("50m sleep"), nap.label)
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertTrue(progress.label.contains("2 completed of 2"), progress.label)
        capture("completed-wake-and-net-nap", app: app)
        app.buttons["home.plan.details"].tap()
        XCTAssertTrue(app.buttons["sleep.addBreak.\(parentID)"].waitForExistence(timeout: 5))
    }

    func testOngoingNapAgreesWithHeroAndShowsElapsedWithoutCountdown() {
        let app = launch("active")
        let nap = event("record:\(parentID)", app: app)
        XCTAssertTrue(nap.label.contains("Sleeping now"), nap.label)
        XCTAssertTrue(nap.label.contains("26m elapsed"), nap.label)
        XCTAssertFalse(nap.label.contains("left"), nap.label)
        XCTAssertFalse(nap.label.contains("Done"), nap.label)
        capture("ongoing-nap", app: app)
        let hero = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        XCTAssertTrue(hero.label.contains("Sleeping now"), hero.label)
    }

    func testVariableNapCountScrollsToLastRecordedNapOnCompactPhones() {
        let app = launch("many")
        let scroll = app.scrollViews["home.plan.scroll"]
        XCTAssertTrue(scroll.exists)
        let fifth = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.plan.event.record:", "Nap 5")).firstMatch
        reveal(scroll, app: app)
        let viewport = scroll.frame.intersection(app.windows.firstMatch.frame)
        for _ in 0..<6 {
            // XCTest can raise an invalid-activation-point failure when isHittable
            // is queried for an offscreen static text. Scroll by geometry first.
            if fifth.exists && !fifth.frame.isEmpty && viewport.contains(fifth.frame) { break }
            scroll.swipeLeft()
        }
        XCTAssertTrue(fifth.exists)
        XCTAssertFalse(fifth.frame.isEmpty)
        XCTAssertTrue(viewport.contains(fifth.frame), app.debugDescription)
        XCTAssertTrue(fifth.isHittable)
        XCTAssertTrue(fifth.label.contains("Nap 5") && fifth.label.contains("Done"), fifth.label)
        capture("multiple-naps-scrolled-compact", app: app)
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertTrue(progress.label.contains("6 completed of 6"), progress.label)
    }

    func testOvernightCarryoverRemainsActiveAndKeepsOriginalDay() {
        let app = launch("carryover")
        let night = event("record:\(parentID)", app: app)
        XCTAssertTrue(night.label.contains("Sleeping now"), night.label)
        XCTAssertTrue(night.label.contains("Previous Sleep Day"), night.label)
        XCTAssertFalse(night.label.contains("Done"), night.label)
        capture("night-carryover", app: app)
    }

    func testExplicitOfflineReferenceFixtureShowsNextAndFutureAsEstimates() {
        let app = launch("reference")
        let scroll = app.scrollViews["home.plan.scroll"]
        let next = event("proposal:fixture-nap-2", app: app)
        XCTAssertTrue(next.label.contains("Next"), next.label)
        XCTAssertTrue(next.label.contains("Estimated"), next.label)
        XCTAssertTrue(next.label.contains("in 2h 29m"), next.label)
        capture("approved-reference-leading", app: app)
        if scroll.exists { scroll.swipeLeft() }
        let future = event("proposal:fixture-bedtime", app: app)
        XCTAssertTrue(future.label.contains("Estimated"), future.label)
        XCTAssertFalse(future.label.contains("Sleeping now"), future.label)
        capture("approved-reference-future", app: app)
    }

    func testDarkModeAndLargeDynamicTypeKeepHorizontalTimelineAndActions() {
        let dark = launch("active", dark: true)
        capture("dark-mode", app: dark)
        dark.terminate()
        let large = launch("active", large: true)
        XCTAssertTrue(large.buttons["home.plan.details"].isHittable)
        capture("large-type-header", app: large)
        let nap = event("record:\(parentID)", app: large)
        let scroll = large.scrollViews["home.plan.scroll"]
        XCTAssertTrue(scroll.exists)
        reveal(scroll, app: large)
        scroll.swipeLeft()
        XCTAssertTrue(nap.label.contains("Sleeping now"), nap.label)
        capture("large-type-horizontal", app: large)
    }
}
