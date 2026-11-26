import XCTest

@MainActor
final class TodaySleepHeroUITests: XCTestCase {
    private func launch(_ scenario: String, live: Bool = false, large: Bool = false, dark: Bool = false,
                        xxl: Bool = false, historicalNightStart: Date? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1" // Existing offline LLM agent.
        app.launchEnvironment["SLEEP_HERO_UI_TESTS"] = "1"
        app.launchEnvironment["SLEEP_HERO_SCENARIO"] = scenario
        if live { app.launchEnvironment["SLEEP_HERO_LIVE_CLOCK"] = "1" }
        if dark { app.launchEnvironment["SLEEP_HERO_DARK"] = "1" }
        if xxl { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if let historicalNightStart {
            app.launchEnvironment["SLEEP_HERO_HISTORICAL_NIGHT_START"] = String(historicalNightStart.timeIntervalSince1970)
        }
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
            // Keep large-type hero actions reachable on SE without overshooting them.
            let distance = element.exists ? element.frame.midY - visible.midY : visible.height
            let step = min(abs(distance), visible.height * 0.4)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Hero action is not reachable")
    }

    private func tapHomeButton(_ identifier: String, app: XCUIApplication) {
        let target = app.buttons[identifier]
        let fixtureLabel = "TEST FIXTURE — NOT A PREDICTION"
        let marker = app.staticTexts[fixtureLabel]
        let scroll = app.scrollViews.containing(.staticText, identifier: fixtureLabel).firstMatch
        let window = app.windows.firstMatch
        let tab = app.buttons["recording.addSleep"]
        let moveLimit = 12
        var viewport = CGRect.null
        var moves = 0
        var stalledMoves = 0
        var lastAnchor: (tracksTarget: Bool, y: CGFloat)?

        for move in 0...moveLimit {
            let screen = window.frame
            let top = screen.minY + 44
            let bottom = tab.exists && tab.isHittable ? min(screen.maxY, tab.frame.minY) : screen.maxY
            let usable = CGRect(x: screen.minX, y: top, width: screen.width, height: max(0, bottom - top))
            viewport = scroll.exists ? usable.intersection(scroll.frame) : usable
            guard !viewport.isEmpty else { break }

            let frame = target.exists ? target.frame : .null
            let tracksTarget = !frame.isEmpty
            if tracksTarget, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)), target.isHittable {
                target.tap()
                return
            }

            // Use the Home marker to measure movement while the target is absent from the hierarchy.
            let anchorY = tracksTarget ? frame.midY : (marker.exists ? marker.frame.midY : nil)
            if let anchorY, let lastAnchor, lastAnchor.tracksTarget == tracksTarget, abs(anchorY - lastAnchor.y) < 2 {
                stalledMoves += 1
            } else {
                stalledMoves = 0
            }
            lastAnchor = anchorY.map { (tracksTarget, $0) }
            guard move < moveLimit, stalledMoves < 2 else { break }

            let distance = tracksTarget ? frame.midY - viewport.midY : viewport.height
            let towardBottom = distance >= 0
            let step = min(max(abs(distance), 44), viewport.height * 0.72)
            let startY = viewport.minY + viewport.height * (towardBottom ? 0.86 : 0.14)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX - screen.minX, dy: startY - screen.minY))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: towardBottom ? -step : step)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
            moves += 1
        }

        capture("home-button-not-reachable-\(identifier)", app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Home navigation accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let targetInfo = target.exists ? "frame=\(target.frame), hittable=\(target.isHittable), label=\(target.label)" : "missing from accessibility hierarchy"
        XCTFail("Home button \(identifier) was unreachable after \(moves) moves (\(stalledMoves) stalled). " +
                "Target \(targetInfo). Viewport \(viewport). Window \(window.frame).")
    }

    private func revealPlanObservation(_ target: XCUIElement, app: XCUIApplication) {
        // Bring the parent Home content into view before navigating its nested timeline.
        reveal(app.buttons["home.plan.details"], app: app)
        let scroll = app.scrollViews["home.plan.scroll"].firstMatch
        var lastViewport = CGRect.null
        for _ in 0..<8 {
            let window = app.windows.firstMatch.frame
            let navigation = app.navigationBars.firstMatch
            let top = navigation.exists ? max(window.minY, navigation.frame.maxY) : window.minY
            let tab = app.buttons["recording.addSleep"]
            let bottom = tab.exists && tab.isHittable ? tab.frame.minY : window.maxY
            let homeViewport = CGRect(x: window.minX, y: top,
                                      width: window.width, height: max(0, bottom - top))
            guard target.exists else { break }
            let frame = target.frame
            let viewport = scroll.exists ? homeViewport.intersection(scroll.frame) : homeViewport
            lastViewport = viewport
            let exposedInContainer = !scroll.exists || scroll.descendants(matching: .any)
                .matching(identifier: target.identifier).firstMatch.exists
            // This is combined readable text, not a button. Require its complete bounds
            // in the visible container and its accessible label, rather than tap-hittability.
            if exposedInContainer && !frame.isEmpty && !viewport.isNull && viewport.contains(frame) && !target.label.isEmpty { return }
            if frame.minY < homeViewport.minY || frame.maxY > homeViewport.maxY {
                let distance = frame.midY - homeViewport.midY
                let step = min(abs(distance), homeViewport.height * 0.4)
                guard step > 0 else { break }
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: homeViewport.midX, dy: homeViewport.midY))
                start.press(forDuration: 0.05,
                            thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step)),
                            withVelocity: .slow, thenHoldForDuration: 0.1)
            } else if scroll.exists && !viewport.isEmpty {
                if frame.maxX > viewport.maxX { scroll.swipeLeft() }
                else if frame.minX < viewport.minX { scroll.swipeRight() }
                else { break }
            } else { break }
        }
        capture("recorded-wake-not-visible", app: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Recorded wake accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let targetInfo = target.exists
            ? "frame=\(target.frame), hittable=\(target.isHittable), label=\(target.label), value=\(String(describing: target.value))"
            : "missing from accessibility hierarchy"
        let scrollInfo = scroll.exists ? "frame=\(scroll.frame)" : "no horizontal fallback"
        XCTFail("Recorded wake not visible: \(targetInfo); scroll=\(scrollInfo); " +
                "viewport=\(lastViewport); window=\(app.windows.firstMatch.frame)")
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
        let addBreak = app.buttons["sleep.addBreak.22222222-2222-2222-2222-222222222222"]
        XCTAssertTrue(addBreak.waitForExistence(timeout: 5))
        revealDayDetail(addBreak, app: app)
        XCTAssertTrue(addBreak.isHittable)
        addBreak.tap()
        let breakEditor = app.navigationBars["Add Awake Break"]
        XCTAssertTrue(breakEditor.waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        dismissed(breakEditor)
        XCTAssertTrue(addBreak.exists)
    }
    func testPlanActionScrollsToExistingTimelineWithoutInventingNavigation() {
        let app = launch("morningConfirmed")
        let plan = app.buttons["hero.plan"]
        reveal(plan, app: app)
        plan.tap()
        let timeline = app.buttons["home.plan.details"]
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
        XCTAssertTrue(app.navigationBars["Morning Wake"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["home.wake.date"].exists)
        app.buttons["home.wake.cancel"].tap()
        dismissed(app.navigationBars["Morning Wake"])
        XCTAssertTrue(app.buttons["hero.confirmWake"].exists)
        let nap = app.buttons["hero.addNap"]
        reveal(nap, app: app)
        nap.tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
    }

    func testBedtimeRoutineTransitionVisualCaptures() {
        for (scenario, title) in [("bedtimeBefore", "Nap completed"), ("bedtimeRoutine", "Bedtime routine"),
                                  ("nightActive", "Night sleep in progress"), ("morningUnconfirmed", "Good morning, Alex!")] {
            let app = launch(scenario)
            let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            XCTAssertTrue(summary.label.contains(title), summary.label)
            if scenario == "bedtimeRoutine" {
                XCTAssertTrue(summary.label.contains("Baby's usual bedtime"), summary.label)
                XCTAssertTrue(app.buttons["hero.recordNight"].isHittable)
                XCTAssertFalse(app.buttons["hero.endSleep"].exists)
            }
            capture("bedtime-transition-\(scenario)", app: app)
            app.terminate()
        }
    }

    func testBedtimeRecordNightCancelAndCompletedSave() {
        let app = launch("bedtimeRoutine", live: true)
        let record = app.buttons["hero.recordNight"]
        record.tap()
        XCTAssertTrue(app.navigationBars["Add Night Sleep"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recording.end.edit"].exists)
        app.buttons["recording.cancel"].tap()
        dismissed(app.navigationBars["Add Night Sleep"])
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Cancel must leave the routine cue unchanged.")
        record.tap()
        XCTAssertTrue(app.navigationBars["Add Night Sleep"].waitForExistence(timeout: 5))
        let save = app.buttons["recording.save"]
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        dismissed(app.navigationBars["Add Night Sleep"])
        let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Good morning, Alex!"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 5), .completed)
        XCTAssertFalse(record.exists)
        XCTAssertFalse(app.buttons["hero.endSleep"].exists)
    }

    func testBedtimeOngoingSaveAndForegroundPreserveConfirmedState() {
        let app = launch("bedtimeRoutine", live: true, large: true)
        let record = app.buttons["hero.recordNight"]
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Foreground refresh must retain the eligible routine cue.")
        reveal(record, app: app)
        capture("bedtime-routine-large-type", app: app)
        record.tap()
        XCTAssertTrue(app.navigationBars["Add Night Sleep"].waitForExistence(timeout: 5))
        let ongoing = app.switches["recording.ongoing"]
        reveal(ongoing, app: app)
        XCTAssertEqual(ongoing.value as? String, "0")
        ongoing.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -20, dy: 0)).tap()
        let toggled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: ongoing)
        XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 5), .completed)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["recording.end.edit"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        let save = app.buttons["recording.save"]
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        dismissed(app.navigationBars["Add Night Sleep"])
        XCUIDevice.shared.press(.home)
        app.activate()
        let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Night sleep in progress"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["hero.endSleep"].exists)
        XCTAssertFalse(record.exists)
        capture("bedtime-confirmed-night-large-type", app: app)
    }
}

