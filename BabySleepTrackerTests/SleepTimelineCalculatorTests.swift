import XCTest
@testable import BabySleepTracker

final class SleepTimelineCalculatorTests: XCTestCase {

    func testTimelineUsesNapRecordsAndIgnoresNightAndBreakSegments() {
        let nap = SleepRecord(date: Date(timeIntervalSince1970: 1_000), duration: 60, kind: .dayNap)
        let night = SleepRecord(date: Date(timeIntervalSince1970: 2_000), duration: 480, kind: .nightSleep)
        let breakRecord = SleepRecord(date: Date(timeIntervalSince1970: 1_010), duration: 10, kind: .break, parentNapID: nap.id)
        let calculator = SleepTimelineCalculator(records: [nap, night, breakRecord], wakeRecord: nil, snapshot: nil, defaultWakeTime: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 5_000), profileProvider: DefaultAgeBasedSleepProfileProvider())

        let items = calculator.calculate()

        XCTAssertEqual(items[1].kind, .nap(index: 1))
        XCTAssertEqual(items[1].durationMinutes, 50)
        XCTAssertFalse(items.contains { $0.kind == .bedtime && $0.durationMinutes != nil })
    }

    func testTimelineMarksCompletedActiveAndUpcomingNaps() {
        let completed = SleepRecord(date: Date(timeIntervalSince1970: 100), duration: 20)
        let active = SleepRecord(date: Date(timeIntervalSince1970: 1_000), duration: 60, isOngoing: true)
        let upcoming = SleepRecord(date: Date(timeIntervalSince1970: 2_000), duration: 30)
        let calculator = SleepTimelineCalculator(records: [completed, active, upcoming], wakeRecord: nil, snapshot: nil, defaultWakeTime: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1_020), profileProvider: DefaultAgeBasedSleepProfileProvider())

        let items = calculator.calculate()

        XCTAssertEqual(items[1].visualState, .completed)
        XCTAssertEqual(items[2].visualState, .active)
        XCTAssertEqual(items[3].visualState, .upcoming)
    }

    func testTimelineFallsBackToPredictedNapsAndBedtimeWithoutPredictionData() {
        let nap = SleepRecord(date: Date(timeIntervalSince1970: 1_000), duration: 60)
        let calculator = SleepTimelineCalculator(records: [nap], wakeRecord: nil, snapshot: nil, defaultWakeTime: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1_100), profileProvider: DefaultAgeBasedSleepProfileProvider())

        let items = calculator.calculate()

        XCTAssertTrue(items.contains { $0.kind == .nap(index: 2) })
        XCTAssertTrue(items.contains { $0.kind == .bedtime })
    }
}
