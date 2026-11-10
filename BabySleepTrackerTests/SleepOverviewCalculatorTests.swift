import XCTest
@testable import BabySleepTracker

final class SleepOverviewCalculatorTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
    }

    func testTotalsIncludeSleepAndSubtractOnlyParentBreaks() {
        let nap = record(dayOffset: 0, hour: 8, duration: 60, kind: .dayNap)
        let otherNap = record(dayOffset: 0, hour: 12, duration: 30, kind: .dayNap)
        let parentBreak = SleepRecord(date: nap.date.addingTimeInterval(600), duration: 10, kind: .break, parentNapID: nap.id)
        let otherNapBreak = SleepRecord(date: otherNap.date.addingTimeInterval(600), duration: 20, kind: .break, parentNapID: otherNap.id)
        let night = record(dayOffset: 0, hour: 22, duration: 480, kind: .nightSleep)

        let metrics = calculate([nap, otherNap, parentBreak, otherNapBreak, night])

        // The second nap starts at now and the night starts in the future.
        XCTAssertEqual(metrics.todayTotal, 60 - 10)
    }

    func testYesterdayTotalIncludesOnlyYesterdayRecord() {
        let today = record(dayOffset: 0, duration: 30)
        let yesterday = record(dayOffset: -1, duration: 60)
        let twoDaysAgo = record(dayOffset: -2, duration: 90)

        let metrics = calculate([today, yesterday, twoDaysAgo])

        XCTAssertEqual(metrics.yesterdayTotal, yesterday.duration)
    }

    func testSevenDayAveragesUseExpectedRangesAndIntegerTruncation() {
        let records = [
            record(dayOffset: 0, duration: 61),
            record(dayOffset: -1, duration: 60),
            record(dayOffset: -7, duration: 100),
            record(dayOffset: -8, duration: 101)
        ]

        let metrics = calculate(records)

        XCTAssertEqual(metrics.last7DaysAverage, 121 / 7)
        XCTAssertEqual(metrics.previous7DaysAverage, 201 / 7)
        XCTAssertEqual(metrics.todayDelta, 1)
    }

    func testAverageNapUsesNewestFirstDropFirstAndFallbacks() {
        let newest = record(dayOffset: 0, hour: 10, duration: 100)
        let older = record(dayOffset: 0, hour: 8, duration: 60)
        let oldest = record(dayOffset: -1, hour: 8, duration: 80)

        let metrics = calculate([older, newest, oldest])

        XCTAssertEqual(metrics.averageNapMinutes, (80 + 60) / 2)
        XCTAssertEqual(metrics.latestNapDelta, 100 - 70)

        let empty = calculate([])
        XCTAssertEqual(empty.averageNapMinutes, 80)
        XCTAssertEqual(empty.latestNapDelta, 95 - 80)
    }

    func testConsistencyUsesOnlyNonZeroDaysAndFallbacks() {
        let empty = calculate([])
        XCTAssertEqual(empty.consistencyPercent, 87)

        let oneDay = calculate([record(dayOffset: 0, duration: 60)])
        XCTAssertEqual(oneDay.consistencyPercent, 74)

        let varied = calculate([
            record(dayOffset: 0, duration: 1),
            record(dayOffset: -1, duration: 10_000)
        ])
        XCTAssertEqual(varied.consistencyPercent, 55)
    }

    func testTodayNapCountAndGoalProgressUseCurrentDayOnly() {
        let nap = record(dayOffset: 0, duration: 60, kind: .dayNap)
        let ongoingNap = record(dayOffset: 0, hour: 10, duration: 60, kind: .dayNap, isOngoing: true)
        let night = record(dayOffset: 0, hour: 22, duration: 480, kind: .nightSleep)
        let yesterdayNap = record(dayOffset: -1, duration: 120, kind: .dayNap)

        let metrics = calculate([nap, ongoingNap, night, yesterdayNap])

        XCTAssertEqual(metrics.todayNapCount, 2)
        XCTAssertEqual(metrics.todayGoalProgress, min(Double(metrics.rolling24hMinutes) / 660.0, 1.0))
    }

    private func calculate(_ records: [SleepRecord]) -> SleepOverviewMetrics {
        SleepOverviewCalculator(records: records, now: now, calendar: calendar, totalSleepReference: 660...840).calculate()
    }

    private func record(dayOffset: Int, hour: Int = 8, duration: Int, kind: SleepKind = .dayNap, isOngoing: Bool = false) -> SleepRecord {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return SleepRecord(date: date, duration: duration, kind: kind, isOngoing: isOngoing)
    }
}

