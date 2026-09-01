import Foundation

// MARK: - Baby Age Calculator

protocol BabyAgeCalculating {
    func ageInMonths(
        birthDate: Date,
        on date: Date
    ) -> Int
}

// MARK: - Default Baby Age Calculator

final class DefaultBabyAgeCalculator: BabyAgeCalculating {

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func ageInMonths(
        birthDate: Date,
        on date: Date
    ) -> Int {

        guard date >= birthDate else {
            return 0
        }

        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: birthDate,
            to: date
        )

        let years = components.year ?? 0
        let months = components.month ?? 0

        return max(0, years * 12 + months)
    }
}
