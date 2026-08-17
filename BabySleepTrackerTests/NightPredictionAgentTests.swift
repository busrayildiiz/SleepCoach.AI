//
//  NightPredictionAgentTests.swift
//  BabySleepTrackerTests
//

import XCTest
@testable import BabySleepTracker

final class NightPredictionAgentTests: XCTestCase {

    // MARK: - Properties

    private var profileProvider: DefaultAgeBasedSleepProfileProvider!
    private var overtiredCalculator: OvertiredCalculator!
    private var agent: DefaultNightPredictionAgent!

    // IMPORTANT:
    // Production code uses Calendar.current inside OvertiredCalculator.
    // The tests must use the same calendar/timezone.
    private let calendar = Calendar.current

    private lazy var now: Date = {
        calendar.date(
            bySettingHour: 20,
            minute: 0,
            second: 0,
            of: Date()
        )!
    }()

    // MARK: - Setup

    override func setUp() {
        super.setUp()

        profileProvider = DefaultAgeBasedSleepProfileProvider()

        // OvertiredCalculator does NOT accept a calendar parameter.
        overtiredCalculator = OvertiredCalculator(
            profileProvider: profileProvider
        )

        agent = DefaultNightPredictionAgent(
            profileProvider: profileProvider,
            overtiredCalculator: overtiredCalculator,
            calendar: calendar
        )
    }

