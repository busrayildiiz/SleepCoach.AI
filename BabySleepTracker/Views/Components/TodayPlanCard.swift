import SwiftUI

private struct PlanNodeAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Only the compact top card from the approved design is product UI.
struct TodayPlanCard: View {
    let presentation: TodayPlanPresentation
    let now: Date
    var calendar: Calendar = .current
    let viewFullPlan: () -> Void
    @ScaledMetric(relativeTo: .body) private var minimumNodeWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var nodeDiameter: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var connectorGap: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var items: [SleepTimelineItem] { presentation.items }
    private var accent: Color { RecordingColor.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heading; Spacer(minLength: 4); detailsButton }
                VStack(alignment: .leading, spacing: 4) { heading; detailsButton }
            }
            if items.isEmpty && presentation.morningWake == nil {
                Text("No sleep recorded yet")
                    .recordingFont(12, weight: .medium).foregroundStyle(RecordingColor.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    timeline.fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal) { timeline.padding(.vertical, 2) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.plan.scroll")
                }
            }
            if presentation.predictionsUnavailable {
                Text("Predictions unavailable")
                    .recordingFont(10, weight: .medium).foregroundStyle(RecordingColor.secondary)
                    .accessibilityIdentifier("home.plan.unavailable")
            }
        }
        .foregroundStyle(RecordingColor.ink)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.systemBackground))
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

    @ViewBuilder private var heading: some View {
        if presentation.isOvernight {
            Text("Today's Plan — Overnight")
                .recordingFont(18, weight: .bold, rounded: true)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("home.plan.title")
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { title; progress }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { title; progress }
            }
        }
    }
    private var title: some View {
        Text("Today's Plan").recordingFont(20, weight: .bold, rounded: true)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("home.plan.title")
    }
    @ViewBuilder private var progress: some View {
        if presentation.availableEventCount > 0 {
            Text("Today · \(presentation.completedEventCount) of \(presentation.availableEventCount)")
                .recordingFont(11, weight: .bold).foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(CoachColor.purple.opacity(0.11), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(presentation.completedEventCount) completed of \(presentation.availableEventCount) available events")
                .accessibilityIdentifier("home.plan.progress")
        }
    }
    private var detailsButton: some View {
        Button(action: viewFullPlan) {
            HStack(spacing: 4) {
                Text("View full plan")
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .recordingFont(12, weight: .bold).foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("home.plan.details")
    }

    private var timeline: some View {
        HStack(alignment: .top, spacing: connectorGap) {
            ForEach(items) { node($0) }
            if let wake = presentation.morningWake { morningWakeNode(wake) }
        }
        .backgroundPreferenceValue(PlanNodeAnchors.self) { anchors in
            GeometryReader { proxy in
                let ids = items.map(\.id) + (presentation.morningWake.map { [$0.id] } ?? [])
                ForEach(Array(ids.dropLast().enumerated()), id: \.element) { index, id in
                    if let left = anchors[id], let right = anchors[ids[index + 1]] {
                        connector(from: proxy[left], to: proxy[right],
                            confirmed: presentation.isConfirmedConnector(after: index),
                            gap: index + 1 < items.count ? items[index + 1].awakeBeforeMinutes : nil)
                    }
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func node(_ item: SleepTimelineItem) -> some View {
        VStack(spacing: 3) {
            symbol(state: item.visualState, icon: icon(item))
                .anchorPreference(key: PlanNodeAnchors.self, value: .bounds) { [item.id: $0] }
                .padding(.vertical, 6)
            eventTime(item).recordingFont(12, weight: .semibold)
                .foregroundStyle(RecordingColor.secondary).monospacedDigit().fixedSize()
            eventTitle(item).recordingFont(13, weight: .bold).fixedSize()
            status(item).recordingFont(11, weight: .semibold).fixedSize()
        }
        // Intrinsic text width is intentional: scroll rather than wrap metadata vertically.
        .frame(minWidth: minimumNodeWidth)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(metadata(item))
        .accessibilityIdentifier("home.plan.event.\(item.id)")
    }
    private func eventTime(_ item: SleepTimelineItem) -> Text {
        guard let time = item.time else { return Text("—") }
        let short = time.formatted(.dateTime.hour().minute())
        if !dynamicType.isAccessibilitySize, let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(time, inSameDayAs: yesterday) { return Text("Yesterday · \(short)") }
        return Text(time, format: .dateTime.hour().minute())
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
    private func icon(_ item: SleepTimelineItem) -> String {
        switch item.kind {
        case .wake: return "sun.max.fill"
        case .nap: return "moon.fill"
        case .bedtime: return "moon.zzz.fill"
        case .plan: return "calendar"
        }
    }
    private func symbol(state: SleepTimelineItem.VisualState, icon: String) -> some View {
        let active = state == .active
        let completed = state == .completed
        let next = state == .next
        return ZStack {
            if active {
                Circle().fill(CoachColor.purple.opacity(0.10)).padding(-6)
                Circle().stroke(CoachColor.purple.opacity(0.14), lineWidth: 4).padding(-3)
            }
            Circle().fill(active ? AnyShapeStyle(LinearGradient(colors: [CoachColor.purple,
                CoachColor.purpleDeep], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                AnyShapeStyle(CoachColor.purple.opacity(completed ? 0.09 : 0.025)))
            Circle().strokeBorder(active ? Color.white.opacity(0.7) : CoachColor.purple.opacity(next ? 0.85 : 0.35),
                style: StrokeStyle(lineWidth: next ? 1.8 : 1.4, dash: state == .future || state == .unavailable ? [4, 3] : []))
            Image(systemName: completed ? "checkmark" : icon)
                .recordingFont(17, weight: .semibold)
                .foregroundStyle(active ? Color.white : (completed ? CoachColor.muted : accent))
        }
        .frame(width: nodeDiameter, height: nodeDiameter).accessibilityHidden(true)
    }
    @ViewBuilder private func status(_ item: SleepTimelineItem) -> some View {
        switch item.visualState {
        case .completed: Text("Done").foregroundStyle(RecordingColor.secondary)
        case .active:
            Group {
                if dynamicType.isAccessibilitySize {
                    Text("\(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed")
                        .accessibilityLabel("Sleeping now · \(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed")
                } else { Text("Sleeping now · \(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed") }
            }
            .foregroundStyle(accent).padding(.horizontal, 7).padding(.vertical, 4)
            .background(CoachColor.purple.opacity(0.13), in: Capsule())
        case .next, .future:
            if !dynamicType.isAccessibilitySize, let minutes = presentation.minutesUntil(item, now: now) {
                Text("Estimated · in \(TimeFormat.minutes(minutes))").foregroundStyle(accent)
            } else { Text("Estimated").foregroundStyle(accent) }
        case .unavailable: Text("Not confirmed").foregroundStyle(RecordingColor.secondary)
        }
    }
    private func metadata(_ item: SleepTimelineItem) -> Text {
        var value = Text("Original Sleep Day: \(item.sleepDay.formatted(date: .abbreviated, time: .omitted)).")
        if let time = item.time { value = value + Text(" Start: \(time.formatted(date: .abbreviated, time: .shortened)).") }
        if let duration = item.durationMinutes { value = value + Text(" \(TimeFormat.minutes(duration)) net sleep.") }
        if item.isCarryover { value = value + Text(" Previous Sleep Day context.") }
        if let gap = item.awakeBeforeMinutes, gap > 0 { value = value + Text(" Awake for \(TimeFormat.minutes(gap)) before this event.") }
        if item.source == .estimate { value = value + Text(" Estimated, not an observation.") }
        if item.visualState == .next { value = value + Text(" Next planned event.") }
        if let minutes = presentation.minutesUntil(item, now: now) { value = value + Text(" In \(TimeFormat.minutes(minutes)).") }
        return value
    }
    private func morningWakeNode(_ wake: TodayPlanPresentation.MorningWake) -> some View {
        VStack(spacing: 3) {
            symbol(state: wake.source == .estimated ? .next : .unavailable, icon: "sun.max.fill")
                .anchorPreference(key: PlanNodeAnchors.self, value: .bounds) { [wake.id: $0] }
                .padding(.vertical, 6)
            Group {
                if let time = wake.time { Text(time, format: .dateTime.hour().minute()) }
                else { Text("—") }
            }
            .recordingFont(12, weight: .semibold).foregroundStyle(RecordingColor.secondary).fixedSize()
            Group {
                switch wake.source {
                case .estimated: Text("Estimated wake")
                case .routine: Text("Usual wake")
                case .unavailable: Text("Morning wake")
                }
            }.recordingFont(13, weight: .bold).fixedSize()
            Group {
                switch wake.source {
                case .estimated: Text("Estimated").foregroundStyle(accent)
                case .routine: Text("Routine").foregroundStyle(RecordingColor.secondary)
                case .unavailable: Text("Unavailable").foregroundStyle(RecordingColor.secondary)
                }
            }.recordingFont(11, weight: .semibold).fixedSize()
        }
        .frame(minWidth: minimumNodeWidth).fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(wake.time.map { Text("Unconfirmed planning reference: \($0.formatted(date: .abbreviated, time: .shortened)).") } ?? Text("Morning wake unavailable. No wake has been confirmed."))
        .accessibilityIdentifier("home.plan.wakeReference")
    }
    private func connector(from left: CGRect, to right: CGRect, confirmed: Bool, gap: Int?) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: left.maxX, y: left.midY))
                path.addLine(to: CGPoint(x: right.minX, y: right.midY))
            }
            .stroke(CoachColor.purple.opacity(confirmed ? 0.8 : 0.22),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: confirmed ? [] : [1, 4]))
            if let gap, gap > 0 {
                Text(TimeFormat.minutes(gap)).recordingFont(10, weight: .semibold)
                    .foregroundStyle(RecordingColor.secondary).fixedSize()
                    .position(x: (left.maxX + right.minX) / 2, y: left.midY - 15)
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
        let hour = scenario == "morning-grace" ? 7 :
            (["carryover", "overnight-routine", "overnight-estimate"].contains(scenario) ? 1 : 12)
        let minute = scenario == "morning-grace" ? 30 : (hour == 1 ? 55 : 7)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
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
        if ["completed", "active", "reference", "many"].contains(scenario) {
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
        case "carryover", "overnight-routine", "overnight-estimate", "morning-grace":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            let start = Calendar.current.date(bySettingHour: 18, minute: 45, second: 0, of: yesterday)!
            records = [SleepRecord(id: parentID, date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)]
        default: break
        }
        if ["overnight-routine", "overnight-estimate", "morning-grace"].contains(scenario) {
            defaults.set(7.0, forKey: "typicalWakeHour")
            defaults.set(0.0, forKey: "typicalWakeMinute")
            defaults.set(19.0, forKey: "typicalBedHour")
        }
        SleepRecordPersistence().save(records)
        DailyWakeRecordPersistence().save(wakes)
    }
    static func wakePredictions(records: [SleepRecord]) -> [HeroPrediction] {
        guard scenario == "overnight-estimate", let night = records.first else { return [] }
        return [.init(kind: .morningWake, sleepKind: .nightSleep, start: nil, end: at(7, 15),
            wakeWindow: nil, anchorRecordID: night.id, anchorDate: night.date,
            provenance: .ruleEngine, eligibility: .verified, generatedAt: now,
            validUntil: at(7, 15))]
    }
    static func presentation(records: [SleepRecord], wakes: [DailyWakeRecord], hero: TodaySleepHeroModel,
                             routine: TodaySleepHeroModel.Routine?) -> TodayPlanPresentation {
        let proposals: [SleepTimelineProposal] = scenario == "reference" ? [
            .init(id: "fixture-nap-2", kind: .nap(index: 2), sleepDay: now, time: at(14, 36), source: .estimate),
            .init(id: "fixture-bedtime", kind: .bedtime, sleepDay: now, time: at(18), source: .estimate)
        ] : []
        return TodayPlanPresentation.make(records: records, wakes: wakes, hero: hero, now: now,
            calendar: .current, routine: routine, proposals: proposals,
            eligibility: scenario == "reference" ? .verified : .unavailable)
    }
}
#endif
