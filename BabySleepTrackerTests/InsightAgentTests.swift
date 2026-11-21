import XCTest
@testable import BabySleepTracker

final class InsightAgentTests: XCTestCase {

    private let agent = DefaultInsightAgent()

    // MARK: - Helpers

    private func makePattern(
        bestFirstNapHour: Int? = 10,
        bestNapExtraMinutes: Int? = 10,
        averageNapDurationMinutes: Int? = 90,
        sampleSize: Int = 7,
        dataQuality: DataQuality = .good,
        wakingWindowTrend: Trend = .stable,
        napDurationTrend: Trend = .stable
    ) -> BabyPattern {
        BabyPattern(
            averageWakeWindowMinutes: 180,
            bestFirstNapHour: bestFirstNapHour,
            bestNapExtraMinutes: bestNapExtraMinutes,
            averageNapDurationMinutes: averageNapDurationMinutes,
            napCountPerDay: 2,
            averageNightSleepMinutes: 600,
            estimatedBedtimeShiftMinutes: 0,
            wakingWindowTrend: wakingWindowTrend,
            napDurationTrend: napDurationTrend,
            sampleSize: sampleSize,
            dataQuality: dataQuality,
            weekOverWeekNapChange: 0
        )
    }

    // MARK: - Headline

    func testHeadlineForTooYoungPhase() {
        let result = agent.buildInsights(
            phase: .tooYoung,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.headline,
            "General sleep guidance"
        )
    }

    func testHeadlineForBaselinePhase() {
        let result = agent.buildInsights(
            phase: .baseline,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.headline,
            "General sleep guidance"
        )
    }

    func testHeadlineForLearningPhase() {
        let result = agent.buildInsights(
            phase: .learning(day: 6),
            pattern: nil,
            trackedDays: 6,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.headline,
            "General sleep guidance"
        )
    }

