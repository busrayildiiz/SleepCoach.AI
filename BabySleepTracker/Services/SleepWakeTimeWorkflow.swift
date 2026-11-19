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
    var historicalRecovery: HistoricalWakeRecoveryState? = nil
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

enum DayDetailWakeEvidence: Equatable {
    case missing, recorded(Date), ambiguous

    init(records: [DailyWakeRecord], day: Date, calendar: Calendar) {
        let candidates = records.filter { calendar.isDate($0.day, inSameDayAs: day) }
        switch candidates.count {
        case 0: self = .missing
        case 1: self = .recorded(candidates[0].wakeTime)
        default: self = .ambiguous
        }
    }
}

/// An editor snapshot for one explicitly selected historical date.
final class HistoricalWakeDraft {
    private struct OpenDraft {
        weak var value: HistoricalWakeDraft?
    }

    private static var openDrafts: [OpenDraft] = []
    let day: Date
    let calendar: Calendar
    let candidates: [DailyWakeRecord]
    fileprivate let intent: ObservationCreationIntent
    fileprivate let defaults: UserDefaults
    fileprivate private(set) var invalidated = false
    fileprivate var confirmation: HistoricalWakeConfirmation?

    init(day: Date, calendar: Calendar, persistence: DailyWakeRecordPersistence) {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let scope = DaytimeReviewWindow.capture(calendar)
        self.calendar = scope
        let validDay = day.timeIntervalSinceReferenceDate.isFinite
        self.day = validDay ? scope.startOfDay(for: day) : day
        defaults = persistence.defaults
        candidates = validDay ? (persistence.load() ?? []).filter { scope.isDate($0.day, inSameDayAs: day) } : []
        intent = ObservationCreationIntent(recordID: candidates.first?.id ?? UUID())
        Self.openDrafts.removeAll { $0.value == nil }
        if validDay { Self.openDrafts.append(OpenDraft(value: self)) }
    }

    /// Called only by the parent's explicit confirmation action.
    func confirmObservedWake(at time: Date) -> HistoricalWakeConfirmation? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard confirmation == nil, !intent.isRetired, time.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let capture = HistoricalWakeConfirmation(time: time)
        confirmation = capture
        return capture
    }

    static func invalidateChangedDays(defaults: UserDefaults, old: [DailyWakeRecord], new: [DailyWakeRecord]) {
        // Called under the persistence lock before any record-write notification.
        openDrafts.removeAll { $0.value == nil }
        for entry in openDrafts {
            guard let draft = entry.value, draft.defaults === defaults, !draft.invalidated else { continue }
            func identities(_ records: [DailyWakeRecord]) -> [String] {
                records.filter { draft.calendar.isDate($0.day, inSameDayAs: draft.day) }
                    .map(ObservationProvenance.wakeIdentity).sorted()
            }
            if identities(old) != identities(new) { draft.invalidated = true }
        }
    }

    func abandon() -> Bool { intent.abandon() }
}

/// The draft owns this opaque capture. Object identity binds it to the draft's
/// calendar, day, expected wake and operation, including an initially absent wake.
final class HistoricalWakeConfirmation {
    fileprivate let time: Date
    fileprivate var spent = false

    fileprivate init(time: Date) { self.time = time }
}

enum HistoricalWakeRecoveryState: Equatable {
    case pending, failed

    var message: String {
        switch self {
        case .pending: return "A historical morning wake still needs recovery. Try Save again."
        case .failed: return "Historical morning wake recovery could not be saved. Try Save again."
        }
    }
}

enum HistoricalWakeOutcome: Equatable {
    case saved, confirmationRequired, invalidTime, ambiguous, stale, recoveryPending, recoveryFailed, saveFailed, incomplete

    var canRetry: Bool { self == .incomplete }
    var blocksEditing: Bool { canRetry || self == .recoveryPending || self == .recoveryFailed }

