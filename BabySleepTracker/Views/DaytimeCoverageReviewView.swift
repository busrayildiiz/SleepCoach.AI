import Combine
import SwiftUI

struct DaytimeCoverageReviewView: View {
    let initialDay: Date?
    let initialCalendar: Calendar
    let onRecordSaved: (SleepRecord) -> Bool

    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var feedbackFocused: Bool
    @State private var model: DaytimeCoverageReviewModel
    @State private var calendar: Calendar
    @State private var date: Date
    @State private var latestPastDate: Date
    @State private var appeared = false
    @State private var editor: Editor?
    @State private var showWithdrawal = false
    @State private var isWriting = false
    @State private var recordChanged = false

    private enum Editor: Identifiable {
        case nap(SleepRecord?, day: Date)
        case wake(Date, Calendar)

        var id: String {
            switch self {
            case .nap(let record, _): return record?.id.uuidString ?? "new-nap"
            case .wake(let day, _): return "wake-\(day.timeIntervalSinceReferenceDate)"
            }
        }
    }

    init(initialDay: Date?, initialCalendar: Calendar, onRecordSaved: @escaping (SleepRecord) -> Bool) {
        self.initialDay = initialDay
        self.initialCalendar = initialCalendar
        self.onRecordSaved = onRecordSaved
        let calendar = DaytimeReviewWindow.capture(.current)
        let latestPastDate = calendar.startOfDay(for: Date()).addingTimeInterval(-1)
        _calendar = State(initialValue: calendar)
        _date = State(initialValue: calendar.startOfDay(for: latestPastDate))
        _latestPastDate = State(initialValue: latestPastDate)
        #if DEBUG && targetEnvironment(simulator)
        _model = State(initialValue: .init(storage: DaytimeCoverageUITestFixture.reviewStorage()))
        #else
        _model = State(initialValue: .init(storage: .init(defaults: SecureDataStore.shared)))
        #endif
    }

