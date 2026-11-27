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
    var homeError: String? = nil
}

enum HomeWakeOperation {
    case independent
    case associated(AssociatedHomeWake)
}

struct AssociatedHomeWake {
    let night: SleepRecordVersion
    let nightStart: Date
    let morning: Date
    let calendar: Calendar

    init(night: SleepRecord, morning: Date, calendar: Calendar) {
        self.night = SleepRecordVersion(night)
        nightStart = night.date
        self.calendar = DaytimeReviewWindow.capture(calendar)
        self.morning = self.calendar.startOfDay(for: morning)
    }
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
    var needsTimeConfirmation: Bool { existing == nil && selected == initial }
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

/// A read-only snapshot of one existing wake and its actual semantic relationship.
struct MorningWakeCorrectionContext {
    let wake: DailyWakeRecord
    let linkedNight: SleepRecord?
    let calendar: Calendar
    var day: Date { wake.day }
    var requiresPairedConfirmation: Bool { linkedNight != nil }
    fileprivate let defaults: any PrivateDataStore
    fileprivate let generation: UUID?
    fileprivate let openedDay: Date
    fileprivate let wakeEntry: ObservationProvenance.Entry?
    fileprivate let nightEntry: ObservationProvenance.Entry?
    fileprivate let link: ObservationProvenance.NightWakeLink?

    static func load(wakeID: UUID, at now: Date, calendar: Calendar = .current,
                     wakePersistence: DailyWakeRecordPersistence = .init(),
                     sleepPersistence: SleepRecordPersistence = .init()) -> Self? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = wakePersistence.defaults
        let generation = defaults.generationToken
        let scope = DaytimeReviewWindow.capture(calendar)
        guard defaults === sleepPersistence.defaults, now.timeIntervalSinceReferenceDate.isFinite,
              defaults.object(forKey: ObservationCompletionPending.key) == nil,
              defaults.object(forKey: StandaloneWakePending.key) == nil,
              let state = MorningWakeCorrectionBinding.read(defaults),
              let wake = state.wakes.first(where: { $0.id == wakeID }),
              wake.isObserved(on: wake.day, at: now, calendar: scope),
              wake.day == scope.startOfDay(for: wake.wakeTime),
              state.wakes.filter({ scope.isDate($0.day, inSameDayAs: wake.day) }).count == 1,
              !state.sleeps.contains(where: { $0.id == wakeID }) else { return nil }
        let wakeEntry = state.metadata.wakes[wakeID.uuidString]
        guard wakeEntry.map({ $0.content == ObservationProvenance.wakeIdentity(wake) &&
            $0.revision == wake.persistedRevision }) ?? (wake.persistedRevision == nil) else { return nil }
        let link = state.metadata.links[wakeID.uuidString]
        guard MorningWakeCorrectionBinding.linkShapeIsValid(state.metadata, wakeID: wakeID) else { return nil }
        var night: SleepRecord?
        var onset: ObservationProvenance.Entry?
        if let link {
            guard link.wakeID == wakeID, link.wakeRevision == wakeEntry?.revision,
                  link.recordedCalendar.map({ $0 == scope }) ?? true,
                  let actual = state.sleeps.first(where: { $0.id == link.nightID }),
                  actual.kind == .nightSleep, !actual.isOngoing, actual.completedEnd(at: now) == wake.wakeTime,
                  let entry = state.metadata.sleeps[actual.id.uuidString],
                  entry.content == ObservationProvenance.sleepIdentity(actual),
                  entry.revision == actual.persistedRevision, entry.revision == link.nightRevision,
                  state.metadata.links.values.filter({ $0.nightID == actual.id }).count == 1 else { return nil }
            night = actual
            onset = entry
        }
        guard defaults.isAvailable, defaults.generationToken == generation else { return nil }
        return .init(wake: wake, linkedNight: night, calendar: scope, defaults: defaults, generation: generation,
                     openedDay: scope.startOfDay(for: now),
                     wakeEntry: wakeEntry, nightEntry: onset, link: link)
    }

    fileprivate func matches(_ other: Self) -> Bool {
        defaults === other.defaults && generation == other.generation && calendar == other.calendar &&
            ObservationProvenance.wakeIdentity(wake) == ObservationProvenance.wakeIdentity(other.wake) &&
            wakeEntry == other.wakeEntry && nightEntry == other.nightEntry && link == other.link &&
            linkedNight.map(ObservationProvenance.sleepIdentity) == other.linkedNight.map(ObservationProvenance.sleepIdentity)
    }
}

struct MorningWakeCorrectionConfirmation {
    fileprivate let operation: UUID
    fileprivate let time: Date
}

