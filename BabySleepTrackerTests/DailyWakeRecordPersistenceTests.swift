import XCTest
@testable import BabySleepTracker

final class DailyWakeRecordPersistenceTests: XCTestCase {
    func testUnavailableProtectedStorageCannotReplaceWakeHistory() throws {
        let store = TestPrivateDataStore()
        let original = try JSONEncoder().encode([makeRecord(day: 100, wakeTime: 200)])
        store.set(original, forKey: "dailyWakeRecords_v1")
        let attempts = store.writeAttempts
        store.isAvailable = false
        let persistence = DailyWakeRecordPersistence(defaults: store)

        XCTAssertNil(persistence.load())
        XCTAssertFalse(persistence.save([]))
        XCTAssertEqual(store.writeAttempts, attempts)
        XCTAssertEqual(store.values["dailyWakeRecords_v1"] as? Data, original)
    }

    func testProtectedWakeWriteFailureDoesNotPublishSuccessfulReplacement() throws {
        let store = TestPrivateDataStore()
        let persistence = DailyWakeRecordPersistence(defaults: store)
        XCTAssertTrue(persistence.save([makeRecord(day: 100, wakeTime: 200)]))
        let original = try XCTUnwrap(store.data(forKey: "dailyWakeRecords_v1"))
        store.failWrites = true

        XCTAssertFalse(persistence.save([makeRecord(day: 300, wakeTime: 400)]))
        XCTAssertEqual(store.values["dailyWakeRecords_v1"] as? Data, original)
        XCTAssertFalse(store.isAvailable)
    }

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
