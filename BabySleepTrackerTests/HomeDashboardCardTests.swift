import XCTest
@testable import BabySleepTracker

final class HomeDashboardCardTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let now = Date(timeIntervalSince1970: 1_800_036_000)
    func testUnverifiedEstimateIsNeutralWithoutFabricatedValues() {
        let state = HomeSleepCardPresentation.make(records: [], now: now, calendar: calendar,
            estimate: .init(kind: .nightSleep, start: now.addingTimeInterval(-3600), wake: now.addingTimeInterval(3600)))
        XCTAssertEqual(state.status, .missing)
        XCTAssertNil(state.start)
        XCTAssertNil(state.elapsedMinutes)
        XCTAssertNil(state.expectedWake)
        XCTAssertNil(state.progress)
        XCTAssertEqual(state.title, "Ready to record")
    }
    func testConfirmedNightHasObservedElapsedWithoutInventedWakeOrProgress() {
        let record = SleepRecord(date: now.addingTimeInterval(-8340), duration: 0, kind: .nightSleep, isOngoing: true)
        let state = HomeSleepCardPresentation.make(records: [record], now: now, calendar: calendar)
        XCTAssertEqual(state.section, "LIVE NIGHT SLEEP")
        XCTAssertEqual(state.elapsedMinutes, 139)
        XCTAssertEqual(state.durationLabel, "elapsed")
        XCTAssertNil(state.expectedWake)
        XCTAssertNil(state.progress)
        XCTAssertTrue(state.accessibility(now: now, calendar: calendar).contains("not estimated"))
    }
    func testNapSequenceUsesValidSameSleepDayRecordsNotClockOrDuplicates() {
        let start = calendar.startOfDay(for: now).addingTimeInterval(20 * 3600)
        let preceding = (1...3).map { SleepRecord(date: start.addingTimeInterval(Double(-$0 * 3600)), duration: 20) }
        let active = SleepRecord(date: start, duration: 0, isOngoing: true)
        let invalid = SleepRecord(date: start.addingTimeInterval(-1000), duration: 0)
        let previousDay = SleepRecord(date: start.addingTimeInterval(-86400), duration: 30)
        let state = HomeSleepCardPresentation.make(records: preceding + [preceding[0], active, invalid, previousDay], now: start.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(state.napNumber, 4)
        XCTAssertEqual(state.section, "LIVE NAP 4")
        XCTAssertEqual(state.kind, .dayNap)
    }
    func testVerifiedEstimateUpdatesLabelsTimesAndRingTogether() {
        let start = now.addingTimeInterval(-1800), wake = now.addingTimeInterval(3600)
        let state = HomeSleepCardPresentation.make(records: [], now: now, calendar: calendar,
            estimate: .init(kind: .dayNap, start: start, wake: wake), eligibilityVerified: true)
        XCTAssertEqual(state.section, "LIKELY FIRST NAP")
        XCTAssertEqual(state.title, "Likely sleeping")
        XCTAssertEqual(state.start, start)
        XCTAssertEqual(state.elapsedMinutes, 30)
        XCTAssertEqual(state.expectedWake, wake)
        XCTAssertEqual(state.progress!, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(state.durationLabel, "estimated")
        XCTAssertFalse(state.accessibility(now: now, calendar: calendar).contains("asleep"))
    }
    func testSecondNapAndLikelyNightClassification() {
        let reference = calendar.startOfDay(for: now).addingTimeInterval(18 * 3600)
        let first = SleepRecord(date: reference.addingTimeInterval(-7200), duration: 30)
        for (kind, section) in [(SleepKind.dayNap, "LIKELY SECOND NAP"), (.nightSleep, "LIKELY NIGHT SLEEP")] {
            let state = HomeSleepCardPresentation.make(records: [first], now: reference, calendar: calendar,
                estimate: .init(kind: kind, start: reference.addingTimeInterval(-600), wake: reference.addingTimeInterval(600)), eligibilityVerified: true)
            XCTAssertEqual(state.section, section)
        }
    }
    func testInvalidEstimatesAndFutureRecordsAreMissing() {
        let future = SleepRecord(date: now.addingTimeInterval(60), duration: 0, isOngoing: true)
        let completed = SleepRecord(date: now.addingTimeInterval(-3600), duration: 30)
        let state = HomeSleepCardPresentation.make(records: [future, completed], now: now, calendar: calendar,
            estimate: .init(kind: .nightSleep, start: now.addingTimeInterval(-120), wake: now), eligibilityVerified: true)
        XCTAssertEqual(state.status, .missing)
        XCTAssertEqual(HomeSleepCardPresentation.session(record: completed, records: [], now: now, calendar: calendar).status, .completed)
    }
    func testMidnightKeepsStartDaySequenceAndExplicitDate() {
        let midnight = calendar.startOfDay(for: now)
        let first = SleepRecord(date: midnight.addingTimeInterval(-7200), duration: 30)
        let active = SleepRecord(date: midnight.addingTimeInterval(-600), duration: 0, isOngoing: true)
        let state = HomeSleepCardPresentation.make(records: [first, active], now: midnight.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(state.napNumber, 2)
        XCTAssertEqual(state.elapsedMinutes, 20)
        XCTAssertEqual(state.time(active.date, relativeTo: midnight, calendar: calendar), active.date.formatted(date: .abbreviated, time: .shortened))
    }
    func testWakeSaveFailureSuccessAndNextDay() {
        let record = DailyWakeRecord(day: now, wakeTime: now)
        var state = HomeWakeCardState(records: [])
        for success in [false, true] {
            state.accept(.init(updatedWakeRecords: [record], updatedSleepRecords: [], normalizedWakeTime: now,
                closedNightRecord: nil, wakePersistenceSucceeded: success, sleepPersistenceSucceeded: false))
            XCTAssertEqual(state.isVisible(now: now, calendar: calendar), !success)
        }
        XCTAssertTrue(state.isVisible(now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar))
    }
    func testPersistenceReloadAndDeletion() {
        let name = "HomeDashboardCardTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = DailyWakeRecordPersistence(defaults: defaults)
        XCTAssertTrue(persistence.save([DailyWakeRecord(day: now, wakeTime: now)]))
        XCTAssertFalse(HomeWakeCardState(records: persistence.load() ?? []).isVisible(now: now, calendar: calendar))
        XCTAssertTrue(persistence.save([]))
        XCTAssertTrue(HomeWakeCardState(records: persistence.load() ?? []).isVisible(now: now, calendar: calendar))
    }
}