enum MorningWakeCorrectionOutcome: Equatable {
    case saved, unchanged, requiresConfirmation, stale, invalidTime, unavailable, recoveryPending, failed
    var succeeded: Bool { self == .saved || self == .unchanged }
    var message: String {
        switch self {
        case .saved: return "Morning wake updated."
        case .unchanged: return "Morning wake is unchanged."
        case .requiresConfirmation: return "Confirm updating both the wake time and the linked night's end."
        case .stale: return "This wake or its link changed. Reopen it to review the latest records. Any saved changes are kept."
        case .invalidTime: return "Choose a valid wake time on this date that keeps the sleep and awake breaks consistent."
        case .unavailable: return "Saved observations could not be opened. Try again when they are available."
        case .recoveryPending: return "A sleep or wake update still needs recovery. Any saved changes are kept."
        case .failed: return "The correction could not be completed. Retry this update; any saved changes are kept."
        }
    }
}

/// The editor retains this exact capability through notifications and failed submissions.
final class MorningWakeCorrectionDraft {
    let context: MorningWakeCorrectionContext
    private let wakePersistence: DailyWakeRecordPersistence
    private let sleepPersistence: SleepRecordPersistence
    private let intent: ObservationCreationIntent
    private(set) var pendingTime: Date?
    var requiresExplicitCancellation: Bool { intent.requiresExplicitCancellation }

    init(context: MorningWakeCorrectionContext, wakePersistence: DailyWakeRecordPersistence = .init(),
         sleepPersistence: SleepRecordPersistence = .init()) {
        self.context = context
        self.wakePersistence = wakePersistence
        self.sleepPersistence = sleepPersistence
        intent = ObservationCreationIntent(recordID: context.wake.id)
    }

    func confirmUpdateBoth(at time: Date) -> MorningWakeCorrectionConfirmation? {
        guard context.requiresPairedConfirmation, time.timeIntervalSinceReferenceDate.isFinite,
              !intent.isRetired, pendingTime == nil || pendingTime == time else { return nil }
        return .init(operation: intent.operationID, time: time)
    }

    @discardableResult
    func abandon() -> Bool { intent.abandon() }

