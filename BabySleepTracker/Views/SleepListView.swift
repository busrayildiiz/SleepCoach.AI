//
//  SleepListView.swift
//  BabySleepTracker
//

import SwiftUI
import Foundation

struct SleepListView: View {

    // MARK: - Sheet routing

    struct SelectedDay: Identifiable {
        let id = UUID()
        let day: Date
    }

    enum ActiveSheet: Identifiable {
        case addSleep(editing: SleepRecord?, defaultDate: Date)
        case addBreak(napID: UUID, date: Date, napDuration: Int)
        case dayDetail(SelectedDay)
        case wakeTime

        var id: String {
            switch self {
            case .addSleep(let editing, let date):
                return "addSleep-\(editing?.id.uuidString ?? "new")-\(date.timeIntervalSince1970)"
            case .addBreak(let id, _, _):
                return "addBreak-\(id)"
            case .dayDetail(let day):
                return "dayDetail-\(day.id)"
            case .wakeTime:
                return "wakeTime"
            }
        }
    }

    private struct TimelineItem: Identifiable {
        enum VisualState {
            case completed
            case active
            case upcoming
        }

        let id = UUID()
        let icon: String
        let iconColor: Color
        let time: String
        let title: String
        let detail: String
        let visualState: VisualState
        let isActive: Bool
        let isFuture: Bool
        var awakeBeforeMinutes: Int
        
        init(
            icon: String,
            iconColor: Color,
            time: String,
            title: String,
            detail: String,
            visualState: VisualState,
            isActive: Bool,
            isFuture: Bool,
            awakeBeforeMinutes: Int = 0
        ) {
            self.icon               = icon
            self.iconColor          = iconColor
            self.time               = time
            self.title              = title
            self.detail             = detail
            self.visualState        = visualState
            self.isActive           = isActive
            self.isFuture           = isFuture
            self.awakeBeforeMinutes = awakeBeforeMinutes
        }
    }

    // MARK: - State

    @StateObject private var orchestrator = SleepCoachOrchestrator.shared
    @State private var activeSheet: ActiveSheet? = nil
    @State private var records: [SleepRecord] = []
    @State private var wakeRecords: [DailyWakeRecord] = []
    @State private var addDefaultDate: Date = Date()

    @AppStorage("babyName")   private var babyName:   String = "Baby"
    @AppStorage("parentName") private var parentName: String = ""

    // MARK: - Persistence
    
