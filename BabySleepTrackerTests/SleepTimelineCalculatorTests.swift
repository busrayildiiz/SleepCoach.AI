import XCTest
@testable import BabySleepTracker

final class SleepTimelineCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13))! }
    private func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
    private func calculate(records: [SleepRecord] = [], wake: DailyWakeRecord? = nil,
                           proposals: [SleepTimelineProposal] = [], verified: Bool = false,
                           now: Date? = nil, selectedDay: Date? = nil) -> [SleepTimelineItem] {
        SleepTimelineCalculator(records: records, wakeRecord: wake, now: now ?? at(12),
            calendar: calendar, day: selectedDay, proposals: proposals,
            predictionEligibility: verified ? .verified : .unavailable).calculate()
    }
    private func proposal(_ id: String, hour: Double, source: SleepTimelineProposal.Source = .estimate,
                          kind: SleepTimelineItem.Kind = .nap(index: 1)) -> SleepTimelineProposal {
        .init(id: id, kind: kind, sleepDay: day, time: at(hour), source: source)
    }
    private func item(_ record: SleepRecord, in items: [SleepTimelineItem]) throws -> SleepTimelineItem {
        try XCTUnwrap(items.first { $0.source == .recorded(record.id) })
    }

    func testCompletedNapKeepsNetRecordedDurationAndAttachedBreak() throws {
        let nap = SleepRecord(date: at(8), duration: 60)
        let attached = SleepRecord(date: at(8.25), duration: 10, kind: .break, parentNapID: nap.id)
        let unrelated = SleepRecord(date: at(8.5), duration: 20, kind: .break, parentNapID: UUID())
        let items = calculate(records: [nap, attached, unrelated])
        let result = try item(nap, in: items)
        XCTAssertEqual(result.visualState, .completed)
        XCTAssertEqual(result.durationMinutes, 50)
        XCTAssertEqual(result.observedEnd, at(9))
        XCTAssertNil(result.elapsedMinutes)
        XCTAssertEqual(items.filter { if case .recorded = $0.source { return true }; return false }.count, 1)
    }

    func testOnlyConfirmedOngoingSleepIsActiveAndHasElapsedNotInferredEnd() throws {
        let ongoing = SleepRecord(date: at(11), duration: 90, kind: .nightSleep, isOngoing: true)
        let result = try item(ongoing, in: calculate(records: [ongoing]))
        XCTAssertEqual(result.visualState, .active)
        XCTAssertEqual(result.elapsedMinutes, 60)
        XCTAssertNil(result.durationMinutes)
        XCTAssertNil(result.observedEnd, "Stored duration must not become an ongoing session's end.")
        XCTAssertEqual(result.kind, .bedtime)
        XCTAssertEqual(result.sleepDay, day)
    }

    func testUnknownInvalidAndFutureRecordIntervalsAreNeitherCompletedNorActive() throws {
        let records = [
            SleepRecord(date: at(8), duration: 0),
            SleepRecord(date: at(9), duration: -30),
            SleepRecord(date: at(10), duration: 0, endDate: at(9)),
            SleepRecord(date: at(11), duration: 120), // Recorded end is in the future.
            SleepRecord(date: at(13), duration: 30),
            SleepRecord(date: at(14), duration: 0, isOngoing: true)
        ]
        let items = calculate(records: records)
        for record in records {
            let result = try item(record, in: items)
            XCTAssertEqual(result.visualState, .unavailable)
            XCTAssertEqual(result.unavailableReason, .invalidRecord)
            XCTAssertNil(result.durationMinutes)
            XCTAssertNil(result.elapsedMinutes)
            XCTAssertNil(result.observedEnd)
            XCTAssertNil(result.awakeBeforeMinutes)
        }
    }

    func testWakeRequiresValidRecordedTimeForSelectedDay() throws {
        let wake = DailyWakeRecord(day: day, wakeTime: at(7))
        let result = try XCTUnwrap(calculate(wake: wake).first { $0.kind == .wake })
        XCTAssertEqual(result.source, .recorded(wake.id))
        XCTAssertEqual(result.visualState, .completed)
        XCTAssertEqual(result.time, at(7))
        for invalid in [DailyWakeRecord(day: day, wakeTime: at(13)), DailyWakeRecord(day: day, wakeTime: at(-1))] {
            let value = try XCTUnwrap(calculate(wake: invalid).first { $0.kind == .wake })
            XCTAssertEqual(value.visualState, .unavailable)
        }
        let otherDay = DailyWakeRecord(day: at(-24), wakeTime: at(-17))
        XCTAssertEqual(calculate(wake: otherDay).first?.unavailableReason, .missingRecord)
    }

    func testNoRecordsOrPredictionDataProducesNeutralPlaceholdersNotFallbackTimes() {
        let items = calculate()
        XCTAssertEqual(items.map(\.kind), [.wake, .plan])
        XCTAssertTrue(items.allSatisfy { $0.visualState == .unavailable })
        XCTAssertTrue(items.allSatisfy { $0.time == nil && $0.durationMinutes == nil && $0.elapsedMinutes == nil })
        XCTAssertTrue(items.allSatisfy { $0.source == .unavailable })
        XCTAssertFalse(items.contains { $0.kind == .nap(index: 1) || $0.kind == .bedtime })
    }

    func testUnverifiedPredictionsNeverExposeTimeOrBecomeUpcoming() throws {
        for hour in [10.0, 13.0] {
            let result = try XCTUnwrap(calculate(proposals: [proposal("prediction", hour: hour)]).first { $0.source == .estimate })
            XCTAssertEqual(result.visualState, .unavailable)
            XCTAssertEqual(result.unavailableReason, .eligibilityUnverified)
            XCTAssertNil(result.time)
            XCTAssertNil(result.durationMinutes)
            XCTAssertFalse(result.isActive || result.isFuture)
        }
    }

    func testDefaultAndGeneralGuidanceNeverBecomeRecordedOrEligibleEvents() throws {
        for source in [SleepTimelineProposal.Source.defaultValue, .guidance] {
            for hour in [7.0, 18.0] {
                let result = try XCTUnwrap(calculate(proposals: [proposal("reference", hour: hour, source: source, kind: .wake)], verified: true)
                    .first { $0.id == "proposal:reference" })
                XCTAssertEqual(result.source, source == .defaultValue ? .defaultValue : .guidance)
                XCTAssertEqual(result.visualState, .unavailable)
                XCTAssertEqual(result.unavailableReason, .notAnObservation)
                XCTAssertNil(result.time)
                XCTAssertTrue(result.usesDashedConnector)
            }
        }
    }

    func testVerifiedEstimatesChooseExactlyOneChronologicalNextThenFuture() {
        let items = calculate(proposals: [proposal("bedtime", hour: 20, kind: .bedtime),
            proposal("nap-2", hour: 16, kind: .nap(index: 2)), proposal("nap-1", hour: 13)], verified: true)
        let estimates = items.filter { $0.source == .estimate }
        XCTAssertEqual(estimates.map(\.id), ["proposal:nap-1", "proposal:nap-2", "proposal:bedtime"])
        XCTAssertEqual(estimates.map(\.visualState), [.next, .future, .future])
        XCTAssertTrue(estimates.allSatisfy { $0.isFuture && $0.usesDashedConnector && !$0.isActive })
        XCTAssertTrue(estimates.allSatisfy { $0.durationMinutes == nil && $0.observedEnd == nil && $0.elapsedMinutes == nil })
    }

    func testPastAndExactlyDuePredictionsStayUnavailableNotCompletedOrActive() {
        let proposals = [proposal("past", hour: 10), proposal("due", hour: 12), proposal("upcoming", hour: 14)]
        let items = calculate(proposals: proposals, verified: true).filter { $0.source == .estimate }
        XCTAssertEqual(items.map(\.visualState), [.unavailable, .unavailable, .next])
        XCTAssertEqual(items.map(\.unavailableReason), [.overdue, .overdue, nil])
        XCTAssertEqual(items[0].time, at(10)) // Still identified as an overdue estimate, not an observation.
        XCTAssertFalse(items.contains { $0.visualState == .completed || $0.visualState == .active })
    }

    func testElapsedAndPresentationTransitionUseExplicitReferenceDate() throws {
        let ongoing = SleepRecord(date: at(11), duration: 0, isOngoing: true)
        XCTAssertEqual(try item(ongoing, in: calculate(records: [ongoing])).elapsedMinutes, 60)
        XCTAssertEqual(try item(ongoing, in: calculate(records: [ongoing], now: at(12.5))).elapsedMinutes, 90)
        let prediction = proposal("next", hour: 13)
        XCTAssertEqual(calculate(proposals: [prediction], verified: true).last?.visualState, .next)
        let later = calculate(proposals: [prediction], verified: true, now: at(14))
        XCTAssertEqual(later.last?.visualState, .unavailable)
        XCTAssertEqual(later.last?.unavailableReason, .overdue)
    }

    func testVariableNapsAndRecordedNightAreNotTruncated() {
        let naps = (1...5).map { SleepRecord(date: at(Double($0)), duration: 20) }
        let night = SleepRecord(date: at(6), duration: 120, kind: .nightSleep)
        let items = calculate(records: Array(naps.reversed()) + [night])
        let recorded = items.filter { if case .recorded = $0.source { return true }; return false }
        XCTAssertEqual(recorded.count, 6)
        XCTAssertEqual(recorded.map(\.kind), (1...5).map { SleepTimelineItem.Kind.nap(index: $0) } + [.bedtime])
        XCTAssertTrue(recorded.allSatisfy { $0.visualState == .completed })
    }

    func testEligiblePlanningEventsAlsoHaveNoFourNodeLimit() {
        let plans = (1...6).map { proposal("nap-\($0)", hour: 12 + Double($0), kind: .nap(index: $0)) }
        let items = calculate(proposals: plans + [proposal("bedtime", hour: 21, kind: .bedtime)], verified: true)
        let estimates = items.filter { $0.source == .estimate }
        XCTAssertEqual(estimates.count, 7)
        XCTAssertEqual(estimates.filter { $0.visualState == .next }.count, 1)
        XCTAssertEqual(estimates.filter { $0.visualState == .future }.count, 6)
        XCTAssertEqual(estimates.last?.kind, .bedtime)
    }

    func testInvalidNapDoesNotIncrementConfirmedNapSequence() throws {
        let unknown = SleepRecord(date: at(8), duration: 0)
        let valid = SleepRecord(date: at(9), duration: 30)
        let items = calculate(records: [unknown, valid])
        XCTAssertEqual(try item(unknown, in: items).kind, .nap(index: nil))
        XCTAssertEqual(try item(valid, in: items).kind, .nap(index: 1))
    }

    func testAwakeGapRequiresObservedEndNotOngoingOrMissingEnd() throws {
        let wake = DailyWakeRecord(day: day, wakeTime: at(7))
        let completed = SleepRecord(date: at(8), duration: 30)
        let ongoing = SleepRecord(date: at(10), duration: 0, isOngoing: true)
        let items = calculate(records: [completed, ongoing], wake: wake,
            proposals: [proposal("future", hour: 14)], verified: true)
        XCTAssertEqual(try item(completed, in: items).awakeBeforeMinutes, 60)
        XCTAssertEqual(try item(ongoing, in: items).awakeBeforeMinutes, 90)
        XCTAssertNil(items.last?.awakeBeforeMinutes, "Do not guess when ongoing sleep will end.")
    }

    func testCrossMidnightNightAndAttachedBreakStayOnStartSleepDay() throws {
        let night = SleepRecord(date: at(23), duration: 480, kind: .nightSleep)
        let awake = SleepRecord(date: at(25), duration: 20, kind: .break, parentNapID: night.id)
        let tomorrowNap = SleepRecord(date: at(34), duration: 30)
        let records = [night, awake, tomorrowNap]
        let selected = calculate(records: records, now: at(36), selectedDay: day)
        let result = try item(night, in: selected)
        XCTAssertEqual(result.sleepDay, day)
        XCTAssertEqual(result.time, at(23))
        XCTAssertEqual(result.observedEnd, at(31))
        XCTAssertEqual(result.durationMinutes, 460)
        XCTAssertFalse(selected.contains { $0.source == .recorded(tomorrowNap.id) })
        let nextDay = calculate(records: records, now: at(36))
        XCTAssertFalse(nextDay.contains { $0.source == .recorded(night.id) })
        XCTAssertEqual(try item(tomorrowNap, in: nextDay).kind, .nap(index: 1))
    }

    func testOngoingNightRemainsActiveAfterMidnightOnItsOriginalSleepDay() throws {
        let night = SleepRecord(date: at(23), duration: 0, kind: .nightSleep, isOngoing: true)
        let result = try item(night, in: calculate(records: [night], now: at(25), selectedDay: day))
        XCTAssertEqual(result.visualState, .active)
        XCTAssertEqual(result.sleepDay, day)
        XCTAssertEqual(result.elapsedMinutes, 120)
        XCTAssertNil(result.observedEnd)
    }

    func testPreviousDayOngoingNightCarriesOverAsContextWithoutReassignment() throws {
        let night = SleepRecord(date: at(23), duration: 0, kind: .nightSleep, isOngoing: true)
        let before = try item(night, in: calculate(records: [night], now: at(23.5)))
        let after = try item(night, in: calculate(records: [night], now: at(25)))
        XCTAssertEqual(before.id, after.id)
        XCTAssertFalse(before.isCarryover)
        XCTAssertTrue(after.isCarryover)
        XCTAssertEqual(after.visualState, .active)
        XCTAssertEqual(after.sleepDay, day)
        XCTAssertEqual(after.time, night.date)
        XCTAssertEqual(after.elapsedMinutes, 120)
        XCTAssertNil(after.observedEnd)
        XCTAssertNil(after.durationMinutes)
        XCTAssertEqual(after.source, .recorded(night.id))
    }

    func testCompletingCarryoverRemovesContextButKeepsOriginalDayHistory() throws {
        let night = SleepRecord(date: at(23), duration: 180, kind: .nightSleep)
        XCTAssertFalse(calculate(records: [night], now: at(27)).contains { $0.source == .recorded(night.id) })
        let original = try item(night, in: calculate(records: [night], now: at(27), selectedDay: day))
        XCTAssertEqual(original.visualState, .completed)
        XCTAssertFalse(original.isCarryover)
        XCTAssertEqual(original.sleepDay, day)
        XCTAssertEqual(original.durationMinutes, 180)
    }

    func testCarryoverDoesNotInflateCurrentDayNapNumberOrIncludeOlderUnclosedRecords() throws {
        let first = SleepRecord(date: at(20), duration: 30)
        let carryover = SleepRecord(date: at(23.5), duration: 0, isOngoing: true)
        let current = SleepRecord(date: at(25), duration: 30)
        let stale = SleepRecord(date: at(-1), duration: 0, kind: .nightSleep, isOngoing: true)
        let items = calculate(records: [first, carryover, current, stale], now: at(27))
        XCTAssertEqual(try item(carryover, in: items).kind, .nap(index: 2))
        XCTAssertEqual(try item(current, in: items).kind, .nap(index: 1))
        XCTAssertFalse(items.contains { $0.source == .recorded(first.id) || $0.source == .recorded(stale.id) })
    }

    func testCarryoverUsesCalendarPreviousDayAcrossDaylightSavingTransition() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let now = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 1)))
        let night = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true)
        let items = SleepTimelineCalculator(records: [night], wakeRecord: nil, now: now, calendar: local).calculate()
        let result = try item(night, in: items)
        XCTAssertTrue(result.isCarryover)
        XCTAssertEqual(result.sleepDay, local.startOfDay(for: start))
        XCTAssertEqual(result.elapsedMinutes, 25 * 60 + 30)
        XCTAssertNil(result.observedEnd)
    }

    func testProposalGroupingAndStableOrderingAreDeterministic() {
        let first = proposal("a", hour: 14)
        let second = proposal("b", hour: 14)
        let otherDay = SleepTimelineProposal(id: "tomorrow", kind: .nap(index: 1), sleepDay: at(24), time: at(34), source: .estimate)
        let expected = calculate(proposals: [first, second], verified: true)
        XCTAssertEqual(calculate(proposals: [otherDay, second, first], verified: true), expected)
        XCTAssertEqual(expected.filter { $0.source == .estimate }.map(\.visualState), [.next, .future])
    }
    func testPlanProgressCountsConfirmedCompletionsAndAvailableEventsOnly() {
        let wake = DailyWakeRecord(day: day, wakeTime: at(7))
        let done = SleepRecord(date: at(8), duration: 30)
        let active = SleepRecord(date: at(11), duration: 0, isOngoing: true)
        let invalid = SleepRecord(date: at(10), duration: 0)
        let items = calculate(records: [done, active, invalid], wake: wake,
            proposals: [proposal("next", hour: 14), proposal("future", hour: 20, kind: .bedtime)], verified: true)
        let display = TodayPlanPresentation(items: items)
        XCTAssertEqual(display.completedEventCount, 2)
        XCTAssertEqual(display.availableEventCount, 5)
        XCTAssertEqual(TodayPlanPresentation(items: calculate()).availableEventCount, 0)
        XCTAssertEqual(TodayPlanPresentation(items: calculate()).completedEventCount, 0)
    }

    func testProgressNeverUsesAFixedFourEventDenominator() {
        for count in [1, 3, 5, 8] {
            let naps = (0..<count).map { SleepRecord(date: at(1 + Double($0)), duration: 20) }
            let display = TodayPlanPresentation(items: calculate(records: naps))
            XCTAssertEqual(display.availableEventCount, count)
            XCTAssertEqual(display.completedEventCount, count)
        }
    }

    func testSolidConnectorRequiresConfirmedProgressOnBothSides() {
        let wake = DailyWakeRecord(day: day, wakeTime: at(7))
        let done = SleepRecord(date: at(8), duration: 30)
        let active = SleepRecord(date: at(11), duration: 0, isOngoing: true)
        let items = calculate(records: [done, active], wake: wake,
            proposals: [proposal("next", hour: 14)], verified: true)
        let display = TodayPlanPresentation(items: items)
        XCTAssertTrue(display.isConfirmedConnector(after: 0))
        XCTAssertTrue(display.isConfirmedConnector(after: 1))
        XCTAssertFalse(display.isConfirmedConnector(after: 2), "An ongoing sleep has no observed ending.")
        XCTAssertFalse(display.isConfirmedConnector(after: 3))
        XCTAssertFalse(display.isConfirmedConnector(after: -1))
    }

    func testMissingWakeAndInvalidIntervalCannotCreateSolidProgress() {
        let unknown = SleepRecord(date: at(8), duration: 0)
        let done = SleepRecord(date: at(9), duration: 30)
        let display = TodayPlanPresentation(items: calculate(records: [unknown, done]))
        XCTAssertFalse(display.isConfirmedConnector(after: 0))
        XCTAssertFalse(display.isConfirmedConnector(after: 1))
        XCTAssertEqual(display.completedEventCount, 1)
        XCTAssertEqual(display.availableEventCount, 1)
    }

    func testRelativeTimeRequiresVerifiedFutureEstimateAndStopsWhenOverdue() throws {
        let proposals = [proposal("next", hour: 13)]
        let eligible = calculate(proposals: proposals, verified: true)
        let display = TodayPlanPresentation(items: eligible)
        let estimate = try XCTUnwrap(eligible.first { $0.source == .estimate })
        XCTAssertEqual(display.minutesUntil(estimate, now: at(12)), 60)
        XCTAssertNil(display.minutesUntil(estimate, now: at(13)), "Never display stale countdowns.")
        XCTAssertNil(display.minutesUntil(estimate, now: at(14)))
        let unverified = calculate(proposals: proposals)
        let neutral = try XCTUnwrap(unverified.first { $0.source == .estimate })
        XCTAssertNil(TodayPlanPresentation(items: unverified).minutesUntil(neutral, now: at(12)))
        let overdue = calculate(proposals: proposals, verified: true, now: at(14))
        XCTAssertEqual(TodayPlanPresentation(items: overdue).availableEventCount, 0)
    }

    func testEditingAndDeletingRecordReprojectsDurationProgressAndIdentity() throws {
        let original = SleepRecord(date: at(8), duration: 60)
        let updated = SleepRecord(id: original.id, date: at(9), duration: 40)
        let awake = SleepRecord(date: at(9.25), duration: 10, kind: .break, parentNapID: original.id)
        let before = try item(original, in: calculate(records: [original]))
        let afterItems = calculate(records: [updated, awake])
        let after = try item(updated, in: afterItems)
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(after.time, at(9))
        XCTAssertEqual(after.durationMinutes, 30)
        XCTAssertEqual(TodayPlanPresentation(items: afterItems).completedEventCount, 1)
        XCTAssertEqual(TodayPlanPresentation(items: calculate()).completedEventCount, 0)
    }

    func testWakeDeletionRemovesItsProgressWithoutInventingDefaultWake() {
        let done = SleepRecord(date: at(8), duration: 30)
        let wake = DailyWakeRecord(day: day, wakeTime: at(7))
        XCTAssertEqual(TodayPlanPresentation(items: calculate(records: [done], wake: wake)).completedEventCount, 2)
        let deleted = calculate(records: [done])
        XCTAssertEqual(TodayPlanPresentation(items: deleted).completedEventCount, 1)
        XCTAssertNil(deleted.first?.time)
        XCTAssertEqual(deleted.first?.visualState, .unavailable)
    }

    func testHeroAndTimelineAgreeOnActiveNapCompletionAndOvernightCarryover() throws {
        let cases = [SleepRecord(date: at(11), duration: 0, isOngoing: true),
                     SleepRecord(date: at(10), duration: 60),
                     SleepRecord(date: at(-4), duration: 0, kind: .nightSleep, isOngoing: true)]
        for record in cases {
            let hero = TodaySleepHeroModel.make(records: [record], wakeRecords: [], now: at(12),
                calendar: calendar, routine: nil, displayName: "Parent", babyName: "Baby")
            let result = try item(record, in: calculate(records: [record]))
            XCTAssertEqual(hero.record?.id, record.id)
            XCTAssertEqual(result.visualState, record.isOngoing ? .active : .completed)
            XCTAssertEqual(hero.record?.isOngoing, result.isActive)
            if record.isOngoing { XCTAssertNil(result.observedEnd) }
        }
    }

    func testProgressRetainsCarryoverContextWithoutCompletingOrReassigningIt() throws {
        let night = SleepRecord(date: at(-4), duration: 0, kind: .nightSleep, isOngoing: true)
        let items = calculate(records: [night])
        let result = try item(night, in: items)
        XCTAssertTrue(result.isCarryover)
        XCTAssertEqual(result.sleepDay, calendar.startOfDay(for: at(-4)))
        XCTAssertEqual(TodayPlanPresentation(items: items).availableEventCount, 1)
        XCTAssertEqual(TodayPlanPresentation(items: items).completedEventCount, 0)
    }

    func testLocalTimezoneUsesLocalStartDayRatherThanUTCDate() throws {
        var local = calendar
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        let now = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 1)))
        let start = now.addingTimeInterval(-30 * 60)
        let record = SleepRecord(date: start, duration: 20)
        let items = SleepTimelineCalculator(records: [record], wakeRecord: nil, now: now, calendar: local).calculate()
        XCTAssertEqual(try item(record, in: items).sleepDay, local.startOfDay(for: now))
        XCTAssertEqual(TodayPlanPresentation(items: items).completedEventCount, 1)
    }
    private func homePlan(_ records: [SleepRecord], wakes: [DailyWakeRecord] = [], now: Date,
                          routine: TodaySleepHeroModel.Routine? = nil,
                          predictions: [HeroPrediction] = []) -> TodayPlanPresentation {
        let hero = TodaySleepHeroModel.make(records: records, wakeRecords: wakes, now: now,
            calendar: calendar, routine: routine, displayName: "Parent", babyName: "Baby", proposals: predictions)
        return TodayPlanPresentation.make(records: records, wakes: wakes, hero: hero, now: now,
            calendar: calendar, routine: routine)
    }
    private var overnightStart: Date { at(18).addingTimeInterval(45 * 60) }
    private var overnightNow: Date { at(25).addingTimeInterval(55 * 60) }
    private func night() -> SleepRecord {
        SleepRecord(date: overnightStart, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: overnightStart)
    }
    private func wakePrediction(_ night: SleepRecord, now: Date,
                                eligible: HeroPrediction.Eligibility = .verified,
                                source: HeroPrediction.Provenance = .ruleEngine,
                                expires: Date? = nil, anchor: UUID? = nil) -> HeroPrediction {
        .init(kind: .morningWake, sleepKind: .nightSleep, start: nil, end: at(31.25), wakeWindow: nil,
              anchorRecordID: anchor ?? night.id, anchorDate: night.date, provenance: source,
              eligibility: eligible, generatedAt: now, validUntil: expires ?? at(31.25))
    }

    func testUnavailablePredictionsAreIndicatorsRatherThanScheduledNodes() {
        let empty = TodayPlanPresentation(items: calculate())
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.predictionsUnavailable)
        let done = SleepRecord(date: at(8), duration: 30)
        let display = TodayPlanPresentation(items: calculate(records: [done]))
        XCTAssertEqual(display.items.map(\.source), [.recorded(done.id)])
        XCTAssertTrue(display.predictionsUnavailable)
        XCTAssertEqual(display.availableEventCount, 1)
    }

    func testOvernightRoutineKeepsOriginalIDDayAndElapsedWithoutInventedEnd() throws {
        let record = night()
        let display = homePlan([record], now: overnightNow, routine: .init(wakeHour: 7))
        XCTAssertTrue(display.isOvernight)
        XCTAssertEqual(display.items.count, 1)
        let event = try XCTUnwrap(display.items.first)
        XCTAssertEqual(event.id, "record:\(record.id.uuidString)")
        XCTAssertEqual(event.sleepDay, day)
        XCTAssertEqual(event.time, overnightStart)
        XCTAssertEqual(event.elapsedMinutes, 430)
        XCTAssertTrue(event.isCarryover)
        XCTAssertEqual(event.visualState, .active)
        XCTAssertNil(event.observedEnd)
        XCTAssertNil(event.durationMinutes)
        XCTAssertEqual(display.morningWake?.source, .routine)
        XCTAssertEqual(display.morningWake?.time, at(31))
        XCTAssertEqual(display.completedEventCount, 0)
        XCTAssertEqual(display.availableEventCount, 1, "Routine is not an observed or eligible predicted event.")
        XCTAssertFalse(display.isConfirmedConnector(after: 0))
    }

    func testOvernightWithoutRoutineHasNeutralMorningReferenceAndNoTimestamp() {
        let display = homePlan([night()], now: overnightNow)
        XCTAssertEqual(display.morningWake?.source, .unavailable)
        XCTAssertNil(display.morningWake?.time)
        XCTAssertFalse(display.predictionsUnavailable, "Do not repeat prediction descriptions in the two-node horizon.")
        XCTAssertFalse(display.items.contains { $0.kind == .wake || $0.kind == .plan })
    }

    func testVerifiedWakePredictionTakesPriorityOverRoutine() {
        let record = night()
        let display = homePlan([record], now: overnightNow, routine: .init(wakeHour: 7),
            predictions: [wakePrediction(record, now: overnightNow)])
        XCTAssertEqual(display.morningWake?.source, .estimated)
        XCTAssertEqual(display.morningWake?.time, at(31.25))
        XCTAssertEqual(display.availableEventCount, 2)
        XCTAssertEqual(display.items.first?.visualState, .active)
        XCTAssertFalse(display.isConfirmedConnector(after: 0))
    }

    func testUnverifiedStaleLLMAndWrongAnchorWakePredictionsFallBackToRoutine() {
        let record = night()
        let invalid = [wakePrediction(record, now: overnightNow, eligible: .unavailable),
                       wakePrediction(record, now: overnightNow, source: .llm),
                       wakePrediction(record, now: overnightNow, source: .ageGuidance),
                       wakePrediction(record, now: overnightNow, expires: overnightNow),
                       wakePrediction(record, now: overnightNow, anchor: UUID())]
        for prediction in invalid {
            let display = homePlan([record], now: overnightNow, routine: .init(wakeHour: 7), predictions: [prediction])
            XCTAssertEqual(display.morningWake?.source, .routine)
            XCTAssertEqual(display.morningWake?.time, at(31))
            XCTAssertEqual(display.completedEventCount, 0)
        }
        XCTAssertEqual(homePlan([record], now: overnightNow, predictions: [invalid[0]]).morningWake?.source, .unavailable)
    }

    func testMorningGraceKeepsNightActiveAndPastRoutineUnconfirmed() {
        let record = night()
        let routine = TodaySleepHeroModel.Routine(wakeHour: 7, bedHour: 19)
        for now in [at(31.5), at(32), at(35)] {
            let hero = TodaySleepHeroModel.make(records: [record], wakeRecords: [], now: now,
                calendar: calendar, routine: routine, displayName: "Parent", babyName: "Baby")
            XCTAssertEqual(hero.mode, .morningUnconfirmed)
            let display = TodayPlanPresentation.make(records: [record], wakes: [], hero: hero,
                now: now, calendar: calendar, routine: routine)
            XCTAssertEqual(display.items.first?.visualState, .active)
            XCTAssertNil(display.items.first?.observedEnd)
            XCTAssertEqual(display.morningWake?.source, .routine)
            XCTAssertEqual(display.morningWake?.time, at(31), "Do not roll a missed routine into tomorrow.")
            XCTAssertEqual(display.completedEventCount, 0)
        }
    }

    func testSeparateConfirmedWakeReplacesReferenceWithoutClosingUnresolvedNight() {
        let record = night()
        let wake = DailyWakeRecord(day: at(24), wakeTime: at(31.25))
        let display = homePlan([record], wakes: [wake], now: at(32), routine: .init(wakeHour: 7))
        XCTAssertTrue(display.isOvernight)
        XCTAssertNil(display.morningWake)
        XCTAssertEqual(display.items.map(\.source), [.recorded(record.id), .recorded(wake.id)])
        XCTAssertEqual(display.items.map(\.visualState), [.active, .completed])
        XCTAssertNil(display.items[0].observedEnd)
        XCTAssertFalse(display.isConfirmedConnector(after: 0))
        XCTAssertTrue(record.isOngoing)
    }

    func testExplicitWakeWorkflowClosesNightAndReplacesRoutineWithObservedEvents() throws {
        let suite = "TodayPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sleepStore = SleepRecordPersistence(defaults: defaults)
        let wakeStore = DailyWakeRecordPersistence(defaults: defaults)
        let record = night()
        let awake = SleepRecord(date: at(25), duration: 10, kind: .break, parentNapID: record.id)
        XCTAssertTrue(sleepStore.save([record, awake]))
        let storedBefore = defaults.data(forKey: "sleepRecords")
        _ = homePlan(sleepStore.load() ?? [], now: at(32), routine: .init(wakeHour: 7))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), storedBefore)
        XCTAssertNil(wakeStore.load(), "Rendering the morning grace boundary never saves a wake.")
        let result = SleepWakeTimeWorkflow(selectedWakeTime: at(31.25), now: at(32), calendar: calendar,
            wakeRecords: [], sleepRecords: [record, awake], wakePersistence: wakeStore, sleepPersistence: sleepStore).execute()
        XCTAssertTrue(result.wakePersistenceSucceeded && result.sleepPersistenceSucceeded)
        let records = try XCTUnwrap(sleepStore.load())
        let closed = try XCTUnwrap(records.first { $0.id == record.id })
        XCTAssertFalse(closed.isOngoing)
        XCTAssertEqual(closed.observedEnd, at(31.25))
        let display = homePlan(records, wakes: wakeStore.load() ?? [], now: at(32), routine: .init(wakeHour: 7))
        XCTAssertFalse(display.isOvernight)
        XCTAssertNil(display.morningWake)
        XCTAssertEqual(display.items.map(\.visualState), [.completed, .completed])
        XCTAssertEqual(display.items[0].sleepDay, day)
        XCTAssertEqual(display.items[0].durationMinutes, 740)
        XCTAssertEqual(display.items.filter { $0.source == .recorded(record.id) }.count, 1)
        XCTAssertTrue(display.isConfirmedConnector(after: 0))
    }

    func testMidnightChangesHorizonWithoutChangingRecordIdentityOrOwningDay() throws {
        let record = SleepRecord(date: at(23.5), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(23.5))
        let before = homePlan([record], now: at(23.75), routine: .init(wakeHour: 7))
        let after = homePlan([record], now: at(24.25), routine: .init(wakeHour: 7))
        XCTAssertFalse(before.isOvernight)
        XCTAssertTrue(after.isOvernight)
        XCTAssertEqual(before.items.first?.id, after.items.first?.id)
        XCTAssertEqual(after.items.first?.sleepDay, day)
        XCTAssertEqual(after.items.first?.time, record.date)
        XCTAssertEqual(after.items.first?.elapsedMinutes, 45)
    }

    func testActiveNapCrossingUsualBedtimeDoesNotBecomeNightOrOvernight() {
        let nap = SleepRecord(date: at(18.5), duration: 0, isOngoing: true, createdAt: at(18.5))
        let display = homePlan([nap], now: at(19.25), routine: .init(wakeHour: 7, bedHour: 19))
        XCTAssertFalse(display.isOvernight)
        XCTAssertNil(display.morningWake)
        XCTAssertEqual(display.items.first?.kind, .nap(index: 1))
        XCTAssertEqual(display.items.first?.visualState, .active)
        XCTAssertEqual(display.items.first?.elapsedMinutes, 45)
    }

    func testUnclosedNightRemainsContextAfterMoreThanOneCalendarBoundary() {
        let record = night()
        let display = homePlan([record], now: at(49), routine: .init(wakeHour: 7))
        XCTAssertTrue(display.isOvernight)
        XCTAssertEqual(display.items.first?.source, .recorded(record.id))
        XCTAssertEqual(display.items.first?.sleepDay, day)
        XCTAssertEqual(display.morningWake?.time, at(31), "Keep this night's unresolved reference, not a new synthetic cycle.")
    }

    func testDeletingOrEditingNightReprojectsContextWithoutDuplicateIDs() {
        let record = night()
        let edited = SleepRecord(id: record.id, date: at(19), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(19))
        let display = homePlan([edited], now: overnightNow, routine: .init(wakeHour: 7))
        XCTAssertEqual(display.items.count, 1)
        XCTAssertEqual(display.items.first?.time, at(19))
        XCTAssertEqual(display.items.first?.source, .recorded(record.id))
        let deleted = homePlan([], now: overnightNow, routine: .init(wakeHour: 7))
        XCTAssertFalse(deleted.isOvernight)
        XCTAssertNil(deleted.morningWake)
        XCTAssertTrue(deleted.items.isEmpty)
    }

    func testInvalidOrMissingRoutineDoesNotInventSevenAM() {
        for routine in [TodaySleepHeroModel.Routine(wakeHour: -1), .init(wakeHour: 25), .init(wakeHour: 7, wakeMinute: 70)] {
            let display = homePlan([night()], now: overnightNow, routine: routine)
            XCTAssertEqual(display.morningWake?.source, .unavailable)
            XCTAssertNil(display.morningWake?.time)
        }
    }

    func testOvernightHorizonUsesLocalCalendarAcrossDSTAndTimezoneChanges() throws {
        var local = calendar
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let now = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 1)))
        let record = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)
        for zone in ["America/New_York", "Europe/Istanbul"] {
            local.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let routine = TodaySleepHeroModel.Routine(wakeHour: 7)
            let hero = TodaySleepHeroModel.make(records: [record], wakeRecords: [], now: now,
                calendar: local, routine: routine, displayName: "Parent", babyName: "Baby")
            let display = TodayPlanPresentation.make(records: [record], wakes: [], hero: hero,
                now: now, calendar: local, routine: routine)
            XCTAssertTrue(display.isOvernight)
            XCTAssertEqual(display.items.first?.time, start)
            XCTAssertEqual(display.items.first?.sleepDay, local.startOfDay(for: start))
            XCTAssertEqual(display.items.first?.elapsedMinutes, 25 * 60 + 30)
            let morning = try XCTUnwrap(display.morningWake?.time)
            XCTAssertEqual(local.component(.hour, from: morning), 7)
            XCTAssertEqual(local.component(.minute, from: morning), 0)
        }
    }
}
