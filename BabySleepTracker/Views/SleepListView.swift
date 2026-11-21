//
//  SleepListView.swift
//  BabySleepTracker
//

import SwiftUI
import Foundation

final class SleepGenerationCoalescer: ObservableObject {
    private var isGenerationPending = false
    private let schedule: (@escaping () -> Void) -> Void

    init(schedule: @escaping (@escaping () -> Void) -> Void = { action in
        DispatchQueue.main.async(execute: action)
    }) {
        self.schedule = schedule
    }

    func request(_ generation: @escaping () -> Void) {
        guard !isGenerationPending else { return }
        isGenerationPending = true
        schedule { [weak self] in
            self?.isGenerationPending = false
            generation()
        }
    }
}

struct SleepListView: View {

    // MARK: - Sheet routing

    struct SelectedDay: Identifiable {
        let id = UUID()
        let day: Date
    }

    enum ActiveSheet: Identifiable {
        case addSleep(editing: SleepRecord?, defaultDate: Date)
        case addNightSleep(defaultDate: Date)
        case addBreak(parentID: UUID)
        case endSleep(parent: SleepRecord, review: Bool = false)
        case dayDetail(SelectedDay)
        case wakeTime(association: AssociatedHomeWake? = nil)

        var isRecording: Bool {
            switch self {
            case .addSleep, .addNightSleep, .addBreak, .endSleep: return true
            case .dayDetail, .wakeTime: return false
            }
        }

        var id: String {
            switch self {
            case .addSleep(let editing, let date):
                return "addSleep-\(editing?.id.uuidString ?? "new")-\(date.timeIntervalSince1970)"
            case .addNightSleep(let date):
                return "addNightSleep-\(date.timeIntervalSince1970)"
            case .addBreak(let id):
                return "addBreak-\(id)"
            case .endSleep(let parent, _):
                return "endSleep-\(parent.id)"
            case .dayDetail(let day):
                return "dayDetail-\(day.id)"
            case .wakeTime(let association):
                return "wakeTime-\(association?.night.id.uuidString ?? "independent")"
            }
        }
    }

    // MARK: - State

    @StateObject private var orchestrator = SleepCoachOrchestrator.shared
    @StateObject private var generationCoalescer = SleepGenerationCoalescer()
    @State private var activeSheet: ActiveSheet? = nil
    @State private var records: [SleepRecord] = []
    @State private var wakeRecords: [DailyWakeRecord] = []
    @State private var addDefaultDate: Date = Date()
    private let sleepRecordPersistence = SleepRecordPersistence()
    private let dailyWakeRecordPersistence = DailyWakeRecordPersistence()

    @AppStorage("babyName")   private var babyName:   String = "Baby"
    @AppStorage("parentName") private var parentName: String = ""

    @State private var heroShowsPlan = false
    @Binding var sleepConfirmation: StillSleepingConfirmation?

    init(sleepConfirmation: Binding<StillSleepingConfirmation?> = .constant(nil)) {
        _sleepConfirmation = sleepConfirmation
    }

    // MARK: - Persistence

    private func upsert(_ record: SleepRecord) -> Bool {
        guard sleepRecordPersistence.saveRecording(record) else { return false }
        loadRecords()
        return true
    }
    private func completeNight(_ record: SleepRecord) -> NightSleepCompletionResult {
        let result = NightSleepCompletion(submitted: record, now: Date(), calendar: record.recordingCalendar ?? .current,
            sleepPersistence: sleepRecordPersistence, wakePersistence: dailyWakeRecordPersistence).execute()
        loadRecords()
        loadWakeRecords()
        return result
    }

    private func deleteRecords(_ ids: Set<UUID>) {
        if sleepRecordPersistence.delete(ids: ids) { loadRecords() }
    }

    private func loadRecords() {
        if let decoded = sleepRecordPersistence.load() {
            records = decoded
        }
    }

    private func loadWakeRecords() {
        wakeRecords = dailyWakeRecordPersistence.load() ?? []
    }

    private func saveWakeTime(_ selectedTime: Date, capture: WakeObservationCapture?,
                              operation: HomeWakeOperation, calendar: Calendar) -> String? {
        #if DEBUG && targetEnvironment(simulator)
        if HomeCardTestFixture.enabled && ProcessInfo.processInfo.environment["HOME_WAKE_SAVE_FAIL"] == "1" { return "Saving did not finish. Review your wake time and try again." }
        #endif
        let result = SleepWakeTimeWorkflow(
            selectedWakeTime: selectedTime,
            now: Date(),
            calendar: calendar,
            wakeRecords: wakeRecords,
            sleepRecords: records,
            wakePersistence: dailyWakeRecordPersistence,
            sleepPersistence: sleepRecordPersistence,
            capture: capture,
            homeOperation: operation
        ).execute()
        var state = HomeWakeCardState(records: wakeRecords)
        state.accept(result)
        wakeRecords = state.records
        if result.sleepPersistenceSucceeded { records = result.updatedSleepRecords }
        if let recovery = result.historicalRecovery { return recovery.message }
        if let error = result.homeError { return error }
        if result.wakePersistenceSucceeded && result.evidencePublicationSucceeded &&
            (result.closedNightRecord == nil || result.sleepPersistenceSucceeded) { return nil }
        return "Saving did not finish. Review your wake time and try again."
    }

    // MARK: - Derived Data

    private var sleeps: [SleepRecord] {
        records.filter { $0.kind != .break }.sorted { $0.date > $1.date }
    }

    private var breaks: [SleepRecord] {
        records.filter { $0.kind == .break }
    }

    private var latestSleep: SleepRecord? { sleeps.first }

    private var latestSleepMinutes: Int {
        guard let latestSleep else { return 95 }
        return latestSleep.totalMinutes(breaks: breaks)
    }

    private var todayRecords: [SleepRecord] {
        SleepAccounting(records: records, now: Date(), calendar: .current).records(on: Date())
    }

    private var todaySleeps: [SleepRecord] {
        todayRecords.filter { $0.kind != .break }.sorted { $0.date < $1.date }
    }

    private var todayWakeRecord: DailyWakeRecord? {
        let now = Date()
        let calendar = Calendar.current
        return DailyWakeRecord.uniqueObservation(in: wakeRecords, on: now, at: now, calendar: calendar)
    }