extension TodaySleepHeroUITests {
    private func finishNightAndVerifyCanonicalWake(large: Bool) {
        // This fixture seeds only an ongoing night. The actual Home End Sleep Save
        // must create the wake; no preconstructed completed/wake pair is supplied.
        let app = launch("nightActive", live: true, large: large)
        let end = app.buttons["hero.endSleep"]
        reveal(end, app: app); end.tap()
        let editor = app.navigationBars["Edit Night Sleep"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let save = app.buttons["recording.save"]
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled); save.tap()
        dismissed(editor)
        let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        let morning = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Good morning"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [morning], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["hero.confirmWake"].exists)
        XCTAssertFalse(app.buttons["home.wake.add"].exists)
        let wake = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "home.plan.event.record:", "wake")).firstMatch
        revealPlanObservation(wake, app: app)
        XCTAssertTrue(wake.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch.exists)
        capture(large ? "night-completed-canonical-wake-large" : "night-completed-canonical-wake", app: app)
    }
    func testHomeEndNightCreatesRecordedCanonicalWake() {
        finishNightAndVerifyCanonicalWake(large: false)
    }
    func testHomeEndNightCreatesCanonicalWakeAtAccessibilitySize() {
        finishNightAndVerifyCanonicalWake(large: true)
    }
}

