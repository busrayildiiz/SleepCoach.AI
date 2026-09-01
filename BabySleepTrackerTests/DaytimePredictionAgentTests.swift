
import XCTest
@testable import BabySleepTracker

final class DaytimePredictionAgentTests: XCTestCase {

    private var profileProvider: MockDaytimeProfileProvider!
    private var agent: DefaultDaytimePredictionAgent!

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

        UserDefaults.standard.removeObject(forKey: "typicalWakeHour")
        UserDefaults.standard.removeObject(forKey: "typicalWakeMinute")
        UserDefaults.standard.removeObject(forKey: "babyName")

        profileProvider = MockDaytimeProfileProvider()

        agent = DefaultDaytimePredictionAgent(
            profileProvider: profileProvider
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "typicalWakeHour")
        UserDefaults.standard.removeObject(forKey: "typicalWakeMinute")
        UserDefaults.standard.removeObject(forKey: "babyName")

        agent = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - No Wake Record / Typical Wake Fallback

    func testUsesSavedTypicalWakeTimeWhenNoNapOrWakeRecordExists() {
        UserDefaults.standard.set(7.0, forKey: "typicalWakeHour")
        UserDefaults.standard.set(30.0, forKey: "typicalWakeMinute")

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertTrue(result.usedDefaultWakeTime)
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

        XCTAssertEqual(
            result.nextNapTime.timeIntervalSince(expectedNextNap),
            0,
            accuracy: 1
        )

        XCTAssertTrue(result.reasoning.contains {
            $0.contains("last nap end time")
        })
    }

    func testSubtractsBreakFromLastNapWhenCalculatingAnchor() {
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

        // Net sleep = 120 - 30 = 90 minutes.
        let expectedAnchor = napDate.addingTimeInterval(90 * 60)
        let expectedNextNap = expectedAnchor.addingTimeInterval(210 * 60)

        XCTAssertEqual(
            result.nextNapTime.timeIntervalSince(expectedNextNap),
            0,
            accuracy: 1
        )
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

        XCTAssertEqual(
            result.nextNapTime.timeIntervalSince(expectedNextNap),
            0,
            accuracy: 1
        )

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

        XCTAssertEqual(
            result.nextNapTime.timeIntervalSince(expectedNextNap),
            0,
            accuracy: 1
        )
    }

    // MARK: - Wake Record Anchor

    func testUsesLatestWakeRecordWhenNoNapExists() {
        let earlyWake = DailyWakeRecord(
            day: now,
            wakeTime: day(hour: 6, minute: 30)
        )

        let latestWake = DailyWakeRecord(
            day: now,
            wakeTime: day(hour: 7, minute: 15)
        )

        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [earlyWake, latestWake],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        let expectedNextNap = latestWake.wakeTime.addingTimeInterval(210 * 60)

        XCTAssertEqual(
            result.nextNapTime.timeIntervalSince(expectedNextNap),
            0,
            accuracy: 1
        )

        XCTAssertFalse(result.usedDefaultWakeTime)
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

    func testBlendedWakeWindowUsesObservedPatternAtSevenDays() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 300
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        // baseline = 210
        // weight = 7 / 14 = 0.5
        // blended = 255
        XCTAssertEqual(result.wakeWindowUsed, 255)
    }

    func testBlendedWakeWindowUsesFullyObservedPatternAtFourteenDays() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 300
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.wakeWindowUsed, 285)
    }

    func testBlendedWakeWindowIsClampedToLowerBound() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 0
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // profile lower bound = 180, lower clamp = 150
        XCTAssertEqual(result.wakeWindowUsed, 150)
    }

    func testBlendedWakeWindowIsClampedToUpperBound() {
        let pattern = makePattern(
            averageWakeWindowMinutes: 1000
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        // profile upper bound = 240, upper clamp = 285
        XCTAssertEqual(result.wakeWindowUsed, 285)
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

    func testExpectedDurationUsesPatternAverageForFirstNap() {
        let pattern = makePattern(
            averageNapDurationMinutes: 100
        )

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertEqual(
            result.expectedDurationMinutes,
            100
        )
    }

    func testExpectedDurationSubtractsTenMinutesForLaterNaps() {
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

    func testPatternNapDurationNeverFallsBelowThirtyMinutes() {
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
            30
        )
    }

    // MARK: - Prediction Mode

    func testPredictionModeIsAgeBaselineForZeroToSixTrackedDays() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 6,
            now: now
        )

        XCTAssertEqual(result.mode, .ageBaseline)
        XCTAssertEqual(
            result.windowStart,
            result.nextNapTime.addingTimeInterval(-20 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            result.nextNapTime.addingTimeInterval(20 * 60)
        )
    }

    func testPredictionModeIsBlendedForSevenToThirteenTrackedDays() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 7,
            now: now
        )

        XCTAssertEqual(result.mode, .blended)
        XCTAssertEqual(
            result.windowStart,
            result.nextNapTime.addingTimeInterval(-15 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            result.nextNapTime.addingTimeInterval(15 * 60)
        )
    }

    func testPredictionModeIsBlendedAtFourteenDaysWithoutPattern() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.mode, .blended)
    }

    func testPredictionModeIsPersonalizedAtFourteenDaysWithPattern() {
        let pattern = makePattern()

        let result = agent.predictNextNap(
            pattern: pattern,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertEqual(result.mode, .personalized)
        XCTAssertEqual(
            result.windowStart,
            result.nextNapTime.addingTimeInterval(-10 * 60)
        )
        XCTAssertEqual(
            result.windowEnd,
            result.nextNapTime.addingTimeInterval(10 * 60)
        )
    }

    // MARK: - Confidence

    func testConfidenceForAgeBaselineWithoutSignals() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertEqual(result.confidence, 44)
    }

    func testConfidenceAddsWakeTimeAndPattern() {
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

        // blended: 58
        // wake: +8
        // pattern: +5
        // = 71
        XCTAssertEqual(result.confidence, 71)
    }

    func testConfidenceSubtractsTenForOngoingNap() {
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

        // 44 - 10 = 34
        XCTAssertEqual(result.confidence, 42)
    }

    // MARK: - Reasoning

    func testReasoningExplainsMissingWakeTime() {
        let result = agent.predictNextNap(
            pattern: nil,
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 0,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("using your saved typical wake-up time")
            }
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("age baseline")
            }
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("14 more tracked days")
            }
        )
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
                $0.contains("last nap end time")
            }
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Blending age baseline")
            }
        )
    }

    func testPersonalizedReasoningUsesBabyName() {
        UserDefaults.standard.set(
            "Umay",
            forKey: "babyName"
        )

        let result = agent.predictNextNap(
            pattern: makePattern(),
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Umay's own sleep pattern")
            }
        )
    }

    func testEmptyBabyNameFallsBackToBaby() {
        UserDefaults.standard.set(
            "   ",
            forKey: "babyName"
        )

        let result = agent.predictNextNap(
            pattern: makePattern(),
            todayRecords: [],
            wakeRecords: [],
            ageMonths: 9,
            trackedDays: 14,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains {
                $0.contains("Baby's own sleep pattern")
            }
        )
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
