import XCTest
@testable import BabySleepTracker

final class TodaySleepHeroModelTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13))! }
    private func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
    private func sleep(_ start: Double, minutes: Int = 60, kind: SleepKind = .dayNap, ongoing: Bool = false) -> SleepRecord {
        SleepRecord(date: at(start), duration: minutes, kind: kind, isOngoing: ongoing, createdAt: at(start))
    }
    private func model(_ records: [SleepRecord] = [], wakes: [DailyWakeRecord] = [], now: Double = 12,
                       routine: TodaySleepHeroModel.Routine? = nil, proposals: [HeroPrediction] = [],
                       confirmation: TodaySleepHeroModel.StillSleepingConfirmation? = nil) -> TodaySleepHeroModel {
        .make(records: records, wakeRecords: wakes, now: at(now), calendar: calendar, routine: routine,
              displayName: "Parent", babyName: "Baby", proposals: proposals, confirmation: confirmation)
    }
    private func wake(_ hour: Double) -> DailyWakeRecord { DailyWakeRecord(day: day, wakeTime: at(hour)) }
    private func prediction(_ kind: HeroPrediction.Kind = .nextSleep, start: Double? = 13, end: Double? = 14,
                            record: SleepRecord? = nil, anchor: Date? = nil,
                            eligibility: HeroPrediction.Eligibility = .verified,
                            source: HeroPrediction.Provenance = .ruleEngine,
                            generated: Double = 12, expires: Double = 18,
                            window: ClosedRange<Int>? = nil) -> HeroPrediction {
        .init(kind: kind, sleepKind: .dayNap, start: start.map(at), end: end.map(at), wakeWindow: window,
              anchorRecordID: record?.id, anchorDate: anchor ?? record?.observedEnd,
              provenance: source, eligibility: eligibility, generatedAt: at(generated), validUntil: at(expires))
    }
    func testAllSevenStatesUseOnlyEligibleOrConfirmedInputs() {
        let night = sleep(-4, kind: .nightSleep, ongoing: true)
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        XCTAssertEqual(model().mode, .ready)
        XCTAssertEqual(model([sleep(11, ongoing: true)]).mode, .napActive)
        XCTAssertEqual(model([sleep(10)]).mode, .napCompleted)
        XCTAssertEqual(model([night], now: 6, routine: routine).mode, .nightActive)
        XCTAssertEqual(model(wakes: [wake(7.25)], now: 8).mode, .morningConfirmed)
        XCTAssertEqual(model([night], now: 8, routine: routine).mode, .morningUnconfirmed)
        XCTAssertEqual(model(proposals: [prediction()]).mode, .likelyNext)
    }
    func testGraceBoundaryIsPresentationOnlyAndConfigurable() {
        let night = sleep(-4, kind: .nightSleep, ongoing: true)
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        XCTAssertEqual(model([night], now: 7.5 - 1.0 / 3600, routine: routine).mode, .nightActive)
        let boundary = model([night], now: 7.5, routine: routine)
        XCTAssertEqual(boundary.mode, .morningUnconfirmed)
        XCTAssertTrue(boundary.isNightOpen)
        XCTAssertNil(boundary.wakeTime)
        XCTAssertNil(boundary.netMinutes)
        XCTAssertNil(boundary.record?.observedEnd)
        XCTAssertEqual(boundary.record?.id, night.id)
        XCTAssertEqual(model([night], now: 7.5, routine: .init(wakeHour: 7, graceMinutes: 45)).mode, .nightActive)
    }
    func testNewerExplicitSleepingConfirmationTakesPriorityOverRoutineAndEarlierWake() {
        let night = sleep(-4, kind: .nightSleep, ongoing: true)
        let confirmation = TodaySleepHeroModel.StillSleepingConfirmation(recordID: night.id, date: at(8))
        let current = model([night], wakes: [wake(7.25)], now: 8.5, routine: .init(wakeHour: 7), confirmation: confirmation)
        XCTAssertEqual(current.mode, .nightActive)
        let laterWake = model([night], wakes: [wake(8.25)], now: 8.5, routine: .init(wakeHour: 7), confirmation: confirmation)
        XCTAssertEqual(laterWake.mode, .morningConfirmed)
        let wrongParent = TodaySleepHeroModel.StillSleepingConfirmation(recordID: UUID(), date: at(8))
        XCTAssertEqual(model([night], now: 8.5, routine: .init(wakeHour: 7), confirmation: wrongParent).mode, .morningUnconfirmed)
    }
    func testTransientConfirmationExpiresAtNextLocalDayAndFutureConfirmationIsIgnored() {
        let night = sleep(-4, kind: .nightSleep, ongoing: true)
        let confirmation = TodaySleepHeroModel.StillSleepingConfirmation(recordID: night.id, date: at(8))
        XCTAssertEqual(model([night], now: 32, routine: .init(wakeHour: 7), confirmation: confirmation).mode, .morningUnconfirmed)
        let future = TodaySleepHeroModel.StillSleepingConfirmation(recordID: night.id, date: at(9))
        XCTAssertEqual(model([night], now: 8, routine: .init(wakeHour: 7), confirmation: future).mode, .morningUnconfirmed)
    }

    func testNewlyRecordedOngoingNightIsAnExplicitObservationAfterTransition() {
        let night = SleepRecord(date: at(-4), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(8))
        XCTAssertEqual(model([night], now: 8.5, routine: .init(wakeHour: 7)).mode, .nightActive)
    }
    func testActiveNapSupersedesOlderCompletionAndWake() {
        let old = sleep(9), active = sleep(11, ongoing: true)
        let result = model([old, active], wakes: [wake(7)], routine: .init(wakeHour: 7))
        XCTAssertEqual(result.mode, .napActive)
        XCTAssertEqual(result.record?.id, active.id)
        XCTAssertEqual(result.napNumber, 2)
        XCTAssertEqual(result.elapsedMinutes, 60)
        XCTAssertNil(result.netMinutes)
        XCTAssertNil(result.record?.observedEnd)
        XCTAssertTrue(result.canAddBreak)
    }
    func testCompletedNapUsesConfirmedEndAndUnionOfAttachedBreaks() {
        let nap = sleep(8, minutes: 120)
        let first = SleepRecord(date: at(8 + 10.0 / 60), duration: 20, kind: .break, parentNapID: nap.id)
        let overlapping = SleepRecord(date: at(8 + 20.0 / 60), duration: 20, kind: .break, parentNapID: nap.id)
        let unrelated = SleepRecord(date: at(8.5), duration: 20, kind: .break, parentNapID: UUID())
        let result = model([nap, first, overlapping, unrelated])
        XCTAssertEqual(result.mode, .napCompleted)
        XCTAssertEqual(result.netMinutes, 90)
        XCTAssertEqual(result.record?.observedEnd, at(10))
        XCTAssertTrue(result.predictions.isEmpty)
        XCTAssertEqual(result.predictionUnavailableReason, .eligibilityUnverified)
        XCTAssertFalse(result.canAddBreak)
    }
    func testCompletedNapPredictionsRequireExactRecordedEndAnchor() {
        let nap = sleep(9)
        let valid = prediction(.wakeWindow, start: nil, end: nil, record: nap, window: 120...150)
        XCTAssertNotNil(model([nap], proposals: [valid]).prediction(.wakeWindow))
        let wrong = prediction(.wakeWindow, start: nil, end: nil, record: nap, anchor: at(9.5), window: 120...150)
        XCTAssertTrue(model([nap], proposals: [wrong]).predictions.isEmpty)
        XCTAssertEqual(wrong.unavailableReason(now: at(12), record: nap, wake: nil), .wrongAnchor)
    }
    func testWakeFromRecordedNightCompletionDoesNotRequireSyntheticDailyWake() {
        let night = SleepRecord(date: at(-4), duration: 675, kind: .nightSleep, createdAt: at(-4), endDate: at(7.25))
        let result = model([night], now: 8)
        XCTAssertEqual(result.mode, .morningConfirmed)
        XCTAssertEqual(result.wakeTime, at(7.25))
        XCTAssertEqual(result.title, "Good morning, Parent!")
        XCTAssertFalse(result.isNightOpen)
    }
    func testRetroactiveWakeAndCompletedNapPrecedenceUseObservedTimesNotLoggingTime() {
        let nap = sleep(9)
        XCTAssertEqual(model([nap], wakes: [wake(7.25)]).mode, .napCompleted)
        XCTAssertEqual(model([nap], wakes: [wake(11)]).mode, .morningConfirmed)
        let late = SleepRecord(date: at(8), duration: 30, createdAt: at(11.5))
        XCTAssertEqual(model([late, nap]).record?.id, nap.id)
    }
    func testFutureWakeAndUnknownOrFutureSleepCannotBecomeConfirmed() {
        let unknown = sleep(8, minutes: 0), future = sleep(13, ongoing: true)
        let result = model([unknown, future], wakes: [wake(13)])
        XCTAssertEqual(result.mode, .ready)
        XCTAssertNil(result.record)
        XCTAssertNil(result.wakeTime)
    }
    func testMissingOrInvalidRoutineDoesNotInventSevenAMTransition() {
        XCTAssertEqual(model(now: 8).mode, .ready)
        XCTAssertEqual(model(now: 8, routine: .init(wakeHour: 25)).mode, .ready)
        XCTAssertEqual(model([sleep(-4, kind: .nightSleep, ongoing: true)], now: 8).mode, .nightActive)
        XCTAssertNil(model(now: 8).routineWake)
    }
    func testRoutineLoadsOnlyExplicitValidSettings() throws {
        let name = "HeroRoutineTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(TodaySleepHeroModel.Routine.load(defaults: defaults))
        defaults.set(7.0, forKey: "typicalWakeHour")
        XCTAssertEqual(TodaySleepHeroModel.Routine.load(defaults: defaults)?.wakeMinute, 0)
        defaults.set(15.0, forKey: "typicalWakeMinute")
        XCTAssertEqual(TodaySleepHeroModel.Routine.load(defaults: defaults)?.wakeMinute, 15)
        defaults.set(25.0, forKey: "typicalWakeHour")
        XCTAssertNil(TodaySleepHeroModel.Routine.load(defaults: defaults))
        defaults.set(Double.nan, forKey: "typicalWakeHour")
        XCTAssertNil(TodaySleepHeroModel.Routine.load(defaults: defaults))
    }

    func testUnverifiedAgeGuidanceAndLLMNeverAuthorizePersonalizedTimes() {
        for candidate in [prediction(eligibility: .unavailable), prediction(source: .ageGuidance), prediction(source: .llm)] {
            let result = model(proposals: [candidate])
            XCTAssertEqual(result.mode, .ready)
            XCTAssertTrue(result.predictions.isEmpty)
        }
    }
    func testExpiredOverdueAndFutureGeneratedPredictionsAreRejected() {
        for candidate in [prediction(expires: 12), prediction(start: 11, end: 12), prediction(generated: 13)] {
            XCTAssertEqual(model(proposals: [candidate]).mode, .ready)
        }
        XCTAssertEqual(model(proposals: [prediction(start: 12, end: 13)]).mode, .ready)
    }
    func testPredictionValidityDoesNotInventOrLimitTheObservedSleepEnd() {
        let candidate = prediction(start: 13, end: 14, expires: 12.5)
        let result = model(proposals: [candidate])
        XCTAssertEqual(result.mode, .likelyNext)
        XCTAssertNil(result.record)
        XCTAssertNil(result.netMinutes)
        XCTAssertEqual(result.prediction(.nextSleep)?.end, at(14))
    }

    func testEligibleNextSleepNeverOverridesObservedNapOrMorning() {
        let estimate = prediction()
        XCTAssertEqual(model([sleep(10)], proposals: [estimate]).mode, .napCompleted)
        XCTAssertEqual(model(wakes: [wake(7)], proposals: [estimate]).mode, .morningConfirmed)
        XCTAssertEqual(model(routine: .init(wakeHour: 7), proposals: [estimate]).mode, .morningUnconfirmed)
    }
    func testOvernightCarryoverPreservesIDOriginalSleepDayAndElapsed() {
        let night = sleep(-4, kind: .nightSleep, ongoing: true)
        let result = model([night], now: 6)
        XCTAssertEqual(result.mode, .nightActive)
        XCTAssertEqual(result.record?.id, night.id)
        XCTAssertEqual(result.sleepDay, calendar.startOfDay(for: at(-4)))
        XCTAssertEqual(result.elapsedMinutes, 600)
        XCTAssertNil(result.record?.observedEnd)
    }
    func testNapCompletedAcrossMidnightRemainsRelevantWithoutMovingItsSleepDay() {
        let nap = sleep(-0.5)
        let result = model([nap], now: 0.5)
        XCTAssertEqual(result.mode, .napCompleted)
        XCTAssertEqual(result.record?.id, nap.id)
        XCTAssertEqual(result.netMinutes, 60)
        XCTAssertEqual(result.sleepDay, calendar.startOfDay(for: nap.date))
    }

    func testPreviousSleepDayNapsDoNotInflateCurrentDayNapNumber() {
        let old = sleep(-4), first = sleep(8), second = sleep(10), active = sleep(11, ongoing: true)
        XCTAssertEqual(model([old, first, second, active]).napNumber, 3)
        XCTAssertEqual(model([old], now: 6).mode, .ready)
    }
    func testEditingAndDeletionRecomputeWithoutStickyCompletedState() {
        let nap = sleep(9)
        XCTAssertEqual(model([nap]).mode, .napCompleted)
        XCTAssertEqual(model().mode, .ready)
        let edited = SleepRecord(id: nap.id, date: nap.date, duration: 90, createdAt: nap.createdAt, endDate: at(10.5))
        XCTAssertEqual(model([edited]).netMinutes, 90)
        XCTAssertEqual(model([edited]).record?.observedEnd, at(10.5))
    }
    func testEndSleepDraftIsCancelableAndPreservesStoredIdentityUntilSave() throws {
        let night = sleep(-4, minutes: 0, kind: .nightSleep, ongoing: true)
        var draft = SleepRecordingDraft(defaultDate: night.date, editing: night, now: at(8))
        draft.prepareForEnding(at: at(8))
        XCTAssertTrue(night.isOngoing)
        XCTAssertNil(night.observedEnd)
        XCTAssertFalse(draft.isOngoing)
        let saved = try XCTUnwrap(draft.record(kind: .nightSleep, editing: night, now: at(8)))
        XCTAssertEqual(saved.id, night.id)
        XCTAssertEqual(saved.createdAt, night.createdAt)
        XCTAssertEqual(saved.observedEnd, at(8))
        XCTAssertEqual(model([saved], now: 8).mode, .morningConfirmed)
    }
    func testRoutineGraceCanCrossMidnightWithoutReassigningSleep() {
        let night = sleep(-2, kind: .nightSleep, ongoing: true)
        let result = model([night], now: 1.0 / 3, routine: .init(wakeHour: 23, wakeMinute: 50, bedHour: 8))
        XCTAssertEqual(result.mode, .morningUnconfirmed)
        XCTAssertEqual(result.routineWake, at(-1.0 / 6))
        XCTAssertEqual(result.sleepDay, calendar.startOfDay(for: night.date))
    }
    func testDSTUsesLocalRoutineBoundaryAndActualElapsedTime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20)))
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 7, minute: 30)))
        let night = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)
        let result = TodaySleepHeroModel.make(records: [night], wakeRecords: [], now: now, calendar: cal,
            routine: .init(wakeHour: 7), displayName: "Parent", babyName: "Baby")
        XCTAssertEqual(result.mode, .morningUnconfirmed)
        XCTAssertEqual(result.elapsedMinutes, 750)
        XCTAssertEqual(result.sleepDay, cal.startOfDay(for: start))
    }
    func testMorningProjectionNeverCreatesPersistedWakeOrEnd() throws {
        let name = "HeroTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let wakes = DailyWakeRecordPersistence(defaults: defaults)
        let night = sleep(-4, minutes: 0, kind: .nightSleep, ongoing: true)
        XCTAssertTrue(persistence.save([night]))
        let before = try XCTUnwrap(defaults.data(forKey: "sleepRecords"))
        _ = model(try XCTUnwrap(persistence.load()), now: 8, routine: .init(wakeHour: 7))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before)
        XCTAssertNil(wakes.load())
    }

    func testBedtimeBoundaryReplacesCompletedNapButNotBefore() {
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        let records = [sleep(16)]
        XCTAssertEqual(model(records, now: 19 - 1.0 / 3600, routine: routine).mode, .napCompleted)
        for hour in [19.0, 20.55, 23.99] {
            let result = model(records, wakes: [wake(7)], now: hour, routine: routine)
            XCTAssertEqual(result.mode, .bedtimeRoutine)
            XCTAssertEqual(result.routineBedtime, at(19))
            XCTAssertEqual(result.title, "Bedtime routine")
            XCTAssertNil(result.record)
            XCTAssertNil(result.elapsedMinutes)
            XCTAssertNil(result.netMinutes)
        }
        XCTAssertEqual(model(now: 20, routine: routine).mode, .bedtimeRoutine)
    }

    func testConfirmedOngoingNapAndNightTakePriorityAtBedtime() {
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        for (kind, expected) in [(SleepKind.dayNap, TodaySleepHeroModel.Mode.napActive), (.nightSleep, .nightActive)] {
            let record = sleep(18.5, minutes: 0, kind: kind, ongoing: true)
            let result = model([record], now: 20, routine: routine)
            XCTAssertEqual(result.mode, expected)
            XCTAssertEqual(result.record?.id, record.id)
            XCTAssertNil(result.record?.observedEnd)
            XCTAssertEqual(result.elapsedMinutes, 90)
        }
    }

    func testBedtimeRequiresValidExplicitBedtimeAndNoPredictionEligibility() throws {
        XCTAssertEqual(model([sleep(16)], now: 20, routine: .init(wakeHour: 7)).mode, .napCompleted)
        XCTAssertEqual(model(now: 20, routine: .init(wakeHour: 7, bedHour: 25)).mode, .morningUnconfirmed)
        let name = "BedtimeRoutineTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(19.0, forKey: "typicalBedHour")
        let routine = try XCTUnwrap(TodaySleepHeroModel.Routine.load(defaults: defaults))
        XCTAssertNil(routine.wakeHour)
        let result = model(now: 20, routine: routine, proposals: [prediction(start: 21, end: 22, generated: 20, expires: 23)])
        XCTAssertEqual(result.mode, .bedtimeRoutine)
        XCTAssertTrue(result.predictions.isEmpty, "Routine defaults must not activate prediction display.")
        XCTAssertNil(result.routineWake)
        XCTAssertEqual(model(now: 24, routine: routine).mode, .ready, "No invented morning boundary without wake settings.")
        defaults.set(60.0, forKey: "typicalBedMinute")
        XCTAssertNil(TodaySleepHeroModel.Routine.load(defaults: defaults))
    }

    func testRelevantRetroactiveNightSuppressesRoutineAndDeletionRecalculates() {
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        let nap = sleep(16)
        let previousNight = sleep(-4, minutes: 660, kind: .nightSleep)
        XCTAssertEqual(model([nap, previousNight], now: 21, routine: routine).mode, .bedtimeRoutine)
        let night = SleepRecord(date: at(18), duration: 120, kind: .nightSleep, createdAt: at(20.5), endDate: at(20))
        let confirmed = model([nap, night], now: 21, routine: routine)
        XCTAssertEqual(confirmed.mode, .morningConfirmed)
        XCTAssertEqual(confirmed.wakeTime, at(20))
        let edited = SleepRecord(id: night.id, date: at(18), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(20.5))
        XCTAssertEqual(model([nap, edited], now: 21, routine: routine).mode, .nightActive)
        XCTAssertEqual(model([nap], now: 21, routine: routine).mode, .bedtimeRoutine)
        XCTAssertEqual(model([nap, sleep(18, minutes: 0, kind: .nightSleep)], now: 21, routine: routine).mode, .bedtimeRoutine,
                       "A record with no observed interval is not a confirmed night.")
    }

    func testLaterConfirmedWakeTakesPriorityOverBedtimeCue() {
        let records = [sleep(16)]
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        let result = model(records, wakes: [wake(20)], now: 21, routine: routine)
        XCTAssertEqual(result.mode, .morningConfirmed)
        XCTAssertEqual(result.wakeTime, at(20))
        XCTAssertEqual(model(records, wakes: [wake(7)], now: 21, routine: routine).mode, .bedtimeRoutine,
                       "Editing the wake back to morning must remove the later confirmation.")
        XCTAssertEqual(model(records, now: 21, routine: routine).mode, .bedtimeRoutine)
    }

    func testBedtimeCarriesAcrossMidnightAndStopsAtMorningGrace() {
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        for hour in [24.0, 26, 31.5 - 1.0 / 3600] {
            let result = model([sleep(16)], now: hour, routine: routine)
            XCTAssertEqual(result.mode, .bedtimeRoutine)
            XCTAssertEqual(result.routineBedtime, at(19))
        }
        XCTAssertEqual(model(now: 31.5, routine: routine).mode, .morningUnconfirmed)
        let night = sleep(20, minutes: 0, kind: .nightSleep, ongoing: true)
        XCTAssertEqual(model([night], now: 32, routine: routine).mode, .morningUnconfirmed)
        XCTAssertEqual(model([sleep(16)], now: 32, routine: routine).mode, .morningUnconfirmed)
        XCTAssertEqual(model([sleep(16)], now: 43, routine: routine).mode, .bedtimeRoutine)
    }

    func testReprojectionAfterForegroundAndRoutineEditsHasNoStickyState() {
        let records = [sleep(16)]
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        XCTAssertEqual(model(records, now: 18, routine: routine).mode, .napCompleted)
        // The existing TimelineView/foreground reload calls the same projection with fresh time.
        XCTAssertEqual(model(records, now: 20, routine: routine).mode, .bedtimeRoutine)
        XCTAssertEqual(model(records, now: 20, routine: .init(wakeHour: 7, bedHour: 21)).mode, .napCompleted)
        XCTAssertEqual(model(records, now: 20, routine: .init(wakeHour: 7)).mode, .napCompleted)
    }

    func testLocalBedtimeWindowsAcrossTimezonesAndDST() throws {
        for (zone, month, dayOfMonth) in [("Europe/Istanbul", 11, 13), ("America/New_York", 3, 8), ("America/New_York", 11, 1)] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let morningDay = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: month, day: dayOfMonth)))
            let eveningDay = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: morningDay))
            let bedtime = try XCTUnwrap(cal.date(bySettingHour: 19, minute: 0, second: 0, of: eveningDay))
            func project(_ now: Date) -> TodaySleepHeroModel {
                .make(records: [], wakeRecords: [], now: now, calendar: cal,
                      routine: .init(wakeHour: 7, bedHour: 19), displayName: "Parent", babyName: "Baby")
            }
            let overnight = project(try XCTUnwrap(cal.date(bySettingHour: 3, minute: 30, second: 0, of: morningDay)))
            XCTAssertEqual(overnight.mode, .bedtimeRoutine, zone)
            XCTAssertEqual(overnight.routineBedtime, bedtime, zone)
            XCTAssertEqual(project(try XCTUnwrap(cal.date(bySettingHour: 7, minute: 30, second: 0, of: morningDay))).mode, .morningUnconfirmed)
        }
    }

    func testBedtimeProjectionAndFailedSubmissionNeverPersistRoutineAsSleep() throws {
        let name = "BedtimePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let nap = sleep(16)
        XCTAssertTrue(persistence.save([nap]))
        let before = try XCTUnwrap(defaults.data(forKey: "sleepRecords"))
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        XCTAssertEqual(model(try XCTUnwrap(persistence.load()), now: 21, routine: routine).mode, .bedtimeRoutine)
        var draft = SleepRecordingDraft(defaultDate: at(21), now: at(21))
        XCTAssertEqual(draft.start, at(20), "Keep the recording draft's existing time, not usual bedtime.")
        XCTAssertNotEqual(draft.start, at(19))
        draft.isOngoing = true
        var submission = RecordingSubmission()
        var dismissed = false
        submission.submit(draft.record(kind: .nightSleep, now: at(21)), save: { _ in false }, dismiss: { dismissed = true })
        XCTAssertFalse(dismissed)
        XCTAssertFalse(submission.isSubmitted)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before)
        XCTAssertNil(DailyWakeRecordPersistence(defaults: defaults).load())
        XCTAssertEqual(model(try XCTUnwrap(persistence.load()), now: 21, routine: routine).mode, .bedtimeRoutine)
    }
}
