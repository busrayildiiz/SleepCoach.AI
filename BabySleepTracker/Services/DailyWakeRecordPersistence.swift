import Foundation

struct DailyWakeRecordPersistence {
    let defaults: any PrivateDataStore
    let storage: ObservationStorage
    private let key = "dailyWakeRecords_v1"

    init(defaults: any PrivateDataStore = SecureDataStore.shared, writer: ((Data, String) -> Bool)? = nil) {
        self.defaults = defaults
        storage = ObservationStorage(defaults: defaults, writer: writer)
    }

    func load() -> [DailyWakeRecord]? {
        let generation = defaults.generationToken
        guard defaults.isAvailable, let data = defaults.data(forKey: key) else { return nil }
        guard var records = try? JSONDecoder().decode([DailyWakeRecord].self, from: data) else { return nil }
        let metadata = ObservationProvenance.load(defaults)
        for index in records.indices {
            if let entry = metadata?.wakes[records[index].id.uuidString],
               entry.content == ObservationProvenance.wakeIdentity(records[index]) {
                records[index].persistedRevision = entry.revision
            }
        }
        return defaults.isAvailable && defaults.generationToken == generation ? records : nil
    }

    @discardableResult
    func save(_ records: [DailyWakeRecord], beforeWrite: ((ObservationProvenance) -> Bool)? = nil,
              completionOperationID: UUID? = nil) -> Bool {
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
        provenance.revokeCoverage(old: old, new: records)
        let cancellation = ObservationCompletionPending.load(defaults).flatMap { pending -> ObservationCompletionPending? in
            guard pending.operationID != completionOperationID, !pending.isCancelled,
                  records.first(where: { $0.id == pending.wake.id }).map(ObservationProvenance.wakeIdentity) !=
                    old.first(where: { $0.id == pending.wake.id }).map(ObservationProvenance.wakeIdentity) else { return nil }
            return pending
        }
        let standaloneCancellation = StandaloneWakePending.load(defaults).flatMap { pending -> StandaloneWakePending? in
            guard pending.operationID != completionOperationID, !pending.isCancelled else { return nil }
            func scope(_ values: [DailyWakeRecord]) -> [String] {
                values.filter { record in
                    record.id == pending.wake.id ||
                        (pending.historical == true && pending.calendar.isDate(record.day, inSameDayAs: pending.wake.day))
                }.map(ObservationProvenance.wakeIdentity).sorted()
            }
            return scope(records) != scope(old) ? pending : nil
        }
        if let pending = standaloneCancellation, pending.historical == true {
            _ = provenance.revokeUnfinishedHistoricalWake(pending)
        }
        provenance.reconcile(wakes: records)
        var prepared = true
        if let beforeWrite { ObservationStorage.lock.withoutLock { prepared = beforeWrite(provenance) } }
        guard defaults.isAvailable, defaults.generationToken == generation, prepared, defaults.data(forKey: key) == expectedData,
              defaults.data(forKey: ObservationProvenance.key) == expectedMetadata,
              completionOperationID.map({ ObservationStorage.completionIsActive($0, defaults: defaults) }) ?? true else { return false }
        // Retain a cancellation tombstone through failed/interrupted replacement writes.
        // It preserves recovery contents but prevents a deleted record from resurrecting.
        if var cancelled = cancellation {
            cancelled.isCancelled = true
            guard storage.journal(cancelled) else { return false }
        }
        if var cancelled = standaloneCancellation {
            cancelled.isCancelled = true
            guard storage.standaloneJournal(cancelled) else { return false }
        }
        // The sidecar can change even if the record write fails. Retire affected
        // drafts before observers run and require a fresh review on failure.
        HistoricalWakeDraft.invalidateChangedDays(defaults: defaults, old: old, new: records)
        guard storage.save(records, key: key, provenance: provenance, expectedData: expectedData) else { return false }
        if let cancellation, ObservationCompletionPending.load(defaults)?.operationID == cancellation.operationID {
            defaults.removeObject(forKey: ObservationCompletionPending.key)
            guard defaults.isAvailable, defaults.data(forKey: ObservationCompletionPending.key) == nil else { return false }
            guard storage.finishRetirementIfRequested(cancellation.operationID, reservation: cancellation.creation) else { return false }
        }
        if let standaloneCancellation, StandaloneWakePending.load(defaults)?.operationID == standaloneCancellation.operationID {
            defaults.removeObject(forKey: StandaloneWakePending.key)
            guard defaults.isAvailable, defaults.data(forKey: StandaloneWakePending.key) == nil else { return false }
            guard storage.finishRetirementIfRequested(standaloneCancellation.operationID, reservation: standaloneCancellation.creation) else { return false }
        }
        if records.count < old.count { _ = storage.pruneRecoveryArchives(removingRaw: true) }

        guard defaults.isAvailable else { return false }
        ObservationStorage.post(.dailyWakeRecordsDidChange)
        return defaults.isAvailable && defaults.generationToken == generation
    }
}