    func submit(_ time: Date, confirmation: MorningWakeCorrectionConfirmation? = nil, at now: Date,
                calendar: Calendar = .current) -> MorningWakeCorrectionOutcome {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = wakePersistence.defaults
        guard defaults === sleepPersistence.defaults, defaults === context.defaults,
              defaults.isAvailable, defaults.generationToken == context.generation else { return .unavailable }
        guard !intent.isRetired, DaytimeReviewWindow.capture(calendar) == context.calendar,
              pendingTime == nil || pendingTime == time else { return .stale }
        guard now.timeIntervalSinceReferenceDate.isFinite, time.timeIntervalSinceReferenceDate.isFinite,
              time <= now, context.calendar.isDate(time, inSameDayAs: context.day) else { return .invalidTime }
        guard pendingTime != nil || context.openedDay == context.calendar.startOfDay(for: now) else { return .stale }
        if context.requiresPairedConfirmation,
           (confirmation?.operation != intent.operationID || confirmation?.time != time) {
            return .requiresConfirmation
        }
        let workflow = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: context.calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakePersistence, sleepPersistence: sleepPersistence)
        if let pending = ObservationCompletionPending.load(defaults), pending.operationID == intent.operationID {
            guard pending.morningWakeCorrection != nil, pendingTime == time,
                  pending.canResume(defaults: defaults, now: now) else { return .stale }
            return workflow.complete(pending).evidencePublicationSucceeded ? .saved : .failed
        }
        if let pending = StandaloneWakePending.load(defaults), pending.operationID == intent.operationID {
            guard pending.morningWakeCorrection != nil, pendingTime == time,
                  pending.canResume(defaults: defaults, now: now) else { return .stale }
            return workflow.completeStandalone(pending).evidencePublicationSucceeded ? .saved : .failed
        }
        guard defaults.object(forKey: ObservationCompletionPending.key) == nil,
              defaults.object(forKey: StandaloneWakePending.key) == nil else { return .recoveryPending }
        let normalized = time == context.wake.wakeTime ? time :
            context.calendar.dateInterval(of: .minute, for: time)?.start
        guard let selected = normalized, selected <= now,
              context.calendar.isDate(selected, inSameDayAs: context.day) else { return .invalidTime }
        let wake = DailyWakeRecord(id: context.wake.id, day: context.day, wakeTime: selected)
        let binding = MorningWakeCorrectionBinding(originalWake: context.wake,
            originalWakeEntry: context.wakeEntry, originalLink: context.link)
        let input = binding.input(wake: wake, originalNight: context.linkedNight,
                                  originalNightRevision: context.linkedNight?.persistedRevision, calendar: context.calendar)
        if pendingTime != nil, let state = MorningWakeCorrectionBinding.read(defaults),
           let actualWake = state.wakes.first(where: { $0.id == wake.id }),
           let entry = state.metadata.wakes[wake.id.uuidString],
           entry.completedOperationID == intent.operationID, entry.completedInput == input,
           entry.content == ObservationProvenance.wakeIdentity(wake),
           entry.content == ObservationProvenance.wakeIdentity(actualWake), entry.revision == actualWake.persistedRevision {
            if let original = context.linkedNight {
                guard let night = state.sleeps.first(where: { $0.id == original.id }),
                      let receipt = state.metadata.sleeps[original.id.uuidString],
                      receipt.completedOperationID == intent.operationID, receipt.completedInput == input,
                      receipt.content == ObservationProvenance.sleepIdentity(night), receipt.revision == night.persistedRevision,
                      night.date == original.date, night.createdAt == original.createdAt, night.completedEnd(at: now) == selected,
                      state.metadata.links[wake.id.uuidString] == ObservationProvenance.NightWakeLink(nightID: night.id, wakeID: wake.id,
                        nightRevision: receipt.revision, wakeRevision: entry.revision, recordedCalendar: context.calendar),
                      MorningWakeCorrectionBinding.linkShapeIsValid(state.metadata, wakeID: wake.id, nightID: night.id),
                      state.wakes.filter({ context.calendar.isDate($0.day, inSameDayAs: wake.day) }).count == 1,
                      MorningWakeCorrectionBinding.validNight(night, in: state.sleeps, now: now, calendar: context.calendar)
                else { return .stale }
            } else if state.metadata.links[wake.id.uuidString] != nil ||
                !MorningWakeCorrectionBinding.linkShapeIsValid(state.metadata, wakeID: wake.id) { return .stale }
            return .saved
        }
        guard let current = MorningWakeCorrectionContext.load(wakeID: context.wake.id, at: now,
            calendar: calendar, wakePersistence: wakePersistence, sleepPersistence: sleepPersistence),
              context.matches(current) else { return MorningWakeCorrectionBinding.read(defaults) == nil ? .unavailable : .stale }
        if selected == context.wake.wakeTime { return .unchanged }
        let originalContent = ObservationProvenance.wakeIdentity(context.wake)
        var pair = context.linkedNight.map {
            ObservationCompletionPending(version: 3, originalNight: $0, wake: wake,
                originalWakeContent: originalContent, originalWakeRevision: context.wake.persistedRevision)
        }
        if var pending = pair {
            pending.recordedCalendar = context.calendar
            pending.originalNightRevision = context.linkedNight?.persistedRevision
            pending.onset = context.nightEntry
            pending.morningWakeCorrection = binding
            pending.wakeAttested = true
            pending.operationID = intent.operationID
            pending.selectedInput = time
            guard let records = MorningWakeCorrectionBinding.read(defaults)?.sleeps,
                  MorningWakeCorrectionBinding.validNight(pending.night, in: records, now: now, calendar: context.calendar)
            else { return .invalidTime }
            pair = pending
        }
        pendingTime = time
        guard wakePersistence.storage.bind(intent),
              let reservation = wakePersistence.storage.reserveCreation(intent, collection: "dailyWakeRecords_v1",
                content: ObservationProvenance.wakeIdentity(wake)) else { return .failed }
        // Reservation I/O may call test adapters or maintenance. Recheck the captured pair.
        guard let latest = MorningWakeCorrectionContext.load(wakeID: context.wake.id, at: now,
            calendar: calendar, wakePersistence: wakePersistence, sleepPersistence: sleepPersistence), context.matches(latest)
        else { return .stale }
        if var pending = pair {
            pending.creation = reservation
            guard pending.isValid(now: now, calendar: context.calendar), wakePersistence.storage.journal(pending) else { return .failed }
            return workflow.complete(pending).evidencePublicationSucceeded ? .saved : .failed
        }
        var pending = StandaloneWakePending(operationID: intent.operationID, wake: wake,
            originalContent: originalContent, originalRevision: context.wake.persistedRevision,
            calendar: context.calendar, attested: true, creation: reservation, selectedInput: time)
        pending.morningWakeCorrection = binding
        guard wakePersistence.storage.standaloneJournal(pending) else { return .failed }
        return workflow.completeStandalone(pending).evidencePublicationSucceeded ? .saved : .failed
    }
}

