import Foundation

extension Notification.Name {
    /// Ephemeral presentation confirmation; never stored or used by learning/accounting.
    static let sleepStillSleepingConfirmed = Notification.Name("sleepStillSleepingConfirmed")
}

/// Transient form state; the persisted SleepRecord format is unchanged.
struct SleepRecordingDraft {
    var start: Date {
        didSet { if start != oldValue { hasConfirmedNapTimes = false } }
    }
    var end: Date {
        didSet {
            if end != oldValue {
                confirmedEnd = nil
                hasConfirmedNapTimes = false
            }
        }
    }
    var isOngoing: Bool {
        didSet {
            if isOngoing {
                confirmedEnd = nil
                hasConfirmedNapTimes = false
            }
        }
    }
    let requiresNapTimeConfirmation: Bool
    private(set) var hasConfirmedNapTimes = false
    private let observationID: UUID
    private let creationIntent: ObservationCreationIntent?
    private let initialStart: Date
    private var initialEnd: Date
    private var nightCompletionIntent: ObservationCreationIntent? = nil
    private var confirmedEnd: Date?
    private(set) var completionCalendar: Calendar?
    private(set) var requiresEndConfirmation = false
    var hasConfirmedEnd: Bool { confirmedEnd == end }
    var isReadyToSubmit: Bool {
        if requiresNapTimeConfirmation && !hasConfirmedNapTimes { return false }
        return isOngoing || !requiresEndConfirmation || hasConfirmedEnd
    }

    init(defaultDate: Date, editing: SleepRecord? = nil, now: Date = Date(),
         requiresNapTimeConfirmation: Bool = false) {
        self.requiresNapTimeConfirmation = requiresNapTimeConfirmation
        observationID = editing?.id ?? UUID()
        creationIntent = ObservationCreationIntent(recordID: observationID)
        start = editing?.date ?? min(defaultDate, now.addingTimeInterval(-3600))
        end = editing.map { $0.observedEnd ?? $0.date } ?? min(start.addingTimeInterval(3600), now)
        initialStart = start
        initialEnd = end
        isOngoing = editing?.isOngoing ?? false
    }

    /// Presentation draft only; Cancel never changes the stored ongoing session.
    mutating func prepareForEnding(at now: Date, calendar: Calendar? = nil, requireConfirmation: Bool = false) {
        guard isOngoing else { return }
        isOngoing = false
        end = now
        initialEnd = end
        completionCalendar = calendar.map(DaytimeReviewWindow.capture)
        requiresEndConfirmation = requireConfirmation
        if nightCompletionIntent == nil { nightCompletionIntent = ObservationCreationIntent(recordID: UUID()) }
    }
    mutating func confirmObservedEnd(now: Date) {
        guard nightCompletionIntent != nil, !isOngoing, validationMessage(now: now) == nil else { return }
        confirmedEnd = end
    }

    /// Acknowledges the displayed interval for saving. Timestamp provenance follows the capture rules.
    mutating func confirmObservedNapTimes(now: Date) {
        guard requiresNapTimeConfirmation, !isOngoing, validationMessage(now: now) == nil else { return }
        hasConfirmedNapTimes = true
    }

    mutating func applyEndSelection(_ selection: RecordingEndpointSelection) {
        if selection.hasChanged { confirmedEnd = nil }
        end = selection.value
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
        guard kind != .break, isReadyToSubmit, validationMessage(now: now) == nil else { return nil }
        if nightCompletionIntent != nil, let editing, (kind != editing.kind || start != editing.date) {
            // The command still validates the exact original start for all direct submissions.
            if completionCalendar != nil { return nil }
        }
        let unchangedOngoing = editing.flatMap { original in
            isOngoing && original.isOngoing && original.date == start && original.kind == kind ? original : nil
        }
        var record = SleepRecord(
            id: observationID, date: start,
            duration: isOngoing ? (unchangedOngoing?.duration ?? 0) : Int(end.timeIntervalSince(start) / 60),
            kind: kind, parentNapID: editing?.parentNapID, isOngoing: isOngoing,
            createdAt: editing?.createdAt ?? now, endDate: isOngoing ? unchangedOngoing?.endDate : end
        )
        record.recordingDraft = true
        record.recordingBaseline = editing.map(ObservationProvenance.sleepIdentity)
        record.recordingRevision = editing?.persistedRevision
        record.creationIntent = creationIntent
        record.nightCompletionIntent = nightCompletionIntent
        record.recordingCalendar = completionCalendar
        return record
    }

