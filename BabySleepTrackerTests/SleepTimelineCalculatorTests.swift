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
}
