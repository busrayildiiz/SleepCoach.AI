//
//  PatternAgentContractTests.swift
//  BabySleepTrackerTests
//
//  PatternAgent is pure, deterministic math over sleep history — no LLM
//  involvement — so every output here has one correct answer for a given
//  input. These are contract tests: fixed inputs, exact expected outputs.
//

import Foundation
import XCTest

@testable import BabySleepTracker

final class PatternAgentContractTests: XCTestCase {

    var sut: PatternAgent!
    var calendar: Calendar!
    private var base: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        sut = PatternAgent(calendar: calendar)
        base = date(2026, 1, 1, 0, 0)
    }

    override func tearDown() {
        sut = nil
        calendar = nil
        base = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return calendar.date(from: c)!
    }

    private func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
        let d = calendar.date(byAdding: .day, value: offset, to: base)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
    }

    private func nap(_ offset: Int, hour: Int, minute: Int = 0, duration: Int) -> SleepRecord {
        SleepRecord(date: day(offset, hour: hour, minute: minute), duration: duration, kind: .dayNap)
    }

    private func night(_ offset: Int, hour: Int, minute: Int = 0, duration: Int = 600) -> SleepRecord {
        SleepRecord(date: day(offset, hour: hour, minute: minute), duration: duration, kind: .nightSleep)
    }

    // MARK: - Data Quality

    func test_frequentRecordingDoesNotProveCoverageOrSupplyPersonalizedPatterns() {
        let now = day(30, hour: 12)
        for days in [2, 5, 10, 15] {
            let records = (0..<days).map { nap($0, hour: 12, duration: 60) }
            let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: now)
            let accounting = SleepAccounting(records: records, now: now, calendar: calendar)

            XCTAssertEqual(pattern.sampleSize, days)
            XCTAssertEqual(pattern.averageNapDurationMinutes, 60)
            XCTAssertEqual(pattern.dataQuality, .poor)
            XCTAssertEqual(accounting.completedSubtotal(on: day(days - 1, hour: 12)), .incomplete(60, reason: .incomplete))
            XCTAssertNil(pattern.bestFirstNapHour)
            XCTAssertNil(pattern.napCountPerDay)
            XCTAssertEqual(pattern.wakingWindowTrend, .insufficient)
            XCTAssertEqual(pattern.napDurationTrend, .insufficient)
        }
    }

    func test_sampleSize_countsDaysWithMeasurableSleepSessions() {
        let records = [
            nap(0, hour: 9, duration: 60),
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 60),
            SleepRecord(date: day(2, hour: 11), duration: 0, isOngoing: true)
        ]
        let wakeRecords = [
            DailyWakeRecord(day: day(1, hour: 7), wakeTime: day(1, hour: 7)),  // same day as a nap
            DailyWakeRecord(day: day(2, hour: 7), wakeTime: day(2, hour: 7)),  // new day
            DailyWakeRecord(day: day(3, hour: 7), wakeTime: day(3, hour: 7)),  // new day
        ]

        let pattern = sut.analyze(records: records, wakeRecords: wakeRecords, ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.sampleSize, 2)
        XCTAssertEqual(pattern.averageNapDurationMinutes, 60)
    }

    // MARK: - Average Nap Duration

    func test_averageNapDurationMinutes_isTheMeanOfAllNapDurations() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 90),
            nap(1, hour: 9,  duration: 120),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.averageNapDurationMinutes, 90) // (60+90+120)/3
    }

    func test_averageNapDurationMinutes_subtractsBreaksFromTotal() {
        let napRecord = nap(0, hour: 9, duration: 90)
        let breakRecord = SleepRecord(
            date: day(0, hour: 9, minute: 30),
            duration: 20,
            kind: .break,
            parentNapID: napRecord.id
        )

        let pattern = sut.analyze(records: [napRecord, breakRecord], wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        // 90 minute nap minus a 20 minute break inside it = 70 effective minutes.
        XCTAssertEqual(pattern.averageNapDurationMinutes, 70)
    }

    // MARK: - Best Nap Hour

    func test_measuredNapAverageDoesNotRecommendABestFirstNapHour() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(1, hour: 13, duration: 90),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.averageNapDurationMinutes, 75)
        XCTAssertNil(pattern.bestFirstNapHour)
        XCTAssertNil(pattern.bestNapExtraMinutes)
    }

    // MARK: - Nap Count Per Day

    func test_napCountPerDay_isUnknownWithUnconfirmedDayCoverage() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 60), // day 0: 2 naps
            nap(1, hour: 9,  duration: 60), // day 1: 1 nap
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.sampleSize, 2)
        XCTAssertEqual(pattern.averageNapDurationMinutes, 60)
        XCTAssertNil(pattern.napCountPerDay)
    }

    // MARK: - Bedtime Shift

    func test_moreRecordedNapMinutesDoNotProveLaterBedtimes() {
        let records = [
            // Day 0 has two recorded naps and a 20:30 night start.
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 60),
            night(0, hour: 20, minute: 30),

            // Day 1 has two recorded naps and a 20:00 night start.
            nap(1, hour: 9,  duration: 60),
            nap(1, hour: 13, duration: 60),
            night(1, hour: 20, minute: 0),

            // Days 2 and 3 each have one recorded nap and earlier night starts.
            nap(2, hour: 9, duration: 60),
            night(2, hour: 19, minute: 0),

            nap(3, hour: 9, duration: 60),
            night(3, hour: 19, minute: 30),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.averageNightSleepMinutes, 600)
        XCTAssertEqual(pattern.sampleSize, 4)
        XCTAssertNil(pattern.estimatedBedtimeShiftMinutes)
    }

    func test_earlierRecordedNightStartDoesNotProveZeroBedtimeShift() {
        let records = [
            nap(0, hour: 9, duration: 60),
            nap(0, hour: 13, duration: 60),
            night(0, hour: 19, minute: 0),

            nap(1, hour: 9, duration: 60),
            night(1, hour: 20, minute: 0),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))

        XCTAssertEqual(pattern.averageNightSleepMinutes, 600)
        XCTAssertNil(pattern.estimatedBedtimeShiftMinutes)
    }

    // MARK: - Nap Duration Trend

    func test_longerRecentRecordedNapsDoNotProveAnIncreasingTrend() {
        let records = [
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 60),
            nap(2, hour: 12, duration: 60),
            nap(3, hour: 12, duration: 90),
            nap(4, hour: 12, duration: 90),
            nap(5, hour: 12, duration: 90),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))
        XCTAssertEqual(pattern.averageNapDurationMinutes, 75)
        XCTAssertEqual(pattern.napDurationTrend, .insufficient)
    }

    func test_shorterRecentRecordedNapsDoNotProveADecreasingTrend() {
        let records = [
            nap(0, hour: 12, duration: 90),
            nap(1, hour: 12, duration: 90),
            nap(2, hour: 12, duration: 90),
            nap(3, hour: 12, duration: 60),
            nap(4, hour: 12, duration: 60),
            nap(5, hour: 12, duration: 60),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))
        XCTAssertEqual(pattern.averageNapDurationMinutes, 75)
        XCTAssertEqual(pattern.napDurationTrend, .insufficient)
    }

    func test_similarRecordedNapsDoNotProveAStableTrend() {
        let records = [
            nap(0, hour: 12, duration: 70),
            nap(1, hour: 12, duration: 70),
            nap(2, hour: 12, duration: 70),
            nap(3, hour: 12, duration: 75),
            nap(4, hour: 12, duration: 75),
            nap(5, hour: 12, duration: 75),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))
        XCTAssertEqual(pattern.averageNapDurationMinutes, 72)
        XCTAssertEqual(pattern.napDurationTrend, .insufficient)
    }

    func test_napDurationTrend_insufficient_whenFewerThanFourDataPoints() {
        let records = [
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 90),
            nap(2, hour: 12, duration: 120),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: day(30, hour: 12))
        XCTAssertEqual(pattern.napDurationTrend, .insufficient)
    }

    // MARK: - Week Over Week

    func test_weekOverWeekChangeIsUnknownWithPartialRecordingInBothWeeks() {
        let now = day(20, hour: 12) // fixed reference point past all sample data

        var records: [SleepRecord] = []
        // "This week" (now-7 ..< now): 3 naps of 90 min, days 14-16
        for offset in [14, 15, 16] {
            records.append(nap(offset, hour: 12, duration: 90))
        }
        // "Last week" (now-14 ..< now-7): 3 naps of 60 min, days 7-9
        for offset in [7, 8, 9] {
            records.append(nap(offset, hour: 12, duration: 60))
        }

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: now)

        XCTAssertEqual(pattern.sampleSize, 6)
        XCTAssertEqual(pattern.averageNapDurationMinutes, 75)
        XCTAssertNil(pattern.weekOverWeekNapChange)
    }
}