    fileprivate func captureForSubmission(_ record: SleepRecord, editing: SleepRecord?) -> SleepObservationCapture? {
        // Save is an actual observation submission only when applicable boundaries were
        // deliberately entered. Constructors and automatic End Sleep prefills never attest.
        if nightCompletionIntent != nil, hasConfirmedEnd, !isOngoing, start == initialStart {
            return SleepObservationCapture(record: record, previous: editing, confirmsStart: false)
        }
        if (start != initialStart && (isOngoing || end != initialEnd)) ||
            (editing?.isOngoing == true && start == initialStart && end != initialEnd) {
            return SleepObservationCapture(record: record, previous: editing, confirmsStart: start != initialStart)
        }
        return nil
    }
}

/// An end-only draft for an existing nap. Opening or dismissing it never records a wake.
struct NapCompletionDraft {
    let parent: SleepRecord
    let calendar: Calendar
    private var recording: SleepRecordingDraft
    private var submission = RecordingSubmission()
    private var invalidLocalTime = false

    var end: Date { recording.end }
    var isSubmitted: Bool { submission.isSubmitted }
    var requiresExplicitCancellation: Bool { recording.requiresExplicitCancellation }

    init(parent: SleepRecord, now: Date, calendar: Calendar) {
        self.parent = parent
        let capturedCalendar = DaytimeReviewWindow.capture(calendar)
        self.calendar = capturedCalendar
        var draft = SleepRecordingDraft(defaultDate: parent.date, editing: parent, now: now)
        draft.prepareForEnding(at: now, calendar: capturedCalendar, requireConfirmation: true)
        recording = draft
    }

    mutating func selectEnd(_ value: Date, changesDay: Bool) {
        let day = changesDay ? value : end
        let time = changesDay ? end : value
        guard let selected = RecordingEndpointSelection.combine(day: day, time: time,
                preserving: end, calendar: calendar) else {
            invalidLocalTime = true
            return
        }
        var selection = RecordingEndpointSelection(end)
        selection.select(selected)
        recording.applyEndSelection(selection)
        invalidLocalTime = false
    }

    func validationMessage(records: [SleepRecord], now: Date) -> String? {
        guard parent.kind == .dayNap, parent.isOngoing,
              let current = records.first(where: { $0.id == parent.id }),
              SleepRecordVersion(parent).matches(current) else {
            return "This nap has changed or is no longer open. Close this sheet and review the current record."
        }
        if invalidLocalTime { return "Choose a valid local time for this date." }
        if let message = recording.validationMessage(now: now) { return message }
        let exceedsEnd = records.contains { record in
            record.kind == .break && record.parentNapID == parent.id &&
                record.observedEnd.map { $0 > end } == true
        }
        if exceedsEnd { return "Choose an end time after the last awake break, or edit that break first." }
        return nil
    }

    /// Save explicitly confirms only the selected end; the original start retains its provenance.
    @discardableResult
    mutating func submit(records: [SleepRecord], now: Date, save: (SleepRecord) -> Bool,
                         dismiss: () -> Void) -> Bool {
        guard !submission.isSubmitted else { return true }
        guard validationMessage(records: records, now: now) == nil else { return false }
        recording.confirmObservedEnd(now: now)
        submission.submit(draft: recording, kind: .dayNap, editing: parent, now: now,
                          save: save, dismiss: dismiss)
        return submission.isSubmitted
    }