    private var hasPassedTypicalWakeTime: Bool {
        let wakeHour = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
        let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
        let today = Calendar.current.startOfDay(for: Date())
        let typicalWake = Calendar.current.date(
            bySettingHour: Int(wakeHour),
            minute: Int(wakeMinute),
            second: 0,
            of: today
        ) ?? defaultWakeTime
        return Date() >= typicalWake
    }

    private var shouldShowTodayWakeUpPrompt: Bool {
        todayWakeRecord == nil &&
        activeSleepRecord == nil &&
        hasPassedTypicalWakeTime
    }

    private var defaultWakeTime: Date {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }
    

    
    private var displayedParentName: String {
        let name = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "there" }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var overviewMetrics: SleepOverviewMetrics {
        SleepOverviewCalculator(records: records, now: Date(), calendar: .current, totalSleepReference: orchestrator.snapshot.map { DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: $0.ageMonths).totalSleep24hRange }).calculate()
    }

    private var todayTotal: Int { overviewMetrics.todayTotal }
    private var yesterdayTotal: Int { overviewMetrics.yesterdayTotal }
    private var todayDelta: Int { overviewMetrics.todayDelta }
    private var last7DaysAverage: Int { overviewMetrics.last7DaysAverage }
    private var previous7DaysAverage: Int { overviewMetrics.previous7DaysAverage }
    private var averageNapMinutes: Int { overviewMetrics.averageNapMinutes }
    private var latestNapDelta: Int { overviewMetrics.latestNapDelta }

    private var nextNapAnchor: Date {
        if let last = todaySleeps.last {
            return Calendar.current.date(
                byAdding: .minute, value: last.duration, to: last.date
            ) ?? last.date
        }
        return todayWakeRecord?.wakeTime ?? defaultWakeTime
    }

    private var recommendedWakeWindowMinutes: Int {
        if latestSleepMinutes >= 90 { return 130 }
        if latestSleepMinutes >= 60 { return 150 }
        return 120
    }

    private var nextNapTime: Date {
        // Her zaman snapshot'tan al, snapshot yoksa fallback
        guard let snapshotTime = orchestrator.snapshot?.daytime.nextNapTime else {
            return Calendar.current.date(
                byAdding: .minute,
                value: recommendedWakeWindowMinutes,
                to: nextNapAnchor
            ) ?? Date()
        }
        return snapshotTime
    }

    private var confidencePercent: Int {
        if let c = orchestrator.snapshot?.daytime.confidence { return c }
        let boost = todayWakeRecord == nil ? 0 : 6
        return min(94, 68 + boost + min(records.count, 9) * 2)
    }

    private var nextNapWindowStart: Date {
        orchestrator.snapshot?.daytime.windowStart
            ?? Calendar.current.date(byAdding: .minute, value: -15, to: nextNapTime)
            ?? nextNapTime
    }

    private var nextNapWindowEnd: Date {
        orchestrator.snapshot?.daytime.windowEnd
            ?? Calendar.current.date(byAdding: .minute, value: 10, to: nextNapTime)
            ?? nextNapTime
    }

    // FIX: Settings'te kaydedilen varsayılan wake time kullanıldı mı?
    private var usingDefaultWakeTime: Bool {
        orchestrator.snapshot?.daytime.usedDefaultWakeTime ?? false
    }
 
    
    private var isNextNapOverdue: Bool {
        guard orchestrator.snapshot?.nextSleepKind == .nap else { return false }
        guard let napTime = orchestrator.snapshot?.daytime.nextNapTime else { return false }
        return napTime < Date()
    }
    private var wakeWindowBeforeLatest: Int? {
        let now = Date()
        let calendar = Calendar.current
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        let sleeps = accounting.records(on: now)
        guard let firstNap = sleeps.filter({ $0.kind == .dayNap && $0.completedEnd(at: now) != nil })
            .min(by: { $0.date < $1.date }) else { return nil }
        let earlierEnd = records.filter { $0.kind != .break }.compactMap { $0.completedEnd(at: now) }
            .filter { $0 <= firstNap.date && calendar.isDate($0, inSameDayAs: firstNap.date) }.max()
        let wake = DailyWakeRecord.uniqueObservation(in: wakeRecords, on: now, at: now, calendar: calendar)?.wakeTime
        guard let anchor = [earlierEnd, wake].compactMap({ $0 }).filter({ $0 <= firstNap.date }).max() else { return nil }
        return accounting.recordedAwakeMinutes(from: anchor, until: firstNap.date)
    }

    private var insightText: String {
        if orchestrator.snapshot?.hasCurrentSleep == true {
            return "Record the observed end when your baby wakes."
        }
        if let llm = orchestrator.currentCoaching?.coachMessage, !llm.isEmpty { return llm }
        if orchestrator.isLLMLoading { return "Reviewing \(babyName)'s recorded sleep…" }
        return orchestrator.snapshot?.insights.coachTip
            ?? "Record an actual wake or sleep end to use it as a planning reference."
    }

    // MARK: - Expected Nap Slots Helper

        private var expectedNapSlotCount: Int {
            guard let ageMonths = orchestrator.snapshot?.ageMonths else { return 2 }
            let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
            return profile.expectedNapCount.upperBound
        }

    private func planPresentation(at actual: Date) -> TodayPlanPresentation {
        let now = planNow(actual)
        let calendar = Calendar.current
        let routine = SleepRoutine.load(defaults: .standard)
        let hero = sleepHero(at: now, calendar: calendar, routine: routine)
        #if DEBUG && targetEnvironment(simulator)
        if TodayPlanUITestFixture.enabled {
            return TodayPlanUITestFixture.presentation(records: records, wakes: wakeRecords, hero: hero, routine: routine)
        }
        #endif
        // No verified provider exists. No legacy phase, DQS or LLM timestamp is used.
        return TodayPlanPresentation.make(records: records, wakes: wakeRecords, hero: hero,
            now: now, calendar: calendar, routine: routine)
    }

    // MARK: - Helpers

    private func shortTime(_ date: Date) -> String {
        let f        = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func changeLabel(_ minutes: Int, fallback: String = "Collecting pattern") -> String {
        guard minutes != 0 else { return fallback }
        return "\(minutes > 0 ? "+" : "-")\(TimeFormat.minutes(abs(minutes)))"
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day)     { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let ids = Set(items.filter { $0.kind != .break }.map(\.id))
        return SleepAccounting.netMinutes(records: records, now: Date(), sleepIDs: ids)
    }

    private func deleteDay(_ day: Date) {
        let cal = Calendar.current
        deleteRecords(Set(records.filter { cal.isDate($0.date, inSameDayAs: day) }.map(\.id)))
    }


    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    #if DEBUG && targetEnvironment(simulator)
                    if HomeCardTestFixture.enabled || HeroUITestFixture.enabled || TodayPlanUITestFixture.enabled { Text("TEST FIXTURE — NOT A PREDICTION").font(.caption2).foregroundStyle(.secondary) }
                    #endif
                    headerSection
                    nextNapOrBedtimeCard
                    rhythmLearningStrip
                    todayWakeSection
                       todayTimelineCard.id("home.todayPlan")
                       coachInsightCard
                        sleepOverviewCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 112)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .onAppear {
                _ = sleepRecordPersistence.storage.pruneRecoveryArchives()
                _ = SleepWakeTimeWorkflow.resumePending(now: Date(), wakePersistence: dailyWakeRecordPersistence,
                                                       sleepPersistence: sleepRecordPersistence)
                loadRecords()
                loadWakeRecords()
                orchestrator.loadCachedLLMResponse()
                orchestrator.generate(confirmation: sleepConfirmation)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in
                loadRecords()
                generationCoalescer.request { orchestrator.generate(confirmation: sleepConfirmation) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .dailyWakeRecordsDidChange)) { _ in
                loadWakeRecords()
                generationCoalescer.request { orchestrator.generate(confirmation: sleepConfirmation) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                loadRecords()
                loadWakeRecords()
                orchestrator.generate(confirmation: sleepConfirmation, requestCoaching: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                loadRecords()
                loadWakeRecords()
                orchestrator.generate(confirmation: sleepConfirmation, requestCoaching: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .babyProfileDidChange)) { _ in
                generationCoalescer.request { orchestrator.generate(confirmation: sleepConfirmation) }
            }
            .environment(\.locale, Locale(identifier: "en_US"))
            .onChange(of: heroShowsPlan) { requested in
                if requested {
                    withAnimation { proxy.scrollTo("home.todayPlan", anchor: .top) }
                    heroShowsPlan = false
                }
            }
            }
        }
        .sheet(item: presentationSheet(recording: false), content: sheetContent)
        .fullScreenCover(item: presentationSheet(recording: true), content: sheetContent)
    }

    private func presentationSheet(recording: Bool) -> Binding<ActiveSheet?> {
        Binding(get: {
            guard let sheet = activeSheet, sheet.isRecording == recording else { return nil }
            return sheet
        }, set: { value in
            // An outgoing presentation must not clear a different incoming destination.
            if let value { activeSheet = value }
            else if activeSheet?.isRecording == recording { activeSheet = nil }
        })
    }

    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        SleepListSheetRouter(
            sheet: sheet,
            records: records,
            todayWakeTime: todayWakeRecord?.wakeTime,
            defaultWakeTime: defaultWakeTime,
            onRecordUpsert: upsert,
            onNightCompletion: completeNight,
            onBreakSaved: upsert,
            onDeleteRecords: { ids in
                deleteRecords(ids)
            },
            onWakeTimeSave: saveWakeTime
        )
    }
    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Good day, \(displayedParentName) 👋")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoonHeaderArt()
                .frame(width: 64, height: 50)
        }
        .padding(.top, 6)
    }

    // MARK: - Rhythm Learning Strip

    // Only relevant while still in the learning window. Once the phase is
    // personalized (14+ tracked days), predictions are already real and
    // this strip has nothing meaningful left to communicate.
    private var shouldShowRhythmLearningStrip: Bool {
        orchestrator.snapshot != nil
    }

    private var rhythmLearningDays: Int {
        orchestrator.snapshot?.dataQualityReport.trackedDays ?? 0
    }

    private var rhythmLearningProgress: Double {
        min(1.0, max(0.0, Double(rhythmLearningDays) / 14.0))
    }

    private var rhythmQualityLabel: String {
        "Last 14 days"
    }

    private var rhythmLearningHint: String {
        "Recording coverage is unconfirmed"
    }

    private var rhythmLearningStrip: some View {
        Group {
            if shouldShowRhythmLearningStrip {
                rhythmLearningStripContent
            }
        }
    }

    private var rhythmLearningStripContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.16), lineWidth: 4)
                    .frame(width: 44, height: 44)
                Circle()
                    .trim(from: 0, to: rhythmLearningProgress)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.55, green: 0.45, blue: 0.98),
                                Color(red: 1.0, green: 0.72, blue: 0.30)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.86))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Days with records")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer()
                    Text("\(rhythmLearningDays)/14")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.86))
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.45, blue: 0.98),
                                    Color(red: 1.0, green: 0.72, blue: 0.30)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(8, geo.size.width * rhythmLearningProgress))
                    }
                }
                .frame(height: 6)

                HStack {
                    Text(rhythmQualityLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Text(rhythmLearningHint)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.45, blue: 0.96).opacity(0.025),
                                Color(red: 0.55, green: 0.45, blue: 0.96).opacity(0.065)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(red: 0.55, green: 0.45, blue: 0.96).opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.07), radius: 9, x: 0, y: 4)
    }

    // MARK: - Sleep Overview Card

    private var sleepOverviewCard: some View {
        let metrics = overviewMetrics
        let rhythm = orchestrator.snapshot?.pattern?.averageWakeWindowMinutes ?? wakeWindowBeforeLatest
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SLEEP OVERVIEW")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.92))
                        .tracking(0.5)
                    Text("Today and recent days")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                }

                Spacer()

                Button {
                    activeSheet = .dayDetail(SelectedDay(day: Date()))
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.92))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Today’s sleep records")
                .accessibilityIdentifier("sleep.todayRecords")
            }

            HStack(spacing: 10) {
                summaryCell(
                    icon: "moon.fill",
                    iconColor: Color(red: 0.55, green: 0.48, blue: 0.96),
                    title: "Sleep Day",
                    value: metrics.recordedSleepDay.display,
                    badge: "24h: \(metrics.recordedRolling24h.display)",
                    badgeColor: goalBadgeColor(progress: metrics.recordedGoalProgress)
                )

                summaryCell(
                    icon: "moon.zzz.fill",
                    iconColor: Color(red: 0.26, green: 0.72, blue: 0.56),
                    title: "Naps",
                    value: "\(metrics.todayNapCount)",
                    badge: napBadgeText(metrics),
                    badgeColor: napBadgeColor(metrics)
                )

                summaryCell(
                    icon: "waveform.path",
                    iconColor: Color(red: 1.0, green: 0.68, blue: 0.24),
                    title: "Recorded awake gaps",
                    value: rhythm.map(TimeFormat.minutes) ?? "Unavailable",
                    badge: rhythm == nil ? "Needs records" : "From records",
                    badgeColor: Color(.secondaryLabel)
                )
            }

            if let progress = metrics.recordedGoalProgress {
                VStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.55, green: 0.45, blue: 0.98),
                                            Color(red: 1.0, green: 0.72, blue: 0.30)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 7)

                    HStack {
                        Text("\(Int(progress * 100))% of 24h minimum reference")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(.secondaryLabel))
                        Spacer()
                        Text("Goal: 14h")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }


            if !groupedByDay.isEmpty {
                Divider().overlay(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.12))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("RECENT DAYS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(.secondaryLabel))
                            .tracking(0.4)
                        Spacer()
                        Text("\(groupedByDay.count) tracked")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }

                    VStack(spacing: 8) {
                        ForEach(Array(groupedByDay.prefix(3).enumerated()), id: \.element.day) { index, group in
                            Button {
                                activeSheet = .dayDetail(SelectedDay(day: group.day))
                            } label: {
                                premiumDayRow(group: group, rank: index)
                            }
                            .buttonStyle(CardPressButtonStyle())
                            .accessibilityIdentifier("sleep.dayRecords.\(index)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { deleteDay(group.day) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.045),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.08), radius: 16, x: 0, y: 6)
    }

    // MARK: - Summary Cell

    private func summaryCell(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        badge: String,
        badgeColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // İkon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [iconColor.opacity(0.16), iconColor.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor.opacity(0.78))
            }

            // Başlık
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // Değer
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            // Badge
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badgeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.0), iconColor.opacity(0.045)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(iconColor.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: iconColor.opacity(0.08), radius: 10, x: 0, y: 5)
    }

    // MARK: - Badge Helpers

    private func goalBadgeColor(progress: Double?) -> Color {
        guard let progress else { return Color(.secondaryLabel) }
        if progress >= 1 { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        if progress >= 0.7 { return Color(red: 0.45, green: 0.35, blue: 0.92) }
        return Color(.secondaryLabel)
    }

    private func napBadgeText(_ metrics: SleepOverviewMetrics) -> String {
        guard !metrics.recordedDaytime.isIncomplete else { return "Incomplete" }
        guard let ageMonths = orchestrator.snapshot?.ageMonths else { return "Completed" }
        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
        let expected = profile.expectedNapCount
        if metrics.todayNapCount >= expected.lowerBound { return "On track" }
        let remaining = expected.lowerBound - metrics.todayNapCount
        return "\(remaining) more needed"
    }

    private func napBadgeColor(_ metrics: SleepOverviewMetrics) -> Color {
        guard !metrics.recordedDaytime.isIncomplete, let ageMonths = orchestrator.snapshot?.ageMonths else {
            return Color(.secondaryLabel)
        }
        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
        let expected = profile.expectedNapCount
        if metrics.todayNapCount >= expected.lowerBound { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        return Color(.secondaryLabel)
    }
    
    private var activeSleepRecord: SleepRecord? {
        activeSleepCalculation.activeSleepRecord
    }

    private var inferredNightSleepStart: Date? {
        activeSleepCalculation.inferredNightSleepStart
    }

    private var inferredNightSleepRecord: SleepRecord? {
        activeSleepCalculation.inferredNightSleepRecord
    }

    // Live sleep card gerçek ongoing kayıt varsa canlı, default gece penceresindeysek tahmini gösterilir.
    private var isStillInNightSleep: Bool {
        activeSleepCalculation.isStillInNightSleep
    }

    private var activeSleepCalculator: SleepStateCalculator {
        SleepStateCalculator(
            records: records,
            now: Date(),
            calendar: .current,
            typicalWakeHour: Int(UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0),
            typicalWakeMinute: Int(UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0),
            typicalBedHour: Int(UserDefaults.standard.object(forKey: "typicalBedHour") as? Double ?? 19.0),
            typicalBedMinute: Int(UserDefaults.standard.object(forKey: "typicalBedMinute") as? Double ?? 30.0),
            averageNapDurationMinutes: orchestrator.snapshot?.pattern?.averageNapDurationMinutes,
            predictedNextNapTime: orchestrator.snapshot?.daytime.nextNapTime,
            recommendedWakeWindowMinutes: recommendedWakeWindowMinutes
        )
    }

    private var activeSleepCalculation: SleepStateCalculation {
        activeSleepCalculator.calculate()
    }

    // MARK: next nap or bedtime?

    private var nextNapOrBedtimeCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let model = sleepHero(at: context.date)
            TodaySleepHeroCard(model: model,
                addNap: { activeSheet = .addSleep(editing: nil, defaultDate: Date()) },
                recordNight: { activeSheet = .addNightSleep(defaultDate: Date()) },
                endSleep: {
                    if let record = model.record {
                        activeSheet = .endSleep(parent: record, review: model.elapsedMinutes == nil)
                    }
                },
                reviewEnd: { record in
                    activeSheet = record.isOngoing ? .endSleep(parent: record, review: true)
                        : .addSleep(editing: record, defaultDate: record.date)
                },
                addBreak: { if model.canAddBreak, let record = model.record { activeSheet = .addBreak(parentID: record.id) } },
                viewDetails: { activeSheet = .dayDetail(SelectedDay(day: model.sleepDay ?? context.date)) },
                viewPlan: { heroShowsPlan = true },
                confirmWake: {
                    let association = model.assessment.reminderNight.map {
                        AssociatedHomeWake(night: $0, morning: model.routineWake ?? model.now, calendar: model.calendar)
                    }
                    activeSheet = .wakeTime(association: association)
                })
        }
    }

    private func sleepHero(at now: Date, calendar: Calendar = .current,
                           routine: SleepRoutine? = .load(defaults: .standard)) -> TodaySleepHeroModel {
        #if DEBUG && targetEnvironment(simulator)
        if TodayPlanUITestFixture.enabled {
            return TodaySleepHeroModel.make(records: records, wakeRecords: wakeRecords,
                now: TodayPlanUITestFixture.now, calendar: .current,
                routine: TodaySleepHeroModel.Routine.load(defaults: .standard),
                displayName: displayedParentName, babyName: babyName,
                proposals: TodayPlanUITestFixture.wakePredictions(records: records))
        }
        if HeroUITestFixture.enabled { return HeroUITestFixture.model(records: records, wakes: wakeRecords, confirmation: sleepConfirmation) }
        if HomeCardTestFixture.enabled { return HeroUITestFixture.legacyModel(records: records, wakes: wakeRecords) }
        #endif
        // No verified eligibility provider exists. Do not feed the legacy counter,
        // DQS or LLM text into this prediction display contract.
        return TodaySleepHeroModel.make(records: records, wakeRecords: wakeRecords,
            now: now, calendar: calendar, routine: routine,
            displayName: displayedParentName, babyName: babyName,
            confirmation: sleepConfirmation, instant: ContinuousClock.now)
    }

    @ViewBuilder private func homeCardArtwork(kind: SleepKind?) -> some View {
        if kind == .nightSleep { MoonHeaderArt() }
        else { Image(systemName: "bed.double.fill").font(.system(size: 30)).foregroundStyle(Color.sleepPurple) }
    }

    private func homeCardNow(_ actual: Date) -> Date {
        #if DEBUG && targetEnvironment(simulator)
        if HomeCardTestFixture.enabled { return HomeCardTestFixture.now }
        #endif
        return actual
    }

    private func homeCardPresentation(now: Date) -> HomeSleepCardPresentation {
        #if DEBUG && targetEnvironment(simulator)
        if HomeCardTestFixture.enabled { return HomeCardTestFixture.presentation(records: records) }
        #endif
        return HomeSleepCardPresentation.make(records: records, now: now, calendar: .current)
    }

    private func expectedWakeTime(for ongoingSleep: SleepRecord?) -> Date {
        activeSleepCalculator.expectedWakeTime(for: ongoingSleep)
    }

    private func nextSleepTimeAfterCurrentSleep(ongoingSleep: SleepRecord?, expectedWake: Date) -> Date? {
        activeSleepCalculator.nextSleepTimeAfterCurrentSleep(ongoingSleep: ongoingSleep, expectedWake: expectedWake)
    }
    
    
    // MARK: - Today Wake Up Card

    private var todayWakeSection: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            if HomeWakeCardState(records: wakeRecords).isVisible(now: context.date, calendar: calendar) {
                HomeWakeTimeCard { activeSheet = .wakeTime() }
            } else if let wakeTime = DailyWakeRecord.uniqueObservation(in: wakeRecords, on: context.date,
                at: context.date, calendar: calendar)?.wakeTime {
                WakeUpCard(time: wakeTime)
            }
        }
    }

    // MARK: - Regular Next Nap / Bedtime Card

    private var regularNextNapOrBedtimeCard: some View {
        let isBedtime    = orchestrator.snapshot?.nextSleepKind == .bedtime
        let isOverdue    = isNextNapOverdue
        let displayTime  = isBedtime
            ? (orchestrator.snapshot?.night.optimalBedtimeStart ?? nextNapTime)
            : nextNapTime

        return Button {
            activeSheet = .addSleep(editing: nil, defaultDate: isOverdue ? Date() : displayTime)
        } label: {
            NextSleepCard(
                isBedtime:         isBedtime,
                isOverdue:         isOverdue,
                displayTime:       displayTime,
                windowStart:       nextNapWindowStart,
                windowEnd:         nextNapWindowEnd,
                confidencePercent: confidencePercent,
                bedtimeWindowEnd:  orchestrator.snapshot?.night.optimalBedtimeEnd,
                overtiredRiskTime: orchestrator.snapshot?.night.overtiredRiskTime
            )
        }
        .buttonStyle(CardPressButtonStyle())
    }
    // MARK: - NextSleepCard

    struct NextSleepCard: View {

        let isBedtime:         Bool
        let isOverdue:         Bool
        let displayTime:       Date
        let windowStart:       Date
        let windowEnd:         Date
        let confidencePercent: Int
        let bedtimeWindowEnd:  Date?
        let overtiredRiskTime: Date?

        @State private var pulse        = false
        @State private var starOpacity1: Double = 0.3
        @State private var starOpacity2: Double = 0.6
        @State private var starOpacity3: Double = 0.2

        // MARK: - State Kind (önce tanımlanmalı)

        enum StateKind { case nextNap, overdueNap, bedtimeApproaching, nightMode, overtired }

        private var stateKind: StateKind {
            if isBedtime, let risk = overtiredRiskTime, Date() >= risk { return .overtired }
            if isOverdue          { return .overdueNap }
            if isBedtime, Date() >= displayTime { return .nightMode }
            if isBedtime          { return .bedtimeApproaching }
            return .nextNap
        }

        // MARK: - Theme

        struct CardTheme {
            let bg:         Color
            let border:     Color
            let shadow:     Color
            let label:      Color
            let title:      Color
            let subtitle:   Color
            let ringTrack:  Color
            let ringArc:    [Color]
            let ringText:   Color
            let bottom:     Color
            let labelText:  String
            let showStars:  Bool
            let showPulse:  Bool
        }

        private var theme: CardTheme {
            switch stateKind {
            case .nextNap:
                return CardTheme(
                    bg:        Color(red:0.98,green:0.97,blue:1.0),
                    border:    Color(red:0.55,green:0.45,blue:0.98).opacity(0.18),
                    shadow:    Color(red:0.45,green:0.35,blue:0.92).opacity(0.10),
                    label:     Color(red:0.45,green:0.35,blue:0.86),
                    title:     Color(red:0.17,green:0.13,blue:0.32),
                    subtitle:  Color(red:0.42,green:0.38,blue:0.58),
                    ringTrack: Color(red:0.55,green:0.45,blue:0.98).opacity(0.14),
                    ringArc:   [Color(red:0.55,green:0.45,blue:0.98).opacity(0.55), Color(red:0.45,green:0.35,blue:0.92), Color(red:1.0,green:0.72,blue:0.30)],
                    ringText:  Color(red:0.17,green:0.13,blue:0.32),
                    bottom:    Color(red:0.42,green:0.38,blue:0.58),
                    labelText: "NEXT NAP",
                    showStars: false,
                    showPulse: true
                )
            case .overdueNap:
                return CardTheme(
                    bg:        Color(red:0.52,green:0.25,blue:0.04),
                    border:    Color.orange.opacity(0.4),
                    shadow:    Color(red:0.38,green:0.16,blue:0.02).opacity(0.55),
                    label:     Color(red:1.0,green:0.72,blue:0.3),
                    title:     .white,
                    subtitle:  Color(red:1.0,green:0.72,blue:0.3).opacity(0.85),
                    ringTrack: Color.white.opacity(0.10),
                    ringArc:   [Color.orange.opacity(0.6), Color.orange, .white],
                    ringText:  .white,
                    bottom:    Color(red:1.0,green:0.72,blue:0.3).opacity(0.8),
                    labelText: "NAP WINDOW PASSED",
                    showStars: false,
                    showPulse: true
                )
            case .bedtimeApproaching:
                return CardTheme(
                    bg:        Color(red:0.98,green:0.96,blue:1.0),
                    border:    Color(red:0.55,green:0.45,blue:0.98).opacity(0.20),
                    shadow:    Color(red:0.45,green:0.35,blue:0.92).opacity(0.11),
                    label:     Color(red:0.45,green:0.35,blue:0.86),
                    title:     Color(red:0.17,green:0.13,blue:0.32),
                    subtitle:  Color(red:0.42,green:0.38,blue:0.58),
                    ringTrack: Color(red:0.55,green:0.45,blue:0.98).opacity(0.14),
                    ringArc:   [Color(red:0.55,green:0.45,blue:0.98).opacity(0.55), Color(red:0.45,green:0.35,blue:0.92), Color(red:1.0,green:0.72,blue:0.3)],
                    ringText:  Color(red:0.17,green:0.13,blue:0.32),
                    bottom:    Color(red:0.42,green:0.38,blue:0.58),
                    labelText: "BEDTIME",
                    showStars: false,
                    showPulse: false
                )
            case .nightMode:
                return CardTheme(
                    bg:        Color(red:0.12,green:0.08,blue:0.35),
                    border:    Color(red:0.32,green:0.22,blue:0.72).opacity(0.4),
                    shadow:    Color(red:0.08,green:0.05,blue:0.25).opacity(0.6),
                    label:     Color(red:0.72,green:0.65,blue:0.98),
                    title:     .white,
                    subtitle:  Color(red:0.72,green:0.65,blue:0.98).opacity(0.85),
                    ringTrack: Color.white.opacity(0.10),
                    ringArc:   [Color(red:0.72,green:0.65,blue:0.98).opacity(0.6), Color(red:0.72,green:0.65,blue:0.98), .white],
                    ringText:  .white,
                    bottom:    Color(red:0.72,green:0.65,blue:0.98).opacity(0.8),
                    labelText: "BEDTIME",
                    showStars: true,
                    showPulse: true
                )
            case .overtired:
                return CardTheme(
                    bg:        Color(red:0.50,green:0.06,blue:0.06),
                    border:    Color.red.opacity(0.4),
                    shadow:    Color(red:0.35,green:0.04,blue:0.04).opacity(0.55),
                    label:     Color(red:1.0,green:0.72,blue:0.3),
                    title:     .white,
                    subtitle:  Color(red:1.0,green:0.72,blue:0.3).opacity(0.85),
                    ringTrack: Color.white.opacity(0.10),
                    ringArc:   [Color.red.opacity(0.6), Color.red, .white],
                    ringText:  .white,
                    bottom:    Color(red:1.0,green:0.72,blue:0.3).opacity(0.8),
                    labelText: "OVERTIRED RISK",
                    showStars: false,
                    showPulse: true
                )
            }
        }

        // MARK: - Body

        var body: some View {
            let t = theme
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(t.bg)

                if t.showStars { starsLayer }

                VStack(spacing: 0) {
                    topRow(t)
                    if stateKind == .nextNap {
                        Divider().background(t.ringTrack).padding(.horizontal, 16)
                        recommendedWindowBand(t)
                    }
                    Divider().background(t.ringTrack).padding(.horizontal, 16)
                    bottomRow(t)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(t.border, lineWidth: 1))
            .shadow(color: t.shadow, radius: 16, x: 0, y: 8)
            .onAppear {
                pulse = true
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { starOpacity1 = 0.9 }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.4)) { starOpacity2 = 0.2 }
                withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(0.9)) { starOpacity3 = 0.8 }
            }
        }

        // MARK: - Top Row

        private func topRow(_ t: CardTheme) -> some View {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    // Etiket
                    HStack(spacing: 5) {
                        if t.showPulse {
                            Circle()
                                .fill(t.label)
                                .frame(width: 6, height: 6)
                                .scaleEffect(pulse ? 1.4 : 0.8)
                                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        }
                        Text(t.labelText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(t.label)
                            .tracking(0.5)
                    }

                    // Ana başlık
                    Text(mainTitleText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(t.title)
                        .monospacedDigit()

                    // Alt açıklama
                    Text(subLabelText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
                circularRight(t)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }

        private var mainTitleText: String {
            switch stateKind {
            case .overdueNap:  return "Add nap now"
            case .overtired:   return "Sleep now!"
            case .nextNap:     return "Nap at \(ampm(displayTime))"
            case .bedtimeApproaching, .nightMode:
                return "Bedtime at \(ampm(displayTime))"
            }
        }

        private var subLabelText: String {
            switch stateKind {
            case .nextNap:
                return "Recommended start around \(ampm(displayTime))"
            case .overdueNap:
                return "Expected \(ampm(displayTime)) — may be overtired"
            case .bedtimeApproaching:
                let m = minutesUntilBedtime
                if m >= 60 { return "\(m/60)h \(m%60 > 0 ? "\(m%60)m " : "")until bedtime" }
                return "\(m)m until bedtime"
            case .nightMode:
                return "Time to sleep · Sweet dreams 🌙"
            case .overtired:
                return "Past optimal window — put baby to sleep immediately"
            }
        }

        private var minutesUntilBedtime: Int {
            guard isBedtime, stateKind == .bedtimeApproaching else { return 0 }
            return max(0, Int(displayTime.timeIntervalSince(Date()) / 60))
        }

        private func recommendedWindowBand(_ t: CardTheme) -> some View {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.label.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(t.label)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended window")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(t.label)
                        .tracking(0.3)
                    Text("\(ampm(windowStart)) – \(ampm(windowEnd))")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(t.title)
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Overtired risk")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.bottom.opacity(0.82))
                    Text("after \(ampm(windowEnd))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.label)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }

        // MARK: - Circular Right

        private func circularRight(_ t: CardTheme) -> some View {
            ZStack {
                Circle().stroke(t.ringTrack, lineWidth: 5).frame(width: 72, height: 72)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(
                        AngularGradient(colors: t.ringArc, center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1.0), value: ringProgress)

                VStack(spacing: 1) {
                    Text(ringCenterLabel)
                        .font(.system(size: ringCenterLabel.count > 3 ? 12 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(t.ringText)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Text(ringSubLabel)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(t.label.opacity(0.7))
                }
            }
        }

        private var ringProgress: Double {
            switch stateKind {
            case .nextNap, .overdueNap, .overtired:
                return Double(confidencePercent) / 100.0
            case .bedtimeApproaching:
                let total = Double(4 * 60)
                let elapsed = total - Double(minutesUntilBedtime)
                return min(1.0, max(0, elapsed / total))
            case .nightMode:
                return 1.0
            }
        }

        private var ringCenterLabel: String {
            switch stateKind {
            case .nextNap, .overdueNap: return "\(confidencePercent)%"
            case .bedtimeApproaching:
                let m = minutesUntilBedtime
                return m >= 60 ? "\(m/60)h\(m%60>0 ? "\(m%60)m" : "")" : "\(m)m"
            case .nightMode:   return "🌙"
            case .overtired:   return "!"
            }
        }

        private var ringSubLabel: String {
            switch stateKind {
            case .nextNap, .overdueNap: return "conf."
            case .bedtimeApproaching:   return "to bed"
            case .nightMode:            return "night"
            case .overtired:            return "urgent"
            }
        }

        // MARK: - Bottom Row

        private func bottomRow(_ t: CardTheme) -> some View {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: bottomIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.bottom)
                    Text(bottomLeftText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.bottom)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Text(bottomRightText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }

        private var bottomIcon: String {
            switch stateKind {
            case .nextNap:             return "moon.fill"
            case .overdueNap:          return "exclamationmark.triangle"
            case .bedtimeApproaching:  return "moon.stars"
            case .nightMode:           return "waveform.path"
            case .overtired:           return "exclamationmark.triangle.fill"
            }
        }

        private var bottomLeftText: String {
            switch stateKind {
            case .nextNap:            return "Tap when sleep starts"
            case .overdueNap:         return "Tap to log nap now"
            case .bedtimeApproaching:
                if let end = bedtimeWindowEnd { return "Earliest \(ampm(displayTime)) · Latest \(ampm(end))" }
                return "Bedtime window"
            case .nightMode:
                if let end = bedtimeWindowEnd { return "Window \(ampm(displayTime)) – \(ampm(end))" }
                return "Start bedtime log"
            case .overtired:          return "Overtired — act now"
            }
        }

        private var bottomRightText: String {
            switch stateKind {
            case .nextNap:            return "\(confidencePercent)% confidence"
            case .overdueNap:         return "Log now →"
            case .bedtimeApproaching:
                if let risk = overtiredRiskTime { return "Overtired after \(ampm(risk))" }
                return ""
            case .nightMode:
                if let risk = overtiredRiskTime { return "Risk: \(ampm(risk))" }
                return "Good night 🌙"
            case .overtired:          return "Sleep immediately"
            }
        }

        // MARK: - Stars

        private var starsLayer: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle().fill(Color.white).frame(width:2.5,height:2.5).position(x:w*0.15,y:h*0.22).opacity(starOpacity1)
                    Circle().fill(Color.white).frame(width:1.5,height:1.5).position(x:w*0.75,y:h*0.15).opacity(starOpacity2)
                    Circle().fill(Color.white).frame(width:2,height:2).position(x:w*0.88,y:h*0.40).opacity(starOpacity3)
                    Circle().fill(Color.white).frame(width:1.5,height:1.5).position(x:w*0.25,y:h*0.70).opacity(starOpacity2)
                    Circle().fill(Color.white).frame(width:1,height:1).position(x:w*0.60,y:h*0.25).opacity(starOpacity1)
                    Image(systemName:"moon.stars.fill")
                        .font(.system(size:56,weight:.thin))
                        .foregroundStyle(LinearGradient(
                            colors:[Color.white.opacity(0.06),Color.white.opacity(0.03)],
                            startPoint:.topLeading,endPoint:.bottomTrailing))
                        .position(x:w*0.82,y:h*0.38)
                }
            }
        }

        // MARK: - Helper

        private func ampm(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
    }
    // MARK: Default Wake Time Warning Banner

    private var defaultWakeTimeWarningBanner: some View {
        Button {
            activeSheet = .wakeTime()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next nap prediction uses your default wake-up time.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Add today's actual wake-up time for a more accurate prediction.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(CardPressButtonStyle())
    }

    // MARK: - Coach Insight Card

    private var coachInsightCard: some View {
        VStack(spacing: 0) {

            HStack(spacing: 10) {

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.45, blue: 0.98),
                                    Color(red: 0.38, green: 0.28, blue: 0.82)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)
                        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.4),
                                radius: 6, x: 0, y: 3)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AI Coach")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(.label))

                        if orchestrator.isLLMLoading {
                            // Yükleniyor
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .tint(Color(red: 0.55, green: 0.45, blue: 0.98))
                                Text("Analyzing...")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.98))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.10))
                            )
                        } else if orchestrator.currentCoaching != nil {
                            // AI yanıtı var
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8, weight: .bold))
                                Text("AI")
                                    .font(.system(size: 9, weight: .heavy))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.55, green: 0.45, blue: 0.98),
                                                Color(red: 0.38, green: 0.28, blue: 0.82)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                        } else {
                            // Rule engine
                            Text("Smart tip")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.98))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.10))
                                )
                        }
                    }

                    Text("Personalized for \(babyName)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // ── Seperator ───────────────────────────────────────────
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.0),
                            Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.25),
                            Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 16)

            // ── Message ─────────────────────────────────────────────
            HStack(alignment: .top, spacing: 10) {
               
                Text("❝")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.25))
                    .offset(y: -2)

                VStack(alignment: .leading, spacing: 5) {
                    Text(insightText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(.label).opacity(0.82))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let snapshot = orchestrator.snapshot, !snapshot.hasCurrentSleep {
                        let bedtime = snapshot.nextSleepKind == .bedtime
                        let source = bedtime ? snapshot.night.source : snapshot.daytime.source
                        let limitation = bedtime ? snapshot.night.recommendation.limitation : snapshot.daytime.recommendation.limitation
                        Text([source.rawValue, limitation?.rawValue].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))

                // Sol kenar mor aksanı
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .center
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.08),
                radius: 12, x: 0, y: 4)
    }
    
    // MARK: - Today's Plan

    private var todayTimelineCard: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = planPresentation(at: context.date)
            TodayPlanCard(presentation: presentation, now: planNow(context.date)) {
                activeSheet = .dayDetail(SelectedDay(day: presentation.focusedNightSleepDay ?? context.date))
            }
        }
    }

    private func planNow(_ actual: Date) -> Date {
        #if DEBUG && targetEnvironment(simulator)
        if TodayPlanUITestFixture.enabled { return TodayPlanUITestFixture.now }
        #endif
        return actual
    }

    // MARK: - Recent Days

    private var groupedByDay: [(day: Date, items: [SleepRecord])] {
        let cal    = Calendar.current
        let groups = Dictionary(grouping: records) { cal.startOfDay(for: $0.date) }
        return groups
            .map { (day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private func premiumDayRow(group: (day: Date, items: [SleepRecord]), rank: Int) -> some View {
        let summary = SleepAccounting(records: records, now: Date(), calendar: .current).completedSubtotal(on: group.day)
        let sessions = group.items.filter { $0.kind != .break }.count

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dayAccent(for: rank).opacity(0.11))
                    .frame(width: 44, height: 44)
                Image(systemName: dayIcon(for: group.items))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(dayAccent(for: rank))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dayTitle(group.day))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.sleepInk)

                    if Calendar.current.isDateInToday(group.day) {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 0.16, green: 0.68, blue: 0.46))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.16, green: 0.68, blue: 0.46).opacity(0.10))
                            )
                    }
                }

                Text("\(sessions) sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sleepMuted)


            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(summary.display)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.sleepInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(summary.isIncomplete ? "Review records" : "Finalized")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.sleepMuted)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.sleepPurpleDeep.opacity(0.65))
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.82))
        )
    }

    private func dayAccent(for rank: Int) -> Color {
        switch rank {
        case 0: return Color(red: 0.45, green: 0.35, blue: 0.92)
        case 1: return Color(red: 0.16, green: 0.68, blue: 0.46)
        default: return Color(red: 1.0, green: 0.68, blue: 0.12)
        }
    }

    private func dayIcon(for items: [SleepRecord]) -> String {
        if items.contains(where: { $0.kind == .nightSleep }) {
            return "moon.stars.fill"
        }
        return "calendar"
    }


}

