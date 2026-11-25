import XCTest

@MainActor
final class DaytimeCoverageReviewUITests: XCTestCase {
    private func launch(scenario: String = "wakeOnly", failSave: Bool = false, largeType: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        app.launchEnvironment["DAYTIME_COVERAGE_UI_TESTS"] = "1"
        app.launchEnvironment["DAYTIME_COVERAGE_SCENARIO"] = scenario
        if failSave { app.launchEnvironment["DAYTIME_COVERAGE_FAIL_SAVE"] = "1" }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        requireHittable: Bool = true, inReview: Bool = false) {
        let window = app.windows.firstMatch
        let navigation = app.navigationBars["Daytime recording"]
        let moveLimit = 12
        var lastTargetY: CGFloat?
        var stalledMoves = 0
        var moves = 0
        var viewport = CGRect.null

        for move in 0...moveLimit {
            let form = inReview ? app.collectionViews.firstMatch : nil
            if let form {
                guard window.exists || window.waitForExistence(timeout: 5),
                      navigation.exists || navigation.waitForExistence(timeout: 5),
                      form.exists || form.waitForExistence(timeout: 5) else {
                    captureReview("scroll-review-unavailable")
                    XCTFail("Daytime recording was unavailable after \(moves) scroll moves. " +
                            "App state \(app.state), window \(window.exists), navigation \(navigation.exists), " +
                            "form \(form.exists).\n\(app.debugDescription)")
                    return
                }
            }
            let screen = window.frame
            if inReview {
                // The review fills the sheet below its navigation bar. Use window
                // coordinates so gestures do not resolve the Form during animation.
                let navigationFrame = navigation.frame
                guard !navigationFrame.isEmpty, screen.intersects(navigationFrame) else { break }
                let top = max(screen.minY, navigationFrame.maxY)
                viewport = CGRect(x: screen.minX, y: top, width: screen.width,
                                  height: max(0, screen.maxY - top)).insetBy(dx: 6, dy: 6)
            } else {
                let tab = app.buttons["recording.addSleep"]
                let bottom = tab.exists && tab.isHittable ? tab.frame.minY : screen.maxY
                viewport = CGRect(x: screen.minX + 6, y: screen.minY + 55, width: screen.width - 12,
                                  height: max(0, bottom - screen.minY - 65))
            }
            guard !viewport.isEmpty else { break }

            let frame = element.exists ? element.frame : .null
            let hasFrame = !frame.isEmpty
            if hasFrame, !requireHittable || element.isHittable,
               viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return
            }

            // Measure movement from the app-scoped target once its row resolves.
            // The move limit bounds scrolling while the row is virtualized.
            let currentTargetY = inReview && hasFrame ? frame.midY : nil
            if let currentTargetY, let lastTargetY, abs(currentTargetY - lastTargetY) < 1 {
                stalledMoves += 1
            } else {
                stalledMoves = 0
            }
            lastTargetY = currentTargetY
            guard move < moveLimit, stalledMoves < 2 else { break }

            let targetY = inReview && frame.midY < viewport.minY ? viewport.minY + 24 : viewport.midY
            let distance = hasFrame ? frame.midY - targetY : (towardTop ? -viewport.height : viewport.height)
            let scrollingUp = distance < 0
            let stride: CGFloat = inReview ? 0.75 : 0.4
            let step = min(max(30, abs(distance)), viewport.height * stride)
            let startY = !inReview ? viewport.midY :
                viewport.minY + viewport.height * (scrollingUp ? 0.12 : 0.88)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX - screen.minX, dy: startY - screen.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: scrollingUp ? step : -step))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            moves += 1
        }
        if inReview { captureReview("scroll-target-unreachable") }
        XCTFail("Review control was unreachable after \(moves) moves (\(stalledMoves) without progress). " +
                "Viewport \(viewport), last target y \(lastTargetY.map { "\($0)" } ?? "unavailable"): " +
                "\(element)\n\(app.debugDescription)")
    }

    private func openFromToday(_ app: XCUIApplication) {
        let records = app.buttons["sleep.todayRecords"]
        reveal(records, in: app)
        records.tap()
        openReviewLink(app)
    }

    private func openReviewLink(_ app: XCUIApplication) {
        let link = app.buttons["daytimeReview.open"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Daytime recording"].waitForExistence(timeout: 5))
        let select = app.buttons["daytimeReview.select"]
        if select.exists { select.tap() }
    }

    private func expectStatus(_ label: String, app: XCUIApplication) {
        let status = app.staticTexts["daytimeReview.status"]
        reveal(status, in: app, towardTop: true, inReview: true)
        let predicate = NSPredicate(format: "label == %@", label)
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: 5)
    }

    private func chooseAndSave(_ identifier: String, app: XCUIApplication) {
        let choice = app.buttons[identifier]
        reveal(choice, in: app)
        choice.tap()
        let save = app.buttons["daytimeReview.save"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
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
        XCTAssertTrue(app.navigationBars["Daytime recording"].waitForExistence(timeout: 5))
    }

    private func reopenWithoutReusingAnswer(_ app: XCUIApplication) {
        let reopen = app.buttons["daytimeReview.reopen"]
        reveal(reopen, in: app)
        let save = app.buttons["daytimeReview.save"]
        XCTAssertFalse(save.exists)
        reopen.tap()
        reveal(save, in: app, requireHittable: false)
        XCTAssertFalse(save.isEnabled)
        expectStatus("Needs review again", app: app)
    }

    func testWakeOnlyReviewRequiresChoicePersistsAndCanBeWithdrawn() {
        let app = launch()
        openFromToday(app)
        expectStatus("Awaiting review", app: app)
        let save = app.buttons["daytimeReview.save"]
        reveal(save, in: app, requireHittable: false)
        XCTAssertFalse(save.isEnabled)
        let zero = app.buttons["daytimeReview.complete"]
        reveal(zero, in: app, towardTop: true)
        XCTAssertEqual(zero.label, "There were no naps")
        zero.tap()
        captureReview("zero-nap-answer")
        app.buttons["daytimeReview.later"].tap()

        openReviewLink(app)
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
        reveal(withdraw, in: app)
        withdraw.tap()
        app.buttons["Cancel"].tap()
        expectStatus("Zero naps confirmed", app: app)
        reveal(withdraw, in: app)
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
        reveal(feedback, in: app)
        XCTAssertTrue(feedback.label.contains("verify the save"))
        let retry = app.buttons["daytimeReview.save"]
        reveal(retry, in: app)
        XCTAssertEqual(retry.label, "Retry save")
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        expectStatus("Recording marked incomplete", app: app)
    }

    func testAddingNapInvalidatesConfirmationAndReturnsToTheSameReview() {
        let app = launch()
        openFromToday(app)
        let day = app.staticTexts["daytimeReview.day"].label
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Zero naps confirmed", app: app)
        let add = app.buttons["daytimeReview.addNap"]
        reveal(add, in: app)
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
        XCTAssertTrue(app.navigationBars["Daytime recording"].waitForExistence(timeout: 5))
        expectStatus("Needs review again", app: app)
        captureReview("invalidated")
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, day)
        let reopen = app.buttons["daytimeReview.reopen"]
        reveal(reopen, in: app)
        reopen.tap()
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("You confirmed all naps were recorded", app: app)
        captureReview("confirmed-with-naps")
        let nap = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.0").firstMatch
        reveal(nap, in: app)
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
        reveal(first, in: app)
        XCTAssertTrue(first.label.contains("9:45"), first.label)
        captureReview("recorded-naps")
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("You confirmed all naps were recorded", app: app)

        let edit = app.buttons["daytimeReview.nap.0.edit"]
        reveal(edit, in: app)
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
        reveal(first, in: app)
        XCTAssertTrue(first.label.contains("9:00"), first.label)
        XCTAssertTrue(first.label.contains("9:50"), first.label)
        let second = naps.matching(identifier: "daytimeReview.nap.1").firstMatch
        reveal(second, in: app)
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
        reveal(complete, in: app)
        complete.tap()
        let saveReview = app.buttons["daytimeReview.save"]
        reveal(saveReview, in: app)
        XCTAssertTrue(saveReview.isEnabled)

        let edit = app.buttons["daytimeReview.morning.edit"]
        reveal(edit, in: app, towardTop: true)
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
        reveal(morning, in: app)
        XCTAssertTrue(morning.label.contains("7:15"), morning.label)
        XCTAssertTrue(morning.label.contains("Verified wake"), morning.label)
        reopenWithoutReusingAnswer(app)
    }

    func testMissingFollowingWakeBlocksBothAnswers() {
        let app = launch(scenario: "missingFollowing")
        openFromToday(app)
        expectStatus("Review unavailable", app: app)
        captureReview("missing-wake-blocker")
        let following = app.descendants(matching: .any).matching(identifier: "daytimeReview.following").firstMatch
        reveal(following, in: app)
        XCTAssertTrue(following.label.contains("Missing wake"))
        captureReview("missing-following-wake")
        XCTAssertFalse(app.buttons["daytimeReview.complete"].exists)
        XCTAssertFalse(app.buttons["daytimeReview.incomplete"].exists)
    }

    func testDuplicateMorningWakeExplainsBlockAndOffersAnotherDate() {
        let app = launch(scenario: "duplicateMorning")
        openFromToday(app)
        expectStatus("Review unavailable", app: app)
        let morning = app.descendants(matching: .any).matching(identifier: "daytimeReview.morning").firstMatch
        reveal(morning, in: app)
        XCTAssertTrue(morning.label.contains("More than one morning wake is recorded for this date."))
        XCTAssertTrue(morning.label.contains("Choose another date or review later."))
        XCTAssertFalse(app.buttons["daytimeReview.morning.edit"].exists)

        let chooseDate = app.buttons["Choose another date"]
        reveal(chooseDate, in: app)
        XCTAssertFalse(app.buttons["daytimeReview.save"].exists)
        chooseDate.tap()
        XCTAssertTrue(app.buttons["daytimeReview.select"].waitForExistence(timeout: 5))
    }

    func testHistoricalEntryShowsChronologicalNapsAndReachableActionsAtAccessibilitySize() {
        let app = launch(scenario: "withNaps", largeType: true)
        let day = app.buttons["sleep.dayRecords.0"]
        reveal(day, in: app)
        day.tap()
        openReviewLink(app)
        let first = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.0").firstMatch
        let second = app.descendants(matching: .any).matching(identifier: "daytimeReview.nap.1").firstMatch
        reveal(first, in: app)
        XCTAssertTrue(first.label.contains("9:00"))
        reveal(second, in: app)
        XCTAssertTrue(second.label.contains("12:00"))
        captureReview("recorded-naps-accessibility-xxxl")
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("You confirmed all naps were recorded", app: app)
        captureReview("confirmed-accessibility-xxxl")
        XCTAssertTrue(app.buttons["daytimeReview.later"].isHittable)
    }
}
