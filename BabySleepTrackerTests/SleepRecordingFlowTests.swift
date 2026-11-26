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

    @MainActor
    func testOnlyRecordingRoutesUseFullScreenPresentation() {
        XCTAssertTrue(SleepListView.ActiveSheet.addSleep(editing: nil, defaultDate: start).isRecording)
        XCTAssertTrue(SleepListView.ActiveSheet.addNightSleep(defaultDate: start).isRecording)
        XCTAssertNotEqual(SleepListView.ActiveSheet.addNightSleep(defaultDate: start).id,
                          SleepListView.ActiveSheet.addSleep(editing: nil, defaultDate: start).id)
        XCTAssertTrue(SleepListView.ActiveSheet.addBreak(parentID: parent.id).isRecording)
        XCTAssertTrue(SleepListView.ActiveSheet.endSleep(parent: parent).isRecording)
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true)
        let finishNap = SleepListView.ActiveSheet.finishNap(parent: nap)
        XCTAssertFalse(finishNap.isRecording, "Quick nap completion opens a bottom sheet.")
        guard case .finishNap(let selected) = finishNap else { return XCTFail("Missing ongoing nap") }
        XCTAssertEqual(selected.id, nap.id)
        XCTAssertNotEqual(finishNap.id, SleepListView.ActiveSheet.endSleep(parent: nap).id)
        XCTAssertNotEqual(finishNap.id, SleepListView.ActiveSheet.finishNap(parent: parent).id)
        XCTAssertFalse(SleepListView.ActiveSheet.dayDetail(.init(day: start)).isRecording)
        XCTAssertFalse(SleepListView.ActiveSheet.wakeTime().isRecording)
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

    func testReviewNapRequiresConfirmationAndSavesPrefillsAsUnverified() throws {
        let suite = "SleepRecordingFlowTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        var draft = SleepRecordingDraft(defaultDate: start, now: now, requiresNapTimeConfirmation: true)
        var submission = RecordingSubmission()

        XCTAssertFalse(draft.isReadyToSubmit)
        submission.submit(draft: draft, kind: .dayNap, now: now, save: { _ in
            XCTFail("Saving requires confirmation of both nap times.")
            return false
        }, dismiss: { XCTFail("An unconfirmed draft must stay open.") })
        XCTAssertFalse(submission.isSubmitted)

        draft.confirmObservedNapTimes(now: now)
        XCTAssertTrue(draft.isReadyToSubmit)
        submission.submit(draft: draft, kind: .dayNap, now: now, save: { record in
            XCTAssertNil(record.observationCapture)
            return persistence.saveRecording(record, now: now)
        }, dismiss: {})
        XCTAssertTrue(submission.isSubmitted)
        let saved = try XCTUnwrap(persistence.load()?.first)
        XCTAssertEqual(saved.date, start)
        XCTAssertEqual(saved.observedEnd, start.addingTimeInterval(3600))
        XCTAssertEqual(TrustedObservationAdapter(defaults: defaults).snapshot().sleeps.map(\.source), [.recordedUnverified])

        let homeDraft = SleepRecordingDraft(defaultDate: start, now: now)
        XCTAssertNotNil(homeDraft.record(kind: .dayNap, now: now))
    }

    func testReviewNapRequiresReconfirmationAfterEitherTimeChanges() {
        var draft = SleepRecordingDraft(defaultDate: start, now: now, requiresNapTimeConfirmation: true)
        draft.start = start.addingTimeInterval(15 * 60)
        draft.end = start.addingTimeInterval(45 * 60)
        XCTAssertFalse(draft.isReadyToSubmit)

        draft.confirmObservedNapTimes(now: now)
        XCTAssertTrue(draft.isReadyToSubmit)
        draft.start = start.addingTimeInterval(20 * 60)
        XCTAssertFalse(draft.isReadyToSubmit)

        draft.confirmObservedNapTimes(now: now)
        XCTAssertTrue(draft.isReadyToSubmit)
        let confirmedEnd = draft.end
        draft.end = confirmedEnd.addingTimeInterval(60)
        draft.end = confirmedEnd
        XCTAssertFalse(draft.isReadyToSubmit)

        draft.confirmObservedNapTimes(now: now)
        XCTAssertTrue(draft.isReadyToSubmit)
    }

    func testReviewNapCannotConfirmAnInvalidInterval() {
        var draft = SleepRecordingDraft(defaultDate: start, now: now, requiresNapTimeConfirmation: true)
        draft.end = draft.start
        draft.confirmObservedNapTimes(now: now)
        XCTAssertFalse(draft.isReadyToSubmit)

        draft.end = now.addingTimeInterval(60)
        draft.confirmObservedNapTimes(now: now)
        XCTAssertFalse(draft.isReadyToSubmit)
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
        XCTAssertTrue(persistence.save([sleep]))
        var draft = AwakeBreakDraft(parent: try XCTUnwrap(persistence.load()?.first), now: now)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
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
        let draft = AwakeBreakDraft(parent: try XCTUnwrap(persistence.load()?.first { $0.id == sleep.id }), now: now)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        let notification = expectation(forNotification: .sleepRecordsDidChange, object: nil) { _ in
            let loaded = persistence.load() ?? []
            return loaded.count == 3 && sleep.totalMinutes(breaks: loaded, at: self.now) == 55
        }
        XCTAssertTrue(persistence.saveRecording(record, now: now))
        wait(for: [notification], timeout: 1)
        XCTAssertEqual(persistence.load()?.map(\.id), [sleep.id, other.id, record.id])
        // A second sheet with a different ID must not duplicate the same interval.
        let currentParent = try XCTUnwrap(persistence.load()?.first { $0.id == sleep.id })
        let duplicateDraft = AwakeBreakDraft(parent: currentParent, now: now)
        XCTAssertEqual(duplicateDraft.validationMessage(existing: persistence.load()!, now: now),
                       "This interval overlaps an existing awake break. Review its start and end.")
        let duplicate = try XCTUnwrap(duplicateDraft.record(existing: [], now: now))
        XCTAssertEqual(duplicate.parentRevision, currentParent.persistedRevision)
        XCTAssertNotNil(duplicate.parentRevision)
        XCTAssertNotEqual(duplicate.id, record.id)
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

extension SleepRecordingFlowTests {
    private var napCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testFinishNapCancelPreservesTheStoredOngoingSession() throws {
        let suite = "FinishNapTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        XCTAssertTrue(persistence.save([nap]))
        let original = try XCTUnwrap(persistence.load()?.first)
        let before = defaults.data(forKey: "sleepRecords")
        var draft = NapCompletionDraft(parent: original, now: now, calendar: napCalendar)
        let selected = now.addingTimeInterval(-600)
        draft.selectEnd(selected, changesDay: true)
        draft.selectEnd(selected, changesDay: false)

        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before, "Opening or editing the sheet must not finish the nap.")
        XCTAssertTrue(draft.abandon())
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before)
        let stored = try XCTUnwrap(persistence.load()?.first)
        XCTAssertTrue(stored.isOngoing)
        XCTAssertNil(stored.observedEnd)
        XCTAssertFalse(draft.isSubmitted)
    }

    func testFinishNapSavesTheSelectedEndOnceAndPreservesIdentityBreaksAndWakeRecords() throws {
        let suite = "FinishNapTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start.addingTimeInterval(3))
        let awake = SleepRecord(date: start.addingTimeInterval(600), duration: 5, kind: .break, parentNapID: nap.id, createdAt: start)
        let other = SleepRecord(date: start.addingTimeInterval(-3600), duration: 30, kind: .dayNap, createdAt: start)
        XCTAssertTrue(persistence.save([nap, awake, other]))
        let original = try XCTUnwrap(persistence.load()?.first { $0.id == nap.id })
        let records = try XCTUnwrap(persistence.load())
        let wakePersistence = DailyWakeRecordPersistence(defaults: defaults)
        let wakesBefore = defaults.data(forKey: "dailyWakeRecords_v1")
        var draft = NapCompletionDraft(parent: original, now: now, calendar: napCalendar)
        let selected = try XCTUnwrap(napCalendar.dateInterval(of: .minute, for: now.addingTimeInterval(-1200))?.start)
        draft.selectEnd(selected, changesDay: true)
        draft.selectEnd(selected, changesDay: false)
        XCTAssertEqual(draft.end, selected)
        XCTAssertNil(draft.validationMessage(records: records, now: now))

        var saves = 0
        var dismissals = 0
        let save: (SleepRecord) -> Bool = { record in
            saves += 1
            XCTAssertEqual(record.id, original.id)
            XCTAssertEqual(record.date, original.date)
            XCTAssertEqual(record.createdAt, original.createdAt)
            XCTAssertEqual(record.kind, .dayNap)
            XCTAssertFalse(record.isOngoing)
            XCTAssertEqual(record.endDate, selected)
            XCTAssertEqual(record.observationCapture?.confirmsStart, false)
            return persistence.saveRecording(record, now: self.now)
        }
        XCTAssertTrue(draft.submit(records: records, now: now, save: save, dismiss: { dismissals += 1 }))
        _ = draft.submit(records: records, now: now, save: save, dismiss: { dismissals += 1 })
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(draft.isSubmitted)

        let stored = try XCTUnwrap(persistence.load())
        XCTAssertEqual(Set(stored.map(\.id)), Set([nap.id, awake.id, other.id]))
        let completed = try XCTUnwrap(stored.first { $0.id == nap.id })
        XCTAssertEqual(completed.observedEnd, selected)
        XCTAssertEqual(completed.totalMinutes(breaks: stored, at: now), Int(selected.timeIntervalSince(start) / 60) - 5)
        XCTAssertEqual(stored.first { $0.id == awake.id }?.observedEnd, awake.observedEnd)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakesBefore)
        XCTAssertTrue((wakePersistence.load() ?? []).isEmpty, "Finishing a daytime nap must not create a morning wake observation.")
    }

    func testFinishNapRejectsInvalidEndTimesAndNonOngoingNapParents() {
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        for selected in [start, start.addingTimeInterval(-60), now.addingTimeInterval(120)] {
            var draft = NapCompletionDraft(parent: nap, now: now, calendar: napCalendar)
            draft.selectEnd(selected, changesDay: true)
            draft.selectEnd(selected, changesDay: false)
            XCTAssertNotNil(draft.validationMessage(records: [nap], now: now))
            XCTAssertFalse(draft.submit(records: [nap], now: now, save: { _ in
                XCTFail("An invalid endpoint must not be submitted.")
                return true
            }, dismiss: { XCTFail("An invalid draft must stay open.") }))
        }
        let ongoingNight = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true)
        for invalid in [ongoingNight, SleepRecord(date: start, duration: 30, kind: .dayNap)] {
            var draft = NapCompletionDraft(parent: invalid, now: now, calendar: napCalendar)
            XCTAssertNotNil(draft.validationMessage(records: [invalid], now: now))
            XCTAssertFalse(draft.submit(records: [invalid], now: now, save: { _ in
                XCTFail("Quick completion is only for ongoing daytime naps.")
                return true
            }, dismiss: { XCTFail("An invalid parent must stay open.") }))
        }
    }

    func testFinishNapRechecksLatestParentAndAwakeBreakBeforeSaving() throws {
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        var draft = NapCompletionDraft(parent: nap, now: now, calendar: napCalendar)
        let selected = try XCTUnwrap(napCalendar.dateInterval(of: .minute, for: now.addingTimeInterval(-1200))?.start)
        draft.selectEnd(selected, changesDay: true)
        draft.selectEnd(selected, changesDay: false)
        XCTAssertNil(draft.validationMessage(records: [nap], now: now))

        let newBreak = SleepRecord(date: selected.addingTimeInterval(-60), duration: 5, kind: .break, parentNapID: nap.id)
        let changed = SleepRecord(id: nap.id, date: nap.date, duration: 30, kind: .dayNap,
                                  createdAt: nap.createdAt, endDate: nap.date.addingTimeInterval(1800))
        for latest in [[], [changed], [nap, newBreak]] {
            XCTAssertNotNil(draft.validationMessage(records: latest, now: now))
            XCTAssertFalse(draft.submit(records: latest, now: now, save: { _ in
                XCTFail("A stale parent or a later awake break must block completion.")
                return true
            }, dismiss: { XCTFail("A rejected completion must stay open.") }))
        }
        let unrelated = SleepRecord(date: newBreak.date, duration: newBreak.duration, kind: .break, parentNapID: UUID())
        XCTAssertNil(draft.validationMessage(records: [nap, unrelated], now: now))
    }

    func testFinishNapEnforcesTheOneMinuteMinimumAtSubmission() {
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        let tooSoon = start.addingTimeInterval(59)
        var early = NapCompletionDraft(parent: nap, now: tooSoon, calendar: napCalendar)
        XCTAssertNotNil(early.validationMessage(records: [nap], now: tooSoon))
        XCTAssertFalse(early.submit(records: [nap], now: tooSoon, save: { _ in
            XCTFail("A nap shorter than one minute must not be submitted.")
            return true
        }, dismiss: { XCTFail("An invalid draft must stay open.") }))

        let minimum = start.addingTimeInterval(60)
        var valid = NapCompletionDraft(parent: nap, now: minimum, calendar: napCalendar)
        XCTAssertNil(valid.validationMessage(records: [nap], now: minimum))
        XCTAssertTrue(valid.submit(records: [nap], now: minimum, save: { record in
            XCTAssertEqual(record.duration, 1)
            XCTAssertEqual(record.endDate, minimum)
            return true
        }, dismiss: {}))
    }

    func testFinishNapPersistenceRejectsABreakAddedAfterDraftValidation() throws {
        let suite = "FinishNapTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = SleepRecordPersistence(defaults: defaults)
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        XCTAssertTrue(persistence.save([nap]))
        let snapshot = try XCTUnwrap(persistence.load())
        let original = try XCTUnwrap(snapshot.first)
        let selected = try XCTUnwrap(napCalendar.dateInterval(of: .minute, for: now.addingTimeInterval(-1200))?.start)
        var draft = NapCompletionDraft(parent: original, now: now, calendar: napCalendar)
        draft.selectEnd(selected, changesDay: true)
        draft.selectEnd(selected, changesDay: false)
        XCTAssertNil(draft.validationMessage(records: snapshot, now: now))

        var breakDraft = AwakeBreakDraft(parent: original, now: now)
        breakDraft.start = selected.addingTimeInterval(-60)
        breakDraft.end = selected.addingTimeInterval(240)
        let addedBreak = try XCTUnwrap(breakDraft.record(existing: snapshot, now: now))
        var saveAttempts = 0
        var dismissals = 0
        XCTAssertFalse(draft.submit(records: snapshot, now: now, save: { candidate in
            saveAttempts += 1
            // Simulate a second editor saving a valid break after this sheet's last read.
            guard persistence.saveRecording(addedBreak, now: self.now) else {
                XCTFail("The concurrent awake break must be accepted for the ongoing nap.")
                return false
            }
            let currentParent = persistence.load()?.first { $0.id == original.id }
            XCTAssertTrue(currentParent.map { SleepRecordVersion(original).matches($0) } == true,
                          "Only the attached breaks changed; the original parent revision still matches.")
            let saved = persistence.saveRecording(candidate, now: self.now)
            XCTAssertFalse(saved, "Persistence must recheck latest breaks under the write lock.")
            return saved
        }, dismiss: { dismissals += 1 }))
        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(draft.isSubmitted)
        XCTAssertEqual(draft.end, selected)

        let stored = try XCTUnwrap(persistence.load())
        XCTAssertEqual(Set(stored.map(\.id)), Set([original.id, addedBreak.id]))
        let stillOpen = try XCTUnwrap(stored.first { $0.id == original.id })
        XCTAssertTrue(stillOpen.isOngoing)
        XCTAssertNil(stillOpen.observedEnd)
        XCTAssertEqual(stored.first { $0.id == addedBreak.id }?.observedEnd, addedBreak.observedEnd)
    }

    func testFinishNapTimeValidationRefreshDoesNotMoveTheSelectedEnd() throws {
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        var draft = NapCompletionDraft(parent: nap, now: now, calendar: napCalendar)
        let selected = try XCTUnwrap(napCalendar.dateInterval(of: .minute, for: now.addingTimeInterval(120))?.start)
        draft.selectEnd(selected, changesDay: true)
        draft.selectEnd(selected, changesDay: false)
        XCTAssertEqual(draft.end, selected)
        XCTAssertNotNil(draft.validationMessage(records: [nap], now: now))

        XCTAssertNil(draft.validationMessage(records: [nap], now: selected))
        XCTAssertEqual(draft.end, selected, "Advancing the reference clock must not silently replace the chosen end.")
        XCTAssertFalse(draft.isSubmitted)
    }

    func testFinishNapFailedSaveRetainsSelectedTimeAndCanRetry() {
        let nap = SleepRecord(date: start, duration: 0, kind: .dayNap, isOngoing: true, createdAt: start)
        var draft = NapCompletionDraft(parent: nap, now: now, calendar: napCalendar)
        var attempts = 0
        var dismissals = 0
        XCTAssertFalse(draft.submit(records: [nap], now: now, save: { record in
            attempts += 1
            XCTAssertEqual(record.endDate, self.now)
            return false
        }, dismiss: { dismissals += 1 }))
        XCTAssertFalse(draft.isSubmitted)
        XCTAssertEqual(draft.end, now)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(draft.submit(records: [nap], now: now, save: { record in
            attempts += 1
            XCTAssertEqual(record.endDate, self.now)
            XCTAssertEqual(record.observationCapture?.confirmsStart, false)
            return true
        }, dismiss: { dismissals += 1 }))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(dismissals, 1)
    }
}

