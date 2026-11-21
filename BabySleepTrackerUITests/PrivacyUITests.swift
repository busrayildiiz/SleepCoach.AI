import XCTest

@MainActor
final class PrivacyUITests: XCTestCase {
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

    func testDataHandlingExplanationIsReachableFromSettings() {
        let app = launchFixture()
        app.buttons["Settings"].tap()
        let button = app.buttons["privacy.dataHandling"]
        let scroll = app.scrollViews["settings.scroll"]
        for _ in 0..<8 {
            if button.exists && button.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["How Your Data Is Used"].waitForExistence(timeout: 5))
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
