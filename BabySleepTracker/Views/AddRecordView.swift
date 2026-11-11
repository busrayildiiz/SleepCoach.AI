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
            Form {
                Section {
                    Picker("Sleep type", selection: $vm.kind) {
                        Text("Nap").tag(SleepKind.dayNap)
                        Text("Night Sleep").tag(SleepKind.nightSleep)
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("recording.kind")
                    Toggle("Still Sleeping", isOn: $draft.isOngoing)
                        .accessibilityIdentifier("recording.ongoing")
                } footer: {
                    Text("Still Sleeping keeps this session open until you explicitly record its end.")
                }
                Section("When") {
                    RecordingDateField(title: "Start", identifier: "recording.start", date: $draft.start)
                    if !draft.isOngoing {
                        RecordingDateField(title: "End", identifier: "recording.end", date: $draft.end)
                    }
                }
                Section("Sleep Summary") {
                    if draft.isOngoing {
                        Text("Still sleeping · no end recorded")
                    } else {
                        Text("Duration: \(TimeFormat.minutes(max(0, Int(draft.end.timeIntervalSince(draft.start) / 60))))")
                    }
                    if let parent = editingRecord {
                        Text("Saved net sleep: \(TimeFormat.minutes(parent.totalMinutes(breaks: existingBreaks)))")
                            .accessibilityIdentifier("recording.netSleep")
                        Button("Add Awake Break") { breakParent = parent }
                            .accessibilityIdentifier("recording.addBreak")
                    }
                    if let message = draft.validationMessage(now: Date()) {
                        Text(message).foregroundStyle(.red)
                            .accessibilityIdentifier("recording.validation")
                    }
                }
                Section {
                    RecordingSaveButton(title: editingRecord == nil ? "Save Sleep" : "Save Changes",
                                        enabled: !submission.isSubmitted && draft.validationMessage(now: Date()) == nil) {
                        submission.submit(draft.record(kind: vm.kind, editing: editingRecord, now: Date()),
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
            .navigationTitle(title)
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
            .onAppear(perform: loadBreaks)
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in loadBreaks() }
            .sheet(item: $breakParent) { parent in
                AddBreakView(parent: parent, existingBreaks: existingBreaks, onSave: onSave)
            }
        }
        .tint(RecordingStyle.accent)
    }

    private func loadBreaks() {
        existingBreaks = (SleepRecordPersistence().load() ?? []).filter {
            $0.kind == .break && $0.parentNapID == editingRecord?.id
        }
    }
}
