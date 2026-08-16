
import XCTest
@testable import BabySleepTracker

final class DailyWakeRecordTests: XCTestCase {

    func testInitStoresProvidedValues() {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let wakeTime = Date(timeIntervalSince1970: 1_700_002_000)

        let record = DailyWakeRecord(
            id: id,
            day: day,
            wakeTime: wakeTime
        )

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.day, day)
        XCTAssertEqual(record.wakeTime, wakeTime)
    }

    func testInitGeneratesUniqueIDByDefault() {
        let day = Date()
        let wakeTime = Date()

        let first = DailyWakeRecord(
            day: day,
            wakeTime: wakeTime
        )

        let second = DailyWakeRecord(
            day: day,
            wakeTime: wakeTime
        )

        XCTAssertNotEqual(first.id, second.id)
    }

    func testRecordCanBeEncodedAndDecoded() throws {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let wakeTime = Date(timeIntervalSince1970: 1_700_002_000)

        let original = DailyWakeRecord(
            id: id,
            day: day,
            wakeTime: wakeTime
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(
            DailyWakeRecord.self,
            from: data
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.day, original.day)
        XCTAssertEqual(decoded.wakeTime, original.wakeTime)
    }
}
