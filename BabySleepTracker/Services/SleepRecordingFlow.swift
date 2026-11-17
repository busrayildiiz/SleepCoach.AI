import Foundation

extension Notification.Name {
    /// Ephemeral presentation confirmation; never stored or used by learning/accounting.
    static let sleepStillSleepingConfirmed = Notification.Name("sleepStillSleepingConfirmed")
}

/// Transient form state; the persisted SleepRecord format is unchanged.
struct SleepRecordingDraft {
    var start: Date
    var end: Date
    var isOngoing: Bool
    private let observationID: UUID
    private let creationIntent: ObservationCreationIntent?
    private let initialStart: Date
    private var initialEnd: Date
    private var nightCompletionIntent: ObservationCreationIntent? = nil

    init(defaultDate: Date, editing: SleepRecord? = nil, now: Date = Date()) {
        observationID = editing?.id ?? UUID()
        creationIntent = ObservationCreationIntent(recordID: observationID)
        start = editing?.date ?? min(defaultDate, now.addingTimeInterval(-3600))
        end = editing.map { $0.observedEnd ?? $0.date } ?? min(start.addingTimeInterval(3600), now)
        initialStart = start
        initialEnd = end
        isOngoing = editing?.isOngoing ?? false
    }

    /// Presentation draft only; Cancel never changes the stored ongoing session.
    mutating func prepareForEnding(at now: Date) {
        guard isOngoing else { return }
        isOngoing = false
        end = now
        initialEnd = end
        if nightCompletionIntent == nil { nightCompletionIntent = ObservationCreationIntent(recordID: UUID()) }
    }
    var requiresExplicitCancellation: Bool {
        creationIntent?.requiresExplicitCancellation == true || nightCompletionIntent?.requiresExplicitCancellation == true
    }
    @discardableResult
    func abandon() -> Bool {
        let recording = creationIntent?.abandon() ?? true
        let completion = nightCompletionIntent?.abandon() ?? true
        return recording && completion
    }

    func validationMessage(now: Date) -> String? {
        if start > now { return "Start must not be in the future." }
        if !isOngoing && end.timeIntervalSince(start) < 60 {
            return "End must be at least one minute after start. Check both dates for overnight sleep."
        }
        if !isOngoing && end > now { return "End must not be in the future." }
        return nil
    }

    func record(kind: SleepKind, editing: SleepRecord? = nil, now: Date) -> SleepRecord? {
        guard kind != .break, validationMessage(now: now) == nil else { return nil }
        var record = SleepRecord(
            id: observationID, date: start,
            duration: isOngoing ? 0 : Int(end.timeIntervalSince(start) / 60),
            kind: kind, parentNapID: editing?.parentNapID, isOngoing: isOngoing,
            createdAt: editing?.createdAt ?? now, endDate: isOngoing ? nil : end
        )
        record.recordingDraft = true
        record.recordingBaseline = editing.map(ObservationProvenance.sleepIdentity)
        record.recordingRevision = editing?.persistedRevision
        record.creationIntent = creationIntent
        record.nightCompletionIntent = nightCompletionIntent
        return record
    }

    fileprivate func captureForSubmission(_ record: SleepRecord, editing: SleepRecord?) -> SleepObservationCapture? {
        // Save is an actual observation submission only when applicable boundaries were
        // deliberately entered. Constructors and automatic End Sleep prefills never attest.
        if (start != initialStart && (isOngoing || end != initialEnd)) ||
            (editing?.isOngoing == true && start == initialStart && end != initialEnd) {
            return SleepObservationCapture(record: record, previous: editing, confirmsStart: start != initialStart)
        }
        return nil
    }
}

struct AwakeBreakDraft {
    let parent: SleepRecord
    let editing: SleepRecord?
    private let observationID: UUID
    private let creationIntent: ObservationCreationIntent?
    private let initialStart: Date
    private let initialEnd: Date
    var start: Date
    var end: Date
    var requiresExplicitCancellation: Bool { creationIntent?.requiresExplicitCancellation == true }
    @discardableResult
    func abandon() -> Bool { creationIntent?.abandon() ?? true }

    init(parent: SleepRecord, editing: SleepRecord? = nil, now: Date = Date()) {
        self.parent = parent
        self.editing = editing
        observationID = editing?.id ?? UUID()
        creationIntent = ObservationCreationIntent(recordID: observationID)
        start = editing?.date ?? parent.date
        end = editing.map { $0.observedEnd ?? $0.date }
            ?? min(parent.date.addingTimeInterval(300), parent.observedEnd ?? now, now)
        initialStart = start
        initialEnd = end
    }

    func validationMessage(existing: [SleepRecord], now: Date) -> String? {
        guard parent.kind != .break, parent.isOngoing || parent.observedEnd != nil else {
            return "Choose a valid sleep session first."
        }
        guard start >= parent.date, end <= (parent.observedEnd ?? now), end <= now else {
            return "The awake break must stay within this sleep session and not extend into the future."
        }
        guard end.timeIntervalSince(start) >= 60 else {
            return "End must be at least one minute after start."
        }
        let overlaps = existing.contains { record in
            guard record.id != editing?.id, record.kind == .break, record.parentNapID == parent.id,
                  let existingEnd = record.observedEnd else { return false }
            return start < existingEnd && record.date < end
        }
        return overlaps ? "This interval overlaps an existing awake break. Review its start and end." : nil
    }