enum DayDetailWakeEvidence: Equatable {
    case missing, recorded(Date), ambiguous

    init(records: [DailyWakeRecord], day: Date, calendar: Calendar, now: Date) {
        let candidates = records.filter {
            $0.day.timeIntervalSinceReferenceDate.isFinite && calendar.isDate($0.day, inSameDayAs: day)
        }
        switch candidates.count {
        case 0: self = .missing
        case 1: self = candidates[0].isObserved(on: day, at: now, calendar: calendar) ? .recorded(candidates[0].wakeTime) : .missing
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
    fileprivate let defaults: any PrivateDataStore
    fileprivate let generation: UUID?
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
        generation = defaults.generationToken
        candidates = validDay ? (persistence.load() ?? []).filter { scope.isDate($0.day, inSameDayAs: day) } : []
        intent = ObservationCreationIntent(recordID: candidates.first?.id ?? UUID())
        Self.openDrafts.removeAll { $0.value == nil }
        invalidated = !defaults.isAvailable || defaults.generationToken != generation
        if validDay, !invalidated { Self.openDrafts.append(OpenDraft(value: self)) }
    }

    /// Called only by the parent's explicit confirmation action.
    func confirmObservedWake(at time: Date) -> HistoricalWakeConfirmation? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable, defaults.generationToken == generation, confirmation == nil, !intent.isRetired,
              time.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let capture = HistoricalWakeConfirmation(time: time)
        confirmation = capture
        return capture
    }

