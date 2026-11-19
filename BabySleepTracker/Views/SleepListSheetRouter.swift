import SwiftUI

struct SleepListSheetRouter: View {
    @Environment(\.dismiss) private var dismiss
    let sheet: SleepListView.ActiveSheet
    let records: [SleepRecord]
    let todayWakeTime: Date?
    let defaultWakeTime: Date
    let onRecordUpsert: (SleepRecord) -> Bool
    let onNightCompletion: (SleepRecord) -> NightSleepCompletionResult
    let onBreakSaved: (SleepRecord) -> Bool
    let onDeleteRecords: (Set<UUID>) -> Void
    let onWakeTimeSave: (Date, WakeObservationCapture?) -> String?

    var body: some View {
        switch sheet {
        case .addSleep(let editing, let date):
            AddRecordView(
                defaultDate: date,
                editingRecord: editing,
                vm: AddRecordViewModel(),
                onSave: onRecordUpsert
            )

        case .addNightSleep(let date):
            AddRecordView(defaultDate: date, vm: AddRecordViewModel(), initialKind: .nightSleep,
                          onSave: onRecordUpsert)

        case .endSleep(let parent):
            // Keep the editor's original revision/capabilities alive after a partial
            // write. The command revalidates persistence; notifications cannot replace
            // this form with a different night or destroy its retry context.
            AddRecordView(defaultDate: parent.date, editingRecord: parent,
                          vm: AddRecordViewModel(), endingOngoing: true,
                          onNightCompletion: parent.kind == .nightSleep ? onNightCompletion : nil, onSave: onRecordUpsert)

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
                nightRecords: records,
                existing: DailyWakeRecordPersistence().load()?.first { $0.wakeTime == todayWakeTime },
                onSave: onWakeTimeSave
            )
        }
    }
}

// MARK: - Wake Time Editor

private struct WakeTimeEditorView: View {
    let onSave: (Date, WakeObservationCapture?) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WakeObservationDraft
    @State private var saveFailed = false
    @State private var saveFailureMessage: String?
    @State private var cancellationFailed = false

    init(initialTime: Date, nightRecords: [SleepRecord], existing: DailyWakeRecord?, onSave: @escaping (Date, WakeObservationCapture?) -> String?) {
        self.onSave   = onSave
        _draft = State(initialValue: WakeObservationDraft(initial: initialTime, existing: existing, nightRecords: nightRecords))
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
                    selection: $draft.selected,
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
                    Button("Cancel") {
                        if draft.abandon() { dismiss() } else { cancellationFailed = true; saveFailed = true }
                    }.accessibilityIdentifier("home.wake.cancel")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        cancellationFailed = false
                        if draft.submit(save: { date, capture in
                            saveFailureMessage = onSave(date, capture)
                            return saveFailureMessage == nil
                        }) { dismiss() } else { saveFailed = true }
                    }.accessibilityIdentifier("home.wake.save")
                        .fontWeight(.semibold)
                }
            }
        }
        .alert(cancellationFailed ? "Could not cancel wake time" : "Could not save wake time", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(cancellationFailed
                 ? "Cancellation could not be saved. Your entry is still open; try Cancel again."
                 : saveFailureMessage ?? "Saving did not finish. Review your wake time and try again."))
        }
        .tint(Color.sleepPurpleDeep)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.requiresExplicitCancellation)
        .onDisappear { _ = draft.abandon() }
    }
}
