import Foundation

struct SleepWakeTimeWorkflowResult {
    let updatedWakeRecords: [DailyWakeRecord]
    let updatedSleepRecords: [SleepRecord]
    let normalizedWakeTime: Date?
    let closedNightRecord: SleepRecord?
    let wakePersistenceSucceeded: Bool
    let sleepPersistenceSucceeded: Bool
    /// Sidecar publication completed; this is not a verified-source/authorization flag.
    var evidencePublicationSucceeded = false
}

/// Existing wake question + deliberate time entry. Saving an untouched prefill mints no intent.
struct WakeObservationDraft {
    private let initial: Date
    private let existing: DailyWakeRecord?
    private let nightSnapshot: [String]?
    private let operationID: UUID
    private let creationIntent: ObservationCreationIntent?
    var selected: Date
    init(initial: Date, existing: DailyWakeRecord? = nil, nightRecords: [SleepRecord]? = nil) {
        nightSnapshot = nightRecords.map { $0.filter { $0.kind == .nightSleep && $0.isOngoing }.map(ObservationProvenance.sleepIdentity).sorted() }
        self.initial = initial; self.existing = existing; selected = initial
        let operation = ObservationCreationIntent(recordID: existing?.id ?? UUID())
        creationIntent = operation
        operationID = operation.operationID
    }
    var requiresExplicitCancellation: Bool { creationIntent?.requiresExplicitCancellation == true }
    @discardableResult
    func abandon() -> Bool { creationIntent?.abandon() ?? true }
    /// Audited Save action for the existing actual-wake question, never a value constructor.
    func submit(save: (Date, WakeObservationCapture?) -> Bool) -> Bool {
        save(selected, WakeObservationCapture(selected: selected, existing: existing, attestsObservation: selected != initial,
                                             nightSnapshot: nightSnapshot, operationID: operationID, creationIntent: creationIntent))
    }
}
struct WakeObservationCapture {
    let selected: Date
    let expectedContent: String?
    let expectedRevision: UUID?
    let attestsObservation: Bool
    let nightSnapshot: [String]?
    let operationID: UUID
    let creationIntent: ObservationCreationIntent?
    fileprivate init(selected: Date, existing: DailyWakeRecord?, attestsObservation: Bool, nightSnapshot: [String]?,
                     operationID: UUID, creationIntent: ObservationCreationIntent?) {
        self.operationID = operationID
        self.creationIntent = creationIntent
        self.nightSnapshot = nightSnapshot
        self.attestsObservation = attestsObservation
        self.selected = selected
        expectedContent = existing.map(ObservationProvenance.wakeIdentity)
        expectedRevision = existing?.persistedRevision
    }
}

struct SleepWakeTimeWorkflow {
    let selectedWakeTime: Date
    let now: Date
    let calendar: Calendar
    let wakeRecords: [DailyWakeRecord]
    let sleepRecords: [SleepRecord]
    let wakePersistence: DailyWakeRecordPersistence
    let sleepPersistence: SleepRecordPersistence
    var capture: WakeObservationCapture? = nil

    private let pendingKey = ObservationCompletionPending.key