extension SleepRecordingFlowTests {
    func testExplicitHistoricalConfirmationAcceptsAnUnchangedEndAndClearsOnEditRevert() throws {
        let now = Date(timeIntervalSinceReferenceDate: 500_000)
        let night = SleepRecord(date: now.addingTimeInterval(-48 * 3600), duration: 0,
                                kind: .nightSleep, isOngoing: true)
        var draft = SleepRecordingDraft(defaultDate: night.date, editing: night, now: now)
        draft.prepareForEnding(at: now, calendar: .current, requireConfirmation: true)
        XCTAssertNil(draft.record(kind: .nightSleep, editing: night, now: now))
        draft.confirmObservedEnd(now: now)
        XCTAssertTrue(draft.isReadyToSubmit)
        var submission = RecordingSubmission()
        var captured: SleepRecord?
        submission.submit(draft: draft, kind: .nightSleep, editing: night, now: now,
                          save: { captured = $0; return false }, dismiss: {})
        let first = try XCTUnwrap(captured)
        XCTAssertEqual(first.endDate, now)
        XCTAssertEqual(first.observationCapture?.confirmsStart, false)
        XCTAssertNotNil(first.nightCompletionIntent)
        XCTAssertFalse(submission.isSubmitted)
        XCTAssertTrue(draft.isReadyToSubmit, "Retry retains the exact confirmation.")

        draft.end = now.addingTimeInterval(-60)
        draft.end = now
        XCTAssertFalse(draft.isReadyToSubmit)
        XCTAssertNil(draft.record(kind: .nightSleep, editing: night, now: now))
        draft.isOngoing = true
        XCTAssertTrue(draft.isReadyToSubmit)
    }