/// Fixed clocks and explicit timezones; no simulator/device clock dependency.
final class SleepAccountingRegressionTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func sleep(_ start: String, _ end: String?, kind: SleepKind = .nightSleep) -> SleepRecord {
        let startDate = date(start)
        let endDate = end.map(date)
        return SleepRecord(date: startDate, duration: endDate.map { Int($0.timeIntervalSince(startDate) / 60) } ?? 0,
                           kind: kind, isOngoing: end == nil, createdAt: startDate, endDate: endDate)
    }
    private func awake(_ start: String, _ end: String, parent: SleepRecord) -> SleepRecord {
        let startDate = date(start), endDate = date(end)
        return SleepRecord(date: startDate, duration: Int(endDate.timeIntervalSince(startDate) / 60),
                           kind: .break, parentNapID: parent.id, createdAt: startDate, endDate: endDate)
    }
    private func accounting(_ records: [SleepRecord], now: String = "2026-09-02T12:00:00Z", zone: String = "UTC") -> SleepAccounting {
        SleepAccounting(records: records, now: date(now), calendar: calendar(zone))
    }

    func testMidnightNightBelongsToStartDayWithItsNapsAndFollowingMorningBreak() {
        let nap = sleep("2026-09-01T13:00:00Z", "2026-09-01T14:30:00Z", kind: .dayNap)
        let night = sleep("2026-09-01T20:00:00Z", "2026-09-02T07:00:00Z")
        let wake = awake("2026-09-02T02:00:00Z", "2026-09-02T02:30:00Z", parent: night)
        let sut = accounting([nap, night, wake])
        let result = sut.sleepDay(on: nap.date)
        XCTAssertEqual(result.daytimeMinutes, 90)
        XCTAssertEqual(result.nightMinutes, 630)
        XCTAssertEqual(result.totalMinutes, 720)
        XCTAssertTrue(result.isFinalized)
        XCTAssertEqual(sut.sleepDay(on: sut.now).totalMinutes, 0)
        XCTAssertTrue(sut.records(on: nap.date).contains { $0.id == wake.id })
        XCTAssertEqual(night.date, date("2026-09-01T20:00:00Z"))
        XCTAssertEqual(night.observedEnd, date("2026-09-02T07:00:00Z"))
    }

    func testOngoingNightRemainsProvisionalAfterTypicalWakeWithoutInventingEnd() {
        let night = sleep("2026-09-01T20:00:00Z", nil)
        let sut = accounting([night])
        XCTAssertEqual(sut.sleepDay(on: night.date).totalMinutes, 960)
        XCTAssertTrue(sut.sleepDay(on: night.date).isProvisional)
        XCTAssertTrue(sut.rolling24hIsProvisional)
        XCTAssertNil(night.observedEnd)
        XCTAssertTrue(night.isOngoing)
    }

    func testDayWithoutNightCannotBeFinalized() {
        let nap = sleep("2026-09-01T13:00:00Z", "2026-09-01T14:00:00Z", kind: .dayNap)
        XCTAssertTrue(accounting([nap]).sleepDay(on: nap.date).isProvisional)
    }

    func testRollingWindowStartsInMiddleOfSession() {
        let night = sleep("2026-09-01T10:00:00Z", "2026-09-01T14:00:00Z")
        XCTAssertEqual(accounting([night]).rolling24hMinutes, 120)
    }

    func testBreakCrossingWindowBoundarySubtractsOnlyItsClippedPortion() {
        let night = sleep("2026-09-01T10:00:00Z", "2026-09-01T14:00:00Z")
        let wake = awake("2026-09-01T11:30:00Z", "2026-09-01T12:30:00Z", parent: night)
        XCTAssertEqual(accounting([night, wake]).rolling24hMinutes, 90)
    }

    func testBreakOutsideWindowDoesNotReduceWindowSleep() {
        let night = sleep("2026-09-01T10:00:00Z", "2026-09-01T14:00:00Z")
        let wake = awake("2026-09-01T10:30:00Z", "2026-09-01T11:00:00Z", parent: night)
        XCTAssertEqual(accounting([night, wake]).rolling24hMinutes, 120)
    }

    func testOverlappingSleepsDuplicateAndOverlappingBreaksAreUnionedWithAwakePrecedence() {
        let first = sleep("2026-09-01T12:00:00Z", "2026-09-01T14:00:00Z")
        let second = sleep("2026-09-01T13:00:00Z", "2026-09-01T15:00:00Z")
        let a = awake("2026-09-01T13:00:00Z", "2026-09-01T13:30:00Z", parent: first)
        let b = awake("2026-09-01T13:20:00Z", "2026-09-01T13:40:00Z", parent: second)
        XCTAssertEqual(accounting([first, second, first, a, a, b]).rolling24hMinutes, 140)
    }

    func testOrphanBreakAndPortionOutsideParentCannotEraseSleep() {
        let first = sleep("2026-09-01T12:00:00Z", "2026-09-01T13:00:00Z")
        let second = sleep("2026-09-01T13:00:00Z", "2026-09-01T14:00:00Z")
        let outside = awake("2026-09-01T12:30:00Z", "2026-09-01T13:30:00Z", parent: first)
        let orphan = SleepRecord(date: date("2026-09-01T13:00:00Z"), duration: 60, kind: .break, parentNapID: UUID())
        XCTAssertEqual(accounting([first, second, outside, orphan]).rolling24hMinutes, 90)
    }

    func testClassificationConflictFlagsSubtotalsWithoutPrioritizingOrMutatingRecords() {
        let nap = sleep("2026-09-01T18:00:00Z", "2026-09-01T20:00:00Z", kind: .dayNap)
        let night = sleep("2026-09-01T19:00:00Z", "2026-09-01T21:00:00Z")
        let sut = accounting([nap, night])
        let summary = sut.sleepDay(on: nap.date)
        XCTAssertEqual(summary.totalMinutes, 180)
        XCTAssertTrue(summary.hasClassificationConflict)
        XCTAssertFalse(summary.subtotalsAreReliable)
        XCTAssertFalse(summary.hasSleepDayConflict)
        XCTAssertEqual(sut.records.map(\.kind), [.dayNap, .nightSleep])
    }

    func testCrossSleepDayConflictDoesNotAllocateSharedTimeAndRollingCountsItOnce() {
        let first = sleep("2026-09-01T23:00:00Z", "2026-09-02T02:00:00Z")
        let second = sleep("2026-09-02T01:00:00Z", "2026-09-02T03:00:00Z")
        let sut = accounting([first, second])
        XCTAssertEqual(sut.rolling24hMinutes, 240)
        XCTAssertTrue(sut.sleepDay(on: first.date).hasSleepDayConflict)
        XCTAssertTrue(sut.sleepDay(on: second.date).hasSleepDayConflict)
        XCTAssertFalse(sut.sleepDay(on: first.date).subtotalsAreReliable)
        XCTAssertEqual(sut.records.map(\.date), [first.date, second.date])
    }

    func testAwakeAttachedToDifferentSleepDayStillTakesPrecedence() {
        let first = sleep("2026-09-01T23:00:00Z", "2026-09-02T02:00:00Z")
        let second = sleep("2026-09-02T01:00:00Z", "2026-09-02T03:00:00Z")
        let wake = awake("2026-09-02T01:00:00Z", "2026-09-02T01:30:00Z", parent: first)
        let sut = accounting([first, second, wake])
        XCTAssertEqual(sut.sleepDay(on: second.date).totalMinutes, 90)
        XCTAssertEqual(sut.rolling24hMinutes, 210)
    }

    func testSpringDSTUsesElapsedTimeAndNotCalendarHourDifference() {
        let night = sleep("2026-03-08T05:00:00Z", "2026-03-08T12:00:00Z") // midnight to 08:00 NY
        let sut = accounting([night], now: "2026-03-08T12:00:00Z", zone: "America/New_York")
        XCTAssertEqual(sut.sleepDay(on: night.date).totalMinutes, 420)
        XCTAssertEqual(sut.rolling24hMinutes, 420)
    }

    func testFallDSTUsesElapsedTimeAndNotCalendarHourDifference() {
        let night = sleep("2026-11-01T04:00:00Z", "2026-11-01T13:00:00Z") // midnight to 08:00 NY
        let sut = accounting([night], now: "2026-11-01T13:00:00Z", zone: "America/New_York")
        XCTAssertEqual(sut.sleepDay(on: night.date).totalMinutes, 540)
        XCTAssertEqual(sut.rolling24hMinutes, 540)
    }

    func testRollingWindowIsExactly24ElapsedHoursAcrossBothDSTChanges() {
        for now in ["2026-03-08T12:00:00Z", "2026-11-01T13:00:00Z"] {
            let reference = date(now)
            let night = SleepRecord(date: reference.addingTimeInterval(-30 * 3600), duration: 0, isOngoing: true)
            let sut = SleepAccounting(records: [night], now: reference, calendar: calendar("America/New_York"))
            XCTAssertEqual(sut.rolling24hMinutes, 1440)
        }
    }

    func testTimezoneChangesGroupingButNeverTimestampsOrRollingTotal() {
        let night = sleep("2026-09-02T01:00:00Z", "2026-09-02T07:00:00Z")
        let utc = accounting([night])
        let la = accounting([night], zone: "America/Los_Angeles")
        XCTAssertEqual(utc.calendar.component(.day, from: night.date), 2)
        XCTAssertEqual(la.calendar.component(.day, from: night.date), 1)
        XCTAssertEqual(utc.rolling24hMinutes, la.rolling24hMinutes)
        XCTAssertEqual(la.records.first?.date, night.date)
        XCTAssertEqual(la.records.first?.observedEnd, night.observedEnd)
    }

    func testMissingLegacyEndIsNotInferredAndDayRemainsProvisional() {
        let night = SleepRecord(date: date("2026-09-01T20:00:00Z"), duration: 0, kind: .nightSleep)
        XCTAssertNil(night.observedEnd)
        XCTAssertEqual(accounting([night]).rolling24hMinutes, 0)
        XCTAssertTrue(accounting([night]).sleepDay(on: night.date).isProvisional)
    }

    func testInjectedHistoricalClockClipsOngoingAndCompletedSessionsAtReference() {
        let ongoing = sleep("2020-01-01T20:00:00Z", nil)
        let completed = sleep("2020-01-01T20:00:00Z", "2020-01-02T08:00:00Z")
        for record in [ongoing, completed] {
            let sut = accounting([record], now: "2020-01-01T22:00:00Z")
            XCTAssertEqual(sut.rolling24hMinutes, 120)
            XCTAssertTrue(sut.sleepDay(on: record.date).isProvisional)
        }
    }

    func testFutureSessionContributesNothing() {
        let future = sleep("2026-09-02T20:00:00Z", nil)
        XCTAssertEqual(accounting([future]).rolling24hMinutes, 0)
    }

    func testLegacyPayloadDecodesWithoutNewEndFieldAndRoundTripsExactEnd() throws {
        let legacy = SleepRecord(date: date("2026-09-01T20:00:00Z"), duration: 660, kind: .nightSleep)
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SleepRecord.self, from: data)
        XCTAssertNil(decoded.endDate)
        XCTAssertEqual(decoded.observedEnd, date("2026-09-02T07:00:00Z"))
        let exact = sleep("2026-09-01T20:00:15Z", "2026-09-02T07:00:42Z")
        let roundTrip = try JSONDecoder().decode(SleepRecord.self, from: JSONEncoder().encode(exact))
        XCTAssertEqual(roundTrip.endDate, exact.endDate)
        XCTAssertEqual(roundTrip.date, exact.date)
    }

    func testDaytimeAnd24HourGuidelinesAreComparedSeparately() {
        let calculator = OvertiredCalculator(profileProvider: DefaultAgeBasedSleepProfileProvider(), calendar: calendar())
        XCTAssertEqual(calculator.daytimeSleepStatus(totalMinutes: 150, ageMonths: 9), .onTrack)
        XCTAssertEqual(calculator.dailySleepStatus(totalMinutes: 150, ageMonths: 9), .below(deficitMinutes: 510))
        XCTAssertEqual(calculator.dailySleepStatus(totalMinutes: 720, ageMonths: 9), .onTrack)
    }
}

