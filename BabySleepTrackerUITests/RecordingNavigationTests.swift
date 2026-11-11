import XCTest

@MainActor
final class RecordingNavigationTests: XCTestCase {
    private let parentID = "11111111-1111-1111-1111-111111111111"

    private func launch(accessibilitySize: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func waitForDismissal(of navigationBar: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: navigationBar
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed,
                       "Recording sheet did not close within 5 seconds.", file: file, line: line)
    }

    func testAddNapCancelThenSaveDismissesAndPersists() {
        let app = launch()
        app.buttons["recording.addSleep"].tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
        app.buttons["recording.cancel"].tap()
        waitForDismissal(of: app.navigationBars["Add Nap"])
        app.buttons["recording.addSleep"].tap()
        let save = app.buttons["recording.save"]
        reveal(save, in: app)
        save.tap()
        waitForDismissal(of: app.navigationBars["Add Nap"])
        XCTAssertTrue(app.buttons["recording.addSleep"].waitForExistence(timeout: 5))
        let day = app.buttons["sleep.dayRecords.0"]
        reveal(day, in: app)
        day.tap()
        let savedNap = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@",
            "sleep.addBreak.", "sleep.addBreak.\(parentID)"
        )).firstMatch
        reveal(savedNap, in: app)
    }

    func testAddAwakeBreakFromRecordDoesNotOpenEditorAndRefreshesNetSleep() {
        let app = launch(accessibilitySize: true)
        let day = app.buttons["sleep.dayRecords.0"]
        reveal(day, in: app)
        day.tap()
        let addBreak = app.buttons["sleep.addBreak.\(parentID)"]
        reveal(addBreak, in: app)
        addBreak.tap()
        XCTAssertTrue(app.navigationBars["Add Awake Break"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Nap"].exists)
        app.buttons["recording.cancel"].tap()
        waitForDismissal(of: app.navigationBars["Add Awake Break"])
        XCTAssertTrue(addBreak.waitForExistence(timeout: 5))
        addBreak.tap()
        let save = app.buttons["recording.save"]
        reveal(save, in: app)
        save.tap()
        waitForDismissal(of: app.navigationBars["Add Awake Break"])
        let netSleep = app.staticTexts["sleep.netSleep.\(parentID)"]
        XCTAssertTrue(netSleep.waitForExistence(timeout: 5))
        XCTAssertEqual(netSleep.label, "55m")
        // Reopening the same interval must disable save instead of creating a duplicate.
        reveal(addBreak, in: app)
        addBreak.tap()
        reveal(save, in: app)
        XCTAssertFalse(save.isEnabled)
    }
}
