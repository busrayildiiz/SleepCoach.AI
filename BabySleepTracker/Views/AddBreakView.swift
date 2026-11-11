import SwiftUI

struct AddBreakView: View {
    let existingBreaks: [SleepRecord]
    let onSave: (SleepRecord) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AwakeBreakDraft
    @State private var submission = RecordingSubmission()
    @State private var saveFailed = false

    init(parent: SleepRecord, editingBreak: SleepRecord? = nil, existingBreaks: [SleepRecord] = [], onSave: @escaping (SleepRecord) -> Bool) {
        self.existingBreaks = existingBreaks
        self.onSave = onSave
        _draft = State(initialValue: AwakeBreakDraft(parent: parent, editing: editingBreak))
    }

    var body: some View {
        NavigationStack {
            RecordingScreen(
                title: draft.editing == nil ? "Add Awake Break" : "Edit Awake Break",
                saveTitle: draft.editing == nil ? "Save Awake Break" : "Save Changes",
                saveEnabled: !submission.isSubmitted && draft.validationMessage(existing: existingBreaks, now: Date()) == nil,
                onCancel: { dismiss() }, onSave: save
            ) {
                parentContext
                RecordingIntervalCard(title: "Awake interval", start: $draft.start, end: $draft.end,
                                      feedback: feedback, validation: validation)
                if let message = draft.validationMessage(existing: existingBreaks, now: Date()) {
                    RecordingValidation(message: message)
                }
                AwakeBreakFeedback(draft: draft, existing: existingBreaks)
                Text("Awake time is subtracted only from this sleep session. Its start and end stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(CoachColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .alert("Could Not Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The sleep session may have changed or this interval is already recorded. Your changes are still here; review the record and try again.")
            }
        }
    }

    private var parentContext: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(draft.parent.kind == .nightSleep ? "Night Sleep" : "Nap", systemImage: draft.parent.kind.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CoachColor.purpleDeep)
            Text(parentDates)
                .font(.caption.weight(.medium))
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var parentDates: String {
        let start = draft.parent.date.formatted(date: .abbreviated, time: .shortened)
        guard let end = draft.parent.observedEnd else { return start + " · still sleeping" }
        let sameDay = Calendar.current.isDate(draft.parent.date, inSameDayAs: end)
        return start + " → " + end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
    }

    private func preview(start: Date, end: Date) -> AwakeBreakDraft {
        var preview = draft
        preview.start = start
        preview.end = end
        return preview
    }

    private func feedback(start: Date, end: Date) -> String {
        let preview = preview(start: start, end: end)
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        guard preview.validationMessage(existing: existingBreaks, now: Date()) == nil else {
            return "Awake \(TimeFormat.minutes(minutes)) · Choose valid times to preview net sleep"
        }
        return "Awake \(TimeFormat.minutes(minutes)) · Net sleep \(TimeFormat.minutes(preview.netMinutes(existing: existingBreaks, now: Date())))"
    }

    private func validation(start: Date, end: Date) -> String? {
        preview(start: start, end: end).validationMessage(existing: existingBreaks, now: Date())
    }

    private func save() {
        submission.submit(draft.record(existing: existingBreaks, now: Date()), save: { record in
            let saved = onSave(record)
            saveFailed = !saved
            return saved
        }, dismiss: { dismiss() })
    }
}

private struct AwakeBreakFeedback: View {
    let draft: AwakeBreakDraft
    let existing: [SleepRecord]
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.recordingCompactHeight) private var compactHeight

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            summary(now: context.date)
        }
    }

    @ViewBuilder private func summary(now: Date) -> some View {
        let proposed = draft.record(existing: existing, now: now)
        let presentation = proposed.flatMap { candidate in
            RecordingIntervalPresentation(parent: draft.parent, existing: existing,
                                          proposed: candidate, editingID: draft.editing?.id, now: now)
        }
        let net = proposed == nil ? draft.parent.totalMinutes(breaks: existing, at: now)
            : draft.netMinutes(existing: existing, now: now)
        if let presentation, !dynamicType.isAccessibilitySize, !compactHeight {
            HStack(spacing: 16) {
                RecordingIntervalRing(presentation: presentation)
                details
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(proposed == nil ? "Saved net sleep" : (draft.parent.isOngoing ? "Net sleep so far" : "Net sleep after saving")): \(TimeFormat.minutes(net))")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(CoachColor.purpleDeep)
                    .accessibilityIdentifier("recording.netSleep")
                details
                if let presentation { RecordingIntervalStrip(presentation: presentation) }
            }
            .padding(.vertical, 8)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Awake break · \(TimeFormat.minutes(max(0, Int(draft.end.timeIntervalSince(draft.start) / 60))))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CoachColor.ink)
            Label {
                Text("Proposed awake").foregroundStyle(CoachColor.muted)
            } icon: {
                Image(systemName: "circle.dashed").foregroundStyle(CoachColor.sun)
            }
            .font(.caption)
            if existing.contains(where: { $0.parentNapID == draft.parent.id && $0.id != draft.editing?.id }) {
                Label {
                    Text("Existing awake").foregroundStyle(CoachColor.muted)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(CoachColor.sun.opacity(0.42))
                }
                .font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
