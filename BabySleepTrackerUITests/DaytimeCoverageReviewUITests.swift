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
                        requireHittable: Bool = true) {
        for _ in 0..<12 {
            let window = app.windows.firstMatch.frame
            let tab = app.buttons["recording.addSleep"]
            let bottom = tab.isHittable ? tab.frame.minY : window.maxY
            let viewport = CGRect(x: window.minX + 6, y: window.minY + 55, width: window.width - 12,
                                  height: max(1, bottom - window.minY - 65))
            if element.exists, !requireHittable || element.isHittable,
               viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                return
            }
            let distance = element.exists && !element.frame.isEmpty ? element.frame.midY - viewport.midY :
                (towardTop ? -viewport.height : viewport.height)
            let step = min(max(30, abs(distance)), viewport.height * 0.4)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(CGVector(dx: 0, dy: distance < 0 ? step : -step))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Review control was unreachable: \(element)\n\(app.debugDescription)")
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
        reveal(status, in: app, towardTop: true)
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
        app.buttons["daytimeReview.later"].tap()

        openReviewLink(app)
        expectStatus("Awaiting review", app: app)
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Zero naps confirmed", app: app)

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
        XCTAssertTrue(saveNap.isEnabled)
        saveNap.tap()
        XCTAssertTrue(app.navigationBars["Daytime recording"].waitForExistence(timeout: 5))
        expectStatus("Needs review again", app: app)
        XCTAssertEqual(app.staticTexts["daytimeReview.day"].label, day)
        let reopen = app.buttons["daytimeReview.reopen"]
        reveal(reopen, in: app)
        reopen.tap()
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Nap recording confirmed", app: app)
    }

    func testMissingFollowingWakeBlocksBothAnswers() {
        let app = launch(scenario: "missingFollowing")
        openFromToday(app)
        expectStatus("Review unavailable", app: app)
        let following = app.descendants(matching: .any).matching(identifier: "daytimeReview.following").firstMatch
        reveal(following, in: app)
        XCTAssertTrue(following.label.contains("Missing wake"))
        XCTAssertFalse(app.buttons["daytimeReview.complete"].exists)
        XCTAssertFalse(app.buttons["daytimeReview.incomplete"].exists)
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
        chooseAndSave("daytimeReview.complete", app: app)
        expectStatus("Nap recording confirmed", app: app)
        XCTAssertTrue(app.buttons["daytimeReview.later"].isHittable)
    }
}
