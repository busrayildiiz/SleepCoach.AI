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
    let onWakeTimeSave: (Date, WakeObservationCapture?, HomeWakeOperation, Calendar) -> String?

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

        case .finishNap(let parent):
            FinishNapEditorView(parent: parent, records: records, onSave: onRecordUpsert)

        case .endSleep(let parent, let review):
            // Keep the editor's original revision/capabilities alive after a partial
            // write. The command revalidates persistence; notifications cannot replace
            // this form with a different night or destroy its retry context.
            AddRecordView(defaultDate: parent.date, editingRecord: parent,
                          vm: AddRecordViewModel(), endingOngoing: true, reviewUnconfirmed: review,
                          onNightCompletion: parent.kind == .nightSleep ? onNightCompletion : nil, onSave: onRecordUpsert)

        case .addBreak(let parentID):
            if let parent = records.first(where: { $0.id == parentID && $0.kind != .break }) {
                AddBreakView(parent: parent,
                             existingBreaks: records.filter { $0.parentNapID == parent.id && $0.kind == .break },
                             records: records, onSave: onBreakSaved)
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

        case .wakeTime(let association):
            let calendar = association?.calendar ?? .current
            let morning = association?.morning ?? calendar.startOfDay(for: defaultWakeTime)
            let wakes = DailyWakeRecordPersistence().load() ?? []
            let existing = DailyWakeRecord.uniqueObservation(in: wakes, on: morning,
                at: max(Date(), todayWakeTime ?? .distantPast), calendar: calendar)
            let routineWake = association.flatMap { SleepRoutine.load(defaults: SecureDataStore.shared)?.wake(on: $0.morning, calendar: $0.calendar) }
            let suggestion = existing?.wakeTime ?? routineWake ?? todayWakeTime ?? defaultWakeTime
            let time = RecordingEndpointSelection.combine(day: morning, time: suggestion,
                preserving: suggestion, calendar: calendar) ?? morning
            WakeTimeEditorView(
                initialTime: time, association: association, calendar: calendar, existing: existing,
                onSave: onWakeTimeSave
            )
        }
    }
}

// MARK: - Quick Nap Completion

private struct FinishNapEditorView: View {
    let records: [SleepRecord]
    let onSave: (SleepRecord) -> Bool
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NapCompletionDraft
    @State private var saveFailed = false
    @State private var cancellationFailed = false
    @State private var failureMessage: String?

    init(parent: SleepRecord, records: [SleepRecord], now: Date = Date(), calendar: Calendar = .current,
         onSave: @escaping (SleepRecord) -> Bool) {
        self.records = records
        self.onSave = onSave
        _draft = State(initialValue: NapCompletionDraft(parent: parent, now: now, calendar: calendar))
    }

    private func pickerBinding(changesDay: Bool) -> Binding<Date> {
        Binding(get: { draft.end }, set: { draft.selectEnd($0, changesDay: changesDay) })
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            editor(now: context.date)
        }
    }

    @ViewBuilder private func editor(now: Date) -> some View {
        let validation = draft.validationMessage(records: records, now: now)
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 6) {
                        Text("When did the nap end?")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.sleepInk)
                        Text("Started \(RecordingFormat.timestamp(draft.parent.date, calendar: draft.calendar))")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.sleepMuted)
                            .accessibilityIdentifier("home.nap.start")
                    }
                    .multilineTextAlignment(.center)
                    DatePicker("End date", selection: pickerBinding(changesDay: true), displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("home.nap.end.date")
                    DatePicker("Nap end time", selection: pickerBinding(changesDay: false), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .accessibilityLabel("Nap end time")
                        .accessibilityIdentifier("home.nap.end.time")
                        .frame(maxWidth: .infinity)
                    Text(RecordingFormat.timestamp(draft.end, calendar: draft.calendar))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.sleepMuted)
                        .accessibilityIdentifier("home.nap.end.selection")
                    if let validation { RecordingValidation(message: validation) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Color.sleepBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecordingSaveButton(title: "Save End Time", enabled: validation == nil && !draft.isSubmitted, action: save)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .background(Color.sleepBackground)
            }
            .navigationTitle("Finish Nap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("home.nap.cancel")
                }
            }
        }
        .alert(cancellationFailed ? "Could Not Cancel" : "Could Not Finish Nap", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(cancellationFailed
                 ? "Cancellation could not be saved. Your entry is still open; try Cancel again."
                 : failureMessage ?? "Saving did not finish. Your selected end time is still here; please try again.")
        }
        .environment(\.calendar, draft.calendar)
        .environment(\.timeZone, draft.calendar.timeZone)
        .tint(RecordingColor.accent)
        .presentationDetents(dynamicType.isAccessibilitySize ? [.large] : [.height(520), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.requiresExplicitCancellation)
        .onDisappear { _ = draft.abandon() }
    }

    private func save() {
        cancellationFailed = false
        let now = Date()
        // Re-read before submitting: an awake break may have been added while the sheet was open.
        let currentRecords = SleepRecordPersistence().load() ?? []
        failureMessage = draft.validationMessage(records: currentRecords, now: now)
        guard failureMessage == nil else { saveFailed = true; return }
        if !draft.submit(records: currentRecords, now: now, save: onSave, dismiss: { dismiss() }) {
            saveFailed = true
        }
    }

    private func cancel() {
        if draft.abandon() { dismiss() } else { cancellationFailed = true; saveFailed = true }
    }
}