    static func invalidateChangedDays(defaults: any PrivateDataStore, old: [DailyWakeRecord], new: [DailyWakeRecord]) {
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
    var homeOperation: HomeWakeOperation? = nil

    private let pendingKey = ObservationCompletionPending.key

    /// Startup recovery uses the ORIGINAL persisted intent, never an unchanged prefill.
    /// Unsupported, cancelled, or revision-mismatched journals remain fail-closed.
    static func resumePending(now: Date, wakePersistence: DailyWakeRecordPersistence,
                              sleepPersistence: SleepRecordPersistence) -> SleepWakeTimeWorkflowResult? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard wakePersistence.defaults.isAvailable, sleepPersistence.defaults.isAvailable else { return nil }
        guard wakePersistence.storage.retireInvalidForwardCompletion(now: now) else { return nil }
        guard let pending = ObservationCompletionPending.load(wakePersistence.defaults),
              pending.wakeAttested || pending.nightCompletionInput != nil || pending.creation?.operationID == pending.operationID,
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
        let available = wakePersistence.defaults.isAvailable && sleepPersistence.defaults.isAvailable
        return SleepWakeTimeWorkflowResult(updatedWakeRecords: wakePersistence.load() ?? [],
            updatedSleepRecords: sleepPersistence.load() ?? [], normalizedWakeTime: time,
            closedNightRecord: closed, wakePersistenceSucceeded: available && wakeOK,
            sleepPersistenceSucceeded: available && sleepOK, evidencePublicationSucceeded: available && evidenceOK,
            historicalRecovery: available ? nil : .failed)
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

    private func associatedInputIdentity(nightID: UUID, baseline: String, revision: UUID?, date: Date) -> String {
        ObservationProvenance.digest(LearningEvidenceIdentity.pack([
            "associated-home-wake-input-v1", nightID.uuidString, baseline, revision?.uuidString ?? "",
            LearningEvidenceIdentity.date(date)
        ]))
    }

    func recoverHistoricalWake(_ draft: HistoricalWakeDraft,
                               confirmation: HistoricalWakeConfirmation? = nil) -> HistoricalWakeOutcome {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let defaults = wakePersistence.defaults
        let time = selectedWakeTime
        let scope = draft.calendar
        guard defaults.isAvailable, sleepPersistence.defaults.isAvailable else { return .recoveryFailed }
        guard defaults.generationToken == draft.generation else { return .stale }
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
            guard defaults.isAvailable else { return .recoveryFailed }
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
        guard defaults.isAvailable, sleepPersistence.defaults.isAvailable else { return .failed }
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
        guard defaults.isAvailable, sleepPersistence.defaults.isAvailable else { return result(time: nil) }
        if let intent = capture?.creationIntent, !wakePersistence.storage.bind(intent) { return result(time: nil) }
        guard defaults === sleepPersistence.defaults,
              now.timeIntervalSinceReferenceDate.isFinite, selectedWakeTime.timeIntervalSinceReferenceDate.isFinite,
              defaults.data(forKey: "sleepRecords") == nil || sleepPersistence.load() != nil,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || wakePersistence.load() != nil else { return result(time: nil) }
        let association: AssociatedHomeWake?
        if case .associated(let target) = homeOperation { association = target } else { association = nil }
        let scope = association?.calendar ?? calendar
        // A completed operation may outlive its editor or cross midnight.
        if let capture, let id = capture.creationIntent?.recordID,
           let metadata = ObservationProvenance.load(defaults),
           let actual = wakePersistence.load()?.first(where: { $0.id == id }),
           let entry = metadata.wakes[id.uuidString],
           entry.completedOperationID == capture.operationID,
           entry.content == ObservationProvenance.wakeIdentity(actual), entry.revision == actual.persistedRevision,
           actual.wakeTime <= now,
           !capture.attestsObservation || entry.source == LearningEvidenceSource.verifiedObservation.rawValue {
            if let association {
                let target = association.night
                let input = associatedInputIdentity(nightID: target.id, baseline: target.content,
                                                    revision: target.revision, date: selectedWakeTime)
                if entry.completedInput == input,
                   let completed = sleepPersistence.load()?.first(where: { $0.id == target.id }),
                   let receipt = metadata.sleeps[target.id.uuidString],
                   receipt.completedOperationID == capture.operationID, receipt.completedInput == input,
                   receipt.content == ObservationProvenance.sleepIdentity(completed),
                   receipt.revision == completed.persistedRevision, completed.observedEnd == actual.wakeTime,
                   actual.day == association.morning,
                   wakePersistence.load()?.filter({ scope.isDate($0.day, inSameDayAs: actual.day) }).count == 1 {
                    return result(time: actual.wakeTime, closed: completed, wakeOK: true, sleepOK: true, evidenceOK: true)
                }
            } else if entry.completedInput == inputIdentity(selectedWakeTime) {
                return result(time: actual.wakeTime, wakeOK: true, evidenceOK: true)
            }
        }
        if let recovery = resolveHistoricalRecovery() {
            var blocked = result(time: nil)
            blocked.historicalRecovery = recovery
            return blocked
        }
        let pending = ObservationCompletionPending.load(defaults)
        let standalone = StandaloneWakePending.load(defaults)
        if pending?.morningWakeCorrection != nil || standalone?.morningWakeCorrection != nil {
            var blocked = result(time: nil)
            blocked.homeError = "An existing wake correction needs recovery. Retry its original submission."
            return blocked
        }
        if standalone?.historical == true {
            var blocked = result(time: nil)
            blocked.historicalRecovery = .pending
            return blocked
        }
        if let homeOperation {
            // Home retries are authorized by the original editor, before any calendar normalization.
            switch homeOperation {
            case .independent:
                if let standalone, standalone.morningWakeCorrection == nil, standalone.operationID == capture?.operationID,
                   standalone.selectedInput == selectedWakeTime,
                   standalone.canResume(defaults: defaults, now: now) {
                    return completeStandalone(standalone)
                }
            case .associated(let association):
                let target = association.night
                if let pending, pending.morningWakeCorrection == nil, pending.nightCompletionInput == nil, pending.operationID == capture?.operationID,
                   pending.selectedInput == selectedWakeTime, target.id == pending.originalNight.id,
                   target.content == pending.originalNightContent, target.revision == pending.originalNightRevision,
                   pending.wake.day == association.morning, pending.recordedCalendar == association.calendar,
                   pending.canResume(defaults: defaults, now: now) {
                    return complete(pending)
                }
            }
            if defaults.data(forKey: pendingKey) != nil || defaults.data(forKey: StandaloneWakePending.key) != nil {
                var blocked = result(time: nil)
                blocked.homeError = "Another sleep or wake entry needs recovery. Retry its original submission before saving this wake."
                return blocked
            }
        } else {
            // Compatibility for existing callers of the wake workflow. Explicit Home commands
            // above never enter the timestamp-only adoption path.
            if let standalone, standalone.morningWakeCorrection == nil, (standalone.wake.wakeTime == selectedWakeTime || standalone.selectedInput == selectedWakeTime),
               standalone.canResume(defaults: defaults, now: now) {
                wakePersistence.storage.adopt(standalone.operationID, by: capture?.creationIntent)
                return completeStandalone(standalone)
            }
            if let pending, pending.morningWakeCorrection == nil, pending.nightCompletionInput == nil, pending.wakeAttested,
               (pending.wake.wakeTime == selectedWakeTime || pending.selectedInput == selectedWakeTime),
               pending.canResume(defaults: defaults, now: now) {
                wakePersistence.storage.adopt(pending.operationID, by: capture?.creationIntent)
                return complete(pending)
            }
        }
        let wakeDay = association?.morning ?? scope.startOfDay(for: now)
        let selectedMinute = scope.dateInterval(of: .minute, for: selectedWakeTime)?.start
        let normalized: Date?
        if association != nil {
            normalized = selectedMinute.flatMap {
                RecordingEndpointSelection.combine(day: wakeDay, time: $0, preserving: $0, calendar: scope)
            }
        } else {
            let parts = scope.dateComponents([.hour, .minute], from: selectedWakeTime)
            if let hour = parts.hour, let minute = parts.minute {
                normalized = scope.date(bySettingHour: hour, minute: minute, second: 0, of: wakeDay)
            } else {
                normalized = nil
            }
        }
        guard let time = normalized, time <= now, scope.isDate(time, inSameDayAs: wakeDay) else { return result(time: nil) }
        // A still-open editor may carry seconds on its original DatePicker value.
        if homeOperation == nil, let pending, pending.morningWakeCorrection == nil, pending.nightCompletionInput == nil, pending.wakeAttested,
           pending.wake.wakeTime == time,
           pending.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(pending.operationID, by: capture?.creationIntent)
            return complete(pending)
        }
        if homeOperation == nil, let standalone, standalone.morningWakeCorrection == nil, standalone.wake.wakeTime == time,
           standalone.canResume(defaults: defaults, now: now) {
            wakePersistence.storage.adopt(standalone.operationID, by: capture?.creationIntent)
            return completeStandalone(standalone)
        }
        let sleeps = sleepPersistence.load() ?? []
        let wakes = wakePersistence.load() ?? []
        let dayWakes = wakes.filter { scope.isDate($0.day, inSameDayAs: wakeDay) }
        guard dayWakes.count <= 1 else { return result(time: time) } // preserve ambiguous historical observations
        if homeOperation != nil, wakes.contains(where: { $0.wakeTime == time && $0.day != wakeDay }) {
            var blocked = result(time: time)
            blocked.homeError = "A wake at this time is already recorded under a different calendar day. Review that wake before saving."
            return blocked
        }
        let oldWake = dayWakes.first
        if let expected = capture?.nightSnapshot,
           expected != sleeps.filter({ $0.kind == .nightSleep && $0.isOngoing }).map(ObservationProvenance.sleepIdentity).sorted() {
            return result(time: time)
        }
        if let capture, capture.expectedContent != oldWake.map(ObservationProvenance.wakeIdentity) ||
            capture.expectedRevision != oldWake?.persistedRevision {
            // An exact replay grants no fresh authority to a revoked revision.
            if homeOperation != nil { return result(time: time) }
            return result(time: time, wakeOK: oldWake?.wakeTime == time,
                          evidenceOK: oldWake?.wakeTime == time &&
                            TrustedObservationAdapter(defaults: defaults).snapshot().wakes.first(where: { $0.record.id == oldWake?.id })?.source == .verifiedObservation)
        }
        let original: SleepRecord?
        switch homeOperation {
        case .independent:
            original = nil
        case .associated(let association):
            let target = association.night
            guard let current = sleeps.first(where: { $0.id == target.id }), target.matches(current),
                  current.kind == .nightSleep, current.isOngoing, current.date < time else {
                var blocked = result(time: time)
                blocked.homeError = "This night changed or the wake is before its start. Review the night and try again."
                return blocked
            }
            original = current
        case nil:
            original = sleeps.filter { $0.kind == .nightSleep && $0.isOngoing && $0.date < time }
                .max { $0.date < $1.date }
        }
        let wake = DailyWakeRecord(id: oldWake?.id ?? capture?.creationIntent?.recordID ?? UUID(), day: wakeDay, wakeTime: time)
        let attested = capture?.selected == selectedWakeTime && capture?.attestsObservation == true
        var creation: ObservationCreationReservation?
        if let intent = capture?.creationIntent {
            guard let reservation = wakePersistence.storage.reserveCreation(intent, collection: "dailyWakeRecords_v1",
                content: ObservationProvenance.wakeIdentity(wake)) else { return result(time: time) }
            creation = reservation
        }
        if let original {
            var transaction = ObservationCompletionPending(version: 3, originalNight: original, wake: wake,
                originalWakeContent: oldWake.map(ObservationProvenance.wakeIdentity), originalWakeRevision: oldWake?.persistedRevision)
            transaction.recordedCalendar = scope
            transaction.operationID = capture?.operationID ?? transaction.operationID
            transaction.wakeAttested = attested
            transaction.onset = ObservationProvenance.load(defaults)?.sleeps[original.id.uuidString]
            transaction.originalNightRevision = original.persistedRevision
            transaction.creation = creation
            transaction.selectedInput = selectedWakeTime
            if let raw = defaults.data(forKey: pendingKey) {
                guard wakePersistence.storage.preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1") else { return result(time: time) }
            }
            guard transaction.isValid(now: now, calendar: scope), wakePersistence.storage.journal(transaction) else { return result(time: time) }
            return complete(transaction)
        }
        let transaction = StandaloneWakePending(operationID: capture?.operationID ?? UUID(), wake: wake,
            originalContent: oldWake.map(ObservationProvenance.wakeIdentity), originalRevision: oldWake?.persistedRevision,
            calendar: scope, attested: attested, creation: creation, selectedInput: selectedWakeTime)
        if let raw = defaults.data(forKey: StandaloneWakePending.key) {
            guard wakePersistence.storage.preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1") else { return result(time: time) }
        }
        guard wakePersistence.storage.standaloneJournal(transaction) else { return result(time: time) }
        return completeStandalone(transaction)
    }

