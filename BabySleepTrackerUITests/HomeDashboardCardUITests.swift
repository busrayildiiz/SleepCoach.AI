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
                // Require a real 44-point target clear of the floating tab controls.
                if !visible.isNull && visible.width >= 44 && visible.height >= 44 {
                    card.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: visible.midX - frame.minX, dy: visible.midY - frame.minY)).tap()
                    return
                }
            }
            // Full-screen flicks overshoot the standalone hero action on SE at AX XXXL
            // and alternate above/below it. Move toward its measured position without inertia.
            let distance = card.exists ? card.frame.midY - viewport.midY : viewport.height
            let step = min(abs(distance), viewport.height * 0.4)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.1)
        }
        XCTFail("Recording card has no visible, hittable 44-point tap area within eight scroll gestures.")
    }

    private func revealWakePickerHour(_ hour: XCUIElement, app: XCUIApplication) {
        let scroll = app.scrollViews["home.wake.scroll"]
        let navigation = app.navigationBars["Today's Wake-up"]
        var previousY: CGFloat?
        var stalledMoves = 0
        for move in 0...4 {
            guard scroll.exists && navigation.buttons["home.wake.cancel"].isHittable else { break }
            let window = app.windows.firstMatch
            let body = window.frame.intersection(scroll.frame)
            let top = max(body.minY, navigation.frame.maxY)
            guard !body.isEmpty && body.maxY > top else { break }
            let viewport = CGRect(x: body.minX, y: top, width: body.width,
                                  height: body.maxY - top).insetBy(dx: 2, dy: 2)
            let frame = hour.exists ? hour.frame : .null
            guard !frame.isNull && !frame.isEmpty && !viewport.isEmpty else { break }
            let fits = frame.height <= viewport.height && frame.width <= viewport.width
            let visible = fits ? viewport.contains(frame) : viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            if visible && hour.isHittable { return }
            if let previousY, abs(previousY - frame.midY) < 1 { stalledMoves += 1 }
            else { stalledMoves = 0 }
            previousY = frame.midY
            guard move < 4 && stalledMoves < 2 else { break }
            let distance = frame.midY - viewport.midY
            let moveDown = distance < 0
            let step = min(max(30, abs(distance)), viewport.height * 0.72)
            let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: viewport.minX + 8 - window.frame.minX,
                dy: viewport.minY + viewport.height * (moveDown ? 0.12 : 0.88) - window.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: moveDown ? step : -step))
            // Move the sheet content along its margin, not the picker wheels.
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
        }
        screenshot("wake-picker-unreachable", app: app)
        XCTFail("Wake hour is not reachable below the editor navigation bar: \(hour)\n\(app.debugDescription)")
    }

    func testWakeSaveHidesAndPersistsAcrossRelaunch() throws {
        let app = launch()
        screenshot("wake-visible", app: app)
        app.buttons["home.wake.add"].tap()
        XCTAssertTrue(app.navigationBars["Today's Wake-up"].waitForExistence(timeout: 5))

        // The suggested 07:00 is still in the future when CI runs after midnight.
        // Enter an observed time that has already elapsed on the local wake day.
        let picker = app.datePickers["home.wake.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        let wheels = picker.pickerWheels
        XCTAssertTrue(wheels.count == 2 || wheels.count == 3, picker.debugDescription)
        let usesMeridiem = wheels.count == 3
        let hour = wheels.element(boundBy: 0)
        let minute = wheels.element(boundBy: 1)
        revealWakePickerHour(hour, app: app)
        XCTAssertTrue(hour.isHittable && minute.isHittable, picker.debugDescription)
        let initialHourValue = try XCTUnwrap(hour.value as? String, picker.debugDescription)
        let hourDigits = try XCTUnwrap(initialHourValue.split(whereSeparator: \.isWhitespace).first,
                                      "The wake hour wheel did not report a value.")
        XCTAssertNotNil(Int(hourDigits), "Unexpected wake hour format: \(initialHourValue)")
        let midnightHour = usesMeridiem ? "12" : String(repeating: "0", count: hourDigits.count)
        hour.adjust(toPickerWheelValue: midnightHour)
        minute.adjust(toPickerWheelValue: "00")
        if usesMeridiem {
            let period = wheels.element(boundBy: 2)
            XCTAssertTrue(period.isHittable, picker.debugDescription)
            period.adjust(toPickerWheelValue: "AM")
            XCTAssertEqual(period.value as? String, "AM", picker.debugDescription)
        }
        let hourValue = try XCTUnwrap(hour.value as? String, picker.debugDescription)
        let minuteValue = try XCTUnwrap(minute.value as? String, picker.debugDescription)
        XCTAssertEqual(Int(hourValue.split(whereSeparator: \.isWhitespace).first ?? ""),
                       usesMeridiem ? 12 : 0, "Unexpected wake hour: \(hourValue)")
        XCTAssertEqual(Int(minuteValue.split(whereSeparator: \.isWhitespace).first ?? ""),
                       0, "Unexpected wake minute: \(minuteValue)")
        app.buttons["home.wake.save"].tap()
        XCTAssertFalse(app.buttons["Confirm and Save"].exists,
                       "An explicitly edited wake time must not use the untouched-time confirmation.")
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
        app.buttons["Confirm and Save"].tap()
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
        // The hero's explicit Add Nap action keeps the existing recording destination.
        let add = app.buttons["hero.addNap"]
        tapVisibleRecordingCard(add, app: app)
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
    }
}
