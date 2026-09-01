import SwiftUI

struct SleepListSheetRouter: View {
    let sheet: SleepListView.ActiveSheet
    let records: [SleepRecord]
    let todayWakeTime: Date?
    let defaultWakeTime: Date
    let onRecordUpsert: (SleepRecord) -> Void
    let onBreakSaved: (SleepRecord) -> Void
    let onDeleteRecords: (Set<UUID>) -> Void
    let onSelectSheet: (SleepListView.ActiveSheet) -> Void
    let onWakeTimeSave: (Date) -> Void

    var body: some View {
        switch sheet {
        case .addSleep(let editing, let date):
            AddRecordView(
                defaultDate: date,
                editingRecord: editing,
                vm: AddRecordViewModel(),
                onSave: onRecordUpsert
            )

        case .addBreak(let napID, let date, let napDuration):
            let existing = records.filter {
                $0.parentNapID == napID && $0.kind == .break
            }
            AddBreakView(
                defaultDate: date,
                targetNapID: napID,
                napDuration: napDuration,
                existingBreaks: existing,
                onSave: onBreakSaved
            )

        case .dayDetail(let selected):
            let dayRecords = records
                .filter { Calendar.current.isDate($0.date, inSameDayAs: selected.day) }
                .sorted { $0.date < $1.date }
            DayDetailView(
                day: selected.day,
                records: dayRecords,
                onDelete: onDeleteRecords,
                onAddSleep: { day in
                    onSelectSheet(.addSleep(editing: nil, defaultDate: day))
                },
                onEditNap: { nap in
                    onSelectSheet(.addSleep(editing: nap, defaultDate: nap.date))
                },
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
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTime: Date

    init(initialTime: Date, onSave: @escaping (Date) -> Void) {
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { onSave(selectedTime); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.sleepPurpleDeep)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
    }
}