    @discardableResult
    func abandon() -> Bool { recording.abandon() }
}

struct RecordingEndpointSelection {
    private(set) var value: Date
    private(set) var hasChanged = false

    init(_ value: Date) { self.value = value }

    mutating func select(_ newValue: Date) {
        if value != newValue { hasChanged = true }
        value = newValue
    }

    static func combine(day: Date, time: Date, preserving existing: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        let zone = calendar.timeZone
        let selectedOffset = calendar.isDate(time, inSameDayAs: day) ? zone.secondsFromGMT(for: time) : nil
        if calendar.isDate(day, inSameDayAs: existing),
           components == calendar.dateComponents([.hour, .minute], from: existing),
           selectedOffset.map({ $0 == zone.secondsFromGMT(for: existing) }) ?? true {
            return existing
        }

        // Actual picker edits have minute precision. Preserve the selected offset in a fold
        // when the picker supplies it, and reject nonexistent local times in a gap.
        let scope = calendar.startOfDay(for: day)
        func resolve(_ repeated: Calendar.RepeatedTimePolicy) -> Date? {
            guard let result = calendar.nextDate(after: scope.addingTimeInterval(-1),
                     matching: DateComponents(hour: hour, minute: minute, second: 0),
                     matchingPolicy: .strict, repeatedTimePolicy: repeated),
                  calendar.isDate(result, inSameDayAs: day) else { return nil }
            return result
        }
        guard let first = resolve(.first) else { return nil }
        if let selectedOffset, selectedOffset != zone.secondsFromGMT(for: first),
           let last = resolve(.last), zone.secondsFromGMT(for: last) == selectedOffset {
            return last
        }
        return first
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

    func netMinutes(existing: [SleepRecord], records: [SleepRecord]? = nil, now: Date, calendar: Calendar = .current) -> Int? {
        let stored = records ?? ([parent] + existing)
        let measured: [SleepRecord]
        if let candidate = record(existing: existing, now: now) {
            measured = stored.filter { $0.id != candidate.id } + [candidate]
        } else {
            measured = stored
        }
        return SleepAccounting(records: measured, now: now, calendar: calendar).completedMinutes(sleepIDs: [parent.id])
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

    /// An unchanged ongoing observation can be reconfirmed without a persistence transaction.
    static func confirmStillSleeping(_ expected: SleepRecordVersion, now: Date, persistence: SleepRecordPersistence,
                                     instant: ContinuousClock.Instant = .now) -> Bool {
        guard let current = persistence.load()?.first(where: { $0.id == expected.id }),
              current.isOngoing, current.date <= now, expected.matches(current) else { return false }
        let confirmation = StillSleepingConfirmation(record: current, date: now, instant: instant)
        NotificationCenter.default.post(name: .sleepStillSleepingConfirmed, object: current.id,
                                        userInfo: ["confirmedAt": now, "confirmation": confirmation])
        return true
    }

    /// Dispatch a deliberate new or edited observation to its recording command.
    static func saveHomeRecord(_ record: SleepRecord, now: Date,
                               onSave: (SleepRecord) -> Bool,
                               onNightCompletion: ((SleepRecord) -> NightSleepCompletionResult)?,
                               confirmation: ((SleepRecord) -> StillSleepingConfirmation?)? = nil) -> (succeeded: Bool, message: String?) {
        if !record.isOngoing, let onNightCompletion {
            let result = onNightCompletion(record)
            return (result.succeeded, result.message)
        }
        let saved = onSave(record)
        if saved && record.isOngoing {
            var details: [AnyHashable: Any] = ["confirmedAt": now]
            if let confirmed = confirmation?(record) { details["confirmation"] = confirmed }
            NotificationCenter.default.post(name: .sleepStillSleepingConfirmed, object: record.id, userInfo: details)
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
