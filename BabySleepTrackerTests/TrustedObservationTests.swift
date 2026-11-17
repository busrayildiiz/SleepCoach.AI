import XCTest
@testable import BabySleepTracker

final class TrustedObservationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var calendar: Calendar!
    private var now: Date!
    private var sleep: SleepRecordPersistence { SleepRecordPersistence(defaults: defaults) }
    private var wake: DailyWakeRecordPersistence { DailyWakeRecordPersistence(defaults: defaults) }
    private var snapshot: LearningEvidenceSnapshot { TrustedObservationAdapter(defaults: defaults).snapshot() }

    override func setUp() {
        super.setUp()
        suite = "TrustedObservationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = Date(timeIntervalSince1970: 1_800_014_400) // deterministic local noon
        now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }
    private func entered(_ kind: SleepKind = .dayNap, ongoing: Bool = false) throws -> SleepRecord {
        var draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-7200), now: now)
        draft.start = now.addingTimeInterval(kind == .nightSleep ? -16 * 3600 : -10800)
        draft.end = now.addingTimeInterval(-600)
        draft.isOngoing = ongoing
        return try submitted(draft, kind: kind)
    }
    private func submitted(_ draft: SleepRecordingDraft, kind: SleepKind = .dayNap,
                           editing: SleepRecord? = nil) throws -> SleepRecord {
        var submission = RecordingSubmission()
        var result: SleepRecord?
        submission.submit(draft: draft, kind: kind, editing: editing, now: now,
                          save: { result = $0; return true }, dismiss: {})
        return try XCTUnwrap(result)
    }
    @discardableResult
    private func startNight() throws -> SleepRecord {
        let night = try entered(.nightSleep, ongoing: true)
        XCTAssertTrue(sleep.saveRecording(night, now: now))
        return try XCTUnwrap(sleep.load()?.first)
    }
    private func wakeCapture(_ draft: WakeObservationDraft) -> WakeObservationCapture? {
        var capture: WakeObservationCapture?
        XCTAssertTrue(draft.submit { _, value in capture = value; return true })
        return capture
    }
    private func workflow(confirmed: Bool = true, fail: String? = nil) -> SleepWakeTimeWorkflow {
        let selected = now.addingTimeInterval(-3600)
        var draft = WakeObservationDraft(initial: now.addingTimeInterval(-7200), existing: wake.load()?.first, nightRecords: sleep.load() ?? [])
        draft.selected = selected
        let writer: (Data, String) -> Bool = { data, key in
            guard key != fail else { return false }
            self.defaults.set(data, forKey: key)
            return self.defaults.data(forKey: key) == data
        }
        return SleepWakeTimeWorkflow(selectedWakeTime: selected, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [],
            wakePersistence: DailyWakeRecordPersistence(defaults: defaults, writer: writer),
            sleepPersistence: SleepRecordPersistence(defaults: defaults, writer: writer),
            capture: confirmed ? wakeCapture(draft) : nil)
    }

    func testExplicitNapIsVerifiedAfterReload() throws {
        let record = try entered()
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        let reloaded = UserDefaults(suiteName: suite)!
        let result = TrustedObservationAdapter(defaults: reloaded).snapshot()
        XCTAssertEqual(result.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(result.sleeps.first?.record.id, record.id)
        XCTAssertNil(sleep.load()?.first?.observationCapture)
    }
    func testUntouchedPrefilledNapStaysUnverified() throws {
        let draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-7200), now: now)
        let record = try XCTUnwrap(draft.record(kind: .dayNap, now: now))
        XCTAssertNil(record.observationCapture)
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testLegacyRecordsRemainUnverified() throws {
        let record = try entered()
        defaults.set(try JSONEncoder().encode([record]), forKey: "sleepRecords")
        XCTAssertEqual(snapshot.sleeps.first?.source, .reconstructedLegacy)
        XCTAssertEqual(sleep.load()?.first?.id, record.id)
    }
    func testSourceEnumAssignmentCannotVerifyPersistedRecord() throws {
        let record = try entered()
        let arbitrary = LearningSleepEvidence(record: record, source: .verifiedObservation)
        XCTAssertTrue(sleep.save([arbitrary.record]))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testRoutinePredictionAndLLMValuesCannotVerifyAutomatically() throws {
        for source in [LearningEvidenceSource.routineDefault, .predicted, .llmGenerated, .unknown] {
            let record = try entered()
            XCTAssertTrue(sleep.save([record]))
            var metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
            let entry = try XCTUnwrap(metadata.sleeps[record.id.uuidString])
            metadata.sleeps[record.id.uuidString] = .init(revision: entry.revision, content: entry.content,
                                                        source: source.rawValue, intent: nil)
            XCTAssertTrue(ObservationStorage(defaults: defaults).metadata(metadata))
            XCTAssertEqual(snapshot.sleeps.first?.source, source)
        }
    }
    func testCorruptedMetadataFailsClosedWithoutDeletingRecords() throws {
        let record = try entered()
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        defaults.set(Data("broken".utf8), forKey: ObservationProvenance.key)
        XCTAssertEqual(snapshot.sleeps.first?.source, .reconstructedLegacy)
        XCTAssertEqual(sleep.load()?.first?.id, record.id)
        XCTAssertTrue(sleep.save(sleep.load()!))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testUnsupportedMetadataVersionFailsClosed() throws {
        XCTAssertTrue(sleep.saveRecording(try entered(), now: now))
        var metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
        metadata.version = 99
        defaults.set(try JSONEncoder().encode(metadata), forKey: ObservationProvenance.key)
        XCTAssertEqual(snapshot.sleeps.first?.source, .reconstructedLegacy)
    }
    func testSleepEditInvalidatesAndRevertDoesNotRestoreTrust() throws {
        let original = try entered()
        XCTAssertTrue(sleep.saveRecording(original, now: now))
        let changed = SleepRecord(id: original.id, date: original.date.addingTimeInterval(-60),
                                  duration: original.duration, createdAt: original.createdAt, endDate: original.endDate)
        XCTAssertTrue(sleep.saveRecording(changed, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertTrue(sleep.save([original]))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testStaleFormCannotOverwriteNewerRevision() throws {
        var original = try entered()
        XCTAssertTrue(sleep.saveRecording(original, now: now))
        original = try XCTUnwrap(sleep.load()?.first)
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.end = now.addingTimeInterval(-120)
        let stale = try XCTUnwrap(draft.record(kind: .dayNap, editing: original, now: now))
        let changed = SleepRecord(id: original.id, date: original.date, duration: 1, endDate: original.date.addingTimeInterval(60))
        XCTAssertTrue(sleep.save([changed]))
        XCTAssertFalse(sleep.saveRecording(stale, now: now))
        XCTAssertEqual(sleep.load()?.first?.duration, 1)
    }
    func testDeletedFormCannotResurrectRecord() throws {
        let original = try entered()
        XCTAssertTrue(sleep.saveRecording(original, now: now))
        let draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        let stale = try XCTUnwrap(draft.record(kind: .dayNap, editing: original, now: now))
        XCTAssertTrue(sleep.save([]))
        XCTAssertFalse(sleep.saveRecording(stale, now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }
    func testRepeatedSaveKeepsIdentityAndRevision() throws {
        let record = try entered()
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        let first = ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString]?.revision
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        XCTAssertEqual(sleep.load()?.count, 1)
        XCTAssertEqual(ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString]?.revision, first)
    }
    func testObservedOngoingNightHasNoInventedEnd() throws {
        _ = try startNight()
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertNil(snapshot.sleeps.first?.record.observedEnd)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }
    func testAutomaticEndPrefillDoesNotVerifyNight() throws {
        let night = try startNight()
        var draft = SleepRecordingDraft(defaultDate: night.date, editing: night, now: now)
        draft.prepareForEnding(at: now)
        let ended = try XCTUnwrap(draft.record(kind: .nightSleep, editing: night, now: now))
        XCTAssertNil(ended.observationCapture)
        XCTAssertTrue(sleep.saveRecording(ended, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }
    func testObservedNapCompletionRequiresEnteredEndAndVerifiedStart() throws {
        var nap = try entered(ongoing: true)
        XCTAssertTrue(sleep.saveRecording(nap, now: now))
        nap = try XCTUnwrap(sleep.load()?.first)
        var draft = SleepRecordingDraft(defaultDate: nap.date, editing: nap, now: now)
        draft.prepareForEnding(at: now)
        draft.end = now.addingTimeInterval(-600)
        let ended = try submitted(draft, editing: nap)
        XCTAssertTrue(sleep.saveRecording(ended, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first?.record.observedEnd, draft.end)
    }
    func testRetrospectiveEnteredSleepIsVerifiedWithoutTimezoneFabrication() throws {
        var draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-86400), now: now)
        draft.start = now.addingTimeInterval(-90000)
        draft.end = now.addingTimeInterval(-87000)
        XCTAssertTrue(sleep.saveRecording(try submitted(draft), now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first?.record.date, draft.start)
    }
    func testManualMorningWakeIsPersistedAndVerified() {
        let result = workflow().execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertFalse(result.sleepPersistenceSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testUntouchedWakePrefillStaysUnverified() {
        XCTAssertTrue(workflow(confirmed: false).execute().wakePersistenceSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }
    func testCanonicalCompletionPreservesIDsStartAndEarlierActualWakeAcrossMidnight() throws {
        let night = try startNight()
        let result = workflow().execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        let persisted = try XCTUnwrap(snapshot.sleeps.first)
        let morning = try XCTUnwrap(snapshot.wakes.first)
        XCTAssertEqual(persisted.record.id, night.id)
        XCTAssertEqual(persisted.record.date, night.date)
        XCTAssertEqual(persisted.record.observedEnd, now.addingTimeInterval(-3600))
        XCTAssertEqual(morning.record.wakeTime, persisted.record.observedEnd)
        XCTAssertEqual(morning.completedNightID, persisted.record.id)
        XCTAssertEqual(morning.record.id, wake.load()?.first?.id)
        XCTAssertEqual(persisted.source, .verifiedObservation)
        XCTAssertEqual(morning.source, .verifiedObservation)
        XCTAssertFalse(calendar.isDate(night.date, inSameDayAs: morning.record.wakeTime))
        XCTAssertNil(defaults.data(forKey: "nightWakeCompletionPending_v1"))
    }
    func testLegacyNightCompletionDoesNotUpgradeOnset() {
        let night = SleepRecord(date: now.addingTimeInterval(-16 * 3600), duration: 0, kind: .nightSleep, isOngoing: true)
        XCTAssertTrue(sleep.save([night]))
        XCTAssertTrue(workflow().execute().sleepPersistenceSucceeded)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testWakeSuccessNightFailureLeavesNoLinkAndRetryRecoversWithoutDuplicates() throws {
        let night = try startNight()
        let failed = workflow(fail: "sleepRecords").execute()
        XCTAssertTrue(failed.wakePersistenceSucceeded)
        XCTAssertFalse(failed.sleepPersistenceSucceeded)
        XCTAssertTrue(sleep.load()?.first?.isOngoing == true)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertNotNil(defaults.data(forKey: "nightWakeCompletionPending_v1"))
        let wakeID = wake.load()?.first?.id
        XCTAssertTrue(workflow().execute().sleepPersistenceSucceeded)
        XCTAssertEqual(sleep.load()?.count, 1)
        XCTAssertEqual(wake.load()?.count, 1)
        XCTAssertEqual(wake.load()?.first?.id, wakeID)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
    }
    func testWakeFailureDoesNotWriteNightAndRetryRecovers() throws {
        let night = try startNight()
        let result = workflow(fail: "dailyWakeRecords_v1").execute()
        XCTAssertFalse(result.wakePersistenceSucceeded)
        XCTAssertFalse(result.sleepPersistenceSucceeded)
        XCTAssertTrue(sleep.load()?.first?.isOngoing == true)
        XCTAssertTrue(snapshot.wakes.isEmpty)
        XCTAssertTrue(workflow().execute().sleepPersistenceSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
        XCTAssertEqual(wake.load()?.count, 1)
    }
    func testRepeatedCompletionKeepsWakeIDAndLink() throws {
        _ = try startNight()
        _ = workflow().execute()
        let id = snapshot.wakes.first?.record.id
        let link = snapshot.wakes.first?.completedNightID
        _ = workflow().execute()
        XCTAssertEqual(snapshot.wakes.first?.record.id, id)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, link)
        XCTAssertEqual(wake.load()?.count, 1)
    }
    func testNightEditRevokesLink() throws {
        _ = try startNight()
        _ = workflow().execute()
        let night = try XCTUnwrap(sleep.load()?.first)
        let changed = SleepRecord(id: night.id, date: night.date.addingTimeInterval(-60), duration: night.duration,
                                  kind: .nightSleep, endDate: night.endDate)
        XCTAssertTrue(sleep.save([changed]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testWakeEditRevokesLinkAndVerification() throws {
        _ = try startNight()
        _ = workflow().execute()
        let original = try XCTUnwrap(wake.load()?.first)
        XCTAssertTrue(wake.save([DailyWakeRecord(id: original.id, day: original.day, wakeTime: now)]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }
    func testNightDeletionRevokesLink() throws {
        _ = try startNight()
        _ = workflow().execute()
        XCTAssertTrue(sleep.save([]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
    }
    func testWakeDeletionRevokesLink() throws {
        _ = try startNight()
        _ = workflow().execute()
        XCTAssertTrue(wake.save([]))
        XCTAssertTrue(snapshot.wakes.isEmpty)
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
    }
    func testEqualTimestampAloneNeverCreatesLink() throws {
        let night = try entered(.nightSleep)
        XCTAssertTrue(sleep.saveRecording(night, now: now))
        XCTAssertTrue(wake.save([DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: night.observedEnd!)]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testOutOfBandContentChangeFailsClosed() throws {
        let original = try entered()
        XCTAssertTrue(sleep.saveRecording(original, now: now))
        let changed = SleepRecord(id: original.id, date: original.date, duration: 1)
        defaults.set(try JSONEncoder().encode([changed]), forKey: "sleepRecords")
        XCTAssertNotEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }
    func testBreakChangesKeepIndependentParentOnsetAndEndLink() throws {
        let night = try startNight()
        _ = workflow().execute()
        let parent = try XCTUnwrap(sleep.load()?.first)
        var draft = AwakeBreakDraft(parent: parent, now: now)
        draft.start = parent.date.addingTimeInterval(600)
        draft.end = draft.start.addingTimeInterval(600)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
        XCTAssertEqual(snapshot.sleeps.first(where: { $0.record.id == night.id })?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first(where: { $0.record.id == record.id })?.source, .recordedUnverified)
        var edit = AwakeBreakDraft(parent: parent, editing: try XCTUnwrap(sleep.load()?.first { $0.id == record.id }), now: now)
        edit.end = record.endDate!.addingTimeInterval(60)
        XCTAssertTrue(sleep.saveRecording(try XCTUnwrap(edit.record(existing: [record], now: now)), now: now))
        XCTAssertTrue(sleep.save([parent]))
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
    }
    func testStaleBreakParentIsRejected() throws {
        let parent = try entered()
        XCTAssertTrue(sleep.save([parent]))
        var draft = AwakeBreakDraft(parent: parent, now: now)
        draft.start = parent.date.addingTimeInterval(600)
        draft.end = draft.start.addingTimeInterval(60)
        let record = try XCTUnwrap(draft.record(existing: [], now: now))
        XCTAssertTrue(sleep.save([]))
        XCTAssertFalse(sleep.saveRecording(record, now: now))
    }
    func testFailedRecordWriteCannotGrantTrust() throws {
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            if key == "sleepRecords" { return false }
            self.defaults.set(data, forKey: key)
            return true
        })
        XCTAssertFalse(persistence.saveRecording(try entered(), now: now))
        XCTAssertTrue(snapshot.sleeps.isEmpty)
    }
    func testFailedMetadataWritePreventsRecordMutation() throws {
        var writes: [String] = []
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            writes.append(key)
            if key == ObservationProvenance.key { return false }
            self.defaults.set(data, forKey: key)
            return self.defaults.data(forKey: key) == data
        })
        XCTAssertFalse(persistence.saveRecording(try entered(), now: now))
        XCTAssertEqual(writes, [ObservationCreationLedger.key, ObservationProvenance.key])
        XCTAssertEqual(ObservationCreationLedger.load(defaults)?.pending.count, 1)
        XCTAssertNil(defaults.data(forKey: ObservationProvenance.key))
        XCTAssertNil(defaults.data(forKey: "sleepRecords"))
    }
    func testFailedPositiveAttestationLeavesSavedRecordUnverified() throws {
        var metadataWrites = 0
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            if key == ObservationProvenance.key { metadataWrites += 1; if metadataWrites == 2 { return false } }
            self.defaults.set(data, forKey: key)
            return true
        })
        XCTAssertTrue(persistence.saveRecording(try entered(), now: now))
        XCTAssertEqual(sleep.load()?.count, 1)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testUnreadableUserRecordsAreNeverOverwritten() {
        let broken = Data("broken".utf8)
        defaults.set(broken, forKey: "sleepRecords")
        XCTAssertFalse(sleep.save([]))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), broken)
        defaults.set(broken, forKey: "dailyWakeRecords_v1")
        XCTAssertFalse(wake.save([]))
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), broken)
    }
    func testDuplicateIDsAreRejected() throws {
        let record = try entered()
        XCTAssertFalse(sleep.save([record, record]))
        XCTAssertNil(sleep.load())
    }
    func testCoverageRemainsUnknownAndNoEligibilityIsAuthorized() throws {
        _ = try startNight()
        _ = workflow().execute()
        XCTAssertTrue(snapshot.daytime.isEmpty)
        let evaluator = LearningEligibilityEvaluator(calendar: calendar, timeZone: calendar.timeZone)
        let evaluation = evaluator.evaluate(snapshot, birthDate: calendar.date(byAdding: .month, value: -8, to: now)!,
                                            now: now, policy: .engineeringV01)
        XCTAssertNotEqual(evaluation.status, .eligibleUnderPolicy)
        XCTAssertTrue(evaluation.dailyResults.allSatisfy { $0.napCoverage == .unknown })
    }
    func testStaleRevisionAfterEditAndRevertIsRejected() throws {
        XCTAssertTrue(sleep.saveRecording(try entered(), now: now))
        let original = try XCTUnwrap(sleep.load()?.first)
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.start = original.date.addingTimeInterval(-600)
        draft.end = original.endDate!.addingTimeInterval(-60)
        let stale = try XCTUnwrap(draft.record(kind: .dayNap, editing: original, now: now))
        XCTAssertTrue(sleep.save([SleepRecord(id: original.id, date: original.date, duration: 1)]))
        XCTAssertTrue(sleep.save([original]))
        XCTAssertFalse(sleep.saveRecording(stale, now: now))
        XCTAssertEqual(sleep.load()?.first?.date, original.date)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testStaleWakeFormCannotOverwriteNewWakeRevision() throws {
        _ = workflow().execute()
        let original = try XCTUnwrap(wake.load()?.first)
        var draft = WakeObservationDraft(initial: original.wakeTime, existing: original)
        draft.selected = now.addingTimeInterval(-1800)
        XCTAssertTrue(wake.save([DailyWakeRecord(id: original.id, day: original.day, wakeTime: now.addingTimeInterval(-600))]))
        let result = SleepWakeTimeWorkflow(selectedWakeTime: draft.selected, now: now, calendar: calendar,
            wakeRecords: [original], sleepRecords: [], wakePersistence: wake, sleepPersistence: sleep,
            capture: wakeCapture(draft)).execute()
        XCTAssertFalse(result.wakePersistenceSucceeded)
        XCTAssertEqual(wake.load()?.first?.wakeTime, now.addingTimeInterval(-600))
    }
    func testVerifiedEnumWithoutCaptureIntentFailsClosed() throws {
        let record = try entered()
        XCTAssertTrue(sleep.save([record]))
        var metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
        let entry = try XCTUnwrap(metadata.sleeps[record.id.uuidString])
        metadata.sleeps[record.id.uuidString] = .init(revision: entry.revision, content: entry.content,
            source: LearningEvidenceSource.verifiedObservation.rawValue, intent: nil)
        XCTAssertTrue(ObservationStorage(defaults: defaults).metadata(metadata))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testFinalMetadataFailureLeavesJournalAndRetryLinksPersistedRecords() throws {
        let night = try startNight()
        var metadataWrites = 0
        let writer: (Data, String) -> Bool = { data, key in
            if key == ObservationProvenance.key { metadataWrites += 1; if metadataWrites == 3 { return false } }
            self.defaults.set(data, forKey: key)
            return true
        }
        var operation = workflow()
        operation = SleepWakeTimeWorkflow(selectedWakeTime: operation.selectedWakeTime, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [],
            wakePersistence: DailyWakeRecordPersistence(defaults: defaults, writer: writer),
            sleepPersistence: SleepRecordPersistence(defaults: defaults, writer: writer), capture: operation.capture)
        let result = operation.execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        XCTAssertNotNil(defaults.data(forKey: "nightWakeCompletionPending_v1"))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        let wakeID = snapshot.wakes.first?.record.id
        _ = workflow().execute()
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
        XCTAssertEqual(snapshot.wakes.first?.record.id, wakeID)
        XCTAssertEqual(sleep.load()?.count, 1)
        XCTAssertEqual(wake.load()?.count, 1)
        XCTAssertNil(defaults.data(forKey: "nightWakeCompletionPending_v1"))
        // The journal carries the original exact onset proof and operation receipts.
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }
    func testConflictingNightAndWakeCannotExposeCompletionLink() throws {
        _ = try startNight()
        _ = workflow().execute()
        let original = try XCTUnwrap(wake.load()?.first)
        let changed = DailyWakeRecord(id: original.id, day: original.day, wakeTime: now)
        // Simulate an out-of-band record write with stale sidecar/link metadata.
        defaults.set(try JSONEncoder().encode([changed]), forKey: "dailyWakeRecords_v1")
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertNotEqual(snapshot.wakes.first?.source, .verifiedObservation)
    }
    func testCoverageRevisionBindingChangesOnEditRevertAndNapInsertion() throws {
        let morning = DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: now.addingTimeInterval(-14400))
        let following = DailyWakeRecord(day: calendar.startOfDay(for: now.addingTimeInterval(86400)), wakeTime: now.addingTimeInterval(72000))
        XCTAssertTrue(wake.save([morning, following]))
        XCTAssertTrue(sleep.save([]))
        let adapter = TrustedObservationAdapter(defaults: defaults)
        let empty = try XCTUnwrap(adapter.daytimeRevisionIdentity(morningWakeID: morning.id, followingWakeID: following.id))
        let nap = try entered()
        XCTAssertTrue(sleep.saveRecording(nap, now: now))
        let first = try XCTUnwrap(adapter.daytimeRevisionIdentity(morningWakeID: morning.id, followingWakeID: following.id))
        XCTAssertNotEqual(empty, first)
        XCTAssertTrue(sleep.save([SleepRecord(id: nap.id, date: nap.date, duration: 1)]))
        XCTAssertTrue(sleep.save([nap]))
        XCTAssertNotEqual(first, adapter.daytimeRevisionIdentity(morningWakeID: morning.id, followingWakeID: following.id))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }

    func testConstructingEnteredRecordDoesNotVerifyObservation() throws {
        var draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-7200), now: now)
        draft.start = now.addingTimeInterval(-10800)
        draft.end = now.addingTimeInterval(-600)
        let record = try XCTUnwrap(draft.record(kind: .dayNap, now: now))
        XCTAssertNil(record.observationCapture)
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }

    func testFailedReportedWriteThatReachedStorageDoesNotDuplicateSubmissionOnRetry() throws {
        var draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-7200), now: now)
        draft.start = now.addingTimeInterval(-10800)
        draft.end = now.addingTimeInterval(-600)
        var firstRecordWrite = true
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            self.defaults.set(data, forKey: key)
            if key == "sleepRecords" && firstRecordWrite { firstRecordWrite = false; return false }
            return true
        })
        var submission = RecordingSubmission()
        var dismissed = false
        submission.submit(draft: draft, kind: .dayNap, now: now,
            save: { persistence.saveRecording($0, now: self.now) }, dismiss: { dismissed = true })
        XCTAssertFalse(dismissed)
        let id = sleep.load()?.first?.id
        submission.submit(draft: draft, kind: .dayNap, now: now,
            save: { persistence.saveRecording($0, now: self.now) }, dismiss: { dismissed = true })
        XCTAssertTrue(dismissed)
        XCTAssertEqual(sleep.load()?.count, 1)
        XCTAssertEqual(sleep.load()?.first?.id, id)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }

    func testDeletingNightDuringPartialSaveCancelsRecoveryWithoutResurrection() throws {
        _ = try startNight()
        _ = workflow(fail: "sleepRecords").execute()
        XCTAssertNotNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertTrue(sleep.save([]))
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        _ = workflow().execute()
        XCTAssertTrue(sleep.load()?.isEmpty == true)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testDeletingWakeDuringPartialSaveCancelsOldRecoveryIdentity() throws {
        _ = try startNight()
        _ = workflow(fail: "sleepRecords").execute()
        let deleted = wake.load()?.first?.id
        XCTAssertTrue(wake.save([]))
        XCTAssertNil(defaults.data(forKey: ObservationCompletionPending.key))
        XCTAssertTrue(snapshot.wakes.isEmpty)
        _ = workflow().execute() // a new explicit operation, not resurrection from the old journal
        XCTAssertNotEqual(wake.load()?.first?.id, deleted)
    }

    private func coveragePair() throws -> (DailyWakeRecord, DailyWakeRecord) {
        let morning = DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: now.addingTimeInterval(-14400))
        let following = DailyWakeRecord(day: calendar.startOfDay(for: now.addingTimeInterval(86400)), wakeTime: now.addingTimeInterval(72000))
        XCTAssertTrue(wake.save([morning, following]))
        return (morning, following)
    }
    @discardableResult
    private func attest(_ pair: (DailyWakeRecord, DailyWakeRecord), complete: Bool = true) throws -> DaytimeCoverageDraft {
        let draft = try XCTUnwrap(TrustedObservationAdapter(defaults: defaults).beginDaytimeConfirmation(
            morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertTrue(draft.submit(complete ? .allNapsRecorded : .notAllNapsRecorded,
                                  at: now.addingTimeInterval(172800), using: ObservationStorage(defaults: defaults)))
        return draft
    }
    func testPreparingZeroNapConfirmationMakesNoAssertion() throws {
        let pair = try coveragePair()
        XCTAssertNotNil(TrustedObservationAdapter(defaults: defaults).beginDaytimeConfirmation(
            morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testExplicitZeroNapAttestationSurvivesReload() throws {
        let pair = try coveragePair()
        try attest(pair)
        let restored = TrustedObservationAdapter(defaults: UserDefaults(suiteName: suite)!).snapshot()
        XCTAssertEqual(restored.daytime.first?.coverage, .confirmedComplete)
        XCTAssertEqual(restored.daytime.first?.napIDs, [])
        XCTAssertNotNil(restored.daytime.first?.confirmedEvidenceIdentity)
        XCTAssertEqual(restored.wakes.first?.source, .recordedUnverified)
    }
    func testExplicitIncompleteCoverageRemainsIneligible() throws {
        let pair = try coveragePair()
        try attest(pair, complete: false)
        XCTAssertEqual(snapshot.daytime.first?.coverage, .incomplete)
        let evaluation = LearningEligibilityEvaluator(calendar: calendar, timeZone: calendar.timeZone).evaluate(snapshot,
            birthDate: calendar.date(byAdding: .month, value: -8, to: now)!, now: now.addingTimeInterval(172800), policy: .engineeringV01)
        XCTAssertNotEqual(evaluation.status, .eligibleUnderPolicy)
        XCTAssertTrue(evaluation.dailyResults.contains { $0.findings.contains { $0.reason == .incompleteNapCoverage } })
    }
    func testFutureCoverageCannotBeAttested() throws {
        let pair = try coveragePair()
        let draft = try XCTUnwrap(TrustedObservationAdapter(defaults: defaults).beginDaytimeConfirmation(
            morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertFalse(draft.submit(.allNapsRecorded, at: now, using: ObservationStorage(defaults: defaults)))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testAddingNapInvalidatesPersistedZeroNapConfirmation() throws {
        let pair = try coveragePair()
        try attest(pair)
        XCTAssertTrue(sleep.saveRecording(try entered(), now: now))
        XCTAssertTrue(snapshot.daytime.isEmpty)
        XCTAssertEqual(ObservationProvenance.load(defaults)?.daytime.count, 0) // permanently revoked before the mutation
    }
    func testDeletingNapInvalidatesPersistedConfirmation() throws {
        let pair = try coveragePair()
        XCTAssertTrue(sleep.saveRecording(try entered(), now: now))
        try attest(pair)
        XCTAssertTrue(sleep.save([]))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testNapTimingEditAndRevertCannotRestoreConfirmation() throws {
        let pair = try coveragePair()
        let nap = try entered()
        XCTAssertTrue(sleep.saveRecording(nap, now: now))
        try attest(pair)
        XCTAssertTrue(sleep.save([SleepRecord(id: nap.id, date: nap.date, duration: 1)]))
        XCTAssertTrue(sleep.save([nap]))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testLoggingOnlyEditPreservesDaytimeConfirmationAndObservedTimes() throws {
        let pair = try coveragePair()
        let nap = try entered()
        XCTAssertTrue(sleep.saveRecording(nap, now: now))
        try attest(pair)
        let changed = SleepRecord(id: nap.id, date: nap.date, duration: nap.duration, kind: nap.kind,
            createdAt: nap.createdAt.addingTimeInterval(600), endDate: nap.endDate)
        XCTAssertTrue(sleep.save([changed]))
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first?.record.date, nap.date)
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete)
    }
    func testWakeCorrectionInvalidatesDependentButNotUnrelatedCycle() throws {
        let pair = try coveragePair()
        let third = DailyWakeRecord(day: calendar.startOfDay(for: pair.1.day.addingTimeInterval(86400)),
                                    wakeTime: pair.1.wakeTime.addingTimeInterval(86400))
        XCTAssertTrue(wake.save([pair.0, pair.1, third]))
        try attest(pair)
        try attest((pair.1, third))
        let corrected = DailyWakeRecord(id: pair.0.id, day: pair.0.day, wakeTime: pair.0.wakeTime.addingTimeInterval(60))
        XCTAssertTrue(wake.save([corrected, pair.1, third]))
        XCTAssertEqual(snapshot.daytime.count, 1)
        XCTAssertEqual(snapshot.daytime.first?.morningWakeID, pair.1.id)
    }
    func testPreviousNightEditDoesNotInvalidateFollowingDayConfirmation() throws {
        let night = try startNight()
        _ = workflow().execute()
        let morning = try XCTUnwrap(wake.load()?.first)
        let following = DailyWakeRecord(day: calendar.startOfDay(for: morning.day.addingTimeInterval(86400)),
                                        wakeTime: morning.wakeTime.addingTimeInterval(86400))
        XCTAssertTrue(wake.save([morning, following]))
        try attest((morning, following))
        let changed = SleepRecord(id: night.id, date: night.date.addingTimeInterval(-60), duration: 1,
                                  kind: .nightSleep, endDate: morning.wakeTime)
        XCTAssertTrue(sleep.save([changed]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete)
    }
    func testAwakeBreakChangeInvalidatesDaytimeConfirmation() throws {
        let pair = try coveragePair()
        let nap = try entered()
        XCTAssertTrue(sleep.saveRecording(nap, now: now))
        try attest(pair)
        let record = SleepRecord(date: nap.date.addingTimeInterval(60), duration: 1, kind: .break, parentNapID: nap.id)
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testStaleConfirmationSubmissionFailsAfterNapInsertion() throws {
        let pair = try coveragePair()
        let draft = try XCTUnwrap(TrustedObservationAdapter(defaults: defaults).beginDaytimeConfirmation(
            morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertTrue(sleep.saveRecording(try entered(), now: now))
        XCTAssertFalse(draft.submit(.allNapsRecorded, at: now.addingTimeInterval(172800), using: ObservationStorage(defaults: defaults)))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testFailedCoverageWriteCannotCreateConfirmation() throws {
        let pair = try coveragePair()
        let draft = try XCTUnwrap(TrustedObservationAdapter(defaults: defaults).beginDaytimeConfirmation(
            morningWakeID: pair.0.id, followingWakeID: pair.1.id))
        XCTAssertFalse(draft.submit(.allNapsRecorded, at: now.addingTimeInterval(172800),
                                    using: ObservationStorage(defaults: defaults, writer: { _, _ in false })))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testIDOnlyDaytimeAssertionCannotQualify() throws {
        let pair = try coveragePair()
        var metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
        metadata.daytime["id-only"] = .init(morningWakeID: pair.0.id, followingWakeID: pair.1.id,
            coverage: "confirmedComplete", binding: "", intent: "parent-attested-daytime-coverage-v1")
        XCTAssertTrue(ObservationStorage(defaults: defaults).metadata(metadata))
        XCTAssertTrue(snapshot.daytime.isEmpty)
    }
    func testMalformedMetadataIsRetainedBeforeUnverifiedRecovery() throws {
        let record = try entered()
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        let raw = Data("malformed-provenance".utf8)
        defaults.set(raw, forKey: ObservationProvenance.key)
        XCTAssertTrue(sleep.save(sleep.load()!))
        let backup = try JSONDecoder().decode([ObservationStorage.RecoveryEntry].self,
            from: XCTUnwrap(defaults.data(forKey: "observationProvenanceRecovery_v1")))
        XCTAssertTrue(backup.contains { $0.raw == raw })
        XCTAssertEqual(sleep.load()?.first?.id, record.id)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testDigestHasStableKnownSHA256ValueAndContainsNoRawHistory() throws {
        XCTAssertEqual(ObservationProvenance.digest("abc"), "sha256-v1:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let record = try entered()
        XCTAssertTrue(sleep.saveRecording(record, now: now))
        let identity = try XCTUnwrap(ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString]?.content)
        XCTAssertEqual(identity.count, 74)
        XCTAssertFalse(identity.contains(record.id.uuidString))
    }
    func testLegacyEndOnlyEditDoesNotVerifyUnchangedOnset() throws {
        let legacy = SleepRecord(date: now.addingTimeInterval(-7200), duration: 60)
        XCTAssertTrue(sleep.save([legacy]))
        let current = try XCTUnwrap(sleep.load()?.first)
        var draft = SleepRecordingDraft(defaultDate: current.date, editing: current, now: now)
        draft.end = now.addingTimeInterval(-600)
        XCTAssertTrue(sleep.saveRecording(try submitted(draft, editing: current), now: now))
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testRetryLaterPreservesPersistedCreatedAtAndDoesNotDuplicateOperation() throws {
        var draft = SleepRecordingDraft(defaultDate: now.addingTimeInterval(-7200), now: now)
        draft.start = now.addingTimeInterval(-10800)
        draft.end = now.addingTimeInterval(-600)
        let first = try XCTUnwrap(draft.record(kind: .dayNap, now: now))
        let later = try XCTUnwrap(draft.record(kind: .dayNap, now: now.addingTimeInterval(300)))
        XCTAssertNotEqual(first.createdAt, later.createdAt)
        XCTAssertEqual(first.id, later.id)
        XCTAssertTrue(sleep.saveRecording(first, now: now))
        XCTAssertTrue(sleep.saveRecording(later, now: now.addingTimeInterval(300)))
        XCTAssertEqual(sleep.load()?.first?.createdAt, first.createdAt)
        XCTAssertEqual(sleep.load()?.count, 1)
    }
    func testUntouchedStaleWakeFormCannotOverwriteNewerWake() throws {
        _ = workflow().execute()
        let original = try XCTUnwrap(wake.load()?.first)
        let draft = WakeObservationDraft(initial: original.wakeTime, existing: original)
        XCTAssertTrue(wake.save([DailyWakeRecord(id: original.id, day: original.day, wakeTime: now.addingTimeInterval(-600))]))
        let result = SleepWakeTimeWorkflow(selectedWakeTime: draft.selected, now: now, calendar: calendar,
            wakeRecords: [original], sleepRecords: [], wakePersistence: wake, sleepPersistence: sleep, capture: wakeCapture(draft)).execute()
        XCTAssertFalse(result.wakePersistenceSucceeded)
        XCTAssertEqual(wake.load()?.first?.wakeTime, now.addingTimeInterval(-600))
    }
    func testSameTimeStaleWakeSubmissionCannotRestoreRevokedTrust() throws {
        _ = workflow().execute()
        let original = try XCTUnwrap(wake.load()?.first)
        var draft = WakeObservationDraft(initial: now.addingTimeInterval(-7200), existing: original)
        draft.selected = original.wakeTime
        XCTAssertTrue(wake.save([DailyWakeRecord(id: original.id, day: original.day, wakeTime: now.addingTimeInterval(-600))]))
        XCTAssertTrue(wake.save([original]))
        let result = SleepWakeTimeWorkflow(selectedWakeTime: draft.selected, now: now, calendar: calendar,
            wakeRecords: [original], sleepRecords: [], wakePersistence: wake, sleepPersistence: sleep, capture: wakeCapture(draft)).execute()
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testUnconfirmedWakeSubmissionDoesNotCreateSemanticLink() throws {
        _ = try startNight()
        _ = workflow(confirmed: false).execute()
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testMalformedRecoveryJournalCannotReplaceOriginalNightStart() throws {
        let night = try startNight()
        let forged = SleepRecord(id: night.id, date: night.date.addingTimeInterval(-86400), duration: 0,
                                 kind: .nightSleep, isOngoing: true, createdAt: night.createdAt)
        let morning = DailyWakeRecord(day: calendar.startOfDay(for: now), wakeTime: now.addingTimeInterval(-3600))
        let pending = ObservationCompletionPending(version: 2, originalNight: forged, wake: morning,
            originalWakeContent: nil, originalWakeRevision: nil)
        defaults.set(try JSONEncoder().encode(pending), forKey: ObservationCompletionPending.key)
        _ = workflow().execute()
        XCTAssertEqual(sleep.load()?.first?.date, night.date)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
    }

    func testStaleWakeFormCannotCompleteNewlyReplacedNight() throws {
        _ = try startNight()
        var draft = WakeObservationDraft(initial: now.addingTimeInterval(-7200), existing: nil, nightRecords: sleep.load()!)
        draft.selected = now.addingTimeInterval(-3600)
        let replacement = SleepRecord(date: now.addingTimeInterval(-10800), duration: 0, kind: .nightSleep, isOngoing: true)
        XCTAssertTrue(sleep.save([replacement]))
        let result = SleepWakeTimeWorkflow(selectedWakeTime: draft.selected, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wake, sleepPersistence: sleep, capture: wakeCapture(draft)).execute()
        XCTAssertFalse(result.wakePersistenceSucceeded)
        XCTAssertTrue(sleep.load()?.first?.isOngoing == true)
        XCTAssertTrue(snapshot.wakes.isEmpty)
    }
    func testRecordChangedBeforeAttestationCannotRetainTrustedMetadata() throws {
        let original = try entered()
        let changed = SleepRecord(id: original.id, date: original.date, duration: 1)
        var writes = 0
        let persistence = SleepRecordPersistence(defaults: defaults, writer: { data, key in
            if key == ObservationProvenance.key {
                writes += 1
                if writes == 2 { self.defaults.set(try! JSONEncoder().encode([changed]), forKey: "sleepRecords") }
            }
            self.defaults.set(data, forKey: key)
            return true
        })
        XCTAssertTrue(persistence.saveRecording(original, now: now))
        XCTAssertEqual(sleep.load()?.first?.duration, 1)
        XCTAssertNotEqual(snapshot.sleeps.first?.source, .verifiedObservation)
    }

    func testNewObservationPreservesUnrelatedHistoricalRecordAndProvenance() throws {
        let historical = SleepRecord(date: now.addingTimeInterval(-864000), duration: 60)
        XCTAssertTrue(sleep.save([historical]))
        let first = try entered()
        XCTAssertTrue(sleep.saveRecording(first, now: now))
        let revision = ObservationProvenance.load(defaults)?.sleeps[first.id.uuidString]?.revision
        let next = SleepRecord(date: now.addingTimeInterval(-300), duration: 1)
        XCTAssertTrue(sleep.saveRecording(next, now: now))
        XCTAssertEqual(sleep.load()?.count, 3)
        XCTAssertEqual(sleep.load()?.first?.id, historical.id)
        XCTAssertEqual(snapshot.sleeps.first { $0.record.id == first.id }?.source, .verifiedObservation)
        XCTAssertEqual(ObservationProvenance.load(defaults)?.sleeps[first.id.uuidString]?.revision, revision)
    }
    func testCanonicalCompletionAcrossDSTUsesElapsedSeconds() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-11-01T03:00:00Z"))
        let actualWake = try XCTUnwrap(formatter.date(from: "2026-11-01T13:00:00Z"))
        let action = try XCTUnwrap(formatter.date(from: "2026-11-01T17:00:00Z"))
        let night = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true)
        XCTAssertTrue(sleep.save([night]))
        var draft = WakeObservationDraft(initial: actualWake.addingTimeInterval(-3600), nightRecords: sleep.load())
        draft.selected = actualWake
        let result = SleepWakeTimeWorkflow(selectedWakeTime: actualWake, now: action, calendar: local,
            wakeRecords: [], sleepRecords: [], wakePersistence: wake, sleepPersistence: sleep, capture: wakeCapture(draft)).execute()
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        XCTAssertEqual(sleep.load()?.first?.duration, 600)
        XCTAssertEqual(sleep.load()?.first?.observedEnd, actualWake)
        XCTAssertEqual(SleepAccounting.netMinutes(records: sleep.load()!, now: action), 600)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, night.id)
    }

    func testScopedDeletionPreservesRecordsAddedAfterStaleDashboardSnapshot() throws {
        let original = try entered()
        XCTAssertTrue(sleep.saveRecording(original, now: now))
        let newer = SleepRecord(date: now.addingTimeInterval(-120), duration: 1)
        XCTAssertTrue(sleep.saveRecording(newer, now: now))
        XCTAssertTrue(sleep.delete(ids: [original.id]))
        XCTAssertEqual(sleep.load()?.map(\.id), [newer.id])
        XCTAssertNil(ObservationProvenance.load(defaults)?.sleeps[original.id.uuidString])
    }

    func testAwakeBreakLoggingOnlyChangeDoesNotInvalidateCoverage() throws {
        let pair = try coveragePair()
        let nap = try entered()
        let pause = SleepRecord(date: nap.date.addingTimeInterval(60), duration: 1, kind: .break,
                                parentNapID: nap.id, createdAt: now)
        XCTAssertTrue(sleep.save([nap, pause]))
        try attest(pair)
        let relogged = SleepRecord(id: pause.id, date: pause.date, duration: pause.duration,
                                   kind: .break, parentNapID: nap.id, createdAt: now.addingTimeInterval(60))
        XCTAssertTrue(sleep.save([nap, relogged]))
        XCTAssertEqual(snapshot.daytime.first?.coverage, .confirmedComplete)
    }

}
