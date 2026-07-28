import SwiftUI

struct InsightsView: View {

    private enum CoachTab: String, CaseIterable {
        case overview = "Today"
        case predictions = "Logic"

        var icon: String {
            switch self {
            case .overview: return "sparkles"
            case .predictions: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    @State private var selectedTab: CoachTab = .overview
    @StateObject private var orchestrator = SleepCoachOrchestrator.shared
    @AppStorage("babyName") private var babyName: String = "Baby"

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    headerSection
                    coachHeroCard
                    tabPicker

                    if selectedTab == .overview {
                        todayDecisionStack
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI Coach")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)
                Text("\(displayedBabyName)'s sleep guidance")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CoachColor.muted)
            }

            Spacer()

            CoachMoonArtwork()
                .frame(width: 66, height: 52)
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(CoachTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selectedTab == tab ? .white : CoachColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selectedTab == tab ? CoachColor.purpleDeep : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(cardStroke(15))
    }

    // MARK: - Overview

    private var coachHeroCard: some View {
        let nextKind = orchestrator.snapshot?.nextSleepKind ?? .nap
        let isBedtime = nextKind == .bedtime
        let targetTime = isBedtime
            ? (orchestrator.snapshot?.night.optimalBedtimeStart ?? Date())
            : (orchestrator.snapshot?.daytime.nextNapTime ?? Date())

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(CoachColor.purpleDeep)
                            .frame(width: 7, height: 7)
                        Text(isBedtime ? "BEDTIME GUIDANCE" : "NEXT NAP GUIDANCE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CoachColor.purpleDeep)
                            .tracking(0.5)
                    }

                    Text(isBedtime ? "Start bedtime at \(time(targetTime))" : "Aim for \(time(targetTime))")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(CoachColor.ink)
                        .monospacedDigit()
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(primaryCoachLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CoachColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                confidenceRing
            }

            HStack(spacing: 9) {
                metricPill(
                    title: "Window",
                    value: isBedtime ? bedtimeWindowText : napWindowText,
                    icon: "timer",
                    color: CoachColor.purpleDeep
                )
                metricPill(
                    title: "Mode",
                    value: modeLabel,
                    icon: "brain.head.profile",
                    color: modeColor
                )
            }
        }
        .padding(18)
        .background(premiumCardBackground(cornerRadius: 22))
        .overlay(cardStroke(22))
    }

    private var todayDecisionStack: some View {
        VStack(spacing: 12) {
            guidanceTimelineCard
            coachMessageCard
            signalsCard
        }
    }

    private var guidanceTimelineCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionHeader("TODAY'S COACH PLAN", icon: "calendar.badge.clock")

            HStack(alignment: .top, spacing: 0) {
                timelineNode(
                    icon: "sun.max.fill",
                    title: "Wake",
                    timeText: wakeAnchorText,
                    detail: wakeDetail,
                    color: CoachColor.sun,
                    state: .done
                )
                timelineSegment(label: firstWakeWindowText, dashed: false)
                timelineNode(
                    icon: "moon.fill",
                    title: "Nap",
                    timeText: daytimeTimeText,
                    detail: "Predicted",
                    color: CoachColor.purpleDeep,
                    state: .active
                )
                timelineSegment(label: eveningWindowText, dashed: true)
                timelineNode(
                    icon: "moon.stars.fill",
                    title: "Bed",
                    timeText: bedtimeStartText,
                    detail: "Optimal",
                    color: CoachColor.purple,
                    state: .upcoming
                )
            }

            infoStrip(
                icon: "arrow.triangle.2.circlepath",
                text: "Plan updates after every sleep, wake-up, or wake period entry."
            )
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var coachMessageCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                iconTile("sparkles", color: CoachColor.purpleDeep, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("AI COACH NOTE", icon: nil)
                    Text(tipTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CoachColor.ink)
                }
                Spacer()
                Button {
                    orchestrator.refreshLLM()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CoachColor.purpleDeep)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(CoachColor.purple.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }

            if orchestrator.isLLMLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(CoachColor.purpleDeep)
                    Text("Analyzing \(displayedBabyName)'s rhythm...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CoachColor.muted)
                }
            } else {
                Text(coachTipText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let insight = orchestrator.llmResponse?.patternInsight, !insight.isEmpty {
                Divider().overlay(CoachColor.stroke)
                insightMiniRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Pattern signal",
                    text: insight,
                    color: CoachColor.green
                )
            }

            if let alert = orchestrator.llmResponse?.alert, !alert.isEmpty {
                insightMiniRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Watch point",
                    text: alert,
                    color: CoachColor.sun
                )
            }
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    private var signalsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader("\(displayedBabyName.uppercased())'S SIGNALS", icon: "waveform.path.ecg")

