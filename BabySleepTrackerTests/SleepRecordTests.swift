
import XCTest
@testable import BabySleepTracker

final class SleepRecordTests: XCTestCase {

    // MARK: - Initialization

    func testInitUsesProvidedValues() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let createdAt = Date(timeIntervalSince1970: 2_000_000)
        let parentNapID = UUID()

        let record = SleepRecord(
            id: id,
            date: date,
            duration: 90,
            kind: .nightSleep,
            parentNapID: parentNapID,
            isOngoing: true,
            createdAt: createdAt
        )

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.date, date)
        XCTAssertEqual(record.duration, 90)
        XCTAssertEqual(record.kind, .nightSleep)
        XCTAssertEqual(record.parentNapID, parentNapID)
        XCTAssertTrue(record.isOngoing)
        XCTAssertEqual(record.createdAt, createdAt)
    }

    func testInitUsesExpectedDefaultValues() {
        let date = Date(timeIntervalSince1970: 1_000_000)

        let record = SleepRecord(
            date: date,
            duration: 45
        )

        XCTAssertEqual(record.kind, .dayNap)
        XCTAssertNil(record.parentNapID)
        XCTAssertFalse(record.isOngoing)
        XCTAssertEqual(record.createdAt, record.createdAt)
    }

    // MARK: - effectiveDuration

    func testEffectiveDurationReturnsStoredDurationWhenSleepIsFinished() {
        let record = SleepRecord(
            date: Date(),
            duration: 75,
            isOngoing: false
        )

        XCTAssertEqual(record.effectiveDuration, 75)
    }

    func testEffectiveDurationCalculatesLiveDurationForOngoingSleep() {
        let date = Date().addingTimeInterval(-65 * 60)

        let record = SleepRecord(
            date: date,
            duration: 10,
            isOngoing: true
        )

        let effectiveDuration = record.effectiveDuration

        // Allow a small timing difference because Date() is evaluated at runtime.
        XCTAssertGreaterThanOrEqual(effectiveDuration, 64)
        XCTAssertLessThanOrEqual(effectiveDuration, 66)
    }

    func testEffectiveDurationNeverReturnsNegativeValueForFutureOngoingSleep() {
        let futureDate = Date().addingTimeInterval(10 * 60)

        let record = SleepRecord(
            date: futureDate,
            duration: 100,
            isOngoing: true
        )

        XCTAssertEqual(record.effectiveDuration, 0)
    }

    // MARK: - totalMinutes

    func testTotalMinutesSubtractsBreaksBelongingToTheSleepRecord() {
        let recordID = UUID()

        let sleep = SleepRecord(
            id: recordID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let break1 = SleepRecord(
            date: Date(),
            duration: 10,
            kind: .break,
            parentNapID: recordID
        )

        let break2 = SleepRecord(
            date: Date(),
            duration: 15,
            kind: .break,
            parentNapID: recordID
        )

        let result = sleep.totalMinutes(breaks: [break1, break2])

        XCTAssertEqual(result, 95)
    }

    func testTotalMinutesIgnoresBreaksBelongingToAnotherSleepRecord() {
        let recordID = UUID()
        let otherRecordID = UUID()

        let sleep = SleepRecord(
            id: recordID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let ownBreak = SleepRecord(
            date: Date(),
            duration: 20,
            kind: .break,
            parentNapID: recordID
        )

        let unrelatedBreak = SleepRecord(
            date: Date(),
            duration: 50,
            kind: .break,
            parentNapID: otherRecordID
        )

        let result = sleep.totalMinutes(
            breaks: [ownBreak, unrelatedBreak]
        )

        XCTAssertEqual(result, 100)
    }

    func testTotalMinutesIgnoresNonBreakRecords() {
        let recordID = UUID()

        let sleep = SleepRecord(
            id: recordID,
            date: Date(),
            duration: 120,
            kind: .dayNap
        )

        let anotherNap = SleepRecord(
            date: Date(),
            duration: 40,
            kind: .dayNap,
            parentNapID: recordID
        )

        let nightSleep = SleepRecord(
            date: Date(),
            duration: 60,
            kind: .nightSleep,
            parentNapID: recordID
        )

        let result = sleep.totalMinutes(
            breaks: [anotherNap, nightSleep]
        )

        XCTAssertEqual(result, 120)
    }

    func testTotalMinutesNeverReturnsNegativeValue() {
        let recordID = UUID()

        let sleep = SleepRecord(
            id: recordID,
            date: Date(),
            duration: 20,
            kind: .dayNap
        )

        let breakRecord = SleepRecord(
            date: Date(),
            duration: 30,
            kind: .break,
            parentNapID: recordID
        )

        let result = sleep.totalMinutes(breaks: [breakRecord])

        XCTAssertEqual(result, 0)
    }

    // MARK: - formattedDuration

    func testFormattedDurationForHoursAndMinutes() {
        let record = SleepRecord(
            date: Date(),
            duration: 125
        )

        XCTAssertEqual(record.formattedDuration, "2 h 5m")
    }

    func testFormattedDurationForMinutesOnly() {
        let record = SleepRecord(
            date: Date(),
            duration: 45
        )

        XCTAssertEqual(record.formattedDuration, "0 h 45m")
    }

    func testFormattedDurationForExactHours() {
        let record = SleepRecord(
            date: Date(),
            duration: 120
        )

        XCTAssertEqual(record.formattedDuration, "2 h 0m")
    }

    // MARK: - displayDate

    func testDisplayDateReturnsTodayForToday() {
        let record = SleepRecord(
            date: Date(),
            duration: 30
        )

        XCTAssertEqual(record.displayDate, "Today")
    }

    func testDisplayDateReturnsYesterdayForYesterday() {
        let yesterday = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: Date()
        )!

        let record = SleepRecord(
            date: yesterday,
            duration: 30
        )

        XCTAssertEqual(record.displayDate, "Yesterday")
    }

    // MARK: - Codable

    func testSleepRecordCanBeEncodedAndDecoded() throws {
        let id = UUID()
        let parentNapID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)

        let original = SleepRecord(
            id: id,
            date: date,
            duration: 90,
            kind: .nightSleep,
            parentNapID: parentNapID,
            isOngoing: true,
            createdAt: createdAt
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SleepRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.date, original.date)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.parentNapID, original.parentNapID)
        XCTAssertEqual(decoded.isOngoing, original.isOngoing)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
    }

    func testDecodingOldRecordWithoutIsOngoingAndCreatedAtUsesFallbackValues() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let oldRecordJSON: [String: Any] = [
            "id": id.uuidString,
            "date": date.timeIntervalSince1970,
            "duration": 90,
            "kind": "dayNap"
        ]

        let data = try JSONSerialization.data(
            withJSONObject: oldRecordJSON
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(SleepRecord.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.date, date)
        XCTAssertEqual(decoded.duration, 90)
        XCTAssertEqual(decoded.kind, .dayNap)

        XCTAssertFalse(decoded.isOngoing)
        XCTAssertEqual(decoded.createdAt, decoded.date)
        XCTAssertNil(decoded.parentNapID)
    }
}
