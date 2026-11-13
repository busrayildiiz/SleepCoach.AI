import XCTest

@MainActor
final class RecordingNavigationTests: XCTestCase {
    private let parentID = "11111111-1111-1111-1111-111111111111"

    private func launch(accessibilitySize: Bool = false, appearance: String = "light", referenceCapture: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RECORDING_UI_TESTS"] = "1"
        if referenceCapture { app.launchEnvironment["RECORDING_REFERENCE_SCREENSHOTS"] = "1" }
        app.launchArguments += ["-appAppearance", appearance]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                let form = app.collectionViews.containing(.any, identifier: element.identifier).firstMatch
                let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
                let window = app.windows.firstMatch.frame
                var viewport = (form.exists ? form.frame : (scroll.exists ? scroll.frame : window)).intersection(window)
                let addSleep = app.buttons["recording.addSleep"]
                if element.identifier.hasPrefix("sleep."), addSleep.exists, addSleep.isHittable {
                    // The custom tab bar overlays the dashboard scroll view. Its raised Add
                    // button marks a conservative, measured bottom edge for visible content.
                    viewport.size.height = max(0, min(viewport.maxY, addSleep.frame.minY) - viewport.minY)
                }
                // A partially visible button can be hittable while its tap center is offscreen.
                if !element.frame.isEmpty && viewport.contains(element.frame) { return }
            }
            app.swipeUp()
        }
        XCTFail("Could not fully reveal \(element.identifier) within eight scroll gestures.")
    }

    private func waitForDismissal(of navigationBar: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: navigationBar
        )
        let result = XCTWaiter.wait(for: [disappeared], timeout: 5)
        if result != .completed { print(XCUIApplication().debugDescription) }
        XCTAssertEqual(result, .completed,
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
        XCTAssertTrue(save.isEnabled, app.staticTexts["recording.validation"].exists
                      ? app.staticTexts["recording.validation"].label : "Save is disabled.")
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
        XCTAssertTrue(save.isEnabled, app.staticTexts["recording.validation"].exists
                      ? app.staticTexts["recording.validation"].label : "Save is disabled.")
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

    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testNativeTimeEditorCancelsWithoutChangesAndDoneAppliesSelection() throws {
        let app = launch()
        app.buttons["recording.addSleep"].tap()
        XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
        let start = app.buttons["recording.start.edit"]
        let original = try XCTUnwrap(start.value as? String)
        XCTAssertFalse(app.switches["recording.ongoing"].exists)
        app.buttons["recording.date.edit"].tap()
        XCTAssertTrue(app.datePickers["recording.start.date"].waitForExistence(timeout: 5))
        app.buttons["recording.time.cancel"].tap()
        waitForDismissal(of: app.navigationBars["Start time"])
        XCTAssertEqual(start.value as? String, original)
        start.tap()
        let picker = app.datePickers["recording.start.time"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.datePickers["recording.start.date"].exists)
        let minute = picker.pickerWheels.element(boundBy: 1)
        let previous = try XCTUnwrap(minute.value as? String)
        let replacement = previous.contains("15") ? "45" : "15"
        minute.adjust(toPickerWheelValue: replacement)
        capture("recording-native-time-editor", app: app)
        app.buttons["recording.time.cancel"].tap()
        waitForDismissal(of: app.navigationBars["Start time"])
        XCTAssertEqual(start.value as? String, original)

        start.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: replacement)
        app.buttons["recording.time.done"].tap()
        waitForDismissal(of: app.navigationBars["Start time"])
        XCTAssertNotEqual(start.value as? String, original)
        XCTAssertTrue(app.navigationBars["Add Nap"].exists)
    }

    func testOngoingNightHidesEndAndRemainsOngoingAfterSave() {
        let app = launch(accessibilitySize: true)
        app.buttons["recording.addSleep"].tap()
        app.buttons["recording.kind.night"].tap()
        XCTAssertTrue(app.navigationBars["Add Night Sleep"].waitForExistence(timeout: 5))
        let ongoing = app.switches["recording.ongoing"]
        reveal(ongoing, in: app)
        ongoing.tap()
        XCTAssertFalse(app.buttons["recording.end.edit"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["recording.ongoingNotice"].firstMatch.exists)
        capture("recording-night-accessibility-ongoing", app: app)
        reveal(ongoing, in: app)
        ongoing.tap()
        XCTAssertTrue(app.buttons["recording.end.edit"].exists)
        reveal(ongoing, in: app)
        ongoing.tap()
        let save = app.buttons["recording.save"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        waitForDismissal(of: app.navigationBars["Add Night Sleep"])
        XCTAssertTrue(app.buttons["sleep.current.addBreak"].waitForExistence(timeout: 5))
        let addBreak = app.buttons["sleep.current.addBreak"]
        reveal(addBreak, in: app)
        addBreak.tap()
        XCTAssertTrue(app.navigationBars["Add Awake Break"].waitForExistence(timeout: 5))
        capture("recording-awake-ongoing-accessibility", app: app)
        app.buttons["recording.cancel"].tap()
        waitForDismissal(of: app.navigationBars["Add Awake Break"])
        XCTAssertTrue(addBreak.waitForExistence(timeout: 5))
    }

    func testRecordingVisualReviewInLightAndDarkAppearance() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, referenceCapture: true)
            let day = app.buttons["sleep.dayRecords.1"]
            reveal(day, in: app)
            day.tap()
            let awake = app.buttons["sleep.addBreak.\(parentID)"]
            reveal(awake, in: app)
            awake.tap()
            XCTAssertTrue(app.navigationBars["Add Awake Break"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["recording.save"].isHittable)
            capture("recording-awake-\(appearance)", app: app)
            app.buttons["recording.parent"].tap()
            XCTAssertTrue(app.navigationBars["Sleep Session"].waitForExistence(timeout: 5))
            app.buttons["recording.parent.done"].tap()
            waitForDismissal(of: app.navigationBars["Sleep Session"])
            XCTAssertTrue(app.navigationBars["Add Awake Break"].exists)
            app.buttons["recording.cancel"].tap()
            waitForDismissal(of: app.navigationBars["Add Awake Break"])
            app.buttons["Done"].tap()
            waitForDismissal(of: awake)

            app.buttons["recording.addSleep"].tap()
            XCTAssertTrue(app.navigationBars["Add Nap"].waitForExistence(timeout: 5))
            capture("recording-nap-\(appearance)", app: app)
            app.buttons["recording.kind.night"].tap()
            XCTAssertTrue(app.navigationBars["Add Night Sleep"].waitForExistence(timeout: 5))
            capture("recording-night-\(appearance)", app: app)
            app.switches["recording.ongoing"].tap()
            capture("recording-night-ongoing-\(appearance)", app: app)
            app.buttons["recording.cancel"].tap()
            waitForDismissal(of: app.navigationBars["Add Night Sleep"])
            app.terminate()
        }
    }

}
