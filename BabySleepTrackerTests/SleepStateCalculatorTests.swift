import XCTest
@testable import BabySleepTracker

final class SleepStateCalculatorTests: XCTestCase {
    private var calendar: Calendar!
    private var now = Date(timeIntervalSince1970: 0)

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
    }

    func testNoActiveSleepDoesNotCreateActiveRecordDuringDay() {
        let result = calculator(records: []).calculate()
        XCTAssertNil(result.activeSleepRecord)
        XCTAssertNil(result.inferredNightSleepRecord)
        XCTAssertFalse(result.isStillInNightSleep)
    }

    func testOngoingDayNapIsActive() {
        let nap = record(hour: 10, kind: .dayNap, ongoing: true)
        let result = calculator(records: [nap]).calculate()
        XCTAssertEqual(result.activeSleepRecord?.id, nap.id)
        XCTAssertEqual(result.activeSleepRecord?.date, nap.date)
    }

    func testOngoingNightSleepIsActive() {
        let night = record(hour: 10, kind: .nightSleep, ongoing: true)
        let result = calculator(records: [night]).calculate()
        XCTAssertEqual(result.activeSleepRecord?.id, night.id)
        XCTAssertTrue(result.isStillInNightSleep)
    }

    func testLatestOngoingRecordWins() {
        let older = record(hour: 8, kind: .dayNap, ongoing: true)
        let newer = record(hour: 10, kind: .nightSleep, ongoing: true)
        let result = calculator(records: [older, newer]).calculate()
        XCTAssertEqual(result.activeSleepRecord?.id, newer.id)
    }

    func testNightIsInferredAfterTypicalBedtimeWithoutActiveRecord() {
        let result = calculator(records: [], hour: 20).calculate()
        let expected = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: now)!
        XCTAssertEqual(result.inferredNightSleepStart, expected)
        XCTAssertEqual(result.inferredNightSleepRecord?.kind, .nightSleep)
        XCTAssertTrue(result.inferredNightSleepRecord?.isOngoing == true)
    }

    func testNightInferenceBeforeWakeUsesPreviousNightBedtime() {
        let early = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now)!
        let result = calculator(records: [], now: early).calculate()
        let todayBedtime = calendar.date(bySettingHour: 19, minute: 30, second: 0, of: early)!
        XCTAssertEqual(result.inferredNightSleepStart, calendar.date(byAdding: .day, value: -1, to: todayBedtime))
    }

    func testNightInferenceAtWakeBoundaryIsNil() {
        let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        XCTAssertNil(calculator(records: [], now: wake).calculate().inferredNightSleepRecord)
    }

    func testFutureTodayNightRecordBeforeWakeIsNormalizedToPreviousDay() {
        let futureNight = record(hour: 18, kind: .nightSleep, ongoing: true)
        let result = calculator(records: [futureNight], hour: 6).calculate()
        XCTAssertEqual(result.activeSleepRecord?.date, calendar.date(byAdding: .day, value: -1, to: futureNight.date))
    }

    func testExpectedWakeUsesTypicalWakeFallbackWhenThereIsNoSleep() {
        let result = calculator(records: []).expectedWakeTime(for: nil)
        XCTAssertEqual(result, calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now))
    }

    func testExpectedWakeForDayNapUsesDurationOrSnapshotFallback() {
        let nap = record(hour: 10, kind: .dayNap, ongoing: true, duration: 45)
        XCTAssertEqual(calculator(records: []).expectedWakeTime(for: nap), nap.date.addingTimeInterval(45 * 60))

        let unknownDuration = record(hour: 10, kind: .dayNap, ongoing: true, duration: 0)
        XCTAssertEqual(calculator(records: [], averageNap: 90).expectedWakeTime(for: unknownDuration), unknownDuration.date.addingTimeInterval(90 * 60))
        XCTAssertEqual(calculator(records: []).expectedWakeTime(for: unknownDuration), unknownDuration.date.addingTimeInterval(75 * 60))
    }

    func testExpectedWakeForNightSleepUsesTodayOrNextTypicalWake() {
        let beforeWake = record(hour: 2, kind: .nightSleep, ongoing: true)
        let afterWake = record(hour: 10, kind: .nightSleep, ongoing: true)
        XCTAssertEqual(calculator(records: []).expectedWakeTime(for: beforeWake), calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now))
        XCTAssertEqual(calculator(records: []).expectedWakeTime(for: afterWake), calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!))
    }

    func testNextSleepUsesSnapshotForNilOrNightAndWakeWindowForNap() {
        let predicted = now.addingTimeInterval(5 * 60 * 60)
        let nap = record(hour: 10, kind: .dayNap, ongoing: true, duration: 60)
        let night = record(hour: 10, kind: .nightSleep, ongoing: true)
        let wake = nap.date.addingTimeInterval(60 * 60)
        let sut = calculator(records: [], predictedNextNap: predicted, recommendedWindow: 130)
        XCTAssertEqual(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: nil, expectedWake: wake), predicted)
        XCTAssertEqual(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: night, expectedWake: wake), predicted)
        XCTAssertEqual(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: nap, expectedWake: wake), wake.addingTimeInterval(130 * 60))
    }

    func testMissingPredictionFallsBackToNilForNightAndCalculatedWakeWindowForNap() {
        let nap = record(hour: 10, kind: .dayNap, ongoing: true)
        let night = record(hour: 10, kind: .nightSleep, ongoing: true)
        let wake = nap.date.addingTimeInterval(75 * 60)
        let sut = calculator(records: [], recommendedWindow: 120)
        XCTAssertNil(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: nil, expectedWake: wake))
        XCTAssertNil(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: night, expectedWake: wake))
        XCTAssertEqual(sut.nextSleepTimeAfterCurrentSleep(ongoingSleep: nap, expectedWake: wake), wake.addingTimeInterval(120 * 60))
    }

    private func calculator(records: [SleepRecord], now: Date? = nil, hour: Int? = nil, averageNap: Int? = nil, predictedNextNap: Date? = nil, recommendedWindow: Int = 120) -> SleepStateCalculator {
        let calculationNow = now ?? (hour.flatMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: self.now) } ?? self.now)
        return SleepStateCalculator(records: records, now: calculationNow, calendar: calendar, typicalWakeHour: 7, typicalWakeMinute: 0, typicalBedHour: 19, typicalBedMinute: 30, averageNapDurationMinutes: averageNap, predictedNextNapTime: predictedNextNap, recommendedWakeWindowMinutes: recommendedWindow)
    }

    private func record(hour: Int, kind: SleepKind, ongoing: Bool, duration: Int = 60) -> SleepRecord {
        SleepRecord(date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!, duration: duration, kind: kind, isOngoing: ongoing)
    }
}
