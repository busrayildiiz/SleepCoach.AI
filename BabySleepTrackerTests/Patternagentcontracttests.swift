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
        sut = PatternAgent()
        calendar = Calendar(identifier: .gregorian)
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
        return Calendar(identifier: .gregorian).date(from: c)!
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

    func test_dataQuality_scalesWithTrackedDayCount() {
        func pattern(days: Int) -> BabyPattern {
            let records = (0..<days).map { nap($0, hour: 12, duration: 60) }
            return sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)
        }

        XCTAssertEqual(pattern(days: 2).dataQuality, .poor)
        XCTAssertEqual(pattern(days: 5).dataQuality, .fair)
        XCTAssertEqual(pattern(days: 10).dataQuality, .good)
        XCTAssertEqual(pattern(days: 15).dataQuality, .excellent)
    }

    func test_sampleSize_countsUnionOfSleepAndWakeDays_notDuplicates() {
        // 2 nap days + 2 additional wake-only days = 4 distinct tracked days,
        // not 4 nap records + 2 wake records counted separately.
        let records = [
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 60),
        ]
        let wakeRecords = [
            DailyWakeRecord(day: day(1, hour: 7), wakeTime: day(1, hour: 7)),  // same day as a nap
            DailyWakeRecord(day: day(2, hour: 7), wakeTime: day(2, hour: 7)),  // new day
            DailyWakeRecord(day: day(3, hour: 7), wakeTime: day(3, hour: 7)),  // new day
        ]

        let pattern = sut.analyze(records: records, wakeRecords: wakeRecords, ageMonths: 9, now: base)

        XCTAssertEqual(pattern.sampleSize, 4)
    }

    // MARK: - Average Nap Duration

    func test_averageNapDurationMinutes_isTheMeanOfAllNapDurations() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 90),
            nap(1, hour: 9,  duration: 120),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)

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

        let pattern = sut.analyze(records: [napRecord, breakRecord], wakeRecords: [], ageMonths: 9, now: base)

        // 90 minute nap minus a 20 minute break inside it = 70 effective minutes.
        XCTAssertEqual(pattern.averageNapDurationMinutes, 70)
    }

    // MARK: - Best Nap Hour

    func test_bestFirstNapHour_picksTheHourWithHighestAverageDuration() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(1, hour: 13, duration: 90),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)

        XCTAssertEqual(pattern.bestFirstNapHour, 13)
        // overall average is (60+90)/2 = 75; best hour's 90 is 15 above that.
        XCTAssertEqual(pattern.bestNapExtraMinutes, 15)
    }

    // MARK: - Nap Count Per Day

    func test_napCountPerDay_averagesAcrossDistinctDays() {
        let records = [
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 60), // day 0: 2 naps
            nap(1, hour: 9,  duration: 60), // day 1: 1 nap
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)

        XCTAssertEqual(pattern.napCountPerDay, 1.5)
    }

    // MARK: - Bedtime Shift

    func test_estimateBedtimeShift_comparesLongSleepDaysAgainstNormalDays() {
        // All naps are 60 min, so the "long day" threshold (avgNap + 30) is 90 min.
        let records = [
            // Day 0 (long day): two 60-min naps = 120 min > 90 → bedtime 20:30
            nap(0, hour: 9,  duration: 60),
            nap(0, hour: 13, duration: 60),
            night(0, hour: 20, minute: 30),

            // Day 1 (long day): two 60-min naps = 120 min > 90 → bedtime 20:00
            nap(1, hour: 9,  duration: 60),
            nap(1, hour: 13, duration: 60),
            night(1, hour: 20, minute: 0),

            // Day 2 (normal day): one 60-min nap = 60 min ≤ 90 → bedtime 19:00
            nap(2, hour: 9, duration: 60),
            night(2, hour: 19, minute: 0),

            // Day 3 (normal day): one 60-min nap = 60 min ≤ 90 → bedtime 19:30
            nap(3, hour: 9, duration: 60),
            night(3, hour: 19, minute: 30),
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)

        // longAvg = (20:30 + 20:00)/2 = 20:15 = 1215 min-of-day
        // normalAvg = (19:00 + 19:30)/2 = 19:15 = 1155 min-of-day
        // shift = max(0, 1215 - 1155) = 60
        XCTAssertEqual(pattern.estimatedBedtimeShiftMinutes, 60)
    }

    func test_estimateBedtimeShift_neverReturnsNegative() {
        // Long days end up with an EARLIER average bedtime than normal days —
        // the result must clamp to 0, not go negative.
        let records = [
            nap(0, hour: 9, duration: 60),
            nap(0, hour: 13, duration: 60),
            night(0, hour: 19, minute: 0), // long day, but earlier bedtime

            nap(1, hour: 9, duration: 60),
            night(1, hour: 20, minute: 0), // normal day, but later bedtime
        ]

        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)

        XCTAssertEqual(pattern.estimatedBedtimeShiftMinutes, 0)
    }

    // MARK: - Nap Duration Trend

    func test_napDurationTrend_increasing_whenRecentNapsAreMeaningfullyLonger() {
        let records = [
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 60),
            nap(2, hour: 12, duration: 60),
            nap(3, hour: 12, duration: 90),
            nap(4, hour: 12, duration: 90),
            nap(5, hour: 12, duration: 90),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)
        XCTAssertEqual(pattern.napDurationTrend, .increasing)
    }

    func test_napDurationTrend_decreasing_whenRecentNapsAreMeaningfullyShorter() {
        let records = [
            nap(0, hour: 12, duration: 90),
            nap(1, hour: 12, duration: 90),
            nap(2, hour: 12, duration: 90),
            nap(3, hour: 12, duration: 60),
            nap(4, hour: 12, duration: 60),
            nap(5, hour: 12, duration: 60),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)
        XCTAssertEqual(pattern.napDurationTrend, .decreasing)
    }

    func test_napDurationTrend_stable_whenChangeIsSmall() {
        let records = [
            nap(0, hour: 12, duration: 70),
            nap(1, hour: 12, duration: 70),
            nap(2, hour: 12, duration: 70),
            nap(3, hour: 12, duration: 75),
            nap(4, hour: 12, duration: 75),
            nap(5, hour: 12, duration: 75),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)
        XCTAssertEqual(pattern.napDurationTrend, .stable)
    }

    func test_napDurationTrend_insufficient_whenFewerThanFourDataPoints() {
        let records = [
            nap(0, hour: 12, duration: 60),
            nap(1, hour: 12, duration: 90),
            nap(2, hour: 12, duration: 120),
        ]
        let pattern = sut.analyze(records: records, wakeRecords: [], ageMonths: 9, now: base)
        XCTAssertEqual(pattern.napDurationTrend, .insufficient)
    }

    // MARK: - Week Over Week

    func test_weekOverWeekNapChange_comparesLastSevenDaysAgainstThePriorSeven() {
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

        XCTAssertEqual(pattern.weekOverWeekNapChange, 30) // 90 - 60
    }
}
