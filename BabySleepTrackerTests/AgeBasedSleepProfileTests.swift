import XCTest
@testable import BabySleepTracker

final class AgeBasedSleepProfileTests: XCTestCase {

    private var sut: DefaultAgeBasedSleepProfileProvider!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()

        defaults = UserDefaults(
            suiteName: "AgeBasedSleepProfileTests"
        )!

        defaults.removePersistentDomain(
            forName: "AgeBasedSleepProfileTests"
        )

        sut = DefaultAgeBasedSleepProfileProvider(
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(
            forName: "AgeBasedSleepProfileTests"
        )

        sut = nil
        defaults = nil

        super.tearDown()
    }

    // MARK: - Profile Lookup

    func test_profile_forAge4_returns4MonthProfile() {
        let profile = sut.profile(forAgeMonths: 4)

        XCTAssertEqual(profile.ageRange, 4...4)
    }

    func test_profile_forAge5_returns5To6MonthProfile() {
        let profile = sut.profile(forAgeMonths: 5)

        XCTAssertEqual(profile.ageRange, 5...6)
    }

    func test_profile_forAge6_returns5To6MonthProfile() {
        let profile = sut.profile(forAgeMonths: 6)

        XCTAssertEqual(profile.ageRange, 5...6)
    }

    func test_profile_forAge7_returns7To8MonthProfile() {
        let profile = sut.profile(forAgeMonths: 7)

        XCTAssertEqual(profile.ageRange, 7...8)
    }

    func test_profile_forAge8_returns7To8MonthProfile() {
        let profile = sut.profile(forAgeMonths: 8)

        XCTAssertEqual(profile.ageRange, 7...8)
    }

    func test_profile_forAge9_returns9To11MonthProfile() {
        let profile = sut.profile(forAgeMonths: 9)

        XCTAssertEqual(profile.ageRange, 9...11)
    }

    func test_profile_forAge12_returns12To14MonthProfile() {
        let profile = sut.profile(forAgeMonths: 12)

        XCTAssertEqual(profile.ageRange, 12...14)
    }

    func test_profile_forAge15_returns15To18MonthProfile() {
        let profile = sut.profile(forAgeMonths: 15)

        XCTAssertEqual(profile.ageRange, 15...18)
    }

    func test_profile_forAge19_returns19To24MonthProfile() {
        let profile = sut.profile(forAgeMonths: 19)

        XCTAssertEqual(profile.ageRange, 19...24)
    }

    func test_profile_forAge24_returns19To24MonthProfile() {
        let profile = sut.profile(forAgeMonths: 24)

        XCTAssertEqual(profile.ageRange, 19...24)
    }

    // MARK: - Boundary Protection

    func test_profile_forAgeBelowSupportedRange_doesNotCrash() {
        let profile = sut.profile(forAgeMonths: 3)

        XCTAssertNotNil(profile)
    }

    func test_profile_forAgeAboveSupportedRange_doesNotCrash() {
        let profile = sut.profile(forAgeMonths: 25)

        XCTAssertNotNil(profile)
    }

    // MARK: - Wake Window Centers

    func test_wakeWindowCenter_for9Months_returnsExpectedCenter() {
        let center = sut.wakeWindowCenter(forAgeMonths: 9)

        XCTAssertEqual(center, 210)
    }

    func test_eveningWakeWindowCenter_for9Months_returnsExpectedCenter() {
        let center = sut.eveningWakeWindowCenter(forAgeMonths: 9)

        XCTAssertEqual(center, 225)
    }

    // MARK: - Profile Invariants

    func test_allProfiles_haveValidWakeWindowOrdering() {
        for profile in DefaultAgeBasedSleepProfileProvider.profiles {
            XCTAssertLessThanOrEqual(
                profile.wakeWindowRange.lowerBound,
                profile.wakeWindowRange.upperBound
            )

            XCTAssertLessThanOrEqual(
                profile.morningWakeWindow.upperBound,
                profile.eveningWakeWindow.lowerBound
            )
        }
    }

    func test_allProfiles_haveValidSleepRanges() {
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
        }
    }

    func test_allProfiles_haveValidNapCountRanges() {
        for profile in DefaultAgeBasedSleepProfileProvider.profiles {
            XCTAssertLessThanOrEqual(
                profile.expectedNapCount.lowerBound,
                profile.expectedNapCount.upperBound
            )
        }
    }

    // MARK: - UserDefaults Behavior

    func test_profile_whenBirthDateExists_currentlyUsesBirthDateInsteadOfProvidedAge() {
        let birthDate = makeDate(
            year: 2025,
            month: 8,
            day: 1
        )

        defaults.set(
            birthDate,
            forKey: "babyBirthDate"
        )

        let profile = sut.profile(forAgeMonths: 4)

        XCTAssertEqual(profile.ageRange, 5...6)
    }

    // MARK: - Helpers

    private func makeDate(
        year: Int,
        month: Int,
        day: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day
            )
        )!
    }
}
