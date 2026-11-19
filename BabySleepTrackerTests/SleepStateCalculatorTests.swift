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

    func testFutureNightIsNotMovedToPreviousDayOrTreatedAsActive() {
        let futureNight = record(hour: 18, kind: .nightSleep, ongoing: true)
        let result = calculator(records: [futureNight], hour: 6).calculate()
        XCTAssertNil(result.activeSleepRecord)
        XCTAssertEqual(futureNight.date, record(hour: 18, kind: .nightSleep, ongoing: true).date)
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

extension SleepStateCalculatorTests {
    func testUnconfirmedNightAndNapExpireAtExactElapsedLimits() {
        for (kind, hours) in [(SleepKind.nightSleep, 24.0), (.dayNap, 4.0)] {
            let start = now.addingTimeInterval(-hours * 3600)
            let record = SleepRecord(date: start, duration: 0, kind: kind, isOngoing: true, createdAt: now)
            let prior = SleepStateCalculator.assess(records: [record], wakes: [],
                evaluation: .init(now: now.addingTimeInterval(-1), calendar: calendar))
            XCTAssertEqual(prior.active?.record.id, record.id)
            for later in [now, start.addingTimeInterval(48 * 3600), start.addingTimeInterval(121 * 3600)] {
                let expired = SleepStateCalculator.assess(records: [record], wakes: [],
                    evaluation: .init(now: later, calendar: calendar))
                XCTAssertNil(expired.active)
                XCTAssertNil(expired.anchor)
                XCTAssertEqual(expired.reviewRecord?.id, record.id)
                XCTAssertNil(expired.reviewRecord?.observedEnd)
            }
        }
    }

    func testNewerConfirmationAndLaterWakeResolveByObservedTimeAndRevision() {
        let day = calendar.startOfDay(for: now)
        func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
        var night = SleepRecord(date: at(-4), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(8.5))
        night.persistedRevision = UUID()
        let oldWake = DailyWakeRecord(day: day, wakeTime: at(7))
        let newWake = DailyWakeRecord(day: day, wakeTime: at(9))
        let confirmation = StillSleepingConfirmation(record: night, date: at(8))
        func assess(_ records: [SleepRecord], wakes: [DailyWakeRecord], at time: Date) -> SleepStateAssessment {
            SleepStateCalculator.assess(records: records, wakes: wakes,
                evaluation: .init(now: time, calendar: calendar, routine: .init(wakeHour: 7), confirmation: confirmation))
        }

        XCTAssertEqual(assess([night], wakes: [oldWake], at: at(7.75)).anchor?.date, at(7))
        let sleeping = assess([night], wakes: [oldWake], at: at(8))
        XCTAssertEqual(sleeping.active?.confirmation, at(8))
        XCTAssertNil(sleeping.active?.elapsed)
        XCTAssertNil(sleeping.anchor)
        XCTAssertEqual(assess([night], wakes: [newWake], at: at(9)).anchor?.date, at(9))
        XCTAssertEqual(assess([night], wakes: [oldWake, newWake], at: at(9)).unavailableReason, .conflict)
        XCTAssertNil(assess([night], wakes: [oldWake], at: at(9.5)).anchor)

        night.persistedRevision = UUID()
        let changed = assess([night], wakes: [oldWake], at: at(8))
        XCTAssertNil(changed.active)
        XCTAssertEqual(changed.anchor?.date, at(7))
    }

    func testAfterMidnightNightUsesFirstSameMorningWake() {
        let night = record(hour: 2, kind: .nightSleep, ongoing: true, duration: 0)
        let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        let grace = wake.addingTimeInterval(30 * 60)
        let routine = SleepRoutine(wakeHour: 7, bedHour: 19)
        XCTAssertEqual(routine.wake(after: night.date, calendar: calendar), wake)
        let boundary = SleepStateCalculator.assess(records: [night], wakes: [],
            evaluation: .init(now: grace, calendar: calendar, routine: routine))
        XCTAssertNil(boundary.active)
        XCTAssertEqual(boundary.reminderNight?.id, night.id)
    }
}
