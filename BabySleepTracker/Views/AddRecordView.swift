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

    init(defaultDate: Date, editingRecord: SleepRecord? = nil, vm: AddRecordViewModel, endingOngoing: Bool = false,
         onSave: @escaping (SleepRecord) -> Bool) {
        self.defaultDate = defaultDate
        self.editingRecord = editingRecord
        self.onSave = onSave
        self.vm = vm
        if let editingRecord { vm.kind = editingRecord.kind }
        var initialDraft = SleepRecordingDraft(defaultDate: defaultDate, editing: editingRecord)
        if endingOngoing { initialDraft.prepareForEnding(at: Date()) }
        _draft = State(initialValue: initialDraft)
    }

    private var title: String {
        let action = editingRecord == nil ? "Add" : "Edit"
        return "\(action) \(vm.kind == .nightSleep ? "Night Sleep" : "Nap")"
    }

    var body: some View {
        NavigationStack {
            RecordingScreen(title: title,
                            saveTitle: editingRecord == nil ? (vm.kind == .nightSleep ? "Save Night Sleep" : "Save Nap") : "Save Changes",
                            saveEnabled: !submission.isSubmitted && draft.validationMessage(now: Date()) == nil,
                            onCancel: { dismiss() }, onSave: save, spacing: 28) {
                RecordingKindPicker(selection: $vm.kind)
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
                VStack(spacing: 24) {
                    RecordingIntervalCard(start: $draft.start, end: $draft.end,
                                          ongoing: vm.kind == .nightSleep || draft.isOngoing ? $draft.isOngoing : nil,
                                          feedback: feedback, validation: validation)
                    if let message = draft.validationMessage(now: Date()) {
                        RecordingValidation(message: message)
                    }
                    SleepRecordingFeedback(draft: draft, kind: vm.kind, editingRecord: editingRecord, breaks: existingBreaks)
                }
                .padding(.horizontal, -4)
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
            .fullScreenCover(item: $breakParent) { parent in
                AddBreakView(parent: parent, existingBreaks: existingBreaks, onSave: onSave)
            }
        }
        .tint(RecordingColor.accent)
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
            if saved && record.isOngoing {
                NotificationCenter.default.post(name: .sleepStillSleepingConfirmed, object: record.id,
                                                userInfo: ["confirmedAt": Date()])
            }
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
    let kind: SleepKind
    let editingRecord: SleepRecord?
    let breaks: [SleepRecord]
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let end = draft.isOngoing ? context.date : draft.end
            let minutes = max(0, Int(end.timeIntervalSince(draft.start) / 60))
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if dynamicType.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) { durationLabel; value(minutes) }
                    } else {
                        HStack(spacing: 12) { durationLabel; Spacer(minLength: 0); value(minutes) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(RecordingColor.inset))
                if let editingRecord {
                    Text("Saved net sleep: \(RecordingFormat.duration(editingRecord.totalMinutes(breaks: breaks, at: context.date)))")
                        .recordingFont(12).foregroundStyle(RecordingColor.secondary)
                        .accessibilityIdentifier("recording.netSleep")
                }
            }
            .padding(10)
            .background(RecordingSurface())
        }
    }

    private var durationLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .recordingFont(20, weight: .medium)
                .frame(width: 28, height: 28)
                .background(Circle().fill(RecordingColor.accent.opacity(0.06)))
                .accessibilityHidden(true)
            Text(draft.isOngoing ? "Elapsed so far" : (kind == .nightSleep ? "Sleep duration" : "Nap duration"))
                .recordingFont(14)
        }
        .foregroundStyle(RecordingColor.accent)
    }

    private func value(_ minutes: Int) -> some View {
        Text(RecordingFormat.duration(minutes))
            .recordingFont(22, weight: .semibold, rounded: true)
            .foregroundStyle(RecordingColor.accent)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("recording.duration")
    }
}
