import SwiftUI

struct AddRecordView: View {
    let defaultDate: Date
    let editingRecord: SleepRecord?
    let reviewUnconfirmed: Bool
    let onSave: (SleepRecord) -> Bool
    let onNightCompletion: ((SleepRecord) -> NightSleepCompletionResult)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AddRecordViewModel
    @State private var draft: SleepRecordingDraft
    @State private var submission = RecordingSubmission()
    @State private var saveFailed = false
    @State private var completionMessage: String?
    @State private var cancellationFailed = false
    @State private var breakParent: SleepRecord?
    @State private var records: [SleepRecord] = []
    private var existingBreaks: [SleepRecord] {
        records.filter { $0.kind == .break && $0.parentNapID == editingRecord?.id }
    }

    init(defaultDate: Date, editingRecord: SleepRecord? = nil, vm: AddRecordViewModel,
         initialKind: SleepKind? = nil, endingOngoing: Bool = false, reviewUnconfirmed: Bool = false,
         onNightCompletion: ((SleepRecord) -> NightSleepCompletionResult)? = nil,
         onSave: @escaping (SleepRecord) -> Bool) {
        self.defaultDate = defaultDate
        self.editingRecord = editingRecord
        self.reviewUnconfirmed = reviewUnconfirmed
        self.onSave = onSave
        self.onNightCompletion = onNightCompletion
        self.vm = vm
        if let editingRecord { vm.kind = editingRecord.kind }
        else if let initialKind { vm.kind = initialKind }
        var initialDraft = SleepRecordingDraft(defaultDate: defaultDate, editing: editingRecord)
        if endingOngoing {
            initialDraft.prepareForEnding(at: Date(), calendar: editingRecord?.kind == .nightSleep ? .current : nil,
                                          requireConfirmation: reviewUnconfirmed && editingRecord?.kind == .nightSleep)
        }
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
                            saveEnabled: !submission.isSubmitted && draft.isReadyToSubmit && draft.validationMessage(now: Date()) == nil,
                            onCancel: cancel, onSave: save, spacing: 28,
                            cancelTitle: reviewUnconfirmed && !draft.requiresExplicitCancellation ? "Review later" : "Cancel") {
                if draft.completionCalendar == nil {
                    RecordingKindPicker(selection: $vm.kind)
                        .padding(.horizontal, 2)
                        .padding(.top, 8)
                }
                VStack(spacing: 24) {
                    RecordingIntervalCard(start: $draft.start, end: $draft.end,
                                          ongoing: vm.kind == .nightSleep || editingRecord?.isOngoing == true || draft.isOngoing ? $draft.isOngoing : nil,
                                          lockedStartCalendar: draft.completionCalendar,
                                          feedback: feedback, validation: validation,
                                          onEndSelection: { draft.applyEndSelection($0) })
                    if draft.requiresEndConfirmation && !draft.isOngoing {
                        Button(draft.hasConfirmedEnd ? "Observed end confirmed" : "Confirm observed end") {
                            draft.confirmObservedEnd(now: Date())
                        }
                        .disabled(draft.hasConfirmedEnd || draft.validationMessage(now: Date()) != nil)
                        .accessibilityIdentifier("recording.end.confirm")
                    }
                    if let message = draft.validationMessage(now: Date()) {
                        RecordingValidation(message: message)
                    }
                    SleepRecordingFeedback(draft: draft, kind: vm.kind, editingRecord: editingRecord, records: records)
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
            .alert(cancellationFailed ? "Could Not Cancel" : "Could Not Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(cancellationFailed
                     ? "Cancellation could not be saved. Your entry is still open; try Cancel again."
                     : completionMessage ?? "The sleep session may have changed or this interval is already recorded. Your changes are still here; review the record and try again.")
            }
            .onAppear(perform: loadBreaks)
            .onDisappear { if breakParent == nil { _ = draft.abandon() } }
            .interactiveDismissDisabled(draft.requiresExplicitCancellation)
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in loadBreaks() }
            .fullScreenCover(item: $breakParent) { parent in
                AddBreakView(parent: parent, existingBreaks: existingBreaks, records: records, onSave: onSave)
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
        if draft.isOngoing && editingRecord?.isOngoing == true { return "End unconfirmed" }
        if draft.requiresEndConfirmation && (!draft.hasConfirmedEnd || end != draft.end) {
            return "Choose the observed sleep end"
        }
        let minutes = max(0, Int((draft.isOngoing ? Date() : end).timeIntervalSince(start) / 60))
        return "\(draft.isOngoing ? "Elapsed so far" : "Duration"): \(TimeFormat.minutes(minutes))"
    }

