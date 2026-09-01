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

        XCTAssertEqual(metrics.todayTotal, 60 - 10 + 30 - 20 + 480)
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
        let newest = record(dayOffset: 0, hour: 12, duration: 100)
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
        XCTAssertEqual(metrics.todayGoalProgress, min(Double(metrics.todayTotal) / 840.0, 1.0))
    }

    private func calculate(_ records: [SleepRecord]) -> SleepOverviewMetrics {
        SleepOverviewCalculator(records: records, now: now, calendar: calendar).calculate()
    }

    private func record(dayOffset: Int, hour: Int = 8, duration: Int, kind: SleepKind = .dayNap, isOngoing: Bool = false) -> SleepRecord {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return SleepRecord(date: date, duration: duration, kind: kind, isOngoing: isOngoing)
    }
}
