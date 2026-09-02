import SwiftUI

struct InsightsView: View {

    private enum CoachTab: String, CaseIterable {
        case overview = "Coach"
        case predictions = "Reasoning"

        var icon: String {
            switch self {
            case .overview: return "sparkles"
            case .predictions: return "bubble.left.and.exclamationmark.bubble.right.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .overview: return "What to do next"
            case .predictions: return "Why this plan"
            }
        }
    }

    @State private var selectedTab: CoachTab = .overview
    @State private var manualActionOverrides: [String: Bool] = [:]
    @EnvironmentObject private var orchestrator: SleepCoachOrchestrator
    
    @AppStorage("babyName") private var babyName: String = "Baby"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    headerSection
                    tabPicker

                    if selectedTab == .overview {
                        coachHeroCard
                        takeActionCard
                        watchForSignsCard
                        aiCoachNoteCard
                        learningProgressOverviewCard
                    } else {
                        predictionLogicStack
                    }
                }
                
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 112)
            }
            .background(CoachColor.background)
            .navigationBarHidden(true)
            .onAppear {
                orchestrator.loadCachedLLMResponse()
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .dailyWakeRecordsDidChange)) { _ in refresh() }
            .environment(\.locale, Locale(identifier: "en_US"))
        }
    }

    // MARK: - Header
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 1) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(CoachColor.purpleDeep)

                Text("AI Coach")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)

                Spacer()

                CoachMoonArtwork()
                    .frame(width: 52, height: 40)
            }

            Text(headerSubtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CoachColor.muted)
        }
    }

    private var headerSubtitle: String {
        orchestrator.snapshot?.nextSleepKind == .bedtime
            ? "Personalized guidance for tonight"
            : "Personalized guidance for today"
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(CoachTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10.5, weight: .bold))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(selectedTab == tab ? CoachColor.purpleDeep : CoachColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(selectedTab == tab ? CoachColor.purple.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        Capsule()
                            .stroke(selectedTab == tab ? CoachColor.purple.opacity(0.18) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color(.systemBackground))
        )
        .overlay(
            Capsule()
                .stroke(CoachColor.purple.opacity(0.12), lineWidth: 1)
        )
    }
    // MARK: - Overview

    private var coachHeroCard: some View {
        let isBedtime = orchestrator.snapshot?.nextSleepKind == .bedtime
        let targetTime = isBedtime
            ? (orchestrator.snapshot?.night.optimalBedtimeStart ?? Date())
            : (orchestrator.snapshot?.daytime.nextNapTime ?? Date())
        let confidence = max(0, min(orchestrator.snapshot?.daytime.confidence ?? 0, 100))
        let windowText = isBedtime ? bedtimeWindowText : napWindowText

        return VStack(alignment: .leading, spacing: 0) {
            Text(isBedtime ? "TONIGHT'S PLAN" : "TODAY'S PLAN")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CoachColor.purpleDeep)
                .tracking(0.4)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(CoachColor.purpleDeep.opacity(0.85))
                        .frame(width: 46, height: 46)
                    Image(systemName: isBedtime ? "moon.fill" : "moon.zzz.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isBedtime ? "Bedtime" : "Next nap")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CoachColor.muted)
                    Text(time(targetTime))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(CoachColor.ink)
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                VStack(spacing: 3) {
                    Text("Confidence")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CoachColor.muted)
                    ZStack {
                        Circle()
                            .stroke(CoachColor.purple.opacity(0.15), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: CGFloat(confidence) / 100)
                            .stroke(CoachColor.purpleDeep, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(confidence)%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(CoachColor.ink)
                    }
                    .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider().overlay(CoachColor.stroke)

            HStack(spacing: 5) {
                Text("Optimal window")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
                Text(windowText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CoachColor.ink)

                Spacer()

                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CoachColor.purpleDeep.opacity(0.7))
                Text(lastUpdatedText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CoachColor.muted)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CoachColor.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(premiumCardBackground(cornerRadius: 20))
        .overlay(cardStroke(20))
    }
    
    
    private var lastUpdatedText: String {
        guard let generatedAt = orchestrator.snapshot?.generatedAt else { return "Updated just now" }
        let minutes = max(0, Int(Date().timeIntervalSince(generatedAt) / 60))
        if minutes < 1 { return "Updated just now" }
        if minutes == 1 { return "Updated 1 min ago" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        return "Updated \(minutes / 60)h ago"
    }
    
    private var takeActionCard: some View {
        let accent = Color(red: 0.85, green: 0.45, blue: 0.10)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(actionCardTitle)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.3)
                }
                .foregroundStyle(accent)

                Spacer()

                Text(minutesToGoText)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.16))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(actionItems.enumerated()), id: \.element.id) { index, item in
                    actionRow(item)
                    if index < actionItems.count - 1 {
                        Divider()
                            .overlay(Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.14))
                            .padding(.leading, 44)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color(red: 1.0, green: 0.965, blue: 0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.78, blue: 0.45).opacity(0.30), lineWidth: 1)
        )
    }

    private var watchForSignsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("WATCH FOR THESE SIGNS")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .tracking(0.3)
                }
                .foregroundStyle(CoachColor.purpleDeep)

                Text("Take your baby to bed when you see 2 or more signs.")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
            }

            VStack(spacing: 8) {
                signBand(
                    statusIcon: "checkmark",
                    statusIconContainer: "circle.fill",
                    title: "Ready for\nsleep",
                    titleColor: CoachColor.green,
                    backgroundColor: CoachColor.green.opacity(0.075),
                    accentColor: CoachColor.green,
                    items: [
                        SignItem(icon: "face.smiling", label: "Rubbing\neyes"),
                        SignItem(icon: "face.dashed", label: "Yawning"),
                        SignItem(icon: "figure.play", label: "Quiet play"),
                        SignItem(icon: "tortoise.fill", label: "Slower\nmovements")
                    ]
                )

                signBand(
                    statusIcon: "exclamationmark",
                    statusIconContainer: "triangle",
                    title: "Getting\novertired",
                    titleColor: CoachColor.red,
                    backgroundColor: CoachColor.red.opacity(0.075),
                    accentColor: CoachColor.red,
                    items: [
                        SignItem(icon: "figure.walk.motion", label: "Arching\nback"),
                        SignItem(icon: "face.dashed.fill", label: "Fussiness\nincreasing"),
                        SignItem(icon: "sparkles", label: "Hyperactive\nbursts"),
                        SignItem(icon: "heart.slash.fill", label: "Harder to\nsettle")
                    ]
                )
            }
        }
        .padding(14)
        .background(premiumCardBackground(cornerRadius: 18))
        .overlay(cardStroke(18))
    }

    private func signBand(
        statusIcon: String,
        statusIconContainer: String,
        title: String,
        titleColor: Color,
        backgroundColor: Color,
        accentColor: Color,
        items: [SignItem]
    ) -> some View {
        HStack(spacing: 7) {
            statusMark(icon: statusIcon, container: statusIconContainer, color: accentColor)

            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(titleColor)
                .lineLimit(2)
                .frame(width: 56, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(accentColor.opacity(0.32))

            HStack(spacing: 6) {
                ForEach(items) { item in
                    signItemView(item, color: accentColor)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private func statusMark(icon: String, container: String, color: Color) -> some View {
        ZStack {
            if container == "circle.fill" {
                Circle()
                    .fill(color.opacity(0.72))
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: container)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(color.opacity(0.88))
            }

            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(container == "circle.fill" ? .white : color)
        }
        .frame(width: 30, height: 30)
    }

    private func signItemView(_ item: SignItem, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.10))
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(color.opacity(0.23), lineWidth: 1)
                    .frame(width: 32, height: 32)
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color.opacity(0.78))
            }

            Text(item.label)
                .font(.system(size: 8.7, weight: .semibold))
                .foregroundStyle(CoachColor.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    private var aiCoachNoteCard: some View {
        HStack(alignment: .center, spacing: 13) {
            CoachBotArtwork()
                .frame(width: 82, height: 88)

            VStack(alignment: .leading, spacing: 8) {
                Text("AI COACH NOTE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(CoachColor.purpleDeep)

                Text(coachTipText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(CoachColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                orchestrator.refreshLLM()
            } label: {
                Image(systemName: orchestrator.isLLMLoading ? "sparkles" : "heart")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(CoachColor.purpleDeep)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(CoachColor.purple.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(premiumCardBackground(cornerRadius: 18))
        .overlay(cardStroke(18))
    }

    private var learningProgressOverviewCard: some View {
        let tracked = min(trackedDays, 14)
        let remaining = max(0, 14 - tracked)

        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("LEARNING PROGRESS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(CoachColor.green)

                HStack(spacing: 15) {
                    learningProgressRing(tracked: tracked)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(learningProgressTitle)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(CoachColor.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(learningProgressDetail(remaining: remaining))
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineSpacing(2)
                            .foregroundStyle(CoachColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            learningBars(tracked: tracked)
                .frame(width: 78, height: 62)
        }
        .padding(16)
        .background(premiumCardBackground(cornerRadius: 18))
        .overlay(cardStroke(18))
    }

    private func learningProgressRing(tracked: Int) -> some View {
        ZStack {
            Circle()
                .trim(from: 0.10, to: 0.90)
                .stroke(CoachColor.green.opacity(0.26), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.10, to: 0.10 + (0.80 * CGFloat(tracked) / 14))
                .stroke(CoachColor.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(90))
            VStack(spacing: 0) {
                Text("\(tracked)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)
                Text("/14")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.muted)
            }
        }
        .frame(width: 60, height: 60)
    }

    private func learningBars(tracked: Int) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            ForEach(0..<4, id: \.self) { index in
                let threshold = (index + 1) * 3
                let fillOpacity = tracked >= threshold ? 0.82 : 0.22
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CoachColor.green.opacity(fillOpacity))
                    .frame(width: 14, height: CGFloat(18 + index * 10))
            }
        }
    }

    private func actionRow(_ item: PreSleepActionItem) -> some View {
        let status = actionStatus(item)
        let done = status == .completed
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                toggleAction(item)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(item.iconBackground)
                        .frame(width: 30, height: 30)
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.iconColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(CoachColor.ink)
                    Text(item.subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(CoachColor.muted)
                }

                Spacer()
                
                ZStack {
                    Circle()
                        .fill(done ? CoachColor.purpleDeep : Color.clear)
                        .frame(width: 19, height: 19)
                    Circle()
                        .stroke(done ? Color.clear : CoachColor.muted.opacity(0.32), lineWidth: 1.3)
                        .frame(width: 19, height: 19)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.vertical, 6.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private func actionStatus(
        _ item: PreSleepActionItem,
        now: Date = .now
    ) -> ActionStatus {

        if manualActionOverrides[item.id] == true {
            return .completed
        }

        let target = actionTargetTime.addingMinutes(-item.offsetMinutesBeforeTarget)

        if now >= target {
            return .readyNow
        }

        return .upcoming
    }
    
    private var minutesToGoText: String {
        let minutes = Int(actionTargetTime.timeIntervalSince(Date()) / 60)
        guard minutes > 0 else { return "Time's up" }
        return "~\(minutes) min to go"
    }
    

    private func toggleAction(_ item: PreSleepActionItem) {

        let currentlyDone = actionStatus(item) == .completed

        manualActionOverrides[item.id] = !currentlyDone
    }
    
    // MARK: - Action Item Model

    private struct PreSleepActionItem: Identifiable {
        let id : String
        let icon: String
        let iconColor: Color
        let iconBackground: Color
        let title: String
        let subtitle: String
        let offsetMinutesBeforeTarget: Int
    }

    // MARK: - Personalization Model

    private struct PersonalizationFactorResult: Identifiable {
        let id: String
        let title: String
        let valueText: String
        let deltaMinutes: Int
    }

    private struct PersonalizationBreakdown {
        let baselineDate: Date
        let finalDate: Date
        let factors: [PersonalizationFactorResult]
        let narrative: String
    }

    private struct AgentContribution: Identifiable {
        let id: String
        let name: String
        let icon: String
        let score: Int
    }

    private struct ConfidenceSignal: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isPositive: Bool
    }

    private struct ComparisonMetric: Identifiable {
        let id: String
        let title: String
        let value: String
        let detail: String
        let icon: String
        let color: Color
    }

    private struct DecisionStep: Identifiable {
        let id: String
        let time: String
        let title: String
        let icon: String
        let color: Color
    }
    private struct SignItem: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
    }

    private var actionTargetTime: Date {
        let isBedtime = orchestrator.snapshot?.nextSleepKind == .bedtime
        return isBedtime
            ? (orchestrator.snapshot?.night.optimalBedtimeStart ?? Date())
            : (orchestrator.snapshot?.daytime.nextNapTime ?? Date())
    }

    private var isBedtimeAction: Bool {
        orchestrator.snapshot?.nextSleepKind == .bedtime
    }

    private var actionCardTitle: String {
        isBedtimeAction ? "TAKE ACTION NOW" : "NAP PREP"
    }

    private var actionItems: [PreSleepActionItem] {
        isBedtimeAction ? bedtimeActionItems : napActionItems
    }

    private var bedtimeActionItems: [PreSleepActionItem] {
        [
            PreSleepActionItem(
                id: "dim_lights",
                icon: "lamp.desk.fill", iconColor: .orange, iconBackground: Color.orange.opacity(0.15),
                title: "Start dimming lights",
                subtitle: "Begin by \(time(actionTargetTime.addingMinutes(-45)))",
                offsetMinutesBeforeTarget: 45
            ),
            PreSleepActionItem(
                id: "quiet_play",
                icon: "gamecontroller.fill", iconColor: CoachColor.green, iconBackground: CoachColor.green.opacity(0.15),
                title: "Quiet play only",
                subtitle: "Avoid stimulating activities",
                offsetMinutesBeforeTarget: 30
            ),
            PreSleepActionItem(
                id: "feed",
                icon: "cup.and.saucer.fill", iconColor: CoachColor.purpleDeep, iconBackground: CoachColor.purple.opacity(0.15),
                title: "Feed before bedtime",
                subtitle: "Finish feeding by \(time(actionTargetTime.addingMinutes(-15)))",
                offsetMinutesBeforeTarget: 15
            ),
            PreSleepActionItem(
                id: "prepare_env",
                icon: "moon.zzz.fill", iconColor: CoachColor.purpleDeep, iconBackground: CoachColor.purple.opacity(0.10),
                title: "Prepare sleep environment",
                subtitle: "Dark, cool, and calm",
                offsetMinutesBeforeTarget: 10
            ),
            PreSleepActionItem(
                id: "routine",
                icon: "book.fill", iconColor: .orange, iconBackground: Color.orange.opacity(0.15),
                title: "Begin bedtime routine",
                subtitle: "Bath, book, and cuddles",
                offsetMinutesBeforeTarget: 0
            )
        ]
    }

    private var napActionItems: [PreSleepActionItem] {
        [
            PreSleepActionItem(
                id: "sleepy_cues",
                icon: "eye.fill", iconColor: CoachColor.purpleDeep, iconBackground: CoachColor.purple.opacity(0.12),
                title: "Watch for sleepy cues",
                subtitle: "Yawning, eye rubbing, fussiness",
                offsetMinutesBeforeTarget: 20
            ),
            PreSleepActionItem(
                id: "quiet_play",
                icon: "gamecontroller.fill", iconColor: CoachColor.green, iconBackground: CoachColor.green.opacity(0.15),
                title: "Quiet play only",
                subtitle: "Avoid stimulating activities",
                offsetMinutesBeforeTarget: 15
            ),
            PreSleepActionItem(
                id: "dim_room",
                icon: "lamp.desk.fill", iconColor: .orange, iconBackground: Color.orange.opacity(0.15),
                title: "Dim the room",
                subtitle: "Begin by \(time(actionTargetTime.addingMinutes(-10)))",
                offsetMinutesBeforeTarget: 10
            ),
            PreSleepActionItem(
                id: "prepare_space",
                icon: "moon.zzz.fill", iconColor: CoachColor.purpleDeep, iconBackground: CoachColor.purple.opacity(0.10),
                title: "Prepare sleep space",
                subtitle: "Dark, cool, and calm",
                offsetMinutesBeforeTarget: 5
            ),
            PreSleepActionItem(
                id: "nap_routine",
                icon: "book.fill", iconColor: .orange, iconBackground: Color.orange.opacity(0.15),
                title: "Begin nap routine",
                subtitle: "Swaddle, sound, cuddles",
                offsetMinutesBeforeTarget: 0
            )
        ]
    }
    
    private func loadTodayRecordsForBreakdown() -> [SleepRecord] {
        guard let data = UserDefaults.standard.data(forKey: "sleepRecords"),
              let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data)
        else { return [] }
        return decoded.filter { Calendar.current.isDateInToday($0.date) }
    }

    private func loadWakeRecordsForBreakdown() -> [DailyWakeRecord] {
        guard let data = UserDefaults.standard.data(forKey: "dailyWakeRecords_v1"),
              let decoded = try? JSONDecoder().decode([DailyWakeRecord].self, from: data)
        else { return [] }
        return decoded
    }

    private func expectedLastNapEndTime(profile: AgeBasedSleepProfile, napCount: Int, anchor: Date) -> Date {
        guard napCount > 0 else { return anchor }
        let wwCenter = (profile.wakeWindowRange.lowerBound + profile.wakeWindowRange.upperBound) / 2
        let napDurationCenter = Int(Double(profile.maxSingleNapMinutes) * 0.75)
        var cursor = anchor
        for _ in 0..<napCount {
            cursor = cursor.addingMinutes(wwCenter).addingMinutes(napDurationCenter)
        }
        return cursor
    }

    private func buildPersonalizationNarrative(
        factors: [PersonalizationFactorResult],
        babyName: String
    ) -> String {
        let totalDelta = factors.reduce(0) { $0 + $1.deltaMinutes }
        let direction = totalDelta < 0 ? "earlier" : "later"

        var clauses: [String] = []

        if let wakeFactor = factors.first(where: { $0.id == "wake_up" }) {
            clauses.append(wakeFactor.deltaMinutes >= 0
                ? "\(babyName) woke up later than usual"
                : "\(babyName) woke up earlier than usual")
        }
        if let napFactor = factors.first(where: { $0.id == "last_nap" }) {
            clauses.append(napFactor.deltaMinutes >= 0
                ? "the last nap still ended later than expected for that wake-up"
                : "the last nap ended earlier than expected for that wake-up")
        }
        if let deficitFactor = factors.first(where: { $0.id == "daytime_deficit" }), deficitFactor.deltaMinutes < 0 {
            clauses.append("today's total daytime sleep was a bit short, raising overtired risk")
        }

        let intro = clauses.isEmpty
            ? "Today's sleep signals were close to the baseline"
            : "Today, " + clauses.joined(separator: ", and ")

        guard totalDelta != 0 else {
            return "\(intro), so bedtime stays right on the age-based baseline tonight."
        }
        return "\(intro), so bedtime is adjusted \(abs(totalDelta)) min \(direction) tonight to protect healthy sleep pressure."
    }
    
    private enum PersonalizationCardState {
        case notApplicable
        case insufficientData(missingNaps: Int)
        case ready(PersonalizationBreakdown)
    }

    private func personalizationCardState() -> PersonalizationCardState {
        guard let snapshot = orchestrator.snapshot,
              snapshot.nextSleepKind == .bedtime,
              snapshot.ageMonths >= 4
        else { return .notApplicable }

        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: snapshot.ageMonths)
        let records = loadTodayRecordsForBreakdown()
        let dayNaps = records.filter { $0.kind == .dayNap && !$0.isOngoing }

        guard dayNaps.count >= profile.expectedNapCount.lowerBound else {
            let missing = profile.expectedNapCount.lowerBound - dayNaps.count
            return .insufficientData(missingNaps: missing)
        }

        guard let breakdown = personalizationBreakdown() else {
            return .insufficientData(missingNaps: 0)
        }

        return .ready(breakdown)
    }
    private func personalizationEmptyContent(missingNaps: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(CoachColor.purpleDeep.opacity(0.12))
                        .frame(width: 19, height: 19)
                    Text("2")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CoachColor.purpleDeep)
                }
                sectionHeader("PERSONALIZATION (HOW WE ADJUSTED)", icon: nil)
            }

            HStack(alignment: .top, spacing: 0) {
                personalizationColumn(title: "AAP baseline", subtitle: "(bedtime range)", value: "–", delta: nil, isEndpoint: true)
                personalizationColumn(title: "Today's wake-up", subtitle: nil, value: "–", delta: nil, isEndpoint: false)
                personalizationColumn(title: "Last nap ended at", subtitle: nil, value: "–", delta: nil, isEndpoint: false)
                personalizationColumn(title: "Today's daytime sleep", subtitle: nil, value: "–", delta: nil, isEndpoint: false)
                personalizationColumn(title: "Final recommendation", subtitle: nil, value: "–", delta: nil, isEndpoint: true)
            }
            .opacity(0.45)

            personalizationDotTrack(stepCount: 5)
                .opacity(0.35)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.10))
                    .padding(.top, 1)

                Text(missingDataMessage(missingNaps: missingNaps))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachColor.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.12))
            )
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }
    private func missingDataMessage(missingNaps: Int) -> String {
        if missingNaps > 0 {
            return "Not enough naps logged today to personalize tonight's bedtime — \(missingNaps) more nap\(missingNaps == 1 ? "" : "s") needed. Showing this once today's sleep is fully logged."
        }
        return "Today's sleep data isn't complete enough yet to explain tonight's adjustment. Log the day's naps and wake time for a personalized breakdown."
    }

    private func personalizationBreakdown() -> PersonalizationBreakdown? {
        guard let snapshot = orchestrator.snapshot,
              snapshot.nextSleepKind == .bedtime,
              snapshot.ageMonths >= 4
        else { return nil }

        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: snapshot.ageMonths)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let records = loadTodayRecordsForBreakdown()
        let breaks = records.filter { $0.kind == .break }
        let dayNaps = records.filter { $0.kind == .dayNap && !$0.isOngoing }.sorted { $0.date < $1.date }

        guard dayNaps.count >= profile.expectedNapCount.lowerBound,
              let actualLastNap = dayNaps.last
        else { return nil }

        let actualLastNapEnd = actualLastNap.date.addingMinutes(actualLastNap.duration)

        let typicalWakeHour = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
        let typicalWakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
        let typicalWake = calendar.date(
            bySettingHour: Int(typicalWakeHour), minute: Int(typicalWakeMinute), second: 0, of: today
        ) ?? today

        // Bugünün GERÇEK loglanan uyanma saati (varsa)
        let wakeRecords = loadWakeRecordsForBreakdown()
        let todayWakeRecord = wakeRecords.first(where: { calendar.isDate($0.day, inSameDayAs: now) })?.wakeTime

        // Baseline: bebek typical saatte uyansaydı beklenen son nap bitişi (yaşa dayalı, bugünden bağımsız)
        let baselineLastNapEnd = expectedLastNapEndTime(
            profile: profile, napCount: profile.expectedNapCount.lowerBound, anchor: typicalWake
        )
        let ewwMin = profile.eveningWakeWindow.lowerBound
        let baselineDate = baselineLastNapEnd.addingMinutes(ewwMin)
        let finalDate = snapshot.night.optimalBedtimeStart

        // Faktör 1: Bugünün gerçek uyanma saati, typical'a göre ne kadar kaydı — günün geri kalanını öteler
        let wakeAnchor = todayWakeRecord ?? typicalWake
        let wakeOffsetDelta = Int(wakeAnchor.timeIntervalSince(typicalWake) / 60)

        // Faktör 2: Wake-up ötelemesi hesaba katıldıktan SONRA, son nap ne kadar erken/geç bitti (residual — çifte sayım yok)
        let expectedLastNapEndAdjusted = baselineLastNapEnd.addingMinutes(wakeOffsetDelta)
        let napTimingDelta = Int(actualLastNapEnd.timeIntervalSince(expectedLastNapEndAdjusted) / 60)

        // Faktör 3: Gündüz uyku açığı telafisi — OvertiredCalculator.bedtimeWindow ile birebir aynı formül
        let totalDaytime = dayNaps.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
        let daytimeDeficit = max(0, profile.daytimeSleepRange.lowerBound - totalDaytime)
        let adjustment = daytimeDeficit / 3
        let deficitDelta = -adjustment

        var factors: [PersonalizationFactorResult] = []

        if todayWakeRecord != nil, abs(wakeOffsetDelta) >= 3 {
            factors.append(PersonalizationFactorResult(
                id: "wake_up",
                title: "Today's wake-up",
                valueText: time(wakeAnchor),
                deltaMinutes: wakeOffsetDelta
            ))
        }

        if abs(napTimingDelta) >= 3 {
            factors.append(PersonalizationFactorResult(
                id: "last_nap",
                title: "Last nap ended at",
                valueText: time(actualLastNapEnd),
                deltaMinutes: napTimingDelta
            ))
        }

        if deficitDelta != 0 {
            factors.append(PersonalizationFactorResult(
                id: "daytime_deficit",
                title: "Today's daytime sleep",
                valueText: TimeFormat.minutes(totalDaytime),
                deltaMinutes: deficitDelta
            ))
        }

        guard !factors.isEmpty else { return nil }

        let narrative = buildPersonalizationNarrative(factors: factors, babyName: displayedBabyName)

        return PersonalizationBreakdown(
            baselineDate: baselineDate,
            finalDate: finalDate,
            factors: factors,
            narrative: narrative
        )
    }

    private var personalizationCard: some View {
        Group {
            switch personalizationCardState() {
            case .notApplicable:
                EmptyView()
            case .insufficientData(let missingNaps):
                personalizationEmptyContent(missingNaps: missingNaps)
            case .ready(let breakdown):
                personalizationContent(breakdown)
            }
        }
    }

    private func personalizationContent(_ breakdown: PersonalizationBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(CoachColor.purpleDeep.opacity(0.12))
                        .frame(width: 19, height: 19)
                    Text("2")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CoachColor.purpleDeep)
                }
                sectionHeader("PERSONALIZATION (HOW WE ADJUSTED)", icon: nil)
            }

            HStack(alignment: .top, spacing: 0) {
                personalizationColumn(
                    title: "AAP baseline", subtitle: "(bedtime range)",
                    value: time(breakdown.baselineDate), delta: nil, isEndpoint: true
                )
                ForEach(breakdown.factors) { factor in
                    personalizationColumn(
                        title: factor.title, subtitle: nil,
                        value: factor.valueText, delta: factor.deltaMinutes, isEndpoint: false
                    )
                }
                personalizationColumn(
                    title: "Final recommendation", subtitle: nil,
                    value: time(breakdown.finalDate), delta: nil, isEndpoint: true
                )
            }

            personalizationDotTrack(stepCount: breakdown.factors.count + 2)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CoachColor.purpleDeep.opacity(0.85))
                    .padding(.top, 1)
                Text(breakdown.narrative)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachColor.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(CoachColor.purple.opacity(0.07))
            )
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private func personalizationColumn(
        title: String, subtitle: String?, value: String, delta: Int?, isEndpoint: Bool
    ) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(CoachColor.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(CoachColor.muted.opacity(0.75))
            }

            Text(value)
                .font(.system(size: isEndpoint ? 13 : 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(isEndpoint ? CoachColor.purpleDeep : CoachColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let delta {
                Text("\(delta >= 0 ? "+" : "–")\(abs(delta)) min")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CoachColor.sun)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func personalizationDotTrack(stepCount: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<stepCount, id: \.self) { index in
                Circle()
                    .stroke(CoachColor.purpleDeep, lineWidth: 1.5)
                    .background(Circle().fill(Color(.systemBackground)))
                    .frame(width: 8, height: 8)
                if index < stepCount - 1 {
                    Rectangle()
                        .fill(CoachColor.purpleDeep.opacity(0.35))
                        .frame(height: 1.5)
                }
            }
        }
    }

    // MARK: - Logic

    private var predictionLogicStack: some View {
        VStack(spacing: 12) {
            medicalEvidenceCard
            personalizationCard
            agentContributionCard
            confidenceExplainerGrid
            todayComparisonCard
            decisionTimelineCard
        }
    }

    private var medicalEvidenceCard: some View {
        let ageMonths = orchestrator.snapshot?.ageMonths ?? 6
        let profile = DefaultAgeBasedSleepProfileProvider().profile(forAgeMonths: ageMonths)

        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(CoachColor.purpleDeep.opacity(0.12))
                        .frame(width: 19, height: 19)
                    Text("1")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CoachColor.purpleDeep)
                }
                sectionHeader("MEDICAL EVIDENCE", icon: nil)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("For \(ageMonths)-month-old babies")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CoachColor.ink)

                VStack(alignment: .leading, spacing: 7) {
                    evidenceRow(napCountText(profile.expectedNapCount))
                    evidenceRow("Wake window: \(hoursMinutesRangeText(profile.wakeWindowRange))")
                    evidenceRow("Total sleep: \(hoursMinutesRangeText(profile.totalSleep24hRange))")
                    evidenceRow("Recommended bedtime: \(bedtimeRangeText(profile.bedtimeHourRange))")
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CoachColor.purpleDeep.opacity(0.85))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("These guidelines provide the clinical baseline for safe and healthy sleep.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CoachColor.ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Source: American Academy of Pediatrics · healthychildren.org")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(CoachColor.purpleDeep.opacity(0.75))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(CoachColor.purple.opacity(0.07))
            )
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var agentContributionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            numberedSectionHeader(number: 3, title: "AGENT CONTRIBUTIONS")

            VStack(spacing: 9) {
                ForEach(agentContributions) { item in
                    agentContributionRow(item)
                }
            }
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private func agentContributionRow(_ item: AgentContribution) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(CoachColor.purple.opacity(0.11))
                    .frame(width: 23, height: 23)
                Image(systemName: item.icon)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(CoachColor.purpleDeep)
            }

            Text(item.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoachColor.ink)
                .frame(width: 132, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(CoachColor.purple.opacity(0.10))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [CoachColor.purple.opacity(0.75), CoachColor.purpleDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * CGFloat(item.score) / 100))
                }
            }
            .frame(height: 5)

            Text("\(item.score)%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(CoachColor.ink)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var confidenceExplainerGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            confidenceDetailsCard
            whyNotHundredCard
        }
    }

    private var confidenceDetailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            numberedSectionHeader(number: 4, title: "CONFIDENCE DETAILS")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(overallConfidence)%")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.purpleDeep)
                    .monospacedDigit()
                Text(confidenceLevelText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(confidenceLevelColor)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(confidenceSignals.prefix(5)) { signal in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: signal.isPositive ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(signal.isPositive ? CoachColor.green : CoachColor.sun)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(signal.title)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(CoachColor.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Text(signal.detail)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(CoachColor.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                    }
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 194, alignment: .topLeading)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var whyNotHundredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            numberedSectionHeader(number: 5, title: "WHY NOT 100%?")

            Text(confidenceLimitTitle)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(CoachColor.ink)

            Text(confidenceLimitDetail)
                .font(.system(size: 11, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [CoachColor.purple.opacity(0.20), CoachColor.purpleDeep.opacity(0.72)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 13, height: CGFloat(8 + index * 8))
                        .opacity(index < min(trackedDays / 2, 6) ? 0.95 : 0.24)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(CoachColor.purple.opacity(0.45))
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 194, alignment: .topLeading)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var todayComparisonCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            numberedSectionHeader(number: 6, title: "TODAY VS YESTERDAY")

            HStack(spacing: 0) {
                ForEach(Array(comparisonMetrics.enumerated()), id: \.element.id) { index, metric in
                    comparisonMetricView(metric)
                    if index < comparisonMetrics.count - 1 {
                        Rectangle()
                            .fill(CoachColor.stroke)
                            .frame(width: 1, height: 44)
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private func comparisonMetricView(_ metric: ComparisonMetric) -> some View {
        VStack(spacing: 5) {
            Image(systemName: metric.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(metric.color)
            Text(metric.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(CoachColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(metric.value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(metric.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(metric.detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(CoachColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private var decisionTimelineCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            numberedSectionHeader(number: 7, title: "DECISION FLOW")

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(decisionSteps.enumerated()), id: \.element.id) { index, step in
                    decisionStepView(step)
                    if index < decisionSteps.count - 1 {
                        VStack {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(CoachColor.purple.opacity(0.52))
                                .padding(.top, 15)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 20)
                    }
                }
            }
        }
        .padding(15)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private func decisionStepView(_ step: DecisionStep) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(step.color.opacity(0.11))
                    .frame(width: 34, height: 34)
                Image(systemName: step.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(step.color)
            }
            Text(step.time)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(CoachColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(step.title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(CoachColor.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(height: 24, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
    private func evidenceRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(CoachColor.purpleDeep.opacity(0.10))
                    .frame(width: 16, height: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(CoachColor.purpleDeep)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CoachColor.ink.opacity(0.82))
        }
    }
    private func napCountText(_ range: ClosedRange<Int>) -> String {
        if range.lowerBound == range.upperBound {
            let n = range.lowerBound
            return "\(n) nap\(n == 1 ? "" : "s") per day"
        }
        return "\(range.lowerBound) – \(range.upperBound) naps per day"
    }
    
    private func hoursMinutesRangeText(_ range: ClosedRange<Int>) -> String {
        "\(hoursMinutesText(range.lowerBound)) – \(hoursMinutesText(range.upperBound))"
    }

    private func hoursMinutesText(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }

    private func hoursRangeText(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound / 60) – \(range.upperBound / 60) hours"
    }

    private func bedtimeRangeText(_ range: ClosedRange<Int>) -> String {
        func hour12(_ hour24: Int) -> (Int, String) {
            let suffix = hour24 >= 12 ? "PM" : "AM"
            let h = hour24 > 12 ? hour24 - 12 : (hour24 == 0 ? 12 : hour24)
            return (h, suffix)
        }
        let (lowHour, lowSuffix) = hour12(range.lowerBound)
        let (highHour, highSuffix) = hour12(range.upperBound)
        return lowSuffix == highSuffix
            ? "\(lowHour) – \(highHour) \(lowSuffix)"
            : "\(lowHour) \(lowSuffix) – \(highHour) \(highSuffix)"
    }
    
    // MARK: - Components

    private enum ActionStatus {
        case upcoming
        case readyNow
        case completed
    }
    
    private var confidenceRing: some View {
        let confidence = max(0, min(orchestrator.snapshot?.daytime.confidence ?? 0, 100))
        return ZStack {
            Circle()
                .stroke(CoachColor.purple.opacity(0.14), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(confidence) / 100)
                .stroke(
                    AngularGradient(
                        colors: [CoachColor.purple.opacity(0.45), CoachColor.purpleDeep, CoachColor.sun],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(confidence)%")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)
                Text("trust")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CoachColor.muted)
            }
        }
        .frame(width: 78, height: 78)
    }

    private func metricPill(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            iconTile(icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CoachColor.muted)
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.07))
        )
    }

    private func sectionHeader(_ title: String, icon: String?) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(CoachColor.purpleDeep)
    }

    private func numberedSectionHeader(number: Int, title: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(CoachColor.purpleDeep.opacity(0.12))
                    .frame(width: 20, height: 20)
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.purpleDeep)
            }
            sectionHeader(title, icon: nil)
        }
    }

    private func insightMiniRow(icon: String, title: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconTile(icon, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CoachColor.ink)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconTile(_ icon: String, color: Color, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.10))
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func premiumCardBackground(cornerRadius: CGFloat = 18) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.systemBackground))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [CoachColor.purple.opacity(0.045), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
        }
        .shadow(color: CoachColor.purpleDeep.opacity(0.07), radius: 14, x: 0, y: 6)
    }

    private func cardStroke(_ cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(CoachColor.purple.opacity(0.14), lineWidth: 1)
    }

    // MARK: - Computed

    private var displayedBabyName: String {
        let trimmed = babyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (orchestrator.snapshot?.babyName ?? "Baby") : trimmed
    }

    private var overallConfidence: Int {
        let daytime = orchestrator.snapshot?.daytime.confidence ?? 0
        let night = orchestrator.snapshot?.night.confidence ?? daytime
        return max(0, min(100, orchestrator.snapshot?.nextSleepKind == .bedtime ? night : daytime))
    }

    private var confidenceLevelText: String {
        switch overallConfidence {
        case 85...100: return "Very high"
        case 70..<85: return "High"
        case 50..<70: return "Learning"
        default: return "Needs logs"
        }
    }

    private var confidenceLevelColor: Color {
        switch overallConfidence {
        case 70...100: return CoachColor.green
        case 50..<70: return CoachColor.sun
        default: return CoachColor.red
        }
    }

    private var agentContributions: [AgentContribution] {
        guard let snapshot = orchestrator.snapshot else {
            return [
                AgentContribution(id: "phase", name: "Sleep Phase Agent", icon: "moonphase.first.quarter", score: 0),
                AgentContribution(id: "pattern", name: "Pattern Agent", icon: "chart.xyaxis.line", score: 0),
                AgentContribution(id: "wake", name: "Wake Window Agent", icon: "clock.arrow.circlepath", score: 0),
                AgentContribution(id: "transition", name: "Transition Agent", icon: "arrow.triangle.2.circlepath", score: 0),
                AgentContribution(id: "risk", name: "Overtired Risk Agent", icon: "exclamationmark.triangle", score: 0),
                AgentContribution(id: "confidence", name: "Confidence Agent", icon: "shield.checkered", score: 0)
            ]
        }

        let report = snapshot.dataQualityReport
        return [
            AgentContribution(id: "phase", name: "Sleep Phase Agent", icon: "moonphase.first.quarter", score: snapshot.readiness.confidence),
            AgentContribution(id: "pattern", name: "Pattern Agent", icon: "chart.xyaxis.line", score: report.rhythmStabilityScore),
            AgentContribution(id: "wake", name: "Wake Window Agent", icon: "clock.arrow.circlepath", score: snapshot.daytime.confidence),
            AgentContribution(id: "transition", name: "Transition Agent", icon: "arrow.triangle.2.circlepath", score: transitionContributionScore),
            AgentContribution(id: "risk", name: "Overtired Risk Agent", icon: "exclamationmark.triangle", score: snapshot.night.confidence),
            AgentContribution(id: "confidence", name: "Confidence Agent", icon: "shield.checkered", score: report.score)
        ]
    }

    private var transitionContributionScore: Int {
        guard let strength = orchestrator.snapshot?.transition.signalStrength else { return 50 }
        switch strength {
        case .none: return 68
        case .weak: return 74
        case .moderate: return 82
        case .strong: return 90
        }
    }

    private var confidenceSignals: [ConfidenceSignal] {
        guard let report = orchestrator.snapshot?.dataQualityReport else {
            return [ConfidenceSignal(id: "empty", title: "Waiting for logs", detail: "Add wake and sleep data", isPositive: false)]
        }

        return [
            ConfidenceSignal(
                id: "tracked",
                title: "\(min(report.trackedDays, 14)) of 14 days tracked",
                detail: report.trackedDays >= 14 ? "Personalized phase active" : "\(max(0, 14 - report.trackedDays)) days left",
                isPositive: report.trackedDays >= 7
            ),
            ConfidenceSignal(
                id: "wake",
                title: "Wake-up time \(orchestrator.snapshot?.daytime.usedDefaultWakeTime == true ? "using default" : "logged")",
                detail: orchestrator.snapshot?.daytime.usedDefaultWakeTime == true ? "Add wake-up for a stronger anchor" : "Strong daily anchor",
                isPositive: orchestrator.snapshot?.daytime.usedDefaultWakeTime != true
            ),
            ConfidenceSignal(
                id: "complete",
                title: "\(report.completeDays) complete days",
                detail: report.completeDays >= 7 ? "Good coverage" : "More full days will help",
                isPositive: report.completeDays >= min(7, max(1, report.trackedDays))
            ),
            ConfidenceSignal(
                id: "consistency",
                title: "Consistency \(qualityWord(report.consistencyScore))",
                detail: "Routine stability signal",
                isPositive: report.consistencyScore >= 70
            ),
            ConfidenceSignal(
                id: "plausibility",
                title: report.plausibilityAnomalyCount == 0 ? "No major data gaps" : "\(report.plausibilityAnomalyCount) data checks",
                detail: report.plausibilityAnomalyCount == 0 ? "Logs look plausible" : "Some entries need review",
                isPositive: report.plausibilityScore >= 80
            )
        ]
    }

    private var confidenceLimitTitle: String {
        orchestrator.snapshot?.phase == .personalized ? "Real life still varies." : "We are still learning."
    }

    private var confidenceLimitDetail: String {
        let remaining = max(0, 14 - trackedDays)
        if remaining > 0 {
            return "\(remaining) more day\(remaining == 1 ? "" : "s") until prediction confidence increases. Sleep cues and late logs can still shift the window."
        }
        return "Even with 14+ days, naps can shift with growth, illness, travel, and missed sleepy cues."
    }

    private var comparisonMetrics: [ComparisonMetric] {
        [
            ComparisonMetric(
                id: "lastNap",
                title: "Last nap",
                value: signedMinutesText(todayLastNapDelta),
                detail: todayLastNapDelta == 0 ? "stable" : (todayLastNapDelta > 0 ? "longer" : "shorter"),
                icon: "moon.zzz.fill",
                color: CoachColor.purpleDeep
            ),
            ComparisonMetric(
                id: "bedtime",
                title: "Bedtime shift",
                value: signedMinutesText(bedtimeShiftDelta),
                detail: bedtimeShiftDelta == 0 ? "same" : (bedtimeShiftDelta > 0 ? "later" : "earlier"),
                icon: "sparkles",
                color: bedtimeShiftDelta <= 0 ? CoachColor.green : CoachColor.sun
            ),
            ComparisonMetric(
                id: "risk",
                title: "Overtired risk",
                value: overtiredRiskComparisonValue,
                detail: overtiredRiskComparisonDetail,
                icon: "exclamationmark.triangle",
                color: overtiredRiskComparisonValue == "Higher" ? CoachColor.red : CoachColor.sun
            )
        ]
    }

    private var decisionSteps: [DecisionStep] {
        let target = orchestrator.snapshot?.nextSleepKind == .bedtime
            ? (orchestrator.snapshot?.night.optimalBedtimeStart ?? Date())
            : (orchestrator.snapshot?.daytime.nextNapTime ?? Date())
        let lastNapEnd = todayLastNapEnd

        return [
            DecisionStep(id: "record", time: "Input", title: lastNapEnd == nil ? "Wake anchor" : "Last nap end", icon: "clock.badge.checkmark", color: CoachColor.purpleDeep),
            DecisionStep(id: "rule", time: "Rules", title: "Age guideline", icon: "gearshape.2.fill", color: CoachColor.purpleDeep),
            DecisionStep(id: "pattern", time: "Pattern", title: "Baby rhythm", icon: "brain.head.profile", color: CoachColor.purple),
            DecisionStep(id: "confidence", time: "Trust", title: "Quality check", icon: "checkmark.seal.fill", color: CoachColor.purpleDeep),
            DecisionStep(id: "final", time: time(target), title: orchestrator.snapshot?.nextSleepKind == .bedtime ? "Bedtime target" : "Sleep target", icon: "shield.lefthalf.filled", color: CoachColor.sun)
        ]
    }

    private var todayLastNapEnd: Date? {
        loadTodayRecordsForBreakdown()
            .filter { $0.kind == .dayNap && !$0.isOngoing }
            .sorted { $0.date < $1.date }
            .last
            .map { $0.date.addingMinutes($0.duration) }
    }

    private var todayLastNapDelta: Int {
        let todayNaps = loadTodayRecordsForBreakdown().filter { $0.kind == .dayNap && !$0.isOngoing }
        guard let latest = todayNaps.sorted(by: { $0.date < $1.date }).last else { return 0 }
        let average = orchestrator.snapshot?.pattern?.averageNapDurationMinutes ?? latest.duration
        return latest.duration - average
    }

    private var bedtimeShiftDelta: Int {
        guard let shift = orchestrator.snapshot?.pattern?.estimatedBedtimeShiftMinutes else { return 0 }
        return shift
    }

    private var overtiredRiskComparisonValue: String {
        guard let night = orchestrator.snapshot?.night else { return "Stable" }
        return night.overtiredRiskTime <= Date() ? "Higher" : "Stable"
    }

    private var overtiredRiskComparisonDetail: String {
        overtiredRiskComparisonValue == "Higher" ? "act soon" : "within window"
    }

    private var trackedDays: Int {
        guard let readiness = orchestrator.snapshot?.readiness else { return 0 }
        return max(0, 14 - readiness.daysUntilPersonalized)
    }

    private var learningProgressTitle: String {
        orchestrator.snapshot?.phase == .personalized
            ? "Your baby's rhythm is personalized"
            : "Learning your baby's unique rhythm"
    }

    private func learningProgressDetail(remaining: Int) -> String {
        if orchestrator.snapshot?.phase == .personalized {
            return "Predictions now prioritize recent wake windows, naps, and bedtime patterns."
        }
        if remaining == 1 {
            return "1 more day until predictions become fully personalized and even more accurate."
        }
        return "\(remaining) more days until predictions become fully personalized and even more accurate."
    }

    private var coachTipText: String {
        if let llmMessage = orchestrator.llmResponse?.coachMessage, !llmMessage.isEmpty {
            return llmMessage
        }
        if orchestrator.isLLMLoading {
            return "Analyzing \(displayedBabyName)'s sleep patterns..."
        }
        return orchestrator.snapshot?.insights.coachTip
            ?? "Keep logging to unlock personalized tips."
    }

    private var napWindowText: String {
        guard let daytime = orchestrator.snapshot?.daytime else { return "-" }
        return "\(time(daytime.windowStart)) - \(time(daytime.windowEnd))"
    }

    private var bedtimeWindowText: String {
        guard let night = orchestrator.snapshot?.night else { return "-" }
        return "\(time(night.optimalBedtimeStart)) - \(time(night.optimalBedtimeEnd))"
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func signedMinutesText(_ minutes: Int) -> String {
        guard minutes != 0 else { return "Unchanged" }
        return "\(minutes > 0 ? "+" : "-")\(abs(minutes)) min"
    }

    private func qualityWord(_ score: Int) -> String {
        switch score {
        case 85...100: return "excellent"
        case 70..<85: return "good"
        case 50..<70: return "building"
        default: return "limited"
        }
    }

    private func refresh() {
        orchestrator.generate()
    }
}

private struct CoachBotArtwork: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Circle()
                    .fill(CoachColor.purple.opacity(0.10))
                    .frame(width: w * 0.90, height: w * 0.90)
                    .position(x: w * 0.48, y: h * 0.45)

                Capsule()
                    .fill(CoachColor.purple.opacity(0.20))
                    .frame(width: w * 0.92, height: h * 0.42)
                    .rotationEffect(.degrees(-8))
                    .position(x: w * 0.45, y: h * 0.78)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
                    .frame(width: w * 0.68, height: h * 0.55)
                    .shadow(color: CoachColor.purpleDeep.opacity(0.11), radius: 10, x: 0, y: 5)
                    .position(x: w * 0.50, y: h * 0.44)

                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(CoachColor.purpleDeep)
                    .frame(width: w * 0.50, height: h * 0.29)
                    .position(x: w * 0.50, y: h * 0.44)

                HStack(spacing: w * 0.13) {
                    Circle().fill(.white).frame(width: 5, height: 5)
                    Circle().fill(.white).frame(width: 5, height: 5)
                }
                .position(x: w * 0.50, y: h * 0.43)

                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: w * 0.18, height: 3)
                    .position(x: w * 0.50, y: h * 0.52)

                Capsule()
                    .fill(CoachColor.purple.opacity(0.24))
                    .frame(width: 5, height: h * 0.15)
                    .position(x: w * 0.50, y: h * 0.12)

                Circle()
                    .fill(CoachColor.purple.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .position(x: w * 0.50, y: h * 0.04)
            }
        }
    }
}

private struct CoachMoonArtwork: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: w * 0.66, height: w * 0.66)
                    .shadow(color: CoachColor.purple.opacity(0.16), radius: 12, x: 0, y: 5)
                    .position(x: w * 0.54, y: h * 0.52)
                Circle()
                    .fill(CoachColor.background)
                    .frame(width: w * 0.52, height: w * 0.52)
                    .position(x: w * 0.68, y: h * 0.40)
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CoachColor.purple.opacity(0.62))
                    .position(x: w * 0.16, y: h * 0.30)
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CoachColor.sun.opacity(0.9))
                    .position(x: w * 0.86, y: h * 0.34)
            }
        }
    }
}

private enum CoachColor {
    static let background = Color(.systemGroupedBackground)
    static let ink = Color(.label)
    static let muted = Color(.secondaryLabel)
    static let purple = Color(red: 0.55, green: 0.45, blue: 0.96)
    static let purpleDeep = Color(red: 0.45, green: 0.35, blue: 0.92)
    static let sun = Color(red: 1.0, green: 0.68, blue: 0.12)
    static let green = Color(red: 0.16, green: 0.68, blue: 0.46)
    static let red = Color(red: 0.95, green: 0.22, blue: 0.32)
    static let stroke = Color(.separator)
}
