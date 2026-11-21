import Foundation
import XCTest
@testable import BabySleepTracker

final class LearningEligibilityEvaluatorTests: XCTestCase {
    func testUnreadableStorageBlocksOtherwiseQualifyingEvidence() {
        var evidence = fixture(Array(1...7))
        let readable = evaluate(evidence)
        XCTAssertEqual(readable.status, .eligibleUnderPolicy)
        evidence.storageIsReadable = false

        let unavailable = evaluate(evidence)
        XCTAssertEqual(unavailable.status, .invalidEvidence)
        XCTAssertEqual(unavailable.reasons, [.storageUnavailable])
        XCTAssertEqual(unavailable.qualifyingDayCount, 0)
        XCTAssertTrue(unavailable.dailyResults.isEmpty)
        XCTAssertNotEqual(unavailable.evidenceIdentity, readable.evidenceIdentity)
    }

    private let policy = LearningEligibilityPolicy.engineeringV01

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-11-16T12:00:00Z") }
    private var birth: Date { date("2026-05-01T00:00:00Z") }
    private func label(_ offset: Int, now: Date? = nil, cal: Calendar? = nil) -> Date {
        let cal = cal ?? calendar()
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now ?? self.now))!
    }
    private func time(_ hour: Int, _ day: Date, cal: Calendar) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
    private func sleep(_ number: Int, _ start: Date, _ end: Date?, kind: SleepKind = .dayNap,
                       parent: UUID? = nil, ongoing: Bool = false, duration: Int? = nil) -> LearningSleepEvidence {
        LearningSleepEvidence(record: SleepRecord(id: id(number), date: start,
            duration: duration ?? end.map { Int($0.timeIntervalSince(start) / 60) } ?? 0,
            kind: kind, parentNapID: parent, isOngoing: ongoing, createdAt: start, endDate: end),
            source: .verifiedObservation)
    }
    private func fixture(_ offsets: [Int] = [1], naps: Int = 1,
                         now: Date? = nil, cal: Calendar? = nil) -> LearningEvidenceSnapshot {
        let cal = cal ?? calendar()
        let now = now ?? self.now
        var wakes: [Date: LearningWakeEvidence] = [:]
        for offset in Set(offsets + offsets.map { $0 - 1 }).sorted() {
            let day = label(offset, now: now, cal: cal)
            wakes[day] = LearningWakeEvidence(record: DailyWakeRecord(id: id(1000 + offset), day: day,
                wakeTime: time(7, day, cal: cal)), source: .verifiedObservation)
        }
        var sleeps: [LearningSleepEvidence] = []
        var confirmations: [LearningDaytimeEvidence] = []
        for offset in offsets.sorted() {
            let day = label(offset, now: now, cal: cal)
            let next = label(offset - 1, now: now, cal: cal)
            let night = sleep(2000 + offset, time(21, day, cal: cal), time(7, next, cal: cal), kind: .nightSleep)
            sleeps.append(night)
            wakes[next]!.completedNightID = night.record.id
            var napIDs = Set<UUID>()
            for index in 0..<naps {
                let nap = sleep(3000 + offset * 10 + index, time(9 + index * 2, day, cal: cal),
                    time(10 + index * 2, day, cal: cal))
                sleeps.append(nap)
                napIDs.insert(nap.record.id)
            }
            confirmations.append(LearningDaytimeEvidence(morning: wakes[day]!, following: wakes[next]!,
                coverage: .confirmedComplete, source: .verifiedObservation,
                naps: sleeps.filter { napIDs.contains($0.record.id) }))
        }
        return LearningEvidenceSnapshot(sleeps: sleeps, wakes: wakes.values.sorted { $0.record.day < $1.record.day },
            daytime: confirmations)
    }
    private func evaluate(_ snapshot: LearningEvidenceSnapshot, now: Date? = nil, birth: Date? = nil,
                          policy: LearningEligibilityPolicy? = .engineeringV01,
                          cal: Calendar? = nil) -> LearningEligibilityEvaluation {
        let cal = cal ?? calendar()
        return LearningEligibilityEvaluator(calendar: cal, timeZone: cal.timeZone)
            .evaluate(snapshot, birthDate: birth ?? self.birth, now: now ?? self.now, policy: policy)
    }
    private func day(_ evaluation: LearningEligibilityEvaluation, offset: Int = 1) -> DailyDataQualityResult {
        evaluation.dailyResults.first { $0.day.id == label(offset, now: evaluation.evaluatedAt,
            cal: calendar(evaluation.timeZoneIdentifier)) }!
    }
    private func has(_ evaluation: LearningEligibilityEvaluation, _ reason: LearningEvidenceFinding.Reason,
                     offset: Int = 1) -> Bool {
        day(evaluation, offset: offset).findings.contains { $0.reason == reason }
    }
    private func replaceNight(_ snapshot: inout LearningEvidenceSnapshot, start: Date? = nil,
                              end: Date? = nil, ongoing: Bool = false, duration: Int? = nil,
                              missingEnd: Bool = false) {
        let index = snapshot.sleeps.firstIndex { $0.record.kind == .nightSleep }!
        let old = snapshot.sleeps[index].record
        snapshot.sleeps[index] = sleep(2001, start ?? old.date, missingEnd ? nil : (end ?? old.endDate),
            kind: .nightSleep, ongoing: ongoing, duration: duration)
    }

    func testZeroValidDays() {
        let result = evaluate(fixture([]))
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.qualifyingDayCount, 0)
        XCTAssertEqual(result.dailyResults.count, 21)
        XCTAssertTrue(result.reasons.contains(.noQualifyingDays))
    }
    func testOneThroughSixDaysNeverMeetSevenDayRequirement() {
        for count in 1...6 {
            let result = evaluate(fixture(Array(1...count)))
            XCTAssertEqual(result.qualifyingDayCount, count)
            XCTAssertEqual(result.status, .unavailable)
        }
    }
    func testSevenNonconsecutiveDaysSatisfyAllRecencyConditions() {
        let result = evaluate(fixture([1, 3, 5, 9, 12, 18, 21]))
        XCTAssertEqual(result.status, .eligibleUnderPolicy)
        XCTAssertEqual(result.qualifyingDayCount, 7)
        XCTAssertEqual(result.recentQualifyingDayCount, 3)
        XCTAssertEqual(result.latestQualifyingDayAge, 1)
        XCTAssertEqual(result.requiredDayCount, 7)
    }
    func testExactlySevenConsecutiveDaysAlsoQualify() {
        XCTAssertEqual(evaluate(fixture(Array(1...7))).status, .eligibleUnderPolicy)
    }
    func testSevenCalendarDaysWithUnknownCoverageDoNotQualify() {
        var input = fixture(Array(1...7))
        input.daytime = []
        XCTAssertEqual(evaluate(input).qualifyingDayCount, 0)
    }
    func testManyHistoricalDaysDoNotReplaceRecentEvidence() {
        let result = evaluate(fixture(Array(8...20)))
        XCTAssertEqual(result.qualifyingDayCount, 13)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.reasons.contains(.insufficientRecentDays))
        XCTAssertTrue(result.reasons.contains(.latestQualifyingDayTooOld))
    }
    func testExactRecencyBoundariesAreInclusive() {
        let result = evaluate(fixture([3, 5, 7, 10, 15, 20, 21, 22]))
        XCTAssertEqual(result.status, .eligibleUnderPolicy)
        XCTAssertEqual(result.qualifyingDayCount, 7)
        XCTAssertEqual(result.recentQualifyingDayCount, 3)
        XCTAssertEqual(result.latestQualifyingDayAge, 3)
        XCTAssertEqual(result.historicalWindow?.start, label(21))
        XCTAssertEqual(result.historicalWindow?.end, label(0))
    }
    func testCurrentLocalLabelIsExcludedEvenWithCompletedFixtures() {
        let result = evaluate(fixture([0]))
        XCTAssertEqual(result.qualifyingDayCount, 0)
        XCTAssertFalse(result.dailyResults.contains { $0.day.id == label(0) })
    }
    func testFullyCompletedDayHasObservedNetDuration() {
        let result = day(evaluate(fixture()))
        XCTAssertTrue(result.qualifies)
        XCTAssertEqual(result.napCoverage, .confirmedComplete)
        XCTAssertEqual(result.netSleepSeconds, 11 * 3600)
        XCTAssertTrue(result.findings.isEmpty)
    }
    func testMissingMorningWake() {
        var input = fixture()
        input.wakes.removeAll { $0.record.id == id(1001) }
        XCTAssertTrue(has(evaluate(input), .missingMorningWake))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testMissingNightOnset() {
        var input = fixture()
        input.sleeps.removeAll { $0.record.kind == .nightSleep }
        XCTAssertTrue(has(evaluate(input), .missingNightOnset))
    }
    func testMissingNightCompletion() {
        var input = fixture()
        replaceNight(&input, missingEnd: true)
        XCTAssertTrue(has(evaluate(input), .missingCompletedEnd))
    }
    func testMissingFollowingWakeDoesNotInferItFromNightEnd() {
        var input = fixture()
        input.wakes.removeAll { $0.record.id == id(1000) }
        XCTAssertTrue(has(evaluate(input), .missingFollowingWake))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testOngoingNightCannotFinalizeDay() {
        var input = fixture()
        replaceNight(&input, ongoing: true, missingEnd: true)
        XCTAssertTrue(has(evaluate(input), .ongoingSession))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testIncompleteNapBlocksDay() {
        var input = fixture()
        let index = input.sleeps.firstIndex { $0.record.kind == .dayNap }!
        let old = input.sleeps[index].record
        input.sleeps[index] = sleep(3010, old.date, nil, ongoing: true)
        XCTAssertTrue(has(evaluate(input), .ongoingSession))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testUnknownCoverageIsNotInferredFromNapCount() {
        var input = fixture(naps: 4)
        input.daytime = []
        XCTAssertTrue(has(evaluate(input), .unknownNapCoverage))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testIncompleteCoverageIsDistinctFromUnknownCoverage() {
        var input = fixture()
        let old = input.daytime[0]
        input.daytime = [.init(morningWakeID: old.morningWakeID, followingWakeID: old.followingWakeID,
            coverage: .incomplete, source: .verifiedObservation, napIDs: old.napIDs)]
        XCTAssertTrue(has(evaluate(input), .incompleteNapCoverage))
    }
    func testExplicitlyConfirmedZeroNapsCanQualify() {
        XCTAssertTrue(day(evaluate(fixture(naps: 0))).qualifies)
    }
    func testZeroNapsWithoutConfirmationCannotQualify() {
        var input = fixture(naps: 0)
        input.daytime = []
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testDifferentVerifiedNapCountsDoNotImposeAgeNorms() {
        for count in 0...5 { XCTAssertTrue(day(evaluate(fixture(naps: count))).qualifies) }
    }
    func testNightAfterMidnightBelongsToChronologicalLearningCycle() {
        var input = fixture()
        replaceNight(&input, start: date("2026-11-16T00:30:00Z"))
        let result = day(evaluate(input))
        XCTAssertTrue(result.qualifies)
        XCTAssertEqual(result.day.id, label(1))
        XCTAssertEqual(result.day.nightID, id(2001))
        // Existing accounting keeps that night on its calendar start date.
        let accounting = SleepAccounting(records: input.sleeps.map(\.record), now: now, calendar: calendar())
        XCTAssertFalse(accounting.records(on: label(1)).contains { $0.id == id(2001) })
    }
    func testSharedMorningIsOneCanonicalObservation() {
        let input = fixture([1, 2])
        let result = evaluate(input)
        XCTAssertEqual(input.wakes.count, 3)
        XCTAssertEqual(day(result, offset: 2).day.followingWakeID, day(result).day.morningWakeID)
        XCTAssertEqual(result.qualifyingDayCount, 2)
        XCTAssertEqual(result.dailyResults.filter(\.qualifies).compactMap(\.netSleepSeconds).reduce(0, +), 22 * 3600)
    }
    func testMissingExplicitNightWakeLinkCannotBeReconstructedFromEqualTimes() {
        var input = fixture()
        let index = input.wakes.firstIndex { $0.record.id == id(1000) }!
        input.wakes[index].completedNightID = nil
        XCTAssertTrue(has(evaluate(input), .unverifiedNightWakeLink))
    }
    func testMultipleMorningWakesAreUnresolvedInsteadOfChoosingOne() {
        var input = fixture()
        input.wakes.append(.init(record: .init(id: id(999), day: label(1),
            wakeTime: time(8, label(1), cal: calendar())), source: .verifiedObservation))
        XCTAssertTrue(has(evaluate(input), .ambiguousOwnership))
    }
    func testMissingIntermediateMorningDoesNotBridgeMultipleDays() {
        var input = fixture([1, 2])
        input.wakes.removeAll { $0.record.id == id(1001) }
        XCTAssertEqual(evaluate(input).qualifyingDayCount, 0)
    }
    func testSpringDSTUsesElapsedSeconds() {
        let cal = calendar("America/New_York")
        let clock = date("2026-03-08T16:00:00Z")
        let input = fixture(now: clock, cal: cal)
        let result = evaluate(input, now: clock, birth: date("2025-09-01T00:00:00Z"), cal: cal)
        XCTAssertTrue(day(result).qualifies)
        XCTAssertEqual(day(result).netSleepSeconds, 10 * 3600)
    }
    func testAutumnDSTUsesElapsedSeconds() {
        let cal = calendar("America/New_York")
        let clock = date("2026-11-01T17:00:00Z")
        let result = evaluate(fixture(now: clock, cal: cal), now: clock, cal: cal)
        XCTAssertTrue(day(result).qualifies)
        XCTAssertEqual(day(result).netSleepSeconds, 12 * 3600)
    }
    func testExplicitTimezoneChangesLabelsWithoutRewritingObservations() {
        let input = fixture()
        let utc = evaluate(input)
        let tokyo = evaluate(input, cal: calendar("Asia/Tokyo"))
        XCTAssertNotEqual(utc.evidenceIdentity, tokyo.evidenceIdentity)
        XCTAssertEqual(tokyo.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(utc.qualifyingDayCount, 1)
        XCTAssertEqual(tokyo.qualifyingDayCount, 1)
        XCTAssertEqual(input.sleeps[0].record.date, date("2026-11-15T21:00:00Z"))
        XCTAssertEqual(tokyo, evaluate(input, cal: calendar("Asia/Tokyo")))
    }
    func testLocalMidnightChangesWindowUsingCalendarDays() {
        let cal = calendar("Europe/Istanbul")
        let before = date("2026-11-16T20:59:59Z")
        let after = date("2026-11-16T21:00:00Z")
        let input = fixture([1, 3, 5, 9, 12, 18, 21], now: before, cal: cal)
        XCTAssertNotEqual(evaluate(input, now: before, cal: cal).historicalWindow,
                          evaluate(input, now: after, cal: cal).historicalWindow)
    }
    func testInvalidDurationAndEndBeforeStartAreBlocking() {
        var input = fixture()
        replaceNight(&input, end: date("2026-11-15T20:00:00Z"), duration: -60)
        let result = evaluate(input)
        XCTAssertTrue(has(result, .invalidDuration))
        XCTAssertFalse(day(result).qualifies)
    }
    func testLegacyDurationEndRemainsUnverifiedEvenWhenWrapperClaimsVerified() {
        var input = fixture()
        replaceNight(&input, duration: 600, missingEnd: true)
        XCTAssertTrue(has(evaluate(input), .legacyEndUnverified))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testDuplicateIdentityBlocksAndOrderDoesNotAffectResult() {
        var input = fixture()
        input.sleeps.append(input.sleeps[0])
        let first = evaluate(input)
        input.sleeps.reverse()
        XCTAssertTrue(has(first, .duplicateIdentity))
        XCTAssertEqual(first, evaluate(input))
        XCTAssertNil(day(first).netSleepSeconds)
    }
    func testSemanticDuplicateWithDifferentIdentityBlocks() {
        var input = fixture()
        let night = input.sleeps[0].record
        input.sleeps.append(sleep(999, night.date, night.endDate, kind: .nightSleep))
        XCTAssertTrue(has(evaluate(input), .duplicateEvent))
    }
    func testEveryNestedOverlapIsInspected() {
        var input = fixture(naps: 0)
        for (number, start, end) in [(10, 9, 15), (11, 10, 14), (12, 11, 13)] {
            input.sleeps.append(sleep(number, time(start, label(1), cal: calendar()), time(end, label(1), cal: calendar())))
        }
        let result = evaluate(input)
        XCTAssertEqual(day(result).findings.filter { $0.reason == .overlappingSleep }.count, 3)
        XCTAssertFalse(day(result).qualifies)
    }
    func testOrphanAwakeBreakBlocks() {
        var input = fixture()
        input.sleeps.append(sleep(99, date("2026-11-15T23:00:00Z"), date("2026-11-15T23:10:00Z"),
            kind: .break, parent: id(999)))
        XCTAssertTrue(has(evaluate(input), .orphanBreak))
    }
    func testBreakOutsideParentBlocks() {
        var input = fixture()
        input.sleeps.append(sleep(99, date("2026-11-15T20:00:00Z"), date("2026-11-15T22:00:00Z"),
            kind: .break, parent: id(2001)))
        XCTAssertTrue(has(evaluate(input), .invalidParent))
    }
    func testBreakCannotParentAnotherBreak() {
        var input = fixture()
        input.sleeps += [sleep(98, date("2026-11-15T23:00:00Z"), date("2026-11-15T23:20:00Z"), kind: .break, parent: id(2001)),
                         sleep(99, date("2026-11-15T23:05:00Z"), date("2026-11-15T23:10:00Z"), kind: .break, parent: id(98))]
        XCTAssertTrue(has(evaluate(input), .invalidParent))
    }
    func testOverlappingAttachedAwakeIntervalsWarnAndSubtractUnion() {
        var input = fixture()
        input.sleeps += [sleep(98, date("2026-11-15T23:00:00Z"), date("2026-11-15T23:20:00Z"), kind: .break, parent: id(2001)),
                         sleep(99, date("2026-11-15T23:10:00Z"), date("2026-11-15T23:30:00Z"), kind: .break, parent: id(2001))]
        let result = day(evaluate(input))
        XCTAssertTrue(result.qualifies)
        XCTAssertEqual(result.netSleepSeconds, 11 * 3600 - 30 * 60)
        XCTAssertTrue(result.findings.contains { $0.reason == .overlappingAwakeIntervals && $0.severity == .warning })
    }
    func testMismatchedWakeAndNightEndRequiresResolution() {
        var input = fixture()
        replaceNight(&input, end: date("2026-11-16T06:30:00Z"))
        XCTAssertTrue(has(evaluate(input), .wakeNightMismatch))
    }
    func testFutureWakeCannotQualify() {
        var input = fixture()
        let index = input.wakes.firstIndex { $0.record.id == id(1000) }!
        input.wakes[index] = .init(record: .init(id: id(1000), day: label(0),
            wakeTime: date("2026-11-16T13:00:00Z")), source: .verifiedObservation, completedNightID: id(2001))
        XCTAssertTrue(has(evaluate(input), .futureObservation))
    }
    func testAllNonverifiedSourcesFailClosedForSleepAndWakeAndCoverage() {
        let sources: [LearningEvidenceSource] = [.unknown, .recordedUnverified, .reconstructedLegacy,
            .routineDefault, .predicted, .llmGenerated]
        for source in sources {
            var input = fixture()
            input.sleeps[0].source = source
            XCTAssertFalse(day(evaluate(input)).qualifies)
            XCTAssertTrue(has(evaluate(input), .unverifiedSource))
            input = fixture()
            input.wakes[0].source = source
            XCTAssertFalse(day(evaluate(input)).qualifies)
            XCTAssertTrue(has(evaluate(input), .unverifiedSource))
            input = fixture()
            let old = input.daytime[0]
            input.daytime[0] = .init(morningWakeID: old.morningWakeID, followingWakeID: old.followingWakeID,
                coverage: .confirmedComplete, source: source, napIDs: old.napIDs,
                confirmedEvidenceIdentity: old.confirmedEvidenceIdentity)
            XCTAssertFalse(day(evaluate(input)).qualifies)
            XCTAssertTrue(has(evaluate(input), .unverifiedSource))
        }
    }
    func testLegacyBridgeNeverFabricatesConfirmationOrVerification() {
        let input = fixture(Array(1...14))
        let legacy = LearningEvidenceSnapshot(records: input.sleeps.map(\.record), wakeRecords: input.wakes.map(\.record))
        XCTAssertEqual(evaluate(legacy).qualifyingDayCount, 0)
        XCTAssertTrue(legacy.daytime.isEmpty)
        XCTAssertTrue(legacy.sleeps.allSatisfy { $0.source == .unknown })
        // Legacy phase and DQS cannot enter the pure API or authorize it.
        XCTAssertEqual(DefaultPhaseAgent().currentPhase(ageMonths: 6, trackedDays: 14), .personalized)
        XCTAssertEqual(evaluate(legacy).status, .unavailable)
    }
    func testAddingVerifiedMissingEvidenceRecomputesEligibility() {
        let complete = fixture(Array(1...7))
        var incomplete = complete
        incomplete.daytime.removeLast()
        XCTAssertEqual(evaluate(incomplete).qualifyingDayCount, 6)
        XCTAssertEqual(evaluate(complete).status, .eligibleUnderPolicy)
    }
    func testEditingPreviouslyValidDayRevokesEligibility() {
        var input = fixture(Array(1...7))
        XCTAssertEqual(evaluate(input).status, .eligibleUnderPolicy)
        replaceNight(&input, end: date("2026-11-16T06:00:00Z"))
        XCTAssertEqual(evaluate(input).status, .unavailable)
    }
    func testDeletingQualifyingDayRevokesEligibility() {
        var input = fixture(Array(1...7))
        input.sleeps.removeAll { $0.record.id == id(2001) }
        XCTAssertEqual(evaluate(input).status, .unavailable)
    }
    func testRetroactiveVerifiedEvidenceCanQualifyWithoutLoggingDelayPenalty() {
        var input = fixture([1, 3, 5, 9, 12, 18, 21])
        input.sleeps = input.sleeps.map {
            let r = $0.record
            return .init(record: .init(id: r.id, date: r.date, duration: r.duration, kind: r.kind,
                createdAt: now, endDate: r.endDate), source: .verifiedObservation)
        }
        XCTAssertEqual(evaluate(input).status, .eligibleUnderPolicy)
    }
    func testPassageOfTimeRevokesWithUnchangedEvidence() {
        let input = fixture([3, 5, 7, 10, 15, 20, 21])
        XCTAssertEqual(evaluate(input).status, .eligibleUnderPolicy)
        let tomorrow = calendar().date(byAdding: .day, value: 1, to: now)!
        let result = evaluate(input, now: tomorrow)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.reasons.contains(.latestQualifyingDayTooOld))
    }
    func testPolicyVersionAndParametersParticipateInEvidenceIdentity() {
        let input = fixture(Array(1...7))
        let changed = LearningEligibilityPolicy(version: "engineering-v0.2-test", minimumQualifyingDays: 8,
            historicalDayCount: 21, recentDayCount: 7, minimumRecentQualifyingDays: 3,
            maximumLatestDayAge: 3, supportedAgeMonths: 4...24)
        XCTAssertNotEqual(evaluate(input).evidenceIdentity, evaluate(input, policy: changed).evidenceIdentity)
        XCTAssertEqual(evaluate(input, policy: changed).status, .unavailable)
    }
    func testUnsupportedCurrentAgesDoNotFallBackToProfile() {
        for birthday in ["2026-08-01T00:00:00Z", "2024-10-01T00:00:00Z", "2027-01-01T00:00:00Z"] {
            XCTAssertEqual(evaluate(fixture(), birth: date(birthday)).status, .unsupportedAge)
        }
    }
    func testFourAndTwentyFourMonthsAreSupportedButHistoricalAgeIsChecked() {
        let lower = evaluate(fixture(), birth: date("2026-07-16T12:00:00Z"))
        XCTAssertEqual(lower.status, .unavailable)
        XCTAssertTrue(has(lower, .unsupportedHistoricalAge))
        let upper = evaluate(fixture(), birth: date("2024-11-01T00:00:00Z"))
        XCTAssertTrue(day(upper).qualifies)
    }
    func testUnconfiguredAndInvalidPoliciesFailClosed() {
        XCTAssertEqual(evaluate(fixture(), policy: nil).status, .unconfiguredPolicy)
        let invalid = LearningEligibilityPolicy(version: "", minimumQualifyingDays: 7,
            historicalDayCount: 2, recentDayCount: 7, minimumRecentQualifyingDays: 3,
            maximumLatestDayAge: 3, supportedAgeMonths: 4...24)
        XCTAssertEqual(evaluate(fixture(), policy: invalid).status, .invalidPolicy)
    }
    func testOrderingDoesNotChangeEvaluationOrEvidenceIdentity() {
        var input = fixture(Array(1...7))
        let result = evaluate(input)
        input.sleeps.reverse()
        input.wakes.reverse()
        input.daytime.reverse()
        XCTAssertEqual(evaluate(input), result)
    }
    func testChangedNapSetRequiresNewCoverageConfirmation() {
        var input = fixture()
        input.sleeps.removeAll { $0.record.kind == .dayNap }
        XCTAssertTrue(has(evaluate(input), .staleNapConfirmation))
    }
    func testIdentityIncludesProvenanceLinksAndSubsecondEdits() {
        let original = fixture()
        var changed = original
        changed.wakes[0].completedNightID = id(999)
        XCTAssertNotEqual(evaluate(original).evidenceIdentity, evaluate(changed).evidenceIdentity)
        changed = original
        let r = changed.sleeps[0].record
        changed.sleeps[0] = sleep(2001, r.date.addingTimeInterval(0.001), r.endDate, kind: .nightSleep)
        XCTAssertNotEqual(evaluate(original).evidenceIdentity, evaluate(changed).evidenceIdentity)
    }
    func testFutureSleepObservationIsBlocking() {
        var input = fixture()
        replaceNight(&input, end: date("2026-11-16T13:00:00Z"))
        XCTAssertTrue(has(evaluate(input), .futureObservation))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testWakeDayMustAgreeWithObservedLocalDate() {
        var input = fixture()
        let index = input.wakes.firstIndex { $0.record.id == id(1000) }!
        input.wakes[index] = .init(record: .init(id: id(1000), day: label(0),
            wakeTime: date("2026-11-15T23:30:00Z")), source: .verifiedObservation,
            completedNightID: id(2001))
        XCTAssertTrue(has(evaluate(input), .invalidWakeDay))
    }
    func testDuplicateWakeIdentitiesAndEventsAreBlocking() {
        var input = fixture()
        input.wakes.append(input.wakes[0])
        XCTAssertTrue(has(evaluate(input), .duplicateIdentity))
        XCTAssertTrue(has(evaluate(input), .duplicateEvent))
        XCTAssertFalse(day(evaluate(input)).qualifies)
    }
    func testMultipleNightSessionsNeedResolvedAssociation() {
        var input = fixture()
        input.sleeps.append(sleep(99, date("2026-11-15T19:00:00Z"),
            date("2026-11-15T20:00:00Z"), kind: .nightSleep))
        XCTAssertTrue(has(evaluate(input), .ambiguousOwnership))
    }
    func testNapAfterNightMakesCycleAssociationUnresolved() {
        var input = fixture(naps: 0)
        input.sleeps.append(sleep(99, date("2026-11-16T07:30:00Z"),
            date("2026-11-16T08:00:00Z")))
        // A nap overlapping the night is also contradictory, with all pairs inspected.
        input.sleeps.append(sleep(98, date("2026-11-15T22:00:00Z"),
            date("2026-11-15T22:30:00Z")))
        XCTAssertTrue(has(evaluate(input), .ambiguousOwnership))
    }
    func testNewExplicitCoverageIsNeededAfterNapDeletion() {
        var input = fixture()
        input.sleeps.removeAll { $0.record.kind == .dayNap }
        XCTAssertFalse(day(evaluate(input)).qualifies)
        let old = input.daytime[0]
        input.daytime[0] = .init(morning: input.wakes.first { $0.record.id == old.morningWakeID }!,
            following: input.wakes.first { $0.record.id == old.followingWakeID }!,
            coverage: .confirmedComplete, source: .verifiedObservation, naps: [])
        XCTAssertTrue(day(evaluate(input)).qualifies)
    }
    func testExplicitTimezoneOverridesCalendarTimezone() {
        let input = fixture()
        let evaluator = LearningEligibilityEvaluator(calendar: calendar("Asia/Tokyo"),
            timeZone: TimeZone(identifier: "UTC")!)
        let explicit = evaluator.evaluate(input, birthDate: birth, now: now, policy: policy)
        XCTAssertEqual(explicit, evaluate(input))
    }
    func testAgeReevaluationCrossesUpperSupportedBoundary() {
        let birthday = date("2024-10-17T00:00:00Z")
        let input = fixture()
        XCTAssertNotEqual(evaluate(input, birth: birthday).status, .unsupportedAge)
        let tomorrow = date("2026-11-17T12:00:00Z")
        XCTAssertEqual(evaluate(input, now: tomorrow, birth: birthday).status, .unsupportedAge)
    }
    func testVersionOnlyChangeProducesNewIdentityWithoutChangingQualification() {
        let changed = LearningEligibilityPolicy(version: "engineering-v0.1-reviewed", minimumQualifyingDays: 7,
            historicalDayCount: 21, recentDayCount: 7, minimumRecentQualifyingDays: 3,
            maximumLatestDayAge: 3, supportedAgeMonths: 4...24)
        let input = fixture(Array(1...7))
        XCTAssertEqual(evaluate(input).status, evaluate(input, policy: changed).status)
        XCTAssertNotEqual(evaluate(input).evidenceIdentity, evaluate(input, policy: changed).evidenceIdentity)
    }

    func testHighLegacyDQSDoesNotAuthorizeUnverifiedEvidence() {
        let report = DataQualityReport(score: 100, level: .excellent,
            completenessScore: 100, consistencyScore: 100, rhythmStabilityScore: 100,
            plausibilityScore: 100, plausibilityAnomalyCount: 0, plausibilityWarnings: [],
            timelinessScore: 100, contextRichnessScore: 100, contextSignals: [],
            missingContextSignals: [], averageLoggingDelayMinutes: 0, trackedDays: 14,
            completeDays: 14, consecutiveMissedDays: 0, missingCriticalFields: [], warnings: [],
            confidenceNote: "Legacy diagnostic only")
        let verifiedFixture = fixture(Array(1...14))
        let legacy = LearningEvidenceSnapshot(records: verifiedFixture.sleeps.map(\.record),
            wakeRecords: verifiedFixture.wakes.map(\.record))
        // This diagnostic has no parameter in the evaluator and cannot replace provenance.
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.level, .excellent)
        XCTAssertEqual(evaluate(legacy).status, .unavailable)
        XCTAssertEqual(evaluate(legacy).qualifyingDayCount, 0)
    }

    func testNapTimingEditWithSameIDInvalidatesCoverageConfirmation() {
        var input = fixture()
        let index = input.sleeps.firstIndex { $0.record.kind == .dayNap }!
        let old = input.sleeps[index].record
        input.sleeps[index] = sleep(3010, old.date.addingTimeInterval(300), old.endDate)
        let result = day(evaluate(input))
        XCTAssertFalse(result.qualifies)
        XCTAssertTrue(result.findings.contains { $0.reason == .staleNapConfirmation })
    }
    func testMorningTimingEditWithSameIDInvalidatesZeroNapConfirmation() {
        var input = fixture(naps: 0)
        let index = input.wakes.firstIndex { $0.record.id == id(1001) }!
        let old = input.wakes[index].record
        input.wakes[index] = .init(record: .init(id: old.id, day: old.day,
            wakeTime: old.wakeTime.addingTimeInterval(60)), source: .verifiedObservation)
        let result = day(evaluate(input))
        XCTAssertFalse(result.qualifies)
        XCTAssertTrue(result.findings.contains { $0.reason == .staleNapConfirmation })
    }
    func testDeletedPreviousNightDoesNotInvalidateIndependentFollowingDay() {
        var input = fixture([1, 2])
        input.sleeps.removeAll { $0.record.id == id(2002) }
        let result = evaluate(input)
        XCTAssertFalse(day(result, offset: 2).qualifies)
        XCTAssertTrue(day(result).qualifies)
        XCTAssertEqual(result.qualifyingDayCount, 1)
    }
    func testDisagreedPreviousNightDoesNotInvalidateIndependentFollowingDay() {
        var input = fixture([1, 2])
        let index = input.sleeps.firstIndex { $0.record.id == id(2002) }!
        let old = input.sleeps[index].record
        input.sleeps[index] = sleep(2002, old.date, old.endDate!.addingTimeInterval(-60), kind: .nightSleep)
        let result = evaluate(input)
        XCTAssertTrue(has(result, .wakeNightMismatch, offset: 2))
        XCTAssertFalse(day(result, offset: 2).qualifies)
        XCTAssertTrue(day(result).qualifies)
    }
    func testWindowSnapshotDoesNotNeedNightBeforeFirstLearningDay() {
        var input = fixture([1])
        let index = input.wakes.firstIndex { $0.record.id == id(1001) }!
        input.wakes[index].completedNightID = id(2002)
        XCTAssertTrue(day(evaluate(input)).qualifies)
    }

    func testFreshConfirmationAfterSameIDTimingEditRestoresDay() {
        var input = fixture()
        let index = input.sleeps.firstIndex { $0.record.kind == .dayNap }!
        let old = input.sleeps[index].record
        input.sleeps[index] = sleep(3010, old.date.addingTimeInterval(300), old.endDate)
        XCTAssertFalse(day(evaluate(input)).qualifies)
        input.daytime[0] = .init(morning: input.wakes.first { $0.record.id == id(1001) }!,
            following: input.wakes.first { $0.record.id == id(1000) }!, coverage: .confirmedComplete,
            source: .verifiedObservation, naps: input.sleeps.filter { $0.record.kind == .dayNap })
        XCTAssertTrue(day(evaluate(input)).qualifies)
    }
    func testIDOnlyConfirmationCannotClaimConfirmedCompleteCoverage() {
        var input = fixture()
        let old = input.daytime[0]
        input.daytime[0] = .init(morningWakeID: old.morningWakeID, followingWakeID: old.followingWakeID,
            coverage: .confirmedComplete, source: .verifiedObservation, napIDs: old.napIDs)
        XCTAssertFalse(day(evaluate(input)).qualifies)
        XCTAssertTrue(has(evaluate(input), .staleNapConfirmation))
    }
    func testDeletingOneOfEightDaysLeavesSevenIndependentQualifyingDays() {
        var input = fixture(Array(1...8))
        input.sleeps.removeAll { $0.record.id == id(2002) }
        let result = evaluate(input)
        XCTAssertEqual(result.qualifyingDayCount, 7)
        XCTAssertEqual(result.status, .eligibleUnderPolicy)
        XCTAssertFalse(day(result, offset: 2).qualifies)
        XCTAssertTrue(day(result, offset: 1).qualifies)
    }
    func testCoverageIdentityChangesForTimingButNotLoggingTimeOrPreviousNightLink() {
        let original = fixture()
        let confirmation = original.daytime[0]
        let morning = original.wakes.first { $0.record.id == confirmation.morningWakeID }!
        let following = original.wakes.first { $0.record.id == confirmation.followingWakeID }!
        let naps = original.sleeps.filter { $0.record.kind == .dayNap }
        var linkedMorning = morning
        linkedMorning.completedNightID = id(999)
        XCTAssertEqual(confirmation.confirmedEvidenceIdentity,
            LearningDaytimeEvidence.identity(morning: linkedMorning, following: following, naps: naps))
        let r = naps[0].record
        let laterLogged = LearningSleepEvidence(record: SleepRecord(id: r.id, date: r.date,
            duration: r.duration, kind: r.kind, createdAt: now, endDate: r.endDate), source: .verifiedObservation)
        XCTAssertEqual(confirmation.confirmedEvidenceIdentity,
            LearningDaytimeEvidence.identity(morning: morning, following: following, naps: [laterLogged]))
        let edited = sleep(3010, r.date.addingTimeInterval(0.001), r.endDate)
        XCTAssertNotEqual(confirmation.confirmedEvidenceIdentity,
            LearningDaytimeEvidence.identity(morning: morning, following: following, naps: [edited]))
    }
    func testPolicyRequirementsAreIndependentRatherThanArtificiallyCoupled() {
        let custom = LearningEligibilityPolicy(version: "independent-constraints-test", minimumQualifyingDays: 2,
            historicalDayCount: 21, recentDayCount: 7, minimumRecentQualifyingDays: 3,
            maximumLatestDayAge: 30, supportedAgeMonths: 4...24)
        let enough = evaluate(fixture([1, 3, 5]), policy: custom)
        XCTAssertEqual(enough.status, .eligibleUnderPolicy)
        let tooFewRecent = evaluate(fixture([1, 3]), policy: custom)
        XCTAssertEqual(tooFewRecent.status, .unavailable)
        XCTAssertEqual(tooFewRecent.reasons, [.insufficientRecentDays])
    }

    func testEntireNightMarkedAwakeCannotCountAsCompletedSleepEvidence() {
        var input = fixture()
        let night = input.sleeps.first { $0.record.kind == .nightSleep }!.record
        input.sleeps.append(sleep(99, night.date, night.endDate, kind: .break, parent: night.id))
        let result = day(evaluate(input))
        XCTAssertFalse(result.qualifies)
        XCTAssertTrue(result.findings.contains { $0.reason == .invalidDuration && $0.severity == .blockingIntegrity })
    }
    func testPositiveSubminuteSleepDoesNotIntroduceScientificDurationThreshold() {
        var input = fixture(naps: 0)
        let night = input.sleeps.first { $0.record.kind == .nightSleep }!.record
        input.sleeps.append(sleep(99, night.date, night.endDate!.addingTimeInterval(-0.5),
            kind: .break, parent: night.id))
        let result = day(evaluate(input))
        XCTAssertTrue(result.qualifies)
        XCTAssertEqual(result.netSleepSeconds, 0.5)
    }

    func testNonfiniteEvaluationTimesFailClosedBeforeCalendarArithmetic() {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            let result = evaluate(fixture(), now: Date(timeIntervalSinceReferenceDate: value))
            XCTAssertEqual(result.status, .invalidEvidence)
            XCTAssertEqual(result.reasons, [.invalidTimestamp])
            XCTAssertTrue(result.dailyResults.isEmpty)
        }
    }
    func testNonfiniteObservationTimestampFailsClosed() {
        var input = fixture()
        let old = input.wakes[0].record
        input.wakes[0] = .init(record: .init(id: old.id, day: old.day,
            wakeTime: Date(timeIntervalSinceReferenceDate: .infinity)), source: .verifiedObservation)
        let result = evaluate(input)
        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertEqual(result.reasons, [.invalidTimestamp])
        XCTAssertEqual(result.qualifyingDayCount, 0)
    }

}
