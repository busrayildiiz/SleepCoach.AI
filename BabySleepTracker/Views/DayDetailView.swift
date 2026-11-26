import Combine
import SwiftUI

enum AddMode {
    case sleep
    case `break`
}

struct DayDetailView: View {
    @State var day: Date
    @State var records: [SleepRecord]

    let onDelete: (_ ids: Set<UUID>) -> Void
    let onRecordUpsert: (SleepRecord) -> Bool
    let onBreakSaved: (_ newBreak: SleepRecord) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var showHistoricalWake = false
    @State private var showAddMenu = false
    @State private var recordingSheet: RecordingSheet?
    @State private var contextNap: SleepRecord?
    @State private var showNapActions = false
    @StateObject private var orchestrator = SleepCoachOrchestrator.shared
    @State private var cal = Calendar.current
    @State private var now = Date()

    private var isToday: Bool { cal.isDate(day, inSameDayAs: now) }
    private var isHistorical: Bool { cal.startOfDay(for: day) < cal.startOfDay(for: now) }

    var body: some View {
        let snapshot = TrustedObservationAdapter(defaults: SecureDataStore.shared)
            .snapshot(includeDaytime: false, calendar: cal)
        let observations = DayDetailObservationProjection(snapshot: snapshot)
        let accounting = SleepAccounting(records: snapshot.sleeps.map(\.record), now: now, calendar: cal)
        let displayed = snapshot.storageIsReadable ? displayedRecords(accounting) : []
        let breaks = displayed.filter { $0.kind == .break }
        let sleeps = displayed.filter { $0.kind != .break }
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dateHeader
                    recordedSummary(accounting.completedSubtotal(on: day), readable: snapshot.storageIsReadable)
                    morningWake(observations.wake(on: day, at: now, calendar: cal))
                    sleepRecords(sleeps, breaks: breaks, accounting: accounting, observations: observations)
                    planningSuggestions(hasNight: (snapshot.storageIsReadable ? sleeps : records)
                        .contains { $0.kind == .nightSleep })
                    daytimeReviewLink
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("history.day.scroll")
            .foregroundStyle(RecordingColor.ink)
            .background(RecordingColor.background.ignoresSafeArea())
            .toolbarBackground(RecordingColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Day detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddMenu = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                    .accessibilityIdentifier("history.day.add")
                }
            }
            .confirmationDialog("Add", isPresented: $showAddMenu, titleVisibility: .hidden) {
                Button("Add Nap") { recordingSheet = .sleep(editing: nil, date: day) }
                if isToday {
                    Button("Record Historical Morning Wake") { showHistoricalWake = true }
                        .accessibilityIdentifier("history.wake.open")
                }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog(
                contextNap.map { $0.kind == .nightSleep ? "Night Sleep" : "Nap" } ?? "",
                isPresented: $showNapActions,
                titleVisibility: .visible
            ) {
                Button("Edit") {
                    if let nap = contextNap { recordingSheet = .sleep(editing: nap, date: nap.date) }
                }
                Button("Add Awake Break") {
                    if let parent = contextNap { recordingSheet = .awakeBreak(parent) }
                }
                Button("Delete", role: .destructive) {
                    if let nap = contextNap { onDelete([nap.id]) }
                }
                Button("Cancel", role: .cancel) { contextNap = nil }
            }
            .sheet(isPresented: $showHistoricalWake, onDismiss: refreshPresentation) {
                let initialDay = isToday ? cal.date(byAdding: .day, value: -1, to: day) ?? day : day
                HistoricalWakeEditor(day: initialDay, calendar: cal) { savedDay, calendar in
                    day = savedDay
                    cal = calendar
                    now = Date()
                    records = SleepAccounting(records: SleepRecordPersistence().load() ?? [],
                                              now: now, calendar: calendar).records(on: savedDay)
                }
            }
            .fullScreenCover(item: $recordingSheet, onDismiss: refreshPresentation) { destination in
                switch destination {
                case .sleep(let editing, let date):
                    AddRecordView(defaultDate: date, editingRecord: editing,
                                  vm: AddRecordViewModel(), onSave: onRecordUpsert)
                case .awakeBreak(let parent):
                    AddBreakView(parent: parent,
                                 existingBreaks: breaks.filter { $0.parentNapID == parent.id },
                                 records: accounting.records,
                                 onSave: onBreakSaved)
                }
            }
            .onAppear(perform: refreshPresentation)
            .onChange(of: day) { _ in refreshPresentation() }
            .onReceive(observationChanges) { _ in refreshPresentation() }
        }
        .tint(RecordingColor.accent)
    }

    private var observationChanges: some Publisher<Notification, Never> {
        let names: [Notification.Name] = [.observationProvenanceDidChange, .sleepRecordsDidChange, .dailyWakeRecordsDidChange,
                                         .secureDataStoreDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                                         UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification]
        return Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: RunLoop.main)
    }

    private func refreshPresentation() { now = Date() }

    private func displayedRecords(_ accounting: SleepAccounting) -> [SleepRecord] {
        let selected = accounting.records(on: day)
        // Keep a carried ongoing night only when it was supplied by the caller.
        let carriedIDs = Set(records.filter {
            $0.kind == .nightSleep && $0.isOngoing && !cal.isDate($0.date, inSameDayAs: day)
        }.map(\.id))
        let carried = accounting.records.filter {
            carriedIDs.contains($0.id) && $0.kind == .nightSleep && $0.isOngoing &&
                !cal.isDate($0.date, inSameDayAs: day)
        }.sorted { $0.date < $1.date }.first
        let nights = (selected.filter { $0.kind == .nightSleep } + [carried].compactMap { $0 })
            .sorted { $0.date < $1.date }
        let parents = (selected.filter { $0.kind == .dayNap } + Array(nights.prefix(1)))
            .sorted { $0.date < $1.date }
        let parentIDs = Set(parents.map(\.id))
        return parents + accounting.records.filter { record in
            record.kind == .break && record.parentNapID.map(parentIDs.contains) == true
        }.sorted { $0.date < $1.date }
    }

    private var dateFormat: Date.FormatStyle {
        .init(date: .omitted, time: .omitted, locale: .current, calendar: cal, timeZone: cal.timeZone)
    }
    private var shortDate: Date.FormatStyle { dateFormat.day().month(.abbreviated) }
    private var fullDate: Date.FormatStyle { shortDate.weekday(.abbreviated).year() }
    private var timeFormat: Date.FormatStyle { dateFormat.hour().minute() }

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isToday {
                    Text("Today · \(day.formatted(shortDate))")
                        .accessibilityLabel(Text("Today, \(day.formatted(fullDate))"))
                } else {
                    Text(day, format: fullDate)
                        .accessibilityLabel(Text(day.formatted(fullDate)))
                }
            }
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("history.day.date")
            Text("Sleep Day · \(day.formatted(dateFormat.timeZone(.localizedGMT(.short))))")
                .font(.footnote)
                .foregroundStyle(RecordingColor.secondary)
        }
    }

    private func recordedSummary(_ subtotal: CompletedRecordedSubtotal, readable: Bool) -> some View {
        let amount = readable ? subtotal.minutes.map(TimeFormat.minutes) : nil
        let value: String
        if !readable { value = String(localized: "Unavailable") }
        else { value = amount ?? String(localized: "Unknown") }
        let total = Text(value).font(.title.weight(.bold)).monospacedDigit()
        let status = summaryStatus(subtotal, readable: readable)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Recorded sleep").font(.footnote).foregroundStyle(RecordingColor.secondary)
            if dynamicType.isAccessibilitySize {
                total
                status
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { total; Spacer(); status }
                    VStack(alignment: .leading, spacing: 6) { total; status }
                }
            }
            if readable {
                switch subtotal.unavailableReason {
                case .conflict:
                    Text("Review the conflicting sleep records.").font(.footnote).foregroundStyle(RecordingColor.secondary)
                case .unresolvedBreak:
                    Text("An awake break needs a confirmed end.").font(.footnote).foregroundStyle(RecordingColor.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .detailSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.day.summary")
    }

    @ViewBuilder
    private func summaryStatus(_ subtotal: CompletedRecordedSubtotal, readable: Bool) -> some View {
        if !readable {
            Text("Saved sleep records could not be opened.").font(.footnote).foregroundStyle(RecordingColor.secondary)
        } else if subtotal.unavailableReason == .missing {
            Text("No recorded subtotal").font(.footnote).foregroundStyle(RecordingColor.secondary)
        } else if subtotal.isIncomplete {
            Label("Incomplete", systemImage: "minus.circle")
                .font(.footnote)
                .foregroundStyle(ObservationStatusColor.caution)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(ObservationStatusColor.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func morningWake(_ wake: DayDetailObservationProjection.Wake) -> some View {
        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            if !dynamicType.isAccessibilitySize {
                Image(systemName: "sun.max")
                    .font(.body.weight(.medium))
                    .foregroundStyle(RecordingColor.accent)
                    .padding(10)
                    .background(RecordingColor.inset, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if dynamicType.isAccessibilitySize {
                    Label("Morning wake", systemImage: "sun.max")
                        .font(.footnote)
                        .foregroundStyle(RecordingColor.secondary)
                } else {
                    Text("Morning wake").font(.footnote).foregroundStyle(RecordingColor.secondary)
                }
                wakeDescription(wake)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(wake == .ambiguous ? "history.day.wake.ambiguous" : "history.day.wake")

            if isHistorical {
                switch wake {
                case .recorded:
                    historicalWakeButton("Edit", icon: "pencil", spokenLabel: "Edit morning wake")
                case .missing:
                    historicalWakeButton("Record", icon: "plus", spokenLabel: "Record morning wake")
                case .ambiguous, .unavailable:
                    historicalWakeButton("Review", icon: "exclamationmark.circle", spokenLabel: "Review morning wakes")
                }
            }
        }
        .padding(13)
        .detailSurface()
    }

    @ViewBuilder
    private func wakeDescription(_ wake: DayDetailObservationProjection.Wake) -> some View {
        switch wake {
        case .recorded(let time, let verified):
            let value = Text(time, format: timeFormat).font(.title3.weight(.bold)).monospacedDigit()
            let status = Group {
                if verified { verifiedObservation }
                else { Text("Recorded").font(.caption).foregroundStyle(RecordingColor.secondary) }
            }
            if dynamicType.isAccessibilitySize {
                value
                status
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) { value; status }
                    VStack(alignment: .leading, spacing: 4) { value; status }
                }
            }
        case .missing:
            Text("No wake recorded").font(.headline)
            if isToday {
                Text("Add today's wake-up time for better predictions")
                    .font(.footnote)
                    .foregroundStyle(RecordingColor.secondary)
            } else if isHistorical {
                Text("Add the wake time you observed.").font(.footnote).foregroundStyle(RecordingColor.secondary)
            }
        case .ambiguous:
            Text("Conflicting morning wakes").font(.headline).foregroundStyle(ObservationStatusColor.caution)
            Text("Multiple wakes are recorded for this date. Resolve the duplicates before confirming a morning wake.")
                .font(.footnote).foregroundStyle(RecordingColor.secondary)
        case .unavailable:
            Text("Morning wake unavailable").font(.headline)
            Text("Saved observations could not be opened.").font(.footnote).foregroundStyle(RecordingColor.secondary)
        }
    }

    private func historicalWakeButton(_ title: LocalizedStringKey, icon: String, spokenLabel: LocalizedStringKey) -> some View {
        Button { showHistoricalWake = true } label: {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RecordingColor.accent)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityHint(Text(day, format: fullDate))
        .accessibilityIdentifier("history.wake.review")
    }

    private func sleepRecords(_ sleeps: [SleepRecord], breaks: [SleepRecord], accounting: SleepAccounting,
                              observations: DayDetailObservationProjection) -> some View {
        let naps = sleeps.filter { $0.kind == .dayNap }
        let heading = Text("Sleep records").font(.headline).accessibilityAddTraits(.isHeader)
        return VStack(alignment: .leading, spacing: 8) {
            if !sleeps.isEmpty {
                let count = Text(sleeps.count == 1 ? "1 record" : "\(sleeps.count) records")
                    .font(.footnote).foregroundStyle(RecordingColor.secondary)
                if dynamicType.isAccessibilitySize {
                    heading
                    count
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) { heading; Spacer(); count }
                        VStack(alignment: .leading, spacing: 4) { heading; count }
                    }
                }
            } else {
                heading
            }
            if sleeps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if observations.snapshot.storageIsReadable {
                        Text("No sleep records").font(.headline)
                        Text("Use + to add a sleep record.").font(.footnote).foregroundStyle(RecordingColor.secondary)
                    } else {
                        Text("Sleep records unavailable").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .detailSurface()
            } else {
                VStack(spacing: dynamicType.isAccessibilitySize ? 8 : 0) {
                    ForEach(Array(sleeps.enumerated()), id: \.element.id) { index, sleep in
                        if index > 0 && !dynamicType.isAccessibilitySize {
                            Divider().padding(.leading, 43).padding(.trailing, 12)
                        }
                        let napNumber = naps.firstIndex { $0.id == sleep.id }.map { $0 + 1 }
                        sleepRow(sleep, number: napNumber, breaks: breaks.filter { $0.parentNapID == sleep.id },
                                 accounting: accounting, verified: observations.isVerified(sleep))
                            .detailSurface(visible: dynamicType.isAccessibilitySize)
                    }
                }
                .background(alignment: .leading) {
                    if !dynamicType.isAccessibilitySize && sleeps.count > 1 {
                        Rectangle().fill(RecordingColor.border)
                            .frame(width: 1).padding(.leading, 23).padding(.vertical, 26)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
                .detailSurface(visible: !dynamicType.isAccessibilitySize)
                if sleeps.contains(where: { $0.completedEnd(at: now) == nil }) {
                    Text("Sleep with an unconfirmed end is not included in this subtotal.")
                        .font(.footnote).foregroundStyle(RecordingColor.secondary)
                }
                if sleeps.contains(where: { $0.kind == .nightSleep && cal.isDate($0.date, inSameDayAs: day) }) {
                    Text("Night sleep stays with the day it started.")
                        .font(.footnote).foregroundStyle(RecordingColor.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sleepRow(_ sleep: SleepRecord, number: Int?, breaks: [SleepRecord],
                          accounting: SleepAccounting, verified: Bool) -> some View {
        let row = DayDetailSleepRow(record: sleep, napNumber: number, breaks: breaks, accounting: accounting,
                                   verified: verified, timeFormat: timeFormat, dateFormat: shortDate,
                                   onEdit: { recordingSheet = .sleep(editing: sleep, date: sleep.date) },
                                   onBreak: { recordingSheet = .awakeBreak(sleep) },
                                   onActions: { contextNap = sleep; showNapActions = true })
        if sleep.kind == .dayNap || cal.isDate(sleep.date, inSameDayAs: day) {
            row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { onDelete([sleep.id]) } label: { Label("Delete", systemImage: "trash") }
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func planningSuggestions(hasNight: Bool) -> some View {
        if isToday, let snapshot = orchestrator.snapshot, !snapshot.hasCurrentSleep {
            let nap = snapshot.nextSleepKind == .nap ? snapshot.daytime.recommendation.value : nil
            let bedtime = hasNight ? nil : snapshot.night.recommendation.value
            if nap != nil || bedtime != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Planning suggestions").font(.headline).accessibilityAddTraits(.isHeader)
                    DayDetailPlanningSuggestions(nap: nap, napSource: snapshot.daytime.source,
                                                 expectedDuration: snapshot.daytime.expectedDurationMinutes,
                                                 bedtime: bedtime, bedtimeSource: snapshot.night.source,
                                                 timeFormat: timeFormat)
                    Text("Suggestions are not sleep records.").font(.footnote).foregroundStyle(RecordingColor.secondary)
                }
                .accessibilityIdentifier("history.day.planning")
            }
        }
    }

    private var daytimeReviewLink: some View {
        let title: LocalizedStringKey = isHistorical ? "Review daytime recording" : "Review a past day"
        return VStack(spacing: 3) {
            Divider().overlay(RecordingColor.border)
            NavigationLink {
                DaytimeCoverageReviewView(initialDay: isHistorical ? day : nil, initialCalendar: cal, onRecordSaved: onRecordUpsert)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checklist").accessibilityHidden(true)
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                }
                .font(.body)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RecordingColor.accent)
            .accessibilityIdentifier("daytimeReview.open")
        }
    }
}

struct HistoricalWakeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HistoricalWakeDraft
    @State private var selected: Date
    @State private var confirmedSelection: Date?
    @State private var outcome: HistoricalWakeOutcome?
    @State private var cancellationBlocked = false
    @State private var message: String?
    @State private var confirmation: HistoricalWakeConfirmation?
    let fixedDay: Bool
    let onSaved: (Date, Calendar) -> Void
    private let persistence = DailyWakeRecordPersistence()

    init(day: Date, calendar: Calendar, fixedDay: Bool = false, onSaved: @escaping (Date, Calendar) -> Void) {
        self.fixedDay = fixedDay
        self.onSaved = onSaved
        let initial = HistoricalWakeDraft(day: day, calendar: calendar, persistence: .init())
        _draft = State(initialValue: initial)
        let existing = initial.candidates.count == 1 ? initial.candidates.first?.wakeTime : nil
        _selected = State(initialValue: existing.flatMap {
            initial.calendar.isDate($0, inSameDayAs: initial.day) ? $0 : nil
        } ?? initial.day)
    }

    private var saveTitle: LocalizedStringKey {
        if outcome?.canRetry == true { return "Retry Saving Morning Wake" }
        return draft.candidates.isEmpty ? "Record Morning Wake" : "Confirm or Correct Morning Wake"
    }

    @ViewBuilder
    private var wakePicker: some View {
        if fixedDay, let interval = draft.calendar.dateInterval(of: .day, for: draft.day) {
            let lastInstant = Date(timeIntervalSinceReferenceDate: interval.end.timeIntervalSinceReferenceDate.nextDown)
            let style = Date.FormatStyle(date: .long, time: .omitted, calendar: draft.calendar, timeZone: draft.calendar.timeZone)
            Text(draft.day, format: style)
                .accessibilityAddTraits(.isHeader)
            DatePicker("Observed wake time", selection: $selected, in: draft.day...lastInstant,
                       displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("history.wake.dateTime")
        } else {
            DatePicker("Observed wake date and time", selection: $selected,
                       in: ...draft.calendar.startOfDay(for: Date()).addingTimeInterval(-1))
                .accessibilityIdentifier("history.wake.dateTime")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                wakePicker
                    .disabled(cancellationBlocked || outcome?.blocksEditing == true)
                    .onChange(of: selected) { value in
                        confirmedSelection = nil
                        message = nil
                        if confirmation != nil || !draft.calendar.isDate(value, inSameDayAs: draft.day) {
                            guard draft.abandon() else {
                                cancellationBlocked = true
                                message = "Cancellation could not be saved. Try again."
                                return
                            }
                            confirmation = nil
                            draft = HistoricalWakeDraft(day: fixedDay ? draft.day : value,
                                                       calendar: draft.calendar, persistence: persistence)
                        }
                    }

                if draft.candidates.count > 1 {
                    Text(LocalizedStringKey(HistoricalWakeOutcome.ambiguous.message))
                        .accessibilityIdentifier("history.wake.duplicate")
                } else {
                    if let wake = draft.candidates.first {
                        LabeledContent("Recorded wake", value: wake.wakeTime.formatted(.dateTime.hour().minute()))
                    }
                    Toggle("I observed this morning wake", isOn: Binding(
                        get: { confirmedSelection == selected },
                        set: { confirmedSelection = $0 ? selected : nil }
                    ))
                        .accessibilityIdentifier("history.wake.confirmation")
                        .disabled(cancellationBlocked || outcome?.blocksEditing == true)
                    Button(saveTitle, action: save)
                        .disabled(confirmedSelection != selected || cancellationBlocked ||
                                  (outcome?.blocksEditing == true && outcome?.canRetry != true))
                        .accessibilityIdentifier("history.wake.save")
                }
                if let message { Text(LocalizedStringKey(message)).accessibilityIdentifier("history.wake.feedback") }
            }
            .environment(\.calendar, draft.calendar)
            .environment(\.timeZone, draft.calendar.timeZone)
            .navigationTitle("Historical Morning Wake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft.abandon() { dismiss() }
                        else {
                            cancellationBlocked = true
                            message = "Cancellation could not be saved. Try Cancel again."
                        }
                    }.accessibilityIdentifier("history.wake.cancel")
                }
            }
        }
        .interactiveDismissDisabled(cancellationBlocked || outcome?.blocksEditing == true)
    }

    private func save() {
        let workflow = SleepWakeTimeWorkflow(selectedWakeTime: selected, now: Date(), calendar: draft.calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: persistence, sleepPersistence: .init())
        guard confirmedSelection == selected, !cancellationBlocked,
              outcome?.blocksEditing != true || outcome?.canRetry == true else { return }
        let capture = confirmation ?? draft.confirmObservedWake(at: selected)
        confirmation = capture
        let result = workflow.recoverHistoricalWake(draft, confirmation: capture)
        outcome = result
        if result == .saved {
            onSaved(draft.day, draft.calendar)
            dismiss()
        } else {
            if !result.blocksEditing {
                guard draft.abandon() else {
                    cancellationBlocked = true
                    message = "Cancellation could not be saved. Try again."
                    return
                }
                draft = HistoricalWakeDraft(day: fixedDay ? draft.day : selected,
                                           calendar: draft.calendar, persistence: persistence)
                confirmation = nil
                confirmedSelection = nil
            }
            message = result.message
        }
    }
}

// MARK: - Wake Up Card

struct WakeUpCard: View {
    let time: Date

    var body: some View {
        HStack(spacing: 14) {
            // İkon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.85, blue: 0.3),
                                Color(red: 1.0, green: 0.65, blue: 0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .shadow(color: Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.4),
                            radius: 8, x: 0, y: 4)
                Image(systemName: "sunrise.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Wake Up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.38, blue: 0.0))
                Text(ampm(time))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.72, green: 0.50, blue: 0.0))
            }

            Spacer()

            Text("Good morning! ☀️")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.72, green: 0.50, blue: 0.0).opacity(0.8))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.96, blue: 0.78),
                            Color(red: 1.0, green: 0.90, blue: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.78, blue: 0.2).opacity(0.5), lineWidth: 1)
        )
    }

    private func ampm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

