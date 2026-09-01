import XCTest
@testable import BabySleepTracker

final class SleepRecordPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var persistence: SleepRecordPersistence!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SleepRecordPersistenceTests-\(UUID().uuidString)")!
        persistence = SleepRecordPersistence(defaults: defaults)
    }

    override func tearDown() {
        persistence = nil
        defaults = nil
        super.tearDown()
    }

    func testLoadReturnsValidRecords() throws {
        let records = [SleepRecord(date: Date(timeIntervalSince1970: 100), duration: 60)]
        defaults.set(try JSONEncoder().encode(records), forKey: "sleepRecords")

        XCTAssertEqual(try XCTUnwrap(persistence.load()).map(\ .id), records.map(\ .id))
    }

    func testLoadReturnsNilWhenNoDataExists() {
        XCTAssertNil(persistence.load())
    }

    func testLoadReturnsNilForInvalidJSON() {
        defaults.set(Data("invalid".utf8), forKey: "sleepRecords")

        XCTAssertNil(persistence.load())
    }

    func testSaveStoresRecordsUnderSleepRecordsAndPreservesOrderAndValues() throws {
        let first = SleepRecord(date: Date(timeIntervalSince1970: 100), duration: 60, kind: .dayNap)
        let second = SleepRecord(date: Date(timeIntervalSince1970: 200), duration: 480, kind: .nightSleep, isOngoing: true)
        let records = [first, second]

        XCTAssertTrue(persistence.save(records))
        let loaded = try XCTUnwrap(persistence.load())

        XCTAssertEqual(loaded.count, records.count)
        XCTAssertEqual(loaded.map(\.id), records.map(\.id))
        XCTAssertEqual(loaded.map(\.date), records.map(\.date))
        XCTAssertEqual(loaded.map(\.duration), records.map(\.duration))
        XCTAssertEqual(loaded.map(\.kind), records.map(\.kind))
        XCTAssertEqual(loaded.map(\.parentNapID), records.map(\.parentNapID))
        XCTAssertEqual(loaded.map(\.isOngoing), records.map(\.isOngoing))
        XCTAssertEqual(loaded.map(\.createdAt), records.map(\.createdAt))
    }

    func testSavePostsNotificationAfterSuccessfulSave() {
        let expectation = expectation(forNotification: .sleepRecordsDidChange, object: nil)

        XCTAssertTrue(persistence.save([SleepRecord(date: Date(), duration: 30)]))
        wait(for: [expectation], timeout: 1)
    }
}
