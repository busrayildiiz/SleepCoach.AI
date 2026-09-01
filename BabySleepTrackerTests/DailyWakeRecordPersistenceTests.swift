import XCTest
@testable import BabySleepTracker

final class DailyWakeRecordPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var persistence: DailyWakeRecordPersistence!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DailyWakeRecordPersistenceTests-\(UUID().uuidString)")!
        persistence = DailyWakeRecordPersistence(defaults: defaults)
    }

    override func tearDown() {
        persistence = nil
        defaults = nil
        super.tearDown()
    }

    func testLoadReturnsValidRecords() throws {
        let records = [makeRecord(day: 100, wakeTime: 200)]
        defaults.set(try JSONEncoder().encode(records), forKey: "dailyWakeRecords_v1")

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.map(\.id), records.map(\.id))
        XCTAssertEqual(loaded.map(\.day), records.map(\.day))
        XCTAssertEqual(loaded.map(\.wakeTime), records.map(\.wakeTime))
    }

    func testLoadReturnsNilWhenDataIsMissing() {
        XCTAssertNil(persistence.load())
    }

    func testLoadReturnsNilForInvalidJSON() {
        defaults.set(Data("invalid".utf8), forKey: "dailyWakeRecords_v1")

        XCTAssertNil(persistence.load())
    }

    func testSaveStoresRecordsUnderDailyWakeRecordsKeyInOrderWithValuesPreserved() throws {
        let first = makeRecord(day: 100, wakeTime: 200)
        let second = makeRecord(day: 300, wakeTime: 400)
        let records = [first, second]

        XCTAssertTrue(persistence.save(records))
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.map(\.id), records.map(\.id))
        XCTAssertEqual(loaded.map(\.day), records.map(\.day))
        XCTAssertEqual(loaded.map(\.wakeTime), records.map(\.wakeTime))
    }

    func testSavePostsNotificationAfterSuccessfulSave() {
        let expectation = expectation(forNotification: .dailyWakeRecordsDidChange, object: nil)

        XCTAssertTrue(persistence.save([makeRecord(day: 100, wakeTime: 200)]))
        wait(for: [expectation], timeout: 1)
    }

    private func makeRecord(day: TimeInterval, wakeTime: TimeInterval) -> DailyWakeRecord {
        DailyWakeRecord(
            day: Date(timeIntervalSince1970: day),
            wakeTime: Date(timeIntervalSince1970: wakeTime)
        )
    }
}