/// Read-only projection of one evidence snapshot. Verification follows record identity and revision.
struct DayDetailObservationProjection {
    enum Wake: Equatable {
        case unavailable, missing, ambiguous, recorded(Date, verified: Bool)
    }

    let snapshot: LearningEvidenceSnapshot

    func wake(on day: Date, at now: Date, calendar: Calendar) -> Wake {
        guard snapshot.storageIsReadable else { return .unavailable }
        let records = snapshot.wakes.map(\.record)
        switch DayDetailWakeEvidence(records: records, day: day, calendar: calendar, now: now) {
        case .ambiguous: return .ambiguous
        case .missing: return .missing
        case .recorded(let time):
            guard let observed = DailyWakeRecord.uniqueObservation(in: records, on: day, at: now, calendar: calendar)
            else { return .missing }
            let matches = snapshot.wakes.filter { $0.record.id == observed.id }
            guard matches.count == 1, !snapshot.sleeps.contains(where: { $0.record.id == observed.id }) else {
                return .ambiguous
            }
            return .recorded(time, verified: matches[0].source == .verifiedObservation)
        }
    }

    func isVerified(_ record: SleepRecord) -> Bool {
        guard snapshot.storageIsReadable,
              !snapshot.wakes.contains(where: { $0.record.id == record.id }) else { return false }
        let matches = snapshot.sleeps.filter { $0.record.id == record.id }
        return matches.count == 1 && matches[0].source == .verifiedObservation &&
            SleepRecordVersion(record).matches(matches[0].record)
    }
}

