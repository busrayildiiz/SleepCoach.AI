import Foundation

struct SleepRecordPersistence {
    let defaults: any PrivateDataStore
    let storage: ObservationStorage
    private let key = "sleepRecords"

    init(defaults: any PrivateDataStore = SecureDataStore.shared, writer: ((Data, String) -> Bool)? = nil) {
        self.defaults = defaults
        storage = ObservationStorage(defaults: defaults, writer: writer)
    }

    func load() -> [SleepRecord]? {
        let generation = defaults.generationToken
        guard defaults.isAvailable, let data = defaults.data(forKey: key) else { return nil }
        guard var records = try? JSONDecoder().decode([SleepRecord].self, from: data) else { return nil }
        let metadata = ObservationProvenance.load(defaults)
        for index in records.indices {
            if let entry = metadata?.sleeps[records[index].id.uuidString],
               entry.content == ObservationProvenance.sleepIdentity(records[index]) {
                records[index].persistedRevision = entry.revision
            }
        }
        return defaults.isAvailable && defaults.generationToken == generation ? records : nil
    }

    /// Re-read before saving so a presented form cannot overwrite newer records.
    /// Break validation uses the latest parent, not a stale sheet snapshot.
    @discardableResult
    func saveRecording(_ record: SleepRecord, now: Date = Date()) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let generation = defaults.generationToken
        guard defaults.isAvailable, record.creationIntent?.isRetired != true else { return false }
        if let intent = record.creationIntent, !storage.bind(intent) { return false }
        if defaults.data(forKey: key) != nil && load() == nil { return false }
        var records = load() ?? []
        let current = records.first { $0.id == record.id }.map(ObservationProvenance.sleepIdentity)
        if record.recordingDraft {
            // Exact replay succeeds; a changed or deleted baseline cannot be resurrected.
            if let existing = records.first(where: { $0.id == record.id }),
               ObservationProvenance.sleepCoverageIdentity(existing) == ObservationProvenance.sleepCoverageIdentity(record) {
                // A retry may occur later, but cannot rewrite the original logging time
                // or use an exact observation replay to renew a revoked attestation.
                if let reservation = record.creationIntent?.reservation {
                    return storage.finishCreation(reservation)
                }
                return true
            }
            guard record.recordingBaseline == current else { return false }
            if record.recordingBaseline != nil {
                guard record.recordingRevision == records.first(where: { $0.id == record.id })?.persistedRevision else {
                    return false
                }
            }
        }
        let priorEntry = ObservationProvenance.load(defaults)?.sleeps[record.id.uuidString]
        if let capture = record.observationCapture {
            guard capture.content == ObservationProvenance.sleepIdentity(record),
                  capture.previousContent == current,
                  capture.creationOperationID == record.creationIntent?.operationID else { return false }
        }
        if let expectedParent = record.parentBaseline {
            guard let parent = records.first(where: { $0.id == record.parentNapID }),
                  ObservationProvenance.sleepIdentity(parent) == expectedParent,
                  parent.persistedRevision == record.parentRevision else { return false }
        }
        if record.kind == .break {
            guard let parent = records.first(where: { $0.id == record.parentNapID }),
                  let end = record.observedEnd else { return false }
            var draft = AwakeBreakDraft(parent: parent, now: now)
            draft.start = record.date
            draft.end = end
            guard draft.validationMessage(existing: records.filter { $0.id != record.id }, now: now) == nil else {
                return false
            }
        }
        if record.kind == .dayNap, !record.isOngoing,
           records.contains(where: { $0.id == record.id && $0.kind == .dayNap && $0.isOngoing }) {
            // Complete against the latest breaks under the same storage lock as the write.
            guard let end = record.observedEnd,
                  !records.contains(where: {
                      $0.kind == .break && $0.parentNapID == record.id &&
                          $0.observedEnd.map { $0 > end } == true
                  }) else { return false }
        }
        var creation: ObservationCreationReservation?
        if record.recordingDraft, record.recordingBaseline == nil {
            guard let intent = record.creationIntent, intent.recordID == record.id,
                  let reserved = storage.reserveCreation(intent, collection: key,
                      content: ObservationProvenance.sleepCoverageIdentity(record)) else { return false }
            creation = reserved
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        var expectedEntry: ObservationProvenance.Entry?
        guard save(records, beforeWrite: { prepared in
            expectedEntry = prepared.sleeps[record.id.uuidString]
            return true
        }, creationIntent: record.creationIntent), defaults.generationToken == generation else { return false }
        if let creation {
            // The record write succeeded even if an observer subsequently corrected
            // its revision. Consume the creation, but let the exact receipt below
            // withhold attestation from that newer revision.
            guard load()?.contains(where: { $0.id == record.id }) == true,
                  storage.finishCreation(creation) else { return false }
        }
        let parentStillMatches = record.parentBaseline.map { expected in
            load()?.first(where: { $0.id == record.parentNapID }).map {
                ObservationProvenance.sleepIdentity($0) == expected && $0.persistedRevision == record.parentRevision
            } ?? false
        } ?? true
        if let capture = record.observationCapture,
           record.creationIntent?.isRetired != true,
           capture.confirmsStart || (priorEntry?.content == capture.previousContent &&
               priorEntry?.source == LearningEvidenceSource.verifiedObservation.rawValue &&
               priorEntry?.intent == "parent-entered-sleep-boundaries-v1"),
           var metadata = ObservationProvenance.load(defaults),
           let entry = metadata.sleeps[record.id.uuidString], entry.content == capture.content,
           entry.revision == expectedEntry?.revision, parentStillMatches,
           load()?.first(where: { $0.id == record.id }).map(ObservationProvenance.sleepIdentity) == capture.content {
            metadata.sleeps[record.id.uuidString] = ObservationProvenance.Entry(
                revision: entry.revision, content: entry.content,
                source: LearningEvidenceSource.verifiedObservation.rawValue,
                intent: capture.intent, coverageContent: entry.coverageContent,
                coverageRevision: entry.coverageRevision)
            // A failed positive attestation leaves the successfully saved record unverified.
            _ = storage.metadata(metadata)
        }
        return defaults.isAvailable && defaults.generationToken == generation
    }

