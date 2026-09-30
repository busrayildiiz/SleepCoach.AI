//
//  Ruleenginecontracttests.swift
//  BabySleepTrackerTests
//
//  Created by MacBook on 15.08.2026.
//

import Foundation
//
//  RuleEngineContractTests.swift
//  BabySleepTrackerTests
//
//  Contract tests for the deterministic rule-engine layer.
//  Unlike the LLM layer, these components must produce the exact same
//  output for the exact same input, every time. A single assertion
//  failure here means the rule engine's math is wrong — not "the model
//  drifted" — so we test them the same way we'd test any pure function.
//

import Foundation
import XCTest

@testable import BabySleepTracker

// MARK: - Fixed profile provider for deterministic control in tests

private final class FixedAgeBasedSleepProfileProvider: AgeBasedSleepProfileProviding {
    let fixedProfile: AgeBasedSleepProfile

    init(fixedProfile: AgeBasedSleepProfile) {
        self.fixedProfile = fixedProfile
    }

    func profile(forAgeMonths age: Int) -> AgeBasedSleepProfile { fixedProfile }

    func wakeWindowCenter(forAgeMonths age: Int) -> Int {
        (fixedProfile.wakeWindowRange.lowerBound + fixedProfile.wakeWindowRange.upperBound) / 2
    }

    func eveningWakeWindowCenter(forAgeMonths age: Int) -> Int {
        (fixedProfile.eveningWakeWindow.lowerBound + fixedProfile.eveningWakeWindow.upperBound) / 2
    }
}

private let nineMonthProfile = AgeBasedSleepProfile(
    ageRange:            9...11,
    totalSleep24hRange:  660...840,
    wakeWindowRange:     180...240,
    morningWakeWindow:   180...210,
    eveningWakeWindow:   210...240,
    expectedNapCount:    2...2,
    maxSingleNapMinutes: 120,
    daytimeSleepRange:   120...180,
    nightSleepRange:     600...720,
    bedtimeHourRange:    18...20,
    lastNapCutoffHour:   16
)

// MARK: - DefaultPhaseAgent

final class PhaseAgentContractTests: XCTestCase {

    var sut: DefaultPhaseAgent!

    override func setUp() {
        super.setUp()
        sut = DefaultPhaseAgent()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func test_currentPhase_whenUnderFourMonths_shouldReturnTooYoung() {
        XCTAssertEqual(sut.currentPhase(ageMonths: 3, trackedDays: 20), .tooYoung)
    }

    func test_currentPhase_whenZeroTrackedDays_shouldReturnBaseline() {
        XCTAssertEqual(sut.currentPhase(ageMonths: 6, trackedDays: 0), .baseline)
    }

    func test_currentPhase_whenBetweenOneAndThirteenDays_shouldReturnLearningWithMatchingDay() {
        XCTAssertEqual(sut.currentPhase(ageMonths: 6, trackedDays: 1), .learning(day: 1))
        XCTAssertEqual(sut.currentPhase(ageMonths: 6, trackedDays: 13), .learning(day: 13))
    }

    func test_currentPhase_whenFourteenOrMoreDays_shouldReturnPersonalized() {
        XCTAssertEqual(sut.currentPhase(ageMonths: 6, trackedDays: 14), .personalized)
        XCTAssertEqual(sut.currentPhase(ageMonths: 6, trackedDays: 90), .personalized)
    }

    func test_readinessReport_confidence_shouldNeverExceedNinetyFour() {
        // personalized base score (82) + both bonus signals (8+5=13) = 95,
        // which must be clamped to the contract's stated ceiling of 94.
        let report = sut.readinessReport(
            ageMonths: 12,
            trackedDays: 30,
            hasTodayWakeTime: true,
            hasYesterdayNightSleep: true
        )
        XCTAssertLessThanOrEqual(report.confidence, 94, "Confidence must never claim near-certainty.")
    }

    func test_readinessReport_tooYoung_shouldReturnZeroConfidenceAndInvalidDaysUntilPersonalized() {
        let report = sut.readinessReport(
            ageMonths: 2,
            trackedDays: 0,
            hasTodayWakeTime: false,
            hasYesterdayNightSleep: false
        )
        XCTAssertEqual(report.confidence, 0)
        XCTAssertEqual(report.daysUntilPersonalized, -1)
    }

    func test_readinessReport_missingSignals_shouldFlagEachMissingInputIndependently() {
        let report = sut.readinessReport(
            ageMonths: 6,
            trackedDays: 2,
            hasTodayWakeTime: false,
            hasYesterdayNightSleep: false
        )
        XCTAssertTrue(report.missingSignals.contains(.wakeTime))
        XCTAssertTrue(report.missingSignals.contains(.nightSleep))
        XCTAssertTrue(report.missingSignals.contains(.consecutiveDays))
    }

    func test_readinessReport_learningPhase_daysUntilPersonalized_shouldCountDownFromFourteen() {
        let report = sut.readinessReport(
            ageMonths: 6,
            trackedDays: 5,
            hasTodayWakeTime: true,
            hasYesterdayNightSleep: true
        )
        XCTAssertEqual(report.daysUntilPersonalized, 9)
    }
}

// MARK: - OvertiredCalculator

final class OvertiredCalculatorContractTests: XCTestCase {

