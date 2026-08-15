import SwiftUI
import Charts

struct HistoryView: View {
    
    // MARK: - Range Picker (tüm sayfayı filtreleyecek)

    private enum HistoryRange: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case overview = "Overview"
    }

    @State private var records: [SleepRecord] = []
    @State private var selectedRange: HistoryRange = .day
    @State private var referenceDate: Date = Date()
    @State private var selectedDate: Date = Date()
    @State private var currentWeekOffset: Int = 0
    @State private var animateChart = false
    
    @State private var selectedTimelineRecord: SleepRecord? = nil

    @AppStorage("babyName") private var babyName: String = "Baby"

    private let calendar = Calendar.current
    private let nowTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()


    private func loadRecords() {
        if let data = UserDefaults.standard.data(forKey: "sleepRecords"),
           let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data) {
            records = decoded
        }
    }
        

    // MARK: - Week days

    private var weekDays: [Date] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        // Pazartesi başlangıç (1=Sun → offset 2, 2=Mon → offset 1 ...)
        let mondayOffset = (weekday == 1 ? -6 : -(weekday - 2))
        let monday = calendar.date(byAdding: .day, value: mondayOffset + (currentWeekOffset * 7), to: today)!
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: monday)! }
    }

    private var monthYearTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: weekDays[3])
    }

    // MARK: - Selected day data

    private var selectedDayRecords: [SleepRecord] {
        records.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var selectedDayNaps: [SleepRecord] {
        selectedDayRecords.filter { $0.kind != .break }.sorted { $0.date < $1.date }
    }

    private var selectedDayBreaks: [SleepRecord] {
        selectedDayRecords.filter { $0.kind == .break }
    }

    private var selectedDayNetSleep: Int {
        totalMinutes(for: selectedDayRecords)
    }

    private var selectedDayWakePeriods: Int {
        selectedDayBreaks.count
    }

    // MARK: - Sleep Timeline

        private var timelineWindowStart: Date {
            let startOfSelected = calendar.startOfDay(for: selectedDate)
            return calendar.date(byAdding: .hour, value: -6, to: startOfSelected) ?? startOfSelected
        }

        private var timelineWindowEnd: Date {
            calendar.date(byAdding: .hour, value: 24, to: timelineWindowStart) ?? timelineWindowStart
        }

        private var timelineRecords: [SleepRecord] {
            records.filter { record in
                let end = record.date.addingTimeInterval(TimeInterval(record.effectiveDuration * 60))
                return end > timelineWindowStart && record.date < timelineWindowEnd
            }
        }

        private var timelineNightSegments: [SleepRecord] { timelineRecords.filter { $0.kind == .nightSleep } }
        private var timelineNapSegments: [SleepRecord]   { timelineRecords.filter { $0.kind == .dayNap } }
        private var timelineBreakSegments: [SleepRecord] { timelineRecords.filter { $0.kind == .break } }

        private var timelineTotalSleepMinutes: Int {
            let breaks = timelineRecords.filter { $0.kind == .break }
            return timelineRecords.filter { $0.kind != .break }.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
        }

        private var timelineNapCount: Int { timelineNapSegments.count }

        private var timelineLongestStretchMinutes: Int {
            let breaks = timelineRecords.filter { $0.kind == .break }
            return timelineRecords.filter { $0.kind != .break }.map { $0.totalMinutes(breaks: breaks) }.max() ?? 0
        }

        private var timelineDateLabel: String {
            if calendar.isDateInToday(selectedDate) { return "Today, \(shortDay(selectedDate))" }
            if calendar.isDateInYesterday(selectedDate) { return "Yesterday, \(shortDay(selectedDate))" }
            return shortDay(selectedDate)
        }

        private func shortDay(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "d MMM"
            return f.string(from: date)
        }

        private func fraction(for date: Date) -> Double {
            let total = timelineWindowEnd.timeIntervalSince(timelineWindowStart)
            guard total > 0 else { return 0 }
            let clamped = min(max(date, timelineWindowStart), timelineWindowEnd)
            return clamped.timeIntervalSince(timelineWindowStart) / total
        }

        /// "now" çizgisi sadece pencere bugünü kapsıyorsa gösterilir
        private var shouldShowNowLine: Bool {
            let now = Date()
            return now >= timelineWindowStart && now <= timelineWindowEnd
        }

        private var sleepTimelineCard: some View {
            VStack(alignment: .leading, spacing: 16) {

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SLEEP TIMELINE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HistoryColor.purple)
                            .tracking(0.4)

                        HStack(spacing: 14) {
                            legendDot(color: HistoryColor.purple, label: "Night sleep")
                            legendDot(color: HistoryColor.green, label: "Nap")
                            legendDot(color: HistoryColor.sun.opacity(0.55), label: "Awake")
                        }
                    }

                    Spacer()

                    Menu {
                        Button("Today") {
                            selectedDate = Date()
                            referenceDate = Date()
                        }
                        Button("Yesterday") {
                            let date = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                            selectedDate = date
                            referenceDate = date
                        }
                        Button("Go back a day") {
                            let date = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                            selectedDate = date
                            referenceDate = date
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(timelineDateLabel)
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(HistoryColor.purple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(HistoryColor.purple.opacity(0.10)))
                        .overlay(Capsule().stroke(HistoryColor.purple.opacity(0.14), lineWidth: 1))
                    }
                }

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        timelineRow(
                            icon: "moon.stars.fill", iconColor: HistoryColor.purple.opacity(0.72),
                            segments: timelineNightSegments, barStyle: AnyShapeStyle(
                                LinearGradient(
                                    colors: [HistoryColor.purple.opacity(0.72), HistoryColor.purpleDeep.opacity(0.82)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            ),
                            rowHeight: 34, now: context.date
                        )
                        timelineRow(
                            icon: "sun.max.fill", iconColor: HistoryColor.sun.opacity(0.68),
                            segments: timelineNapSegments, barStyle: AnyShapeStyle(
                                LinearGradient(
                                    colors: [HistoryColor.green.opacity(0.70), HistoryColor.green.opacity(0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            ),
                            rowHeight: 34, now: context.date
                        )
                        timelineRow(
                            icon: "sun.max", iconColor: HistoryColor.sun.opacity(0.66),
                            segments: timelineBreakSegments, barStyle: AnyShapeStyle(HistoryColor.sun.opacity(0.42)),
                            rowHeight: 16, now: context.date
                        )

                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                ForEach(timelineHourLabels, id: \.self) { label in
                                    Text(label)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(HistoryColor.muted.opacity(0.82))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .frame(height: 14)
                        .padding(.leading, 30)
                    }
                }

                HStack(spacing: 0) {
                    timelineStat(icon: "sparkles", iconColor: HistoryColor.purple, label: "Total sleep", value: TimeFormat.minutes(timelineTotalSleepMinutes), valueColor: HistoryColor.purple)
                    Divider().frame(height: 30)
                    timelineStat(icon: nil, iconColor: HistoryColor.green, label: "Naps", value: "\(timelineNapCount)", valueColor: HistoryColor.green)
                    Divider().frame(height: 30)
                    timelineStat(icon: nil, iconColor: HistoryColor.purple, label: "Longest stretch", value: TimeFormat.minutes(timelineLongestStretchMinutes), valueColor: HistoryColor.purple)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [HistoryColor.purple.opacity(0.08), HistoryColor.sun.opacity(0.06)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(HistoryColor.card)
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(HistoryColor.stroke, lineWidth: 1))
            .shadow(color: HistoryColor.purpleDeep.opacity(0.07), radius: 14, x: 0, y: 6)
        }

        private var timelineHourLabels: [String] {
            let ticks = 6
            return (0...ticks).map { i in
                let date = calendar.date(byAdding: .hour, value: (24 / ticks) * i, to: timelineWindowStart) ?? timelineWindowStart
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "h a"
                return f.string(from: date)
            }
        }

        private func legendDot(color: Color, label: String) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }

        /// Ongoing kayıt için "canlı bitiş" — bugünse Date(), değilse kayıtlı effectiveDuration
        private func liveEnd(for record: SleepRecord, now: Date) -> Date {
            guard record.isOngoing else {
                return record.date.addingTimeInterval(TimeInterval(record.duration * 60))
            }
            return min(now, timelineWindowEnd)
        }

        private func timelineRow(
            icon: String,
            iconColor: Color,
            segments: [SleepRecord],
            barStyle: AnyShapeStyle,
            rowHeight: CGFloat,
            now: Date
        ) -> some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: rowHeight / 2.4, style: .continuous)
                            .fill(HistoryColor.track)
                            .frame(height: rowHeight)

                        ForEach(segments) { record in
                            let end = liveEnd(for: record, now: now)
                            let startX = fraction(for: record.date) * geo.size.width
                            let endX = fraction(for: end) * geo.size.width
                            let width = max(6, endX - startX)

                            Button {
                                selectedTimelineRecord = record
                            } label: {
                                RoundedRectangle(cornerRadius: rowHeight / 2.4, style: .continuous)
                                    .fill(barStyle)
                                    .frame(width: width, height: rowHeight)
                                    .overlay(
                                        // ongoing ise ucunda hafif nabız efekti
                                        record.isOngoing
                                        ? RoundedRectangle(cornerRadius: rowHeight / 2.4, style: .continuous)
                                            .stroke(HistoryColor.purple.opacity(0.28), lineWidth: 2)
                                            .padding(-2)
                                        : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .offset(x: startX)
                        }

                        // Dikey "now" çizgisi — soluk, kesikli
                        if shouldShowNowLine {
                            let nowX = fraction(for: now) * geo.size.width
                            Rectangle()
                                .fill(HistoryColor.muted.opacity(0.35))
                                .frame(width: 1, height: rowHeight + 6)
                                .overlay(
                                    Rectangle()
                                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                        .foregroundStyle(HistoryColor.muted.opacity(0.5))
                                )
                                .offset(x: nowX - 0.5, y: -3)
                        }
                    }
                }
                .frame(height: rowHeight)
            }
        }

        private func timelineStat(icon: String?, iconColor: Color, label: String, value: String, valueColor: Color = .primary) -> some View {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(iconColor)
                    }
                    Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(HistoryColor.muted)
                }
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Persist helper (bar tıklama sonrası edit için)

        private func upsertRecord(_ record: SleepRecord) {
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx] = record
            } else {
                records.append(record)
            }
            if let encoded = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(encoded, forKey: "sleepRecords")
                NotificationCenter.default.post(name: .sleepRecordsDidChange, object: nil)
            }
        }
    
    // MARK: - Yesterday comparison

    private var yesterdayNetSleep: Int {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: selectedDate) else { return 0 }
        let recs = records.filter { calendar.isDate($0.date, inSameDayAs: yesterday) }
        return totalMinutes(for: recs)
    }

    private var vsYesterday: Int { selectedDayNetSleep - yesterdayNetSleep }

    // MARK: - Week chart data

    struct DailySleep: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let minutes: Int
    }

    private var weekChartData: [DailySleep] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US")
        dayFormatter.dateFormat = "EEE"
        return weekDays.map { day in
            let recs = records.filter { calendar.isDate($0.date, inSameDayAs: day) }
            return DailySleep(
                date: day,
                label: dayFormatter.string(from: day),
                minutes: totalMinutes(for: recs)
            )
        }
    }

    private var weekTotal: Int { weekChartData.map { $0.minutes }.reduce(0, +) }

    private var chartMax: Int {
        let maxVal = weekChartData.map { $0.minutes }.max() ?? 60
        return max(120, Int(ceil(Double(maxVal) / 60.0)) * 60)
    }

    // MARK: - Helpers

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let naps = items.filter { $0.kind != .break }
        let breaks = items.filter { $0.kind == .break }
        return naps.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
    }

    private func hasRecords(on day: Date) -> Bool {
        records.contains { calendar.isDate($0.date, inSameDayAs: day) }
    }

    private var selectedDayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: selectedDate)
    }

    private var dayMessage: String {
        if selectedDayNetSleep == 0 { return "No sleep recorded for this day." }
        if selectedDayNetSleep >= 60 * 2 { return "Great nap day! \(babyName) was happy and rested well." }
        return "Short sleep day. Consider adding more nap time."
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Header ─────────────────────────────
                    headerSection
                    rangePicker

                                      switch selectedRange {
                                      case .day:
                                          sleepTimelineCard
                                      case .week, .month, .overview:
                                          comingSoonPlaceholder
                                      }
                    // ── Calendar strip ─────────────────────
                    calendarStrip

                    // ── Selected day card ──────────────────
                    selectedDayCard

                    // ── Stats row ──────────────────────────
                    statsRow

                    // ── Today's naps ───────────────────────
                    if !selectedDayNaps.isEmpty {
                        napsSection
                    }

                    // ── Comparison banner ──────────────────
                    if yesterdayNetSleep > 0 || selectedDayNetSleep > 0 {
                        comparisonBanner
                    }

                    // ── Week overview chart ────────────────
                    weekChartCard

                    // ── Tip ────────────────────────────────
                    tipCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(HistoryColor.background)
            .navigationBarHidden(true)
            .onAppear { loadRecords() }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in
                loadRecords()
            }
            .sheet(item: $selectedTimelineRecord) { record in
                            AddRecordView(
                                defaultDate: record.date,
                                editingRecord: record,
                                vm: AddRecordViewModel(),
                                onSave: { updated in upsertRecord(updated) }
                            )
                        }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sleep History")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(HistoryColor.ink)
                    .minimumScaleFactor(0.82)

                Text("Track patterns over time • Every night tells a story")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(HistoryColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HistoryColor.card)
                    .frame(width: 58, height: 58)
                    .shadow(color: HistoryColor.purpleDeep.opacity(0.09), radius: 12, x: 0, y: 5)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(HistoryColor.purple)
            }
        }
    }
    
    // MARK: Picker View
    
    private var rangePicker: some View {
            HStack(spacing: 4) {
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedRange = range
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(selectedRange == range ? HistoryColor.purple : HistoryColor.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selectedRange == range ? HistoryColor.purple.opacity(0.10) : Color.clear)
                                    .shadow(color: selectedRange == range ? HistoryColor.purpleDeep.opacity(0.06) : Color.clear, radius: 8, x: 0, y: 3)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(selectedRange == range ? HistoryColor.purple.opacity(0.14) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(HistoryColor.card))
            .overlay(Capsule().stroke(HistoryColor.stroke, lineWidth: 1))
            .shadow(color: HistoryColor.purpleDeep.opacity(0.05), radius: 10, x: 0, y: 4)
        }

        private var comingSoonPlaceholder: some View {
            VStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.system(size: 28))
                    .foregroundStyle(HistoryColor.purple.opacity(0.4))
                Text("\(selectedRange.rawValue) view coming soon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HistoryColor.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(HistoryColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(HistoryColor.stroke, lineWidth: 1)
            )
        }

    // MARK: - Calendar Strip

    private var calendarStrip: some View {
        VStack(spacing: 12) {
            // Month navigation
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentWeekOffset -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                }

                Spacer()

                Text(monthYearTitle)
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentWeekOffset += 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                }
            }

            // Day names
            HStack(spacing: 0) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
                    Text(d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day numbers
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
                    let isToday = calendar.isDateInToday(day)
                    let hasDot = hasRecords(on: day)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedDate = day
                            referenceDate = day
                        }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.orange : Color.clear)
                                    .frame(width: 38, height: 38)

                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 16, weight: isSelected || isToday ? .bold : .regular))
                                    .foregroundStyle(isSelected ? .white : (isToday ? .orange : .primary))
                            }

                            // Dot — record var mı
                            Circle()
                                .fill(hasDot ? (isSelected ? Color.white.opacity(0.8) : Color.orange) : Color.clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Selected Day Card

    private var selectedDayCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.08), Color.indigo.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("🌙")
                .font(.system(size: 70))
                .opacity(0.20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(selectedDayTitle)
                        .font(.title3.weight(.bold))
                    Image(systemName: "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }

                Text(dayMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                icon: "moon.fill",
                iconColor: .indigo,
                iconBg: Color.indigo.opacity(0.12),
                label: "Net Sleep",
                value: selectedDayNetSleep > 0 ? TimeFormat.minutes(selectedDayNetSleep) : "–"
            )
            Divider().frame(height: 44)
            statCell(
                icon: "sun.max.fill",
                iconColor: .orange,
                iconBg: Color.orange.opacity(0.12),
                label: "Sessions",
                value: selectedDayNaps.isEmpty ? "–" : "\(selectedDayNaps.count) nap\(selectedDayNaps.count > 1 ? "s" : "")"
            )
            Divider().frame(height: 44)
            statCell(
                icon: "heart",
                iconColor: .pink,
                iconBg: Color.pink.opacity(0.10),
                label: "Wake Periods",
                value: selectedDayWakePeriods == 0 ? "–" : "\(selectedDayWakePeriods) times"
            )
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func statCell(icon: String, iconColor: Color, iconBg: Color,
                          label: String, value: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBg)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(iconColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Naps Section

    private var napsSection: some View {
        VStack(spacing: 0) {
            ForEach(selectedDayNaps) { nap in
                let napBreaks = selectedDayBreaks.filter { $0.parentNapID == nap.id }.sorted { $0.date < $1.date }
                let napEnd = nap.date.addingTimeInterval(TimeInterval(nap.duration * 60))
                let net = nap.totalMinutes(breaks: selectedDayBreaks)

                VStack(spacing: 0) {
                    // Nap row
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: nap.kind.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(nap.kind == .nightSleep ? "Night Sleep" : "Day Nap")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.indigo)
                            Text("\(TimeFormat.ampm(nap.date)) – \(TimeFormat.ampm(napEnd))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(TimeFormat.minutes(net))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.indigo)
                            Text("Net Sleep")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    // Wake periods
                    if !napBreaks.isEmpty {
                        Divider().padding(.leading, 62)

                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.indigo.opacity(0.10))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.indigo)
                            }

                            Text("Wake Periods")
                                .font(.subheadline)
                                .foregroundStyle(.primary)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                ForEach(napBreaks) { br in
                                    HStack(spacing: 8) {
                                        Text(TimeFormat.ampm(br.date))
                                            .monospacedDigit()
                                        Text("\(br.duration) min")
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                if nap.id != selectedDayNaps.last?.id {
                    Divider().padding(.leading, 62)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Comparison Banner

    private var comparisonBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: vsYesterday >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(vsYesterday >= 0 ? .orange : .indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text("Compared to yesterday")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(vsYesterday == 0
                     ? "Same as yesterday"
                     : "\(vsYesterday > 0 ? "+" : "")\(TimeFormat.minutes(abs(vsYesterday))) \(vsYesterday > 0 ? "more" : "less") sleep")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(vsYesterday >= 0 ? .orange : .indigo)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
    }

    // MARK: - Week Chart

    private var weekChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Week Overview")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("Total Sleep")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TimeFormat.minutes(weekTotal))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.indigo)
            }

            Chart(weekChartData) { item in
                let isSelected = calendar.isDate(item.date, inSameDayAs: selectedDate)

                BarMark(
                    x: .value("Day", item.label),
                    y: .value("Min", animateChart ? item.minutes : 0)
                )
                .cornerRadius(8)
                .foregroundStyle(
                    isSelected
                    ? AnyShapeStyle(Color.orange)
                    : AnyShapeStyle(Color.indigo.opacity(0.20))
                )
                .annotation(position: .bottom) {
                    VStack(spacing: 1) {
                        if item.minutes > 0 {
                            Text(TimeFormat.minutes(item.minutes))
                                .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .orange : .secondary)
                        } else {
                            Text("–")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                }
            }
            .chartYScale(domain: 0...chartMax)
            .chartYAxis {
                AxisMarks(values: [0, chartMax / 2, chartMax]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let m = value.as(Int.self) {
                            Text("\(m / 60)h")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 160)
            .onAppear {
                animateChart = false
                withAnimation(.easeOut(duration: 0.7)) { animateChart = true }
            }
            .onChange(of: selectedDate) { _ in
                animateChart = false
                withAnimation(.easeOut(duration: 0.5)) { animateChart = true }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Tip Card

    private var tipCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Naps between 11 AM – 1 PM tend to be longer and more refreshing for \(babyName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("🤍")
                .font(.system(size: 32))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
    }
}

private enum HistoryColor {
    static let background = Color(.systemGroupedBackground)
    static let card = Color(.systemBackground)
    static let ink = Color(red: 0.11, green: 0.09, blue: 0.20)
    static let muted = Color(red: 0.49, green: 0.47, blue: 0.58)
    static let purple = Color(red: 0.47, green: 0.38, blue: 0.94)
    static let purpleDeep = Color(red: 0.28, green: 0.22, blue: 0.67)
    static let green = Color(red: 0.20, green: 0.70, blue: 0.50)
    static let sun = Color(red: 1.0, green: 0.72, blue: 0.32)
    static let stroke = Color(red: 0.47, green: 0.38, blue: 0.94).opacity(0.14)
    static let track = Color(red: 0.96, green: 0.94, blue: 1.0).opacity(0.72)
}
