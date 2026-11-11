import XCTest
@testable import BabySleepTracker

final class SleepRecordingFlowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { start.addingTimeInterval(7200) }
    private var parent: SleepRecord { SleepRecord(date: start, duration: 60, kind: .nightSleep) }

    func testRoutesCarryTheSelectedParentAndHaveDistinctIdentities() {
        let first = parent
        let second = parent
        let route = RecordingSheet.awakeBreak(first)
        guard case .awakeBreak(let selected) = route else { return XCTFail("Missing parent payload") }
        XCTAssertEqual(selected.id, first.id)
        XCTAssertNotEqual(route.id, RecordingSheet.awakeBreak(second).id)
        XCTAssertNotEqual(route.id, RecordingSheet.sleep(editing: first, date: first.date).id)
    }

    func testOngoingNightDoesNotRequireEndAndPreservesIdentityOnEdit() throws {
        let night = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)
        var draft = SleepRecordingDraft(defaultDate: start, editing: night, now: now)
        XCTAssertEqual(draft.end, night.date, "An ongoing session must not be given an inferred end.")
        draft.end = start.addingTimeInterval(-60)
        let record = try XCTUnwrap(draft.record(kind: .nightSleep, editing: night, now: now))
        XCTAssertTrue(record.isOngoing)
        XCTAssertEqual(record.duration, 0)
        XCTAssertNil(record.endDate)
        XCTAssertNil(record.observedEnd)
        XCTAssertEqual(record.id, night.id)
        XCTAssertEqual(record.createdAt, night.createdAt)
        draft.isOngoing = false
        XCTAssertNil(draft.record(kind: .nightSleep, editing: night, now: now))
    }

    func testEditingLegacyUnknownEndDoesNotInventACompletedInterval() {
        let legacy = SleepRecord(date: start, duration: 0, kind: .nightSleep)
        let draft = SleepRecordingDraft(defaultDate: start, editing: legacy, now: now)
        XCTAssertEqual(draft.end, legacy.date)
        XCTAssertNil(draft.record(kind: .nightSleep, editing: legacy, now: now))
    }

    func testCompletedNightRequiresAnExplicitValidEndAndPreservesMidnightDates() throws {
        let midnight = ISO8601DateFormatter().date(from: "2023-11-15T00:00:00Z")!
        var draft = SleepRecordingDraft(defaultDate: midnight, now: midnight.addingTimeInterval(7200))
        draft.start = midnight.addingTimeInterval(-3600)
        draft.end = midnight.addingTimeInterval(3600)
        let record = try XCTUnwrap(draft.record(kind: .nightSleep, now: midnight.addingTimeInterval(7200)))
        XCTAssertFalse(record.isOngoing)
        XCTAssertEqual(record.date, draft.start)
        XCTAssertEqual(record.endDate, draft.end)
        XCTAssertEqual(record.duration, 120)
        draft.end = draft.start
        XCTAssertNotNil(draft.validationMessage(now: now))
        draft.end = now.addingTimeInterval(60)
        XCTAssertNotNil(draft.validationMessage(now: now))
    }

    func testAwakeBreakUsesCorrectParentAndExactEnd() throws {
        let sleep = parent
        var draft = AwakeBreakDraft(parent: sleep, now: now)
        draft.start = start.addingTimeInterval(600)
        draft.end = start.addingTimeInterval(1234)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertEqual(record.parentNapID, sleep.id)
        XCTAssertEqual(record.kind, .break)
        XCTAssertEqual(record.endDate, draft.end)
        XCTAssertEqual(record.duration, 10)
        XCTAssertEqual(draft.netMinutes(existing: [], now: now), 49)
    }

    func testEditingBreakKeepsItsIdentityAndDoesNotOverlapItself() throws {
        let sleep = parent
        let original = SleepRecord(date: start.addingTimeInterval(600), duration: 10,
                                   kind: .break, parentNapID: sleep.id, createdAt: start)
        let draft = AwakeBreakDraft(parent: sleep, editing: original, now: now)
        let updated = try XCTUnwrap(draft.record(existing: [original], now: now))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.parentNapID, sleep.id)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(draft.netMinutes(existing: [original], now: now), 50)
    }

    func testAwakeBreakRejectsInvalidBoundsZeroDurationAndOverlap() throws {
        let sleep = parent
        var draft = AwakeBreakDraft(parent: sleep, now: now)
        let existing = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertNil(draft.record(existing: [existing], now: now))
        let unrelated = SleepRecord(date: existing.date, duration: 5, kind: .break, parentNapID: UUID())
        XCTAssertNotNil(draft.record(existing: [unrelated], now: now))
        draft.start = try XCTUnwrap(existing.observedEnd)
        draft.end = draft.start.addingTimeInterval(300)
        XCTAssertNotNil(draft.record(existing: [existing], now: now)) // Adjacent intervals are valid.
        draft.start = start.addingTimeInterval(-60)
        XCTAssertNil(draft.record(existing: [], now: now))
        draft.start = start
        draft.end = start
        XCTAssertNil(draft.record(existing: [], now: now))
        draft.end = start.addingTimeInterval(3660)
        XCTAssertNil(draft.record(existing: [], now: now))
    }

    func testBreakDuringOngoingNightDoesNotCompleteParentAndCannotExtendPastNow() throws {
        let suite = "SleepRecordingFlowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let sleep = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true)
        var draft = AwakeBreakDraft(parent: sleep, now: now)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertTrue(persistence.save([sleep]))
        XCTAssertTrue(persistence.saveRecording(record, now: now))
        let savedParent = try XCTUnwrap(persistence.load()?.first(where: { $0.id == sleep.id }))
        XCTAssertTrue(savedParent.isOngoing)
        XCTAssertNil(savedParent.observedEnd)
        draft.end = now.addingTimeInterval(60)
        XCTAssertNil(draft.record(existing: [], now: now))
    }

    func testSaveRefreshesNetSleepAndPreservesNewerRecords() throws {
        let suite = "SleepRecordingFlowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let sleep = parent
        let other = SleepRecord(date: now, duration: 10)
        XCTAssertTrue(persistence.save([sleep, other]))
        let draft = AwakeBreakDraft(parent: sleep, now: now)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        let notification = expectation(forNotification: .sleepRecordsDidChange, object: nil) { _ in
            let loaded = persistence.load() ?? []
            return loaded.count == 3 && sleep.totalMinutes(breaks: loaded, at: self.now) == 55
        }
        XCTAssertTrue(persistence.saveRecording(record, now: now))
        wait(for: [notification], timeout: 1)
        XCTAssertEqual(persistence.load()?.map(\.id), [sleep.id, other.id, record.id])
        // A second sheet with a different ID must not duplicate the same interval.
        let duplicate = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertFalse(persistence.saveRecording(duplicate, now: now))
        XCTAssertEqual(persistence.load()?.count, 3)
    }

    func testStaleBreakCannotSaveAfterParentWasDeletedOrShortened() throws {
        let suite = "SleepRecordingFlowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let sleep = parent
        let record = try XCTUnwrap(AwakeBreakDraft(parent: sleep, now: now).record(existing: [], now: now))
        XCTAssertTrue(persistence.save([sleep]))
        XCTAssertTrue(persistence.save([]))
        XCTAssertFalse(persistence.saveRecording(record, now: now))
        let shortened = SleepRecord(id: sleep.id, date: start, duration: 1, kind: .nightSleep)
        XCTAssertTrue(persistence.save([shortened]))
        XCTAssertFalse(persistence.saveRecording(record, now: now))
        XCTAssertEqual(persistence.load()?.count, 1)
    }

    func testInvalidStoredDataIsNotOverwrittenByARecordingSave() throws {
        let suite = "SleepRecordingFlowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = Data("invalid".utf8)
        defaults.set(invalid, forKey: "sleepRecords")
        XCTAssertFalse(SleepRecordPersistence(defaults: defaults).saveRecording(parent, now: now))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), invalid)
    }

    func testSubmissionSavesAndDismissesExactlyOnceAndAllowsRetryOnFailure() {
        var submission = RecordingSubmission()
        var saved = 0
        var dismissed = 0
        submission.submit(nil, save: { _ in saved += 1; return true }, dismiss: { dismissed += 1 })
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(dismissed, 0)
        submission.submit(parent, save: { _ in false }, dismiss: { dismissed += 1 })
        XCTAssertFalse(submission.isSubmitted)
        for _ in 0..<2 {
            submission.submit(parent, save: { _ in saved += 1; return true }, dismiss: { dismissed += 1 })
        }
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(dismissed, 1)
    }
}