    /// Scoped deletion never replaces a newer collection with a stale dashboard array.
    @discardableResult
    func delete(ids: Set<UUID>) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable, defaults.data(forKey: key) == nil || load() != nil else { return false }
        guard storage.cancelCreations(collection: key, deletedIDs: ids) else { return false }
        return save((load() ?? []).filter { !ids.contains($0.id) })
    }

    @discardableResult
    func save(_ records: [SleepRecord], beforeWrite: ((ObservationProvenance) -> Bool)? = nil,
              completionOperationID: UUID? = nil, creationIntent: ObservationCreationIntent? = nil) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        // Never replace unreadable user observations with an empty recovery snapshot.
        let generation = defaults.generationToken
        guard defaults.isAvailable, defaults.data(forKey: key) == nil || load() != nil,
              Set(records.map(\.id)).count == records.count else { return false }
        let expectedData = defaults.data(forKey: key)
        let expectedMetadata = defaults.data(forKey: ObservationProvenance.key)
        var provenance = ObservationProvenance.load(defaults) ?? ObservationProvenance()
        let old = load() ?? []
        let deletedIDs = Set(old.map(\.id)).subtracting(records.map(\.id))
        guard storage.cancelCreations(collection: key, deletedIDs: deletedIDs) else { return false }
        if !deletedIDs.isEmpty, !storage.requestRecoveryCleanup() { return false }
        provenance.revokeCoverage(old: old, new: records, wakes: DailyWakeRecordPersistence(defaults: defaults).load() ?? [])
        // A break is its own observation. Parent onset/end and the semantic end-at-wake
        // link remain valid when their exact contents are unchanged; Phase A checks each
        // break's provenance separately. Coverage is revoked for the changed net interval.
        let cancellation = ObservationCompletionPending.load(defaults).flatMap { pending -> ObservationCompletionPending? in
            guard pending.operationID != completionOperationID, !pending.isCancelled,
                  records.first(where: { $0.id == pending.originalNight.id }).map(ObservationProvenance.sleepIdentity) !=
                    old.first(where: { $0.id == pending.originalNight.id }).map(ObservationProvenance.sleepIdentity) else { return nil }
            return pending
        }
        provenance.reconcile(sleeps: records)
        var prepared = true
        if let beforeWrite { ObservationStorage.lock.withoutLock { prepared = beforeWrite(provenance) } }
        guard defaults.isAvailable, defaults.generationToken == generation, prepared, defaults.data(forKey: key) == expectedData,
              defaults.data(forKey: ObservationProvenance.key) == expectedMetadata,
              creationIntent?.isRetired != true,
              completionOperationID.map({ ObservationStorage.completionIsActive($0, defaults: defaults) }) ?? true else { return false }
        // Retain a cancellation tombstone through failed/interrupted replacement writes.
        // It preserves recovery contents but prevents a deleted record from resurrecting.
        if var cancelled = cancellation {
            cancelled.isCancelled = true
            guard storage.journal(cancelled) else { return false }
        }
        guard storage.save(records, key: key, provenance: provenance, expectedData: expectedData) else { return false }
        if let cancellation, ObservationCompletionPending.load(defaults)?.operationID == cancellation.operationID {
            defaults.removeObject(forKey: ObservationCompletionPending.key)
            guard defaults.isAvailable, defaults.data(forKey: ObservationCompletionPending.key) == nil else { return false }
            guard storage.finishRetirementIfRequested(cancellation.operationID, reservation: cancellation.creation) else { return false }
        }
        if records.count < old.count { _ = storage.pruneRecoveryArchives(removingRaw: true) }

        guard defaults.isAvailable else { return false }
        ObservationStorage.post(.sleepRecordsDidChange)
        return defaults.isAvailable && defaults.generationToken == generation
    }
}
