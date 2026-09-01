import XCTest
@testable import BabySleepTracker

final class SleepWakeTimeWorkflowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SleepWakeTimeWorkflowTests-\(UUID().uuidString)")!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
    }

    func testNormalizesWakeTimeAndReplacesTodayOnly() throws {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let oldToday = DailyWakeRecord(day: today, wakeTime: today)
        let otherDay = DailyWakeRecord(day: yesterday, wakeTime: yesterday)
        let selected = calendar.date(bySettingHour: 8, minute: 25, second: 42, of: yesterday)!
        let result = workflow(selected: selected, wakeRecords: [oldToday, otherDay]).execute()
        let saved = try XCTUnwrap(result.updatedWakeRecords.first { calendar.isDate($0.day, inSameDayAs: today) })

        XCTAssertEqual(saved.day, today)
        XCTAssertEqual(calendar.component(.hour, from: saved.wakeTime), 8)
        XCTAssertEqual(calendar.component(.minute, from: saved.wakeTime), 25)
        XCTAssertEqual(calendar.component(.second, from: saved.wakeTime), 0)
        XCTAssertEqual(result.updatedWakeRecords.count, 2)
        XCTAssertTrue(result.updatedWakeRecords.contains { $0.id == otherDay.id })
    }

    func testPersistsWakeRecordsAndPostsNotification() {
        let expectation = expectation(forNotification: .dailyWakeRecordsDidChange, object: nil)
        let result = workflow(selected: now).execute()
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertNotNil(defaults.data(forKey: "dailyWakeRecords_v1"))
    }

    func testSelectsLatestQualifyingNightAndPreservesMetadata() throws {
        let older = record(at: now.addingTimeInterval(-4 * 3600), kind: .nightSleep, ongoing: true)
        let latest = record(at: now.addingTimeInterval(-2 * 3600), kind: .nightSleep, ongoing: true, parent: UUID())
        let result = workflow(selected: now, sleepRecords: [older, latest]).execute()
        let closed = try XCTUnwrap(result.closedNightRecord)

        XCTAssertEqual(closed.id, latest.id)
        XCTAssertEqual(closed.date, latest.date)
        XCTAssertEqual(closed.kind, latest.kind)
        XCTAssertEqual(closed.parentNapID, latest.parentNapID)
        XCTAssertEqual(closed.createdAt, latest.createdAt)
        XCTAssertFalse(closed.isOngoing)
        XCTAssertEqual(closed.duration, 120)
        XCTAssertTrue(result.updatedSleepRecords.contains { $0.id == older.id && $0.isOngoing })
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        XCTAssertNotNil(defaults.data(forKey: "sleepRecords"))
    }

    func testIgnoresDayNapCompletedNightAndFutureNight() {
        let nap = record(at: now.addingTimeInterval(-3600), kind: .dayNap, ongoing: true)
        let completed = record(at: now.addingTimeInterval(-2 * 3600), kind: .nightSleep, ongoing: false)
        let future = record(at: now.addingTimeInterval(3600), kind: .nightSleep, ongoing: true)
        let result = workflow(selected: now, sleepRecords: [nap, completed, future]).execute()

        XCTAssertNil(result.closedNightRecord)
        XCTAssertFalse(result.sleepPersistenceSucceeded)
        XCTAssertEqual(result.updatedSleepRecords.map(\.id), [nap.id, completed.id, future.id])
    }

    func testClampsDurationToOneAnd720Minutes() throws {
        let short = record(at: now.addingTimeInterval(-30), kind: .nightSleep, ongoing: true)
        XCTAssertEqual(workflow(selected: now, sleepRecords: [short]).execute().closedNightRecord?.duration, 1)

        let long = record(at: now.addingTimeInterval(-13 * 3600), kind: .nightSleep, ongoing: true)
        let result = workflow(selected: now, sleepRecords: [long]).execute()
        XCTAssertEqual(result.closedNightRecord?.duration, 720)
        let data = try XCTUnwrap(defaults.data(forKey: "sleepRecords"))
        XCTAssertEqual(try JSONDecoder().decode([SleepRecord].self, from: data).first?.duration, 720)
    }

    private func workflow(selected: Date, wakeRecords: [DailyWakeRecord] = [], sleepRecords: [SleepRecord] = []) -> SleepWakeTimeWorkflow {
        SleepWakeTimeWorkflow(selectedWakeTime: selected, now: now, calendar: calendar, wakeRecords: wakeRecords, sleepRecords: sleepRecords, wakePersistence: DailyWakeRecordPersistence(defaults: defaults), sleepPersistence: SleepRecordPersistence(defaults: defaults))
    }

    private func record(at date: Date, kind: SleepKind, ongoing: Bool, parent: UUID? = nil) -> SleepRecord {
        SleepRecord(date: date, duration: 0, kind: kind, parentNapID: parent, isOngoing: ongoing, createdAt: date)
    }
}
