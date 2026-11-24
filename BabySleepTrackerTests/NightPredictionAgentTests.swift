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
            calendar: calendar,
            defaults: TestPrivateDataStore()
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

    func testMissingAnchorUsesAgeRangeWithoutInventingBedtime() {
        let context = SleepPredictionContext(records: [], wakes: [], evaluation: .init(now: now, calendar: calendar))
        let result = agent.predictBedtime(pattern: nil, todayRecords: [], wakeRecords: [],
                                         ageMonths: 9, trackedDays: 0, now: now, planning: context)
        XCTAssertNil(result.optimalBedtimeStart)
        XCTAssertNil(result.optimalBedtimeEnd)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertNil(result.confidence)
        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertEqual(result.generalBedtimeHours, 18...20)
    }

    // MARK: - Learning Period

    func testUsesCompletedNapForRuleBasedBedtimeDuringLearning() {

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

        // The last recorded nap ends at 16:00. The estimate uses the general evening wake window.

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
                $0.contains("Last recorded nap ended at")
            }
        )
    }

    // MARK: - Recorded Bedtime Estimates

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
                $0.contains("Last recorded nap ended at")
            }
        )
    }

    // MARK: - Minimum Nap Count

    func testUsesOneRecordedNapEndWithoutIncompleteDayDeficitCompensation() {

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

        // The 16:00 recorded end anchors the 210...240 minute age range.
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertNil(result.confidence)

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
                $0.contains("Last recorded nap ended at")
            }
        )
    }

    // MARK: - Ongoing Nap

    func testDoesNotUseOngoingNapAsCompletedNap() {

        let completedNap = makeNap(
            hour: 15,
            duration: 60
        )

        let ongoingNap = makeNap(
            hour: 18,
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

        XCTAssertNil(ongoingNap.observedEnd)
        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertNil(result.optimalBedtimeStart)
        XCTAssertNil(result.optimalBedtimeEnd)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertNil(result.confidence)
        XCTAssertFalse(result.daytimeSubtotalIsReliable)
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

    func testIncompleteDaytimeSubtotalCannotEstablishADeficit() {

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

        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
    }

    func testExpectedNapCountAndMinutesCannotEstablishCoverage() {

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

        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
    }

    func testIncompleteDaytimeSubtotalCannotEstablishASurplus() {

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

        XCTAssertNil(result.daytimeSleepStatus)
        XCTAssertNil(result.overtiredRiskTime)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
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

    func testConfidenceRequiresABedtimeAnchor() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertNil(result.confidence)
    }

    func testRecordedNapAndTrackedDaysDoNotEstablishConfidence() {

        let result = agent.predictBedtime(
            pattern: nil,
            todayRecords: [makeNap(hour: 15, duration: 60)],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertNil(result.confidence)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
    }

    func testMultipleNapEndsDoNotEstablishConfidence() {

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

        XCTAssertNil(result.confidence)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
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

    func testReasoningMentionsAgeGuidanceBeforeEnoughNaps() {

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
                $0.contains("age-based bedtime guidance")
            }
        )
    }

    func testReasoningAfterFourteenTrackedDaysDescribesRecordedNapEnd() {

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
                $0.contains("Last recorded nap ended at")
            }
        )
    }
}
