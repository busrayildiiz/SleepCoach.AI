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

    init(defaultDate: Date, editing: SleepRecord? = nil, now: Date = Date()) {
        start = editing?.date ?? min(defaultDate, now.addingTimeInterval(-3600))
        end = editing.map { $0.observedEnd ?? $0.date } ?? min(start.addingTimeInterval(3600), now)
        isOngoing = editing?.isOngoing ?? false
    }

    /// Presentation draft only; Cancel never changes the stored ongoing session.
    mutating func prepareForEnding(at now: Date) {
        guard isOngoing else { return }
        isOngoing = false
        end = now
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
        return SleepRecord(
            id: editing?.id ?? UUID(), date: start,
            duration: isOngoing ? 0 : Int(end.timeIntervalSince(start) / 60),
            kind: kind, parentNapID: editing?.parentNapID, isOngoing: isOngoing,
            createdAt: editing?.createdAt ?? now, endDate: isOngoing ? nil : end
        )
    }
}

struct AwakeBreakDraft {
    let parent: SleepRecord
    let editing: SleepRecord?
    var start: Date
    var end: Date

    init(parent: SleepRecord, editing: SleepRecord? = nil, now: Date = Date()) {
        self.parent = parent
        self.editing = editing
        start = editing?.date ?? parent.date
        end = editing.map { $0.observedEnd ?? $0.date }
            ?? min(parent.date.addingTimeInterval(300), parent.observedEnd ?? now, now)
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
        return SleepRecord(id: editing?.id ?? UUID(), date: start,
                           duration: Int(end.timeIntervalSince(start) / 60), kind: .break,
                           parentNapID: parent.id, createdAt: editing?.createdAt ?? now, endDate: end)
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
