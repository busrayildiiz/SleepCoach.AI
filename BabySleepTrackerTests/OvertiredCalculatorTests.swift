import XCTest
@testable import BabySleepTracker

final class OvertiredCalculatorTests: XCTestCase {

    private var profileProvider: MockOvertiredProfileProvider!
    private var calculator: OvertiredCalculator!

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

        profileProvider = MockOvertiredProfileProvider()
        calculator = OvertiredCalculator(
            profileProvider: profileProvider
        )
    }

    override func tearDown() {
        calculator = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - Overtired Risk: Daytime

    func testOvertiredRiskIsHealthyBeforeWakeWindowCenter() {
        let awakeSince = now.addingTimeInterval(-120 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        // Day WW = 180...240
        // Center = 210
        XCTAssertEqual(result, .healthy)
    }

    func testOvertiredRiskRemainsHealthyEarlyInFinalWakeWindow() {
        let awakeSince = now.addingTimeInterval(-220 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        // Progress = (220 - 210) / 30 = 0.33
        XCTAssertEqual(result, .healthy)
    }

    func testOvertiredRiskBecomesSlightlyTiredNearWakeWindowLimit() {
        let awakeSince = now.addingTimeInterval(-235 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        // Progress = 25 / 30 > 0.7
        XCTAssertEqual(result, .slightlyTired)
    }

    func testOvertiredRiskBecomesModerateWhenWakeWindowIsExceeded() {
        let awakeSince = now.addingTimeInterval(-245 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        XCTAssertEqual(result, .moderate)
    }

    func testOvertiredRiskBecomesSignificantAfterTwentyMinutesOverMaximum() {
        let awakeSince = now.addingTimeInterval(-265 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        XCTAssertEqual(result, .significant)
    }

    func testOvertiredRiskBecomesCriticallyTiredAfterFortyFiveMinutesOverMaximum() {
        let awakeSince = now.addingTimeInterval(-290 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: false,
            now: now
        )

        XCTAssertEqual(result, .criticallyTired)
    }

    // MARK: - Overtired Risk: Evening

    func testEveningPeriodUsesEveningWakeWindow() {
        let awakeSince = now.addingTimeInterval(-230 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: true,
            now: now
        )

        // Evening WW = 210...240
        // Center = 225
        // 230 is still early in the final interval.
        XCTAssertEqual(result, .healthy)
    }

    func testEveningPeriodCanBecomeSlightlyTiredBeforeMaximum() {
        let awakeSince = now.addingTimeInterval(-238 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: true,
            now: now
        )

        XCTAssertEqual(result, .slightlyTired)
    }

    func testEveningPeriodUsesEveningMaximumForModerateRisk() {
        let awakeSince = now.addingTimeInterval(-245 * 60)

        let result = calculator.overtiredRisk(
            awakeSinceDate: awakeSince,
            ageMonths: 9,
            isEveningPeriod: true,
            now: now
        )

        XCTAssertEqual(result, .moderate)
    }

    // MARK: - Bedtime Window

    func testBedtimeWindowUsesEveningWakeWindow() {
        let lastNapEnd = day(hour: 15, minute: 0)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 180,
            ageMonths: 9,
            now: now
        )

        let expectedEarliest = lastNapEnd.addingTimeInterval(210 * 60)
        let expectedIdeal = lastNapEnd.addingTimeInterval(225 * 60)
        let expectedLatest = lastNapEnd.addingTimeInterval(240 * 60)
        let expectedCritical = lastNapEnd.addingTimeInterval(260 * 60)

        XCTAssertEqual(
            result.earliest.timeIntervalSince(expectedEarliest),
            0,
            accuracy: 1
        )

        XCTAssertEqual(
            result.ideal.timeIntervalSince(expectedIdeal),
            0,
            accuracy: 1
        )

        XCTAssertEqual(
            result.latest.timeIntervalSince(expectedLatest),
            0,
            accuracy: 1
        )

        XCTAssertEqual(
            result.overtiredRisk.timeIntervalSince(expectedCritical),
            0,
            accuracy: 1
        )
    }

    func testBedtimeWindowMovesEarliestAndIdealEarlierWhenDaytimeSleepIsInsufficient() {
        let lastNapEnd = day(hour: 15, minute: 0)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 150,
            ageMonths: 9,
            now: now
        )

        // Minimum daytime target = 120.
        // No deficit because 150 > 120.
        let expectedEarliest = lastNapEnd.addingTimeInterval(210 * 60)
        let expectedIdeal = lastNapEnd.addingTimeInterval(225 * 60)

        XCTAssertEqual(
            result.earliest.timeIntervalSince(expectedEarliest),
            0,
            accuracy: 1
        )

        XCTAssertEqual(
            result.ideal.timeIntervalSince(expectedIdeal),
            0,
            accuracy: 1
        )
    }

    func testBedtimeWindowAdjustsForDaytimeSleepDeficit() {
        let lastNapEnd = day(hour: 15, minute: 0)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 90,
            ageMonths: 9,
            now: now
        )

        // Target minimum = 120
        // Deficit = 30
        // Adjustment = 30 / 3 = 10 minutes

        let expectedEarliest = lastNapEnd.addingTimeInterval((210 - 10) * 60)
        let expectedIdeal = lastNapEnd.addingTimeInterval((225 - 10) * 60)

        XCTAssertEqual(
            result.earliest.timeIntervalSince(expectedEarliest),
            0,
            accuracy: 1
        )

        XCTAssertEqual(
            result.ideal.timeIntervalSince(expectedIdeal),
            0,
            accuracy: 1
        )
    }

    func testBedtimeWindowDoesNotAdjustLatestTimeForDaytimeDeficit() {
        let lastNapEnd = day(hour: 15, minute: 0)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 60,
            ageMonths: 9,
            now: now
        )

        let expectedLatest = lastNapEnd.addingTimeInterval(240 * 60)

        XCTAssertEqual(
            result.latest.timeIntervalSince(expectedLatest),
            0,
            accuracy: 1
        )
    }

    func testBedtimeReasoningContainsNapEndAndIdealBedtime() {
        let lastNapEnd = day(hour: 15, minute: 30)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 120,
            ageMonths: 9,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains("Son nap")
        )

        XCTAssertTrue(
            result.reasoning.contains("9 aylık")
        )

        XCTAssertTrue(
            result.reasoning.contains("İdeal yatış")
        )
    }

    func testBedtimeReasoningMentionsDaytimeDeficitWhenAdjustmentOccurs() {
        let lastNapEnd = day(hour: 15, minute: 30)

        let result = calculator.bedtimeWindow(
            lastNapEndTime: lastNapEnd,
            totalDaytimeSleepMinutes: 90,
            ageMonths: 9,
            now: now
        )

        XCTAssertTrue(
            result.reasoning.contains("Gündüz uykusu")
        )

        XCTAssertTrue(
            result.reasoning.contains("30 dk eksik")
        )

        XCTAssertTrue(
            result.reasoning.contains("10 dk öne alındı")
        )
    }

    // MARK: - Last Nap Cutoff

    func testLastNapCutoffUsesProfileHour() {
        let date = day(hour: 10, minute: 15)

        let result = calculator.lastNapCutoffTime(
            ageMonths: 9,
            on: date
        )

        let expected = Calendar.current.date(
            bySettingHour: 16,
            minute: 0,
            second: 0,
            of: date
        )!

        XCTAssertEqual(
            result.timeIntervalSince(expected),
            0,
            accuracy: 1
        )
    }

    // MARK: - Daily Sleep Status

    func testDailySleepStatusIsBelowWhenTotalIsUnderRange() {
        let result = calculator.dailySleepStatus(
            totalMinutes: 600,
            ageMonths: 9
        )

        // Minimum = 660
        XCTAssertEqual(
            result,
            .below(deficitMinutes: 60)
        )
    }

    func testDailySleepStatusIsOnTrackWithinRange() {
        let result = calculator.dailySleepStatus(
            totalMinutes: 720,
            ageMonths: 9
        )

        XCTAssertEqual(
            result,
            .onTrack
        )
    }

    func testDailySleepStatusIsAboveWhenTotalExceedsRange() {
        let result = calculator.dailySleepStatus(
            totalMinutes: 900,
            ageMonths: 9
        )

        // Maximum = 840
        XCTAssertEqual(
            result,
            .above(excessMinutes: 60)
        )
    }

    // MARK: - Daily Sleep Status Labels

    func testDailySleepStatusOnTrackLabel() {
        XCTAssertEqual(
            DailySleepStatus.onTrack.label,
            "Günlük uyku hedefte ✓"
        )
    }

    func testDailySleepStatusBelowLabel() {
        XCTAssertEqual(
            DailySleepStatus.below(deficitMinutes: 45).label,
            "Günlük uyku 45m eksik"
        )
    }

    func testDailySleepStatusAboveLabel() {
        XCTAssertEqual(
            DailySleepStatus.above(excessMinutes: 90).label,
            "Günlük uyku 1h 30m fazla"
        )
    }

    // MARK: - Helpers

    private func day(
        hour: Int,
        minute: Int
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

private final class MockOvertiredProfileProvider:
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