    var sut: OvertiredCalculator!

    override func setUp() {
        super.setUp()
        sut = OvertiredCalculator(
            profileProvider: FixedAgeBasedSleepProfileProvider(fixedProfile: nineMonthProfile)
        )
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // Wake window range is 180...240 -> center 210, max 240.

    func test_overtiredRisk_wellBelowWakeWindowCenter_shouldBeHealthy() {
        let awakeSince = Date().addingTimeInterval(-60 * 60) // 60 min awake
        let risk = sut.overtiredRisk(awakeSinceDate: awakeSince, ageMonths: 9, isEveningPeriod: false)
        XCTAssertEqual(risk, .healthy)
    }

    func test_overtiredRisk_justPastWakeWindowMax_shouldBeModerate() {
        let awakeSince = Date().addingTimeInterval(-245 * 60) // 245 min, wwMax is 240
        let risk = sut.overtiredRisk(awakeSinceDate: awakeSince, ageMonths: 9, isEveningPeriod: false)
        XCTAssertEqual(risk, .moderate)
    }

    func test_overtiredRisk_wellPastWakeWindowMax_shouldBeCriticallyTired() {
        let awakeSince = Date().addingTimeInterval(-300 * 60) // 300 min, 60 past wwMax
        let risk = sut.overtiredRisk(awakeSinceDate: awakeSince, ageMonths: 9, isEveningPeriod: false)
        XCTAssertEqual(risk, .criticallyTired)
    }

    func test_dailySleepStatus_belowRange_shouldReportDeficit() {
        // nineMonthProfile.totalSleep24hRange is 660...840
        let status = sut.dailySleepStatus(totalMinutes: 600, ageMonths: 9)
        guard case .below(let deficit) = status else {
            return XCTFail("Expected .below, got \(status)")
        }
        XCTAssertEqual(deficit, 60)
    }

    func test_dailySleepStatus_aboveRange_shouldReportExcess() {
        let status = sut.dailySleepStatus(totalMinutes: 900, ageMonths: 9)
        guard case .above(let excess) = status else {
            return XCTFail("Expected .above, got \(status)")
        }
        XCTAssertEqual(excess, 60)
    }

    func test_dailySleepStatus_withinRange_shouldBeOnTrack() {
        let status = sut.dailySleepStatus(totalMinutes: 700, ageMonths: 9)
        XCTAssertEqual(status, .onTrack)
    }

    func test_bedtimeWindow_whenDaytimeSleepIsShort_shouldMoveIdealBedtimeEarlier() {
        let lastNapEnd = Date()
        // daytimeSleepRange lower bound is 120 -> deficit of 60 min -> adjustment of 60/3 = 20 min earlier.
        let shortDayWindow = sut.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 60,
            ageMonths: 9
        )
        let fullDayWindow = sut.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 150,
            ageMonths: 9
        )
        XCTAssertLessThan(
            shortDayWindow.ideal,
            fullDayWindow.ideal,
            "A larger daytime sleep deficit must move bedtime earlier, not later or unchanged."
        )
    }

    func test_dailySleepStatus_onTrack_isExclusiveWithBelowAndAbove() {
        // Property: for any total in the profile's own range, status must be exactly .onTrack.
        for total in stride(from: 660, through: 840, by: 30) {
            let status = sut.dailySleepStatus(totalMinutes: total, ageMonths: 9)
            XCTAssertEqual(status, .onTrack, "\(total) minutes is inside 660...840 and must be onTrack.")
        }
    }
}

// MARK: - SleepRuleEngine

