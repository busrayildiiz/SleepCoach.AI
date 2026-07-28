import SwiftUI

enum AddMode {
    case sleep
    case `break`
}

struct DayDetailView: View {
    let day: Date
    var records: [SleepRecord]

    let onDelete: (_ ids: Set<UUID>) -> Void
    let onAddSleep: (_ day: Date) -> Void
    let onEditNap: (_ nap: SleepRecord) -> Void
    let onBreakSaved: (_ newBreak: SleepRecord) -> Void

    @State private var showAddMenu = false
    @State private var showAddBreak = false
    @State private var breakTargetNap: SleepRecord? = nil
    @State private var contextNap: SleepRecord? = nil
    @State private var showNapActions = false
    @StateObject private var orchestrator = SleepCoachOrchestrator.shared


    @Environment(\.dismiss) private var dismiss

    private let cal = Calendar.current
    private let now = Date()

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

    private var wakeUpTime: Date? {
        guard let data = UserDefaults.standard.data(forKey: "dailyWakeRecords_v1"),
              let wakeRecords = try? JSONDecoder().decode([DailyWakeRecord].self, from: data),
              let todayWake = wakeRecords.first(where: { cal.isDate($0.day, inSameDayAs: day) })
        else { return nil }
        return todayWake.wakeTime
    }

