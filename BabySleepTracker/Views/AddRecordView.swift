import SwiftUI

struct AddRecordView: View {
    let defaultDate: Date
    let editingRecord: SleepRecord?
    let onSave: (SleepRecord) -> Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AddRecordViewModel
    @State private var draft: SleepRecordingDraft
    @State private var submission = RecordingSubmission()
    @State private var saveFailed = false
    @State private var breakParent: SleepRecord?
    @State private var existingBreaks: [SleepRecord] = []

    init(defaultDate: Date, editingRecord: SleepRecord? = nil, vm: AddRecordViewModel,
         onSave: @escaping (SleepRecord) -> Bool) {
        self.defaultDate = defaultDate
        self.editingRecord = editingRecord
        self.onSave = onSave
        self.vm = vm
        if let editingRecord { vm.kind = editingRecord.kind }
        _draft = State(initialValue: SleepRecordingDraft(defaultDate: defaultDate, editing: editingRecord))
    }

    private var title: String {
        let action = editingRecord == nil ? "Add" : "Edit"
        return "\(action) \(vm.kind == .nightSleep ? "Night Sleep" : "Nap")"
    }

    var body: some View {
        NavigationStack {
            RecordingScreen(title: title,
                            saveTitle: editingRecord == nil ? "Save Sleep" : "Save Changes",
                            saveEnabled: !submission.isSubmitted && draft.validationMessage(now: Date()) == nil,
                            onCancel: { dismiss() }, onSave: save) {
                RecordingKindPicker(selection: $vm.kind)
                RecordingIntervalCard(title: "Sleep interval", start: $draft.start, end: $draft.end,
                                      ongoing: $draft.isOngoing, feedback: feedback, validation: validation)
                if let message = draft.validationMessage(now: Date()) {
                    RecordingValidation(message: message)
                }
                SleepRecordingFeedback(draft: draft, editingRecord: editingRecord, breaks: existingBreaks)
                if let parent = editingRecord {
                    Button { breakParent = parent } label: {
                        Label("Add Awake Break", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 8)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("recording.addBreak")
                }
            }
            .alert("Could Not Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The sleep session may have changed or this interval is already recorded. Your changes are still here; review the record and try again.")
            }
            .onAppear(perform: loadBreaks)
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in loadBreaks() }
            .sheet(item: $breakParent) { parent in
                AddBreakView(parent: parent, existingBreaks: existingBreaks, onSave: onSave)
            }
        }
        .tint(CoachColor.purpleDeep)
    }

    private func preview(start: Date, end: Date) -> SleepRecordingDraft {
        var preview = draft
        preview.start = start
        preview.end = end
        return preview
    }

    private func feedback(start: Date, end: Date) -> String {
        let minutes = max(0, Int((draft.isOngoing ? Date() : end).timeIntervalSince(start) / 60))
        return "\(draft.isOngoing ? "Elapsed so far" : "Duration"): \(TimeFormat.minutes(minutes))"
    }

    private func validation(start: Date, end: Date) -> String? {
        preview(start: start, end: end).validationMessage(now: Date())
    }

    private func save() {
        submission.submit(draft.record(kind: vm.kind, editing: editingRecord, now: Date()), save: { record in
            let saved = onSave(record)
            saveFailed = !saved
            return saved
        }, dismiss: { dismiss() })
    }

    private func loadBreaks() {
        existingBreaks = (SleepRecordPersistence().load() ?? []).filter {
            $0.kind == .break && $0.parentNapID == editingRecord?.id
        }
    }
}

private struct SleepRecordingFeedback: View {
    let draft: SleepRecordingDraft
    let editingRecord: SleepRecord?
    let breaks: [SleepRecord]
    @ScaledMetric(relativeTo: .title2) private var size = 24

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let end = draft.isOngoing ? context.date : draft.end
            let minutes = max(0, Int(end.timeIntervalSince(draft.start) / 60))
            VStack(alignment: .leading, spacing: 6) {
                RecordingSectionLabel(title: draft.isOngoing ? "Elapsed so far" : "Duration")
                Text(TimeFormat.minutes(minutes))
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.purpleDeep)
                    .monospacedDigit()
                    .accessibilityIdentifier("recording.duration")
                if draft.isOngoing {
                    Text("Still sleeping · no end recorded")
                        .font(.caption).foregroundStyle(CoachColor.muted)
                }
                if let editingRecord {
                    Text("Saved net sleep: \(TimeFormat.minutes(editingRecord.totalMinutes(breaks: breaks, at: context.date)))")
                        .font(.caption).foregroundStyle(CoachColor.muted)
                        .accessibilityIdentifier("recording.netSleep")
                }
            }
            .padding(.vertical, 8)
        }
    }
}
