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
            Form {
                Section("Sleep Session") {
                    Text(draft.parent.kind == .nightSleep ? "Night Sleep" : "Nap")
                        .font(.headline)
                    Text(draft.parent.date.formatted(date: .abbreviated, time: .shortened))
                    if let end = draft.parent.observedEnd {
                        Text("To \(end.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Still sleeping · this break will not end the session")
                    }
                }
                Section("Awake Interval") {
                    RecordingDateField(title: "Start", identifier: "recording.start", date: $draft.start)
                    RecordingDateField(title: "End", identifier: "recording.end", date: $draft.end)
                }
                Section {
                    Text("Awake: \(TimeFormat.minutes(max(0, Int(draft.end.timeIntervalSince(draft.start) / 60))))")
                    Text("Net sleep after saving: \(TimeFormat.minutes(draft.netMinutes(existing: existingBreaks, now: Date())))")
                        .accessibilityIdentifier("recording.netSleep")
                    if let message = draft.validationMessage(existing: existingBreaks, now: Date()) {
                        Text(message).foregroundStyle(.red)
                            .accessibilityIdentifier("recording.validation")
                    }
                } header: {
                    Text("Sleep Summary")
                } footer: {
                    Text("Only this session's awake time is subtracted. The original sleep start and end stay unchanged.")
                }
                Section {
                    RecordingSaveButton(title: draft.editing == nil ? "Save Awake Break" : "Save Changes",
                                        enabled: !submission.isSubmitted && draft.validationMessage(existing: existingBreaks, now: Date()) == nil) {
                        submission.submit(draft.record(existing: existingBreaks, now: Date()),
                                          save: { record in
                                              let saved = onSave(record)
                                              saveFailed = !saved
                                              return saved
                                          }, dismiss: { dismiss() })
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(draft.editing == nil ? "Add Awake Break" : "Edit Awake Break")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Could Not Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The sleep session may have changed or this interval is already recorded. Your changes are still here; review the record and try again.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("recording.cancel")
                }
            }
        }
        .tint(RecordingStyle.accent)
    }
}
