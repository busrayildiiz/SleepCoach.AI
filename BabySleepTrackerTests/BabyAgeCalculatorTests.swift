
import XCTest
@testable import BabySleepTracker

final class BabyAgeCalculatorTests: XCTestCase {

    private var sut: DefaultBabyAgeCalculator!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        sut = DefaultBabyAgeCalculator(calendar: calendar)
    }

    override func tearDown() {
        sut = nil
        calendar = nil

        super.tearDown()
    }

    // MARK: - Same Day

    func test_ageInMonths_whenBirthDateAndDateAreSame_returnsZero() {
        let birthDate = date(2025, 8, 1)
        let date = date(2025, 8, 1)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 0)
    }

    // MARK: - One Month

    func test_ageInMonths_oneMonthLater_returnsOne() {
        let birthDate = date(2025, 8, 1)
        let date = date(2025, 9, 1)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 1)
    }

    // MARK: - Multiple Months

    func test_ageInMonths_multipleMonthsLater_returnsCorrectMonths() {
        let birthDate = date(2025, 8, 1)
        let date = date(2026, 2, 1)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 6)
    }

    // MARK: - One Year

    func test_ageInMonths_oneYearLater_returnsTwelve() {
        let birthDate = date(2025, 8, 1)
        let date = date(2026, 8, 1)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 12)
    }

    // MARK: - Years + Months

    func test_ageInMonths_oneYearAndThreeMonthsLater_returnsFifteen() {
        let birthDate = date(2025, 8, 1)
        let date = date(2026, 11, 1)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 15)
    }

    // MARK: - Before Birth

    func test_ageInMonths_whenDateIsBeforeBirth_returnsZero() {
        let birthDate = date(2025, 8, 1)
        let date = date(2025, 7, 31)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 0)
    }

    // MARK: - Before Monthly Anniversary

    func test_ageInMonths_whenMonthlyAnniversaryHasNotBeenReached_returnsPreviousMonth() {
        let birthDate = date(2025, 8, 15)
        let date = date(2025, 9, 14)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 0)
    }

    // MARK: - Monthly Anniversary Reached

    func test_ageInMonths_whenMonthlyAnniversaryIsReached_returnsNewMonth() {
        let birthDate = date(2025, 8, 15)
        let date = date(2025, 9, 15)

        let result = sut.ageInMonths(
            birthDate: birthDate,
            on: date
        )

        XCTAssertEqual(result, 1)
    }

    // MARK: - Helper

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day
            )
        )!
    }
}