    fileprivate func completeStandalone(_ original: StandaloneWakePending) -> SleepWakeTimeWorkflowResult {
        let defaults = wakePersistence.defaults
        let generation = defaults.generationToken
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
        if transaction.morningWakeCorrection != nil {
            guard defaults.generationToken == generation, transaction.canResume(defaults: defaults, now: now),
                  ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults),
                  wakeMatches(wake, receipt), let current = ObservationProvenance.load(defaults)
            else { return result(time: time, wakeOK: true) }
            metadata = current
        }
        var publishedEntry = transaction.attested ? verified(receipt, intent: "parent-entered-morning-wake-v1") : receipt
        publishedEntry.completedOperationID = transaction.operationID
        publishedEntry.completedInput = transaction.morningWakeCorrection?.input(wake: wake, originalNight: nil,
            originalNightRevision: nil, calendar: transaction.calendar) ?? inputIdentity(transaction.selectedInput ?? time)
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
            guard defaults.isAvailable, defaults.data(forKey: StandaloneWakePending.key) == nil else { return result(time: time, wakeOK: true) }
            ObservationStorage.post(.observationProvenanceDidChange)
            let stillCurrent = transaction.canResume(defaults: defaults, now: now) &&
                wakeMatches(wake, receipt) &&
                ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
            return result(time: time, wakeOK: true, evidenceOK: stillCurrent)
        }
        metadata.wakes[wake.id.uuidString] = publishedEntry
        let published = wakePersistence.storage.metadata(metadata) && wakeMatches(wake, receipt) &&
            (transaction.morningWakeCorrection == nil || defaults.generationToken == generation) &&
            transaction.canResume(defaults: defaults, now: now) &&
            ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults) &&
            ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
        if published, StandaloneWakePending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: StandaloneWakePending.key)
            guard defaults.isAvailable, defaults.data(forKey: StandaloneWakePending.key) == nil else {
                return result(time: time, wakeOK: true)
            }
        }
        if transaction.morningWakeCorrection != nil {
            // Vault cleanup may notify observers synchronously, just like publication.
            // Recheck the exact final receipt before acknowledging this correction.
            let current = published && defaults.generationToken == generation &&
                transaction.canResume(defaults: defaults, now: now) &&
                wakeMatches(wake, receipt) &&
                ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString] == publishedEntry
            return result(time: time, wakeOK: true, evidenceOK: current)
        }
        return result(time: time, wakeOK: true, evidenceOK: published)
    }

    fileprivate func complete(_ original: ObservationCompletionPending) -> SleepWakeTimeWorkflowResult {
        guard wakePersistence.defaults === sleepPersistence.defaults,
              original.canResume(defaults: wakePersistence.defaults, now: now) else { return result(time: original.wake.wakeTime) }
        let defaults = wakePersistence.defaults
        let generation = defaults.generationToken
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
        if transaction.morningWakeCorrection != nil {
            guard defaults.generationToken == generation, transaction.canResume(defaults: defaults, now: now),
                  ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults),
                  wakeMatches(wake, wakeEntry), nightMatches(closed, nightEntry),
                  let current = ObservationProvenance.load(defaults)
            else { return result(time: time, closed: closed, wakeOK: true, sleepOK: true) }
            metadata = current
        }
        if transaction.wakeAttested {
            metadata.wakes[wake.id.uuidString] = verified(wakeEntry, intent: "parent-entered-morning-wake-v1")
            if let onset = transaction.onset, onset.content == transaction.originalNightContent,
               onset.revision == transaction.originalNightRevision,
               onset.source == LearningEvidenceSource.verifiedObservation.rawValue,
               (onset.intent == "parent-entered-sleep-boundaries-v1" ||
                (transaction.morningWakeCorrection != nil && onset.intent == "parent-confirmed-night-completion-v1")) {
                metadata.sleeps[closed.id.uuidString] = verified(nightEntry, intent: "parent-confirmed-night-completion-v1")
            }
            metadata.links[wake.id.uuidString] = .init(nightID: closed.id, wakeID: wake.id,
                nightRevision: nightEntry.revision, wakeRevision: wakeEntry.revision,
                recordedCalendar: transaction.recordedCalendar)
        }
        let completionInput = transaction.morningWakeCorrection?.input(wake: wake, originalNight: transaction.originalNight,
            originalNightRevision: transaction.originalNightRevision, calendar: transaction.recordedCalendar ?? calendar) ??
            transaction.nightCompletionInput ?? transaction.selectedInput.map {
            associatedInputIdentity(nightID: transaction.originalNight.id, baseline: transaction.originalNightContent,
                                    revision: transaction.originalNightRevision, date: $0)
        }
        if let input = completionInput {
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
        let completionReceiptsMatch = completionInput.map { input in
            finalMetadata?.sleeps[closed.id.uuidString]?.completedOperationID == transaction.operationID &&
            finalMetadata?.sleeps[closed.id.uuidString]?.completedInput == input &&
            finalMetadata?.wakes[wake.id.uuidString]?.completedOperationID == transaction.operationID &&
            finalMetadata?.wakes[wake.id.uuidString]?.completedInput == input
        } ?? true
        let published = saved && completionReceiptsMatch && transaction.canResume(defaults: defaults, now: now) &&
            (transaction.morningWakeCorrection == nil || defaults.generationToken == generation) &&
            ObservationStorage.completionIsActive(transaction.operationID, defaults: defaults) &&
            wakeMatches(wake, wakeEntry) && nightMatches(closed, nightEntry) && linkMatches
        if published, ObservationCompletionPending.load(defaults)?.operationID == transaction.operationID {
            defaults.removeObject(forKey: pendingKey)
            guard defaults.isAvailable, defaults.data(forKey: pendingKey) == nil else {
                return result(time: time, closed: closed, wakeOK: true, sleepOK: true)
            }
        }
        if transaction.morningWakeCorrection != nil {
            let current = ObservationProvenance.load(defaults)
            let stillPublished = published && defaults.generationToken == generation &&
                transaction.canResume(defaults: defaults, now: now) &&
                wakeMatches(wake, wakeEntry) && nightMatches(closed, nightEntry) &&
                current?.wakes[wake.id.uuidString] == metadata.wakes[wake.id.uuidString] &&
                current?.sleeps[closed.id.uuidString] == metadata.sleeps[closed.id.uuidString] &&
                current?.links[wake.id.uuidString] == metadata.links[wake.id.uuidString]
            return result(time: time, closed: closed, wakeOK: true, sleepOK: true, evidenceOK: stillPublished)
        }
        return result(time: time, closed: closed, wakeOK: true, sleepOK: true, evidenceOK: published)
    }
}