// MARK: - Wake Time Editor

private struct WakeTimeEditorView: View {
    let onSave: (Date, WakeObservationCapture?, HomeWakeOperation, Calendar) -> String?
    let association: AssociatedHomeWake?
    @State private var calendar: Calendar
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WakeObservationDraft
    @State private var saveFailed = false
    @State private var saveFailureMessage: String?
    @State private var cancellationFailed = false
    @State private var confirmSuggestedTime = false

    init(initialTime: Date, association: AssociatedHomeWake?, calendar: Calendar, existing: DailyWakeRecord?,
         onSave: @escaping (Date, WakeObservationCapture?, HomeWakeOperation, Calendar) -> String?) {
        self.onSave = onSave
        self.association = association
        _calendar = State(initialValue: calendar)
        _draft = State(initialValue: WakeObservationDraft(initial: initialTime, existing: existing))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.12)).frame(width: 58, height: 58)
                        Image(systemName: "sunrise.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                    VStack(spacing: 6) {
                        Text("When did your baby wake up?")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.sleepInk)
                            .multilineTextAlignment(.center)
                        Text(association.map { "This also ends the night started \(RecordingFormat.timestamp($0.nightStart, calendar: calendar))." }
                             ?? "Record an observed wake time to help plan today.")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.sleepMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        if let association {
                            Text("Wake date \(RecordingFormat.date(association.morning, calendar: calendar))")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("home.wake.date")
                        }
                    }
                    DatePicker(
                        "Wake-up time",
                        selection: $draft.selected,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel).labelsHidden()
                    .frame(maxHeight: 150).clipped()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
            .background(Color.sleepBackground)
            .navigationTitle(association == nil ? "Today's Wake-up" : "Morning Wake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        if draft.abandon() { dismiss() } else { cancellationFailed = true; saveFailed = true }
                    }.accessibilityIdentifier("home.wake.cancel")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(association == nil ? "Save" : "Save and End Sleep") {
                        if draft.needsTimeConfirmation && !draft.requiresExplicitCancellation {
                            confirmSuggestedTime = true
                        } else {
                            save()
                        }
                    }.accessibilityIdentifier("home.wake.save")
                        .fontWeight(.semibold)
                }
            }
        }
        .confirmationDialog("Confirm observed wake time", isPresented: $confirmSuggestedTime, titleVisibility: .visible) {
            Button("Confirm and Save") { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save this time only if you observed your baby wake at \(RecordingFormat.timestamp(draft.selected, calendar: calendar)).")
        }
        .alert(cancellationFailed ? "Could not cancel wake time" : "Could not save wake time", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(LocalizedStringKey(cancellationFailed
                 ? "Cancellation could not be saved. Your entry is still open; try Cancel again."
                 : saveFailureMessage ?? "Saving did not finish. Review your wake time and try again."))
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .tint(Color.sleepPurpleDeep)
        .presentationDetents(dynamicType.isAccessibilitySize ? [.large] : [.height(390), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.requiresExplicitCancellation)
        .onDisappear { _ = draft.abandon() }
    }

    private func save() {
        cancellationFailed = false
        let operation = association.map(HomeWakeOperation.associated) ?? .independent
        if draft.submit(save: { date, capture in
            saveFailureMessage = onSave(date, capture, operation, calendar)
            return saveFailureMessage == nil
        }) { dismiss() } else { saveFailed = true }
    }
}
