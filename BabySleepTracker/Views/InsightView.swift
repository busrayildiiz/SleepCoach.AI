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
    @StateObject private var orchestrator = SleepCoachOrchestrator.shared
    
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

    // MARK: - Logic

    private var predictionLogicStack: some View {
        VStack(spacing: 12) {
            medicalEvidenceCard
            learningStatusCard
            reasoningCard
            nightWindowCard
            healthCard
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
    
    private var learningStatusCard: some View {
        let tracked = trackedDays
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    sectionHeader("PREDICTION MODEL", icon: "brain.head.profile")
                    Text(modeDescription)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CoachColor.muted)
                }
                Spacer()
                statusBadge(modeLabel, color: modeColor)
            }

            ProgressView(value: Double(min(tracked, 14)), total: 14)
                .tint(CoachColor.purpleDeep)

            HStack {
                Text("\(min(tracked, 14)) tracked days")
                Spacer()
                Text(orchestrator.snapshot?.phase == .personalized ? "Personalized" : "\(max(0, 14 - tracked)) days left")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(CoachColor.muted)
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var reasoningCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader("WHY THIS PREDICTION", icon: "checkmark.seal.fill")

            let reasons = orchestrator.snapshot?.daytime.reasoning ?? []
            if reasons.isEmpty {
                Text("Add wake-up and sleep records to unlock a clearer explanation.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
            } else {
                ForEach(Array(reasons.enumerated()), id: \.offset) { index, reason in
                    numberedReason(index: index + 1, text: reason)
                }
            }
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var nightWindowCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader("TONIGHT WINDOW", icon: "moon.stars.fill")

            HStack(spacing: 10) {
                metricBox("Recommended Start Bedtime", bedtimeStartText, CoachColor.green)
                metricBox("Recommended Latest Bedtime", bedtimeEndText, CoachColor.purpleDeep)
                metricBox("Overtired Risk Hour", overtiredRiskText, CoachColor.sun)
            }

            if let night = orchestrator.snapshot?.night {
                ForEach(night.reasoning.prefix(2), id: \.self) { reason in
                    insightMiniRow(icon: "moon.fill", title: "Night logic", text: reason, color: CoachColor.purple)
                }
            }
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("HEALTH GUARDRAIL", icon: "shield.checkered")
            Text(healthGuardrailText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
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

    private func metricBox(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(CoachColor.muted)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.075))
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

    private func numberedReason(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(CoachColor.purpleDeep))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.10)))
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

    private var trackedDays: Int {
        guard let readiness = orchestrator.snapshot?.readiness else { return 0 }
        return max(0, 14 - readiness.daysUntilPersonalized)
    }

    private var modeLabel: String {
        guard let phase = orchestrator.snapshot?.phase else { return "BASELINE" }
        switch phase {
        case .tooYoung: return "TOO YOUNG"
        case .baseline: return "BASELINE"
        case .learning(let day): return "LEARNING \(min(day, 14))/14"
        case .personalized: return "PERSONAL"
        }
    }

    private var modeColor: Color {
        orchestrator.snapshot?.phase == .personalized ? CoachColor.green : CoachColor.purpleDeep
    }

    private var modeDescription: String {
        guard let phase = orchestrator.snapshot?.phase else {
            return "Start logging sleep to begin."
        }
        switch phase {
        case .tooYoung:
            return "Predictions activate at 4 months."
        case .baseline:
            return "Using age baseline until wake and sleep records build a rhythm."
        case .learning:
            return "Blending age guidance with \(displayedBabyName)'s observed sleep."
        case .personalized:
            return "Predictions prioritize \(displayedBabyName)'s own rhythm."
        }
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

    private var primaryCoachLine: String {
        if let next = orchestrator.snapshot?.nextSleepKind, next == .bedtime {
            return "Tonight's window is \(bedtimeWindowText), with risk rising after \(overtiredRiskText)."
        }
        return "Best nap window: \(napWindowText). Confidence improves as logs become more complete."
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

    private var wakeAnchorText: String {
        guard let daytime = orchestrator.snapshot?.daytime else { return "-" }
        return time(daytime.nextNapTime.addingMinutes(-daytime.wakeWindowUsed))
    }

    private var wakeDetail: String {
        orchestrator.snapshot?.daytime.usedDefaultWakeTime == true ? "Default" : "Logged"
    }

    private var daytimeTimeText: String {
        guard let date = orchestrator.snapshot?.daytime.nextNapTime else { return "-" }
        return time(date)
    }

    private var bedtimeStartText: String {
        guard let date = orchestrator.snapshot?.night.optimalBedtimeStart else { return "-" }
        return time(date)
    }

    private var bedtimeEndText: String {
        guard let date = orchestrator.snapshot?.night.optimalBedtimeEnd else { return "-" }
        return time(date)
    }

    private var overtiredRiskText: String {
        guard let date = orchestrator.snapshot?.night.overtiredRiskTime else { return "-" }
        return time(date)
    }

    private var firstWakeWindowText: String {
        guard let minutes = orchestrator.snapshot?.daytime.wakeWindowUsed else { return "" }
        return TimeFormat.minutes(minutes)
    }

    private var eveningWindowText: String {
        guard let night = orchestrator.snapshot?.night else { return "" }
        let minutes = max(0, Int(night.optimalBedtimeStart.timeIntervalSince(orchestrator.snapshot?.daytime.nextNapTime ?? night.optimalBedtimeStart) / 60))
        return minutes > 0 ? TimeFormat.minutes(minutes) : ""
    }

    private var healthGuardrailText: String {
        guard let ageMonths = orchestrator.snapshot?.ageMonths else {
            return "Log sleep to see health guardrail info."
        }
        if ageMonths < 4 {
            return "AAP guidance does not set a fixed sleep target before 4 months."
        }
        return "AAP-endorsed guidance checks total 24h sleep. Nap timing uses \(displayedBabyName)'s own data when enough logs exist."
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
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
