import SwiftUI

struct AddBreakView: View {
    let existingBreaks: [SleepRecord]
    let onSave: (SleepRecord) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AwakeBreakDraft
    @State private var submission = RecordingSubmission()
    @State private var saveFailed = false
    @State private var showsParent = false

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
                VStack(alignment: .leading, spacing: 10) {
                    RecordingSectionLabel(title: "Awake Interval")
                    RecordingIntervalCard(start: $draft.start, end: $draft.end, style: .awake,
                                          feedback: feedback, validation: validation)
                    if let message = draft.validationMessage(existing: existingBreaks, now: Date()) {
                        RecordingValidation(message: message)
                    }
                }
                AwakeBreakFeedback(draft: draft, existing: existingBreaks)
            }
            .sheet(isPresented: $showsParent) {
                NavigationStack {
                    ScrollView {
                        RecordingCard {
                            Text(parentDates).recordingFont(14).foregroundStyle(RecordingColor.secondary)
                            Text("Saved net sleep: \(RecordingFormat.duration(draft.parent.totalMinutes(breaks: existingBreaks, at: Date())))")
                                .recordingFont(15, weight: .semibold)
                        }
                        .padding(16)
                    }
                    .background(RecordingColor.background)
                    .navigationTitle("Sleep Session")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsParent = false }
                                .accessibilityIdentifier("recording.parent.done")
                        }
                    }
                }
                .tint(RecordingColor.accent)
            }
            .alert("Could Not Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The sleep session may have changed or this interval is already recorded. Your changes are still here; review the record and try again.")
            }
        }
        .tint(RecordingColor.accent)
    }

    private var parentContext: some View {
        Button { showsParent = true } label: {
            HStack(spacing: 16) {
                Image(systemName: draft.parent.kind == .nightSleep ? "moon" : "bed.double")
                    .recordingFont(23, weight: .regular)
                    .foregroundStyle(RecordingColor.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.parent.kind == .nightSleep ? "Night Sleep" : "Nap")
                        .recordingFont(15, weight: .semibold)
                        .foregroundStyle(RecordingColor.ink)
                    Text(parentDates)
                        .recordingFont(13)
                        .foregroundStyle(RecordingColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").recordingFont(13, weight: .medium)
                    .foregroundStyle(RecordingColor.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(RecordingSurface())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the parent sleep session")
        .accessibilityIdentifier("recording.parent")
    }

    private var parentDates: String {
        let start = RecordingFormat.date(draft.parent.date, year: false) + ", " + draft.parent.date.formatted(date: .omitted, time: .shortened)
        guard let end = draft.parent.observedEnd else {
            return start + (draft.parent.isOngoing ? " · still sleeping" : " · end not recorded")
        }
        let sameDay = Calendar.current.isDate(draft.parent.date, inSameDayAs: end)
        return start + " – " + (sameDay ? "" : RecordingFormat.date(end, year: false) + ", ") + end.formatted(date: .omitted, time: .shortened)
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
        VStack(alignment: .leading, spacing: 10) {
            RecordingSectionLabel(title: "Sleep Summary")
            RecordingCard(padding: 20) {
                if let presentation, !dynamicType.isAccessibilitySize {
                    ViewThatFits(in: .horizontal) {
                        ringSummary(presentation, net: net, proposed: proposed != nil, diameter: 144)
                        ringSummary(presentation, net: net, proposed: proposed != nil, diameter: 112)
                    }
                } else {
                    summaryValues(net: net, proposed: proposed != nil)
                    if let presentation { RecordingIntervalStrip(presentation: presentation) }
                }
            }
        }
    }

    private func ringSummary(_ presentation: RecordingIntervalPresentation, net: Int,
                             proposed: Bool, diameter: CGFloat) -> some View {
        HStack(spacing: diameter < 144 ? 10 : 16) {
            RecordingIntervalRing(presentation: presentation, diameter: diameter)
            Rectangle().fill(RecordingColor.border).frame(width: 1, height: 120).accessibilityHidden(true)
            summaryValues(net: net, proposed: proposed, ringVisible: true).frame(minWidth: diameter < 144 ? 112 : 116, alignment: .leading)
        }
    }

    private func summaryValues(net: Int, proposed: Bool, ringVisible: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryValue("Awake duration", minutes: max(0, Int(draft.end.timeIntervalSince(draft.start) / 60)), color: CoachColor.sun, identifier: "recording.awakeDuration")
            summaryValue(proposed ? (draft.parent.isOngoing ? "Net sleep so far" : "Resulting net sleep") : "Saved net sleep",
                         minutes: net, color: RecordingColor.accent, identifier: ringVisible ? "recording.resultingNetSleep" : "recording.netSleep")
        }
    }

    private func summaryValue(_ title: String, minutes: Int, color: Color, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).recordingFont(13).foregroundStyle(RecordingColor.secondary)
                Text(RecordingFormat.duration(minutes))
                    .recordingFont(20, weight: .semibold, rounded: true)
                    .foregroundStyle(RecordingColor.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier(identifier)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
