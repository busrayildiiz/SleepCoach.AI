
import XCTest
@testable import BabySleepTracker

final class DaytimePredictionAgentTests: XCTestCase {

    private var profileProvider: MockDaytimeProfileProvider!
    private var agent: DefaultDaytimePredictionAgent!
    private var defaults: TestPrivateDataStore!

    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        return calendar.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: Date()
        )!
    }()

    override func setUp() {
        super.setUp()
        defaults = TestPrivateDataStore()

        defaults.removeObject(forKey: "typicalWakeHour")
        defaults.removeObject(forKey: "typicalWakeMinute")
        defaults.removeObject(forKey: "babyName")

        profileProvider = MockDaytimeProfileProvider()

        agent = DefaultDaytimePredictionAgent(
            profileProvider: profileProvider,
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removeObject(forKey: "typicalWakeHour")
        defaults.removeObject(forKey: "typicalWakeMinute")
        defaults.removeObject(forKey: "babyName")

        agent = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - No Wake Record / Typical Wake Fallback

    func testUsesSavedTypicalWakeTimeWhenNoNapOrWakeRecordExists() {
        defaults.set(7.0, forKey: "typicalWakeHour")
        defaults.set(30.0, forKey: "typicalWakeMinute")

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertTrue(result.usedDefaultWakeTime)
        XCTAssertEqual(result.recommendation.source, .routine)
        XCTAssertNil(result.confidence)
    }

    // MARK: - Last Completed Nap Anchor

    func testUsesLastCompletedNapEndAsPredictionAnchor() {
        let napDate = day(hour: 9, minute: 0)

        let nap = SleepRecord(
            date: napDate,
            duration: 60,
            kind: .dayNap
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [nap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        let expectedAnchor = napDate.addingTimeInterval(60 * 60)
        let expectedNextNap = expectedAnchor.addingTimeInterval(210 * 60)

        XCTAssertEqual(result.nextNapTime, expectedNextNap)

        XCTAssertTrue(result.reasoning.contains {
            $0.contains("last recorded nap end")
        })
    }

    func testBreakDoesNotMoveActualNapEndAnchorEarlier() {
        let napDate = day(hour: 9, minute: 0)

        let nap = SleepRecord(
            id: UUID(),
            date: napDate,
            duration: 120,
            kind: .dayNap
        )

        let wakePeriod = SleepRecord(
            date: napDate.addingTimeInterval(60 * 60),
            duration: 30,
            kind: .break,
            parentNapID: nap.id
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [nap, wakePeriod],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // Wake windows start at the actual interval end, not start + net sleep.
        let expectedAnchor = napDate.addingTimeInterval(120 * 60)
        let expectedNextNap = expectedAnchor.addingTimeInterval(210 * 60)

        XCTAssertEqual(result.nextNapTime, expectedNextNap)
    }

    // MARK: - Ongoing Nap Anchor

    func testOngoingNapUsesEstimatedEndAsAnchor() {
        let ongoingDate = now.addingTimeInterval(-30 * 60)

        let ongoingNap = SleepRecord(
            date: ongoingDate,
            duration: 0,
            kind: .dayNap,
            isOngoing: true
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [ongoingNap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // elapsed = 30
        // estimated end = elapsed + 30 = 60 minutes from start
        let expectedAnchor = ongoingDate.addingTimeInterval(60 * 60)

        let expectedNextNap = expectedAnchor.addingTimeInterval(210 * 60)

        XCTAssertEqual(result.nextNapTime, expectedNextNap)

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("currently sleeping")
            }
        )
    }

    func testOngoingNapUsesMinimumEstimatedDurationWhenElapsedIsSmall() {
        let ongoingDate = now.addingTimeInterval(-5 * 60)

        let ongoingNap = SleepRecord(
            date: ongoingDate,
            duration: 0,
            kind: .dayNap,
            isOngoing: true
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [ongoingNap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // minimum estimated nap duration is 45 minutes
        let expectedAnchor = ongoingDate.addingTimeInterval(45 * 60)
        let expectedNextNap = expectedAnchor.addingTimeInterval(210 * 60)

        XCTAssertEqual(result.nextNapTime, expectedNextNap)
    }

    // MARK: - Wake Record Anchor

    func testUniqueObservedWakeAnchorsPredictionAndDuplicateWakesDoNot() {
        let earlyWake = DailyWakeRecord(day: now, wakeTime: day(hour: 6, minute: 30))
        let latestWake = DailyWakeRecord(day: now, wakeTime: day(hour: 7, minute: 15))
        let observed = agent.predictNextNap(pattern: nil, todayRecords: [], wakeRecords: [latestWake],
                                           ageMonths: 9, trackedDays: 0, now: now)
        XCTAssertEqual(observed.nextNapTime, latestWake.wakeTime.addingTimeInterval(210 * 60))
        XCTAssertEqual(observed.recommendation.source, .recordedEstimate)
        let conflict = agent.predictNextNap(pattern: nil, todayRecords: [], wakeRecords: [earlyWake, latestWake],
                                           ageMonths: 9, trackedDays: 0, now: now)
        XCTAssertNil(conflict.nextNapTime)
        XCTAssertNil(conflict.confidence)
        XCTAssertEqual(conflict.unavailableReason, .conflict)
    }

    // MARK: - Wake Window Blending

    func testUsesBaselineWakeWindowWithoutPattern() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 210)
    }

    func testDescriptivePatternDoesNotShiftAgeWindowAtSevenTrackedDays() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 300
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 210)
        XCTAssertEqual(result.nextNapTime, day(hour: 10, minute: 30))
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertNil(result.confidence)
    }

    func testDescriptivePatternDoesNotShiftAgeWindowAtFourteenTrackedDays() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 300
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 210)
        XCTAssertEqual(result.nextNapTime, day(hour: 10, minute: 30))
        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertNil(result.confidence)
    }

    func testAnImplausiblyShortDescriptivePatternCannotChangeAgeWindow() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 0
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 210)
        XCTAssertEqual(result.nextNapTime, day(hour: 10, minute: 30))
        XCTAssertNil(result.confidence)
    }

    func testAnImplausiblyLongDescriptivePatternCannotChangeAgeWindow() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 1000
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 210)
        XCTAssertEqual(result.nextNapTime, day(hour: 10, minute: 30))
        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertNil(result.confidence)
    }

    // MARK: - Expected Nap Duration

    func testExpectedDurationUsesSeventyFivePercentOfProfileMaximumWithoutPattern() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        // 120 * 0.75 = 90
        XCTAssertEqual(
            result.expectedDurationMinutes,
            90
        )
    }

    func testExpectedDurationKeepsAgeReferenceWithFirstNapPattern() {
        let pattern = makePattern(
            averageNapDurationMinutes: 100
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertEqual(
            result.expectedDurationMinutes,
            90
        )
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
    }

    func testExpectedDurationKeepsAgeReferenceAfterAnObservedNap() {
        let pattern = makePattern(
            averageNapDurationMinutes: 100
        )

        let firstNap = SleepRecord(
            date: day(hour: 8),
            duration: 60,
            kind: .dayNap
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [firstNap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertEqual(
            result.expectedDurationMinutes,
            90
        )
    }

    func testAnImplausiblePatternNapDurationCannotReplaceAgeReference() {
        let pattern = makePattern(
            averageNapDurationMinutes: 20
        )

        let firstNap = SleepRecord(
            date: day(hour: 8),
            duration: 60,
            kind: .dayNap
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [firstNap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(
            result.expectedDurationMinutes,
            90
        )
        XCTAssertEqual(result.recommendation.limitation, .incomplete)
    }

    // MARK: - Prediction Mode

    func testPredictionModeIsAgeBaselineForZeroToSixTrackedDays() throws {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 6,
            now: now
        )

        let nextNapTime = try XCTUnwrap(result.nextNapTime)
        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertEqual(
            result.windowStart,
            nextNapTime.addingTimeInterval(-20 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            nextNapTime.addingTimeInterval(20 * 60)
        )
    }

    func testGeneralWindowStaysUnchangedAfterSevenTrackedDays() throws {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        let nextNapTime = try XCTUnwrap(result.nextNapTime)
        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertNil(result.confidence)
        XCTAssertEqual(
            result.windowStart,
            nextNapTime.addingTimeInterval(-20 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            nextNapTime.addingTimeInterval(20 * 60)
        )
    }

    func testFourteenTrackedDaysWithoutAnAnchorKeepGeneralGuidance() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertNil(result.confidence)
    }

    func testFourteenTrackedDaysWithAPatternKeepGeneralWindow() throws {
        let pattern = makePattern()

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        let nextNapTime = try XCTUnwrap(result.nextNapTime)
        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertNil(result.confidence)
        XCTAssertEqual(
            result.windowStart,
            nextNapTime.addingTimeInterval(-20 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            nextNapTime.addingTimeInterval(20 * 60)
        )
    }

    // MARK: - Confidence

    func testMissingAnchorWithholdsDatedPredictionAndConfidence() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertNil(result.confidence)
        XCTAssertNil(result.nextNapTime)
        XCTAssertEqual(result.generalWakeWindow, 180...240)
    }

    func testWakeAndDescriptivePatternGiveTimingWithoutConfidence() {
        let pattern = makePattern()

        let wake = DailyWakeRecord(
            day: now,
            wakeTime: day(hour: 7)
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [wake],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertNil(result.confidence)
        XCTAssertEqual(result.nextNapTime, day(hour: 10, minute: 30))
        XCTAssertEqual(result.recommendation.limitation, .missing)
    }

    func testOngoingNapEstimateDoesNotClaimConfidence() {
        let ongoingNap = SleepRecord(
            date: now.addingTimeInterval(-10 * 60),
            duration: 0,
            kind: .dayNap,
            isOngoing: true
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [ongoingNap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertNil(result.confidence)
        XCTAssertEqual(result.recommendation.limitation, .unresolved)
        XCTAssertEqual(result.recommendation.source, .activityEstimate)
    }

    // MARK: - Reasoning

    func testReasoningExplainsMissingObservationsAndGeneralGuidance() {
        let result = agent.predictNextNap(pattern: nil, todayRecords: [], wakeRecords: [],
                                          ageMonths: 9, trackedDays: 0, now: now)

        XCTAssertTrue(result.reasoning.contains { $0.contains("Missing observations") })
        XCTAssertTrue(result.reasoning.contains { $0.contains("age-based") })
        XCTAssertNil(result.recommendation.source)
    }

    func testReasoningExplainsWakeOrLastNapAnchor() {
        let nap = SleepRecord(
            date: day(hour: 9),
            duration: 60,
            kind: .dayNap
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [nap],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("last recorded nap end")
            }
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("general age guidance")
            }
        )
    }

    func testObservedWakeReasoningKeepsSourceAndMissingCoverageExplicit() {
        defaults.set(
            "Umay",
            forKey: "babyName"
        )

        let result = agent.predictNextNap(
            pattern: makePattern(),
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertTrue(result.reasoning.contains { $0.contains("recorded wake") && $0.contains("general age guidance") })
        XCTAssertTrue(result.reasoning.contains(SleepPlanningUnavailable.missing.rawValue))
        XCTAssertFalse(result.reasoning.joined().contains("own sleep pattern"))
    }

    func testMissingNameAndPatternDoNotCreatePersonalizedReasoning() {
        defaults.set(
            "   ",
            forKey: "babyName"
        )

        let result = agent.predictNextNap(
            pattern: makePattern(),
            todayRecords: [],
            wakeRecords: [DailyWakeRecord(day: now, wakeTime: day(hour: 7))],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.recommendation.source, .recordedEstimate)
        XCTAssertTrue(result.reasoning.contains { $0.contains("recorded wake") && $0.contains("general age guidance") })
        XCTAssertTrue(result.reasoning.contains(SleepPlanningUnavailable.missing.rawValue))
        XCTAssertFalse(result.reasoning.joined().contains("own sleep pattern"))
    }

    // MARK: - Helpers

    private func makePattern(
        averageWakeWindowMinutes: Int = 210,
        averageNapDurationMinutes: Int = 90
    ) -> BabyPattern {
        BabyPattern(
            averageWakeWindowMinutes: averageWakeWindowMinutes,
            bestFirstNapHour: 10,
            bestNapExtraMinutes: 10,
            averageNapDurationMinutes: averageNapDurationMinutes,
            napCountPerDay: 2,
            averageNightSleepMinutes: 600,
            estimatedBedtimeShiftMinutes: 0,
            wakingWindowTrend: .stable,
            napDurationTrend: .stable,
            sampleSize: 14,
            dataQuality: .good,
            weekOverWeekNapChange: 0
        )
    }

    private func day(
        hour: Int,
        minute: Int = 0
    ) -> Date {
        let calendar = Calendar.current

        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: calendar.startOfDay(for: now)
        )!
    }
}

// MARK: - Mock Profile Provider

private final class MockDaytimeProfileProvider:
    AgeBasedSleepProfileProviding {

    private let profile = AgeBasedSleepProfile(
        ageRange: 9...11,
        totalSleep24hRange: 660...840,
        wakeWindowRange: 180...240,
        morningWakeWindow: 180...210,
        eveningWakeWindow: 210...240,
        expectedNapCount: 2...2,
        maxSingleNapMinutes: 120,
        daytimeSleepRange: 120...180,
        nightSleepRange: 600...720,
        bedtimeHourRange: 18...20,
        lastNapCutoffHour: 16
    )

    func profile(
        forAgeMonths age: Int
    ) -> AgeBasedSleepProfile {
        profile
    }

    func wakeWindowCenter(
        forAgeMonths age: Int
    ) -> Int {
        210
    }

    func eveningWakeWindowCenter(
        forAgeMonths age: Int
    ) -> Int {
        225
    }
}
