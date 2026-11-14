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
            if element.exists {
                let frame = element.frame
                let fits = frame.height <= viewport.height && frame.width <= viewport.width
                let visible = fits ? viewport.contains(frame) : viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                if visible && element.isHittable { return }
            }
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
        if !app.launchArguments.contains("UICTContentSizeCategoryAccessibilityXXXL") {
            let indicator = app.staticTexts["home.plan.unavailable"]
            if indicator.exists { reveal(indicator, app: app) }
            else {
                let window = app.windows.firstMatch.frame
                let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.plan.event."))
                for index in 0..<nodes.count {
                    let node = nodes.element(boundBy: index)
                    let frame = node.frame
                    if !frame.isEmpty && frame.minX >= window.minX + 8 && frame.maxX <= window.maxX - 8 {
                        reveal(node, app: app)
                        break
                    }
                }
            }
        }
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
        XCTAssertFalse(progress.exists)
        XCTAssertTrue(app.staticTexts["No sleep recorded yet"].exists)
        XCTAssertTrue(app.staticTexts["home.plan.unavailable"].exists)
        let events = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.plan.event."))
        XCTAssertEqual(events.count, 0, "Unavailable predictions must not appear as scheduled nodes.")
        capture("no-confirmed-records-unavailable", app: app)
    }

    func testCompletedWakeAndNetNapNavigateToExistingTimeline() {
        let app = launch("completed")
        let nap = event("record:\(parentID)", app: app)
        XCTAssertTrue(nap.label.contains("Done"), nap.label)
        XCTAssertTrue((nap.value as? String ?? "").contains("50m net sleep"), "Net duration remains available to VoiceOver and the full timeline.")
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertEqual(progress.label, "2 recorded events")
        assertUnavailableIsDetailOnly(app: app)
        assertCompactCard(app: app)
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
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertEqual(progress.label, "2 recorded events", "An ongoing observed sleep is recorded, not completed.")
        assertUnavailableIsDetailOnly(app: app)
        assertCompactCard(app: app)
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
        XCTAssertEqual(progress.label, "6 recorded events")
        assertUnavailableIsDetailOnly(app: app)
    }

    func testOvernightCarryoverRemainsActiveAndKeepsOriginalDay() {
        let app = launch("carryover")
        let night = event("record:\(parentID)", app: app)
        XCTAssertTrue(night.label.contains("Ongoing"), night.label)
        XCTAssertTrue((night.value as? String ?? "").contains("Previous Sleep Day"))
        XCTAssertTrue(night.label.contains("Yesterday"), night.label)
        XCTAssertFalse(night.label.contains("elapsed"), "The duration appears only in the centered capsule.")
        let reference = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        XCTAssertTrue(reference.label.contains("Morning wake") && reference.label.contains("Awaiting wake"), reference.label)
        XCTAssertTrue(reference.label.contains("—"), "No routine must not invent a timestamp.")
        XCTAssertFalse(night.label.contains("Done"), night.label)
        capture("night-carryover", app: app)
        assertOvernightLayout(app: app, elapsed: "7h 10m")
        app.buttons["home.plan.details"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sleep Day:")).firstMatch.waitForExistence(timeout: 5))
    }

    func testExplicitOfflineReferenceFixtureShowsNextAndFutureAsEstimates() {
        let app = launch("reference")
        let scroll = app.scrollViews["home.plan.scroll"]
        let next = event("proposal:fixture-nap-2", app: app)
        XCTAssertTrue((next.value as? String ?? "").contains("Next planned event"))
        XCTAssertTrue(next.label.contains("Estimated"), next.label)
        XCTAssertTrue(next.label.contains("in 2h 29m"), next.label)
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertEqual(progress.label, "1 completed of 4 available events", "Eligible future events retain plan progress.")
        XCTAssertFalse(app.staticTexts["home.plan.unavailable"].exists)
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
    func testOvernightRoutineAndMorningGraceRemainUnconfirmed() {
        for scenario in ["overnight-routine", "morning-grace"] {
            let app = launch(scenario)
            let night = event("record:\(parentID)", app: app)
            XCTAssertTrue(night.label.contains(scenario == "morning-grace" ? "End unconfirmed" : "Ongoing"), night.label)
            XCTAssertFalse(night.label.contains("Done"), night.label)
            let reference = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
            XCTAssertTrue(reference.label.contains("Morning wake") && reference.label.contains("Usual ·") && reference.label.contains("Routine"), reference.label)
            XCTAssertFalse(reference.label.contains("Done") || reference.label.contains("Estimated"), reference.label)
            if scenario == "morning-grace" {
                XCTAssertFalse(night.label.contains("Ongoing") || night.label.contains("Sleeping now"))
                let hero = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
                XCTAssertTrue(hero.label.contains("Good morning"), hero.label)
            }
            capture(scenario, app: app)
            assertOvernightLayout(app: app, elapsed: scenario == "morning-grace" ? "12h 45m" : "7h 10m")
            assertCompactCard(app: app)
            app.terminate()
        }
    }

    func testOvernightEstimatedWakeUsesExplicitVerifiedFixture() {
        let app = launch("overnight-estimate")
        let reference = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        XCTAssertTrue(reference.label.contains("Morning wake") && reference.label.contains("Estimated"), reference.label)
        XCTAssertFalse(reference.label.contains("Routine") || reference.label.contains("Done"), reference.label)
        capture("overnight-estimated-wake", app: app)
        assertOvernightLayout(app: app, elapsed: "7h 10m")
        assertCompactCard(app: app)
    }

    func testOvernightDarkModeAndLargeTypeRetainBothNodesAndSingleElapsedCapsule() {
        let dark = launch("overnight-routine", dark: true)
        capture("overnight-dark-mode", app: dark)
        assertOvernightLayout(app: dark, elapsed: "7h 10m")
        dark.terminate()
        let large = launch("overnight-routine", large: true)
        XCTAssertTrue(large.buttons["home.plan.details"].isHittable)
        capture("overnight-large-header", app: large)
        let scroll = large.scrollViews["home.plan.scroll"]
        XCTAssertTrue(scroll.exists)
        reveal(scroll, app: large)
        scroll.swipeLeft()
        let reference = large.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        XCTAssertTrue(reference.label.contains("Routine"))
        XCTAssertEqual(large.descendants(matching: .any).matching(identifier: "home.plan.overnight.elapsed").count, 1)
        capture("overnight-large-horizontal", app: large)
    }

    private func assertOvernightLayout(app: XCUIApplication, elapsed: String) {
        let night = event("record:\(parentID)", app: app)
        let wake = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        let duration = app.descendants(matching: .any).matching(identifier: "home.plan.overnight.elapsed")
        XCTAssertEqual(duration.count, 1, "Elapsed time is shown once on the overnight card.")
        let badge = duration.firstMatch
        XCTAssertTrue(badge.label.contains("Night sleep") && badge.label.contains(elapsed + " elapsed since recorded start"), badge.label)
        XCTAssertEqual(app.staticTexts["home.plan.title"].label, "Today's Plan")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.plan.overnightBadge").firstMatch.exists)
        XCTAssertFalse(app.scrollViews["home.plan.scroll"].exists, "Both overnight nodes fit the default compact layout.")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(wake.frame.midX - night.frame.midX, window.width * 0.4, "Spread the two nodes across the card.")
        // Accessibility bounds include the active halo above its circle, but not
        // the neutral node's empty top padding. Compare the common caption edge.
        XCTAssertEqual(night.frame.maxY, wake.frame.maxY, accuracy: 2, "Both nodes retain aligned caption rows.")
        XCTAssertEqual(badge.frame.midX, (night.frame.midX + wake.frame.midX) / 2, accuracy: 3)
        XCTAssertGreaterThan(badge.frame.minY, night.frame.minY + 28, "Duration sits below the connector.")
        XCTAssertFalse(night.label.contains("elapsed") || wake.label.contains("elapsed"))
        assertCompactCard(app: app)
    }

    private func assertCompactCard(app: XCUIApplication) {
        let title = app.staticTexts["home.plan.title"]
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.plan.event."))
        var bottom = title.frame.maxY
        for index in 0..<nodes.count {
            let frame = nodes.element(boundBy: index).frame
            if !frame.isEmpty { bottom = max(bottom, frame.maxY) }
        }
        let reference = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        if reference.exists { bottom = max(bottom, reference.frame.maxY) }
        let height = bottom - title.frame.minY + 28
        XCTAssertLessThanOrEqual(height, 250, "Default-size card must stay compact; actual content height: \(height)")
    }

    private func assertUnavailableIsDetailOnly(app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["home.plan.unavailable"].exists, "Recorded timelines do not need a persistent unavailable footer.")
        XCTAssertEqual(app.buttons["home.plan.details"].value as? String, "Predictions unavailable", "Prediction availability remains accessible through the neutral full-plan detail.")
    }
}