            let alerts = orchestrator.snapshot?.insights.alerts ?? []
            if alerts.isEmpty {
                emptyStateRow
            } else {
                ForEach(Array(alerts.prefix(3).enumerated()), id: \.offset) { index, alert in
                    alertRow(alert)
                    if index < min(alerts.count, 3) - 1 {
                        Divider().overlay(CoachColor.stroke).padding(.leading, 48)
                    }
                }
            }
        }
        .padding(16)
        .background(premiumCardBackground())
        .overlay(cardStroke(18))
    }

    // MARK: - Logic

    private var predictionLogicStack: some View {
        VStack(spacing: 12) {
            learningStatusCard
            reasoningCard
            nightWindowCard
            healthCard
        }
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

    private enum TimelineState {
        case done
        case active
        case upcoming
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

    private func timelineNode(
        icon: String,
        title: String,
        timeText: String,
        detail: String,
        color: Color,
        state: TimelineState
    ) -> some View {
        let isActive = state == .active
        let opacity = state == .done ? 0.58 : 1.0

        return VStack(spacing: 6) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(color.opacity(0.16))
                        .frame(width: 46, height: 46)
                        .blur(radius: 7)
                }
                Circle()
                    .fill(color.opacity(isActive ? 0.18 : 0.10))
                    .frame(width: 34, height: 34)
                Circle()
                    .strokeBorder(
                        color.opacity(state == .upcoming ? 0.35 : 0.58),
                        style: state == .upcoming
                            ? StrokeStyle(lineWidth: 1.4, dash: [3, 3])
                            : StrokeStyle(lineWidth: isActive ? 1.8 : 1.0)
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color.opacity(opacity))
            }

            Text(timeText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel).opacity(opacity))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle((isActive ? CoachColor.ink : CoachColor.muted).opacity(opacity))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color.opacity(isActive ? 0.9 : opacity))
                .lineLimit(1)
        }
        .frame(width: 58)
    }

    private func timelineSegment(label: String, dashed: Bool) -> some View {
        VStack(spacing: 3) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1.5)
                .overlay(
                    Rectangle()
                        .strokeBorder(
                            CoachColor.purple.opacity(dashed ? 0.24 : 0.34),
                            style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : [])
                        )
                )

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
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

    private func alertRow(_ alert: SleepAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconTile(alertIcon(alert.severity), color: alertColor(alert.severity), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(alertTitle(alert.severity))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CoachColor.ink)
                    Spacer()
                    if let action = alert.actionTitle {
                        Text(action)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(CoachColor.purpleDeep)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(CoachColor.purple.opacity(0.10)))
                    }
                }
                Text(alert.message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyStateRow: some View {
        HStack(spacing: 10) {
            iconTile("checkmark.seal.fill", color: CoachColor.green, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("No urgent signals")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CoachColor.ink)
                Text("Keep logging sleep to make coaching more personalized.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachColor.muted)
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

    private func infoStrip(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(CoachColor.purpleDeep)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CoachColor.purple.opacity(0.055))
        )
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

    private var primaryCoachLine: String {
        if let next = orchestrator.snapshot?.nextSleepKind, next == .bedtime {
            return "Tonight's window is \(bedtimeWindowText), with risk rising after \(overtiredRiskText)."
        }
        return "Best nap window: \(napWindowText). Confidence improves as logs become more complete."
    }

    private var tipTitle: String {
        guard let readiness = orchestrator.snapshot?.readiness else {
            return "Start with today's wake-up time"
        }
        return readiness.missingSignals.contains(.wakeTime)
            ? "Start with today's wake-up time"
            : "Follow the window, then follow the baby"
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

    // MARK: - Helpers

    private func alertIcon(_ severity: AlertSeverity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.circle.fill"
        }
    }

    private func alertColor(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return CoachColor.purple
        case .warning: return CoachColor.sun
        case .critical: return .red
        }
    }

    private func alertTitle(_ severity: AlertSeverity) -> String {
        switch severity {
        case .info: return "Info"
        case .warning: return "Heads up"
        case .critical: return "Action needed"
        }
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
    static let stroke = Color(.separator)
}
