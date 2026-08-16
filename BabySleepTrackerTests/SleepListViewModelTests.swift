
import XCTest
@testable import BabySleepTracker

@MainActor
final class SleepListViewModelTests: XCTestCase {

    // MARK: - Initial State

    func testViewModelStartsWithEmptyRecordsAndNoError() {
        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        XCTAssertTrue(viewModel.records.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Add

    func testAddInsertsRecordAtBeginning() {
        let firstRecord = makeRecord(
            date: date(day: 1),
            duration: 60
        )

        let secondRecord = makeRecord(
            date: date(day: 2),
            duration: 90
        )

        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.add(firstRecord)
        viewModel.add(secondRecord)

        XCTAssertEqual(viewModel.records.count, 2)
        XCTAssertEqual(viewModel.records[0].id, secondRecord.id)
        XCTAssertEqual(viewModel.records[1].id, firstRecord.id)
    }

    func testAddPersistsUpdatedRecords() {
        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        let record = makeRecord(duration: 75)

        viewModel.add(record)

        XCTAssertEqual(store.saveCallCount, 1)
        XCTAssertEqual(store.savedRecords.count, 1)
        XCTAssertEqual(store.savedRecords.first?.id, record.id)
    }

    func testAddSetsErrorMessageWhenPersistenceFails() {
        let store = TestSleepStore()
        store.saveError = TestError.persistenceFailed

        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.add(makeRecord())

        XCTAssertEqual(
            viewModel.errorMessage,
            "Failed to save records."
        )
    }

    // MARK: - Delete

    func testDeleteRemovesRecordAtSpecifiedIndex() {
        let firstRecord = makeRecord(
            date: date(day: 1),
            duration: 60
        )

        let secondRecord = makeRecord(
            date: date(day: 2),
            duration: 90
        )

        let thirdRecord = makeRecord(
            date: date(day: 3),
            duration: 120
        )

        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.add(firstRecord)
        viewModel.add(secondRecord)
        viewModel.add(thirdRecord)

        viewModel.delete(at: IndexSet(integer: 1))

        XCTAssertEqual(viewModel.records.count, 2)
        XCTAssertFalse(
            viewModel.records.contains { $0.id == secondRecord.id }
        )
    }

    func testDeletePersistsUpdatedRecords() {
        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        let firstRecord = makeRecord(duration: 60)
        let secondRecord = makeRecord(duration: 90)

        viewModel.add(firstRecord)
        viewModel.add(secondRecord)

        let saveCallsBeforeDelete = store.saveCallCount

        viewModel.delete(at: IndexSet(integer: 0))

        XCTAssertEqual(
            store.saveCallCount,
            saveCallsBeforeDelete + 1
        )

        XCTAssertEqual(store.savedRecords.count, 1)
    }

    // MARK: - Grouping

    func testGroupedByDayGroupsRecordsAndSortsDaysDescending() {
        let olderRecord = makeRecord(
            date: date(day: 1, hour: 10),
            duration: 60
        )

        let newerDayEarlierRecord = makeRecord(
            date: date(day: 3, hour: 8),
            duration: 45
        )

        let newerDayLaterRecord = makeRecord(
            date: date(day: 3, hour: 14),
            duration: 90
        )

        let middleDayRecord = makeRecord(
            date: date(day: 2, hour: 12),
            duration: 120
        )

        let store = TestSleepStore()
        let api = TestSleepAPI()

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.add(olderRecord)
        viewModel.add(newerDayEarlierRecord)
        viewModel.add(newerDayLaterRecord)
        viewModel.add(middleDayRecord)

        let grouped = viewModel.groupedByDay()

        XCTAssertEqual(grouped.count, 3)

        // Newest day first.
        XCTAssertEqual(
            Calendar.current.startOfDay(for: grouped[0].day),
            Calendar.current.startOfDay(
                for: newerDayEarlierRecord.date
            )
        )

        XCTAssertEqual(
            Calendar.current.startOfDay(for: grouped[1].day),
            Calendar.current.startOfDay(
                for: middleDayRecord.date
            )
        )

        XCTAssertEqual(
            Calendar.current.startOfDay(for: grouped[2].day),
            Calendar.current.startOfDay(
                for: olderRecord.date
            )
        )

        // Records within a day should be sorted ascending by date.
        XCTAssertEqual(
            grouped[0].items[0].id,
            newerDayEarlierRecord.id
        )

        XCTAssertEqual(
            grouped[0].items[1].id,
            newerDayLaterRecord.id
        )
    }

    func testGroupedByDayReturnsEmptyArrayWhenNoRecordsExist() {
        let viewModel = SleepListViewModel(
            store: TestSleepStore(),
            api: TestSleepAPI()
        )

        XCTAssertTrue(viewModel.groupedByDay().isEmpty)
    }

    // MARK: - Records For Day

    func testRecordsForDayReturnsOnlyRecordsFromRequestedDay() {
        let targetDayRecord = makeRecord(
            date: date(day: 5, hour: 10),
            duration: 60
        )

        let anotherTargetDayRecord = makeRecord(
            date: date(day: 5, hour: 18),
            duration: 90
        )

        let differentDayRecord = makeRecord(
            date: date(day: 6, hour: 10),
            duration: 120
        )

        let viewModel = SleepListViewModel(
            store: TestSleepStore(),
            api: TestSleepAPI()
        )

        viewModel.add(targetDayRecord)
        viewModel.add(anotherTargetDayRecord)
        viewModel.add(differentDayRecord)

        let result = viewModel.records(
            for: date(day: 5, hour: 12)
        )

        XCTAssertEqual(result.count, 2)

        XCTAssertTrue(
            result.contains { $0.id == targetDayRecord.id }
        )

        XCTAssertTrue(
            result.contains { $0.id == anotherTargetDayRecord.id }
        )

        XCTAssertFalse(
            result.contains { $0.id == differentDayRecord.id }
        )
    }

    // MARK: - Total Minutes

    func testTotalMinutesForDaySumsDurations() {
        let first = makeRecord(
            date: date(day: 7, hour: 9),
            duration: 45
        )

        let second = makeRecord(
            date: date(day: 7, hour: 14),
            duration: 90
        )

        let third = makeRecord(
            date: date(day: 7, hour: 20),
            duration: 120
        )

        let viewModel = SleepListViewModel(
            store: TestSleepStore(),
            api: TestSleepAPI()
        )

        viewModel.add(first)
        viewModel.add(second)
        viewModel.add(third)

        XCTAssertEqual(
            viewModel.totalMinutes(for: date(day: 7)),
            255
        )
    }

    func testTotalMinutesForDayReturnsZeroWhenNoRecordsExist() {
        let viewModel = SleepListViewModel(
            store: TestSleepStore(),
            api: TestSleepAPI()
        )

        XCTAssertEqual(
            viewModel.totalMinutes(for: date(day: 20)),
            0
        )
    }

    // MARK: - Load Success

    func testLoadUpdatesRecordsWhenAPIRequestSucceeds() async throws {
        let expectedRecords = [
            makeRecord(
                date: date(day: 10),
                duration: 60
            ),
            makeRecord(
                date: date(day: 11),
                duration: 90
            )
        ]

        let store = TestSleepStore()

        let api = TestSleepAPI(
            result: .success(expectedRecords)
        )

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.load()

        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(
            viewModel.records.map(\.id),
            expectedRecords.map(\.id)
        )

        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Load Failure

    func testLoadSetsErrorMessageWhenAPIRequestFails() async throws {
        let store = TestSleepStore()

        let api = TestSleepAPI(
            result: .failure(TestError.networkFailed)
        )

        let viewModel = SleepListViewModel(
            store: store,
            api: api
        )

        viewModel.load()

        for _ in 0..<100 {
            if viewModel.errorMessage == "Failed to load" {
                break
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            viewModel.errorMessage,
            "Failed to load"
        )

        XCTAssertTrue(viewModel.records.isEmpty)
    }

    // MARK: - onAppear

    func testOnAppearTriggersLoad() async throws {
        let expectedRecords = [
            makeRecord(
                date: date(day: 15),
                duration: 50
            )
        ]

        let api = TestSleepAPI(
            result: .success(expectedRecords)
        )

        let viewModel = SleepListViewModel(
            store: TestSleepStore(),
            api: api
        )

        viewModel.onAppear()

        for _ in 0..<100 {
            if viewModel.records.count == expectedRecords.count {
                break
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(viewModel.records.count, 1)
        XCTAssertEqual(viewModel.records.first?.id, expectedRecords.first?.id)
    }
    // MARK: - Helpers

    private func makeRecord(
        date: Date = Date(),
        duration: Int = 60
    ) -> SleepRecord {
        SleepRecord(
            date: date,
            duration: duration
        )
    }

    private func date(
        day: Int,
        hour: Int = 12
    ) -> Date {
        let calendar = Calendar.current

        return calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: calendar.date(
                byAdding: .day,
                value: day,
                to: calendar.startOfDay(for: Date())
            )!
        )!
    }
}

// MARK: - Test Doubles

private enum TestError: Error {
    case persistenceFailed
    case networkFailed
}

private final class TestSleepStore: SleepStoring {

    private(set) var saveCallCount = 0
    private(set) var savedRecords: [SleepRecord] = []

    var saveError: Error?

    func load() throws -> [SleepRecord] {
        savedRecords
    }

    func save(_ records: [SleepRecord]) throws {
        saveCallCount += 1

        if let saveError {
            throw saveError
        }

        savedRecords = records
    }
}

private struct TestSleepAPI: SleepAPI {

    let result: Result<[SleepRecord], Error>

    init(
        result: Result<[SleepRecord], Error> = .success([])
    ) {
        self.result = result
    }

    func fetchRecords() async throws -> [SleepRecord] {
        try result.get()
    }
}
