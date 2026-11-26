import XCTest

@MainActor
final class DaytimeCoverageReviewUITests: XCTestCase {
    private func launch(scenario: String = "wakeOnly", failSave: Bool = false, largeType: Bool = false,
                        dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        app.launchEnvironment["DAYTIME_COVERAGE_UI_TESTS"] = "1"
        app.launchEnvironment["DAYTIME_COVERAGE_SCENARIO"] = scenario
        if failSave { app.launchEnvironment["DAYTIME_COVERAGE_FAIL_SAVE"] = "1" }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-appAppearance", dark ? "dark" : "light"]
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private enum Screen: Equatable {
        case homeOrEditor, review, dayDetail

        var scrollID: String? {
            switch self {
            case .homeOrEditor: return nil
            case .review: return "daytimeReview.scroll"
            case .dayDetail: return "history.day.scroll"
            }
        }

        var navigationTitle: String {
            self == .review ? "Daytime review" : "Day detail"
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        requireHittable: Bool = true, screen: Screen = .homeOrEditor) {
        let window = app.windows.firstMatch
        let moveLimit = 12
        var lastTargetY: CGFloat?
        var stalledMoves = 0
        var moves = 0
        var viewport = CGRect.null

        let scroll = screen.scrollID.map { app.scrollViews[$0] }
        if let scroll {
            XCTAssertTrue(scroll.waitForExistence(timeout: 5), "Missing \(screen.navigationTitle) scroll view.")
        }

        for move in 0...moveLimit {
            let bounds = window.frame
            if let scroll {
                let navigation = app.navigationBars[screen.navigationTitle]
                // A pushed review also exposes the parent Back button. Use the
                // current screen's own action to verify that it is reachable.
                let navigationAnchor = screen == .review
                    ? navigation.buttons["daytimeReview.later"] : navigation.buttons["Done"]
                let foreground = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND hittable == true"),
                    object: navigationAnchor)
                guard XCTWaiter.wait(for: [foreground], timeout: 3) == .completed else {
                    captureReview("scroll-foreground-check-failed")
                    XCTFail("\(screen.navigationTitle) has no reachable navigation action: \(app.debugDescription)")
                    return
                }
                let body = bounds.intersection(scroll.frame)
                let top = max(body.minY, navigation.exists ? navigation.frame.maxY : body.minY)
                let footer = app.buttons["daytimeReview.save"].exists
                    ? app.buttons["daytimeReview.save"] : app.buttons["daytimeReview.reopen"]
                let bottom = screen == .review && footer.exists
                    ? min(body.maxY, footer.frame.minY - 20) : body.maxY
                viewport = CGRect(x: body.minX, y: top, width: body.width, height: max(0, bottom - top))
                    .insetBy(dx: 2, dy: 2)
            } else {
                let tab = app.buttons["recording.addSleep"]
                let bottom = tab.exists && tab.isHittable ? tab.frame.minY : bounds.maxY
                viewport = CGRect(x: bounds.minX + 6, y: bounds.minY + 55, width: bounds.width - 12,
                                  height: max(0, bottom - bounds.minY - 65))
            }
            guard !viewport.isEmpty, !viewport.isNull else { break }

            let frame = element.exists ? element.frame : .null
            let hasFrame = !frame.isEmpty
            if hasFrame, !requireHittable || element.isHittable,
               viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return
            }

            let currentTargetY = scroll != nil && hasFrame ? frame.midY : nil
            if let currentTargetY, let lastTargetY, abs(currentTargetY - lastTargetY) < 1 {
                stalledMoves += 1
            } else {
                stalledMoves = 0
            }
            lastTargetY = currentTargetY
            guard move < moveLimit, stalledMoves < 2 else { break }

            let targetY = scroll != nil && frame.midY < viewport.minY ? viewport.minY + 24 : viewport.midY
            let distance = hasFrame ? frame.midY - targetY : (towardTop ? -viewport.height : viewport.height)
            let scrollingUp = distance < 0
            let stride: CGFloat = scroll == nil ? 0.4 : 0.72
            let step = min(max(30, abs(distance)), viewport.height * stride)
            let startY = scroll == nil ? viewport.midY :
                viewport.minY + viewport.height * (scrollingUp ? 0.12 : 0.88)
            // Keep navigation drags inside the scroll view's content margin,
            // away from the wide Edit/Add awake break actions at large text sizes.
            let startX = scroll == nil ? viewport.midX : viewport.minX + 8
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: startX - bounds.minX, dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: scrollingUp ? step : -step))
            if scroll != nil {
                start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
            } else {
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            moves += 1
        }
        if scroll != nil { captureReview("scroll-target-unreachable") }
        XCTFail("Control was unreachable after \(moves) moves (\(stalledMoves) without progress). " +
                "Viewport \(viewport), last target y \(lastTargetY.map { "\($0)" } ?? "unavailable"): " +
                "\(element)\n\(app.debugDescription)")
    }

    private func assertFooterButton(_ button: XCUIElement, app: XCUIApplication, enabled: Bool) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let frame = button.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame))
        XCTAssertEqual(button.isEnabled, enabled)
        if enabled { XCTAssertTrue(button.isHittable) }
    }

    private func openFromToday(_ app: XCUIApplication) {
        let records = app.buttons["sleep.todayRecords"]
        reveal(records, in: app)
        records.tap()
        openReviewLink(app, historical: false)
    }

    private func openReviewLink(_ app: XCUIApplication, historical: Bool) {
        let link = app.buttons["daytimeReview.open"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        reveal(link, in: app, screen: .dayDetail)
        XCTAssertTrue(link.isHittable)
        XCTAssertEqual(link.label, historical ? "Review daytime recording" : "Review a past day")
        link.tap()
        XCTAssertTrue(app.navigationBars["Daytime review"].waitForExistence(timeout: 5))
        let select = app.buttons["daytimeReview.select"]
        if historical {
            XCTAssertTrue(app.staticTexts["daytimeReview.day"].waitForExistence(timeout: 5))
            XCTAssertFalse(select.exists)
        } else {
            XCTAssertTrue(select.waitForExistence(timeout: 5))
            select.tap()
        }
    }

    private func expectStatus(_ label: String, app: XCUIApplication) {
        let status = app.staticTexts["daytimeReview.status"]
        reveal(status, in: app, towardTop: true, screen: .review)
        let predicate = NSPredicate(format: "label == %@", label)
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: 5)
    }

    private func chooseAndSave(_ identifier: String, app: XCUIApplication) {
        let choice = app.buttons[identifier]
        reveal(choice, in: app, screen: .review)
        choice.tap()
        let save = app.buttons["daytimeReview.save"]
        assertFooterButton(save, app: app, enabled: true)
        save.tap()
    }

    private func captureReview(_ state: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "B2-3-\(state)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitForReview(after editor: XCUIElement, app: XCUIApplication) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Daytime review"].waitForExistence(timeout: 5))
    }

    private func reopenWithoutReusingAnswer(_ app: XCUIApplication) {
        let reopen = app.buttons["daytimeReview.reopen"]
        assertFooterButton(reopen, app: app, enabled: true)
        let save = app.buttons["daytimeReview.save"]
        XCTAssertFalse(save.exists)
        reopen.tap()
        assertFooterButton(save, app: app, enabled: false)
        expectStatus("Needs review again", app: app)
    }

    func testWakeOnlyReviewRequiresChoicePersistsAndCanBeWithdrawn() {
        let app = launch()
        openFromToday(app)
        expectStatus("Awaiting review", app: app)
        let save = app.buttons["daytimeReview.save"]
        assertFooterButton(save, app: app, enabled: false)
        let zero = app.buttons["daytimeReview.complete"]
        reveal(zero, in: app, towardTop: true, screen: .review)
        XCTAssertEqual(zero.label, "There were no naps")
        zero.tap()
        expectStatus("Awaiting review", app: app)
        reveal(zero, in: app, screen: .review)
        captureReview("zero-nap-answer")
        app.buttons["daytimeReview.later"].tap()

        openReviewLink(app, historical: false)
        expectStatus("Awaiting review", app: app)
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Zero naps confirmed", app: app)
        captureReview("zero-naps-confirmed")

        app.terminate()
        app.launchEnvironment["DAYTIME_COVERAGE_RESET"] = "0"
        app.launch()
        openFromToday(app)
        expectStatus("Zero naps confirmed", app: app)
        let withdraw = app.buttons["daytimeReview.withdraw"]
        reveal(withdraw, in: app, screen: .review)
        withdraw.tap()
        app.buttons["Cancel"].tap()
        expectStatus("Zero naps confirmed", app: app)
        reveal(withdraw, in: app, screen: .review)
        withdraw.tap()
        app.buttons["Withdraw saved answer"].tap()
        expectStatus("Awaiting review", app: app)
    }

    func testFailedSaveKeepsChoiceAndRetrySavesIncompleteAnswer() {
        let app = launch(failSave: true)
        openFromToday(app)
        chooseAndSave("daytimeReview.incomplete", app: app)
        expectStatus("Awaiting review", app: app)
        let feedback = app.staticTexts["daytimeReview.feedback"]
        reveal(feedback, in: app, screen: .review)
        XCTAssertTrue(feedback.label.contains("verify the save"))
        let retry = app.buttons["daytimeReview.save"]
        assertFooterButton(retry, app: app, enabled: true)
        XCTAssertEqual(retry.label, "Retry save")
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        expectStatus("Recording marked incomplete", app: app)
        captureReview("saved-incomplete")
    }

    func testAddingNapInvalidatesConfirmationAndReturnsToTheSameReview() {
        let app = launch()
        openFromToday(app)
        let day = app.staticTexts["daytimeReview.day"].label
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Zero naps confirmed", app: app)
        let add = app.buttons["daytimeReview.addNap"]
        reveal(add, in: app, screen: .review)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
        let saveNap = app.buttons["recording.save"]
        XCTAssertTrue(saveNap.waitForExistence(timeout: 5))
        XCTAssertFalse(saveNap.isEnabled)
        let confirmTimes = app.buttons["recording.napTimes.confirm"]
        reveal(confirmTimes, in: app)
        XCTAssertEqual(confirmTimes.label, "Confirm observed start and end")
        confirmTimes.tap()
        XCTAssertTrue(saveNap.isEnabled)
        saveNap.tap()
        XCTAssertTrue(app.navigationBars["Daytime review"].waitForExistence(timeout: 5))
        expectStatus("Needs review again", app: app)
        captureReview("invalidated")
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, day)
        let reopen = app.buttons["daytimeReview.reopen"]
        assertFooterButton(reopen, app: app, enabled: true)
        reopen.tap()
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Coverage confirmed by you", app: app)
        captureReview("confirmed-with-naps")
        let nap = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.0").firstMatch
        reveal(nap, in: app, screen: .review)
        XCTAssertTrue(nap.label.contains("Unverified recording"))
        captureReview("confirmed-unverified-nap")
    }

    func testEditingExistingNapRefreshesSameDayAndRequiresNewAnswer() {
        let app = launch(scenario: "withNaps")
        openFromToday(app)
        expectStatus("Awaiting review", app: app)
        let reviewDay = app.staticTexts["daytimeReview.day"].label
        let naps = app.descendants(matching: .any)
        let first = naps.matching(identifier: "daytimeReview.nap.0").firstMatch
        reveal(first, in: app, screen: .review)
        XCTAssertTrue(first.label.contains("9:45"), first.label)
        captureReview("recorded-naps")
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Coverage confirmed by you", app: app)

        let edit = app.buttons["daytimeReview.nap.0.edit"]
        reveal(edit, in: app, screen: .review)
        edit.tap()
        let editor = app.navigationBars["Edit Nap"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let end = app.buttons["recording.end.edit"]
        reveal(end, in: app)
        end.tap()
        let time = app.datePickers["recording.end.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        time.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "50")
        app.buttons["recording.time.done"].tap()
        let saveNap = app.buttons["recording.save"]
        XCTAssertTrue(saveNap.waitForExistence(timeout: 5))
        XCTAssertTrue(saveNap.isEnabled)
        saveNap.tap()
        waitForReview(after: editor, app: app)

        expectStatus("Needs review again", app: app)
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, reviewDay)
        reveal(first, in: app, screen: .review)
        XCTAssertTrue(first.label.contains("9:00"), first.label)
        XCTAssertTrue(first.label.contains("9:50"), first.label)
        let second = naps.matching(identifier: "daytimeReview.nap.1").firstMatch
        reveal(second, in: app, screen: .review)
        XCTAssertTrue(second.label.contains("12:00"), second.label)
        reopenWithoutReusingAnswer(app)
    }

    func testCorrectingHistoricalWakeRefreshesSameDayAndRetiresPendingConfirmation() {
        let app = launch()
        openFromToday(app)
        expectStatus("Awaiting review", app: app)
        let reviewDay = app.staticTexts["daytimeReview.day"].label
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Zero naps confirmed", app: app)

        let complete = app.buttons["daytimeReview.complete"]
        reveal(complete, in: app, screen: .review)
        complete.tap()
        let saveReview = app.buttons["daytimeReview.save"]
        assertFooterButton(saveReview, app: app, enabled: true)

        let edit = app.buttons["daytimeReview.morning.edit"]
        reveal(edit, in: app, towardTop: true, screen: .review)
        edit.tap()
        let editor = app.navigationBars["Historical Morning Wake"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let picker = app.descendants(matching: .any).matching(identifier: "history.wake.dateTime").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let minute = app.pickerWheels.element(boundBy: 1)
        let opensCompactPicker = !minute.exists
        if opensCompactPicker {
            let timeButton = picker.buttons.firstMatch
            (timeButton.exists ? timeButton : picker).tap()
        }
        XCTAssertTrue(minute.waitForExistence(timeout: 5), app.debugDescription)
        minute.adjust(toPickerWheelValue: "15")
        if opensCompactPicker && minute.exists {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let saveWake = app.buttons["history.wake.save"]
        reveal(saveWake, in: app, requireHittable: false)
        XCTAssertFalse(saveWake.isEnabled)
        let confirmation = app.switches["history.wake.confirmation"]
        let control = confirmation.switches.firstMatch
        reveal(control, in: app, towardTop: true)
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        reveal(saveWake, in: app)
        XCTAssertTrue(saveWake.isEnabled)
        saveWake.tap()
        waitForReview(after: editor, app: app)

        expectStatus("Needs review again", app: app)
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, reviewDay)
        let morning = app.descendants(matching: .any).matching(identifier: "daytimeReview.morning").firstMatch
        reveal(morning, in: app, screen: .review)
        XCTAssertTrue(morning.label.contains("7:15"), morning.label)
        XCTAssertTrue(morning.label.contains("Verified wake"), morning.label)
        reopenWithoutReusingAnswer(app)
    }

    func testMissingFollowingWakeBlocksBothAnswers() {
        let app = launch(scenario: "missingFollowing")
        let records = app.buttons["sleep.todayRecords"]
        reveal(records, in: app)
        records.tap()
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
        let subtotal = app.descendants(matching: .any).matching(identifier: "history.day.summary").firstMatch
        XCTAssertTrue(subtotal.waitForExistence(timeout: 5))
        XCTAssertTrue(subtotal.label.contains("Unknown"), subtotal.label)
        let wake = app.descendants(matching: .any).matching(identifier: "history.day.wake").firstMatch
        XCTAssertTrue(wake.label.contains("No wake recorded"), wake.label)
        captureReview("day-detail-today-missing-observations")
        openReviewLink(app, historical: false)
        expectStatus("Review unavailable", app: app)
        captureReview("missing-wake-blocker")
        let following = app.descendants(matching: .any).matching(identifier: "daytimeReview.following").firstMatch
        reveal(following, in: app, screen: .review)
        XCTAssertTrue(following.label.contains("Missing wake"))
        captureReview("missing-following-wake")
        XCTAssertFalse(app.buttons["daytimeReview.complete"].exists)
        XCTAssertFalse(app.buttons["daytimeReview.incomplete"].exists)
        XCTAssertFalse(app.buttons["daytimeReview.save"].exists)
    }

    func testDuplicateMorningWakeExplainsBlockAndOffersAnotherDate() {
        let app = launch(scenario: "duplicateMorning")
        openFromToday(app)
        expectStatus("Review unavailable", app: app)
        let morning = app.descendants(matching: .any).matching(identifier: "daytimeReview.morning").firstMatch
        reveal(morning, in: app, screen: .review)
        XCTAssertTrue(morning.label.contains("More than one morning wake is recorded for this date."))
        XCTAssertTrue(morning.label.contains("Choose another date or review later."))
        XCTAssertFalse(app.buttons["daytimeReview.morning.edit"].exists)

        let chooseDate = app.buttons["daytimeReview.chooseDate"]
        reveal(chooseDate, in: app, screen: .review)
        XCTAssertFalse(app.buttons["daytimeReview.save"].exists)
        chooseDate.tap()
        XCTAssertTrue(app.buttons["daytimeReview.select"].waitForExistence(timeout: 5))
    }

    func testHistoricalEntryShowsChronologicalNapsAndReachableActionsAtAccessibilitySize() {
        let app = launch(scenario: "withNaps", largeType: true)
        let day = app.buttons["sleep.dayRecords.0"]
        reveal(day, in: app)
        day.tap()
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
        let selectedDay = app.staticTexts["history.day.date"].label
        captureReview("day-detail-historical-accessibility-overview")
        let firstRecord = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.sleep.record.")).firstMatch
        reveal(firstRecord, in: app, screen: .dayDetail)
        let beforeScrollY = firstRecord.frame.midY
        // A normal pan that begins on a record must scroll, not activate its tap or long press.
        let start = firstRecord.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)),
                    withVelocity: .default, thenHoldForDuration: 0)
        let recordingCancel = app.buttons["recording.cancel"]
        XCTAssertFalse(recordingCancel.exists && recordingCancel.isHittable, "Scrolling a record must not open its editor.")
        XCTAssertTrue(app.navigationBars["Day detail"].buttons["Done"].isHittable)
        XCTAssertLessThan(firstRecord.frame.midY, beforeScrollY - 10, "The record pan must move the scroll content.")
        let reviewLink = app.buttons["daytimeReview.open"]
        reveal(reviewLink, in: app, screen: .dayDetail)
        captureReview("day-detail-historical-accessibility-review-link")
        openReviewLink(app, historical: true)
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, selectedDay)
        let morning = app.descendants(matching: .any).matching(identifier: "daytimeReview.morning").firstMatch
        reveal(morning, in: app, screen: .review)
        captureReview("wake-boundaries-accessibility-xxxl")
        let first = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.0").firstMatch
        let second = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.1").firstMatch
        reveal(first, in: app, screen: .review)
        XCTAssertTrue(first.label.contains("9:00"))
        reveal(second, in: app, screen: .review)
        XCTAssertTrue(second.label.contains("12:00"))
        captureReview("recorded-naps-accessibility-xxxl")
        let complete = app.buttons["daytimeReview.complete"]
        reveal(complete, in: app, screen: .review)
        complete.tap()
        let save = app.buttons["daytimeReview.save"]
        assertFooterButton(save, app: app, enabled: true)
        captureReview("choices-and-footer-accessibility-xxxl")
        save.tap()
        expectStatus("Coverage confirmed by you", app: app)
        captureReview("confirmed-accessibility-xxxl")
        XCTAssertTrue(app.buttons["daytimeReview.later"].isHittable)
    }

    private func waitForDetail(after editor: XCUIElement, app: XCUIApplication) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
    }

    func testDayDetailEditAndReviewKeepVerificationPerRecord() {
        let app = launch(scenario: "withNaps")
        let entry = app.buttons["sleep.dayRecords.0"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))

        let day = app.staticTexts["history.day.date"].label
        let detailRecords = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.sleep.record."))
        let first = detailRecords.element(boundBy: 0)
        let second = detailRecords.element(boundBy: 1)
        reveal(first, in: app, screen: .dayDetail)
        XCTAssertTrue(first.label.contains("9:00") && first.label.contains("9:45"), first.label)
        XCTAssertFalse(first.label.contains("Verified"))
        let recordID = String(first.identifier.dropFirst("history.sleep.record.".count))
        let edit = app.buttons["history.sleep.edit.\(recordID)"]
        first.tap()
        let editor = app.navigationBars["Edit Nap"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        waitForDetail(after: editor, app: app)
        XCTAssertTrue(first.label.contains("9:00") && first.label.contains("9:45"), first.label)

        reveal(edit, in: app, screen: .dayDetail)
        edit.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for (endpoint, minute) in [("start", "05"), ("end", "50")] {
            let endpointButton = app.buttons["recording.\(endpoint).edit"]
            reveal(endpointButton, in: app)
            endpointButton.tap()
            let time = app.datePickers["recording.\(endpoint).time"]
            XCTAssertTrue(time.waitForExistence(timeout: 5))
            time.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: minute)
            app.buttons["recording.time.done"].tap()
        }
        let saveNap = app.buttons["recording.save"]
        reveal(saveNap, in: app)
        XCTAssertTrue(saveNap.isEnabled)
        saveNap.tap()
        waitForDetail(after: editor, app: app)
        reveal(first, in: app, screen: .dayDetail)
        XCTAssertEqual(app.staticTexts["history.day.date"].label, day)
        XCTAssertTrue(first.label.contains("9:05") && first.label.contains("9:50"), first.label)
        XCTAssertTrue(first.label.contains("Verified"), first.label)
        reveal(second, in: app, screen: .dayDetail)
        XCTAssertTrue(second.label.contains("12:00"), second.label)
        XCTAssertFalse(second.label.contains("Verified"))
        let subtotal = app.descendants(matching: .any).matching(identifier: "history.day.summary").firstMatch
        reveal(subtotal, in: app, towardTop: true, screen: .dayDetail)
        XCTAssertTrue(subtotal.label.contains("Incomplete"), subtotal.label)
        captureReview("day-detail-historical-verified-and-incomplete")

        openReviewLink(app, historical: true)
        let verified = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.0").firstMatch
        let unverified = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.1").firstMatch
        reveal(verified, in: app, screen: .review)
        XCTAssertTrue(verified.label.contains("Verified recording"), verified.label)
        reveal(unverified, in: app, screen: .review)
        XCTAssertTrue(unverified.label.contains("Unverified recording"), unverified.label)

        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Coverage confirmed by you", app: app)
        XCTAssertTrue(verified.label.contains("Verified recording"), verified.label)
        XCTAssertTrue(unverified.label.contains("Unverified recording"), unverified.label)
        captureReview("confirmed-mixed-verification")

        app.buttons["daytimeReview.later"].tap()
        XCTAssertTrue(app.navigationBars["Day detail"].waitForExistence(timeout: 5))
        reveal(second, in: app, screen: .dayDetail)
        let unchangedID = second.identifier
        second.press(forDuration: 0.6)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: unchangedID).firstMatch.exists)
        reveal(second, in: app, screen: .dayDetail)
        second.press(forDuration: 0.6)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let removed = app.descendants(matching: .any).matching(identifier: unchangedID).firstMatch
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: removed)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 5), .completed)
        XCTAssertTrue(first.label.contains("9:05") && first.label.contains("Verified"), first.label)
    }

    func testUnsavedChoiceKeepsReviewStatusInDarkAppearance() {
        let app = launch(scenario: "withNaps", dark: true)
        openFromToday(app)
        expectStatus("Awaiting review", app: app)
        captureReview("recorded-naps-dark")
        let choice = app.buttons["daytimeReview.complete"]
        reveal(choice, in: app, screen: .review)
        choice.tap()
        assertFooterButton(app.buttons["daytimeReview.save"], app: app, enabled: true)
        captureReview("selected-unsaved-dark")
        expectStatus("Awaiting review", app: app)
    }
}