struct NightSleepCompletionResult {
    enum State { case completed, invalidSubmission, staleNight, wakeConflict, wakeCalendarConflict, ambiguousWakes, recoveryPending, recoveryFailure, incomplete }
    let state: State
    let sleepPersisted: Bool
    let wakePersisted: Bool
    /// Journal publication/acknowledgement, not a claim of verified learning evidence.
    let evidencePublished: Bool
    var succeeded: Bool { state == .completed }
    var message: String {
        switch state {
        case .wakeConflict: return "A different morning wake is already recorded for this day. Your existing wake was kept. Review it before finishing this night."
        case .wakeCalendarConflict: return "A wake at this time is already recorded under a different calendar day. Review that wake before finishing this night."
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
            guard defaults.isAvailable, wakePersistence.defaults.isAvailable else {
                return .init(state: .recoveryFailure, sleepPersisted: false, wakePersisted: false, evidencePublished: false)
            }
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
        guard defaults.isAvailable, defaults === wakePersistence.defaults else { return result(.invalidSubmission) }
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
        let candidates = wakes.filter { calendar.isDate($0.day, inSameDayAs: day) || $0.wakeTime == end }
        guard candidates.count <= 1 else { return result(.ambiguousWakes) }
        if let wake = candidates.first {
            guard wake.wakeTime == end else { return result(.wakeConflict) }
            guard wake.day == day else { return result(.wakeCalendarConflict) }
        }
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