    override func tearDown() {
        agent = nil
        overtiredCalculator = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDate(
        hour: Int,
        minute: Int = 0
    ) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now
        )!
    }

    private func makeNap(
        hour: Int,
        minute: Int = 0,
        duration: Int,
        ongoing: Bool = false
    ) -> SleepRecord {
        SleepRecord(
            id: UUID(),
            date: makeDate(
                hour: hour,
                minute: minute
            ),
            duration: duration,
            kind: .dayNap,
            isOngoing: ongoing
        )
    }

    // MARK: - Profile

    func testNineMonthProfile() {
        let profile = profileProvider.profile(
            forAgeMonths: 9
        )

        XCTAssertEqual(
            profile.ageRange,
            9...11
        )

        XCTAssertEqual(
            profile.expectedNapCount,
            2...2
        )

        XCTAssertEqual(
            profile.eveningWakeWindow,
            210...240
        )

        XCTAssertEqual(
            profile.daytimeSleepRange,
            120...180
        )

        XCTAssertEqual(
            profile.nightSleepRange,
            600...720
        )

        XCTAssertEqual(
            profile.bedtimeHourRange,
            18...20
        )

        XCTAssertEqual(
            profile.lastNapCutoffHour,
            16
        )
    }

    // MARK: - Fixed Bedtime

    func testBeforeFourteenDaysUsesFixedAgeBasedBedtime() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // 18...20 → midpoint = 19:00
        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 18, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 19, minute: 30)
        )

        // Fixed bedtime risk = ideal + 50 min
        XCTAssertEqual(
            result.overtiredRiskTime,
            makeDate(hour: 19, minute: 50)
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Not enough naps completed yet")
            }
        )
    }

    // MARK: - Learning Period

    func testDoesNotUseNapsBeforeFourteenTrackedDays() {

        let firstNap = makeNap(
            hour: 10,
            duration: 60
        )

        let secondNap = makeNap(
            hour: 15,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 13,
            now: now
        )

        // Even though two naps exist,
        // personalized bedtime is unavailable before 14 days.

        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 18, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 19, minute: 30)
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Not enough naps completed yet")
            }
        )
    }

    // MARK: - Personalized Bedtime

    func testUsesLastCompletedNapAfterFourteenTrackedDays() {

        let firstNap = makeNap(
            hour: 10,
            duration: 60
        )

        let secondNap = makeNap(
            hour: 15,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // Last nap:
        // 15:00 + 60 = 16:00
        //
        // 9 month evening WW:
        // 210...240 min
        //
        // earliest = 19:30
        // latest   = 20:00

        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 19, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 20, minute: 0)
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Last nap ended at")
            }
        )
    }

    // MARK: - Minimum Nap Count

    func testDoesNotUseLastNapWhenMinimumNapCountIsNotReached() {

        let onlyNap = makeNap(
            hour: 15,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                onlyNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // 9 months requires minimum 2 naps.
        // Only 1 completed nap exists.
        // Therefore fixed bedtime is used.

        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 18, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 19, minute: 30)
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Not enough naps completed yet")
            }
        )
    }

    // MARK: - Ongoing Nap

    func testDoesNotUseOngoingNapAsCompletedNap() {

        let completedNap = makeNap(
            hour: 10,
            duration: 60
        )

        let ongoingNap = makeNap(
            hour: 15,
            duration: 60,
            ongoing: true
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                completedNap,
                ongoingNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // Only one completed nap exists.
        // Minimum = 2.
        // Therefore fixed bedtime must be used.

        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 18, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 19, minute: 30)
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Not enough naps completed yet")
            }
        )
    }

    // MARK: - Chronological Ordering

    func testUsesChronologicallyLastCompletedNap() {

        let lateNap = makeNap(
            hour: 15,
            duration: 60
        )

        let earlyNap = makeNap(
            hour: 10,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                lateNap,
                earlyNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // Agent sorts completed naps by date.
        // 15:00 nap must be selected.
        //
        // 15:00 + 60 = 16:00
        // 16:00 + 210 = 19:30
        // 16:00 + 240 = 20:00

        XCTAssertEqual(
            result.optimalBedtimeStart,
            makeDate(hour: 19, minute: 30)
        )

        XCTAssertEqual(
            result.optimalBedtimeEnd,
            makeDate(hour: 20, minute: 0)
        )
    }

    // MARK: - Daytime Sleep Status

    func testDaytimeSleepBelowTarget() {

        let nap = makeNap(
            hour: 10,
            duration: 90
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                nap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // Target = 120...180
        // Actual = 90
        // Deficit = 30

        XCTAssertEqual(
            result.daytimeSleepStatus,
            .below(deficitMinutes: 30)
        )
    }

    func testDaytimeSleepOnTrack() {

        let firstNap = makeNap(
            hour: 10,
            duration: 60
        )

        let secondNap = makeNap(
            hour: 14,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertEqual(
            result.daytimeSleepStatus,
            .onTrack
        )
    }

    func testDaytimeSleepAboveTarget() {

        let firstNap = makeNap(
            hour: 9,
            duration: 90
        )

        let secondNap = makeNap(
            hour: 13,
            duration: 120
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // 210 total.
        // Target max = 180.
        // Excess = 30.

        XCTAssertEqual(
            result.daytimeSleepStatus,
            .above(excessMinutes: 30)
        )
    }

    // MARK: - Expected Night Sleep

    func testExpectedNightSleepUsesAgeProfileWithoutPattern() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // 600...720 → midpoint = 660

        XCTAssertEqual(
            result.expectedNightSleepMinutes,
            660
        )
    }

    // MARK: - Confidence

    func testConfidenceStartsAtForty() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertEqual(
            result.confidence,
            40
        )
    }

    func testConfidenceIncreasesWithTrackedDays() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        // 40 + (7 * 2) = 54

        XCTAssertEqual(
            result.confidence,
            54
        )
    }

    func testConfidenceIncludesLastNap() {

        let firstNap = makeNap(
            hour: 10,
            duration: 60
        )

        let secondNap = makeNap(
            hour: 15,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // Base = 68
        // Last nap = +10
        // Total = 78

        XCTAssertEqual(
            result.confidence,
            78
        )
    }

    // MARK: - Last Nap Cutoff

    func testLastNapCutoffForNineMonths() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // 9–11 months → cutoff 16:00

        XCTAssertEqual(
            result.lastNapCutoffTime,
            makeDate(hour: 16, minute: 0)
        )
    }

    // MARK: - Reasoning

    func testReasoningIsNotEmpty() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertFalse(
            result.reasoning.isEmpty
        )
    }

    func testReasoningMentionsEstimatedBedtimeBeforeEnoughNaps() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Not enough naps completed yet")
            }
        )
    }

    func testReasoningMentionsLastNapAfterPersonalizationStarts() {

        let firstNap = makeNap(
            hour: 10,
            duration: 60
        )

        let secondNap = makeNap(
            hour: 15,
            duration: 60
        )

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [
                firstNap,
                secondNap
            ],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Last nap ended at")
            }
        )
    }
}
