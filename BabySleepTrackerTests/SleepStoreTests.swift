
import XCTest
@testable import BabySleepTracker

final class SleepStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SleepStore!

    override func setUp() {
        super.setUp()

        let suiteName = "SleepStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SleepStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(
            forName: defaultsSuiteName
        )

        store = nil
        defaults = nil

        super.tearDown()
    }

    private var defaultsSuiteName: String {
        defaults.dictionaryRepresentation().keys.first ?? ""
    }

    // MARK: - Load

    func testLoadReturnsEmptyArrayWhenNoRecordsExist() throws {
        let records = try store.load()

        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - Save & Load

    func testSaveStoresRecordsAndLoadReturnsThem() throws {
        let record = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 60,
            kind: .dayNap
        )

        try store.save([record])

        let loadedRecords = try store.load()

        XCTAssertEqual(loadedRecords.count, 1)
        XCTAssertEqual(loadedRecords.first?.id, record.id)
        XCTAssertEqual(loadedRecords.first?.duration, record.duration)
        XCTAssertEqual(loadedRecords.first?.kind, record.kind)
        XCTAssertEqual(loadedRecords.first?.date, record.date)
        XCTAssertEqual(
            loadedRecords.first?.parentNapID,
            record.parentNapID
        )
        XCTAssertEqual(
            loadedRecords.first?.isOngoing,
            record.isOngoing
        )
    }

    func testSaveAndLoadPreservesMultipleRecords() throws {
        let firstRecord = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 45,
            kind: .dayNap
        )

        let secondRecord = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_100_000),
            duration: 480,
            kind: .nightSleep
        )

        let breakRecord = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_200_000),
            duration: 15,
            kind: .break,
            parentNapID: firstRecord.id
        )

        try store.save([
            firstRecord,
            secondRecord,
            breakRecord
        ])

        let loadedRecords = try store.load()

        XCTAssertEqual(loadedRecords.count, 3)

        XCTAssertEqual(loadedRecords[0].id, firstRecord.id)
        XCTAssertEqual(loadedRecords[1].id, secondRecord.id)
        XCTAssertEqual(loadedRecords[2].id, breakRecord.id)
    }

    func testSavingAgainReplacesPreviouslyStoredRecords() throws {
        let firstRecord = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 60
        )

        let secondRecord = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_100_000),
            duration: 90,
            kind: .nightSleep
        )

        try store.save([firstRecord])
        try store.save([secondRecord])

        let loadedRecords = try store.load()

        XCTAssertEqual(loadedRecords.count, 1)
        XCTAssertEqual(loadedRecords.first?.id, secondRecord.id)
        XCTAssertEqual(loadedRecords.first?.duration, 90)
    }

    // MARK: - Corrupted Data

    func testLoadThrowsDecodingFailedWhenStoredDataIsInvalid() {
        let invalidData = Data("not valid json".utf8)

        defaults.set(
            invalidData,
            forKey: "sleep_records_v1"
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard let storeError = error as? SleepStoreError else {
                return XCTFail("Expected SleepStoreError")
            }

            guard case .decodingFailed = storeError else {
                return XCTFail(
                    "Expected SleepStoreError.decodingFailed, got \(storeError)"
                )
            }
        }
    }

    // MARK: - Persistence Isolation

    func testDifferentStoresWithDifferentUserDefaultsAreIndependent() throws {
        let firstSuiteName = "SleepStoreTests-first-\(UUID().uuidString)"
        let secondSuiteName = "SleepStoreTests-second-\(UUID().uuidString)"

        let firstDefaults = UserDefaults(suiteName: firstSuiteName)!
        let secondDefaults = UserDefaults(suiteName: secondSuiteName)!

        let firstStore = SleepStore(defaults: firstDefaults)
        let secondStore = SleepStore(defaults: secondDefaults)

        let record = SleepRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30
        )

        try firstStore.save([record])

        XCTAssertEqual(try firstStore.load().count, 1)
        XCTAssertTrue(try secondStore.load().isEmpty)

        firstDefaults.removePersistentDomain(forName: firstSuiteName)
        secondDefaults.removePersistentDomain(forName: secondSuiteName)
    }
}