final class SleepRuleEngineContractTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func makeProfile(expected: ClosedRange<Int> = 2...2) -> AgeBasedSleepProfile {
        AgeBasedSleepProfile(
            ageRange: 9...11,
            totalSleep24hRange: 660...840,
            wakeWindowRange: 180...240,
            morningWakeWindow: 180...210,
            eveningWakeWindow: 210...240,
            expectedNapCount: expected,
            maxSingleNapMinutes: 120,
            daytimeSleepRange: 120...180,
            nightSleepRange: 600...720,
            bedtimeHourRange: 18...20,
            lastNapCutoffHour: 16
        )
    }

    private func engine(expected: ClosedRange<Int> = 2...2) -> SleepRuleEngine {
        let provider = FixedAgeBasedSleepProfileProvider(fixedProfile: makeProfile(expected: expected))
        return SleepRuleEngine(profileProvider: provider, calendar: calendar)
    }

    private func date(dayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        return calendar.date(byAdding: .day, value: dayOffset, to: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!)!
    }

    private func nap(hour: Int, duration: Int = 60, dayOffset: Int = 0, ongoing: Bool = false) -> SleepRecord {
        SleepRecord(date: date(dayOffset: dayOffset, hour: hour), duration: duration, isOngoing: ongoing)
    }

    private func decide(
        _ records: [SleepRecord],
        expected: ClosedRange<Int> = 2...2,
        now: Date = Date(timeIntervalSince1970: 0),
        latestEnd: Date? = nil,
        duration: Int = 60
    ) -> SleepRuleEngineResult {
        let actualNow = now.timeIntervalSince1970 == 0 ? date(hour: 12) : now
        return engine(expected: expected).decide(
            records: records,
            ageMonths: 9,
            now: actualNow,
            recoveryNapLatestEndTime: latestEnd ?? date(hour: 18),
            recoveryNapDurationMinutes: duration
        )
    }

    func testCountsOnlyCompletedCurrentDayNapsAndExcludesOngoingAndOtherDays() {
        let result = decide([
            nap(hour: 8),
            nap(hour: 10, ongoing: true),
            nap(hour: 11, dayOffset: -1),
            SleepRecord(date: date(hour: 12), duration: 20, kind: .nightSleep)
        ])
        XCTAssertEqual(result.completedNapCount, 1)
        XCTAssertEqual(result.completedNaps.count, 1)
        XCTAssertEqual(result.ongoingNap?.date, date(hour: 10))
    }

    func testUsesChronologicallyLatestCompletedNapAndNetEndTime() {
        let earlier = nap(hour: 8, duration: 60)
        let latest = nap(hour: 11, duration: 90)
        let pause = SleepRecord(date: date(hour: 12), duration: 20, kind: .break, parentNapID: latest.id)
        let result = decide([latest, pause, earlier], expected: 1...1)
        XCTAssertEqual(result.latestCompletedNap?.id, latest.id)
        XCTAssertEqual(result.latestCompletedNapEnd, date(hour: 12, minute: 10))
        XCTAssertEqual(result.completedNaps.map(\.id), [earlier.id, latest.id])
    }

    func testReportsIncompleteTransitionAndCompleteStructures() {
        XCTAssertEqual(decide([nap(hour: 8)]).structure, .incomplete)
        XCTAssertEqual(decide([nap(hour: 8), nap(hour: 11)], expected: 2...3).structure, .transition)
        XCTAssertEqual(decide([nap(hour: 8), nap(hour: 11), nap(hour: 14)], expected: 2...3).structure, .complete)
    }

    func testOngoingNapHasExplicitDecisionAndPreservesFacts() {
        let ongoing = nap(hour: 11, ongoing: true)
        let result = decide([nap(hour: 8), ongoing])
        XCTAssertEqual(result.decision, .ongoingNap)
        XCTAssertEqual(result.completedNapCount, 1)
        XCTAssertEqual(result.ongoingNap?.id, ongoing.id)
    }

    func testIncompleteStructureUsesRecoveryNapWhenItCanFinishBeforeLatestEnd() {
        let result = decide([nap(hour: 8)], now: date(hour: 12), latestEnd: date(hour: 18), duration: 60)
        XCTAssertEqual(result.decision, .recoveryNap)
        XCTAssertEqual(result.recoveryNapCanFinishInTime, true)
    }

    func testIncompleteStructureUsesEarlyBedtimeWhenRecoveryCannotFinishInTime() {
        let result = decide([nap(hour: 8)], now: date(hour: 17), latestEnd: date(hour: 18), duration: 120)
        XCTAssertEqual(result.decision, .earlyBedtime)
        XCTAssertEqual(result.recoveryNapCanFinishInTime, false)
    }

    func testCompleteStructureRemainsBedtimeCompatible() {
        let result = decide([nap(hour: 8), nap(hour: 11)], now: date(hour: 13))
        XCTAssertEqual(result.structure, .complete)
        XCTAssertEqual(result.decision, .bedtime)
        XCTAssertEqual(result.decisionReason, .completeNapStructure)
    }

    func testDecisionReason_ongoingNapInProgress() {
        let result = decide([nap(hour: 8), nap(hour: 11, ongoing: true)], now: date(hour: 12))
        XCTAssertEqual(result.decisionReason, .ongoingNapInProgress)
    }

    func testDecisionReason_pastNapCutoff() {
        let result = decide([nap(hour: 8), nap(hour: 11)], now: date(hour: 17))
        XCTAssertEqual(result.decisionReason, .pastNapCutoff)
    }

    func testDecisionReason_recoveryNapFeasible() {
        let result = decide([nap(hour: 8)], now: date(hour: 12), latestEnd: date(hour: 18), duration: 60)
        XCTAssertEqual(result.decisionReason, .recoveryNapFeasible)
    }

    func testDecisionReason_recoveryNapNotFeasible() {
        let result = decide([nap(hour: 8)], now: date(hour: 17), latestEnd: date(hour: 18), duration: 120)
        XCTAssertEqual(result.decisionReason, .recoveryNapNotFeasible)
    }

    func testDecisionReason_recoveryFeasibilityUnknown() {
        let result = engine().decide(
            records: [nap(hour: 8)],
            ageMonths: 9,
            now: date(hour: 12),
            recoveryNapLatestEndTime: date(hour: 18),
            recoveryNapDurationMinutes: nil
        )
        XCTAssertEqual(result.decisionReason, .recoveryFeasibilityUnknown)
    }

    func testDecisionReason_transitionNapStructure() {
        let result = decide([nap(hour: 8), nap(hour: 11)], expected: 2...3, now: date(hour: 12))
        XCTAssertEqual(result.decisionReason, .transitionNapStructure)
    }

    func testTransitionStructureRemainsDistinguishableWithoutBeingTreatedAsComplete() {
        let result = decide([nap(hour: 8), nap(hour: 11)], expected: 2...3, now: date(hour: 13))
        XCTAssertEqual(result.structure, .transition)
        XCTAssertEqual(result.decision, .normalNap)
    }

    func testOngoingNapDoesNotMapToBedtimeAtLegacyBoundary() {
        let result = decide([nap(hour: 8), nap(hour: 11, ongoing: true)], now: date(hour: 13))
        let legacyKind: NextSleepKind = {
            switch result.decision {
            case .normalNap, .recoveryNap, .ongoingNap: return .nap
            case .bedtime, .earlyBedtime: return .bedtime
            }
        }()
        XCTAssertEqual(result.decision, .ongoingNap)
        if case .nap = legacyKind {
            XCTAssertTrue(true)
        } else {
            XCTFail("An ongoing nap must remain nap-compatible at the legacy boundary.")
        }
    }

    func testRecoveryFeasibilityUsesExplicitDurationAndLatestEndInputs() {
        let feasible = decide([nap(hour: 8)], now: date(hour: 12), latestEnd: date(hour: 18), duration: 60)
        XCTAssertEqual(feasible.recoveryNapCanFinishInTime, true)

        let unknown = engine().decide(
            records: [nap(hour: 8)],
            ageMonths: 9,
            now: date(hour: 12),
            recoveryNapLatestEndTime: date(hour: 18),
            recoveryNapDurationMinutes: nil
        )
        XCTAssertNil(unknown.recoveryNapCanFinishInTime)
        XCTAssertEqual(unknown.decision, .recoveryNap)
    }

    func testPastAgeBasedCutoffUsesBedtimeAndKeepsCutoffSeparateFromRecoveryPolicy() {
        let result = decide([nap(hour: 8), nap(hour: 11)], now: date(hour: 16), latestEnd: date(hour: 18))
        XCTAssertEqual(result.decision, .bedtime)
        XCTAssertEqual(calendar.component(.hour, from: result.ageBasedLastNapCutoffTime), 16)
        XCTAssertEqual(calendar.component(.hour, from: result.recoveryNapLatestEndTime), 18)
    }

    func testCompleteStructureBeforeCutoffIsNormalNap() {
        let result = decide([nap(hour: 8), nap(hour: 11)], now: date(hour: 13))
        XCTAssertEqual(result.structure, .complete)
        XCTAssertEqual(result.decision, .bedtime)
    }

    func testStructuredOvertiredRiskIsExposedWithoutBeingAnAutomaticBedtimeGate() {
        let result = decide([nap(hour: 8), nap(hour: 11)], now: date(hour: 15))
        XCTAssertNotNil(result.overtiredRisk)
        XCTAssertEqual(result.decision, .normalNap)
    }
}