    func testLegacyPersonalizedPhaseStillUsesGeneralHeadline() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.headline,
            "General sleep guidance"
        )
        XCTAssertEqual(result.progressMessage, "Recorded on 14 day(s). Daily coverage is unconfirmed.")
    }

    // MARK: - Coach Tip

    func testCoachTipForTooYoungPhase() {
        let result = agent.buildInsights(
            phase: .tooYoung,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Follow Umay's sleep cues and record actual sleep and wake times when you can."
        )
    }

    func testCoachTipForBaselinePhase() {
        let result = agent.buildInsights(
            phase: .baseline,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
    }

    func testLearningPhaseKeepsGuidanceGeneral() {
        let result = agent.buildInsights(
            phase: .learning(day: 5),
            pattern: nil,
            trackedDays: 5,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertEqual(result.progressMessage, "Recorded on 5 day(s). Daily coverage is unconfirmed.")
    }

    func testLegacyLongerNapHintDoesNotChangeCoachTip() {
        let pattern = makePattern(
            bestFirstNapHour: 10,
            bestNapExtraMinutes: 12
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
    }

    func testSmallLegacyNapHintDoesNotChangeCoachTip() {
        let pattern = makePattern(
            bestFirstNapHour: 10,
            bestNapExtraMinutes: 5
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
    }

    func testLegacyPersonalizedPhaseWithoutPatternUsesGeneralCoachTip() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertNil(result.weeklyPattern)
    }

    func testLegacyMidnightSuggestionDoesNotBecomeAdvice() {
        let pattern = makePattern(
            bestFirstNapHour: 0,
            bestNapExtraMinutes: 10
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
    }

    func testLegacyNoonSuggestionDoesNotBecomeAdvice() {
        let pattern = makePattern(
            bestFirstNapHour: 12,
            bestNapExtraMinutes: 10
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        )
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
    }

    // MARK: - Alerts

    func testPoorPatternQualityDoesNotCreateLegacyAlert() {
        let pattern = makePattern(
            dataQuality: .poor
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
    }

    func testBaselineWithoutPatternDoesNotInferMissingWakeAlert() {
        let result = agent.buildInsights(
            phase: .baseline,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertNil(result.weeklyPattern)
    }

    func testLearningPhaseDoesNotInferMissingWakeAlert() {
        let result = agent.buildInsights(
            phase: .learning(day: 4),
            pattern: nil,
            trackedDays: 4,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.progressMessage, "Recorded on 4 day(s). Daily coverage is unconfirmed.")
    }

    func testLegacyPersonalizedPhaseDoesNotInferWakeAlert() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.headline, "General sleep guidance")
    }

    func testTooYoungPhaseDoesNotInferWakeAlert() {
        let result = agent.buildInsights(
            phase: .tooYoung,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertTrue(result.coachTip.contains("sleep cues"))
    }

    func testPoorPatternQualityAndLearningPhaseKeepOnlyRecordedContext() {
        let pattern = makePattern(
            dataQuality: .poor
        )

        let result = agent.buildInsights(
            phase: .learning(day: 6),
            pattern: pattern,
            trackedDays: 6,
            babyName: "Umay"
        )

        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.")
        XCTAssertEqual(result.progressMessage, "Recorded on 6 day(s). Daily coverage is unconfirmed.")
    }

    // MARK: - Weekly Pattern

    func testOneMeasuredNapCanHaveADescriptiveSummary() {
        let pattern = makePattern(
            averageNapDurationMinutes: 45, sampleSize: 1
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 1,
            babyName: "Umay"
        )

        XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 45m.")
        XCTAssertEqual(result.progressMessage, "Recorded on 1 day(s). Daily coverage is unconfirmed.")
    }

    func testWeeklyPatternUsesMeasuredDurationAlongsideLegacyTrends() {
        let pattern = makePattern(
            bestFirstNapHour: 9,
            sampleSize: 7,
            wakingWindowTrend: .increasing,
            napDurationTrend: .decreasing
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.weeklyPattern,
            "Recorded naps averaged 1h 30m."
        )
    }

    func testWeeklyPatternOmitsLegacyStabilityClaims() {
        let pattern = makePattern(
            bestFirstNapHour: 14,
            sampleSize: 7,
            wakingWindowTrend: .stable,
            napDurationTrend: .stable
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.weeklyPattern,
            "Recorded naps averaged 1h 30m."
        )
    }

    func testWeeklyPatternUsesMeasuredNapWhenTrendEvidenceIsInsufficient() {
        let pattern = makePattern(
            bestFirstNapHour: 10,
            sampleSize: 7,
            wakingWindowTrend: .insufficient,
            napDurationTrend: .insufficient
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.weeklyPattern,
            "Recorded naps averaged 1h 30m."
        )
    }

    func testWeeklyPatternIsUnavailableWithoutMeasuredNapDuration() {
        let pattern = makePattern(
            bestFirstNapHour: 9,
            averageNapDurationMinutes: nil,
            sampleSize: 7,
            wakingWindowTrend: .insufficient,
            napDurationTrend: .insufficient
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        XCTAssertNil(result.weeklyPattern)
    }

    // MARK: - Trend Coverage

    func testWeeklyPatternOmitsAllLegacyWakeWindowTrends() {
        let trends: [Trend] = [
            .increasing,
            .decreasing,
            .stable,
            .insufficient
        ]

        for trend in trends {
            let pattern = makePattern(
                bestFirstNapHour: nil,
                sampleSize: 7,
                wakingWindowTrend: trend,
                napDurationTrend: .insufficient
            )

            let result = agent.buildInsights(
                phase: .personalized,
                pattern: pattern,
                trackedDays: 7,
                babyName: "Umay"
            )

            XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.", "\(trend)")
        }
    }

    func testWeeklyPatternOmitsAllLegacyNapTrends() {
        let trends: [Trend] = [
            .increasing,
            .decreasing,
            .stable,
            .insufficient
        ]

        for trend in trends {
            let pattern = makePattern(
                bestFirstNapHour: nil,
                sampleSize: 7,
                wakingWindowTrend: .insufficient,
                napDurationTrend: trend
            )

            let result = agent.buildInsights(
                phase: .personalized,
                pattern: pattern,
                trackedDays: 7,
                babyName: "Umay"
            )

            XCTAssertEqual(result.weeklyPattern, "Recorded naps averaged 1h 30m.", "\(trend)")
        }
    }

    // MARK: - Progress Message

    func testProgressMessageForTooYoungPhase() {
        let result = agent.buildInsights(
            phase: .tooYoung,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.progressMessage,
            "Recorded on 0 day(s). Daily coverage is unconfirmed."
        )
    }

    func testProgressMessageForBaselinePhase() {
        let result = agent.buildInsights(
            phase: .baseline,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.progressMessage,
            "Recorded on 0 day(s). Daily coverage is unconfirmed."
        )
    }

    func testProgressMessageForLearningPhase() {
        let result = agent.buildInsights(
            phase: .learning(day: 8),
            pattern: nil,
            trackedDays: 8,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.progressMessage,
            "Recorded on 8 day(s). Daily coverage is unconfirmed."
        )
    }

    func testFrequentRecordingDoesNotAuthorizePersonalizedGuidance() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: makePattern(sampleSize: 17, dataQuality: .excellent),
            trackedDays: 17,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.progressMessage,
            "Recorded on 17 day(s). Daily coverage is unconfirmed."
        )
        XCTAssertEqual(result.headline, "General sleep guidance")
        XCTAssertEqual(result.coachTip, "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep.")
    }
}
