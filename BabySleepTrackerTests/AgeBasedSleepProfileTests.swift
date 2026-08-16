import XCTest
@testable import BabySleepTracker

final class AgeBasedSleepProfileTests: XCTestCase {

    private let provider = DefaultAgeBasedSleepProfileProvider()

    override func setUp() {
        super.setUp()

        UserDefaults.standard.removeObject(forKey: "babyBirthDate")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "babyBirthDate")

        super.tearDown()
    }

    // MARK: - Profile lookup without stored birth date

    func testProfileReturnsFourMonthProfile() {
        let profile = provider.profile(forAgeMonths: 4)

        XCTAssertEqual(profile.ageRange, 4...4)
        XCTAssertEqual(profile.totalSleep24hRange, 720...960)
        XCTAssertEqual(profile.wakeWindowRange, 90...120)
        XCTAssertEqual(profile.morningWakeWindow, 75...90)
        XCTAssertEqual(profile.eveningWakeWindow, 90...120)
        XCTAssertEqual(profile.expectedNapCount, 3...5)
        XCTAssertEqual(profile.maxSingleNapMinutes, 120)
        XCTAssertEqual(profile.daytimeSleepRange, 210...270)
        XCTAssertEqual(profile.nightSleepRange, 600...720)
        XCTAssertEqual(profile.bedtimeHourRange, 18...20)
        XCTAssertEqual(profile.lastNapCutoffHour, 17)
    }

    func testProfileReturnsFiveToSixMonthProfile() {
        let fiveMonth = provider.profile(forAgeMonths: 5)
        let sixMonth = provider.profile(forAgeMonths: 6)

        XCTAssertEqual(fiveMonth.ageRange, 5...6)
        XCTAssertEqual(sixMonth.ageRange, 5...6)
        XCTAssertEqual(fiveMonth.wakeWindowRange, 120...180)
        XCTAssertEqual(fiveMonth.expectedNapCount, 3...3)
    }

    func testProfileReturnsSevenToEightMonthProfile() {
        let sevenMonth = provider.profile(forAgeMonths: 7)
        let eightMonth = provider.profile(forAgeMonths: 8)

        XCTAssertEqual(sevenMonth.ageRange, 7...8)
        XCTAssertEqual(eightMonth.ageRange, 7...8)
        XCTAssertEqual(sevenMonth.wakeWindowRange, 150...210)
        XCTAssertEqual(sevenMonth.expectedNapCount, 2...3)
    }

    func testProfileReturnsNineToElevenMonthProfile() {
        let nineMonth = provider.profile(forAgeMonths: 9)
        let elevenMonth = provider.profile(forAgeMonths: 11)

        XCTAssertEqual(nineMonth.ageRange, 9...11)
        XCTAssertEqual(elevenMonth.ageRange, 9...11)
        XCTAssertEqual(nineMonth.wakeWindowRange, 180...240)
        XCTAssertEqual(nineMonth.expectedNapCount, 2...2)
    }

    func testProfileReturnsTwelveToFourteenMonthProfile() {
        let twelveMonth = provider.profile(forAgeMonths: 12)
        let fourteenMonth = provider.profile(forAgeMonths: 14)

        XCTAssertEqual(twelveMonth.ageRange, 12...14)
        XCTAssertEqual(fourteenMonth.ageRange, 12...14)
        XCTAssertEqual(twelveMonth.wakeWindowRange, 210...270)
        XCTAssertEqual(twelveMonth.expectedNapCount, 1...2)
    }

    func testProfileReturnsFifteenToEighteenMonthProfile() {
        let fifteenMonth = provider.profile(forAgeMonths: 15)
        let eighteenMonth = provider.profile(forAgeMonths: 18)

        XCTAssertEqual(fifteenMonth.ageRange, 15...18)
        XCTAssertEqual(eighteenMonth.ageRange, 15...18)
        XCTAssertEqual(fifteenMonth.wakeWindowRange, 270...360)
        XCTAssertEqual(fifteenMonth.expectedNapCount, 1...1)
    }

    func testProfileReturnsNineteenToTwentyFourMonthProfile() {
        let nineteenMonth = provider.profile(forAgeMonths: 19)
        let twentyFourMonth = provider.profile(forAgeMonths: 24)

        XCTAssertEqual(nineteenMonth.ageRange, 19...24)
        XCTAssertEqual(twentyFourMonth.ageRange, 19...24)
        XCTAssertEqual(nineteenMonth.wakeWindowRange, 300...420)
        XCTAssertEqual(nineteenMonth.expectedNapCount, 1...1)
    }

    // MARK: - Boundary behavior

    func testAgeFourUsesFourMonthProfile() {
        XCTAssertEqual(
            provider.profile(forAgeMonths: 4).ageRange,
            4...4
        )
    }

    func testAgeTwentyFourUsesLastProfile() {
        XCTAssertEqual(
            provider.profile(forAgeMonths: 24).ageRange,
            19...24
        )
    }

    func testAgeBelowSupportedRangeFallsBackToLastProfile() {
        XCTAssertEqual(
            provider.profile(forAgeMonths: 3).ageRange,
            19...24
        )
    }

    func testAgeAboveSupportedRangeFallsBackToLastProfile() {
        XCTAssertEqual(
            provider.profile(forAgeMonths: 30).ageRange,
            19...24
        )
    }

    // MARK: - Wake window centers

    func testWakeWindowCenterUsesProfileBounds() {
        XCTAssertEqual(
            provider.wakeWindowCenter(forAgeMonths: 9),
            210
        )

        XCTAssertEqual(
            provider.wakeWindowCenter(forAgeMonths: 15),
            315
        )

        XCTAssertEqual(
            provider.wakeWindowCenter(forAgeMonths: 19),
            360
        )
    }

    func testEveningWakeWindowCenterUsesProfileBounds() {
        XCTAssertEqual(
            provider.eveningWakeWindowCenter(forAgeMonths: 9),
            225
        )

        XCTAssertEqual(
            provider.eveningWakeWindowCenter(forAgeMonths: 15),
            345
        )

        XCTAssertEqual(
            provider.eveningWakeWindowCenter(forAgeMonths: 19),
            390
        )
    }

    // MARK: - Birth date logic

    func testProfileUsesStoredBirthDateWhenAvailable() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -9,
            to: Date()
        )!

        UserDefaults.standard.set(
            birthDate,
            forKey: "babyBirthDate"
        )

        let profile = provider.profile(forAgeMonths: 4)

        XCTAssertEqual(profile.ageRange, 9...11)
    }

    func testProfileAcceptsBirthDateStoredAsTimeInterval() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -15,
            to: Date()
        )!

        UserDefaults.standard.set(
            birthDate.timeIntervalSince1970,
            forKey: "babyBirthDate"
        )

        let profile = provider.profile(forAgeMonths: 4)

        XCTAssertEqual(profile.ageRange, 15...18)
    }

    // MARK: - Profile data consistency

    func testAllProfilesHaveValidAgeRanges() {
        for profile in DefaultAgeBasedSleepProfileProvider.profiles {
            XCTAssertLessThanOrEqual(
                profile.ageRange.lowerBound,
                profile.ageRange.upperBound
            )
        }
    }

    func testAllProfilesHaveValidWakeWindowRanges() {
        for profile in DefaultAgeBasedSleepProfileProvider.profiles {
            XCTAssertLessThanOrEqual(
                profile.wakeWindowRange.lowerBound,
                profile.wakeWindowRange.upperBound
            )

            XCTAssertLessThanOrEqual(
                profile.morningWakeWindow.lowerBound,
                profile.morningWakeWindow.upperBound
            )

            XCTAssertLessThanOrEqual(
                profile.eveningWakeWindow.lowerBound,
                profile.eveningWakeWindow.upperBound
            )
        }
    }

    func testAllProfilesHaveValidNapAndSleepRanges() {
        for profile in DefaultAgeBasedSleepProfileProvider.profiles {
            XCTAssertLessThanOrEqual(
                profile.totalSleep24hRange.lowerBound,
                profile.totalSleep24hRange.upperBound
            )

            XCTAssertLessThanOrEqual(
                profile.daytimeSleepRange.lowerBound,
                profile.daytimeSleepRange.upperBound
            )

            XCTAssertLessThanOrEqual(
                profile.nightSleepRange.lowerBound,
                profile.nightSleepRange.upperBound
            )

            XCTAssertGreaterThan(
                profile.maxSingleNapMinutes,
                0
            )
        }
    }
}