    func record(existing: [SleepRecord], now: Date) -> SleepRecord? {
        guard validationMessage(existing: existing, now: now) == nil else { return nil }
        var record = SleepRecord(id: observationID, date: start,
                           duration: Int(end.timeIntervalSince(start) / 60), kind: .break,
                           parentNapID: parent.id, createdAt: editing?.createdAt ?? now, endDate: end)
        record.recordingDraft = true
        record.recordingBaseline = editing.map(ObservationProvenance.sleepIdentity)
        record.recordingRevision = editing?.persistedRevision
        record.creationIntent = creationIntent
        record.parentBaseline = ObservationProvenance.sleepIdentity(parent)
        record.parentRevision = parent.persistedRevision
        return record
    }

    fileprivate func captureForSubmission(_ record: SleepRecord) -> SleepObservationCapture? {
        guard start != initialStart, end != initialEnd else { return nil }
        return SleepObservationCapture(record: record, previous: editing, confirmsStart: true,
                                       intent: "parent-entered-awake-break-v1")
    }

    func netMinutes(existing: [SleepRecord], now: Date) -> Int {
        let candidate = record(existing: existing, now: now).map { [$0] } ?? []
        return parent.totalMinutes(breaks: existing.filter { $0.id != editing?.id } + candidate, at: now)
    }
}

/// A sheet owns exactly one destination and its required parent payload.
enum RecordingSheet: Identifiable {
    case sleep(editing: SleepRecord?, date: Date)
    case awakeBreak(SleepRecord)

    var id: String {
        switch self {
        case .sleep(let record, let date): return "sleep-\(record?.id.uuidString ?? String(date.timeIntervalSince1970))"
        case .awakeBreak(let parent): return "break-\(parent.id)"
        }
    }
}

/// Latches before callbacks run, so repeated taps cannot save or dismiss twice.
struct RecordingSubmission {
    private(set) var isSubmitted = false

    /// Shared Home form dispatch. Confirming Still Sleeping remains an ordinary
    /// recording action and must not enter canonical night completion.
    static func saveHomeRecord(_ record: SleepRecord, now: Date,
                               onSave: (SleepRecord) -> Bool,
                               onNightCompletion: ((SleepRecord) -> NightSleepCompletionResult)?) -> (succeeded: Bool, message: String?) {
        if !record.isOngoing, let onNightCompletion {
            let result = onNightCompletion(record)
            return (result.succeeded, result.message)
        }
        let saved = onSave(record)
        if saved && record.isOngoing {
            NotificationCenter.default.post(name: .sleepStillSleepingConfirmed, object: record.id, userInfo: ["confirmedAt": now])
        }
        return (saved, nil)
    }

    /// Audited observation form Save action. Building a draft or a record grants no trust.
    mutating func submit(draft: SleepRecordingDraft, kind: SleepKind, editing: SleepRecord? = nil,
                         now: Date, save: (SleepRecord) -> Bool, dismiss: () -> Void) {
        guard var record = draft.record(kind: kind, editing: editing, now: now) else { return }
        record.observationCapture = draft.captureForSubmission(record, editing: editing)
        submit(record, save: save, dismiss: dismiss)
    }

    mutating func submit(draft: AwakeBreakDraft, existing: [SleepRecord], now: Date,
                         save: (SleepRecord) -> Bool, dismiss: () -> Void) {
        guard var record = draft.record(existing: existing, now: now) else { return }
        record.observationCapture = draft.captureForSubmission(record)
        submit(record, save: save, dismiss: dismiss)
    }

    mutating func submit(_ record: SleepRecord?, save: (SleepRecord) -> Bool, dismiss: () -> Void) {
        guard !isSubmitted, let record else { return }
        isSubmitted = true
        if save(record) {
            dismiss()
        } else {
            isSubmitted = false
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Uses the existing injection point; UI recording tests never contact Gemini.
final class RecordingUITestLLMAgent: SleepCoachLLMAgentProtocol {
    func generateInsight(snapshot: OrchestratedSnapshot, records: [SleepRecord],
                         trigger: LLMTrigger) async -> LLMCoachResponse? {
        nil
    }
}
#endif

/// Opaque, transient capture capability. A source enum or decoded record cannot mint it.
struct SleepObservationCapture {
    let content: String
    let previousContent: String?
    let confirmsStart: Bool
    let intent: String
    let creationOperationID: UUID?
    fileprivate init(record: SleepRecord, previous: SleepRecord?, confirmsStart: Bool,
                     intent: String = "parent-entered-sleep-boundaries-v1") {
        self.intent = intent
        creationOperationID = record.creationIntent?.operationID
        self.confirmsStart = confirmsStart
        content = ObservationProvenance.sleepIdentity(record)
        previousContent = previous.map(ObservationProvenance.sleepIdentity)
    }
}