    private var isToday: Bool { cal.isDateInToday(day) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
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
                }
            }
            .confirmationDialog("Add", isPresented: $showAddMenu, titleVisibility: .hidden) {
                Button("Add Nap") { onAddSleep(day) }
                Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog(
                contextNap.map { $0.kind == .nightSleep ? "Night Sleep" : "Nap" } ?? "",
                isPresented: $showNapActions,
                titleVisibility: .visible
            ) {
                Button("Edit") {
                    if let nap = contextNap { onEditNap(nap) }
                }
                Button("Add Wake Period") {
                    breakTargetNap = contextNap
                    showAddBreak = true
                }
                Button("Delete", role: .destructive) {
                    if let nap = contextNap { onDelete([nap.id]) }
                }
                Button("Cancel", role: .cancel) { contextNap = nil }
            }
            .sheet(isPresented: $showAddBreak) {
                if let nap = breakTargetNap {
                    AddBreakView(
                        defaultDate: nap.date,
                        targetNapID: nap.id,
                        napDuration: nap.duration,
                        existingBreaks: breaks.filter { $0.parentNapID == nap.id },
                        onSave: { newBreak in onBreakSaved(newBreak) }
                    )
                }
            }
        }
        .tint(Color(red: 0.45, green: 0.35, blue: 0.92))
    }

    // MARK: - All Cards (kronolojik)
    @ViewBuilder
    private var allCards: some View {
        // 1. Wake Up kartı — kayıt varsa göster, yoksa placeholder
        if let wake = wakeUpTime {
            WakeUpCard(time: wake)
        } else if isToday {
            WakeUpPlaceholderCard()
        }

        // Devam eden night sleep varsa (dünden kalan) önce göster
        if let night = nightSleep, night.isOngoing,
           !cal.isDate(night.date, inSameDayAs: day) {
            NightSleepCard(
                night: night,
                napBreaks: breaks.filter { $0.parentNapID == night.id },
                allBreaks: breaks,
                onAddBreakTap: { breakTargetNap = night; showAddBreak = true },
                onLongPress: { contextNap = night; showNapActions = true }
            )
            .onTapGesture { onEditNap(night) }
        }

        // 2. Gerçek naplar
        ForEach(Array(sortedNaps.enumerated()), id: \.element.id) { index, nap in
            let napBreaks = breaks.filter { $0.parentNapID == nap.id }
            NapDetailCard(
                napNumber: index + 1,
                nap: nap,
                napBreaks: napBreaks,
                allBreaks: breaks,
                onAddBreakTap: { breakTargetNap = nap; showAddBreak = true },
                onLongPress: { contextNap = nap; showNapActions = true }
            )
            .onTapGesture { onEditNap(nap) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { onDelete([nap.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }

        // 3. Tahmini naplar — anchor'u doğru hesapla
        if isToday {
            let ageMonths = orchestrator.snapshot?.ageMonths ?? 9
            let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)
            let minExpected = profile.expectedNapCount.lowerBound
            let remaining = max(0, minExpected - sortedNaps.count)

            if remaining > 0 {
                let predictedNaps = buildPredictedNaps(count: remaining)
                ForEach(Array(predictedNaps.enumerated()), id: \.offset) { index, item in
                    PredictedNapCard(
                        napNumber: sortedNaps.count + index + 1,
                        predictedTime: item.time,
                        expectedDuration: item.duration
                    )
                }
            }
        }

        // 4. Night sleep (bugün girilmiş, tamamlanmış veya live)
        if let night = nightSleep, cal.isDate(night.date, inSameDayAs: day) {
            NightSleepCard(
                night: night,
                napBreaks: breaks.filter { $0.parentNapID == night.id },
                allBreaks: breaks,
                onAddBreakTap: { breakTargetNap = night; showAddBreak = true },
                onLongPress: { contextNap = night; showNapActions = true }
            )
            .onTapGesture { onEditNap(night) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { onDelete([night.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else if isToday, nightSleep == nil {
            // Tahmini bedtime
            let bedtime = orchestrator.snapshot?.night.optimalBedtimeStart
                ?? cal.date(bySettingHour: 19, minute: 30, second: 0, of: day)
                ?? day
            PredictedBedtimeCard(bedtime: bedtime)
        }
    }
    private struct PredictedNapItem {
        let time: Date
        let duration: Int
    }

    private func buildPredictedNaps(count: Int) -> [PredictedNapItem] {
        let wakeWindow = orchestrator.snapshot?.daytime.wakeWindowUsed ?? 180
        let expectedDur = orchestrator.snapshot?.daytime.expectedDurationMinutes ?? 90

        var anchor: Date = {
            if let last = sortedNaps.last {
                return last.date.addingTimeInterval(TimeInterval(last.effectiveDuration * 60))
            }
            return wakeUpTime ?? cal.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? day
        }()

        var result: [PredictedNapItem] = []
        for slot in 0..<count {
            let time: Date = slot == 0
                ? (orchestrator.snapshot?.daytime.nextNapTime ?? anchor.addingMinutes(wakeWindow))
                : anchor.addingMinutes(wakeWindow)
            result.append(PredictedNapItem(time: time, duration: expectedDur))
            anchor = time.addingMinutes(expectedDur)  // ← her slot için anchor ilerliyor
        }
        return result
    }

    private var dayTitle: String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.day().month(.abbreviated))
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
        Text("Estimated")
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
    let allBreaks: [SleepRecord]
    let onAddBreakTap: () -> Void
    let onLongPress: () -> Void

    @State private var breaksExpanded = false

    private let deepPurple = Color(red: 0.28, green: 0.18, blue: 0.68)
    private let midPurple  = Color(red: 0.38, green: 0.28, blue: 0.78)

    private var netMinutes: Int { night.totalMinutes(breaks: allBreaks) }
    private var napEnd: Date {
        night.date.addingTimeInterval(TimeInterval(night.effectiveDuration * 60))
    }

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
                    if night.isOngoing {
                        Text("In progress · started \(ampm(night.date))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                    } else {
                        Text("\(ampm(night.date)) – \(ampm(napEnd))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if night.isOngoing {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(TimeFormat.minutes(night.effectiveDuration))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1.0))
                        }
                        Text("Live")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(midPurple))
                    } else {
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
                            Text("\(br.duration) min")
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
                    Text("Add Wake Period").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color(red: 0.75, green: 0.70, blue: 0.95))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
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
                Text("~\(ampm(bedtime)) estimated")
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
        Text("Estimated")
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
    let allBreaks: [SleepRecord]
    let onAddBreakTap: () -> Void
    let onLongPress: () -> Void

    @State private var breaksExpanded = true

    private let purple     = Color(red: 0.55, green: 0.45, blue: 0.96)
    private let deepPurple = Color(red: 0.35, green: 0.25, blue: 0.80)

    private var isNight: Bool { nap.kind == .nightSleep }
    private var napTint: Color { nap.isOngoing ? purple : (isNight ? deepPurple : purple) }
    private var netMinutes: Int { nap.totalMinutes(breaks: allBreaks) }
    private var napEnd: Date {
        nap.date.addingTimeInterval(TimeInterval(nap.effectiveDuration * 60))
    }
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
                    Text("\(TimeFormat.ampm(nap.date)) – \(TimeFormat.ampm(napEnd))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if nap.isOngoing {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(TimeFormat.minutes(nap.effectiveDuration))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(napTint)
                        }
                        Text("In progress")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(napTint)
                    } else {
                        Text(TimeFormat.minutes(nap.duration))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Text("Total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
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
                    if nap.isOngoing {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(TimeFormat.minutes(netMinutes))
                                .font(.subheadline.weight(.bold)).foregroundStyle(napTint)
                        }
                    } else {
                        Text(TimeFormat.minutes(netMinutes))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    }
                    Text("Net Sleep").font(.caption2).foregroundStyle(.secondary)
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
                            Text("\(br.duration) min").font(.subheadline).foregroundStyle(.secondary)
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
                    Text("Add Wake Period").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(napTint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
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