extension TodaySleepHeroUITests {
    func testHomeEndNightStillSleepingConfirmsWithoutRecordingWake() {
        let app = launch("nightActive", live: true, large: true)
        let end = app.buttons["hero.endSleep"]
        reveal(end, app: app); end.tap()
        let editor = app.navigationBars["Edit Night Sleep"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let ongoing = app.switches["recording.ongoing"]
        reveal(ongoing, app: app)
        XCTAssertEqual(ongoing.value as? String, "0")
        XCTAssertTrue(ongoing.isEnabled)
        XCTAssertTrue(ongoing.isHittable)
        ongoing.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -20, dy: 0)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: ongoing)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        let save = app.buttons["recording.save"]
        reveal(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()

        let home = app.scrollViews.containing(.staticText, identifier: "TEST FIXTURE — NOT A PREDICTION").firstMatch
        let summary = home.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        var actualLabel: String?
        func fail(_ reason: String, file: StaticString = #filePath, line: UInt = #line) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "Still Sleeping failure screen"
            image.lifetime = .keepAlways
            add(image)
            let label = actualLabel ?? (summary.exists ? summary.label : "<unavailable>")
            let hierarchy = XCTAttachment(string: "Home summary label: \(label)\n\n\(app.debugDescription)")
            hierarchy.name = "Still Sleeping failure accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("\(reason) Home summary label: \(label)", file: file, line: line)
        }

        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        guard XCTWaiter.wait(for: [closed], timeout: 5) == .completed,
              app.wait(for: .runningForeground, timeout: 5),
              home.waitForExistence(timeout: 10), summary.waitForExistence(timeout: 5) else {
            fail("The Home summary did not become accessible after closing the night editor.")
            return
        }
        let label = summary.label
        actualLabel = label
        guard label.contains("Night sleep in progress"), home.buttons["hero.endSleep"].exists else {
            fail("Expected an ongoing night and the End Sleep action on Home.")
            return
        }
        capture("night-still-sleeping-no-wake-large", app: app)

        // The overnight plan can omit recorded wakes while a night is active.
        // Today's records show the missing-wake card only when there is no recorded wake.
        tapHomeButton("sleep.todayRecords", app: app)
        let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
        guard app.navigationBars["Day detail"].waitForExistence(timeout: 5),
              wake.waitForExistence(timeout: 5),
              wake.label.contains("Add today's wake-up time for better predictions") else {
            fail("Expected today's sleep records to show that the wake was not recorded.")
            return
        }
        XCTAssertTrue(wake.label.contains("No wake recorded"), wake.label)
        XCTAssertFalse(wake.label.contains("Verified"))
        XCTAssertFalse(app.buttons["history.wake.review"].exists)
    }
}