// MARK: - Decorative Views

private struct MoonHeaderArt: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let s = min(w, h)
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: s * 0.16, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .position(x: w * 0.88, y: h * 0.20)
                Image(systemName: "sparkle")
                    .font(.system(size: s * 0.13, weight: .bold))
                    .foregroundStyle(Color.sleepPurple.opacity(0.55))
                    .position(x: w * 0.12, y: h * 0.32)
                Image(systemName: "moon.fill")
                    .font(.system(size: s * 0.78))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.white.opacity(0.84), Color.sleepLilac, Color.sleepPurple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .rotationEffect(.degrees(-12))
                    .shadow(color: Color.sleepPurple.opacity(0.18),
                            radius: s * 0.10, x: 0, y: s * 0.06)
                    .position(x: w * 0.56, y: h * 0.43)
                HStack(spacing: -s * 0.08) {
                    Circle().fill(Color.white.opacity(0.88)).frame(width: s*0.28, height: s*0.28)
                    Circle().fill(Color.white.opacity(0.94)).frame(width: s*0.38, height: s*0.38)
                    Circle().fill(Color.white.opacity(0.88)).frame(width: s*0.28, height: s*0.28)
                }.position(x: w * 0.57, y: h * 0.78)
                VStack(spacing: s * 0.025) {
                    HStack(spacing: s * 0.14) {
                        SleepArcEye().frame(width: s * 0.13, height: s * 0.08)
                        SleepArcEye().frame(width: s * 0.13, height: s * 0.08)
                    }
                    SleepSmile()
                        .stroke(Color.sleepPurpleDeep,
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .frame(width: s * 0.20, height: s * 0.10)
                }.position(x: w * 0.55, y: h * 0.50)
            }
            .frame(width: w, height: h)
        }
    }
}


private struct SleepArcEye: View {
    var body: some View {
        ArcShape()
            .stroke(Color.sleepPurpleDeep,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

private struct SleepSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return p
    }
}

private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return p
    }
}

// MARK: - Colors

extension Color {
    static let sleepBackground = Color("sleepBackground")
       static let sleepInk        = Color("sleepInk")
       static let sleepMuted      = Color("sleepMuted")
       static let sleepPurple     = Color("sleepPurple")
       static let sleepPurpleDeep = Color("sleepPurpleDeep")
       static let sleepLilac      = Color("sleepLilac")
       static let sleepCloud      = Color("sleepCloud")
       static let sleepWarmCard   = Color("sleepWarmCard")
       static let sleepStroke = Color("sleepStroke")


    init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:     Double((hex >> 16) & 0xff) / 255,
            green:   Double((hex >>  8) & 0xff) / 255,
            blue:    Double( hex         & 0xff) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let sleepRecordsDidChange     = Notification.Name("sleepRecordsDidChange")
    static let dailyWakeRecordsDidChange = Notification.Name("dailyWakeRecordsDidChange")
    static let babyProfileDidChange      = Notification.Name("babyProfileDidChange")   // ← YENİ

}

// MARK: - Button Style

struct CardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