private struct DayDetailSleepRow: View {
    let record: SleepRecord
    let napNumber: Int?
    let breaks: [SleepRecord]
    let accounting: SleepAccounting
    let verified: Bool
    let timeFormat: Date.FormatStyle
    let dateFormat: Date.FormatStyle
    let onEdit: () -> Void
    let onBreak: () -> Void
    let onActions: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var breaksExpanded: Bool

    init(record: SleepRecord, napNumber: Int?, breaks: [SleepRecord], accounting: SleepAccounting,
         verified: Bool, timeFormat: Date.FormatStyle, dateFormat: Date.FormatStyle,
         onEdit: @escaping () -> Void, onBreak: @escaping () -> Void, onActions: @escaping () -> Void) {
        self.record = record
        self.napNumber = napNumber
        self.breaks = breaks
        self.accounting = accounting
        self.verified = verified
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
        self.onEdit = onEdit
        self.onBreak = onBreak
        self.onActions = onActions
        _breaksExpanded = State(initialValue: record.kind == .dayNap)
    }

    private var title: String {
        napNumber.map { String(localized: "Nap \($0)") } ?? String(localized: "Night sleep")
    }
    private var end: Date? { record.completedEnd(at: accounting.now) }
    private var netMinutes: Int? { accounting.completedMinutes(sleepIDs: [record.id]) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if !dynamicType.isAccessibilitySize { marker }
            VStack(alignment: .leading, spacing: 2) {
                if dynamicType.isAccessibilitySize {
                    description
                    editButton
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        description
                        editButton
                    }
                }
                rowActions
                if breaksExpanded {
                    ForEach(breaks) { record in
                        Divider()
                        breakRow(record)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var marker: some View {
        Group {
            if let napNumber { Text("\(napNumber)").font(.caption2.weight(.semibold)) }
            else { Image(systemName: "moon.fill").font(.caption) }
        }
        .foregroundStyle(RecordingColor.accent)
        .padding(5)
        .frame(minWidth: 22, minHeight: 22)
        .background(RecordingColor.inset, in: Circle())
        .background(RecordingColor.background, in: Circle())
        .padding(.top, 3)
        .accessibilityHidden(true)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                if dynamicType.isAccessibilitySize {
                    Text(title).font(.subheadline).foregroundStyle(RecordingColor.secondary)
                    timeRange
                    if verified { verifiedObservation }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) {
                            timeRange
                            if verified { verifiedObservation }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            timeRange
                            if verified { verifiedObservation }
                        }
                    }
                }
                if end == nil {
                    Text(dynamicType.isAccessibilitySize ? "End unconfirmed" : "\(title) · End unconfirmed")
                        .font(.subheadline)
                        .foregroundStyle(ObservationStatusColor.caution)
                }
                if let end, !accounting.calendar.isDate(end, inSameDayAs: record.date) {
                    Text("Ends \(end.formatted(dateFormat))").font(.footnote).foregroundStyle(RecordingColor.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onActions()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("history.sleep.record.\(record.id)")
            .accessibilityAction(named: Text("Actions for \(title)"), onActions)
            if let netMinutes {
                Text(dynamicType.isAccessibilitySize ? "\(TimeFormat.minutes(netMinutes)) net sleep" :
                        "\(title) · \(TimeFormat.minutes(netMinutes)) net sleep")
                    .font(.subheadline)
                    .foregroundStyle(RecordingColor.secondary)
                    .accessibilityIdentifier("sleep.netSleep.\(record.id)")
            } else {
                Text("Net sleep unknown")
                    .font(.subheadline)
                    .foregroundStyle(RecordingColor.secondary)
                    .accessibilityIdentifier("sleep.netSleepUnknown.\(record.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var timeRange: some View {
        let start = record.date.formatted(timeFormat)
        if let end {
            Text("\(start)–\(end.formatted(timeFormat))")
                .font(.headline).monospacedDigit()
        } else {
            Text("Started \(start)").font(.headline).monospacedDigit()
        }
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Text(dynamicType.isAccessibilitySize ? (napNumber == nil ? "Edit night sleep" : "Edit nap") : "Edit")
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44, alignment: dynamicType.isAccessibilitySize ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RecordingColor.accent)
        .accessibilityLabel("Edit \(title)")
        .accessibilityHint(Text(record.date, format: dateFormat))
        .accessibilityIdentifier("history.sleep.edit.\(record.id)")
    }

    private var rowActions: some View {
        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(action: onBreak) {
                Text("Add awake break")
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RecordingColor.accent)
            .accessibilityLabel("Add awake break to \(title)")
            .accessibilityHint(Text(record.date, format: dateFormat))
            .accessibilityIdentifier("sleep.addBreak.\(record.id)")
            if !breaks.isEmpty {
                if !dynamicType.isAccessibilitySize { Spacer(minLength: 0) }
                Button {
                    breaksExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(breaks.count == 1 ? "1 awake break" : "\(breaks.count) awake breaks")
                        Image(systemName: breaksExpanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }
                    .font(.footnote)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(RecordingColor.secondary)
                .accessibilityValue(breaksExpanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private func breakRow(_ record: SleepRecord) -> some View {
        let time = Text(record.date, format: timeFormat).monospacedDigit()
        let minutes = record.completedEnd(at: accounting.now).flatMap { end in
            Int(exactly: (end.timeIntervalSince(record.date) / 60).rounded(.down))
        }
        let duration = Text(minutes.map { String(localized: "\(TimeFormat.minutes($0)) awake") }
                            ?? String(localized: "End unconfirmed"))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { time; Spacer(); duration }
            VStack(alignment: .leading, spacing: 4) { time; duration }
        }
        .font(.footnote)
        .foregroundStyle(RecordingColor.secondary)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct DayDetailPlanningSuggestions: View {
    let nap: Date?
    let napSource: SleepPlanningSource
    let expectedDuration: Int
    let bedtime: Date?
    let bedtimeSource: SleepPlanningSource
    let timeFormat: Date.FormatStyle

    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Group {
            if let nap, let bedtime {
                if dynamicType.isAccessibilitySize {
                    stacked(nap, bedtime)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            napSuggestion(nap)
                            Divider()
                            bedtimeSuggestion(bedtime)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        stacked(nap, bedtime)
                    }
                }
            } else if let nap {
                napSuggestion(nap)
            } else if let bedtime {
                bedtimeSuggestion(bedtime)
            }
        }
        .padding(14)
        .detailSurface()
    }

    private func stacked(_ nap: Date, _ bedtime: Date) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            napSuggestion(nap)
            Divider()
            bedtimeSuggestion(bedtime)
        }
    }

    private func napSuggestion(_ nap: Date) -> some View {
        suggestion("Next nap", icon: "sun.max", time: nap, source: napSource, duration: expectedDuration > 0 ? expectedDuration : nil)
    }

    private func bedtimeSuggestion(_ bedtime: Date) -> some View {
        suggestion("Bedtime", icon: "moon.fill", time: bedtime, source: bedtimeSource)
    }

    private func suggestion(_ title: LocalizedStringKey, icon: String, time: Date,
                            source: SleepPlanningSource, duration: Int? = nil) -> some View {
        let sourceChip = Text(source == .routine ? "Routine" : "Estimated")
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RecordingColor.inset, in: RoundedRectangle(cornerRadius: 7))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(RecordingColor.accent).accessibilityHidden(true)
                Text(title)
            }
            .font(.subheadline)
            .foregroundStyle(RecordingColor.secondary)
            Text(time, format: timeFormat).font(.title2.weight(.bold)).monospacedDigit()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sourceChip
                    if let duration { Text("~\(TimeFormat.minutes(duration))") }
                }
                VStack(alignment: .leading, spacing: 4) {
                    sourceChip
                    if let duration { Text("~\(TimeFormat.minutes(duration))") }
                }
            }
            .font(.caption)
            .foregroundStyle(RecordingColor.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private var verifiedObservation: some View {
    Label("Verified", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(ObservationStatusColor.verified)
}

private extension View {
    @ViewBuilder
    func detailSurface(visible: Bool = true) -> some View {
        if visible {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            background(RecordingColor.surface, in: shape)
                .overlay(shape.strokeBorder(RecordingColor.border, lineWidth: 1).allowsHitTesting(false))
        } else {
            self
        }
    }
}
