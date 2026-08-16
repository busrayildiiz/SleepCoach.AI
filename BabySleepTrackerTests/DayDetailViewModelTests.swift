import XCTest
@testable import BabySleepTracker

final class DayDetailViewModelTests: XCTestCase {

    // MARK: - totalMinutes(for:in:)

    func testTotalMinutesReturnsNapDurationWhenThereAreNoBreaks() {
        let nap = SleepRecord(
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let viewModel = DayDetailViewModel(
            records: [nap],
            totalMinutes: 120
        )

        let result = viewModel.totalMinutes(
            for: nap,
            in: [nap]
        )

        XCTAssertEqual(result, 120)
    }

    func testTotalMinutesSubtractsBreaksBelongingToTheNap() {
        let napID = UUID()

        let nap = SleepRecord(
            id: napID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let break1 = SleepRecord(
            date: Date(),
            duration: 15,
            kind: .break,
            parentNapID: napID
        )

        let break2 = SleepRecord(
            date: Date(),
            duration: 20,
            kind: .break,
            parentNapID: napID
        )

        let viewModel = DayDetailViewModel(
            records: [nap, break1, break2],
            totalMinutes: 120
        )

        let result = viewModel.totalMinutes(
            for: nap,
            in: [nap, break1, break2]
        )

        XCTAssertEqual(result, 85)
    }

    func testTotalMinutesIgnoresBreaksBelongingToAnotherNap() {
        let napID = UUID()
        let otherNapID = UUID()

        let nap = SleepRecord(
            id: napID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let ownBreak = SleepRecord(
            date: Date(),
            duration: 15,
            kind: .break,
            parentNapID: napID
        )

        let unrelatedBreak = SleepRecord(
            date: Date(),
            duration: 30,
            kind: .break,
            parentNapID: otherNapID
        )

        let viewModel = DayDetailViewModel(
            records: [nap, ownBreak, unrelatedBreak],
            totalMinutes: 120
        )

        let result = viewModel.totalMinutes(
            for: nap,
            in: [nap, ownBreak, unrelatedBreak]
        )

        XCTAssertEqual(result, 105)
    }

    func testTotalMinutesIgnoresNonBreakRecords() {
        let napID = UUID()

        let nap = SleepRecord(
            id: napID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let anotherNap = SleepRecord(
            date: Date(),
            duration: 45,
            kind: .dayNap
        )

        let nightSleep = SleepRecord(
            date: Date(),
            duration: 480,
            kind: .nightSleep
        )

        let viewModel = DayDetailViewModel(
            records: [nap, anotherNap, nightSleep],
            totalMinutes: 120
        )

        let result = viewModel.totalMinutes(
            for: nap,
            in: [nap, anotherNap, nightSleep]
        )

        XCTAssertEqual(result, 120)
    }

    // MARK: - formattedTotal

    func testFormattedTotalFormatsHoursAndMinutes() {
        let viewModel = DayDetailViewModel(
            records: [],
            totalMinutes: 125
        )

        XCTAssertEqual(viewModel.formattedTotal, "2 h 5m")
    }

    func testFormattedTotalFormatsMinutesOnly() {
        let viewModel = DayDetailViewModel(
            records: [],
            totalMinutes: 45
        )

        XCTAssertEqual(viewModel.formattedTotal, "0 h 45m")
    }

    func testFormattedTotalFormatsExactHours() {
        let viewModel = DayDetailViewModel(
            records: [],
            totalMinutes: 120
        )

        XCTAssertEqual(viewModel.formattedTotal, "2 h 0m")
    }

    func testFormattedTotalFormatsZeroMinutes() {
        let viewModel = DayDetailViewModel(
            records: [],
            totalMinutes: 0
        )

        XCTAssertEqual(viewModel.formattedTotal, "0 h 0m")
    }
}