    /// Startup recovery uses the ORIGINAL persisted intent, never an unchanged prefill.
    /// Unsupported, cancelled, or revision-mismatched journals remain fail-closed.
    static func resumePending(now: Date, wakePersistence: DailyWakeRecordPersistence,
                              sleepPersistence: SleepRecordPersistence) -> SleepWakeTimeWorkflowResult? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard let pending = ObservationCompletionPending.load(wakePersistence.defaults), pending.wakeAttested,
              pending.canResume(defaults: wakePersistence.defaults, now: now) else {
            guard let standalone = StandaloneWakePending.load(wakePersistence.defaults),
                  standalone.canResume(defaults: wakePersistence.defaults, now: now) else { return nil }
            return SleepWakeTimeWorkflow(selectedWakeTime: standalone.wake.wakeTime, now: now,
                calendar: standalone.calendar, wakeRecords: [], sleepRecords: [],
                wakePersistence: wakePersistence, sleepPersistence: sleepPersistence).completeStandalone(standalone)
        }
        return SleepWakeTimeWorkflow(selectedWakeTime: pending.wake.wakeTime, now: now,
            calendar: pending.recordedCalendar ?? .current, wakeRecords: [], sleepRecords: [],
            wakePersistence: wakePersistence, sleepPersistence: sleepPersistence).complete(pending)
    }

    private func result(time: Date?, closed: SleepRecord? = nil, wakeOK: Bool = false,
                        sleepOK: Bool = false, evidenceOK: Bool = false) -> SleepWakeTimeWorkflowResult {
        SleepWakeTimeWorkflowResult(updatedWakeRecords: wakePersistence.load() ?? [],
            updatedSleepRecords: sleepPersistence.load() ?? [], normalizedWakeTime: time,
            closedNightRecord: closed, wakePersistenceSucceeded: wakeOK,
            sleepPersistenceSucceeded: sleepOK, evidencePublicationSucceeded: evidenceOK)
    }
    private func wakeMatches(_ record: DailyWakeRecord, _ expected: ObservationProvenance.Entry?) -> Bool {
        guard let expected, let metadata = ObservationProvenance.load(wakePersistence.defaults),
              let actual = wakePersistence.load()?.first(where: { $0.id == record.id }),
              let entry = metadata.wakes[record.id.uuidString] else { return false }
        return entry.revision == expected.revision && entry.content == expected.content &&
            ObservationProvenance.wakeIdentity(actual) == expected.content
    }
    private func nightMatches(_ record: SleepRecord, _ expected: ObservationProvenance.Entry?) -> Bool {
        guard let expected, let metadata = ObservationProvenance.load(sleepPersistence.defaults),
              let actual = sleepPersistence.load()?.first(where: { $0.id == record.id }),
              let entry = metadata.sleeps[record.id.uuidString] else { return false }
        return entry.revision == expected.revision && entry.content == expected.content &&
            ObservationProvenance.sleepIdentity(actual) == expected.content
    }
    private func verified(_ entry: ObservationProvenance.Entry, intent: String) -> ObservationProvenance.Entry {
        .init(revision: entry.revision, content: entry.content,
              source: LearningEvidenceSource.verifiedObservation.rawValue, intent: intent,
              coverageContent: entry.coverageContent, coverageRevision: entry.coverageRevision)
    }
    private func inputIdentity(_ date: Date) -> String {
        ObservationProvenance.digest(LearningEvidenceIdentity.pack(["standalone-wake-input-v1", LearningEvidenceIdentity.date(date)]))
    }

    func execute() -> SleepWakeTimeWorkflowResult {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = wakePersistence.defaults
        if let intent = capture?.creationIntent, !wakePersistence.storage.bind(intent) { return result(time: nil) }
        guard defaults === sleepPersistence.defaults,
              now.timeIntervalSinceReferenceDate.isFinite, selectedWakeTime.timeIntervalSinceReferenceDate.isFinite,
              defaults.data(forKey: "sleepRecords") == nil || sleepPersistence.load() != nil,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || wakePersistence.load() != nil else { return result(time: nil) }
        // A completed ordinary operation may outlive its editor or cross midnight.
        // This receipt acknowledges the same write; it never republishes attestation.
        if let capture, let id = capture.creationIntent?.recordID,
           let actual = wakePersistence.load()?.first(where: { $0.id == id }),
           let entry = ObservationProvenance.load(defaults)?.wakes[id.uuidString],
           entry.completedOperationID == capture.operationID,
           entry.completedInput == inputIdentity(selectedWakeTime),
           entry.content == ObservationProvenance.wakeIdentity(actual), entry.revision == actual.persistedRevision,
           actual.wakeTime <= now,
           !capture.attestsObservation || entry.source == LearningEvidenceSource.verifiedObservation.rawValue {
            return result(time: actual.wakeTime, wakeOK: true, evidenceOK: true)
        }
        let pending = ObservationCompletionPending.load(defaults)
        let standalone = StandaloneWakePending.load(defaults)
        if let standalone, (standalone.wake.wakeTime == selectedWakeTime || standalone.selectedInput == selectedWakeTime),
           standalone.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(standalone.operationID, by: capture?.creationIntent)
            return completeStandalone(standalone)
        }
        if let pending, pending.wakeAttested,
           (pending.wake.wakeTime == selectedWakeTime || pending.selectedInput == selectedWakeTime),
           pending.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(pending.operationID, by: capture?.creationIntent)
            return complete(pending)
        }
        let today = calendar.startOfDay(for: now)
        let parts = calendar.dateComponents([.hour, .minute], from: selectedWakeTime)
        guard let time = calendar.date(bySettingHour: parts.hour ?? 7, minute: parts.minute ?? 0, second: 0, of: today),
              time <= now else { return result(time: nil) }
        // A still-open editor may carry seconds on its original DatePicker value.
        if let pending, pending.wakeAttested, pending.wake.wakeTime == time,
           pending.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(pending.operationID, by: capture?.creationIntent)
            return complete(pending)
        }
        if let standalone, standalone.wake.wakeTime == time,
           standalone.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(standalone.operationID, by: capture?.creationIntent)
            return completeStandalone(standalone)
        }
        let sleeps = sleepPersistence.load() ?? []
        let wakes = wakePersistence.load() ?? []
        let todayWakes = wakes.filter { calendar.isDate($0.day, inSameDayAs: today) }
        guard todayWakes.count <= 1 else { return result(time: time) } // preserve ambiguous historical observations
        let oldWake = todayWakes.first
        if let expected = capture?.nightSnapshot,
           expected != sleeps.filter({ $0.kind == .nightSleep && $0.isOngoing }).map(ObservationProvenance.sleepIdentity).sorted() {
            return result(time: time)
        }
        if let capture, capture.expectedContent != oldWake.map(ObservationProvenance.wakeIdentity) ||
            capture.expectedRevision != oldWake?.persistedRevision {
            // An exact replay grants no fresh authority to a revoked revision.
            return result(time: time, wakeOK: oldWake?.wakeTime == time,
                          evidenceOK: oldWake?.wakeTime == time &&
                            TrustedObservationAdapter(defaults: defaults).snapshot().wakes.first(where: { $0.record.id == oldWake?.id })?.source == .verifiedObservation)
        }
        let wake = DailyWakeRecord(id: oldWake?.id ?? capture?.creationIntent?.recordID ?? UUID(), day: today, wakeTime: time)
        let attested = capture?.selected == selectedWakeTime && capture?.attestsObservation == true
        var creation: ObservationCreationReservation?
        if let intent = capture?.creationIntent {
            guard let reservation = wakePersistence.storage.reserveCreation(intent, collection: "dailyWakeRecords_v1",
                content: ObservationProvenance.wakeIdentity(wake)) else { return result(time: time) }
            creation = reservation
        }
        if let original = sleeps.filter({ $0.kind == .nightSleep && $0.isOngoing && $0.date < time })
            .sorted(by: { $0.date > $1.date }).first {
            var transaction = ObservationCompletionPending(version: 3, originalNight: original, wake: wake,
                originalWakeContent: oldWake.map(ObservationProvenance.wakeIdentity), originalWakeRevision: oldWake?.persistedRevision)
            transaction.recordedCalendar = calendar
            transaction.operationID = capture?.operationID ?? transaction.operationID
            transaction.wakeAttested = attested
            transaction.onset = ObservationProvenance.load(defaults)?.sleeps[original.id.uuidString]
            transaction.originalNightRevision = original.persistedRevision
            transaction.creation = creation
            transaction.selectedInput = selectedWakeTime
            if let raw = defaults.data(forKey: pendingKey) {
                guard wakePersistence.storage.preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1") else { return result(time: time) }
            }
            guard transaction.isValid(now: now, calendar: calendar), wakePersistence.storage.journal(transaction) else { return result(time: time) }
            return complete(transaction)
        }
        let transaction = StandaloneWakePending(operationID: capture?.operationID ?? UUID(), wake: wake,
            originalContent: oldWake.map(ObservationProvenance.wakeIdentity), originalRevision: oldWake?.persistedRevision,
            calendar: calendar, attested: attested, creation: creation, selectedInput: selectedWakeTime)
        if let raw = defaults.data(forKey: StandaloneWakePending.key) {
            guard wakePersistence.storage.preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1") else { return result(time: time) }
        }
        guard wakePersistence.storage.standaloneJournal(transaction) else { return result(time: time) }
        return completeStandalone(transaction)
    }

    private func completeStandalone(_ original: StandaloneWakePending) -> SleepWakeTimeWorkflowResult {
        let defaults = wakePersistence.defaults
        guard defaults === sleepPersistence.defaults, original.canResume(defaults: defaults, now: now) else {
            return result(time: original.wake.wakeTime)
        }
        var transaction = original
        let wake = transaction.wake
        let time = wake.wakeTime
        if !wakeMatches(wake, transaction.expected) {
            var current = wakePersistence.load() ?? []
            current.removeAll { $0.id == wake.id }
            current.append(wake)
            guard wakePersistence.save(current, beforeWrite: { prepared in
                transaction.expected = prepared.wakes[wake.id.uuidString]
                return wakePersistence.storage.updateJournal(transaction)
            }, completionOperationID: transaction.operationID) else { return result(time: time) }
        }
        guard wakeMatches(wake, transaction.expected), let receipt = transaction.expected,
              var metadata = ObservationProvenance.load(defaults),
              StandaloneWakePending.load(defaults)?.operationID == transaction.operationID,
              StandaloneWakePending.load(defaults)?.isCancelled == false else { return result(time: time, wakeOK: true) }
        if let creation = transaction.creation, !wakePersistence.storage.finishCreation(creation) { return result(time: time, wakeOK: true) }
        var publishedEntry = transaction.attested ? verified(receipt, intent: "parent-entered-morning-wake-v1") : receipt
        publishedEntry.completedOperationID = transaction.operationID
        publishedEntry.completedInput = inputIdentity(transaction.selectedInput ?? time)
        metadata.wakes[wake.id.uuidString] = publishedEntry
        let published = wakePersistence.storage.metadata(metadata) && wakeMatches(wake, receipt)
        if published, StandaloneWakePending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: StandaloneWakePending.key)
        }
        return result(time: time, wakeOK: true, evidenceOK: published)
    }

    private func complete(_ original: ObservationCompletionPending) -> SleepWakeTimeWorkflowResult {
        guard wakePersistence.defaults === sleepPersistence.defaults,
              original.canResume(defaults: wakePersistence.defaults, now: now) else { return result(time: original.wake.wakeTime) }
        let defaults = wakePersistence.defaults
        var transaction = original
        let wake = transaction.wake
        let closed = transaction.night
        let time = wake.wakeTime
        if !wakeMatches(wake, transaction.expectedWake) {
            var wakes = wakePersistence.load() ?? []
            wakes.removeAll { $0.id == wake.id }
            wakes.append(wake)
            guard wakePersistence.save(wakes, beforeWrite: { prepared in
                transaction.expectedWake = prepared.wakes[wake.id.uuidString]
                return wakePersistence.storage.updateJournal(transaction)
            }, completionOperationID: transaction.operationID) else { return result(time: time, closed: closed) }
        }
        guard wakeMatches(wake, transaction.expectedWake), transaction.canResume(defaults: defaults, now: now) else {
            return result(time: time, closed: closed, wakeOK: true)
        }
        if !nightMatches(closed, transaction.expectedNight) {
            // Re-read after wake notifications. Never overwrite a reentrant correction or
            // drop unrelated records inserted while the first write notified its observers.
            let current = sleepPersistence.load() ?? []
            guard current.first(where: { $0.id == closed.id }).map(ObservationProvenance.sleepIdentity) == transaction.originalNightContent else {
                return result(time: time, closed: closed, wakeOK: true)
            }
            let updated = current.map { $0.id == closed.id ? closed : $0 }
            guard sleepPersistence.save(updated, beforeWrite: { prepared in
                transaction.expectedNight = prepared.sleeps[closed.id.uuidString]
                return wakePersistence.storage.updateJournal(transaction)
            }, completionOperationID: transaction.operationID) else { return result(time: time, closed: closed, wakeOK: true) }
        }
        // Receipts were captured before either service emitted synchronous notifications.
        // A matching timestamp, ID, or latest metadata entry alone is never sufficient.
        guard wakeMatches(wake, transaction.expectedWake), nightMatches(closed, transaction.expectedNight),
              let wakeEntry = transaction.expectedWake, let nightEntry = transaction.expectedNight,
              var metadata = ObservationProvenance.load(defaults),
              ObservationCompletionPending.load(defaults)?.operationID == transaction.operationID,
              ObservationCompletionPending.load(defaults)?.isCancelled == false else {
            return result(time: time, closed: closed, wakeOK: true, sleepOK: true)
        }
        if let creation = transaction.creation, !wakePersistence.storage.finishCreation(creation) {
            return result(time: time, closed: closed, wakeOK: true, sleepOK: true)
        }
        if transaction.wakeAttested {
            metadata.wakes[wake.id.uuidString] = verified(wakeEntry, intent: "parent-entered-morning-wake-v1")
            if let onset = transaction.onset, onset.content == transaction.originalNightContent,
               onset.revision == transaction.originalNightRevision,
               onset.source == LearningEvidenceSource.verifiedObservation.rawValue,
               onset.intent == "parent-entered-sleep-boundaries-v1" {
                metadata.sleeps[closed.id.uuidString] = verified(nightEntry, intent: "parent-confirmed-night-completion-v1")
            }
            metadata.links[wake.id.uuidString] = .init(nightID: closed.id, wakeID: wake.id,
                nightRevision: nightEntry.revision, wakeRevision: wakeEntry.revision)
        }
        let published = wakePersistence.storage.metadata(metadata) && wakeMatches(wake, wakeEntry) && nightMatches(closed, nightEntry)
        if published, ObservationCompletionPending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: pendingKey)
        }
        return result(time: time, closed: closed, wakeOK: true, sleepOK: true, evidenceOK: published)
    }
}
