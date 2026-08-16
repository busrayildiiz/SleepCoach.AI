import XCTest
@testable import BabySleepTracker

final class InsightAgentTests: XCTestCase {

    private let agent = DefaultInsightAgent()

    // MARK: - Helpers

    private func makePattern(
        bestFirstNapHour: Int? = 10,
        bestNapExtraMinutes: Int? = 10,
        sampleSize: Int = 7,
        dataQuality: DataQuality = .good,
        wakingWindowTrend: Trend = .stable,
        napDurationTrend: Trend = .stable
    ) -> BabyPattern {
        BabyPattern(
            averageWakeWindowMinutes: 180,
            bestFirstNapHour: bestFirstNapHour,
            bestNapExtraMinutes: bestNapExtraMinutes,
            averageNapDurationMinutes: 90,
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
            "4 aylıktan itibaren aktif olur"
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
            "Öğrenme başlasın!"
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
            "6/14 — örüntü oluşuyor"
        )
    }

    func testHeadlineForPersonalizedPhase() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.headline,
            "Kişiselleştirilmiş mod aktif ✓"
        )
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
            "Umay henüz 4 aylıktan küçük. Bu dönemde doğal ritmine göre beslen ve uyu."
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
            "İlk uykuyu logla. Uyanma saatini de ekleyerek tahminleri güçlendir."
        )
    }

    func testCoachTipForLearningPhase() {
        let result = agent.buildInsights(
            phase: .learning(day: 5),
            pattern: nil,
            trackedDays: 5,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Harika gidiyorsun! 9 gün daha takip edince kişiselleştirilmiş tahminler başlıyor."
        )
    }

    func testPersonalizedCoachTipUsesPatternWhenExtraMinutesAreMeaningful() {
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
            "Umay'in en uzun napları saat 10 AM civarında başlıyor — ortalamadan ~12 dk daha uzun."
        )
    }

    func testPersonalizedCoachTipUsesFallbackWhenExtraMinutesAreSmall() {
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
            "Tahminler Umay'in kendi ritmine göre üretiliyor. Her kayıt sistemi daha da güçlendiriyor."
        )
    }

    func testPersonalizedCoachTipUsesFallbackWhenPatternIsMissing() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.coachTip,
            "Tahminler Umay'in kendi ritmine göre üretiliyor. Her kayıt sistemi daha da güçlendiriyor."
        )
    }

    func testPersonalizedCoachTipFormatsMidnightCorrectly() {
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
            "Umay'in en uzun napları saat 12 AM civarında başlıyor — ortalamadan ~10 dk daha uzun."
        )
    }

    func testPersonalizedCoachTipFormatsNoonCorrectly() {
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
            "Umay'in en uzun napları saat 12 PM civarında başlıyor — ortalamadan ~10 dk daha uzun."
        )
    }

    // MARK: - Alerts

    func testPoorDataQualityAddsInfoAlert() {
        let pattern = makePattern(
            dataQuality: .poor
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 7,
            babyName: "Umay"
        )

        let infoAlert = result.alerts.first {
            $0.severity == .info
        }

        XCTAssertNotNil(infoAlert)
        XCTAssertEqual(
            infoAlert?.message,
            "Daha fazla gün takip et — tahminler güçlenecek."
        )
        XCTAssertNil(infoAlert?.actionTitle)
        XCTAssertNil(infoAlert?.actionType)
    }

    func testBaselinePhaseAddsWakeTimeWarning() {
        let result = agent.buildInsights(
            phase: .baseline,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        let wakeAlert = result.alerts.first {
            $0.actionType == .addWakeTime
        }

        XCTAssertNotNil(wakeAlert)
        XCTAssertEqual(
            wakeAlert?.severity,
            .warning
        )
        XCTAssertEqual(
            wakeAlert?.actionTitle,
            "Ekle"
        )
    }

    func testLearningPhaseAddsWakeTimeWarning() {
        let result = agent.buildInsights(
            phase: .learning(day: 4),
            pattern: nil,
            trackedDays: 4,
            babyName: "Umay"
        )

        XCTAssertTrue(
            result.alerts.contains {
                $0.actionType == .addWakeTime
            }
        )
    }

    func testPersonalizedPhaseDoesNotAddWakeTimeWarning() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 14,
            babyName: "Umay"
        )

        XCTAssertFalse(
            result.alerts.contains {
                $0.actionType == .addWakeTime
            }
        )
    }

    func testTooYoungPhaseDoesNotAddWakeTimeWarning() {
        let result = agent.buildInsights(
            phase: .tooYoung,
            pattern: nil,
            trackedDays: 0,
            babyName: "Umay"
        )

        XCTAssertFalse(
            result.alerts.contains {
                $0.actionType == .addWakeTime
            }
        )
    }

    func testPoorDataQualityAndLearningPhaseCanProduceTwoAlerts() {
        let pattern = makePattern(
            dataQuality: .poor
        )

        let result = agent.buildInsights(
            phase: .learning(day: 6),
            pattern: pattern,
            trackedDays: 6,
            babyName: "Umay"
        )

        XCTAssertEqual(result.alerts.count, 2)
        XCTAssertTrue(
            result.alerts.contains { $0.severity == .info }
        )
        XCTAssertTrue(
            result.alerts.contains { $0.actionType == .addWakeTime }
        )
    }

    // MARK: - Weekly Pattern

    func testWeeklyPatternReturnsNilWhenSampleSizeIsTooSmall() {
        let pattern = makePattern(
            sampleSize: 6
        )

        let result = agent.buildInsights(
            phase: .personalized,
            pattern: pattern,
            trackedDays: 6,
            babyName: "Umay"
        )

        XCTAssertNil(result.weeklyPattern)
    }

    func testWeeklyPatternContainsNapTimeAndTrends() {
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
            "En iyi nap saati: 9 AM • Uyanıklık penceresi uzuyor • Naplar kısalıyor"
        )
    }

    func testWeeklyPatternHandlesStableTrends() {
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
            "En iyi nap saati: 2 PM • Uyanıklık penceresi tutarlı • Nap süresi tutarlı"
        )
    }

    func testWeeklyPatternHandlesInsufficientTrends() {
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
            "En iyi nap saati: 10 AM"
        )
    }

    func testWeeklyPatternReturnsNilWhenNoPatternPartsExist() {
        let pattern = makePattern(
            bestFirstNapHour: nil,
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

    func testWeeklyPatternCoversAllWakingWindowTrendBranches() {
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

            XCTAssertNotNil(result)
        }
    }

    func testWeeklyPatternCoversAllNapDurationTrendBranches() {
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

            XCTAssertNotNil(result)
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
            "Umay 4 aylık olduğunda tahminler başlayacak."
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
            "Henüz veri yok. Umay'in ilk uykusunu logla."
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
            "8 gün takip edildi. 6 gün kaldı."
        )
    }

    func testProgressMessageForPersonalizedPhase() {
        let result = agent.buildInsights(
            phase: .personalized,
            pattern: nil,
            trackedDays: 17,
            babyName: "Umay"
        )

        XCTAssertEqual(
            result.progressMessage,
            "Kişiselleştirilmiş! 17 gün verisi kullanılıyor."
        )
    }
}