    private func upsert(_ record: SleepRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        saveRecords()
    }
    private func saveRecords() {
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: "sleepRecords")
            NotificationCenter.default.post(name: .sleepRecordsDidChange, object: nil)
        }
    }

    private func loadRecords() {
        if let data    = UserDefaults.standard.data(forKey: "sleepRecords"),
           let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data) {
            records = decoded
        }
    }

    private func loadWakeRecords() {
        if let data    = UserDefaults.standard.data(forKey: "dailyWakeRecords_v1"),
           let decoded = try? JSONDecoder().decode([DailyWakeRecord].self, from: data) {
            wakeRecords = decoded
        }
    }

    private func saveWakeTime(_ selectedTime: Date) {
        let calendar = Calendar.current
        let today    = calendar.startOfDay(for: Date())
        let comps    = calendar.dateComponents([.hour, .minute], from: selectedTime)
        guard let wakeTime = calendar.date(
            bySettingHour: comps.hour ?? 7,
            minute:        comps.minute ?? 0,
            second:        0,
            of:            today
        ) else { return }

        wakeRecords.removeAll { calendar.isDate($0.day, inSameDayAs: today) }
        wakeRecords.append(DailyWakeRecord(day: today, wakeTime: wakeTime))

        if let encoded = try? JSONEncoder().encode(wakeRecords) {
            UserDefaults.standard.set(encoded, forKey: "dailyWakeRecords_v1")
            NotificationCenter.default.post(name: .dailyWakeRecordsDidChange, object: nil)
        }

        closeOngoingNightSleepIfWakeTimeEndsIt(wakeTime)
    }

    private func closeOngoingNightSleepIfWakeTimeEndsIt(_ wakeTime: Date) {
        guard let ongoing = records
            .filter({ $0.kind == .nightSleep && $0.isOngoing && wakeTime > $0.date })
            .sorted(by: { $0.date > $1.date })
            .first
        else { return }

        let duration = max(1, Int(wakeTime.timeIntervalSince(ongoing.date) / 60))
        let closed = SleepRecord(
            id: ongoing.id,
            date: ongoing.date,
            duration: min(duration, 12 * 60),
            kind: ongoing.kind,
            parentNapID: ongoing.parentNapID,
            isOngoing: false,
            createdAt: ongoing.createdAt
        )
        upsert(closed)
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
        records.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var todaySleeps: [SleepRecord] {
        todayRecords.filter { $0.kind != .break }.sorted { $0.date < $1.date }
    }

    private var todayWakeRecord: DailyWakeRecord? {
        wakeRecords.first { Calendar.current.isDateInToday($0.day) }
    }

    private var shouldShowTodayWakeUpPrompt: Bool {
        todayWakeRecord == nil &&
        (!isStillInNightSleep || Calendar.current.component(.hour, from: Date()) >= 5)
    }

    private var defaultWakeTime: Date {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    }
    

    
    private var displayedParentName: String {
        let name = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "there" }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var todayTotal: Int { totalMinutes(for: todayRecords) }

    private var yesterdayTotal: Int {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) else { return 0 }
        return totalMinutes(for: records.filter { cal.isDate($0.date, inSameDayAs: yesterday) })
    }

    private var todayDelta: Int { todayTotal - yesterdayTotal }

    private var last7DaysAverage: Int {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totals = (0..<7).map { offset -> Int in
            let day   = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            let items = records.filter { cal.isDate($0.date, inSameDayAs: day) }
            return totalMinutes(for: items)
        }
        return totals.reduce(0, +) / max(totals.count, 1)
    }

    private var previous7DaysAverage: Int {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totals = (7..<14).map { offset -> Int in
            let day   = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            let items = records.filter { cal.isDate($0.date, inSameDayAs: day) }
            return totalMinutes(for: items)
        }
        return totals.reduce(0, +) / max(totals.count, 1)
    }

    private var averageNapMinutes: Int {
        let comparable = sleeps.dropFirst().map { $0.totalMinutes(breaks: breaks) }
        guard !comparable.isEmpty else { return 80 }
        return comparable.reduce(0, +) / comparable.count
    }

    private var latestNapDelta: Int { latestSleepMinutes - averageNapMinutes }

    private var consistencyPercent: Int {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totals = (0..<7).compactMap { offset -> Int? in
            let day   = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            let items = records.filter { cal.isDate($0.date, inSameDayAs: day) }
            let t     = totalMinutes(for: items)
            return t > 0 ? t : nil
        }
        guard totals.count > 1 else { return records.isEmpty ? 87 : 74 }
        let avg      = Double(totals.reduce(0, +)) / Double(totals.count)
        let variance = totals.reduce(0.0) { $0 + pow(Double($1) - avg, 2) } / Double(totals.count)
        let dev      = sqrt(variance)
        return max(55, min(97, Int(100 - (dev / max(avg, 1) * 100))))
    }

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
    private var wakeWindowBeforeLatest: Int {
        guard let firstNap = todaySleeps
            .filter({ $0.kind == .dayNap })
            .sorted(by: { $0.date < $1.date })
            .first
        else { return 158 }

        if let wt = todayWakeRecord?.wakeTime {
            return max(0, Int(firstNap.date.timeIntervalSince(wt) / 60))
        }

        // Wake record yok — önceki naptan tahmin et
        let older = todaySleeps
            .filter { $0.date < firstNap.date }
            .sorted { $0.date > $1.date }

        if let prev = older.first,
           let prevEnd = Calendar.current.date(
               byAdding: .minute, value: prev.duration, to: prev.date
           ) {
            return max(0, Int(firstNap.date.timeIntervalSince(prevEnd) / 60))
        }

        return 120 // fallback
    }

    private var insightText: String {
        if let llm = orchestrator.llmResponse?.coachMessage, !llm.isEmpty { return llm }
        if orchestrator.isLLMLoading { return "Analyzing \(babyName)'s sleep patterns..." }
        return orchestrator.snapshot?.insights.coachTip
            ?? "Start with one sleep session and your baby's wake window will become easier to predict."
    }

    // MARK: - Expected Nap Slots Helper

        private var expectedNapSlotCount: Int {
            guard let ageMonths = orchestrator.snapshot?.ageMonths else { return 2 }
            let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
            return profile.expectedNapCount.upperBound
        }

        private var timelineItems: [TimelineItem] {
            let now = Date()
            let sortedNaps = todaySleeps
                .filter { $0.kind == .dayNap }
                .sorted { $0.date < $1.date }
            let wakeUp = timelineWakeAnchor(sortedNaps: sortedNaps)
            let expectedDuration = timelineExpectedNapDuration
            var items: [TimelineItem] = [
                TimelineItem(
                    icon: "sun.max.fill",
                    iconColor: Color(red: 1.0, green: 0.68, blue: 0.20),
                    time: shortTime(wakeUp),
                    title: "Wake up",
                    detail: timelineWakeDetail,
                    visualState: wakeUp <= now ? .completed : .upcoming,
                    isActive: false,
                    isFuture: wakeUp > now
                )
            ]

            var anchorEnd = wakeUp
            for (index, nap) in sortedNaps.enumerated() {
                guard items.count < 4 else { return items }
                let napEnd = Calendar.current.date(byAdding: .minute, value: nap.duration, to: nap.date) ?? nap.date
                let awakeBeforeNap = max(0, Int(nap.date.timeIntervalSince(anchorEnd) / 60))
                let isActiveNap = nap.isOngoing || (nap.date <= now && napEnd > now)
                let state: TimelineItem.VisualState = isActiveNap ? .active : (napEnd <= now ? .completed : .upcoming)

                items.append(TimelineItem(
                    icon: "moon.fill",
                    iconColor: timelineNapColor(state: state),
                    time: shortTime(nap.date),
                    title: "Nap \(index + 1)",
                    detail: nap.isOngoing ? "Sleeping now" : TimeFormat.minutes(nap.totalMinutes(breaks: breaks)),
                    visualState: state,
                    isActive: isActiveNap,
                    isFuture: nap.date > now,
                    awakeBeforeMinutes: awakeBeforeNap
                ))
                anchorEnd = napEnd
            }

            let shouldPredictMoreNaps = orchestrator.snapshot?.nextSleepKind != .bedtime
            var predictedIndex = sortedNaps.count + 1
            while shouldPredictMoreNaps && items.count < 4 && predictedIndex <= expectedNapSlotCount {
                let predictedStart = timelinePredictedNapStart(
                    napIndex: predictedIndex,
                    anchorEnd: anchorEnd
                )
                let awakeBeforeNap = max(0, Int(predictedStart.timeIntervalSince(anchorEnd) / 60))

                items.append(TimelineItem(
                    icon: "moon.fill",
                    iconColor: timelineNapColor(state: .upcoming),
                    time: shortTime(predictedStart),
                    title: "Nap \(predictedIndex)",
                    detail: "~\(TimeFormat.minutes(expectedDuration))",
                    visualState: .upcoming,
                    isActive: false,
                    isFuture: true,
                    awakeBeforeMinutes: awakeBeforeNap
                ))

                anchorEnd = predictedStart.addingMinutes(expectedDuration)
                predictedIndex += 1
            }

            if items.count < 4 {
                let bedtime = timelineBedtime(after: anchorEnd)
                let awakeBeforeBed = max(0, Int(bedtime.timeIntervalSince(anchorEnd) / 60))
                items.append(TimelineItem(
                    icon: "moon.stars.fill",
                    iconColor: Color.sleepPurpleDeep,
                    time: shortTime(bedtime),
                    title: "Bedtime",
                    detail: "Night sleep",
                    visualState: bedtime <= now ? .completed : .upcoming,
                    isActive: false,
                    isFuture: bedtime > now,
                    awakeBeforeMinutes: awakeBeforeBed
                ))
            }

            return items
        }
    
    private var completedNapCountToday: Int {
        todaySleeps.filter { $0.kind == .dayNap }.count
    }

    private var timelineProfile: AgeBasedSleepProfile {
        let ageMonths = orchestrator.snapshot?.ageMonths ?? 10
        return DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
    }

    private var timelineExpectedNapDuration: Int {
        if let minutes = orchestrator.snapshot?.daytime.expectedDurationMinutes {
            return minutes
        }
        let profile = timelineProfile
        let target = profile.daytimeSleepRange.lowerBound / max(profile.expectedNapCount.upperBound, 1)
        return min(profile.maxSingleNapMinutes, max(45, target))
    }

    private var timelineWakeDetail: String {
        if todayWakeRecord != nil { return "Logged" }
        return "Default wake"
    }

    private func timelineWakeAnchor(sortedNaps: [SleepRecord]) -> Date {
        if let wake = todayWakeRecord?.wakeTime { return wake }
        if let firstNap = sortedNaps.first {
            let wakeWindow = timelineWakeWindow(forNapIndex: 1)
            return Calendar.current.date(byAdding: .minute, value: -wakeWindow, to: firstNap.date) ?? firstNap.date
        }
        return defaultWakeTime
    }

    private func timelineWakeWindow(forNapIndex index: Int) -> Int {
        if index == completedNapCountToday + 1,
           let minutes = orchestrator.snapshot?.daytime.wakeWindowUsed {
            return minutes
        }

        let profile = timelineProfile
        if index <= 1 {
            return (profile.morningWakeWindow.lowerBound + profile.morningWakeWindow.upperBound) / 2
        }
        if index >= profile.expectedNapCount.upperBound + 1 {
            return (profile.eveningWakeWindow.lowerBound + profile.eveningWakeWindow.upperBound) / 2
        }
        return (profile.wakeWindowRange.lowerBound + profile.wakeWindowRange.upperBound) / 2
    }

    private func timelinePredictedNapStart(napIndex: Int, anchorEnd: Date) -> Date {
        if napIndex == completedNapCountToday + 1,
           let nextNap = orchestrator.snapshot?.daytime.nextNapTime {
            return nextNap
        }
        return anchorEnd.addingMinutes(timelineWakeWindow(forNapIndex: napIndex))
    }

    private func timelineBedtime(after anchorEnd: Date) -> Date {
        if let bedtime = orchestrator.snapshot?.night.optimalBedtimeStart {
            return bedtime
        }

        let profile = timelineProfile
        let proposed = anchorEnd.addingMinutes(timelineWakeWindow(forNapIndex: expectedNapSlotCount + 1))
        let hour = Calendar.current.component(.hour, from: proposed)
        guard hour < profile.bedtimeHourRange.lowerBound || hour > profile.bedtimeHourRange.upperBound else {
            return proposed
        }
        return Calendar.current.date(
            bySettingHour: min(max(hour, profile.bedtimeHourRange.lowerBound), profile.bedtimeHourRange.upperBound),
            minute: Calendar.current.component(.minute, from: proposed),
            second: 0,
            of: proposed
        ) ?? proposed
    }

    private func timelineNapColor(state: TimelineItem.VisualState) -> Color {
        switch state {
        case .completed:
            return Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.42)
        case .active:
            return Color.sleepPurpleDeep
        case .upcoming:
            return Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.58)
        }
    }
    // MARK: - Helpers

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let naps   = items.filter { $0.kind != .break }
        let breaks = items.filter { $0.kind == .break }
        return naps.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
    }

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

    private func deleteDay(_ day: Date) {
        let cal = Calendar.current
        records.removeAll { cal.isDate($0.date, inSameDayAs: day) }
        saveRecords()
    }


    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    headerSection
                    nextNapOrBedtimeCard
                    rhythmLearningStrip
                    todayWakeSection
                       todayTimelineCard
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
                loadRecords()
                loadWakeRecords()
                orchestrator.loadCachedLLMResponse()
                orchestrator.generate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in
                loadRecords()
                orchestrator.generate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dailyWakeRecordsDidChange)) { _ in
                loadWakeRecords()
                orchestrator.generate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .babyProfileDidChange)) { _ in
                orchestrator.generate()
            }
            .environment(\.locale, Locale(identifier: "en_US"))
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {

            case .addSleep(let editing, let date):
                AddRecordView(
                    defaultDate: date,
                    editingRecord: editing,
                    vm: AddRecordViewModel(),
                    onSave: { record in upsert(record) }
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
                    onSave: { newBreak in
                        records.append(newBreak)
                        saveRecords()
                    }
                )

            case .dayDetail(let selected):
                let dayRecords = records
                    .filter { Calendar.current.isDate($0.date, inSameDayAs: selected.day) }
                    .sorted { $0.date < $1.date }
                DayDetailView(
                    day: selected.day,
                    records: dayRecords,
                    onDelete: { ids in
                        records.removeAll { ids.contains($0.id) }
                        saveRecords()
                    },
                    onAddSleep: { day in
                        activeSheet = .addSleep(editing: nil, defaultDate: day)
                    },
                    onEditNap: { nap in
                        activeSheet = .addSleep(editing: nap, defaultDate: nap.date)
                    },
                    onBreakSaved: { newBreak in
                        records.append(newBreak)
                        saveRecords()
                    }
                )
            case .wakeTime:
                WakeTimeEditorView(
                    initialTime: todayWakeRecord?.wakeTime ?? defaultWakeTime,
                    onSave: saveWakeTime
                )
            }
        }
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

    private var rhythmLearningDays: Int {
        orchestrator.snapshot.map { max(0, 14 - $0.readiness.daysUntilPersonalized) } ?? 0
    }

    private var rhythmLearningProgress: Double {
        min(1.0, max(0.0, Double(rhythmLearningDays) / 14.0))
    }

    private var rhythmQualityLabel: String {
        guard let report = orchestrator.snapshot?.dataQualityReport else { return "Collecting data" }
        switch report.score {
        case 90...100: return "Excellent data quality"
        case 70..<90:  return "Good data quality"
        case 50..<70:  return "Data quality building"
        default:       return "Needs more logs"
        }
    }

    private var rhythmLearningHint: String {
        guard let report = orchestrator.snapshot?.dataQualityReport else {
            return "Log wake time and naps today"
        }
        if report.timelinessScore < 70 {
            return "Log closer to sleep times"
        }
        if report.completeDays < min(7, max(1, report.trackedDays)) {
            return "Complete today's wake and nap logs"
        }
        if rhythmLearningDays >= 14 {
            return "Personalized predictions active"
        }
        return "\(14 - rhythmLearningDays) days until stronger personalization"
    }

    private var rhythmLearningStrip: some View {
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
                    Text("Learning your baby's rhythm...")
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
                        .foregroundStyle(Color(.tertiaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.06), radius: 10, x: 0, y: 4)
    }

    // MARK: - Sleep Overview Card

    private var sleepOverviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            }

            HStack(spacing: 10) {
                summaryCell(
                    icon: "moon.fill",
                    iconColor: Color(red: 0.45, green: 0.35, blue: 0.92),
                    title: "Sleep",
                    value: todayTotal > 0 ? "\(todayTotal / 60)h \(todayTotal % 60)m" : "0m",
                    badge: goalBadgeText,
                    badgeColor: goalBadgeColor
                )

                summaryCell(
                    icon: "moon.zzz.fill",
                    iconColor: Color(red: 0.45, green: 0.35, blue: 0.92),
                    title: "Naps",
                    value: "\(todayNapCount)",
                    badge: napBadgeText,
                    badgeColor: napBadgeColor
                )

                summaryCell(
                    icon: "waveform.path",
                    iconColor: Color(red: 0.45, green: 0.35, blue: 0.92),
                    title: "Rhythm",
                    value: TimeFormat.minutes(orchestrator.snapshot?.pattern?.averageWakeWindowMinutes ?? wakeWindowBeforeLatest),
                    badge: wakeWindowBadgeText,
                    badgeColor: wakeWindowBadgeColor
                )
            }

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
                            .frame(width: max(8, geo.size.width * todayGoalProgress))
                    }
                }
                .frame(height: 7)

                HStack {
                    Text("\(Int(todayGoalProgress * 100))% of daily goal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer()
                    Text("Goal: 14h")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
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
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor.opacity(0.7))
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Badge Helpers

    private var todayNapCount: Int {
        todaySleeps.filter { $0.kind == .dayNap }.count
    }

    private var todayGoalProgress: Double {
        min(Double(todayTotal) / 840.0, 1.0)
    }

    private var goalBadgeText: String {
        let pct = Int(min(Double(todayTotal) / 840.0 * 100, 100))
        if pct >= 100 { return "Goal reached ✓" }
        if pct >= 70  { return "\(pct)% of goal" }
        return "\(pct)% of goal"
    }

    private var goalBadgeColor: Color {
        let pct = Int(min(Double(todayTotal) / 840.0 * 100, 100))
        if pct >= 100 { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        if pct >= 70  { return Color(red: 0.45, green: 0.35, blue: 0.92) }
        return Color(.secondaryLabel)
    }

    private var napBadgeText: String {
        guard let ageMonths = orchestrator.snapshot?.ageMonths else { return "–" }
        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
        let expected = profile.expectedNapCount
        if todayNapCount >= expected.lowerBound { return "On track" }
        let remaining = expected.lowerBound - todayNapCount
        return "\(remaining) more needed"
    }

    private var napBadgeColor: Color {
        guard let ageMonths = orchestrator.snapshot?.ageMonths else { return Color(.secondaryLabel) }
        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
        let expected = profile.expectedNapCount
        if todayNapCount >= expected.lowerBound { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        return Color(.secondaryLabel)
    }

    private var wakeWindowBadgeText: String {
        let pct = consistencyPercent
        if pct >= 80 { return "Good" }
        if pct >= 60 { return "Building" }
        return "Low"
    }

    private var wakeWindowBadgeColor: Color {
        let pct = consistencyPercent
        if pct >= 80 { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        if pct >= 60 { return Color(red: 0.45, green: 0.35, blue: 0.92) }
        return Color(.secondaryLabel)
    }
    
    // Henüz typical wake time gelmediyse ve bugün hiç kayıt yoksa, bebek hâlâ gece uykusunda kabul edilir.
    // Ayrıca herhangi bir devam eden uyku kaydı varsa kart canlı uyku durumuna geçer.
    private var isStillInNightSleep: Bool {
        // Case 1: Herhangi bir ongoing sleep kaydı var (dünden de olabilir)
        if records.contains(where: { $0.kind != .break && $0.isOngoing }) {
            return true
        }
        // Case 2: Hiç kayıt yok ve typicalWakeHour henüz gelmedi
        guard todayWakeRecord == nil, todaySleeps.isEmpty else { return false }
        let wakeHour   = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
        let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
        let today = Calendar.current.startOfDay(for: Date())
        let typicalWake = Calendar.current.date(
            bySettingHour: Int(wakeHour), minute: Int(wakeMinute), second: 0, of: today
        ) ?? Date()
        return Date() < typicalWake
        
        
    }    // MARK: next nap or bedtime?

    @ViewBuilder
    private var nextNapOrBedtimeCard: some View {
        if isStillInNightSleep {
            stillSleepingCard
        } else {
            regularNextNapOrBedtimeCard
        }
    }
    
    // MARK: - Live Night Sleep Card Wrapper

    private var stillSleepingCard: some View {
        // 1. UserDefaults'tan ham kayıtları oku (Orchestrator'daki loader'ın aynısı)
        let rawRecords: [SleepRecord] = {
            guard let data = UserDefaults.standard.data(forKey: "sleepRecords"),
                  let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data)
            else { return [] }
            return decoded
        }()
        
        // 2. Bu kayıtlar içinden aktif olan uykuyu filtrele
        let ongoingSleep = rawRecords
            .filter { $0.isOngoing && $0.kind != .break }
            .sorted { $0.date > $1.date }
            .first
        
        // Tahmini uyanma saati
        let expectedWake = expectedWakeTime(for: ongoingSleep)
        let nextSleepAfterCurrent = nextSleepTimeAfterCurrentSleep(
            ongoingSleep: ongoingSleep,
            expectedWake: expectedWake
        )

        return CurrentSleepSessionCard(
            ongoingNight: ongoingSleep,
            expectedWakeTime: expectedWake,
            nextSleepTime: nextSleepAfterCurrent
        )
    }

    private func expectedWakeTime(for ongoingSleep: SleepRecord?) -> Date {
        guard let ongoingSleep else {
            let wakeHour = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
            let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
            return Calendar.current.date(
                bySettingHour: Int(wakeHour),
                minute: Int(wakeMinute),
                second: 0,
                of: Date()
            ) ?? defaultWakeTime
        }

        if ongoingSleep.kind == .dayNap {
            let expectedNapMinutes = ongoingSleep.duration > 0
                ? ongoingSleep.duration
                : (orchestrator.snapshot?.pattern?.averageNapDurationMinutes ?? 75)
            return Calendar.current.date(
                byAdding: .minute,
                value: expectedNapMinutes,
                to: ongoingSleep.date
            ) ?? Date()
        }

        let wakeHour = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
        let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
        let candidate = Calendar.current.date(
            bySettingHour: Int(wakeHour),
            minute: Int(wakeMinute),
            second: 0,
            of: Date()
        ) ?? defaultWakeTime

        if candidate > ongoingSleep.date {
            return candidate
        }

        return Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private func nextSleepTimeAfterCurrentSleep(ongoingSleep: SleepRecord?, expectedWake: Date) -> Date? {
        guard let ongoingSleep else {
            return orchestrator.snapshot?.daytime.nextNapTime
        }

        if ongoingSleep.kind == .nightSleep {
            return orchestrator.snapshot?.daytime.nextNapTime
        }

        return Calendar.current.date(
            byAdding: .minute,
            value: recommendedWakeWindowMinutes,
            to: expectedWake
        )
    }
    
    
    // MARK: - Today Wake Up Card

    @ViewBuilder
    private var todayWakeSection: some View {
        if let wakeTime = todayWakeRecord?.wakeTime {
            WakeUpCard(time: wakeTime)
        } else if shouldShowTodayWakeUpPrompt {
            todayWakeUpCard
        }
    }

    private var todayWakeUpCard: some View {
        Button { activeSheet = .wakeTime } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 48, height: 48)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wake-up time needed")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text("Add \(babyName)'s actual wake-up time\nfor more accurate predictions.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Add wake time")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            }
            .padding(16)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(CardPressButtonStyle())
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
            activeSheet = .wakeTime
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
                        } else if orchestrator.llmResponse != nil {
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

                Text(insightText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(.label).opacity(0.82))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
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
    
    // MARK: - Timeline Card

    private var todayTimelineCard: some View {
        
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isStillInNightSleep ? "Plan for Today" : "Today's Timeline")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(.label))
                Spacer()
                Button {
                    activeSheet = .dayDetail(SelectedDay(day: Date()))
                } label: {
                    HStack(spacing: 5) {
                        Text("View full timeline")
                            .font(.system(size: 13, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.92))
                }
                .buttonStyle(.plain)
            }

            if isStillInNightSleep {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.98))
                    Text("The plan adjusts as the day goes on. Predictions refresh after every new record.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.07))
                )
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                    premiumTimelineNode(item)
                    if index < timelineItems.count - 1 {
                        premiumTimelineSegment(
                            awakeMinutes: timelineItems[index + 1].awakeBeforeMinutes,
                            isDashed:     timelineItems[index + 1].isFuture,
                            fromColor:    item.iconColor,
                            toColor:      timelineItems[index + 1].iconColor
                        )
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.systemBackground))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.05),
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
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.08),
                radius: 16, x: 0, y: 6)
    }
    // MARK: - Premium Timeline Node

    private func premiumTimelineNode(_ item: TimelineItem) -> some View {
        let isActive = item.visualState == .active
        let isCompleted = item.visualState == .completed
        let fillOpacity = isActive ? 0.18 : (isCompleted ? 0.08 : 0.10)
        let iconOpacity = isActive ? 1.0 : (isCompleted ? 0.48 : 0.62)
        let textOpacity = isActive ? 1.0 : (isCompleted ? 0.52 : 0.72)

        return VStack(spacing: 6) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(item.iconColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                        .blur(radius: 7)
                }

                Circle()
                    .fill(item.iconColor.opacity(fillOpacity))
                    .frame(width: 34, height: 34)

                if item.visualState == .upcoming {
                    Circle()
                        .strokeBorder(
                            item.iconColor.opacity(0.34),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                        )
                        .frame(width: 34, height: 34)
                } else {
                    Circle()
                        .strokeBorder(item.iconColor.opacity(isActive ? 0.65 : 0.24), lineWidth: isActive ? 1.8 : 1)
                        .frame(width: 34, height: 34)
                }

                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.iconColor.opacity(iconOpacity))
            }

            VStack(spacing: 2) {
                Text(item.time)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel).opacity(textOpacity))
                    .monospacedDigit()

                Text(item.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle((isActive ? Color(.label) : Color(.secondaryLabel)).opacity(textOpacity))
                    .multilineTextAlignment(.center)

                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.iconColor.opacity(isActive ? 0.9 : iconOpacity))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: 58)
    }

    // MARK: - Premium Timeline Segment

    private func premiumTimelineSegment(
        awakeMinutes: Int,
        isDashed:     Bool,
        fromColor:    Color,
        toColor:      Color
    ) -> some View {
        VStack(spacing: 3) {
            if isDashed {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 1.5)
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.25),
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                            )
                    )
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [fromColor.opacity(0.4), toColor.opacity(0.4)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1.5)
            }

            if awakeMinutes > 0 {
                Text(TimeFormat.minutes(awakeMinutes))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
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
        let total = totalMinutes(for: group.items)
        let sessions = group.items.filter { $0.kind != .break }.count
        let progress = min(Double(total) / 840.0, 1.0)

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

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(dayAccent(for: rank).opacity(0.10))
                        Capsule()
                            .fill(dayAccent(for: rank).opacity(0.70))
                            .frame(width: max(6, geo.size.width * progress))
                    }
                }
                .frame(height: 5)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(TimeFormat.minutes(total))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.sleepInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(dayQualityLabel(total))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(dayQualityColor(total))
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

    private func dayQualityLabel(_ minutes: Int) -> String {
        if minutes >= 840 { return "Goal" }
        if minutes >= 600 { return "Steady" }
        if minutes > 0 { return "Light" }
        return "Empty"
    }

    private func dayQualityColor(_ minutes: Int) -> Color {
        if minutes >= 840 { return Color(red: 0.16, green: 0.68, blue: 0.46) }
        if minutes >= 600 { return Color(red: 0.45, green: 0.35, blue: 0.92) }
        if minutes > 0 { return Color(red: 1.0, green: 0.68, blue: 0.12) }
        return Color(.secondaryLabel)
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

private extension Color {
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