extension SleepAccountingRegressionTests {
    func testTouchingWindowBoundaryContributesNoSleep() {
        let session = sleep("2026-09-01T10:00:00Z", "2026-09-01T12:00:00Z")
        XCTAssertEqual(accounting([session]).rolling24hMinutes, 0)
    }

    func testRoundingHappensAfterIntervalUnionAndSubtraction() {
        let a = sleep("2026-09-01T12:00:00Z", "2026-09-01T12:00:40Z")
        let b = sleep("2026-09-01T12:00:40Z", "2026-09-01T12:01:20Z")
        XCTAssertEqual(accounting([a, b]).rolling24hMinutes, 1)
    }

    func testOverviewWeeklyAverageDoesNotSumConflictingSleepDayAllocations() {
        let a = sleep("2026-09-01T23:00:00Z", "2026-09-02T02:00:00Z")
        let b = sleep("2026-09-02T01:00:00Z", "2026-09-02T03:00:00Z")
        let sut = accounting([a, b])
        let metrics = SleepOverviewCalculator(records: sut.records, now: sut.now, calendar: sut.calendar).calculate()
        XCTAssertEqual(metrics.last7DaysAverage, 240 / 7)
        XCTAssertFalse(metrics.subtotalsAreReliable)
    }
}

extension SleepAccountingRegressionTests {
    func testPatternDoesNotLearnOngoingOrMissingEndAsCompletedDuration() {
        let completed = sleep("2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z", kind: .dayNap)
        let ongoing = sleep("2026-09-01T13:00:00Z", nil, kind: .dayNap)
        let missing = SleepRecord(date: date("2026-09-01T15:00:00Z"), duration: 0, kind: .dayNap)
        let pattern = PatternAgent(calendar: calendar()).analyze(records: [completed, ongoing, missing],
            wakeRecords: [], ageMonths: 9, now: date("2026-09-02T12:00:00Z"))
        XCTAssertEqual(pattern.averageNapDurationMinutes, 60)
    }

    func testNextNapUsesExactObservedEndRatherThanNetSleep() {
        let nap = sleep("2026-09-01T10:00:15Z", "2026-09-01T11:30:42Z", kind: .dayNap)
        let wake = awake("2026-09-01T10:30:00Z", "2026-09-01T10:50:00Z", parent: nap)
        let result = DefaultDaytimePredictionAgent(profileProvider: DefaultAgeBasedSleepProfileProvider(), calendar: calendar())
            .predictNextNap(pattern: nil, todayRecords: [nap, wake], wakeRecords: [], ageMonths: 9,
                            trackedDays: 0, now: date("2026-09-01T12:00:00Z"))
        XCTAssertEqual(result.nextNapTime, date("2026-09-01T15:00:42Z"))
    }
}