    func testHistoricalEndpointCompositionPreservesDateAndTimeInBothPickerOrders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
        }
        let initial = try date(19, 20, 11).addingTimeInterval(3.125)
        let pickedDay = try date(15, 0, 0)
        let pickedTime = try date(19, 7, 21)
        let dateFirst = try XCTUnwrap(RecordingEndpointSelection.combine(day: pickedDay, time: initial, preserving: initial, calendar: calendar))
        let timeAfterDate = RecordingEndpointSelection.combine(day: dateFirst, time: pickedTime, preserving: dateFirst, calendar: calendar)
        let timeFirst = try XCTUnwrap(RecordingEndpointSelection.combine(day: initial, time: pickedTime, preserving: initial, calendar: calendar))
        let dateAfterTime = RecordingEndpointSelection.combine(day: pickedDay, time: timeFirst, preserving: timeFirst, calendar: calendar)
        XCTAssertEqual(timeAfterDate, try date(15, 7, 21))
        XCTAssertEqual(timeAfterDate, dateAfterTime)
        XCTAssertEqual(RecordingEndpointSelection.combine(day: initial, time: initial, preserving: initial, calendar: calendar), initial)
    }

    func testHistoricalConfirmationSurvivesCanceledPickerButAcceptedEditAndRevertClearsIt() throws {
        let now = Date(timeIntervalSinceReferenceDate: 500_000)
        let night = SleepRecord(date: now.addingTimeInterval(-48 * 3600), duration: 0,
                                kind: .nightSleep, isOngoing: true)
        var draft = SleepRecordingDraft(defaultDate: night.date, editing: night, now: now)
        draft.prepareForEnding(at: now, calendar: .current, requireConfirmation: true)
        draft.confirmObservedEnd(now: now)

        var canceled = RecordingEndpointSelection(draft.end)
        canceled.select(now.addingTimeInterval(-60))
        XCTAssertTrue(canceled.hasChanged)
        XCTAssertEqual(draft.end, now)
        XCTAssertTrue(draft.hasConfirmedEnd)

        draft.applyEndSelection(RecordingEndpointSelection(draft.end))
        XCTAssertTrue(draft.hasConfirmedEnd, "Done on an unchanged picker keeps the earlier explicit confirmation.")
        canceled.select(now)
        draft.applyEndSelection(canceled)
        XCTAssertEqual(draft.end, now)
        XCTAssertFalse(draft.hasConfirmedEnd)
        XCTAssertFalse(draft.isReadyToSubmit)
        XCTAssertNil(draft.record(kind: .nightSleep, editing: night, now: now))
        draft.confirmObservedEnd(now: now)
        let record = try XCTUnwrap(draft.record(kind: .nightSleep, editing: night, now: now))
        XCTAssertEqual(record.date, night.date)
        XCTAssertEqual(record.kind, .nightSleep)
        XCTAssertEqual(record.observedEnd, now)
    }
}

extension SleepRecordingFlowTests {
    func testHistoricalEndpointCompositionRejectsDSTGapAndRetainsSelectedFold() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
        }

        let beforeGap = try local(3, 7, 2, 30)
        let gapDay = try local(3, 8, 0, 0)
        XCTAssertNil(RecordingEndpointSelection.combine(day: gapDay, time: beforeGap, preserving: beforeGap, calendar: calendar))

        let firstOccurrence = try local(11, 1, 1, 30)
        let secondOccurrence = firstOccurrence.addingTimeInterval(3600)
        XCTAssertEqual(calendar.component(.hour, from: secondOccurrence), 1)
        XCTAssertEqual(RecordingEndpointSelection.combine(day: firstOccurrence, time: secondOccurrence,
                                                          preserving: firstOccurrence, calendar: calendar), secondOccurrence)
    }
}
