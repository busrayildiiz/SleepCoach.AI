import XCTest

@MainActor
final class PrivacyUITests: XCTestCase {
    /// CI runs this first so a shared startup crash stops the job before dozens
    /// of unrelated UI cases each spend time waiting for the same missing app.
    func testLaunchShowsHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        addTeardownBlock {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "STARTUP-TEST-ONLY-home"
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.buttons["recording.addSleep"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recording.addSleep"].isHittable)
        XCTAssertFalse(app.otherElements["protectedDataUnavailable"].exists)
    }

    private func launchFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["recording.addSleep"].waitForExistence(timeout: 5))
        return app
    }

    private func openDeletion(in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        let scroll = app.scrollViews["settings.scroll"]
        let button = app.buttons["deleteAllLocalData"]
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.buttons["privacy.delete.confirm"].waitForExistence(timeout: 3))
    }

    func testRecordingEditorReturnsToHistoryTab() {
        let app = launchFixture()
        let weekRange = app.buttons["Week"]
        XCTAssertFalse(weekRange.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["privacy.dataHandling"].exists, app.debugDescription)

        app.buttons["History"].tap()
        XCTAssertTrue(weekRange.waitForExistence(timeout: 5))
        XCTAssertTrue(weekRange.isHittable, app.debugDescription)

        app.buttons["recording.addSleep"].tap()
        let editor = app.navigationBars["Add Nap"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        let editorDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [editorDismissed], timeout: 5), .completed)

        let weekView = app.staticTexts["Week view coming soon"]
        XCTAssertFalse(weekView.exists)
        XCTAssertTrue(weekRange.isHittable)
        weekRange.tap()
        XCTAssertTrue(weekView.waitForExistence(timeout: 5))
        XCTAssertTrue(weekView.isHittable)

        app.buttons["Home"].tap()
        XCTAssertFalse(weekRange.exists, app.debugDescription)
        app.buttons["History"].tap()
        XCTAssertTrue(weekView.waitForExistence(timeout: 5))
        XCTAssertTrue(weekView.isHittable)

        // Check the top content and bottom tab bar on both simulator sizes.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "history-tab-after-recording-dismissal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testBackgroundRoundTripRestoresUsablePrivateScreens() {
        let app = launchFixture()
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let addSleep = app.buttons["recording.addSleep"]
        XCTAssertTrue(addSleep.waitForExistence(timeout: 5))
        XCTAssertTrue(addSleep.isHittable)
        XCTAssertFalse(app.otherElements["privacy.windowCover"].exists)
        addSleep.tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        XCTAssertTrue(addSleep.waitForExistence(timeout: 5))
    }

    func testDataHandlingExplanationIsReachableFromSettings() {
        let app = launchFixture()
        app.buttons["Settings"].tap()
        let button = app.buttons["privacy.dataHandling"]
        let scroll = app.scrollViews["settings.scroll"]
        XCTAssertTrue(scroll.exists, app.debugDescription)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, app.buttons["recording.addSleep"].frame.minY,
                                 app.debugDescription)
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["How Your Data Is Used"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["On this device"].exists)
        XCTAssertTrue(app.staticTexts["App preferences"].exists)
        XCTAssertFalse(app.staticTexts["3 members"].exists)
        app.buttons["privacy.dataHandling.done"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 3))
    }

    func testCancellingDeletionKeepsExistingRecords() {
        let app = launchFixture()
        openDeletion(in: app)
        app.buttons["Cancel"].tap()
        app.buttons["Home"].tap()
        let recordedDay = app.buttons["sleep.dayRecords.0"]
        for _ in 0..<8 {
            if recordedDay.exists && recordedDay.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(recordedDay.isHittable)
        recordedDay.tap()
        XCTAssertTrue(app.buttons["sleep.addBreak.11111111-1111-1111-1111-111111111111"]
            .waitForExistence(timeout: 5))
    }

    func testDeletionReturnsToLocalSetupAndRemainsDeletedAfterRelaunch() {
        let app = launchFixture()
        openDeletion(in: app)
        app.buttons["privacy.delete.confirm"].tap()
        XCTAssertTrue(app.buttons["profile.create"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recording.addSleep"].exists)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RECORDING_UI_TESTS")
        // Legacy routing flags alone must never reopen a deleted/absent profile.
        app.launchArguments += ["-authComplete", "YES", "-onboardingComplete", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["profile.create"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recording.addSleep"].exists)
        XCTAssertFalse(app.buttons["Continue with Apple"].exists)
        XCTAssertFalse(app.buttons["Continue with Google"].exists)

        app.buttons["profile.create"].tap()
        XCTAssertTrue(app.textFields["Your Name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Email"].exists)
        XCTAssertFalse(app.secureTextFields["Password"].exists)
    }
}
