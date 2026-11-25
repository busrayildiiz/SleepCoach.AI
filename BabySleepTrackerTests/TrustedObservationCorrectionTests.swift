import XCTest
@testable import BabySleepTracker

final class TrustedObservationCorrectionTests: XCTestCase {
    private final class ObserverGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !entered else { return false }
            entered = true; return true
        }
        var wasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    }
    private var defaults: UserDefaults!
    private var suite: String!
    private var calendar: Calendar!
    private var now: Date!
    private var sleeps: SleepRecordPersistence { .init(defaults: defaults) }
    private var wakes: DailyWakeRecordPersistence { .init(defaults: defaults) }
    private var adapter: TrustedObservationAdapter { .init(defaults: defaults) }
    private var snapshot: LearningEvidenceSnapshot { adapter.snapshot() }

    override func setUp() {
        super.setUp()
        suite = "TrustedObservationCorrectionTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }
    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0,
                      of: calendar.date(byAdding: .day, value: day, to: now)!)!
    }
    @discardableResult
    private func sleep(start: Date, end: Date?, kind: SleepKind, editing: SleepRecord? = nil) throws -> SleepRecord {
        let action = (end ?? start).addingTimeInterval(60)
        var draft = SleepRecordingDraft(defaultDate: start.addingTimeInterval(-1234), editing: editing, now: action)
        draft.start = start; draft.end = end ?? start; draft.isOngoing = end == nil
        var submission = RecordingSubmission()
        var id: UUID?
        submission.submit(draft: draft, kind: kind, editing: editing, now: action,
            save: { id = $0.id; return self.sleeps.saveRecording($0, now: action) }, dismiss: {})
        XCTAssertTrue(submission.isSubmitted)
        return try XCTUnwrap(sleeps.load()?.first { $0.id == id })
    }
    @discardableResult
    private func pause(parent: SleepRecord, start: Date, end: Date, trusted: Bool = true,
                       editing: SleepRecord? = nil) throws -> SleepRecord {
        var draft = AwakeBreakDraft(parent: parent, editing: editing, now: now)
        draft.start = start; draft.end = end
        let all = sleeps.load() ?? []
        var id: UUID?
        if trusted {
            var submission = RecordingSubmission()
            submission.submit(draft: draft, existing: all, now: now,
                save: { id = $0.id; return self.sleeps.saveRecording($0, now: self.now) }, dismiss: {})
            XCTAssertTrue(submission.isSubmitted)
        } else {
            let record = try XCTUnwrap(draft.record(existing: all, now: now))
            id = record.id
            XCTAssertTrue(sleeps.saveRecording(record, now: now))
        }
        return try XCTUnwrap(sleeps.load()?.first { $0.id == id })
    }
    private func operation(time: Date? = nil, action: Date? = nil,
                           writer: ((Data, String) -> Bool)? = nil) -> SleepWakeTimeWorkflow {
        let selected = time ?? at(0, 7)
        let action = action ?? now!
        let existing = wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: selected) }
        var draft = WakeObservationDraft(initial: selected.addingTimeInterval(-3600), existing: existing,
                                         nightRecords: sleeps.load() ?? [])
        draft.selected = selected
        var capture: WakeObservationCapture?
        XCTAssertTrue(draft.submit { _, value in capture = value; return true })
        return SleepWakeTimeWorkflow(selectedWakeTime: selected, now: action, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: .init(defaults: defaults, writer: writer),
            sleepPersistence: .init(defaults: defaults, writer: writer), capture: capture)
    }
    private func writer(failing key: String) -> (Data, String) -> Bool {
        { data, candidate in
            guard candidate != key else { return false }
            self.defaults.set(data, forKey: candidate)
            return true
        }
    }
    @discardableResult
    private func night() throws -> SleepRecord { try sleep(start: at(-1, 20), end: nil, kind: .nightSleep) }
    private func pair() throws -> (DailyWakeRecord, DailyWakeRecord) {
        XCTAssertTrue(operation(time: at(-1, 7), action: at(-1, 8)).execute().evidencePublicationSucceeded)
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        let records = try XCTUnwrap(wakes.load()).sorted { $0.wakeTime < $1.wakeTime }
        return (records[0], records[1])
    }
    private func confirm(_ pair: (DailyWakeRecord, DailyWakeRecord)) throws {
        let draft = try XCTUnwrap(adapter.beginDaytimeConfirmation(morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertTrue(draft.submit(.allNapsRecorded, at: now, using: .init(defaults: defaults)))
    }

    func testReentrantNightCorrectionCannotInheritCompletionAttestation() throws {
        let original = try night()
        let changed = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard changed.claim() else { return }
            let record = self.sleeps.load()!.first!
            let corrected = SleepRecord(id: record.id, date: record.date.addingTimeInterval(-60), duration: record.duration,
                kind: record.kind, createdAt: record.createdAt, endDate: record.endDate)
            XCTAssertTrue(self.sleeps.saveRecording(corrected, now: self.now))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result = operation().execute()
        XCTAssertTrue(changed.wasEntered)
        XCTAssertFalse(result.evidencePublicationSucceeded)
        XCTAssertEqual(sleeps.load()?.first?.date, original.date.addingTimeInterval(-60))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testReentrantWakeCorrectionCannotInheritCompletionAttestation() throws {
        _ = try night()
        let changed = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in
            guard changed.claim() else { return }
            let record = self.wakes.load()!.first!
            XCTAssertTrue(self.wakes.save([DailyWakeRecord(id: record.id, day: record.day, wakeTime: record.wakeTime.addingTimeInterval(60))]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result = operation().execute()
        XCTAssertFalse(result.evidencePublicationSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
    }
    func testMetadataObserverCannotBeOverwrittenByOuterNightWrite() throws {
        let original = try night()
        let changed = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationProvenanceDidChange, object: nil, queue: nil) { _ in
            guard changed.claim() else { return }
            let record = self.sleeps.load()!.first!
            let corrected = SleepRecord(id: record.id, date: record.date.addingTimeInterval(-60), duration: 0,
                                        kind: .nightSleep, isOngoing: true, createdAt: record.createdAt)
            XCTAssertTrue(self.sleeps.saveRecording(corrected, now: self.now))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(operation().execute().evidencePublicationSucceeded)
        XCTAssertEqual(sleeps.load()?.first?.date, original.date.addingTimeInterval(-60))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testReentrantNapInsertionRetiresTheDaytimeAnswerBeforeAcknowledgement() throws {
        let boundaries = try pair()
        let nap = SleepRecord(date: at(-1, 10), duration: 40)
        var model = DaytimeCoverageReviewModel(storage: wakes.storage)
        model.start(day: boundaries.0.day, at: now, calendar: calendar)
        model.choose(.allNapsRecorded)
        let changed = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationProvenanceDidChange,
                                                               object: nil, queue: nil) { _ in
            guard changed.claim() else { return }
            XCTAssertTrue(self.sleeps.save([nap]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.save(at: now, calendar: calendar)

        XCTAssertTrue(changed.wasEntered)
        XCTAssertEqual(model.feedback, .changed)
        XCTAssertEqual(model.inspection?.status, .invalidated)
        XCTAssertEqual(model.inspection?.naps.map(\.id), [nap.id])
        XCTAssertFalse(model.canSave)
        XCTAssertTrue(adapter.snapshot(calendar: calendar).daytime.isEmpty)
    }

    func testZeroNapInsertDeleteCannotResurrectConfirmation() throws {
        let boundaries = try pair(); try confirm(boundaries)
        let nap = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        XCTAssertTrue(snapshot.daytime.isEmpty)
        XCTAssertTrue(sleeps.delete(ids: [nap.id]))
        XCTAssertTrue(snapshot.daytime.isEmpty)
        XCTAssertTrue(ObservationProvenance.load(defaults)?.daytime.isEmpty == true)
    }
    func testNonemptyNapInsertDeleteCannotResurrectConfirmation() throws {
        let boundaries = try pair()
        _ = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        try confirm(boundaries)
        let extra = try sleep(start: at(-1, 14), end: at(-1, 15), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [extra.id]))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testDeletingAndRecreatingEquivalentNapNeedsNewConfirmation() throws {
        let boundaries = try pair()
        let nap = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        try confirm(boundaries)
        XCTAssertTrue(sleeps.delete(ids: [nap.id]))
        _ = try sleep(start: nap.date, end: nap.endDate, kind: .dayNap)
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testUnrelatedInsertDeleteKeepsConfirmation() throws {
        let boundaries = try pair(); try confirm(boundaries)
        let other = try sleep(start: at(-5, 10), end: at(-5, 11), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [other.id]))
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete)
    }
    func testFailedInvalidationPreventsNapMutation() throws {
        let boundaries = try pair(); try confirm(boundaries)
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationProvenance.key))
        let nap = SleepRecord(date: at(-1, 10), duration: 60, createdAt: now, endDate: at(-1, 11))
        XCTAssertFalse(persistence.saveRecording(nap, now: now))
        XCTAssertTrue(sleeps.load()?.isEmpty ?? true)
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete) // unchanged real observations
    }
    func testInterruptionAfterRevocationCannotRestoreAssertionOnRetry() throws {
        let boundaries = try pair(); try confirm(boundaries)
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        let nap = SleepRecord(date: at(-1, 10), duration: 60, createdAt: now, endDate: at(-1, 11))
        XCTAssertFalse(persistence.saveRecording(nap, now: now))
        XCTAssertTrue(snapshot.daytime.isEmpty)
        XCTAssertTrue(sleeps.saveRecording(nap, now: now))
        XCTAssertTrue(sleeps.delete(ids: [nap.id]))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testTypedAwakeBreakIsVerifiedAndUntouchedPrefillIsNot() throws {
        let nap = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        let entered = try pause(parent: nap, start: nap.date.addingTimeInterval(1200), end: nap.date.addingTimeInterval(1800))
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == entered.id }?.source, .verifiedObservation)
        let current = try XCTUnwrap(sleeps.load()?.first { $0.id == nap.id })
        var submission = RecordingSubmission()
        var prefilledID: UUID?
        submission.submit(draft: AwakeBreakDraft(parent: current, now: now), existing: sleeps.load()!, now: now,
            save: { prefilledID = $0.id; return self.sleeps.saveRecording($0, now: self.now) }, dismiss: {})
        XCTAssertTrue(submission.isSubmitted)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == prefilledID }?.source, .recordedUnverified)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == nap.id }?.source, .verifiedObservation)
    }
    func testStaleTypedBreakCannotVerifyAfterParentEditRevert() throws {
        let parent = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        var draft = AwakeBreakDraft(parent: parent, now: now)
        draft.start = parent.date.addingTimeInterval(1200); draft.end = parent.date.addingTimeInterval(1800)
        XCTAssertTrue(sleeps.save([SleepRecord(id: parent.id, date: parent.date.addingTimeInterval(-60), duration: parent.duration, createdAt: parent.createdAt, endDate: parent.endDate)]))
        XCTAssertTrue(sleeps.save([parent]))
        var submission = RecordingSubmission()
        submission.submit(draft: draft, existing: sleeps.load()!, now: now,
                          save: { self.sleeps.saveRecording($0, now: self.now) }, dismiss: {})
        XCTAssertFalse(submission.isSubmitted)
        XCTAssertEqual(sleeps.load()?.count, 1)
    }
    func testReopenedUnchangedEditorResumesOriginalAttestedOperation() throws {
        let original = try night()
        let failed = operation(writer: writer(failing: "sleepRecords")).execute()
        XCTAssertFalse(failed.evidencePublicationSucceeded)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let oldOperation = try XCTUnwrap(ObservationCompletionPending.load(defaults)?.operationID)
        let editor = WakeObservationDraft(initial: saved.wakeTime, existing: saved, nightRecords: sleeps.load())
        var capture: WakeObservationCapture?
        XCTAssertTrue(editor.submit { _, value in capture = value; return true })
        XCTAssertFalse(try XCTUnwrap(capture).attestsObservation)
        var resumedIDs: [UUID] = []
        let resumeWriter: (Data, String) -> Bool = { data, key in
            if key == ObservationCompletionPending.key {
                resumedIDs.append(try! JSONDecoder().decode(ObservationCompletionPending.self, from: data).operationID)
            }
            self.defaults.set(data, forKey: key); return true
        }
        let result = SleepWakeTimeWorkflow(selectedWakeTime: saved.wakeTime, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: .init(defaults: defaults, writer: resumeWriter),
            sleepPersistence: .init(defaults: defaults, writer: resumeWriter), capture: capture).execute()
        XCTAssertTrue(result.evidencePublicationSucceeded)
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(wakes.load()?.first?.id, saved.id)
        XCTAssertFalse(resumedIDs.isEmpty)
        XCTAssertTrue(resumedIDs.allSatisfy { $0 == oldOperation })
    }
    func testFinalPublicationFailureReportedAndRestartRecoveryUsesReceipts() throws {
        let original = try night()
        var writes = 0
        let injected: (Data, String) -> Bool = { data, key in
            if key == ObservationProvenance.key { writes += 1; if writes == 3 { return false } }
            self.defaults.set(data, forKey: key); return true
        }
        let result = operation(writer: injected).execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        XCTAssertFalse(result.evidencePublicationSucceeded)
        let persistedID = ObservationCompletionPending.load(defaults)?.operationID
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now,
            wakePersistence: .init(defaults: reloaded), sleepPersistence: .init(defaults: reloaded))
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertNotNil(persistedID)
    }
    func testRecoveryAcrossLocalMidnightKeepsOriginalWakeDayAndTime() throws {
        _ = try night()
        _ = operation(writer: writer(failing: "sleepRecords")).execute()
        let saved = try XCTUnwrap(wakes.load()?.first)
        let recovered = SleepWakeTimeWorkflow.resumePending(now: at(1, 8), wakePersistence: wakes, sleepPersistence: sleeps)
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, saved.wakeTime)
        XCTAssertEqual(wakes.load()?.first?.day, saved.day)
        XCTAssertEqual(sleeps.load()?.first?.observedEnd, saved.wakeTime)
    }
    func testFailedDeletionRetainsJournalButCannotResurrectDeletedIntent() throws {
        let original = try night()
        _ = operation(writer: writer(failing: "sleepRecords")).execute()
        let id = ObservationCompletionPending.load(defaults)?.operationID
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        XCTAssertFalse(failing.delete(ids: [original.id]))
        XCTAssertEqual(ObservationCompletionPending.load(defaults)?.operationID, id)
        XCTAssertTrue(ObservationCompletionPending.load(defaults)?.isCancelled == true)
        XCTAssertEqual(sleeps.load()?.count, 1)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testFailedWakeEditRetainsCancelledJournalAndActualWake() throws {
        _ = try night(); _ = operation(writer: writer(failing: "sleepRecords")).execute()
        let original = try XCTUnwrap(wakes.load()?.first)
        let id = ObservationCompletionPending.load(defaults)?.operationID
        let failing = DailyWakeRecordPersistence(defaults: defaults, writer: writer(failing: "dailyWakeRecords_v1"))
        XCTAssertFalse(failing.save([DailyWakeRecord(id: original.id, day: original.day, wakeTime: original.wakeTime.addingTimeInterval(60))]))
        XCTAssertEqual(ObservationCompletionPending.load(defaults)?.operationID, id)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, original.wakeTime)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
    }
    func testUnattestedJournalCannotBecomeTrustedThroughStartupRecovery() throws {
        _ = try night()
        var op = operation(writer: writer(failing: "sleepRecords")); op.capture = nil
        _ = op.execute()
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    private func archive(_ key: String = "observationProvenanceRecovery_v1") throws -> [ObservationStorage.RecoveryEntry] {
        try JSONDecoder().decode([ObservationStorage.RecoveryEntry].self, from: XCTUnwrap(defaults.data(forKey: key)))
    }
    func testQuarantineCountBytesAndPayloadSizeAreBounded() throws {
        var instant = now!
        let storage = ObservationStorage(defaults: defaults, clock: { instant })
        for index in 0..<20 {
            instant.addTimeInterval(1)
            XCTAssertTrue(storage.preserve(Data(repeating: UInt8(index), count: 8192), recoveryKey: ObservationStorage.archiveKeys[0]))
        }
        XCTAssertLessThanOrEqual(try archive().count, ObservationStorage.archiveCount)
        XCTAssertLessThanOrEqual(defaults.data(forKey: ObservationStorage.archiveKeys[0])!.count, ObservationStorage.archiveBytes)
        XCTAssertTrue(storage.preserve(Data(repeating: 99, count: 20000), recoveryKey: ObservationStorage.archiveKeys[0]))
        let oversized = try XCTUnwrap(archive().first { $0.byteCount == 20000 })
        XCTAssertNil(oversized.raw)
    }
    func testRecoveryArchiveExpiryUsesInjectedTime() throws {
        var instant = now!
        let storage = ObservationStorage(defaults: defaults, clock: { instant })
        XCTAssertTrue(storage.preserve(Data("unknown".utf8), recoveryKey: ObservationStorage.archiveKeys[0]))
        instant.addTimeInterval(ObservationStorage.archiveTTL)
        XCTAssertTrue(storage.pruneRecoveryArchives())
        XCTAssertTrue(try archive().isEmpty)
    }
    func testUnsupportedJournalArchiveNeverRetainsRawNightOrWake() throws {
        let storage = ObservationStorage(defaults: defaults, clock: { self.now })
        XCTAssertTrue(storage.preserve(Data("private-night-and-wake".utf8), recoveryKey: ObservationStorage.archiveKeys[1]))
        let retained = try XCTUnwrap(archive(ObservationStorage.archiveKeys[1]).first)
        XCTAssertNil(retained.raw)
    }
    func testSuccessfulRecordDeletionStripsArchivedRawMetadata() throws {
        let record = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        let storage = ObservationStorage(defaults: defaults)
        XCTAssertTrue(storage.preserve(Data("old-metadata".utf8), recoveryKey: ObservationStorage.archiveKeys[0]))
        XCTAssertNotNil(try XCTUnwrap(archive().first).raw)
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertFalse(try archive().isEmpty)
        XCTAssertTrue(try archive().allSatisfy { $0.raw == nil })
    }
    func testCorruptArchiveFailsClosedWithoutDestroyingObservationArrays() throws {
        let original = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        let bytes = try XCTUnwrap(defaults.data(forKey: "sleepRecords"))
        defaults.set(Data("bad-provenance".utf8), forKey: ObservationProvenance.key)
        defaults.set(Data("bad-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        XCTAssertFalse(sleeps.save([]))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), bytes)
        XCTAssertEqual(sleeps.load()?.first?.id, original.id)
        XCTAssertEqual(snapshot.sleeps.first?.source, .reconstructedLegacy)
    }
    func testArchiveWriteFailurePreventsUnsafeMetadataReplacement() throws {
        let original = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        defaults.set(Data("bad-provenance".utf8), forKey: ObservationProvenance.key)
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationStorage.archiveKeys[0]))
        XCTAssertFalse(persistence.save([]))
        XCTAssertEqual(sleeps.load()?.first?.id, original.id)
    }

    private func evaluate() -> LearningEligibilityEvaluation {
        LearningEligibilityEvaluator(calendar: calendar, timeZone: calendar.timeZone).evaluate(snapshot,
            birthDate: calendar.date(byAdding: .month, value: -8, to: now)!, now: now, policy: .engineeringV01)
    }
    private func buildDays(_ count: Int, start: Int? = nil, confirmCoverage: Bool = true,
                           breakTrust: Bool? = nil) throws {
        let first = start ?? -count
        XCTAssertTrue(operation(time: at(first, 7), action: at(first, 8)).execute().evidencePublicationSucceeded)
        for offset in first..<(first + count) {
            let morning = try XCTUnwrap(wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: at(offset, 7)) })
            let nap = try sleep(start: at(offset, 10), end: at(offset, 11), kind: .dayNap)
            if offset == first + count - 1, let trusted = breakTrust {
                _ = try pause(parent: nap, start: nap.date.addingTimeInterval(1200), end: nap.date.addingTimeInterval(1800), trusted: trusted)
            }
            _ = try sleep(start: at(offset, 20), end: nil, kind: .nightSleep)
            let result = operation(time: at(offset + 1, 7), action: at(offset + 1, 8)).execute()
            XCTAssertTrue(result.evidencePublicationSucceeded)
            let following = try XCTUnwrap(wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: at(offset + 1, 7)) })
            if confirmCoverage { try confirm((morning, following)) }
        }
    }
    func testSevenPersistedTrustedLearningDaysAreEligible() throws {
        try buildDays(7)
        XCTAssertEqual(evaluate().status, .eligibleUnderPolicy)
        XCTAssertEqual(evaluate().qualifyingDayCount, 7)
        XCTAssertEqual(sleeps.load()?.count, 14)
        XCTAssertEqual(wakes.load()?.count, 8)
        let fresh = TrustedObservationAdapter(defaults: UserDefaults(suiteName: suite)!).snapshot()
        XCTAssertEqual(fresh.daytime.count, 7)
    }
    func testSixPersistedTrustedLearningDaysAreInsufficient() throws {
        try buildDays(6)
        XCTAssertEqual(evaluate().qualifyingDayCount, 6)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testUnknownCoverageCannotQualifyPersistedTrustedDays() throws {
        try buildDays(7, confirmCoverage: false)
        XCTAssertEqual(evaluate().qualifyingDayCount, 0)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testTrustedAwakeBreakCanContributeToEligibility() throws {
        try buildDays(7, breakTrust: true)
        XCTAssertEqual(evaluate().status, .eligibleUnderPolicy)
        XCTAssertTrue(snapshot.sleeps.filter { $0.record.kind == .break }.allSatisfy { $0.source == .verifiedObservation })
        let last = try XCTUnwrap(evaluate().dailyResults.first { $0.day.id == calendar.startOfDay(for: at(-1, 7)) })
        XCTAssertEqual(last.netSleepSeconds, 60 * 60 + 11 * 3600 - 600)
    }
    func testUnverifiedAwakeBreakBlocksItsDayAndReattestedRevisionRepairsIt() throws {
        try buildDays(7, breakTrust: false)
        XCTAssertEqual(evaluate().qualifyingDayCount, 6)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
        let old = try XCTUnwrap(sleeps.load()?.first { $0.kind == .break })
        let parent = try XCTUnwrap(sleeps.load()?.first { $0.id == old.parentNapID })
        _ = try pause(parent: parent, start: old.date.addingTimeInterval(60), end: old.observedEnd!.addingTimeInterval(60), editing: old)
        XCTAssertEqual(evaluate().qualifyingDayCount, 6) // the old completeness answer was revoked
        let morning = try XCTUnwrap(wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: at(-1, 7)) })
        let following = try XCTUnwrap(wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: at(0, 7)) })
        try confirm((morning, following))
        XCTAssertEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testStaleCoveragePreventsEligibilityAfterNapInsertDelete() throws {
        try buildDays(7)
        let extra = try sleep(start: at(-1, 14), end: at(-1, 15), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [extra.id]))
        XCTAssertEqual(evaluate().qualifyingDayCount, 6)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testBrokenCanonicalLinkPreventsEligibility() throws {
        try buildDays(7)
        let night = try XCTUnwrap(sleeps.load()?.first { $0.kind == .nightSleep && calendar.isDate($0.date, inSameDayAs: at(-1, 20)) })
        let corrected = SleepRecord(id: night.id, date: night.date.addingTimeInterval(-60), duration: night.duration,
                                    kind: .nightSleep, createdAt: night.createdAt, endDate: night.endDate)
        XCTAssertTrue(sleeps.saveRecording(corrected, now: now))
        XCTAssertEqual(evaluate().qualifyingDayCount, 6)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testPersistedFixtureStillEnforcesLatestDayRecency() throws {
        try buildDays(7, start: -14)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
        XCTAssertTrue(evaluate().reasons.contains(.latestQualifyingDayTooOld))
    }
    func testPersistedFixtureStillEnforcesHistoricalWindow() throws {
        try buildDays(7, start: -30)
        XCTAssertEqual(evaluate().qualifyingDayCount, 0)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
    func testFixedCanonicalVectorsMatchAcrossCryptoKitAndSwiftCrypto() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parent = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let start = Date(timeIntervalSinceReferenceDate: 123456789.125)
        let end = Date(timeIntervalSinceReferenceDate: 123460389.625)
        let logged = Date(timeIntervalSinceReferenceDate: 123460400.5)
        let nap = SleepRecord(id: id, date: start, duration: 60, createdAt: logged, endDate: end)
        let revised = SleepRecord(id: id, date: start, duration: 60, createdAt: logged, endDate: end.addingTimeInterval(0.25))
        let ongoing = SleepRecord(id: id, date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: logged)
        let pause = SleepRecord(id: id, date: start, duration: 60, kind: .break, parentNapID: parent, createdAt: logged, endDate: end)
        let wake = DailyWakeRecord(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            day: Date(timeIntervalSinceReferenceDate: 123465600), wakeTime: Date(timeIntervalSinceReferenceDate: 123490800.25))
        // Canonical bytes and SHA-256 expected values were independently calculated using
        // IEEE-754 big-endian bit extraction and Python hashlib, not the Swift implementation.
        XCTAssertEqual(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: nap)), "36:11111111-1111-1111-1111-11111111111116:419d6f34548000002:606:dayNap3:nil5:false16:419d6f6cc200000016:419d6f6c968000007:unknown")
        XCTAssertEqual(ObservationProvenance.sleepIdentity(nap), "sha256-v1:eadbff5c0cd1bbfd43b703f651ffa8718be51e56e7253e8f81f199186c571311")
        XCTAssertEqual(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: revised)), "36:11111111-1111-1111-1111-11111111111116:419d6f34548000002:606:dayNap3:nil5:false16:419d6f6cc200000016:419d6f6c978000007:unknown")
        XCTAssertEqual(ObservationProvenance.sleepIdentity(revised), "sha256-v1:311a37fbd342a0a124b5309f151575523ab0fc4a64a0ff0fdc3b652feca7f164")
        XCTAssertEqual(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: ongoing)), "36:11111111-1111-1111-1111-11111111111116:419d6f34548000001:010:nightSleep3:nil4:true16:419d6f6cc20000003:nil7:unknown")
        XCTAssertEqual(ObservationProvenance.sleepIdentity(ongoing), "sha256-v1:f45cf8c815b5c3130952af02c746385f8b52a445d4cf60178edec368ff232362")
        XCTAssertEqual(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: pause)), "36:11111111-1111-1111-1111-11111111111116:419d6f34548000002:605:break36:22222222-2222-2222-2222-2222222222225:false16:419d6f6cc200000016:419d6f6c968000007:unknown")
        XCTAssertEqual(ObservationProvenance.sleepIdentity(pause), "sha256-v1:05c2464beec5e22ed9a4f9811b0ab92ad8c588382b341c3e37f951b40259b9d8")
        XCTAssertEqual(LearningEvidenceIdentity.wake(LearningWakeEvidence(record: wake)), "36:33333333-3333-3333-3333-33333333333316:419d6fbe0000000016:419d7147c10000007:unknown3:nil")
        XCTAssertEqual(ObservationProvenance.wakeIdentity(wake), "sha256-v1:efdf9fa262e37edab2200a0a51e6488047526a30fa9d0a91f070ec23c7814f01")
        let encoded = try JSONEncoder().encode(nap)
        let restored = try JSONDecoder().decode(SleepRecord.self, from: encoded)
        XCTAssertEqual(ObservationProvenance.sleepIdentity(restored), ObservationProvenance.sleepIdentity(nap))
        XCTAssertTrue(sleeps.save([nap]))
        let revision = ObservationProvenance.load(defaults)?.sleeps[id.uuidString]?.revision
        XCTAssertTrue(sleeps.save([revised]))
        XCTAssertNotEqual(revision, ObservationProvenance.load(defaults)?.sleeps[id.uuidString]?.revision)
    }

    func testOldConfirmationDraftCannotBeReusedAfterZeroNapRoundTrip() throws {
        let boundaries = try pair()
        let draft = try XCTUnwrap(adapter.beginDaytimeConfirmation(morningWakeID: boundaries.0.id, followingWakeID: boundaries.1.id))
        XCTAssertTrue(draft.submit(.allNapsRecorded, at: now, using: .init(defaults: defaults)))
        let nap = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [nap.id]))
        XCTAssertFalse(draft.submit(.allNapsRecorded, at: now, using: .init(defaults: defaults)))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testUnsubmittedDraftAlsoExpiresAfterMembershipRoundTrip() throws {
        let boundaries = try pair()
        let draft = try XCTUnwrap(adapter.beginDaytimeConfirmation(morningWakeID: boundaries.0.id, followingWakeID: boundaries.1.id))
        let nap = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [nap.id]))
        XCTAssertFalse(draft.submit(.allNapsRecorded, at: now, using: .init(defaults: defaults)))
    }
    func testUnsupportedRawJournalIsRetiredWithoutRetainingObservationContents() throws {
        defaults.set(Data("unsupported-sensitive-journal".utf8), forKey: ObservationCompletionPending.key)
        let storage = ObservationStorage(defaults: defaults, clock: { self.now })
        XCTAssertTrue(storage.pruneRecoveryArchives())
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        let retained = try XCTUnwrap(archive(ObservationStorage.archiveKeys[1]).first)
        XCTAssertNil(retained.raw)
    }

    func testSuccessfulDeletionRetiresPreviouslyCancelledJournalContents() throws {
        let record = try night()
        _ = operation(writer: writer(failing: "sleepRecords")).execute()
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        XCTAssertFalse(failing.delete(ids: [record.id]))
        XCTAssertTrue(ObservationCompletionPending.load(defaults)?.isCancelled == true)
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertFalse(try archive(ObservationStorage.archiveKeys[1]).isEmpty)
        XCTAssertTrue(try archive(ObservationStorage.archiveKeys[1]).allSatisfy { $0.raw == nil })
    }
    func testSuccessfulDeletionRetiresUnreadableArchiveWithoutTouchingOtherRecords() throws {
        let record = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        let other = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        defaults.set(Data("undecodable-archive-possibly-containing-deleted-observations".utf8), forKey: ObservationStorage.archiveKeys[0])
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertFalse(try archive().isEmpty)
        XCTAssertTrue(try archive().allSatisfy { $0.raw == nil })
        XCTAssertEqual(sleeps.load()?.map(\.id), [other.id])
    }

    func testDifferentCanonicalWakeCreatedDuringPartialSavePreventsDuplicateRecovery() throws {
        _ = try night()
        _ = operation(writer: writer(failing: "dailyWakeRecords_v1")).execute()
        let independent = DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: at(0, 7).addingTimeInterval(60))
        XCTAssertTrue(wakes.save([independent]))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertEqual(wakes.load()?.map(\.id), [independent.id])
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
    }
    func testRepeatedQuarantineDoesNotExtendOriginalRetentionDeadline() throws {
        var instant = now!
        let storage = ObservationStorage(defaults: defaults, clock: { instant })
        let raw = Data("repeated-corruption".utf8)
        XCTAssertTrue(storage.preserve(raw, recoveryKey: ObservationStorage.archiveKeys[0]))
        let first = try XCTUnwrap(archive().first?.savedAt)
        instant.addTimeInterval(86400)
        XCTAssertTrue(storage.preserve(raw, recoveryKey: ObservationStorage.archiveKeys[0]))
        XCTAssertEqual(try XCTUnwrap(archive().first).savedAt, first)
        instant = first.addingTimeInterval(ObservationStorage.archiveTTL)
        XCTAssertTrue(storage.pruneRecoveryArchives())
        XCTAssertTrue(try archive().isEmpty)
    }

    func testCommittedJournalLeftByCrashResumesWithoutDuplicateRecordWrites() throws {
        _ = try night()
        var lastJournal: Data?
        let captureJournal: (Data, String) -> Bool = { data, key in
            if key == ObservationCompletionPending.key { lastJournal = data }
            self.defaults.set(data, forKey: key); return true
        }
        XCTAssertTrue(operation(writer: captureJournal).execute().evidencePublicationSucceeded)
        defaults.set(try XCTUnwrap(lastJournal), forKey: ObservationCompletionPending.key) // crash before cleanup
        var recordWrites = 0
        let countWrites: (Data, String) -> Bool = { data, key in
            if key == "sleepRecords" || key == "dailyWakeRecords_v1" { recordWrites += 1 }
            self.defaults.set(data, forKey: key); return true
        }
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now,
            wakePersistence: .init(defaults: defaults, writer: countWrites),
            sleepPersistence: .init(defaults: defaults, writer: countWrites))
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(recordWrites, 0)
        XCTAssertEqual(sleeps.load()?.count, 1)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertNotNil(snapshot.wakes.first?.completedNightID)
    }
    func testPendingOperationCannotResumeAfterNightEditAndRevert() throws {
        let original = try night()
        _ = operation(writer: writer(failing: "sleepRecords")).execute()
        let changed = SleepRecord(id: original.id, date: original.date.addingTimeInterval(-60), duration: 0,
                                  kind: .nightSleep, isOngoing: true, createdAt: original.createdAt)
        XCTAssertTrue(sleeps.saveRecording(changed, now: now))
        XCTAssertTrue(sleeps.save([original]))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testRecordingAttestationCannotAdoptReentrantEditRevertRevision() throws {
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            let recorded = self.sleeps.load()!.first!
            let changed = SleepRecord(id: recorded.id, date: recorded.date.addingTimeInterval(-60),
                duration: recorded.duration, kind: recorded.kind, createdAt: recorded.createdAt, endDate: recorded.endDate)
            XCTAssertTrue(self.sleeps.save([changed]))
            XCTAssertTrue(self.sleeps.save([recorded]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }

    func testCorruptArchiveDoesNotPreventExpiredSiblingCleanup() throws {
        let storage = ObservationStorage(defaults: defaults, clock: { self.now })
        let expired = ObservationStorage.RecoveryEntry(digest: "expired", savedAt: now.addingTimeInterval(-8 * 86400),
                                                       byteCount: 12, raw: nil)
        defaults.set(try JSONEncoder().encode([expired]), forKey: ObservationStorage.archiveKeys[1])
        let corrupt = Data("unreadable-private-archive".utf8)
        defaults.set(corrupt, forKey: ObservationStorage.archiveKeys[0])
        XCTAssertFalse(storage.pruneRecoveryArchives())
        XCTAssertTrue(try archive(ObservationStorage.archiveKeys[1]).isEmpty)
        XCTAssertEqual(defaults.data(forKey: ObservationStorage.archiveKeys[0]), corrupt)
        XCTAssertNotNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
        XCTAssertTrue(storage.pruneRecoveryArchives())
        let retired = try XCTUnwrap(archive().first)
        XCTAssertNil(retired.raw)
        XCTAssertNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
    }

    func testUnsupportedJournalRetiresDespiteCorruptSiblingArchive() throws {
        defaults.set(Data("bad-sibling".utf8), forKey: ObservationStorage.archiveKeys[0])
        defaults.set(Data("unsupported-sensitive-night".utf8), forKey: ObservationCompletionPending.key)
        let storage = ObservationStorage(defaults: defaults, clock: { self.now })
        XCTAssertFalse(storage.pruneRecoveryArchives())
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        let retained = try XCTUnwrap(archive(ObservationStorage.archiveKeys[1]).first)
        XCTAssertNil(retained.raw)
        XCTAssertTrue(snapshot.sleeps.isEmpty)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testSuccessfulDeletionReportsAndRetriesArchiveCleanupFailure() throws {
        let removed = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        let other = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        let storage = ObservationStorage(defaults: defaults)
        XCTAssertTrue(storage.preserve(Data("private-retained-metadata".utf8), recoveryKey: ObservationStorage.archiveKeys[0]))
        let failure = expectation(forNotification: .observationRecoveryMaintenanceDidFail, object: nil) { notification in
            guard let stores = notification.userInfo?["stores"] as? [String] else { return false }
            return !stores.isEmpty && stores.allSatisfy { ObservationStorage.archiveKeys.contains($0) }
        }
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationStorage.archiveKeys[0]))
        XCTAssertTrue(failing.delete(ids: [removed.id]))
        wait(for: [failure], timeout: 1)
        XCTAssertEqual(sleeps.load()?.map(\.id), [other.id])
        XCTAssertNotNil(try XCTUnwrap(archive().first).raw)
        XCTAssertNotNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
        let reloaded = ObservationStorage(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reloaded.pruneRecoveryArchives())
        XCTAssertNil(try XCTUnwrap(archive().first).raw)
        XCTAssertNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
        XCTAssertEqual(sleeps.load()?.map(\.id), [other.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testArchiveFailureCannotAuthorizeDeletedCreation() throws {
        let record = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
        defaults.set(Data("corrupt-sensitive-recovery".utf8), forKey: ObservationStorage.archiveKeys[0])
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationStorage.archiveKeys[0]))
        XCTAssertTrue(failing.delete(ids: [record.id]))
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(try XCTUnwrap(sleeps.load()).isEmpty)
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    private func seedRawLegacy(metadata: Data? = nil) throws -> (SleepRecord, SleepRecord, DailyWakeRecord) {
        let night = SleepRecord(date: at(-1, 20), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: at(-1, 20))
        let other = SleepRecord(date: at(-2, 10), duration: 60, kind: .dayNap, createdAt: at(-2, 10))
        let prior = DailyWakeRecord(day: calendar.startOfDay(for: at(-2, 7)), wakeTime: at(-2, 7))
        defaults.set(try JSONEncoder().encode([night, other]), forKey: "sleepRecords")
        defaults.set(try JSONEncoder().encode([prior]), forKey: "dailyWakeRecords_v1")
        if let metadata { defaults.set(metadata, forKey: ObservationProvenance.key) }
        XCTAssertNil(ObservationProvenance.load(defaults))
        return (night, other, prior)
    }

    private func assertLegacyCompletion(_ original: (SleepRecord, SleepRecord, DailyWakeRecord),
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let records = try XCTUnwrap(sleeps.load(), file: file, line: line)
        XCTAssertEqual(Set(records.map(\.id)), Set([original.0.id, original.1.id]), file: file, line: line)
        let closed = try XCTUnwrap(records.first { $0.id == original.0.id }, file: file, line: line)
        XCTAssertFalse(closed.isOngoing, file: file, line: line)
        XCTAssertEqual(closed.date, original.0.date, file: file, line: line)
        XCTAssertEqual(closed.createdAt, original.0.createdAt, file: file, line: line)
        XCTAssertEqual(closed.observedEnd, at(0, 7), file: file, line: line)
        XCTAssertEqual(ObservationProvenance.sleepIdentity(try XCTUnwrap(records.first { $0.id == original.1.id })),
                       ObservationProvenance.sleepIdentity(original.1), file: file, line: line)
        let persistedWakes = try XCTUnwrap(wakes.load(), file: file, line: line)
        XCTAssertEqual(persistedWakes.count, 2, file: file, line: line)
        XCTAssertEqual(ObservationProvenance.wakeIdentity(try XCTUnwrap(persistedWakes.first { $0.id == original.2.id })),
                       ObservationProvenance.wakeIdentity(original.2), file: file, line: line)
        XCTAssertNotEqual(snapshot.sleeps.first { $0.record.id == original.0.id }?.source, .verifiedObservation, file: file, line: line)
        XCTAssertEqual(snapshot.wakes.first { $0.record.wakeTime == at(0, 7) }?.source, .verifiedObservation, file: file, line: line)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy, file: file, line: line)
    }

    func testRawPreB1OngoingNightCompletesWithoutSidecar() throws {
        let original = try seedRawLegacy()
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        try assertLegacyCompletion(original)
        XCTAssertNotNil(ObservationProvenance.load(defaults))
    }

    func testMalformedProvenanceAllowsUnverifiedLegacyRecordingWithoutDataLoss() throws {
        let raw = Data("malformed-sensitive-sidecar".utf8)
        let original = try seedRawLegacy(metadata: raw)
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        try assertLegacyCompletion(original)
        let retained = try XCTUnwrap(archive().first)
        XCTAssertEqual(retained.raw, raw)
    }

    func testUnsupportedProvenanceAllowsUnverifiedLegacyRecordingWithoutDataLoss() throws {
        let original = try seedRawLegacy()
        var unsupported = ObservationProvenance()
        unsupported.version = 999
        unsupported.sleeps[original.0.id.uuidString] = .init(revision: UUID(),
            content: ObservationProvenance.sleepIdentity(original.0), source: LearningEvidenceSource.verifiedObservation.rawValue,
            intent: "parent-entered-sleep-boundaries-v1")
        defaults.set(try JSONEncoder().encode(unsupported), forKey: ObservationProvenance.key)
        XCTAssertNil(ObservationProvenance.load(defaults))
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        try assertLegacyCompletion(original)
        XCTAssertFalse(try archive().isEmpty)
    }

    func testRawLegacyCompletionRetriesAndRestartsAfterPartialWrite() throws {
        let original = try seedRawLegacy()
        let failed = operation(writer: writer(failing: "sleepRecords")).execute()
        XCTAssertTrue(failed.wakePersistenceSucceeded)
        XCTAssertFalse(failed.sleepPersistenceSucceeded)
        XCTAssertNil(snapshot.wakes.first { $0.record.wakeTime == at(0, 7) }?.completedNightID)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: .init(defaults: reloaded),
            sleepPersistence: .init(defaults: reloaded))
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        try assertLegacyCompletion(original)
    }

    func testRawLegacyMetadataWriteFailurePreservesBothObservationArrays() throws {
        _ = try seedRawLegacy()
        let sleepBytes = defaults.data(forKey: "sleepRecords")
        let wakeBytes = defaults.data(forKey: "dailyWakeRecords_v1")
        let pending = operation(writer: writer(failing: ObservationProvenance.key))
        XCTAssertFalse(pending.execute().wakePersistenceSucceeded)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), sleepBytes)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakeBytes)
        XCTAssertTrue(pending.execute().evidencePublicationSucceeded == false)
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        XCTAssertNotEqual(snapshot.sleeps.first { $0.record.kind == .nightSleep }?.source, .verifiedObservation)
    }

    func testMalformedLegacyQuarantineFailurePreservesArraysAndTrust() throws {
        let raw = Data("malformed-legacy-sidecar".utf8)
        _ = try seedRawLegacy(metadata: raw)
        let sleepBytes = defaults.data(forKey: "sleepRecords")
        let wakeBytes = defaults.data(forKey: "dailyWakeRecords_v1")
        let failed = operation(writer: writer(failing: ObservationStorage.archiveKeys[0])).execute()
        XCTAssertFalse(failed.wakePersistenceSucceeded)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), sleepBytes)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakeBytes)
        XCTAssertEqual(defaults.data(forKey: ObservationProvenance.key), raw)
        XCTAssertTrue(snapshot.sleeps.allSatisfy { $0.source != .verifiedObservation })
        XCTAssertTrue(snapshot.wakes.allSatisfy { $0.source != .verifiedObservation })
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
    }

    func testRawCompletedLegacyNightAndMatchingWakeDoNotGainSemanticLink() throws {
        let night = SleepRecord(date: at(-1, 20), duration: 660, kind: .nightSleep, endDate: at(0, 7))
        let wake = DailyWakeRecord(day: calendar.startOfDay(for: at(0, 7)), wakeTime: at(0, 7))
        defaults.set(try JSONEncoder().encode([night]), forKey: "sleepRecords")
        defaults.set(try JSONEncoder().encode([wake]), forKey: "dailyWakeRecords_v1")
        let editor = WakeObservationDraft(initial: wake.wakeTime, existing: wake, nightRecords: [night])
        var capture: WakeObservationCapture?
        XCTAssertTrue(editor.submit { _, value in capture = value; return true })
        let result = SleepWakeTimeWorkflow(selectedWakeTime: wake.wakeTime, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps, capture: capture).execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertEqual(wakes.load()?.map(\.id), [wake.id])
        XCTAssertNotEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testCreationCaptureCannotBeAttachedToFreshOperationAfterDeletion() throws {
        let captured = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(captured, now: now))
        XCTAssertTrue(sleeps.delete(ids: [captured.id]))
        var forged = captured
        forged.creationIntent = ObservationCreationIntent(recordID: captured.id)
        XCTAssertFalse(sleeps.saveRecording(forged, now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testRestartRetiresAbandonedCreationSlotsWithoutReopeningOldSerials() throws {
        let abandoned = try capturedCreation()
        XCTAssertFalse(SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
            .saveRecording(abandoned, now: now))
        var ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        ledger.processID = UUID() // model a different process; the durable counter remains
        defaults.set(try JSONEncoder().encode(ledger), forKey: ObservationCreationLedger.key)
        let fresh = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(fresh, now: now))
        XCTAssertFalse(sleeps.saveRecording(abandoned, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [fresh.id])
        XCTAssertEqual(ObservationCreationLedger.load(defaults)?.next, 2)
    }

    func testRestartRetirementKeepsJournalBackedPendingCreation() throws {
        let pending = operation(writer: writer(failing: "dailyWakeRecords_v1"))
        XCTAssertFalse(pending.execute().wakePersistenceSucceeded)
        let receipt = try XCTUnwrap(StandaloneWakePending.load(defaults)?.creation)
        var ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        ledger.processID = UUID()
        defaults.set(try JSONEncoder().encode(ledger), forKey: ObservationCreationLedger.key)
        let unrelated = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(unrelated, now: now))
        XCTAssertTrue(ObservationCreationLedger.contains(receipt, defaults: defaults))
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps)
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.map(\.id), [receipt.recordID])
        XCTAssertEqual(sleeps.load()?.map(\.id), [unrelated.id])
    }

    func testUnsupportedJournalCleanupRetriesAfterCommittedDeletion() throws {
        let original = try night()
        let raw = Data("unsupported-sensitive-journal".utf8)
        defaults.set(raw, forKey: ObservationCompletionPending.key)
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationStorage.archiveKeys[1]))
        XCTAssertTrue(failing.delete(ids: [original.id]))
        XCTAssertTrue(try XCTUnwrap(sleeps.load()).isEmpty)
        XCTAssertEqual(defaults.data(forKey: ObservationCompletionPending.key), raw)
        XCTAssertNotNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
        XCTAssertTrue(ObservationStorage(defaults: defaults).pruneRecoveryArchives())
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertNil(try XCTUnwrap(archive(ObservationStorage.archiveKeys[1]).first).raw)
        XCTAssertNil(defaults.data(forKey: ObservationStorage.cleanupRequestKey))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testCombinedRecoveryArchivesRemainWithinTotalByteBudget() throws {
        let storage = ObservationStorage(defaults: defaults, clock: { self.now })
        for index in 0..<20 {
            XCTAssertTrue(storage.preserve(Data(repeating: UInt8(index), count: 6000),
                                           recoveryKey: ObservationStorage.archiveKeys[0]))
            XCTAssertTrue(storage.preserve(Data(repeating: UInt8(index), count: 9000),
                                           recoveryKey: ObservationStorage.archiveKeys[1]))
        }
        let total = try ObservationStorage.archiveKeys.reduce(0) { $0 + (try XCTUnwrap(defaults.data(forKey: $1))).count }
        XCTAssertLessThanOrEqual(total, ObservationStorage.archiveBytes)
        for key in ObservationStorage.archiveKeys {
            let entries = try archive(key)
            XCTAssertFalse(entries.isEmpty)
            XCTAssertLessThanOrEqual(entries.count, 4)
            XCTAssertTrue(entries.allSatisfy { ($0.raw?.count ?? 0) <= 8192 })
        }
        XCTAssertTrue(try archive(ObservationStorage.archiveKeys[1]).allSatisfy { $0.raw == nil })
    }

    func testCorruptCreationLedgerCannotAuthorizeNewOrStaleCreations() throws {
        let old = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(old, now: now))
        XCTAssertTrue(sleeps.delete(ids: [old.id]))
        let other = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        let bytes = defaults.data(forKey: "sleepRecords")
        let metadata = defaults.data(forKey: ObservationProvenance.key)
        let corrupt = Data("corrupted-creation-counter".utf8)
        defaults.set(corrupt, forKey: ObservationCreationLedger.key)
        XCTAssertFalse(sleeps.saveRecording(old, now: now))
        XCTAssertFalse(sleeps.saveRecording(try capturedCreation(), now: now))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), bytes)
        XCTAssertEqual(defaults.data(forKey: ObservationProvenance.key), metadata)
        XCTAssertEqual(defaults.data(forKey: ObservationCreationLedger.key), corrupt)
        XCTAssertEqual(sleeps.load()?.map(\.id), [other.id])
    }

    func testJournalCannotMoveCreationReceiptToDifferentWake() throws {
        XCTAssertFalse(operation(writer: writer(failing: "dailyWakeRecords_v1")).execute().wakePersistenceSucceeded)
        let pending = try XCTUnwrap(StandaloneWakePending.load(defaults))
        let creation = try XCTUnwrap(pending.creation)
        XCTAssertTrue(ObservationCreationLedger.contains(creation, defaults: defaults))
        let wrongWake = DailyWakeRecord(day: pending.wake.day, wakeTime: pending.wake.wakeTime)
        let corrupted = StandaloneWakePending(operationID: pending.operationID, wake: wrongWake,
            originalContent: nil, originalRevision: nil, calendar: calendar, attested: true, creation: creation)
        defaults.set(try JSONEncoder().encode(corrupted), forKey: StandaloneWakePending.key)
        let sleepBytes = defaults.data(forKey: "sleepRecords")
        let wakeBytes = defaults.data(forKey: "dailyWakeRecords_v1")
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), sleepBytes)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakeBytes)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    private enum MaintenanceMutation { case insert, edit, delete }
    private final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func enteredCreation(start: Date, end: Date) throws -> (SleepRecordingDraft, SleepRecord) {
        var draft = SleepRecordingDraft(defaultDate: start.addingTimeInterval(-1234), now: now)
        draft.start = start; draft.end = end
        var record: SleepRecord?
        var submission = RecordingSubmission()
        submission.submit(draft: draft, kind: .dayNap, now: now,
                          save: { record = $0; return true }, dismiss: {})
        return (draft, try XCTUnwrap(record))
    }

    private func sleepMaintenance(_ mutation: MaintenanceMutation, otherThread: Bool = false) throws {
        let existing = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        let revision = existing.persistedRevision
        let outer = try capturedCreation()
        let inserted = try enteredCreation(start: at(-1, 14), end: at(-1, 15)).1
        let corrected = SleepRecord(id: existing.id, date: existing.date.addingTimeInterval(60), duration: 60,
                                    createdAt: existing.createdAt, endDate: existing.observedEnd!.addingTimeInterval(60))
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let gate = ObserverGate()
        let diagnostics = EventCounter()
        let changes = EventCounter()
        let observation = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in changes.increment() }
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            diagnostics.increment()
            guard gate.claim() else { return }
            XCTAssertEqual(Set(self.sleeps.load()!.map(\.id)), Set([existing.id, outer.id]),
                           "Diagnostics must see the completed outer observation write")
            let mutate = {
                switch mutation {
                case .insert: XCTAssertTrue(self.sleeps.saveRecording(inserted, now: self.now))
                case .edit: XCTAssertTrue(self.sleeps.saveRecording(corrected, now: self.now))
                case .delete: XCTAssertTrue(self.sleeps.delete(ids: [existing.id]))
                }
            }
            if otherThread {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { mutate(); done.signal() }
                XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "Notification retained a persistence lock")
            } else { mutate() }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(observation)
        }
        XCTAssertTrue(sleeps.saveRecording(outer, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(diagnostics.value, 1)
        XCTAssertEqual(changes.value, 2, "One collection notification per actual successful write")
        let expected: [SleepRecord]
        switch mutation {
        case .insert: expected = [existing, outer, inserted]
        case .edit: expected = [corrected, outer]
        case .delete: expected = [outer]
        }
        let final = try XCTUnwrap(sleeps.load())
        XCTAssertEqual(Set(final.map(\.id)), Set(expected.map(\.id)))
        for record in expected {
            let actual = try XCTUnwrap(final.first { $0.id == record.id })
            XCTAssertEqual(ObservationProvenance.sleepIdentity(actual), ObservationProvenance.sleepIdentity(record))
            let entry = try XCTUnwrap(ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString])
            XCTAssertEqual(actual.persistedRevision, entry.revision)
            XCTAssertEqual(entry.content, ObservationProvenance.sleepIdentity(actual))
        }
        if mutation == .edit {
            XCTAssertNotEqual(final.first { $0.id == existing.id }?.persistedRevision, revision)
            XCTAssertEqual(snapshot.sleeps.first { $0.record.id == existing.id }?.source, .recordedUnverified)
        }
        if mutation == .insert {
            XCTAssertEqual(final.first { $0.id == existing.id }?.persistedRevision, revision)
            XCTAssertEqual(snapshot.sleeps.first { $0.record.id == inserted.id }?.source, .verifiedObservation)
        }
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == outer.id }?.source, .verifiedObservation)
    }

    func testMaintenanceObserverSleepInsertionPreservesBothWrites() throws { try sleepMaintenance(.insert) }
    func testMaintenanceObserverSleepEditPreservesCorrection() throws { try sleepMaintenance(.edit) }
    func testMaintenanceObserverSleepDeletionCannotResurrectRecord() throws { try sleepMaintenance(.delete) }
    func testMaintenanceObserverCanPersistFromAnotherThreadWithoutDeadlock() throws { try sleepMaintenance(.insert, otherThread: true) }

    private func wakeMaintenance(_ mutation: MaintenanceMutation) throws {
        XCTAssertTrue(operation(time: at(-2, 7), action: at(-2, 8)).execute().evidencePublicationSucceeded)
        let existing = try XCTUnwrap(wakes.load()?.first)
        let outerOperation = operation()
        let corrected = DailyWakeRecord(id: existing.id, day: existing.day, wakeTime: existing.wakeTime.addingTimeInterval(60))
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let gate = ObserverGate()
        let changes = EventCounter()
        let inserted = DailyWakeRecord(day: calendar.startOfDay(for: at(-1, 7)), wakeTime: at(-1, 7))
        let observation = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in changes.increment() }
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertEqual(self.wakes.load()?.count, 2)
            switch mutation {
            case .insert:
                // A historical insertion uses the collection service, not a second
                // Today's Wake workflow evaluated with a different historical clock.
                XCTAssertTrue(self.wakes.save(self.wakes.load()! + [inserted]))
            case .edit:
                XCTAssertTrue(self.wakes.save(self.wakes.load()!.map { $0.id == existing.id ? corrected : $0 }))
            case .delete:
                XCTAssertTrue(self.wakes.save(self.wakes.load()!.filter { $0.id != existing.id }))
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(observation)
        }
        let result = outerOperation.execute()
        XCTAssertTrue(result.evidencePublicationSucceeded)
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(changes.value, 2)
        let final = try XCTUnwrap(wakes.load())
        let outer = try XCTUnwrap(final.first { $0.wakeTime == at(0, 7) })
        var ids: Set<UUID> = [outer.id]
        if mutation != .delete { ids.insert(existing.id) }
        if mutation == .insert { ids.insert(inserted.id) }
        XCTAssertEqual(Set(final.map(\.id)), ids)
        for record in final {
            let entry = try XCTUnwrap(ObservationProvenance.load(defaults)?.wakes[record.id.uuidString])
            XCTAssertEqual(entry.content, ObservationProvenance.wakeIdentity(record))
            XCTAssertEqual(entry.revision, record.persistedRevision)
        }
        if mutation == .edit {
            let actual = try XCTUnwrap(final.first { $0.id == existing.id })
            XCTAssertEqual(ObservationProvenance.wakeIdentity(actual), ObservationProvenance.wakeIdentity(corrected))
            XCTAssertNotEqual(actual.persistedRevision, existing.persistedRevision)
            XCTAssertEqual(snapshot.wakes.first { $0.record.id == existing.id }?.source, .recordedUnverified)
        }
        XCTAssertEqual(snapshot.wakes.first { $0.record.id == outer.id }?.source, .verifiedObservation)
        if mutation == .insert {
            XCTAssertEqual(snapshot.wakes.first { $0.record.id == inserted.id }?.source, .recordedUnverified)
        }
        XCTAssertTrue(snapshot.wakes.allSatisfy { $0.completedNightID == nil })
    }

    func testMaintenanceObserverWakeInsertionPreservesBothWrites() throws { try wakeMaintenance(.insert) }
    func testMaintenanceObserverWakeEditPreservesCorrection() throws { try wakeMaintenance(.edit) }
    func testMaintenanceObserverWakeDeletionCannotResurrectRecord() throws { try wakeMaintenance(.delete) }

    func testMaintenanceCorrectionOfSubmittedSleepCannotInheritAttestation() throws {
        let record = try capturedCreation()
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let corrected = SleepRecord(id: record.id, date: record.date.addingTimeInterval(60), duration: 60,
                                    createdAt: record.createdAt, endDate: record.observedEnd!.addingTimeInterval(60))
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(self.sleeps.saveRecording(corrected, now: self.now))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(sleeps.load()?.map(ObservationProvenance.sleepIdentity), [ObservationProvenance.sleepIdentity(corrected)])
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }

    func testMaintenanceDeletionOfSubmittedSleepCannotBeUndone() throws {
        let record = try capturedCreation()
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(self.sleeps.delete(ids: [record.id]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(sleeps.load()?.map(\.id), [])
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testMaintenanceCorrectionOfSubmittedWakeCannotInheritAttestation() throws {
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            let record = self.wakes.load()!.first!
            XCTAssertTrue(self.wakes.save([DailyWakeRecord(id: record.id, day: record.day, wakeTime: record.wakeTime.addingTimeInterval(60))]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(operation().execute().evidencePublicationSucceeded)
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(wakes.load()?.map(\.wakeTime), [at(0, 7).addingTimeInterval(60)])
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testMaintenanceDeletionOfSubmittedWakeCannotBeUndone() throws {
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let pending = operation()
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(self.wakes.save([]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(pending.execute().evidencePublicationSucceeded)
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(wakes.load()?.map(\.id), [])
        XCTAssertFalse(pending.execute().wakePersistenceSucceeded)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testFailedObservationWriteStillReportsMaintenanceAfterItsWriteAttempt() throws {
        let outer = try capturedCreation()
        let inserted = try enteredCreation(start: at(-1, 14), end: at(-1, 15)).1
        defaults.set(Data("corrupt-archive".utf8), forKey: ObservationStorage.archiveKeys[0])
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .observationRecoveryMaintenanceDidFail, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(self.sleeps.saveRecording(inserted, now: self.now))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords")).saveRecording(outer, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(sleeps.load()?.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testSleepReceiptCallbackCannotOverwriteNestedCollectionWrite() throws {
        let outer = try capturedCreation()
        let inserted = try enteredCreation(start: at(-1, 14), end: at(-1, 15)).1
        XCTAssertFalse(sleeps.save([outer], beforeWrite: { _ in
            XCTAssertTrue(self.sleeps.saveRecording(inserted, now: self.now))
            return true
        }))
        XCTAssertEqual(sleeps.load()?.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testWakeReceiptCallbackCannotOverwriteNestedCollectionWrite() throws {
        let outer = DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: at(0, 7))
        let inserted = DailyWakeRecord(day: calendar.startOfDay(for: at(-1, 7)), wakeTime: at(-1, 7))
        XCTAssertFalse(wakes.save([outer], beforeWrite: { _ in
            XCTAssertTrue(self.wakes.save([inserted]))
            return true
        }))
        XCTAssertEqual(wakes.load()?.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testReceiptCallbackCanWaitForAnotherWriterWithoutHoldingLock() throws {
        let inserted = try enteredCreation(start: at(-1, 14), end: at(-1, 15)).1
        let outer = try capturedCreation()
        XCTAssertFalse(sleeps.save([outer], beforeWrite: { _ in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                XCTAssertTrue(self.sleeps.saveRecording(inserted, now: self.now))
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
            return true
        }))
        XCTAssertEqual(sleeps.load()?.map(\.id), [inserted.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testReceiptCallbackEditRevertCannotRestorePreparedMetadata() throws {
        let existing = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        let outer = try capturedCreation()
        let corrected = SleepRecord(id: existing.id, date: existing.date.addingTimeInterval(60), duration: 60,
            createdAt: existing.createdAt, endDate: existing.observedEnd!.addingTimeInterval(60))
        XCTAssertFalse(sleeps.save([existing, outer], beforeWrite: { _ in
            XCTAssertTrue(self.sleeps.saveRecording(corrected, now: self.now))
            XCTAssertTrue(self.sleeps.save([existing]))
            return true
        }))
        XCTAssertEqual(sleeps.load()?.map(ObservationProvenance.sleepIdentity), [ObservationProvenance.sleepIdentity(existing)])
        XCTAssertNotEqual(sleeps.load()?.first?.persistedRevision, existing.persistedRevision)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }

    func testAbandonedFailedSleepFormsDoNotExhaustLedgerWithoutRestart() throws {
        let other = try sleep(start: at(-3, 10), end: at(-3, 11), kind: .dayNap)
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        let process = ObservationCreationLedger.processID
        var old: SleepRecord?
        for _ in 0..<72 {
            let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
            old = old ?? record
            XCTAssertFalse(persistence.saveRecording(record, now: now))
            XCTAssertTrue(draft.abandon())
            XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
        }
        let fresh = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(fresh, now: now))
        XCTAssertFalse(sleeps.saveRecording(try XCTUnwrap(old), now: now))
        XCTAssertEqual(Set(sleeps.load()!.map(\.id)), Set([other.id, fresh.id]))
        let ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        XCTAssertEqual(ledger.processID, process)
        XCTAssertEqual(ledger.next, 74) // unrelated creation + 72 abandoned + fresh
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == fresh.id }?.source, .verifiedObservation)
    }

    func testAbandonedFailedAwakeBreakFormsDoNotExhaustLedger() throws {
        let parent = try sleep(start: at(-1, 9), end: at(-1, 12), kind: .nightSleep)
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        var abandoned: SleepRecord?
        for _ in 0..<68 {
            var draft = AwakeBreakDraft(parent: parent, now: now)
            draft.start = at(-1, 10); draft.end = at(-1, 11)
            var submitted: SleepRecord?
            var submission = RecordingSubmission()
            submission.submit(draft: draft, existing: sleeps.load()!, now: now,
                save: { submitted = $0; return persistence.saveRecording($0, now: self.now) }, dismiss: {})
            XCTAssertFalse(submission.isSubmitted)
            abandoned = abandoned ?? submitted
            XCTAssertTrue(draft.abandon())
        }
        XCTAssertEqual(sleeps.load()?.map(\.id), [parent.id])
        XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
        _ = try pause(parent: parent, start: at(-1, 10), end: at(-1, 11))
        XCTAssertFalse(sleeps.saveRecording(try XCTUnwrap(abandoned), now: now))
        XCTAssertEqual(sleeps.load()?.count, 2)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.kind == .break }?.source, .verifiedObservation)
    }

    func testAbandoningAnotherFormPreservesActiveCreationRetry() throws {
        let active = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        let discarded = try enteredCreation(start: at(-1, 14), end: at(-1, 15))
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        XCTAssertFalse(persistence.saveRecording(active.1, now: now))
        XCTAssertFalse(persistence.saveRecording(discarded.1, now: now))
        XCTAssertTrue(discarded.0.abandon())
        XCTAssertTrue(sleeps.saveRecording(active.1, now: now))
        XCTAssertFalse(sleeps.saveRecording(discarded.1, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [active.1.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testAbandonAfterAmbiguousCreationPreservesSavedObservationWithoutTrust() throws {
        let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        let ambiguous = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            self.defaults.set(data, forKey: key); return key != "sleepRecords"
        })
        XCTAssertFalse(ambiguous.saveRecording(record, now: now))
        let bytes = defaults.data(forKey: "sleepRecords")
        XCTAssertTrue(draft.abandon())
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), bytes)
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [record.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
    }

    func testAbandonBeforeFirstPersistenceCannotCreateObservation() throws {
        let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        XCTAssertTrue(draft.abandon())
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertNil(defaults.data(forKey: "sleepRecords"))
        XCTAssertNil(defaults.data(forKey: ObservationCreationLedger.key))
        XCTAssertTrue(sleeps.saveRecording(try capturedCreation(), now: now))
    }

    func testFailedRetirementIsRetriedByHealthyWriterWithoutResettingCounter() throws {
        let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        var failRetirement = false
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            if key == "sleepRecords" || (key == ObservationCreationLedger.key && failRetirement) { return false }
            self.defaults.set(data, forKey: key); return true
        })
        XCTAssertFalse(persistence.saveRecording(record, now: now))
        let originalLedger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        failRetirement = true
        XCTAssertFalse(draft.abandon())
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        let fresh = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(fresh, now: now))
        let ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        XCTAssertEqual(ledger.id, originalLedger.id)
        XCTAssertEqual(ledger.next, originalLedger.next + 1)
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(sleeps.load()?.map(\.id), [fresh.id])
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
    }

    func testNeverAllocatedOverflowFormCanBeAbandoned() throws {
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        var active: [(SleepRecordingDraft, SleepRecord)] = []
        for _ in 0..<ObservationCreationLedger.capacity {
            let item = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
            active.append(item)
            XCTAssertFalse(failing.saveRecording(item.1, now: now))
        }
        let overflow = try enteredCreation(start: at(-1, 14), end: at(-1, 15))
        XCTAssertFalse(sleeps.saveRecording(overflow.1, now: now))
        XCTAssertTrue(overflow.0.abandon())
        XCTAssertTrue(active[0].0.abandon())
        XCTAssertTrue(sleeps.saveRecording(active[1].1, now: now))
        XCTAssertFalse(sleeps.saveRecording(overflow.1, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [active[1].1.id])
        for item in active { XCTAssertTrue(item.0.abandon()) }
        XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
        XCTAssertEqual(ObservationCreationLedger.load(defaults)?.next, UInt64(ObservationCreationLedger.capacity))
    }

    private func submitWakeDraft(_ draft: WakeObservationDraft, writer: ((Data, String) -> Bool)? = nil,
                                 using reloaded: UserDefaults? = nil, action: Date? = nil) throws
        -> (result: SleepWakeTimeWorkflowResult, accepted: Bool, capture: WakeObservationCapture?) {
        let target = reloaded ?? defaults!
        var response: SleepWakeTimeWorkflowResult?
        var capture: WakeObservationCapture?
        let accepted = draft.submit { time, captured in
            capture = captured
            let result = SleepWakeTimeWorkflow(selectedWakeTime: time, now: action ?? self.now, calendar: self.calendar,
                wakeRecords: [], sleepRecords: [], wakePersistence: .init(defaults: target, writer: writer),
                sleepPersistence: .init(defaults: target, writer: writer), capture: captured).execute()
            response = result
            return result.wakePersistenceSucceeded && result.evidencePublicationSucceeded &&
                (result.closedNightRecord == nil || result.sleepPersistenceSucceeded)
        }
        return (try XCTUnwrap(response), accepted, capture)
    }

    private func failSecondMetadataWrite() -> (Data, String) -> Bool {
        var writes = 0
        return { data, key in
            if key == ObservationProvenance.key { writes += 1; if writes == 2 { return false } }
            self.defaults.set(data, forKey: key); return true
        }
    }

    func testUntouchedWakeSameEditorRetriesPublicationWithoutAttestation() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        let failed = try submitWakeDraft(draft, writer: failSecondMetadataWrite())
        XCTAssertFalse(failed.accepted)
        XCTAssertTrue(failed.result.wakePersistenceSucceeded)
        XCTAssertFalse(try XCTUnwrap(failed.capture).attestsObservation)
        let original = try XCTUnwrap(wakes.load()?.first)
        let operation = try XCTUnwrap(StandaloneWakePending.load(defaults))
        XCTAssertFalse(operation.attested)
        var recordWrites = 0
        let recovered = try submitWakeDraft(draft, writer: { data, key in
            if key == "dailyWakeRecords_v1" { recordWrites += 1 }
            self.defaults.set(data, forKey: key); return true
        })
        XCTAssertTrue(recovered.accepted)
        XCTAssertFalse(try XCTUnwrap(recovered.capture).attestsObservation)
        XCTAssertEqual(recordWrites, 0)
        XCTAssertEqual(wakes.load()?.map(\.id), [original.id])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, original.persistedRevision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertNil(defaults.data(forKey: StandaloneWakePending.key))
    }

    func testUntouchedWakeReloadRecoveryAndLaterSameEditorRetryRemainIdempotent() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertFalse(try submitWakeDraft(draft, writer: failSecondMetadataWrite()).accepted)
        let original = try XCTUnwrap(wakes.load()?.first)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: .init(defaults: reloaded),
            sleepPersistence: .init(defaults: reloaded))?.evidencePublicationSucceeded == true)
        XCTAssertTrue(try submitWakeDraft(draft, using: reloaded).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [original.id])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, original.persistedRevision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testUntouchedWakeIndependentCorrectionPreventsOriginalRetry() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertFalse(try submitWakeDraft(draft, writer: failSecondMetadataWrite()).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let corrected = DailyWakeRecord(id: saved.id, day: saved.day, wakeTime: saved.wakeTime.addingTimeInterval(60))
        XCTAssertTrue(wakes.save([corrected]))
        let revision = wakes.load()?.first?.persistedRevision
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertEqual(wakes.load()?.map(ObservationProvenance.wakeIdentity), [ObservationProvenance.wakeIdentity(corrected)])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, revision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testUntouchedWakeCompletedReceiptCannotAcknowledgeEditAndRevert() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertTrue(try submitWakeDraft(draft).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        XCTAssertTrue(wakes.save([DailyWakeRecord(id: saved.id, day: saved.day, wakeTime: saved.wakeTime.addingTimeInterval(60))]))
        XCTAssertTrue(wakes.save([saved]))
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertNotEqual(wakes.load()?.first?.persistedRevision, saved.persistedRevision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testUntouchedWakeCrossMidnightRetryRetainsOriginalSelectionAndWakeDay() throws {
        let input = at(0, 7).addingTimeInterval(12.125)
        let draft = WakeObservationDraft(initial: input, nightRecords: [])
        XCTAssertFalse(try submitWakeDraft(draft, writer: failSecondMetadataWrite()).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        XCTAssertEqual(StandaloneWakePending.load(defaults)?.selectedInput, input)
        XCTAssertTrue(try submitWakeDraft(draft, action: at(1, 12)).accepted)
        XCTAssertTrue(try submitWakeDraft(draft, action: at(2, 12)).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(wakes.load()?.first?.day, saved.day)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, saved.wakeTime)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testUnverifiedRecoveryPreservesPersistedSecondsAndSubseconds() throws {
        let time = at(-1, 7).addingTimeInterval(12.125)
        let record = DailyWakeRecord(day: calendar.startOfDay(for: time), wakeTime: time)
        XCTAssertTrue(wakes.save([record]))
        let receipt = try XCTUnwrap(ObservationProvenance.load(defaults)?.wakes[record.id.uuidString])
        let journal = StandaloneWakePending(operationID: UUID(), wake: record, originalContent: nil,
            originalRevision: nil, calendar: calendar, attested: false, expected: receipt, selectedInput: time)
        XCTAssertTrue(ObservationStorage(defaults: defaults).standaloneJournal(journal))
        XCTAssertTrue(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps)?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.map(\.wakeTime), [time])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, receipt.revision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testAbandonedWakeCannotResumeOrVerifyAlreadyPersistedObservation() throws {
        var draft = WakeObservationDraft(initial: at(0, 6), nightRecords: [])
        draft.selected = at(0, 7)
        XCTAssertFalse(try submitWakeDraft(draft, writer: failSecondMetadataWrite()).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        XCTAssertTrue(draft.abandon())
        XCTAssertNil(defaults.data(forKey: StandaloneWakePending.key))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, saved.persistedRevision)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testAbandonedWakeBeforeObservationWriteCannotExhaustLedger() throws {
        for _ in 0..<68 {
            let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
            XCTAssertFalse(try submitWakeDraft(draft, writer: writer(failing: "dailyWakeRecords_v1")).accepted)
            XCTAssertTrue(draft.abandon())
            XCTAssertFalse(try submitWakeDraft(draft).accepted)
        }
        XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
        let fresh = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertTrue(try submitWakeDraft(fresh).accepted)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testRetirementDuringReceiptPreparationPreventsSleepCreation() throws {
        let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        XCTAssertFalse(SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
            .saveRecording(record, now: now))
        let metadata = defaults.data(forKey: ObservationProvenance.key)
        XCTAssertFalse(sleeps.save([record], beforeWrite: { _ in
            XCTAssertTrue(draft.abandon())
            return true
        }, creationIntent: record.creationIntent))
        XCTAssertNil(defaults.data(forKey: "sleepRecords"))
        XCTAssertEqual(defaults.data(forKey: ObservationProvenance.key), metadata)
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testRetirementDuringWakeReceiptPreparationPreventsCreation() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertFalse(try submitWakeDraft(draft, writer: writer(failing: "dailyWakeRecords_v1")).accepted)
        let pending = try XCTUnwrap(StandaloneWakePending.load(defaults))
        XCTAssertFalse(wakes.save([pending.wake], beforeWrite: { _ in
            XCTAssertTrue(draft.abandon())
            return true
        }, completionOperationID: pending.operationID))
        XCTAssertNil(defaults.data(forKey: "dailyWakeRecords_v1"))
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testRetirementAfterSleepWritePreservesObservationButWithholdsAttestation() throws {
        let (draft, record) = try enteredCreation(start: at(-1, 10), end: at(-1, 11))
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(draft.abandon())
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertEqual(sleeps.load()?.map(\.id), [record.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
    }

    func testAbandonedSleepEditCannotApplyOrVerifyItsCapturedChanges() throws {
        let original = try sleep(start: at(-1, 10), end: at(-1, 11), kind: .dayNap)
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.start = original.date.addingTimeInterval(60)
        draft.end = original.observedEnd!.addingTimeInterval(60)
        var record: SleepRecord?
        var submission = RecordingSubmission()
        submission.submit(draft: draft, kind: .dayNap, editing: original, now: now,
                          save: { record = $0; return true }, dismiss: {})
        XCTAssertTrue(draft.abandon())
        XCTAssertFalse(sleeps.saveRecording(try XCTUnwrap(record), now: now))
        XCTAssertEqual(sleeps.load()?.map(ObservationProvenance.sleepIdentity), [ObservationProvenance.sleepIdentity(original)])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testExistingWakeNightCompletionCanBeAbandonedWithoutResuming() throws {
        let original = try night()
        XCTAssertTrue(wakes.save([DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: at(0, 7))]))
        let existing = try XCTUnwrap(wakes.load()?.first)
        var draft = WakeObservationDraft(initial: existing.wakeTime, existing: existing, nightRecords: sleeps.load())
        draft.selected = at(0, 7).addingTimeInterval(15 * 60)
        let failed = try submitWakeDraft(draft, writer: writer(failing: "sleepRecords"))
        XCTAssertTrue(failed.result.wakePersistenceSucceeded)
        XCTAssertFalse(failed.accepted)
        XCTAssertEqual(ObservationCompletionPending.load(defaults)?.operationID, failed.capture?.operationID)
        XCTAssertTrue(draft.abandon())
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertEqual(sleeps.load()?.map(\.id), [original.id])
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertEqual(wakes.load()?.map(\.id), [existing.id])
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }

    func testReopenedWakeEditorRetiresOriginalStandaloneOperationOnCancel() throws {
        let original = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        XCTAssertFalse(try submitWakeDraft(original, writer: failSecondMetadataWrite()).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let pending = try XCTUnwrap(StandaloneWakePending.load(defaults))
        let reopened = WakeObservationDraft(initial: saved.wakeTime, existing: saved, nightRecords: [])
        let failed = try submitWakeDraft(reopened, writer: writer(failing: ObservationProvenance.key))
        XCTAssertFalse(failed.accepted)
        XCTAssertNotEqual(failed.capture?.operationID, pending.operationID)
        XCTAssertTrue(reopened.abandon())
        XCTAssertNil(defaults.data(forKey: StandaloneWakePending.key))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertFalse(try submitWakeDraft(original).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testReopenedEditorCancellationRetiresUpdateWithUnchangedOriginalBaseline() throws {
        XCTAssertTrue(operation().execute().evidencePublicationSucceeded)
        let existing = try XCTUnwrap(wakes.load()?.first)
        var original = WakeObservationDraft(initial: existing.wakeTime, existing: existing, nightRecords: [])
        original.selected = existing.wakeTime.addingTimeInterval(15 * 60)
        XCTAssertFalse(try submitWakeDraft(original, writer: writer(failing: ObservationProvenance.key)).accepted)
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, existing.persistedRevision)
        var reopened = WakeObservationDraft(initial: existing.wakeTime, existing: existing, nightRecords: [])
        reopened.selected = original.selected
        XCTAssertFalse(try submitWakeDraft(reopened, writer: writer(failing: ObservationProvenance.key)).accepted)
        XCTAssertTrue(reopened.abandon())
        XCTAssertFalse(try submitWakeDraft(original).accepted)
        XCTAssertEqual(wakes.load()?.map(ObservationProvenance.wakeIdentity), [ObservationProvenance.wakeIdentity(existing)])
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation, "Retirement must preserve the prior independent observation")
        XCTAssertNil(defaults.data(forKey: StandaloneWakePending.key))
        XCTAssertTrue(try XCTUnwrap(ObservationCreationLedger.load(defaults)).pending.isEmpty)
    }

    func testNightJournalSameEditorRetryAcrossMidnightKeepsOriginalPickerInput() throws {
        let original = try night()
        var draft = WakeObservationDraft(initial: at(0, 6).addingTimeInterval(12.125), nightRecords: sleeps.load())
        draft.selected = at(0, 7).addingTimeInterval(12.125)
        XCTAssertFalse(try submitWakeDraft(draft, writer: writer(failing: "sleepRecords")).accepted)
        let saved = try XCTUnwrap(wakes.load()?.first)
        XCTAssertEqual(ObservationCompletionPending.load(defaults)?.selectedInput, draft.selected)
        XCTAssertTrue(try submitWakeDraft(draft, action: at(1, 12)).accepted)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(wakes.load()?.first?.wakeTime, saved.wakeTime)
        XCTAssertEqual(wakes.load()?.first?.day, saved.day)
        XCTAssertEqual(sleeps.load()?.first?.observedEnd, saved.wakeTime)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
    }

    func testCancelledJournalAndFailedRetirementRecoverWithoutCounterReset() throws {
        _ = try night()
        var draft = WakeObservationDraft(initial: at(0, 6), nightRecords: sleeps.load())
        draft.selected = at(0, 7)
        var failRetirement = false
        let backend: (Data, String) -> Bool = { data, key in
            if key == "sleepRecords" || (key == ObservationCreationLedger.key && failRetirement) { return false }
            self.defaults.set(data, forKey: key); return true
        }
        XCTAssertFalse(try submitWakeDraft(draft, writer: backend).accepted)
        let ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        failRetirement = true
        XCTAssertFalse(draft.abandon())
        XCTAssertTrue(ObservationCompletionPending.load(defaults)?.isCancelled == true)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertTrue(ObservationStorage(defaults: defaults).pruneRecoveryArchives())
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertNil(try XCTUnwrap(archive(ObservationStorage.archiveKeys[1]).first).raw)
        let fresh = try enteredCreation(start: at(-2, 10), end: at(-2, 11)).1
        XCTAssertTrue(sleeps.saveRecording(fresh, now: now))
        let after = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        XCTAssertEqual(after.id, ledger.id)
        XCTAssertEqual(after.next, ledger.next + 1)
        XCTAssertTrue(after.pending.isEmpty)
        XCTAssertFalse(try submitWakeDraft(draft).accepted)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    private func capturedCreation(kind: SleepKind = .dayNap) throws -> SleepRecord {
        var draft = SleepRecordingDraft(defaultDate: at(-1, 9), now: now)
        draft.start = at(-1, 10); draft.end = at(-1, 11)
        var result: SleepRecord?
        var submission = RecordingSubmission()
        submission.submit(draft: draft, kind: kind, now: now,
                          save: { result = $0; return true }, dismiss: {})
        let record = try XCTUnwrap(result)
        XCTAssertNotNil(record.observationCapture)
        return record
    }

    func testConsumedCreateCannotReplayAfterDeletionAndReload() throws {
        let record = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        let fresh = SleepRecordPersistence(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(fresh.saveRecording(record, now: now))
        XCTAssertTrue(try XCTUnwrap(fresh.load()).isEmpty)
        XCTAssertNil(ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString])
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testConsumedAwakeBreakCreateCannotReplayAfterDeletion() throws {
        let parent = try sleep(start: at(-1, 9), end: at(-1, 12), kind: .nightSleep)
        var draft = AwakeBreakDraft(parent: parent, now: now)
        draft.start = at(-1, 10); draft.end = at(-1, 11)
        var captured: SleepRecord?
        var submission = RecordingSubmission()
        submission.submit(draft: draft, existing: sleeps.load()!, now: now,
                          save: { captured = $0; return true }, dismiss: {})
        let record = try XCTUnwrap(captured)
        XCTAssertNotNil(record.observationCapture)
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [parent.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertNil(ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString])
    }

    func testAmbiguousCreationWriteThenDeletionCannotRetry() throws {
        let record = try capturedCreation()
        let ambiguous = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            self.defaults.set(data, forKey: key)
            return key != "sleepRecords"
        })
        XCTAssertFalse(ambiguous.saveRecording(record, now: now))
        XCTAssertEqual(sleeps.load()?.first?.id, record.id)
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(try XCTUnwrap(sleeps.load()).isEmpty)
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testPendingCreationSurvivesReloadAndUnrelatedDeletion() throws {
        let pending = try capturedCreation()
        XCTAssertFalse(SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
            .saveRecording(pending, now: now))
        let other = try sleep(start: at(-2, 10), end: at(-2, 11), kind: .dayNap)
        XCTAssertTrue(sleeps.delete(ids: [other.id]))
        let reloaded = SleepRecordPersistence(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reloaded.saveRecording(pending, now: now))
        XCTAssertEqual(reloaded.load()?.map(\.id), [pending.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testReentrantCreationDeletionRejectsNestedAndLaterReplay() throws {
        let record = try capturedCreation()
        let gate = ObserverGate()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard gate.claim() else { return }
            XCTAssertTrue(self.sleeps.delete(ids: [record.id]))
            XCTAssertFalse(self.sleeps.saveRecording(record, now: self.now))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(gate.wasEntered)
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }

    func testGenuineNewCreationAfterDeletionHasNewOperationAndIdentity() throws {
        let old = try capturedCreation()
        XCTAssertTrue(sleeps.saveRecording(old, now: now))
        XCTAssertTrue(sleeps.delete(ids: [old.id]))
        let fresh = try capturedCreation()
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertNotEqual(fresh.creationIntent?.operationID, old.creationIntent?.operationID)
        XCTAssertTrue(sleeps.saveRecording(fresh, now: now))
        XCTAssertFalse(sleeps.saveRecording(old, now: now))
        XCTAssertEqual(sleeps.load()?.map(\.id), [fresh.id])
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testCreationLedgerFailurePreventsObservationAndTrust() throws {
        let record = try capturedCreation()
        let persistence = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationCreationLedger.key))
        XCTAssertFalse(persistence.saveRecording(record, now: now))
        XCTAssertNil(defaults.data(forKey: "sleepRecords"))
        XCTAssertNil(defaults.data(forKey: ObservationProvenance.key))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
        XCTAssertTrue(sleeps.saveRecording(record, now: now))
    }

    func testCreationRevocationFailurePreventsDeletionAndStaleTrust() throws {
        let record = try capturedCreation()
        let ambiguous = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            self.defaults.set(data, forKey: key); return key != "sleepRecords"
        })
        XCTAssertFalse(ambiguous.saveRecording(record, now: now))
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: ObservationCreationLedger.key))
        XCTAssertFalse(failing.delete(ids: [record.id]))
        XCTAssertEqual(sleeps.load()?.map(\.id), [record.id])
        XCTAssertNotEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertTrue(sleeps.delete(ids: [record.id]))
        XCTAssertFalse(sleeps.saveRecording(record, now: now))
    }

    func testCreationLedgerDoesNotGrowWithDeletedHistory() throws {
        var original: SleepRecord?
        for _ in 0..<80 {
            let record = try capturedCreation()
            original = original ?? record
            XCTAssertTrue(sleeps.saveRecording(record, now: now))
            XCTAssertTrue(sleeps.delete(ids: [record.id]))
        }
        let ledger = try XCTUnwrap(ObservationCreationLedger.load(defaults))
        XCTAssertEqual(ledger.next, 80)
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(defaults.data(forKey: ObservationCreationLedger.key)).count, 256)
        XCTAssertFalse(sleeps.saveRecording(try XCTUnwrap(original), now: now))
    }

    func testCreationLedgerCapacityPreservesExistingPendingRetries() throws {
        var pending: [SleepRecord] = []
        let failing = SleepRecordPersistence(defaults: defaults, writer: writer(failing: "sleepRecords"))
        for _ in 0..<ObservationCreationLedger.capacity {
            let record = try capturedCreation()
            pending.append(record)
            XCTAssertFalse(failing.saveRecording(record, now: now))
        }
        let overflow = try capturedCreation()
        XCTAssertFalse(sleeps.saveRecording(overflow, now: now))
        XCTAssertEqual(ObservationCreationLedger.load(defaults)?.pending.count, ObservationCreationLedger.capacity)
        XCTAssertTrue(sleeps.saveRecording(pending[0], now: now))
        XCTAssertTrue(sleeps.saveRecording(overflow, now: now))
        XCTAssertEqual(sleeps.load()?.count, 2)
    }

    private func standaloneFailingPublication() -> SleepWakeTimeWorkflow {
        var metadataWrites = 0
        return operation(writer: { data, key in
            if key == ObservationProvenance.key {
                metadataWrites += 1
                if metadataWrites == 2 { return false }
            }
            self.defaults.set(data, forKey: key); return true
        })
    }

    func testStandaloneWakePublicationRecoversOriginalSameEditorIntent() throws {
        let operation = standaloneFailingPublication()
        let failed = operation.execute()
        XCTAssertTrue(failed.wakePersistenceSucceeded)
        XCTAssertFalse(failed.evidencePublicationSucceeded)
        XCTAssertNil(failed.closedNightRecord)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let pending = try XCTUnwrap(StandaloneWakePending.load(defaults))
        let revision = saved.persistedRevision
        XCTAssertEqual(pending.operationID, operation.capture?.operationID)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        let retried = operation.execute()
        XCTAssertTrue(retried.evidencePublicationSucceeded)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, revision)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertNil(defaults.data(forKey: StandaloneWakePending.key))
    }

    func testStandaloneWakePublicationRecoversAfterStorageReload() throws {
        XCTAssertFalse(standaloneFailingPublication().execute().evidencePublicationSucceeded)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: .init(defaults: reloaded),
                                                           sleepPersistence: .init(defaults: reloaded))
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.map(\.id), [saved.id])
        XCTAssertEqual(wakes.load()?.first?.wakeTime, saved.wakeTime)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
    }

    func testStandaloneUnchangedReopenedEditorUsesOnlyOriginalAttestation() throws {
        XCTAssertFalse(standaloneFailingPublication().execute().evidencePublicationSucceeded)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let editor = WakeObservationDraft(initial: saved.wakeTime, existing: saved, nightRecords: [])
        var capture: WakeObservationCapture?
        XCTAssertTrue(editor.submit { _, value in capture = value; return true })
        XCTAssertFalse(try XCTUnwrap(capture).attestsObservation)
        let result = SleepWakeTimeWorkflow(selectedWakeTime: saved.wakeTime, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps, capture: capture).execute()
        XCTAssertTrue(result.evidencePublicationSucceeded)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
    }

    func testStandaloneWakeCorrectionAndRevertCannotRecoverOldAttestation() throws {
        let stale = standaloneFailingPublication()
        XCTAssertFalse(stale.execute().evidencePublicationSucceeded)
        let original = try XCTUnwrap(wakes.load()?.first)
        let changed = DailyWakeRecord(id: original.id, day: original.day, wakeTime: original.wakeTime.addingTimeInterval(60))
        XCTAssertTrue(wakes.save([changed]))
        XCTAssertTrue(wakes.save([original]))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertFalse(stale.execute().evidencePublicationSucceeded)
        XCTAssertEqual(wakes.load()?.map(\.id), [original.id])
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }

    func testStandaloneWakeCreateReplayAfterDeletionCannotRestoreObservation() throws {
        let stale = operation()
        XCTAssertTrue(stale.execute().evidencePublicationSucceeded)
        XCTAssertTrue(wakes.save([]))
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let replay = SleepWakeTimeWorkflow(selectedWakeTime: stale.selectedWakeTime, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: .init(defaults: reloaded),
            sleepPersistence: .init(defaults: reloaded), capture: stale.capture).execute()
        XCTAssertFalse(replay.wakePersistenceSucceeded)
        XCTAssertFalse(replay.evidencePublicationSucceeded)
        XCTAssertTrue(try XCTUnwrap(wakes.load()).isEmpty)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testStandalonePartialPublicationDeletionCannotRecover() throws {
        let stale = standaloneFailingPublication()
        XCTAssertFalse(stale.execute().evidencePublicationSucceeded)
        XCTAssertTrue(wakes.save([]))
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
        XCTAssertFalse(stale.execute().wakePersistenceSucceeded)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }

    func testStandaloneUntouchedPrefillNeverGainsAttestationOnRestart() throws {
        let draft = WakeObservationDraft(initial: at(0, 7), nightRecords: [])
        var capture: WakeObservationCapture?
        XCTAssertTrue(draft.submit { _, value in capture = value; return true })
        let result = SleepWakeTimeWorkflow(selectedWakeTime: draft.selected, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps, capture: capture).execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes, sleepPersistence: sleeps))
    }

    func testMissingSemanticLinkAloneDisqualifiesOtherwiseVerifiedDay() throws {
        try buildDays(7)
        XCTAssertEqual(evaluate().qualifyingDayCount, 7)
        let following = try XCTUnwrap(wakes.load()?.first { calendar.isDate($0.day, inSameDayAs: at(0, 7)) })
        let before = snapshot
        let linked = try XCTUnwrap(before.wakes.first { $0.record.id == following.id }?.completedNightID)
        XCTAssertEqual(before.wakes.first { $0.record.id == following.id }?.source, .verifiedObservation)
        XCTAssertEqual(before.sleeps.first { $0.record.id == linked }?.source, .verifiedObservation)
        var metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
        metadata.links.removeValue(forKey: following.id.uuidString)
        XCTAssertTrue(ObservationStorage(defaults: defaults).metadata(metadata))
        XCTAssertEqual(snapshot.wakes.first { $0.record.id == following.id }?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == linked }?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.daytime.count, 7)
        let affected = try XCTUnwrap(evaluate().dailyResults.first { $0.day.id == calendar.startOfDay(for: at(-1, 7)) })
        XCTAssertFalse(affected.qualifies)
        XCTAssertEqual(affected.findings.map(\.reason), [.unverifiedNightWakeLink])
        XCTAssertEqual(evaluate().qualifyingDayCount, 6)
        XCTAssertNotEqual(evaluate().status, .eligibleUnderPolicy)
    }
}

extension TrustedObservationCorrectionTests {
    func testForwardCompletionPreservesUnrelatedDaytimeConfirmationAndWakeEditRevokesAffectedCoverage() throws {
        let boundaries = try pair()
        try confirm(boundaries)
        let baseline = try XCTUnwrap(ObservationProvenance.load(defaults)?.daytime)
        now = at(1, 12)
        let original = try sleep(start: at(-1, 20), end: nil, kind: .nightSleep)
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: now); draft.end = at(0, 7)
        var submission = RecordingSubmission()
        submission.submit(draft: draft, kind: .nightSleep, editing: original, now: now, save: {
            NightSleepCompletion(submitted: $0, now: self.now, calendar: self.calendar,
                sleepPersistence: self.sleeps, wakePersistence: self.wakes).execute().succeeded
        }, dismiss: {})
        XCTAssertTrue(submission.isSubmitted)
        XCTAssertEqual(Set(ObservationProvenance.load(defaults)?.daytime.keys.map { $0 } ?? []), Set(baseline.keys))
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete)
        let corrected = DailyWakeRecord(id: boundaries.1.id, day: boundaries.1.day, wakeTime: boundaries.1.wakeTime.addingTimeInterval(60))
        XCTAssertTrue(wakes.save([boundaries.0, corrected]))
        XCTAssertTrue(ObservationProvenance.load(defaults)?.daytime.isEmpty == true)
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
}
