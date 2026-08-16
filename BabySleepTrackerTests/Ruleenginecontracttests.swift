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