    private func validation(start: Date, end: Date) -> String? {
        preview(start: start, end: end).validationMessage(now: Date())
    }

    private func save() {
        cancellationFailed = false
        let now = Date()
        let kind = draft.completionCalendar == nil ? vm.kind : (editingRecord?.kind ?? vm.kind)
        if let original = editingRecord, original.isOngoing, draft.isOngoing,
           original.kind == kind, original.date == draft.start {
            if draft.requiresExplicitCancellation {
                completionMessage = "Retry or cancel the pending end submission before confirming Still Sleeping."
                saveFailed = true
            } else if RecordingSubmission.confirmStillSleeping(SleepRecordVersion(original), now: now,
                                                               persistence: SleepRecordPersistence()) {
                dismiss()
            } else {
                completionMessage = "This sleep record changed. Reopen it to review its current status."
                saveFailed = true
            }
            return
        }
        submission.submit(draft: draft, kind: kind, editing: editingRecord, now: now, save: { record in
            let persistence = SleepRecordPersistence()
            let prior = record.isOngoing ? persistence.load()?.first { $0.id == record.id } : nil
            let canConfirm = prior.map { SleepRecordVersion($0) == editingRecord.map(SleepRecordVersion.init) } ?? (editingRecord == nil)
            let result = RecordingSubmission.saveHomeRecord(record, now: now, onSave: onSave,
                onNightCompletion: onNightCompletion, confirmation: { saved in
                    guard canConfirm, let stored = persistence.load()?.first(where: { $0.id == saved.id }),
                          ObservationProvenance.sleepIdentity(stored) == ObservationProvenance.sleepIdentity(saved) else { return nil }
                    if let prior, ObservationProvenance.sleepIdentity(prior) == ObservationProvenance.sleepIdentity(stored),
                       prior.persistedRevision != stored.persistedRevision { return nil }
                    return StillSleepingConfirmation(record: stored, date: now, instant: ContinuousClock.now)
                })
            completionMessage = result.message
            saveFailed = !result.succeeded
            return result.succeeded
        }, dismiss: { dismiss() })
    }
    private func cancel() {
        if draft.abandon() { dismiss() } else { cancellationFailed = true; saveFailed = true }
    }

    private func loadBreaks() {
        records = SleepRecordPersistence().load() ?? []
    }
}

private struct SleepRecordingFeedback: View {
    let draft: SleepRecordingDraft
    let kind: SleepKind
    let editingRecord: SleepRecord?
    let records: [SleepRecord]
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let end = draft.isOngoing ? context.date : draft.end
            let hidesDuration = (draft.isOngoing && editingRecord?.isOngoing == true) ||
                (draft.requiresEndConfirmation && !draft.hasConfirmedEnd)
            let minutes = hidesDuration ? nil : max(0, Int(end.timeIntervalSince(draft.start) / 60))
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
                if let editingRecord, editingRecord.completedEnd(at: context.date) != nil {
                    let accounting = SleepAccounting(records: records, now: context.date, calendar: draft.completionCalendar ?? .current)
                    let net = accounting.completedMinutes(sleepIDs: [editingRecord.id])
                    Text(net.map { "Saved net sleep: \(RecordingFormat.duration($0))" } ?? "Saved net sleep unknown")
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

    private func value(_ minutes: Int?) -> some View {
        Text(minutes.map(RecordingFormat.duration) ?? "End unconfirmed")
            .recordingFont(22, weight: .semibold, rounded: true)
            .foregroundStyle(RecordingColor.accent)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("recording.duration")
    }
}
