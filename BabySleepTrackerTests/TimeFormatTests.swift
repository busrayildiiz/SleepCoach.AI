
import XCTest
@testable import BabySleepTracker

final class TimeFormatTests: XCTestCase {

    // MARK: - minutes

    func testMinutesReturnsMinutesOnlyWhenLessThanOneHour() {
        XCTAssertEqual(
            TimeFormat.minutes(45),
            "45m"
        )
    }

    func testMinutesReturnsHoursOnlyForExactHour() {
        XCTAssertEqual(
            TimeFormat.minutes(120),
            "2h"
        )
    }

    func testMinutesReturnsHoursAndMinutes() {
        XCTAssertEqual(
            TimeFormat.minutes(125),
            "2h 5m"
        )
    }

    func testMinutesReturnsZeroMinutes() {
        XCTAssertEqual(
            TimeFormat.minutes(0),
            "0m"
        )
    }

    func testMinutesHandlesSingleMinute() {
        XCTAssertEqual(
            TimeFormat.minutes(1),
            "1m"
        )
    }

    func testMinutesHandlesNegativeValuesAccordingToCurrentBehavior() {
        XCTAssertEqual(
            TimeFormat.minutes(-5),
            "-5m"
        )
    }

    // MARK: - ampm

    func testAmpmFormatsMorningTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let components = DateComponents(
            calendar: calendar,
            year: 2026,
            month: 8,
            day: 16,
            hour: 9,
            minute: 30
        )

        let date = calendar.date(from: components)!

        XCTAssertEqual(
            TimeFormat.ampm(date),
            "9:30 AM"
        )
    }
    
    func testAmpmFormatsAfternoonTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let components = DateComponents(
            calendar: calendar,
            year: 2026,
            month: 8,
            day: 16,
            hour: 14,
            minute: 5
        )

        let date = calendar.date(from: components)!

        XCTAssertEqual(
            TimeFormat.ampm(date),
            "2:05 PM"
        )
    }
    func testAmpmFormatsMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let components = DateComponents(
            calendar: calendar,
            year: 2026,
            month: 8,
            day: 16,
            hour: 0,
            minute: 0
        )

        let date = calendar.date(from: components)!

        XCTAssertEqual(
            TimeFormat.ampm(date),
            "12:00 AM"
        )
    }
    func testAmpmFormatsNoon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let components = DateComponents(
            calendar: calendar,
            year: 2026,
            month: 8,
            day: 16,
            hour: 12,
            minute: 0
        )

        let date = calendar.date(from: components)!

        XCTAssertEqual(
            TimeFormat.ampm(date),
            "12:00 PM"
        )
    }
}