    var message: String {
        switch self {
        case .saved: return ""
        case .confirmationRequired: return "Confirm that you observed the selected morning wake."
        case .invalidTime: return "Choose an observed wake time on a past date."
        case .ambiguous: return "More than one wake is recorded for this date. No wake time can be confirmed for this date. Choose another date, or cancel and resolve the duplicate wake records first."
        case .stale: return "Wake evidence changed or a previous write invalidated this review. Review the latest entry and confirm it again."
        case .recoveryPending: return "Another sleep or wake entry needs recovery. Cancel and reopen this form after resolving it."
        case .recoveryFailed: return "Wake recovery is blocked. Cancel and reopen this form after recovery is resolved."
        case .saveFailed: return "The wake could not be saved. Review the entry and confirm it again."
        case .incomplete: return "The wake could not be fully saved. Retry with the same date and time."
        }
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
        guard wakePersistence.storage.retireInvalidForwardCompletion(now: now) else { return nil }
        guard let pending = ObservationCompletionPending.load(wakePersistence.defaults),
              pending.wakeAttested || pending.nightCompletionInput != nil,
              pending.canResume(defaults: wakePersistence.defaults, now: now) else {
            guard let standalone = StandaloneWakePending.load(wakePersistence.defaults) else { return nil }
            let workflow = SleepWakeTimeWorkflow(selectedWakeTime: standalone.wake.wakeTime, now: now,
                calendar: standalone.calendar, wakeRecords: [], sleepRecords: [],
                wakePersistence: wakePersistence, sleepPersistence: sleepPersistence)
            guard standalone.canResume(defaults: wakePersistence.defaults, now: now) else {
                if standalone.historical == true { _ = workflow.resolveHistoricalRecovery() }
                return nil
            }
            return workflow.completeStandalone(standalone)
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

    func recoverHistoricalWake(_ draft: HistoricalWakeDraft,
                               confirmation: HistoricalWakeConfirmation? = nil) -> HistoricalWakeOutcome {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = wakePersistence.defaults
        let time = selectedWakeTime
        let scope = draft.calendar
        guard let confirmation, draft.confirmation === confirmation, confirmation.time == time, !confirmation.spent
        else { return .confirmationRequired }
        guard defaults === draft.defaults, defaults === sleepPersistence.defaults,
              now.timeIntervalSinceReferenceDate.isFinite, time.timeIntervalSinceReferenceDate.isFinite,
              draft.day.timeIntervalSinceReferenceDate.isFinite,
              time <= now, draft.day < scope.startOfDay(for: now),
              scope.isDate(time, inSameDayAs: draft.day) else { return .invalidTime }
        func matchingJournal() -> StandaloneWakePending? {
            guard let pending = StandaloneWakePending.load(defaults), pending.historical == true,
                  pending.operationID == draft.intent.operationID, pending.wake.wakeTime == time,
                  pending.calendar == scope, pending.wake.day == draft.day,
                  pending.originalContent == draft.candidates.first.map(ObservationProvenance.wakeIdentity),
                  pending.originalRevision == draft.candidates.first?.persistedRevision else { return nil }
            return pending
        }
        func outcomeAfterAttempt(_ result: SleepWakeTimeWorkflowResult? = nil) -> HistoricalWakeOutcome {
            if result?.evidencePublicationSucceeded == true {
                confirmation.spent = true
                return .saved
            }
            if let pending = matchingJournal(), !draft.intent.isRetired,
               defaults.data(forKey: ObservationCompletionPending.key) == nil,
               pending.canResume(defaults: defaults, now: now) { return .incomplete }

            // Only a live journal can authorize another attempt with this capture.
            confirmation.spent = true
            if matchingJournal() != nil { return .stale }
            if defaults.data(forKey: StandaloneWakePending.key) != nil ||
                defaults.data(forKey: ObservationCompletionPending.key) != nil { return .recoveryFailed }
            return draft.invalidated || draft.intent.isRetired ? .stale : .saveFailed
        }

        let loaded = wakePersistence.load()
        guard defaults.data(forKey: "dailyWakeRecords_v1") == nil || loaded != nil,
              defaults.data(forKey: ObservationProvenance.key) == nil || ObservationProvenance.load(defaults) != nil
        else { return .recoveryFailed }
        if let pending = matchingJournal() {
            guard !draft.intent.isRetired else { return .stale }
            guard defaults.data(forKey: ObservationCompletionPending.key) == nil else { return .recoveryFailed }
            guard pending.canResume(defaults: defaults, now: now) else { return .stale }
            return outcomeAfterAttempt(completeStandalone(pending))
        }
        let wakes = loaded ?? []
        let candidates = wakes.filter { scope.isDate($0.day, inSameDayAs: draft.day) }
        guard candidates.count <= 1 else { return .ambiguous }
        guard !draft.intent.isRetired else { return .stale }
        guard wakePersistence.storage.bind(draft.intent) else { return .recoveryFailed }
        if (defaults.data(forKey: StandaloneWakePending.key) != nil && StandaloneWakePending.load(defaults) == nil) ||
            (defaults.data(forKey: ObservationCompletionPending.key) != nil && ObservationCompletionPending.load(defaults) == nil) {
            return .recoveryFailed
        }
        let current = candidates.first
        let entry = current.flatMap { ObservationProvenance.load(defaults)?.wakes[$0.id.uuidString] }
        guard defaults.data(forKey: ObservationCompletionPending.key) == nil,
              defaults.data(forKey: StandaloneWakePending.key) == nil else { return .recoveryPending }
        let expected = draft.candidates.first
        guard !draft.invalidated,
              current.map(ObservationProvenance.wakeIdentity) == expected.map(ObservationProvenance.wakeIdentity),
              current?.persistedRevision == expected?.persistedRevision else { return .stale }
        if let current, current.wakeTime == time,
           entry?.revision == current.persistedRevision,
           entry?.source == LearningEvidenceSource.verifiedObservation.rawValue,
           entry?.intent == "parent-entered-morning-wake-v1" {
            confirmation.spent = true
            return .saved
        }
        let wake = DailyWakeRecord(id: draft.intent.recordID, day: draft.day, wakeTime: time)
        guard let creation = wakePersistence.storage.reserveCreation(draft.intent, collection: "dailyWakeRecords_v1",
            content: ObservationProvenance.wakeIdentity(wake)) else { return outcomeAfterAttempt() }
        guard !draft.invalidated,
              defaults.data(forKey: ObservationCompletionPending.key) == nil,
              defaults.data(forKey: StandaloneWakePending.key) == nil else { return .stale }
        var pending = StandaloneWakePending(operationID: draft.intent.operationID, wake: wake,
            originalContent: current.map(ObservationProvenance.wakeIdentity), originalRevision: current?.persistedRevision,
            calendar: scope, attested: true, creation: creation, selectedInput: time)
        pending.historical = true
        guard wakePersistence.storage.standaloneJournal(pending) else { return outcomeAfterAttempt() }
        return outcomeAfterAttempt(completeStandalone(pending))
    }

    fileprivate func resolveHistoricalRecovery() -> HistoricalWakeRecoveryState? {
        let defaults = wakePersistence.defaults
        guard let pending = StandaloneWakePending.load(defaults), pending.historical == true else {
            if defaults.data(forKey: StandaloneWakePending.key) != nil,
               StandaloneWakePending.load(defaults) == nil,
               !wakePersistence.storage.pruneRecoveryArchives() { return .failed }
            return nil
        }
        guard defaults.data(forKey: ObservationCompletionPending.key) == nil else { return .pending }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || wakePersistence.load() != nil,
              defaults.data(forKey: ObservationProvenance.key) == nil || ObservationProvenance.load(defaults) != nil
        else { return .failed }
        if pending.canResume(defaults: defaults, now: now) {
            _ = completeStandalone(pending)
            guard let remaining = StandaloneWakePending.load(defaults) else { return nil }
            return remaining.operationID == pending.operationID ? .failed : .pending
        }
        // A wall-clock rollback alone is not permission to discard an observation.
        if let nextDay = pending.calendar.date(byAdding: .day, value: 1, to: pending.wake.day),
           nextDay > now, pending.canResume(defaults: defaults, now: nextDay) { return .pending }
        return wakePersistence.storage.retireHistoricalWake(pending) ? nil : .failed
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
        if let recovery = resolveHistoricalRecovery() {
            var blocked = result(time: nil)
            blocked.historicalRecovery = recovery
            return blocked
        }
        let pending = ObservationCompletionPending.load(defaults)
        let standalone = StandaloneWakePending.load(defaults)
        if standalone?.historical == true {
            var blocked = result(time: nil)
            blocked.historicalRecovery = .pending
            return blocked
        }
        if let standalone, (standalone.wake.wakeTime == selectedWakeTime || standalone.selectedInput == selectedWakeTime),
           standalone.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(standalone.operationID, by: capture?.creationIntent)
            return completeStandalone(standalone)
        }
        if let pending, pending.nightCompletionInput == nil, pending.wakeAttested,
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
        if let pending, pending.nightCompletionInput == nil, pending.wakeAttested, pending.wake.wakeTime == time,
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
        guard transaction.canResume(defaults: defaults, now: now),
              wakeMatches(wake, transaction.expected), let receipt = transaction.expected,
              var metadata = ObservationProvenance.load(defaults),
              StandaloneWakePending.load(defaults)?.operationID == transaction.operationID,
              StandaloneWakePending.load(defaults)?.isCancelled == false else { return result(time: time, wakeOK: true) }
        if let creation = transaction.creation, !wakePersistence.storage.finishCreation(creation) { return result(time: time, wakeOK: true) }
        var publishedEntry = transaction.attested ? verified(receipt, intent: "parent-entered-morning-wake-v1") : receipt
        publishedEntry.completedOperationID = transaction.operationID
        publishedEntry.completedInput = inputIdentity(transaction.selectedInput ?? time)
        if transaction.historical == true {
            let storage = wakePersistence.storage
            guard defaults.data(forKey: ObservationCompletionPending.key) == nil,
                  let journal = defaults.data(forKey: StandaloneWakePending.key),
                  transaction.canResume(defaults: defaults, now: now),
                  ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults),
                  wakeMatches(wake, receipt),
                  var latest = ObservationProvenance.load(defaults)
            else { return result(time: time, wakeOK: true) }
            publishedEntry.historicalWakeCalendar = transaction.calendar
            latest.wakes[wake.id.uuidString] = publishedEntry
            guard storage.publishHistoricalWake(latest),
                  defaults.data(forKey: StandaloneWakePending.key) == journal,
                  defaults.data(forKey: ObservationCompletionPending.key) == nil,
                  transaction.canResume(defaults: defaults, now: now),
                  ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults),
                  wakeMatches(wake, receipt),
                  ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
            else { return result(time: time, wakeOK: true) }
            defaults.removeObject(forKey: StandaloneWakePending.key)
            guard defaults.data(forKey: StandaloneWakePending.key) == nil else { return result(time: time, wakeOK: true) }
            ObservationStorage.post(.observationProvenanceDidChange)
            let stillCurrent = transaction.canResume(defaults: defaults, now: now) &&
                wakeMatches(wake, receipt) &&
                ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
            return result(time: time, wakeOK: true, evidenceOK: stillCurrent)
        }
        metadata.wakes[wake.id.uuidString] = publishedEntry
        let published = wakePersistence.storage.metadata(metadata) && wakeMatches(wake, receipt) &&
            transaction.canResume(defaults: defaults, now: now) &&
            ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults) &&
            ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
        if published, StandaloneWakePending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: StandaloneWakePending.key)
        }
        return result(time: time, wakeOK: true, evidenceOK: published)
    }

    fileprivate func complete(_ original: ObservationCompletionPending) -> SleepWakeTimeWorkflowResult {
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
        guard transaction.canResume(defaults: defaults, now: now),
              wakeMatches(wake, transaction.expectedWake), nightMatches(closed, transaction.expectedNight),
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
                nightRevision: nightEntry.revision, wakeRevision: wakeEntry.revision,
                recordedCalendar: transaction.recordedCalendar)
        }
        if let input = transaction.nightCompletionInput {
            // Revision-bound acknowledgement for an exact retry; never a new attestation.
            metadata.wakes[wake.id.uuidString]?.completedOperationID = transaction.operationID
            metadata.wakes[wake.id.uuidString]?.completedInput = input
            metadata.sleeps[closed.id.uuidString]?.completedOperationID = transaction.operationID
            metadata.sleeps[closed.id.uuidString]?.completedInput = input
        }
        let saved = wakePersistence.storage.metadata(metadata)
        let finalMetadata = ObservationProvenance.load(defaults)
        let link = finalMetadata?.links[wake.id.uuidString]
        let linkMatches = !transaction.wakeAttested ||
            (link?.nightID == closed.id && link?.wakeID == wake.id &&
             link?.nightRevision == nightEntry.revision && link?.wakeRevision == wakeEntry.revision)
        let completionReceiptsMatch = transaction.nightCompletionInput.map { input in
            finalMetadata?.sleeps[closed.id.uuidString]?.completedOperationID == transaction.operationID &&
            finalMetadata?.sleeps[closed.id.uuidString]?.completedInput == input &&
            finalMetadata?.wakes[wake.id.uuidString]?.completedOperationID == transaction.operationID &&
            finalMetadata?.wakes[wake.id.uuidString]?.completedInput == input
        } ?? true
        let published = saved && completionReceiptsMatch && transaction.canResume(defaults: defaults, now: now) &&
            ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults) &&
            wakeMatches(wake, wakeEntry) && nightMatches(closed, nightEntry) && linkMatches
        if published, ObservationCompletionPending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: pendingKey)
        }
        return result(time: time, closed: closed, wakeOK: true, sleepOK: true, evidenceOK: published)
    }
}

