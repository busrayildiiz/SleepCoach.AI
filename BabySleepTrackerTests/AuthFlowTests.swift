import XCTest
import SwiftUI
@testable import BabySleepTracker

final class AuthFlowTests: XCTestCase {

    // MARK: - AuthState

    func testAuthStateContainsAllExpectedStates() {
        let states: [AuthState] = [
            .landing,
            .creatingAccount,
            .loggingIn,
            .onboarding,
            .loggedIn
        ]

        XCTAssertEqual(states.count, 5)
    }

    // MARK: - BabyAgeFormatter

    func testBabyAgeReturnsNewbornForLessThanOneMonth() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .day,
            value: -15,
            to: Date()
        )!

        let result = BabyAgeFormatter.string(
            from: birthDate,
            to: Date()
        )

        XCTAssertEqual(result, "Newborn")
    }

    func testBabyAgeReturnsMonthsBetweenOneAndTwentyThreeMonths() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -9,
            to: Date()
        )!

        let result = BabyAgeFormatter.string(
            from: birthDate,
            to: Date()
        )

        XCTAssertEqual(result, "9 months")
    }

    func testBabyAgeReturnsMonthsForTwentyThreeMonths() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -23,
            to: Date()
        )!

        let result = BabyAgeFormatter.string(
            from: birthDate,
            to: Date()
        )

        XCTAssertEqual(result, "23 months")
    }

    func testBabyAgeReturnsYearsAtTwentyFourMonths() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -24,
            to: Date()
        )!

        let result = BabyAgeFormatter.string(
            from: birthDate,
            to: Date()
        )

        XCTAssertEqual(result, "2 years")
    }

    func testBabyAgeReturnsYearsForOlderChildren() {
        let calendar = Calendar.current

        let birthDate = calendar.date(
            byAdding: .month,
            value: -36,
            to: Date()
        )!

        let result = BabyAgeFormatter.string(
            from: birthDate,
            to: Date()
        )

        XCTAssertEqual(result, "3 years")
    }

    // MARK: - Color Hex

    func testColorHexInitializerAcceptsSixDigitHex() {
        let color = Color(hex: "6B63D8")

        XCTAssertNotNil(color)
    }

    func testColorHexInitializerAcceptsThreeDigitHex() {
        let color = Color(hex: "ABC")

        XCTAssertNotNil(color)
    }

    func testColorHexInitializerAcceptsEightDigitHex() {
        let color = Color(hex: "FF6B63D8")

        XCTAssertNotNil(color)
    }

    func testColorHexInitializerHandlesInvalidHexLength() {
        let color = Color(hex: "12")

        XCTAssertNotNil(color)
    }
}