    var body: some View {
        Form {
            if let inspection = model.inspection {
                statusSection(inspection)
                if let morning = inspection.morning, let following = inspection.following {
                    Section("Wake boundaries") {
                        boundary(morning, title: "Morning wake", identifier: "daytimeReview.morning")
                        boundary(following, title: "Following morning wake", identifier: "daytimeReview.following")
                    }
                    napSection(inspection)
                }
                answerSection(inspection)
            } else {
                if let feedback = model.feedback { Section { feedbackText(feedback) } }
                Section {
                    DatePicker("Review date", selection: $date, in: ...latestPastDate, displayedComponents: .date)
                        .accessibilityIdentifier("daytimeReview.date")
                    Button("Review selected day", action: start)
                        .accessibilityIdentifier("daytimeReview.select")
                }
            }
        }
        .navigationTitle("Daytime recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Review later") {
                    model.deferReview()
                    dismiss()
                }
                .disabled(isWriting)
                .accessibilityIdentifier("daytimeReview.later")
            }
        }
        .tint(RecordingColor.accent)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .onAppear(perform: appear)
        .onReceive(observationChanges) { _ in refresh() }
        .onChange(of: model.feedback) { value in if value != nil { feedbackFocused = true } }
        .confirmationDialog("Withdraw the saved daytime answer?", isPresented: $showWithdrawal, titleVisibility: .visible) {
            Button("Withdraw saved answer", role: .destructive) { write(withdrawing: true) }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Nap record changed", isPresented: $recordChanged) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Review the latest naps and open the record again.")
        }
        .fullScreenCover(item: $editor, onDismiss: refresh) { editor in
            switch editor {
            case .nap(let record, let day):
                AddRecordView(defaultDate: day, editingRecord: record, vm: AddRecordViewModel(),
                              endingOngoing: record?.isOngoing == true, napOnly: true, onSave: onRecordSaved)
            case .wake(let day, let calendar):
                HistoricalWakeEditor(day: day, calendar: calendar, fixedDay: true) { _, _ in }
            }
        }
    }

    private var observationChanges: some Publisher<Notification, Never> {
        let names: [Notification.Name] = [.observationProvenanceDidChange, .sleepRecordsDidChange, .dailyWakeRecordsDidChange,
                                         .secureDataStoreDidChange, .NSSystemTimeZoneDidChange,
                                         UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification]
        return Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            .debounce(for: .milliseconds(25), scheduler: RunLoop.main)
    }

    private func statusSection(_ inspection: DaytimeCoverageInspection) -> some View {
        Section {
            Text(inspection.day, format: dateStyle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("daytimeReview.day")
            Text(statusTitle(inspection))
                .font(.body.weight(.semibold))
                .accessibilityIdentifier("daytimeReview.status")
            if let blocker = inspection.blocker {
                Text(blockerMessage(blocker, hasWakeWindow: inspection.hasWakeWindow)).foregroundStyle(.secondary)
                if inspection.status == .invalidated { Text("The previous answer needs a new review.") }
            }
            if let feedback = model.feedback { feedbackText(feedback) }
        }
    }

    private func statusTitle(_ inspection: DaytimeCoverageInspection) -> LocalizedStringKey {
        if inspection.blocker != nil { return "Review unavailable" }
        switch inspection.status {
        case .unknown: return "Awaiting review"
        case .incomplete: return "Recording marked incomplete"
        case .confirmed: return inspection.naps.isEmpty ? "Zero naps confirmed" : "You confirmed all naps were recorded"
        case .invalidated: return "Needs review again"
        }
    }

    private func blockerMessage(_ blocker: DaytimeCoverageInspection.Blocker, hasWakeWindow: Bool) -> LocalizedStringKey {
        switch blocker {
        case .notHistorical: return "Choose a date before today."
        case .storageUnavailable: return "Saved observations could not be opened."
        case .wakeBoundaries: return "Each date needs one verified morning wake before you can save a review."
        case .conflictingEvidence:
            return hasWakeWindow
                ? "Conflicting records prevent a review of this day."
                : "The two wakes do not form a valid daytime interval. Use Review recorded wake to check past wake times."
        case .unresolvedNap: return "A nap needs an observed end before this day can be reviewed."
        case .crossingNap: return "A nap crosses a morning wake. Check the recorded times."
        case .crossingBreak: return "An awake break crosses a morning wake. Check the recorded times."
        case .unavailableRevision: return "A recorded observation could not be verified against its saved revision."
        }
    }

    @ViewBuilder
    private func boundary(_ boundary: DaytimeCoverageInspection.Boundary, title: LocalizedStringKey,
                          identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.body.weight(.semibold))
            if let time = boundary.time {
                Text(time, format: timestampStyle)
            } else {
                Text(boundary.day, format: dateStyle)
            }
            Text(wakeStatus(boundary.status)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)

        if boundary.day < calendar.startOfDay(for: Date()),
           [.missing, .unverified, .verified].contains(boundary.status) {
            Button(boundary.status == .missing ? "Record morning wake" : "Review recorded wake") {
                refresh()
                guard let current = model.inspection,
                      current.morning == boundary || current.following == boundary else { return }
                editor = .wake(boundary.day, calendar)
            }
            .accessibilityIdentifier("\(identifier).edit")
        } else if boundary.status == .missing || boundary.status == .unverified {
            Text("Use Today’s Wake-up on Home to record an observed wake.")
                .foregroundStyle(.secondary)
        }
    }

    private func wakeStatus(_ status: DaytimeCoverageInspection.Boundary.Status) -> LocalizedStringKey {
        switch status {
        case .missing: return "Missing wake"
        case .conflicting: return "More than one morning wake is recorded for this date. Choose another date or review later."
        case .invalid: return "This wake cannot be used for the selected date."
        case .pending: return "Wake recovery is pending. Finish the original recording or reopen the app."
        case .unverified: return "Recorded wake needs verification"
        case .future: return "This wake time is still in the future."
        case .verified: return "Verified wake"
        }
    }

    private func napSection(_ inspection: DaytimeCoverageInspection) -> some View {
        let naps = model.review?.naps ?? inspection.naps
        let title: LocalizedStringKey = inspection.hasWakeWindow ? "Naps between the wakes" : "Naps starting on this date"
        return Section(title) {
            if naps.isEmpty && inspection.blocker == nil {
                Text("No naps recorded").accessibilityIdentifier("daytimeReview.empty")
            }
            ForEach(Array(naps.enumerated()), id: \.offset) { index, nap in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nap \(index + 1)").font(.body.weight(.semibold))
                    Text("Start \(nap.start.formatted(timestampStyle))")
                    if let end = nap.end {
                        Text("End \(end.formatted(timestampStyle))")
                    } else {
                        Text(nap.isOngoing ? "Ongoing nap" : "End missing")
                    }
                    if nap.usesLegacyDuration {
                        Text("End calculated from the saved duration").foregroundStyle(.secondary)
                    }
                    if nap.source != .verifiedObservation {
                        Text("Unverified recording").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("daytimeReview.nap.\(index)")
                Button(nap.isOngoing ? "Record nap end" : "Edit nap") { editNap(nap) }
                    .accessibilityIdentifier("daytimeReview.nap.\(index).edit")
            }
            Button("Add nap") {
                refresh()
                guard let current = model.inspection, current.morning != nil else { return }
                editor = .nap(nil, day: current.morning?.time ?? current.day)
            }
            .accessibilityIdentifier("daytimeReview.addNap")
        }
    }

    @ViewBuilder
    private func answerSection(_ inspection: DaytimeCoverageInspection) -> some View {
        if let review = model.review {
            Section("Daytime answer") {
                answerButton(review.naps.isEmpty ? "There were no naps" : "All naps are recorded",
                             answer: .allNapsRecorded, identifier: "daytimeReview.complete")
                answerButton("Recording is incomplete", answer: .notAllNapsRecorded, identifier: "daytimeReview.incomplete")
                Button(model.feedback == .saveFailed ? "Retry save" : "Save review") { write(withdrawing: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave || isWriting)
                    .accessibilityIdentifier("daytimeReview.save")
                if model.canWithdraw {
                    Button(inspection.status == .confirmed ? "Withdraw confirmation" : "Withdraw saved answer",
                           role: .destructive) { showWithdrawal = true }
                        .disabled(isWriting)
                        .accessibilityIdentifier("daytimeReview.withdraw")
                }
            }
        } else if inspection.blocker == nil {
            Section {
                Button(model.feedback == .preparationFailed ? "Retry opening review" : "Review these records") {
                    model.startAgain(at: Date(), calendar: .current)
                }
                .accessibilityIdentifier("daytimeReview.reopen")
            }
        }
        Section {
            Button("Choose another date") {
                date = inspection.day
                model.deferReview()
            }
            .disabled(isWriting)
        }
    }

    private func answerButton(_ title: LocalizedStringKey, answer: ParentDaytimeAttestation,
                              identifier: String) -> some View {
        let selected = model.selection == answer
        return Button {
            model.choose(answer)
        } label: {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .disabled(isWriting)
    }

    private func feedbackText(_ feedback: DaytimeCoverageReviewModel.Feedback) -> some View {
        let message: LocalizedStringKey
        switch feedback {
        case .preparationFailed: message = "Couldn’t open the review. Try again."
        case .changed: message = "The evidence or saved answer changed. Review the current records again."
        case .calendarChanged: message = "The calendar or time zone changed. Choose the review date again."
        case .saved: message = "Daytime answer saved."
        case .saveFailed: message = "Couldn’t verify the save. Check the current status and try again."
        case .withdrawn: message = "Daytime answer withdrawn."
        case .withdrawalFailed: message = "Couldn’t verify withdrawal. Check the current status and try again."
        }
        return Text(message)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("daytimeReview.feedback")
            .accessibilityFocused($feedbackFocused)
    }

    private var dateStyle: Date.FormatStyle {
        .init(date: .long, time: .omitted, locale: .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    private var timestampStyle: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .current, calendar: calendar, timeZone: calendar.timeZone)
            .year().month(.abbreviated).day().hour().minute().timeZone(.localizedGMT(.short))
    }

    private func appear() {
        if appeared {
            refresh()
            return
        }
        appeared = true
        if let initialDay, DaytimeReviewWindow.capture(initialCalendar) == calendar,
           calendar.startOfDay(for: initialDay) <= latestPastDate {
            date = initialDay
            start()
        }
    }

    private func start() {
        refresh()
        model.start(day: date, at: Date(), calendar: calendar)
    }

    private func refresh() {
        let now = Date()
        let current = DaytimeReviewWindow.capture(.current)
        model.refresh(at: now, calendar: current)
        latestPastDate = current.startOfDay(for: now).addingTimeInterval(-1)
        if current != calendar || date > latestPastDate {
            date = current.startOfDay(for: latestPastDate)
        }
        calendar = current
    }

    private func editNap(_ nap: DaytimeCoverageReview.Nap) {
        refresh()
        let matches = SleepRecordPersistence().load()?.filter { $0.id == nap.id } ?? []
        guard model.inspection?.naps.contains(nap) == true, matches.count == 1, let record = matches.first,
              record.kind == .dayNap, record.date == nap.start, record.observedEnd == nap.end,
              record.isOngoing == nap.isOngoing else {
            recordChanged = true
            return
        }
        editor = .nap(record, day: record.date)
    }

    private func write(withdrawing: Bool) {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        let now = Date()
        if withdrawing { model.withdraw(at: now, calendar: .current) }
        else { model.save(at: now, calendar: .current) }
    }
}