struct NightSleepCompletionResult {
    enum State { case completed, invalidSubmission, staleNight, wakeConflict, ambiguousWakes, recoveryPending, recoveryFailure, incomplete }
    let state: State
    let sleepPersisted: Bool
    let wakePersisted: Bool
    /// Journal publication/acknowledgement, not a claim of verified learning evidence.
    let evidencePublished: Bool
    var succeeded: Bool { state == .completed }
    var message: String {
        switch state {
        case .wakeConflict: return "A different morning wake is already recorded for this day. Your existing wake was kept. Review it before finishing this night."
        case .ambiguousWakes: return "More than one morning wake exists for this day. Review those records before finishing this night."
        case .staleNight: return "This night changed or was deleted. Reopen it before saving."
        case .invalidSubmission: return "Keep the original night start and choose a valid ending to finish this night."
        case .recoveryFailure: return "Recovery could not be safely saved. Your observations have been kept. Please retry Save before starting another night completion."
        case .recoveryPending: return "A sleep or wake entry still needs recovery. Retry its original submission or cancel it before starting another."
        case .incomplete: return "Night completion is incomplete. Saved observations have been kept. Retry Save to finish synchronization, or Cancel to keep them without completing recovery."
        case .completed: return ""
        }
    }
}

/// Home End Sleep only. The recording submission supplies its expected content,
/// revision and transient capabilities; ordinary edits never enter this command.
/// Uses B1's journal and receipt publisher, not the wake editor's date normalization.
struct NightSleepCompletion {
    let submitted: SleepRecord
    let now: Date
    let calendar: Calendar
    let sleepPersistence: SleepRecordPersistence
    let wakePersistence: DailyWakeRecordPersistence

