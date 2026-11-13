import SwiftUI

/// Only the top card from the approved board is product UI.
struct TodayPlanCard: View {
    let items: [SleepTimelineItem]
    let now: Date
    var calendar: Calendar = .current
    let viewFullPlan: () -> Void
    @ScaledMetric(relativeTo: .body) private var nodeWidth: CGFloat = 68
    @ScaledMetric(relativeTo: .body) private var nodeDiameter: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var connectorWidth: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    private var presentation: TodayPlanPresentation { .init(items: items) }
    private var accent: Color { RecordingColor.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading
                    Spacer(minLength: 8)
                    detailsButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    detailsButton
                }
            }

            ViewThatFits(in: .horizontal) {
                timeline.fixedSize(horizontal: true, vertical: false)
                ScrollView(.horizontal) {
                    timeline.padding(.vertical, 5)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.plan.scroll")
            }
        }
        .foregroundStyle(RecordingColor.ink)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [CoachColor.purple.opacity(0.025),
                            CoachColor.purple.opacity(colorScheme == .dark ? 0.12 : 0.065)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(CoachColor.purple.opacity(0.15), lineWidth: 1))
        .shadow(color: CoachColor.purpleDeep.opacity(0.08), radius: 12, x: 0, y: 5)
    }

    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { title; progress }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { title; progress }
        }
    }

    private var title: some View {
        Text("Today's Plan")
            .recordingFont(20, weight: .bold, rounded: true)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var progress: some View {
        Group {
            if presentation.availableEventCount > 0 {
                Text("Today · \(presentation.completedEventCount) of \(presentation.availableEventCount)")
            } else {
                Text("Today · No records")
            }
        }
        .recordingFont(11, weight: .bold)
        .foregroundStyle(accent)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(CoachColor.purple.opacity(0.11), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("\(presentation.completedEventCount) completed of \(presentation.availableEventCount) available events")
        .accessibilityIdentifier("home.plan.progress")
    }

    private var detailsButton: some View {
        Button(action: viewFullPlan) {
            HStack(spacing: 5) {
                Text("View full plan")
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .recordingFont(12, weight: .bold)
            .foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.plan.details")
    }

    private var timeline: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                node(item)
                if index < items.count - 1 { connector(after: index) }
            }
        }
    }

    private func node(_ item: SleepTimelineItem) -> some View {
        VStack(spacing: 5) {
            symbol(item).padding(.bottom, 5)
            Group {
                if let time = item.time {
                    if calendar.isDate(time, inSameDayAs: now) {
                        Text(time, format: .dateTime.hour().minute())
                    } else {
                        Text(time, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                } else { Text("—") }
            }
            .recordingFont(12, weight: .semibold)
            .foregroundStyle(RecordingColor.secondary)
            .monospacedDigit()

            eventTitle(item).recordingFont(13, weight: .bold)
            status(item).recordingFont(11, weight: .semibold)
            if item.isCarryover {
                Text("Previous Sleep Day").recordingFont(10, weight: .medium)
                    .foregroundStyle(RecordingColor.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: nodeWidth)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.plan.event.\(item.id)")
    }

    private func eventTitle(_ item: SleepTimelineItem) -> Text {
        switch item.kind {
        case .wake: return Text("Wake up")
        case .nap(let index): return index.map { Text("Nap \($0)") } ?? Text("Nap")
        case .bedtime:
            if case .recorded = item.source { return Text("Night sleep") }
            return Text("Bedtime")
        case .plan: return Text("Plan")
        }
    }

    private func symbol(_ item: SleepTimelineItem) -> some View {
        let active = item.visualState == .active
        let completed = item.visualState == .completed
        let next = item.visualState == .next
        let iconColor = item.visualState == .unavailable ? RecordingColor.secondary :
            (item.visualState == .future ? CoachColor.purple.opacity(0.65) : accent)
        return ZStack {
            if active {
                Circle().fill(CoachColor.purple.opacity(0.10)).padding(-9)
                Circle().stroke(CoachColor.purple.opacity(0.14), lineWidth: 5).padding(-4)
            }
            Circle().fill(active ? AnyShapeStyle(LinearGradient(colors: [CoachColor.purple,
                CoachColor.purpleDeep], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                AnyShapeStyle(CoachColor.purple.opacity(completed ? 0.09 : 0.025)))
            Circle().strokeBorder(active ? Color.white.opacity(0.7) : CoachColor.purple.opacity(next ? 0.85 : 0.35),
                style: StrokeStyle(lineWidth: next ? 1.8 : 1.4,
                    dash: item.visualState == .future || item.visualState == .unavailable ? [4, 3] : []))
            Image(systemName: completed ? "checkmark" : icon(item))
                .recordingFont(17, weight: .semibold)
                .foregroundStyle(active ? Color.white : (completed ? CoachColor.muted : iconColor))
        }
        .frame(width: nodeDiameter, height: nodeDiameter)
        .padding(.vertical, 9)
        .accessibilityHidden(true)
    }

    private func icon(_ item: SleepTimelineItem) -> String {
        switch item.kind {
        case .wake: return "sun.max.fill"
        case .nap: return "moon.fill"
        case .bedtime: return "moon.zzz.fill"
        case .plan: return "calendar"
        }
    }

    @ViewBuilder private func status(_ item: SleepTimelineItem) -> some View {
        switch item.visualState {
        case .completed:
            Text("Done").foregroundStyle(RecordingColor.secondary)
            if let duration = item.durationMinutes {
                Text("\(TimeFormat.minutes(duration)) sleep")
                    .recordingFont(10, weight: .medium).foregroundStyle(RecordingColor.secondary)
            }
        case .active:
            Text("Sleeping now · \(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed")
                .foregroundStyle(accent)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(width: nodeWidth + 12)
                .background(CoachColor.purple.opacity(0.13), in: Capsule())
        case .next, .future:
            if item.visualState == .next {
                Text("Next · Estimated").foregroundStyle(accent)
            } else {
                Text("Estimated").foregroundStyle(accent)
            }
            if let minutes = presentation.minutesUntil(item, now: now) {
                Text("in \(TimeFormat.minutes(minutes))").foregroundStyle(accent)
            }
        case .unavailable:
            unavailableText(item).foregroundStyle(RecordingColor.secondary)
        }
    }

    private func unavailableText(_ item: SleepTimelineItem) -> Text {
        switch item.source {
        case .recorded: return Text("Unconfirmed interval")
        case .defaultValue: return Text("Default · not recorded")
        case .guidance: return Text("General guidance")
        case .estimate:
            return item.unavailableReason == .overdue ? Text("Overdue estimate") : Text("Estimate unavailable")
        case .unavailable:
            return item.kind == .wake ? Text("Not recorded") : Text("Prediction unavailable")
        }
    }

    private func connector(after index: Int) -> some View {
        let solid = presentation.isConfirmedConnector(after: index)
        let gap = items[index + 1].awakeBeforeMinutes
        let inset = max(0, (nodeWidth - nodeDiameter) / 2)
        return Rectangle().fill(Color.clear)
            .frame(width: connectorWidth, height: nodeDiameter + 18)
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: -inset, y: (nodeDiameter + 18) / 2))
                    path.addLine(to: CGPoint(x: connectorWidth + inset, y: (nodeDiameter + 18) / 2))
                }
                .stroke(CoachColor.purple.opacity(solid ? 0.8 : 0.22),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: solid ? [] : [1, 4]))
            }
            .overlay(alignment: .top) {
                if let gap, gap > 0 {
                    Text(TimeFormat.minutes(gap))
                        .recordingFont(10, weight: .semibold)
                        .foregroundStyle(RecordingColor.secondary)
                        .fixedSize()
                        .accessibilityLabel("Awake for \(TimeFormat.minutes(gap))")
                }
            }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Explicit offline simulator fixtures; never authorize production prediction eligibility.
enum TodayPlanUITestFixture {
    static var enabled: Bool { ProcessInfo.processInfo.environment["TODAY_PLAN_UI_TESTS"] == "1" }
    static var scenario: String { ProcessInfo.processInfo.environment["TODAY_PLAN_SCENARIO"] ?? "empty" }
    static var now: Date {
        Calendar.current.date(bySettingHour: 12, minute: 7, second: 0, of: Date())!
    }
    static let parentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
    }
    static func prepare() {
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "authComplete")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set("Alex", forKey: "parentName")
        defaults.set("Baby", forKey: "babyName")
        defaults.set(ProcessInfo.processInfo.environment["TODAY_PLAN_DARK"] == "1" ? "dark" : "light", forKey: "appAppearance")
        var records: [SleepRecord] = []
        var wakes: [DailyWakeRecord] = []
        if scenario != "empty" && scenario != "carryover" {
            wakes = [DailyWakeRecord(day: Calendar.current.startOfDay(for: now), wakeTime: at(7, 15))]
        }
        switch scenario {
        case "completed":
            let nap = SleepRecord(id: parentID, date: at(9), duration: 60, createdAt: at(9))
            records = [nap, SleepRecord(date: at(9, 15), duration: 10, kind: .break, parentNapID: parentID)]
        case "active", "reference":
            records = [SleepRecord(id: parentID, date: at(11, 41), duration: 0, isOngoing: true, createdAt: at(11, 41))]
        case "many":
            wakes = [DailyWakeRecord(day: Calendar.current.startOfDay(for: now), wakeTime: at(4))]
            records = (1...5).map { SleepRecord(date: at(4 + $0), duration: 20, createdAt: at(4 + $0)) }
        case "carryover":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            let start = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: yesterday)!
            records = [SleepRecord(id: parentID, date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)]
        default: break
        }
        SleepRecordPersistence().save(records)
        DailyWakeRecordPersistence().save(wakes)
    }
    static func timeline(records: [SleepRecord], wakes: [DailyWakeRecord]) -> [SleepTimelineItem] {
        let proposals: [SleepTimelineProposal] = scenario == "reference" ? [
            .init(id: "fixture-nap-2", kind: .nap(index: 2), sleepDay: now, time: at(14, 36), source: .estimate),
            .init(id: "fixture-bedtime", kind: .bedtime, sleepDay: now, time: at(18), source: .estimate)
        ] : []
        return SleepTimelineCalculator(records: records, wakeRecord: wakes.first, now: now,
            calendar: .current, proposals: proposals,
            predictionEligibility: scenario == "reference" ? .verified : .unavailable).calculate()
    }
}
#endif
