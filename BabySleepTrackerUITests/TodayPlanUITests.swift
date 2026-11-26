import XCTest

@MainActor
final class TodayPlanUITests: XCTestCase {
    private let parentID = "33333333-3333-3333-3333-333333333333"
    private let historicalNapID = "44444444-4444-4444-4444-444444444444"
    private let completedNightID = "55555555-5555-5555-5555-555555555555"
    private let wakeID = "66666666-6666-6666-6666-666666666666"

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

    func testHistoricalWakeEditorGatesSaveAndReturnsToSavedDayAtAccessibilitySize() {
        let app = launch("completed", large: true)
        app.buttons["home.plan.details"].tap()
        let detail = app.navigationBars["Day detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let selectedDate = app.staticTexts["history.day.date"]
        XCTAssertTrue(selectedDate.waitForExistence(timeout: 5))
        let todayLabel = selectedDate.label
        XCTAssertTrue(todayLabel.contains("Today"), todayLabel)
        let calendar = Calendar.current
        let expectedDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let display = Date.FormatStyle(date: .omitted, time: .omitted, locale: .current,
                                       calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year()
        let expectedLabel = expectedDay.formatted(display)

        func openEditor() {
            app.buttons["history.day.add"].tap()
            let open = app.buttons["history.wake.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            XCTAssertTrue(app.navigationBars["Historical Morning Wake"].waitForExistence(timeout: 5))
        }

        openEditor()
        let save = app.buttons["history.wake.save"]
        let confirmation = app.switches["history.wake.confirmation"]
        let datePicker = app.descendants(matching: .any).matching(identifier: "history.wake.dateTime").firstMatch
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(confirmation.exists)
        XCTAssertTrue(datePicker.exists)
        app.buttons["history.wake.cancel"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedDate.label, todayLabel)

        openEditor()
        let initialPicker = datePicker.debugDescription
        func failureDetails(_ message: String) -> String {
            """
            \(message)
            Date picker when reopened: \(initialPicker)
            Date picker at failure: \(datePicker.debugDescription)
            \(app.debugDescription)
            """
        }

        let switchControl = confirmation.switches.firstMatch
        for _ in 0..<4 where !switchControl.exists || !switchControl.isHittable { app.swipeUp() }
        XCTAssertTrue(switchControl.exists && switchControl.isHittable,
                      failureDetails("The nested confirmation switch could not be reached."))
        XCTAssertTrue(confirmation.isEnabled && switchControl.isEnabled,
                      failureDetails("The confirmation switch was disabled."))
        XCTAssertEqual(confirmation.value as? String, "0", failureDetails("A reopened editor must start unconfirmed."))
        // At AX XXXL, the labelled switch spans the row. Tap the nested control's center.
        switchControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: confirmation)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 5), .completed,
                       failureDetails("The confirmation switch did not turn on."))

        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        let saveEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saveEnabled], timeout: 5), .completed,
                       failureDetails("Save did not enable after confirmation."))
        XCTAssertTrue(save.isEnabled, failureDetails("Save was disabled before submission."))
        save.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let returnedToSavedDay = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expectedLabel),
                                                           object: selectedDate)
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToSavedDay], timeout: 5), .completed, selectedDate.label)
        XCTAssertTrue(app.buttons["history.wake.review"].exists)
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

    func testStandaloneMorningWakeEditPrefillsCancelsAndSavesRecordedAndVerifiedWake() {
        for scenario in ["morning-wake-recorded", "morning-wake-verified"] {
            let app = launch(scenario)
            let dayLabel = openDayDetailForWakeCorrection(app)
            let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
            XCTAssertTrue(wake.label.contains(scenario == "morning-wake-recorded" ? "Recorded" : "Verified"), wake.label)
            captureMorningWake("\(scenario)-edit-entry", app: app)

            openWakeCorrection(app)
            assertWakeSelection("8:20", app: app)
            XCTAssertFalse(app.staticTexts["home.wake.linkedExplanation"].exists)
            captureMorningWake("\(scenario)-persisted-prefill", app: app)
            selectWakeMinute("35", app: app)
            app.buttons["home.wake.cancel"].tap()
            waitForWakeEditorDismissal(app)
            XCTAssertEqual(app.staticTexts["history.day.date"].label, dayLabel)
            XCTAssertTrue(wake.label.contains("8:20"), "Cancel must retain the persisted wake: \(wake.label)")

            openWakeCorrection(app)
            assertWakeSelection("8:20", app: app)
            selectWakeMinute("35", app: app)
            app.buttons["home.wake.save"].tap()
            waitForWakeEditorDismissal(app)
            assertCorrectedDayAndPlan(dayLabel, linked: false, app: app)
            app.terminate()
        }
    }

    func testLinkedMorningWakeRequiresUpdateBothConsentAndRefreshesTheSameDay() {
        let app = launch("morning-wake-linked")
        let dayLabel = openDayDetailForWakeCorrection(app)
        captureMorningWake("linked-edit-entry", app: app)
        openWakeCorrection(app)
        assertWakeSelection("8:20", app: app)
        XCTAssertTrue(app.staticTexts["home.wake.linkedExplanation"].exists)
        captureMorningWake("linked-persisted-prefill", app: app)

        selectWakeMinute("35", app: app)
        app.buttons["home.wake.save"].tap()
        let updateBoth = app.buttons["home.wake.updateBoth"]
        XCTAssertTrue(updateBoth.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "8:35")).count > 0)
        captureMorningWake("linked-explicit-update-both", app: app)
        app.buttons["home.wake.updateBoth.cancel"].tap()
        app.buttons["home.wake.cancel"].tap()
        waitForWakeEditorDismissal(app)
        let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
        XCTAssertTrue(wake.label.contains("8:20"), "Cancelling consent must not write the correction: \(wake.label)")
        XCTAssertEqual(app.staticTexts["history.day.date"].label, dayLabel)

        // A reopened editor must still use persisted time, not the cancelled proposal.
        openWakeCorrection(app)
        assertWakeSelection("8:20", app: app)
        selectWakeMinute("35", app: app)
        app.buttons["home.wake.save"].tap()
        XCTAssertTrue(updateBoth.waitForExistence(timeout: 5))
        updateBoth.tap()
        waitForWakeEditorDismissal(app)
        assertCorrectedDayAndPlan(dayLabel, linked: true, app: app)
    }

    func testLinkedMorningWakeEditAndConsentRemainReachableInDarkAccessibilitySize() {
        let app = launch("morning-wake-linked", dark: true, large: true)
        let dayLabel = openDayDetailForWakeCorrection(app)
        captureMorningWake("linked-dark-accessibility-edit-entry", app: app)
        openWakeCorrection(app)
        captureMorningWake("linked-dark-accessibility-editor-overview", app: app)
        let date = app.staticTexts["home.wake.date"]
        revealWakeControl(date, app: app, editor: true)
        XCTAssertTrue(date.isHittable)
        assertWakeSelection("8:20", app: app)
        selectWakeMinute("35", app: app)
        captureMorningWake("linked-dark-accessibility-picker", app: app)
        let save = app.buttons["home.wake.save"]
        XCTAssertTrue(save.isHittable && save.isEnabled)
        save.tap()
        let updateBoth = app.buttons["home.wake.updateBoth"]
        XCTAssertTrue(updateBoth.waitForExistence(timeout: 5))
        XCTAssertTrue(updateBoth.isHittable && updateBoth.isEnabled)
        captureMorningWake("linked-dark-accessibility-confirmation", app: app)
        updateBoth.tap()
        waitForWakeEditorDismissal(app)
        assertCorrectedDayAndPlan(dayLabel, linked: true, app: app)
    }

    func testFutureMorningWakeCorrectionShowsErrorAndKeepsPersistedWakeUnchanged() {
        let app = launch("morning-wake-verified")
        let dayLabel = openDayDetailForWakeCorrection(app)
        openWakeCorrection(app)
        assertWakeSelection("8:20", app: app)
        let wheels = app.datePickers["home.wake.time"].pickerWheels
        let hour = wheels.element(boundBy: 0)
        revealWakeControl(hour, app: app, editor: true)
        if wheels.count == 3 {
            hour.adjust(toPickerWheelValue: "1")
            wheels.element(boundBy: 2).adjust(toPickerWheelValue: "PM")
        } else {
            hour.adjust(toPickerWheelValue: "13")
        }
        // B's captured clock is 12:07. The proposed 13:20 is still on the fixed day.
        app.buttons["home.wake.save"].tap()
        let error = app.alerts["Could not save wake time"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(error.staticTexts["Choose a valid wake time on this date that keeps the sleep and awake breaks consistent."].exists)
        captureMorningWake("future-time-rejected-editor-retained", app: app)
        error.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Edit Morning Wake"].buttons["home.wake.cancel"].isHittable)
        XCTAssertFalse(app.staticTexts["home.wake.pending"].exists, "Validation must not reserve an invalid correction.")
        app.buttons["home.wake.cancel"].tap()
        waitForWakeEditorDismissal(app)
        XCTAssertEqual(app.staticTexts["history.day.date"].label, dayLabel)
        let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
        XCTAssertTrue(wake.label.contains("8:20"), wake.label)
        captureMorningWake("future-time-rejected-original-wake", app: app)
    }

    private func openDayDetailForWakeCorrection(_ app: XCUIApplication) -> String {
        app.buttons["home.plan.details"].tap()
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
        let date = app.staticTexts["history.day.date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        let dayLabel = date.label
        XCTAssertTrue(dayLabel.contains("Today"), dayLabel)
        let edit = app.buttons["history.wake.edit"]
        revealWakeControl(edit, app: app)
        XCTAssertTrue(edit.isEnabled && edit.isHittable)
        XCTAssertTrue(edit.label.contains("Edit morning wake"))
        return dayLabel
    }

    private func openWakeCorrection(_ app: XCUIApplication) {
        let edit = app.buttons["history.wake.edit"]
        revealWakeControl(edit, app: app)
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Morning Wake"].waitForExistence(timeout: 5))
        let date = app.staticTexts["home.wake.date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "d MMM yyyy"
        XCTAssertTrue(date.label.contains(formatter.string(from: Date())), date.label)
    }

    private func assertWakeSelection(_ time: String, app: XCUIApplication) {
        let selected = app.staticTexts["home.wake.selection"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", time), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, selected.label)
    }

    private func selectWakeMinute(_ minute: String, app: XCUIApplication) {
        let picker = app.datePickers["home.wake.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        let minuteWheel = picker.pickerWheels.element(boundBy: 1)
        revealWakeControl(minuteWheel, app: app, editor: true)
        XCTAssertTrue(minuteWheel.isEnabled && minuteWheel.isHittable)
        minuteWheel.adjust(toPickerWheelValue: minute)
        assertWakeSelection("8:\(minute)", app: app)
    }

    private func waitForWakeEditorDismissal(_ app: XCUIApplication) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.navigationBars["Edit Morning Wake"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(app.navigationBars["Day detail"].buttons["Done"].isHittable)
    }

    private func assertCorrectedDayAndPlan(_ dayLabel: String, linked: Bool, app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts["history.day.date"].label, dayLabel)
        let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
        let corrected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "8:35"), object: wake)
        XCTAssertEqual(XCTWaiter.wait(for: [corrected], timeout: 5), .completed, wake.label)
        revealWakeControl(app.buttons["history.wake.edit"], app: app)
        captureMorningWake("\(linked ? "linked" : "standalone")-same-day-after-save", app: app)
        app.navigationBars["Day detail"].buttons["Done"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.navigationBars["Day detail"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let observed = event("record:\(wakeID)", app: app)
        reveal(observed, app: app)
        XCTAssertTrue(observed.label.contains("8:35"), "Today's Plan must reload the observed correction: \(observed.label)")
        if linked {
            let night = event("record:\(completedNightID)", app: app)
            let calendar = Calendar.current
            let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
            let start = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: yesterday)!
            let end = calendar.date(bySettingHour: 8, minute: 35, second: 0, of: Date())!
            let minutes = Int(end.timeIntervalSince(start) / 60)
            let duration = "\(minutes / 60)h \(minutes % 60)m net sleep"
            let metadata = night.value as? String ?? ""
            XCTAssertTrue(metadata.contains(duration),
                          "The same linked night's accounting must refresh: \(night.value ?? "missing")")
            XCTAssertTrue(metadata.contains("Previous Sleep Day context."), metadata)
            XCTAssertTrue(metadata.contains("Original Sleep Day: \(yesterday.formatted(date: .abbreviated, time: .omitted))."),
                          "Displaying a completed night on the plan must retain its original Sleep Day: \(metadata)")
        }
        captureMorningWake("\(linked ? "linked" : "standalone")-refreshed-plan", app: app)
    }

    private func captureMorningWake(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "MORNING-WAKE-TEST-ONLY-\(name)"
        image.lifetime = .keepAlways
        add(image)
    }

    private func revealWakeControl(_ element: XCUIElement, app: XCUIApplication, editor: Bool = false) {
        let scroll = app.scrollViews[editor ? "home.wake.scroll" : "history.day.scroll"]
        let navigation = app.navigationBars[editor ? "Edit Morning Wake" : "Day detail"]
        let anchor = editor ? navigation.buttons["home.wake.cancel"] : navigation.buttons["Done"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var previousY: CGFloat?
        var stalledMoves = 0
        for move in 0...10 {
            let foreground = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: anchor)
            guard XCTWaiter.wait(for: [foreground], timeout: 3) == .completed else {
                XCTFail("The expected editor must remain in front: \(app.debugDescription)")
                return
            }
            let window = app.windows.firstMatch
            let body = window.frame.intersection(scroll.frame)
            let top = max(body.minY, navigation.frame.maxY)
            let viewport = CGRect(x: body.minX, y: top, width: body.width, height: body.maxY - top).insetBy(dx: 2, dy: 2)
            let frame = element.exists ? element.frame : .null
            if !frame.isNull && !frame.isEmpty {
                let fits = frame.height <= viewport.height && frame.width <= viewport.width
                let visible = fits ? viewport.contains(frame) : viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                if visible && element.isHittable { return }
                if let previousY, abs(previousY - frame.midY) < 1 { stalledMoves += 1 }
                else { stalledMoves = 0 }
                previousY = frame.midY
            }
            guard move < 10, stalledMoves < 2, !viewport.isEmpty else { break }
            let distance = frame.isNull ? viewport.height : frame.midY - viewport.midY
            let up = distance < 0
            let step = min(max(30, abs(distance)), viewport.height * 0.72)
            let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: viewport.minX + 8 - window.frame.minX,
                dy: viewport.minY + viewport.height * (up ? 0.12 : 0.88) - window.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: up ? step : -step))
            // Drag the content margin, away from the wheel and full-width AX actions.
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
        }
        captureMorningWake("unreachable-control", app: app)
        XCTFail("Wake correction control was not reachable: \(element)\n\(app.debugDescription)")
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
        // TodayPlanUITestFixture anchors carryover at 01:55 today and seeds the
        // same parent ID at 18:45 on the preceding calendar day.
        let calendar = Calendar.current
        let fixtureNow = calendar.date(bySettingHour: 1, minute: 55, second: 0, of: Date())!
        let previousDay = calendar.date(byAdding: .day, value: -1, to: fixtureNow)!
        let originalStart = calendar.date(bySettingHour: 18, minute: 45, second: 0, of: previousDay)!
        let dateDisplay = Date.FormatStyle(date: .omitted, time: .omitted, locale: .current,
                                          calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated).weekday(.abbreviated).year()
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
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
        let selectedDate = app.staticTexts["history.day.date"]
        XCTAssertTrue(selectedDate.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedDate.label, originalStart.formatted(dateDisplay),
                       "The full plan must retain the carried night's original Sleep Day.")
        XCTAssertTrue(app.buttons["sleep.addBreak.\(parentID)"].waitForExistence(timeout: 5), "The full plan opens the carried night's original Sleep Day.")
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
            assertOvernightLayout(app: app, elapsed: scenario == "morning-grace" ? nil : "7h 10m")
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

    func testNightStartsFocusedBeforeMidnightAndKeepsDayHistoryAccessible() {
        let app = launch("night-before-midnight")
        capture("night-before-midnight", app: app)
        let night = event("record:\(parentID)", app: app)
        XCTAssertTrue(night.label.contains("Today ·") && night.label.contains("Ongoing"), night.label)
        XCTAssertFalse(night.label.contains("Yesterday") || night.label.contains("Done"), night.label)
        XCTAssertFalse(event("record:\(historicalNapID)", app: app).exists)
        XCTAssertFalse(event("record:\(wakeID)", app: app).exists)
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.plan.event."))
        XCTAssertEqual(nodes.count, 1, "Only the active night is an observed event in the focused Home horizon.")
        let reference = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        XCTAssertTrue(reference.label.contains("Routine") && reference.label.contains("Morning wake"))
        XCTAssertFalse(reference.label.contains("Done"))
        assertOvernightLayout(app: app, elapsed: "1h 26m")
        app.buttons["home.plan.details"].tap()
        XCTAssertTrue(app.buttons["sleep.addBreak.\(historicalNapID)"].waitForExistence(timeout: 5), "The recorded daytime nap stays in the full plan.")
    }

    func testSameNightRemainsFocusedAfterMidnightWithYesterdayCaption() {
        let app = launch("night-after-midnight")
        capture("night-after-midnight", app: app)
        let night = event("record:\(parentID)", app: app)
        XCTAssertTrue(night.label.contains("Yesterday ·") && night.label.contains("Ongoing"), night.label)
        XCTAssertFalse(night.label.contains("Today ·") || night.label.contains("Done"), night.label)
        XCTAssertTrue((night.value as? String ?? "").contains("Previous Sleep Day"))
        assertOvernightLayout(app: app, elapsed: "6h 50m")
    }

    func testCompletedDayEventsKeepTheirEventTypesAndDoneState() {
        let app = launch("completed-event-icons")
        capture("completed-event-icons", app: app)
        for (id, title) in [(completedNightID, "Night sleep"), (wakeID, "Wake up"), (parentID, "Nap 1")] {
            let node = event("record:\(id)", app: app)
            XCTAssertTrue(node.label.contains(title) && node.label.contains("Done"), node.label)
            XCTAssertFalse(node.label.contains("Sleeping now") || node.label.contains("Ongoing"), node.label)
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.plan.overnightBadge").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch.exists)
        let progress = app.descendants(matching: .any).matching(identifier: "home.plan.progress").firstMatch
        XCTAssertEqual(progress.label, "3 recorded events")
        assertUnavailableIsDetailOnly(app: app)
    }

    private func assertOvernightLayout(app: XCUIApplication, elapsed: String?) {
        let night = event("record:\(parentID)", app: app)
        let wake = app.descendants(matching: .any).matching(identifier: "home.plan.wakeReference").firstMatch
        let duration = app.descendants(matching: .any).matching(identifier: "home.plan.overnight.elapsed")
        XCTAssertEqual(duration.count, elapsed == nil ? 0 : 1, "Only a current recording shows elapsed time.")
        let badge = duration.firstMatch
        if let elapsed {
            XCTAssertTrue(badge.label.contains("Night sleep") && badge.label.contains(elapsed + " elapsed since recorded start"), badge.label)
        }
        XCTAssertEqual(app.staticTexts["home.plan.title"].label, "Today's Plan")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.plan.overnightBadge").firstMatch.exists)
        XCTAssertFalse(app.scrollViews["home.plan.scroll"].exists, "Both overnight nodes fit the default compact layout.")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(wake.frame.midX - night.frame.midX, window.width * 0.4, "Spread the two nodes across the card.")
        // Accessibility bounds include the active halo above its circle, but not
        // the neutral node's empty top padding. Compare the common caption edge.
        XCTAssertEqual(night.frame.maxY, wake.frame.maxY, accuracy: 2, "Both nodes retain aligned caption rows.")
        if elapsed != nil {
            XCTAssertEqual(badge.frame.midX, (night.frame.midX + wake.frame.midX) / 2, accuracy: 3)
            XCTAssertGreaterThan(badge.frame.minY, night.frame.minY + 28, "Duration sits below the connector.")
        }
        XCTAssertFalse(night.label.contains("elapsed") || wake.label.contains("elapsed"))
        assertCompactCard(app: app, maximumHeight: 220)
    }

    private func assertCompactCard(app: XCUIApplication, maximumHeight: CGFloat = 250) {
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
        XCTAssertLessThanOrEqual(height, maximumHeight, "Default-size card must stay compact; actual content height: \(height)")
    }

    private func assertUnavailableIsDetailOnly(app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["home.plan.unavailable"].exists, "Recorded timelines do not need a persistent unavailable footer.")
        XCTAssertEqual(app.buttons["home.plan.details"].value as? String, "Predictions unavailable", "Prediction availability remains accessible through the neutral full-plan detail.")
    }
}