    func execute() -> NightSleepCompletionResult {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = sleepPersistence.defaults
        var expectedWake: DailyWakeRecord?
        func result(_ state: NightSleepCompletionResult.State, publication: Bool = false) -> NightSleepCompletionResult {
            let nightOK = sleepPersistence.load()?.contains {
                ObservationProvenance.sleepIdentity($0) == ObservationProvenance.sleepIdentity(submitted)
            } == true
            let wakeOK = expectedWake.map { expected in
                wakePersistence.load()?.contains {
                    ObservationProvenance.wakeIdentity($0) == ObservationProvenance.wakeIdentity(expected)
                } == true
            } ?? false
            return .init(state: state, sleepPersisted: nightOK, wakePersisted: wakeOK, evidencePublished: publication)
        }
        guard defaults === wakePersistence.defaults else { return result(.invalidSubmission) }
        guard wakePersistence.storage.retireInvalidForwardCompletion(now: now) else { return result(.recoveryFailure) }
        if submitted.nightCompletionIntent?.isRetired == true { return result(.staleNight) }
        guard submitted.recordingDraft,
              submitted.kind == .nightSleep, !submitted.isOngoing,
              let end = submitted.endDate, end.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, end <= now,
              end.timeIntervalSince(submitted.date) >= 60,
              let intent = submitted.nightCompletionIntent,
              submitted.creationIntent?.isRetired != true,
              wakePersistence.storage.bind(intent),
              defaults.data(forKey: "sleepRecords") == nil || sleepPersistence.load() != nil,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || wakePersistence.load() != nil else {
            return result(.invalidSubmission)
        }
        let historicalRecovery = SleepWakeTimeWorkflow(selectedWakeTime: end, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakePersistence, sleepPersistence: sleepPersistence)
            .resolveHistoricalRecovery()
        if let historicalRecovery {
            return result(historicalRecovery == .pending ? .recoveryPending : .recoveryFailure)
        }
        let input = ObservationCompletionPending.completionInput(baseline: submitted.recordingBaseline ?? "",
            revision: submitted.recordingRevision, completed: submitted)
        let sleeps = sleepPersistence.load() ?? []
        let wakes = wakePersistence.load() ?? []
        guard let current = sleeps.first(where: { $0.id == submitted.id }) else { return result(.staleNight) }
        let metadata = ObservationProvenance.load(defaults)
        let workflow = SleepWakeTimeWorkflow(selectedWakeTime: end, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakePersistence, sleepPersistence: sleepPersistence)
        func complete(_ pending: ObservationCompletionPending) -> NightSleepCompletionResult {
            let outcome = workflow.complete(pending)
            let scope = pending.recordedCalendar ?? calendar
            let candidates = (wakePersistence.load() ?? []).filter { scope.isDate($0.day, inSameDayAs: pending.wake.day) }
            let canonicalMatches = candidates.count == 1 && candidates.first?.id == pending.wake.id
            let persisted = result(.incomplete, publication: outcome.evidencePublicationSucceeded && canonicalMatches)
            if persisted.sleepPersisted && persisted.wakePersisted && persisted.evidencePublished {
                wakePersistence.storage.rememberNightCompletion(pending, submissionInput: input, by: intent)
            }
            return .init(state: persisted.sleepPersisted && persisted.wakePersisted && persisted.evidencePublished ? .completed : .incomplete,
                         sleepPersisted: persisted.sleepPersisted, wakePersisted: persisted.wakePersisted,
                         evidencePublished: persisted.evidencePublished)
        }
        if let pending = ObservationCompletionPending.load(defaults), pending.nightCompletionInput != nil,
           pending.nightCompletionInput == input ||
            (pending.originalNightContent == submitted.recordingBaseline &&
             submitted.recordingRevision == current.persistedRevision &&
             pending.originalNightContent == ObservationProvenance.sleepIdentity(current) &&
             ObservationProvenance.sleepIdentity(pending.night) == ObservationProvenance.sleepIdentity(submitted)) {
            guard pending.canResume(defaults: defaults, now: now) else { return result(.staleNight) }
            wakePersistence.storage.adopt(pending.operationID, by: intent)
            expectedWake = pending.wake
            return complete(pending)
        }
        let adopted = intent.nightCompletionAcknowledgement
        let acknowledgedOperation = adopted?.operationID ?? intent.operationID
        let acknowledgedInput = adopted?.persistedInput ?? input
        let acknowledgementMatches = adopted.map { $0.submissionInput == input && $0.nightID == submitted.id } ?? true
        if acknowledgementMatches,
           let wake = wakes.first(where: { metadata?.wakes[$0.id.uuidString]?.completedOperationID == acknowledgedOperation }),
           wake.wakeTime == end,
           let nightEntry = metadata?.sleeps[current.id.uuidString],
           let wakeEntry = metadata?.wakes[wake.id.uuidString],
           nightEntry.completedOperationID == acknowledgedOperation, nightEntry.completedInput == acknowledgedInput,
           wakeEntry.completedOperationID == acknowledgedOperation, wakeEntry.completedInput == acknowledgedInput,
           adopted.map({ $0.wakeID == wake.id && $0.nightRevision == nightEntry.revision && $0.wakeRevision == wakeEntry.revision }) ?? true,
           nightEntry.revision == current.persistedRevision, wakeEntry.revision == wake.persistedRevision,
           nightEntry.content == ObservationProvenance.sleepIdentity(submitted),
           nightEntry.content == ObservationProvenance.sleepIdentity(current),
           wakeEntry.content == ObservationProvenance.wakeIdentity(wake) {
            let scope = adopted?.calendar ?? calendar
            guard wakes.filter({ scope.isDate($0.day, inSameDayAs: wake.day) }).count == 1 else {
                return result(.ambiguousWakes)
            }
            expectedWake = wake
            return result(.completed, publication: true)
        }
        let day = calendar.startOfDay(for: end)
        let candidates = wakes.filter { calendar.isDate($0.day, inSameDayAs: day) }
        guard candidates.count <= 1 else { return result(.ambiguousWakes) }
        if let wake = candidates.first, wake.wakeTime != end { return result(.wakeConflict) }
        // Preserve another operation, including malformed journals, rather than replacing
        // its recovery context with a new snapshot.
        guard defaults.data(forKey: ObservationCompletionPending.key) == nil,
              defaults.data(forKey: StandaloneWakePending.key) == nil else { return result(.recoveryPending) }
        // A retired creation serial cannot be recycled into a fresh completion,
        // even when the first operation left a matching ordinary wake behind.
        if let reservation = intent.reservation,
           !ObservationCreationLedger.contains(reservation, defaults: defaults) { return result(.staleNight) }
        guard current.kind == .nightSleep, current.isOngoing,
              ObservationProvenance.sleepIdentity(current) == submitted.recordingBaseline,
              current.persistedRevision == submitted.recordingRevision else { return result(.staleNight) }
        var pending = ObservationCompletionPending(version: 3, originalNight: current,
            wake: candidates.first ?? DailyWakeRecord(id: intent.recordID, day: day, wakeTime: end),
            originalWakeContent: candidates.first.map(ObservationProvenance.wakeIdentity),
            originalWakeRevision: candidates.first?.persistedRevision)
        guard ObservationProvenance.sleepIdentity(pending.night) == ObservationProvenance.sleepIdentity(submitted) else {
            return result(.invalidSubmission)
        }
        pending.operationID = intent.operationID
        pending.recordedCalendar = calendar
        pending.originalNightRevision = current.persistedRevision
        pending.onset = metadata?.sleeps[current.id.uuidString]
        pending.selectedInput = end
        pending.nightCompletionInput = input
        if let capture = submitted.observationCapture {
            guard capture.content == ObservationProvenance.sleepIdentity(submitted),
                  capture.previousContent == submitted.recordingBaseline,
                  capture.creationOperationID == submitted.creationIntent?.operationID else { return result(.invalidSubmission) }
            // A matching independent wake is reused without upgrading its trust or
            // inferring a semantic association from timestamp equality.
            pending.wakeAttested = candidates.isEmpty
        }
        if candidates.isEmpty {
            guard let reservation = wakePersistence.storage.reserveCreation(intent, collection: "dailyWakeRecords_v1",
                content: ObservationProvenance.wakeIdentity(pending.wake)) else { return result(.incomplete) }
            pending.creation = reservation
        }
        guard pending.isValid(now: now, calendar: calendar), wakePersistence.storage.journal(pending) else {
            return result(.incomplete)
        }
        expectedWake = pending.wake
        return complete(pending)
    }
}