extension TodaySleepHeroUITests {
    private func revealDayDetail(_ element: XCUIElement, app: XCUIApplication, requiresTap: Bool = true) {
        let scroll = app.scrollViews["history.day.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let nav = app.navigationBars["Day detail"]
        for _ in 0..<8 {
            let bounds = window.frame
            let area = bounds.intersection(scroll.frame)
            let top = nav.exists ? max(area.minY, nav.frame.maxY) : area.minY
            let viewport = CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
            guard !viewport.isEmpty, !viewport.isNull, element.exists else { break }
            let frame = element.frame
            let visible = requiresTap ? viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) : viewport.contains(frame)
            if visible && (!requiresTap || element.isHittable) { return }
            let distance = frame.midY - viewport.midY
            let step = min(max(30, abs(distance)), viewport.height * 0.55)
            let startY = viewport.minY + viewport.height * (distance < 0 ? 0.18 : 0.82)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX - bounds.minX, dy: startY - bounds.minY))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        capture("day-detail-target-unreachable", app: app)
        XCTFail("Day Detail element was unreachable: \(element)\n\(app.debugDescription)")
    }

    func testDayDetailShowsUnknownNetForAnOngoingNapAtLargeTextSize() {
        let app = launch("napNetUnknown", live: true, large: true)
        tapHomeButton("sleep.todayRecords", app: app)
        let suffix = "22222222-2222-2222-2222-222222222222"
        let unknown = app.staticTexts["sleep.netSleepUnknown." + suffix]
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        XCTAssertEqual(unknown.label, "Net sleep unknown")
        XCTAssertFalse(app.staticTexts["sleep.netSleep." + suffix].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "history.day.planning").firstMatch.exists)
        revealDayDetail(unknown, app: app, requiresTap: false)
        capture("ongoing-nap-unknown-net-xxxl", app: app)
        let addBreak = app.buttons["sleep.addBreak." + suffix]
        revealDayDetail(addBreak, app: app)
        XCTAssertTrue(addBreak.isHittable)
        capture("day-detail-ongoing-actions-xxxl", app: app)
        let review = app.buttons["daytimeReview.open"]
        revealDayDetail(review, app: app)
        XCTAssertTrue(review.isHittable)
        capture("day-detail-today-review-link-xxxl", app: app)
    }

    func testHistoricalPickerCancelPreservesConfirmationAndAcceptedRevertClearsIt() throws {
        let app = launch("staleNight", live: true)
        let review = app.buttons["hero.reviewEnd"]
        reveal(review, app: app)
        review.tap()
        let confirmation = app.buttons["recording.end.confirm"]
        let end = app.buttons["recording.end.edit"]
        let save = app.buttons["recording.save"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        reveal(confirmation, app: app)
        confirmation.tap()
        XCTAssertTrue(save.isEnabled, "The unchanged endpoint can be explicitly confirmed.")

        reveal(end, app: app)
        end.tap()
        let picker = app.datePickers["recording.end.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let minute = picker.pickerWheels.element(boundBy: 1)
        let original = try selectedMinute(in: minute)
        let other = original == 15 ? "45" : "15"
        minute.adjust(toPickerWheelValue: other)
        app.buttons["recording.time.cancel"].tap()
        dismissed(app.navigationBars["End time"])
        XCTAssertTrue(save.isEnabled)

        reveal(end, app: app)
        end.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(try selectedMinute(in: minute), original)
        minute.adjust(toPickerWheelValue: other)
        minute.adjust(toPickerWheelValue: String(format: "%02d", original))
        XCTAssertEqual(try selectedMinute(in: minute), original)
        app.buttons["recording.time.done"].tap()
        dismissed(app.navigationBars["End time"])
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(confirmation.isEnabled)
    }

    func testHistoricalCompletionPersistsNightAndWakeAfterSelectingDateThenTime() throws {
        try completeHistoricalNight(timeFirst: false)
    }

    func testHistoricalCompletionPersistsNightAndWakeAfterSelectingTimeThenDateAtAccessibilitySize() throws {
        try completeHistoricalNight(timeFirst: true)
    }

    private func completeHistoricalNight(timeFirst: Bool) throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let wakeDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let startDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: wakeDay))
        let start = try XCTUnwrap(calendar.date(bySettingHour: 20, minute: 12, second: 0, of: startDay))
        let wakeTime = try XCTUnwrap(calendar.date(bySettingHour: 7, minute: 21, second: 0, of: wakeDay))
        let reviewTime = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: wakeDay))
        let app = launch("staleNight", live: true, xxl: timeFirst, historicalNightStart: start)
        let review = app.buttons["hero.reviewEnd"]
        reveal(review, app: app)
        review.tap()

        let editor = app.navigationBars["Edit Night Sleep"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recording.start.edit"].exists)
        XCTAssertTrue(app.staticTexts[recordingTimestamp(start, calendar: calendar)].exists)
        let save = app.buttons["recording.save"]
        XCTAssertFalse(save.isEnabled)
        let end = app.buttons["recording.end.edit"]
        reveal(end, app: app)
        end.tap()

        let datePicker = app.datePickers["recording.end.date"]
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        if timeFirst { selectMorningTime(in: app) }
        selectHistoricalDate(wakeDay, from: today, calendar: calendar, in: app)
        if !timeFirst { selectMorningTime(in: app) }
        let selection = app.staticTexts["recording.end.selection"]
        let expected = recordingTimestamp(wakeTime, calendar: calendar)
        XCTAssertEqual(selection.label, expected)
        app.buttons["recording.time.done"].tap()
        dismissed(app.navigationBars["End time"])
        XCTAssertEqual(end.value as? String, expected)
        XCTAssertFalse(save.isEnabled)

        let confirmation = app.buttons["recording.end.confirm"]
        reveal(confirmation, app: app)
        confirmation.tap()
        XCTAssertEqual(confirmation.label, "Observed end confirmed")
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        dismissed(editor)
        dismissed(review)

        app.terminate()
        app.launchEnvironment["SLEEP_HERO_RESET"] = "0"
        app.launchEnvironment["SLEEP_HERO_HISTORICAL_REVIEW_TIME"] = String(reviewTime.timeIntervalSince1970)
        app.launch()
        XCTAssertTrue(app.staticTexts["TEST FIXTURE — NOT A PREDICTION"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["hero.reviewEnd"].exists)
        XCTAssertFalse(app.buttons["hero.endSleep"].exists)

        let wakes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "home.plan.event.record:", "Wake up"))
        let wake = wakes.firstMatch
        revealPlanObservation(wake, app: app)
        XCTAssertEqual(wakes.count, 1)
        XCTAssertTrue(wake.label.contains(wakeTime.formatted(.dateTime.hour().minute())))
        XCTAssertTrue((wake.value as? String)?.contains(wakeDay.formatted(date: .abbreviated, time: .omitted)) == true)

        tapHomeButton("sleep.dayRecords.0", app: app)
        XCTAssertTrue(app.navigationBars[startDay.formatted(.dateTime.day().month(.abbreviated))].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Night Sleep"].exists)
        XCTAssertTrue(app.staticTexts["8:12 PM – 7:21 AM"].exists)
        XCTAssertFalse(app.staticTexts["End unconfirmed"].exists)
        capture(timeFirst ? "historical-time-first-persisted" : "historical-date-first-persisted", app: app)
    }

    private func selectMorningTime(in app: XCUIApplication) {
        let wheels = app.datePickers["recording.end.time"].pickerWheels
        let hours = wheels.element(boundBy: 0)
        reveal(hours, app: app)
        hours.adjust(toPickerWheelValue: "7")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "21")
        if wheels.count == 3 { wheels.element(boundBy: 2).adjust(toPickerWheelValue: "AM") }
    }

    private func selectedMinute(in wheel: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(wheel.value as? String, "The minute wheel did not report a value.")
        let number = value.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
        return try XCTUnwrap(number.flatMap { (0...59).contains($0) ? $0 : nil },
                            "Expected a minute from 0 through 59 in the wheel value '\(value)'.")
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        return XCTWaiter.wait(for: [ready], timeout: 5) == .completed
    }

    private func selectHistoricalDate(_ date: Date, from initialDay: Date, calendar: Calendar, in app: XCUIApplication) {
        let datePicker = app.datePickers["recording.end.date"]
        reveal(datePicker, app: app)
        let control = datePicker.buttons.firstMatch
        if control.exists && control.isHittable {
            control.tap()
        } else {
            datePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let previousMonthID = "DatePicker.PreviousMonth"
        let popover = app.datePickers.containing(.button, identifier: previousMonthID).firstMatch
        if !calendar.isDate(date, equalTo: initialDay, toGranularity: .month) {
            let previousMonth = popover.buttons[previousMonthID]
            guard waitUntilHittable(previousMonth) else {
                XCTFail("The opened calendar's previous-month button is unreachable. \(app.debugDescription)")
                return
            }
            previousMonth.tap()
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        let label = formatter.string(from: date)
        let day = popover.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        guard waitUntilHittable(day) else {
            XCTFail("The opened calendar's '\(label)' button is unreachable. \(app.debugDescription)")
            return
        }
        day.tap()
        if popover.exists {
            let dismissPopup = app.buttons["PopoverDismissRegion"].firstMatch
            if dismissPopup.exists && dismissPopup.isHittable { dismissPopup.tap() }
            dismissed(popover)
        }
    }

    private func recordingTimestamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let zone = calendar.timeZone.abbreviation(for: date) ?? calendar.timeZone.identifier
        return "\(formatter.string(from: date)) \(zone)"
    }

    func testStaleNightCanBeReviewedLaterOrConfirmedWithoutAnElapsedTimer() {
        let app = launch("staleNight", live: true, xxl: true)
        let review = app.buttons["hero.reviewEnd"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hero.endSleep"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.plan.overnight.elapsed").firstMatch.exists)
        reveal(review, app: app)
        review.tap()

        let editor = app.navigationBars["Edit Night Sleep"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recording.start.edit"].exists)
        XCTAssertFalse(app.buttons["recording.save"].isEnabled)
        let deferReview = app.buttons["recording.cancel"]
        XCTAssertEqual(deferReview.label, "Review later")
        deferReview.tap()
        dismissed(editor)
        XCTAssertTrue(review.exists)

        reveal(review, app: app)
        review.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let ongoing = app.switches["recording.ongoing"]
        reveal(ongoing, app: app)
        ongoing.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -20, dy: 0)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: ongoing)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        let save = app.buttons["recording.save"]
        reveal(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        dismissed(editor)

        let summary = app.descendants(matching: .any).matching(identifier: "home.sleep.summary").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Still sleeping confirmed"), object: summary)], timeout: 5), .completed)
        XCTAssertFalse(summary.label.contains("elapsed"))
        XCTAssertTrue(app.buttons["hero.endSleep"].exists)
        XCTAssertTrue(app.buttons["home.wake.add"].exists)
        capture("stale-night-still-sleeping-xxl", app: app)
        app.buttons["AI Coach"].tap()
        let current = app.staticTexts["coach.currentSleep"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(current.label, "Sleeping tonight")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "coach.sleepPreparation").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Time's up"].exists)
    }
}
