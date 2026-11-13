import SwiftUI

struct SleepListSheetRouter: View {
    @Environment(\.dismiss) private var dismiss
    let sheet: SleepListView.ActiveSheet
    let records: [SleepRecord]
    let todayWakeTime: Date?
    let defaultWakeTime: Date
    let onRecordUpsert: (SleepRecord) -> Bool
    let onBreakSaved: (SleepRecord) -> Bool
    let onDeleteRecords: (Set<UUID>) -> Void
    let onWakeTimeSave: (Date) -> Bool

    var body: some View {
        switch sheet {
        case .addSleep(let editing, let date):
            AddRecordView(
                defaultDate: date,
                editingRecord: editing,
                vm: AddRecordViewModel(),
                onSave: onRecordUpsert
            )

        case .addBreak(let parentID):
            if let parent = records.first(where: { $0.id == parentID && $0.kind != .break }) {
                AddBreakView(parent: parent,
                             existingBreaks: records.filter { $0.parentNapID == parent.id && $0.kind == .break },
                             onSave: onBreakSaved)
            } else {
                NavigationStack {
                    Text("This sleep session is no longer available.")
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RecordingColor.background)
                        .navigationTitle("Add Awake Break")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                                    .accessibilityIdentifier("recording.cancel")
                            }
                        }
                }
                .tint(RecordingColor.accent)
            }

        case .dayDetail(let selected):
            let dayRecords = SleepAccounting(records: records, now: Date(), calendar: .current)
                .records(on: selected.day).sorted { $0.date < $1.date }
            DayDetailView(
                day: selected.day,
                records: dayRecords,
                onDelete: onDeleteRecords,
                onRecordUpsert: onRecordUpsert,
                onBreakSaved: onBreakSaved
            )

        case .wakeTime:
            WakeTimeEditorView(
                initialTime: todayWakeTime ?? defaultWakeTime,
                onSave: onWakeTimeSave
            )
        }
    }
}

// MARK: - Wake Time Editor

private struct WakeTimeEditorView: View {
    let onSave: (Date) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTime: Date
    @State private var saveFailed = false

    init(initialTime: Date, onSave: @escaping (Date) -> Bool) {
        self.onSave   = onSave
        _selectedTime = State(initialValue: initialTime)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.12)).frame(width: 58, height: 58)
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                VStack(spacing: 6) {
                    Text("When did your baby wake up?")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.sleepInk)
                        .multilineTextAlignment(.center)
                    Text("This time becomes the starting point for today's sleep predictions.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sleepMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                DatePicker(
                    "Wake-up time",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel).labelsHidden()
                .frame(maxHeight: 150).clipped()
                Spacer()
            }
            .padding(.top, 24)
            .background(Color.sleepBackground)
            .navigationTitle("Today's Wake-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("home.wake.cancel")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if onSave(selectedTime) { dismiss() } else { saveFailed = true }
                    }.accessibilityIdentifier("home.wake.save")
                        .fontWeight(.semibold)
                }
            }
        }
        .alert("Could not save wake time", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Your wake time has not been saved. Please try again.") }
        .tint(Color.sleepPurpleDeep)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
    }
}
