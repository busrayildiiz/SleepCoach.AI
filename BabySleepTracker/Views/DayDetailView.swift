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

    @State private var showHistoricalWake = false
    @State private var showAddMenu = false
    @State private var recordingSheet: RecordingSheet?
    @State private var contextNap: SleepRecord? = nil
    @State private var showNapActions = false
    @StateObject private var orchestrator = SleepCoachOrchestrator.shared


    @Environment(\.dismiss) private var dismiss

    @State private var cal = Calendar.current
    @State private var now = Date()

    // MARK: - Derived

    private var sortedNaps: [SleepRecord] {
        records.filter { $0.kind == .dayNap }.sorted { $0.date < $1.date }
    }

    private var nightSleep: SleepRecord? {
        records.filter { $0.kind == .nightSleep }.sorted { $0.date < $1.date }.first
    }

    private var breaks: [SleepRecord] {
        records.filter { $0.kind == .break }.sorted { $0.date < $1.date }
    }

    private var wakeEvidence: DayDetailWakeEvidence {
        DayDetailWakeEvidence(records: DailyWakeRecordPersistence().load() ?? [], day: day, calendar: cal, now: now)
    }

    private var wakeUpTime: Date? {
        if case .recorded(let time) = wakeEvidence { return time }
        return nil
    }

    private var accounting: SleepAccounting {
        SleepAccounting(records: SleepRecordPersistence().load() ?? records, now: now, calendar: cal)
    }

    private var isToday: Bool { cal.isDate(day, inSameDayAs: now) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    let summary = accounting.completedSubtotal(on: day)
                    Text("Sleep Day: " + summary.display)
                        .font(.subheadline)
                    if cal.startOfDay(for: day) < cal.startOfDay(for: now) {
                        Button("Review Morning Wake") { showHistoricalWake = true }
                            .accessibilityIdentifier("history.wake.review")
                    }
                    daytimeReviewLink
                    allCards
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(dayTitle)
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
            .sheet(isPresented: $showHistoricalWake) {
                let initialDay = isToday ? cal.date(byAdding: .day, value: -1, to: day) ?? day : day
                HistoricalWakeEditor(day: initialDay, calendar: cal) { savedDay, calendar in
                    day = savedDay
                    cal = calendar
                    now = Date()
                    records = SleepAccounting(records: SleepRecordPersistence().load() ?? [],
                                              now: now, calendar: calendar).records(on: savedDay)
                }
            }
            .fullScreenCover(item: $recordingSheet) { destination in
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
            .onReceive(NotificationCenter.default.publisher(for: .dailyWakeRecordsDidChange)) { _ in
                now = Date()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in
                now = Date()
                if let saved = SleepRecordPersistence().load() {
                    records = SleepAccounting(records: saved, now: now, calendar: cal).records(on: day)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in now = Date() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in now = Date() }
        }
        .tint(Color(red: 0.45, green: 0.35, blue: 0.92))
    }

    private var daytimeReviewLink: some View {
        let historical = cal.startOfDay(for: day) < cal.startOfDay(for: now)
        let title: LocalizedStringKey = historical ? "Review daytime recording" : "Review a past day"
        return NavigationLink {
            DaytimeCoverageReviewView(initialDay: historical ? day : nil, initialCalendar: cal, onRecordSaved: onRecordUpsert)
        } label: {
            Label(title, systemImage: "checklist")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(RecordingColor.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .foregroundStyle(RecordingColor.accent)
        .accessibilityIdentifier("daytimeReview.open")
    }

    // MARK: - All Cards (kronolojik)
    @ViewBuilder
    private var allCards: some View {
        switch wakeEvidence {
        case .recorded(let time):
            WakeUpCard(time: time)
        case .missing:
            if isToday {
                WakeUpPlaceholderCard()
            } else {
                Text("No morning wake recorded")
                    .foregroundStyle(.secondary)
            }
        case .ambiguous:
            VStack(alignment: .leading, spacing: 4) {
                Text("Conflicting morning wakes").font(.headline)
                Text("Multiple wakes are recorded for this date. Resolve the duplicates before confirming a morning wake.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("history.day.wake.ambiguous")
        }

        // Devam eden night sleep varsa (dünden kalan) önce göster
        if let night = nightSleep, night.isOngoing,
           !cal.isDate(night.date, inSameDayAs: day) {
            NightSleepCard(
                night: night,
                napBreaks: breaks.filter { $0.parentNapID == night.id },
                accounting: accounting,
                onAddBreakTap: { recordingSheet = .awakeBreak(night) },
                onEditTap: { recordingSheet = .sleep(editing: night, date: night.date) },
                onLongPress: { contextNap = night; showNapActions = true }
            )
        }

        // 2. Gerçek naplar
        ForEach(Array(sortedNaps.enumerated()), id: \.element.id) { index, nap in
            let napBreaks = breaks.filter { $0.parentNapID == nap.id }
            NapDetailCard(
                napNumber: index + 1,
                nap: nap,
                napBreaks: napBreaks,
                accounting: accounting,
                onAddBreakTap: { recordingSheet = .awakeBreak(nap) },
                onEditTap: { recordingSheet = .sleep(editing: nap, date: nap.date) },
                onLongPress: { contextNap = nap; showNapActions = true }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { onDelete([nap.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }

        if isToday, let snapshot = orchestrator.snapshot, !snapshot.hasCurrentSleep,
           snapshot.nextSleepKind == .nap, let next = snapshot.daytime.recommendation.value {
            PredictedNapCard(napNumber: sortedNaps.count + 1, predictedTime: next,
                             expectedDuration: snapshot.daytime.expectedDurationMinutes, source: snapshot.daytime.source)
        }

        // 4. Night sleep (bugün girilmiş, tamamlanmış veya live)
        if let night = nightSleep, cal.isDate(night.date, inSameDayAs: day) {
            NightSleepCard(
                night: night,
                napBreaks: breaks.filter { $0.parentNapID == night.id },
                accounting: accounting,
                onAddBreakTap: { recordingSheet = .awakeBreak(night) },
                onEditTap: { recordingSheet = .sleep(editing: night, date: night.date) },
                onLongPress: { contextNap = night; showNapActions = true }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { onDelete([night.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else if isToday, nightSleep == nil, let snapshot = orchestrator.snapshot, !snapshot.hasCurrentSleep,
                  let bedtime = snapshot.night.recommendation.value {
            PredictedBedtimeCard(bedtime: bedtime, source: snapshot.night.source)
        }
    }

    private var dayTitle: String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.day().month(.abbreviated))
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
struct WakeUpPlaceholderCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.85, blue: 0.3).opacity(0.2))
                    .frame(width: 48, height: 48)
                Circle()
                    .strokeBorder(
                        Color(red: 1.0, green: 0.75, blue: 0.2).opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "sunrise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Wake Up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.38, blue: 0.0).opacity(0.5))
                Text("Add today's wake-up time for better predictions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.7))
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 1.0, green: 0.96, blue: 0.78).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.78, blue: 0.2).opacity(0.25), lineWidth: 1)
        )
        .opacity(0.7)
    }
}
// MARK: - Predicted Nap Card

struct PredictedNapCard: View {
    let napNumber: Int
    let predictedTime: Date
    let expectedDuration: Int
    var source: SleepPlanningSource = .recordedEstimate

    private let purple = Color(red: 0.55, green: 0.45, blue: 0.96)

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(purple.opacity(0.10))
                    .frame(width: 48, height: 48)
                Circle()
                    .strokeBorder(
                        purple.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "moon.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(purple.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Nap \(napNumber)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(.label).opacity(0.5))
                    estimatedBadge
                }
                Text("~\(ampm(predictedTime)) · \(TimeFormat.minutes(expectedDuration)) expected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.7))
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(purple.opacity(0.2), lineWidth: 1)
        )
        .opacity(0.75)
    }

    private var estimatedBadge: some View {
        Text(source == .routine ? "Routine" : "Estimated")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(.systemGroupedBackground))
                    .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
            )
    }

    private func ampm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Night Sleep Card

struct NightSleepCard: View {
    let night: SleepRecord
    let napBreaks: [SleepRecord]
    let accounting: SleepAccounting
    let onAddBreakTap: () -> Void
    let onEditTap: () -> Void
    let onLongPress: () -> Void

    @State private var breaksExpanded = false

    private let deepPurple = Color(red: 0.28, green: 0.18, blue: 0.68)
    private let midPurple  = Color(red: 0.38, green: 0.28, blue: 0.78)

    private var netMinutes: Int? { accounting.completedMinutes(sleepIDs: [night.id]) }
    private var observedEnd: Date? { night.completedEnd(at: accounting.now) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [midPurple, deepPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .shadow(color: deepPurple.opacity(0.5), radius: 8, x: 0, y: 4)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Night Sleep")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1.0))
                    Text(ampm(night.date) + (observedEnd.map { " – \(ampm($0))" } ?? " · End unconfirmed"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if netMinutes == nil {
                        Text(observedEnd == nil ? "End unconfirmed" : "Net sleep unknown")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    } else if let netMinutes {
                        Text(TimeFormat.minutes(netMinutes))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1.0))
                        Text("Net sleep")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture(perform: onEditTap)
            .accessibilityAction(named: Text("Edit Sleep"), onEditTap)
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress()
            }

            if !napBreaks.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.horizontal, 16)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { breaksExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Wake periods (\(napBreaks.count))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                        Spacer()
                        Image(systemName: breaksExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if breaksExpanded {
                    ForEach(napBreaks) { br in
                        HStack {
                            Text(ampm(br.date))
                                .font(.subheadline)
                                .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1.0))
                                .monospacedDigit()
                            Spacer()
                            Text(br.completedEnd(at: accounting.now)
                                .map { TimeFormat.minutes(Int($0.timeIntervalSince(br.date) / 60)) } ?? "End unconfirmed")
                                .font(.subheadline)
                                .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.15))
                .padding(.horizontal, 16)

            Button(action: onAddBreakTap) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    Text("Add Awake Break").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sleep.addBreak.\(night.id)")
            .padding(.horizontal, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.12, blue: 0.42),
                            Color(red: 0.12, green: 0.08, blue: 0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(midPurple.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: deepPurple.opacity(0.3), radius: 12, x: 0, y: 6)
    }

    private func ampm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Predicted Bedtime Card

struct PredictedBedtimeCard: View {
    let bedtime: Date
    var source: SleepPlanningSource = .recordedEstimate

    private let deepPurple = Color(red: 0.28, green: 0.18, blue: 0.68)
    private let midPurple  = Color(red: 0.38, green: 0.28, blue: 0.78)

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(deepPurple.opacity(0.12))
                    .frame(width: 48, height: 48)
                Circle()
                    .strokeBorder(
                        deepPurple.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(deepPurple.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Bedtime")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(.label).opacity(0.45))
                    estimatedBadge
                }
                Text(source == .routine ? ampm(bedtime) : "~\(ampm(bedtime)) estimated")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.6))
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.12, blue: 0.42).opacity(0.25),
                            Color(red: 0.12, green: 0.08, blue: 0.32).opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(deepPurple.opacity(0.2), lineWidth: 1)
        )
        .opacity(0.75)
    }

    private var estimatedBadge: some View {
        Text(source == .routine ? "Routine" : "Estimated")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(.systemGroupedBackground))
                    .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
            )
    }

    private func ampm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - NapDetailCard

struct NapDetailCard: View {
    let napNumber: Int
    let nap: SleepRecord
    let napBreaks: [SleepRecord]
    let accounting: SleepAccounting
    let onAddBreakTap: () -> Void
    let onEditTap: () -> Void
    let onLongPress: () -> Void

    @State private var breaksExpanded = true

    private let purple     = Color(red: 0.55, green: 0.45, blue: 0.96)
    private let deepPurple = Color(red: 0.35, green: 0.25, blue: 0.80)

    private var isNight: Bool { nap.kind == .nightSleep }
    private var napTint: Color { nap.isOngoing ? purple : (isNight ? deepPurple : purple) }
    private var netMinutes: Int? { accounting.completedMinutes(sleepIDs: [nap.id]) }
    private var napEnd: Date? { nap.completedEnd(at: accounting.now) }
    private var title: String { isNight ? "Night Sleep" : "Nap \(napNumber)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(napTint.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: nap.kind.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(napTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(napTint)
                    Text(TimeFormat.ampm(nap.date) + (napEnd.map { " – \(TimeFormat.ampm($0))" } ?? " · End unconfirmed"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if netMinutes == nil {
                        Text(napEnd == nil ? "End unconfirmed" : "Net sleep unknown")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(napTint)
                    } else if let netMinutes {
                        Text(TimeFormat.minutes(netMinutes))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("Net sleep")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onEditTap)
            .accessibilityAction(named: Text("Edit Sleep"), onEditTap)
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress()
            }

            Divider().padding(.horizontal, 14)

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("\(napBreaks.count)")
                        .font(.title2.weight(.bold)).foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text("Breaks").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 36)

                VStack(spacing: 2) {
                    if let netMinutes {
                        Text(TimeFormat.minutes(netMinutes))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                            .accessibilityIdentifier("sleep.netSleep.\(nap.id)")
                        Text("Net Sleep").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Net sleep unknown").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sleep.netSleepUnknown.\(nap.id)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)

            if !napBreaks.isEmpty {
                Divider().padding(.horizontal, 14)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { breaksExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Breaks (Wake Periods)").font(.subheadline).foregroundStyle(.primary)
                        Spacer()
                        Text("\(napBreaks.count)")
                            .font(.caption.weight(.semibold)).foregroundStyle(napTint)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(napTint.opacity(0.10)))
                        Image(systemName: breaksExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if breaksExpanded {
                    ForEach(napBreaks) { br in
                        HStack {
                            Text(TimeFormat.ampm(br.date)).font(.subheadline).foregroundStyle(.primary).monospacedDigit()
                            Spacer()
                            Text(br.completedEnd(at: accounting.now)
                                .map { TimeFormat.minutes(Int($0.timeIntervalSince(br.date) / 60)) } ?? "End unconfirmed")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if br.id != napBreaks.last?.id { Divider().padding(.leading, 14) }
                    }
                }
            }

            Divider().padding(.horizontal, 14)

            Button(action: onAddBreakTap) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    Text("Add Awake Break").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(napTint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sleep.addBreak.\(nap.id)")
            .padding(.horizontal, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(napTint.opacity(0.15), style: StrokeStyle(lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}
