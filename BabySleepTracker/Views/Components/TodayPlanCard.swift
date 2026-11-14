import SwiftUI

private struct PlanNodeAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Equal intrinsic column widths keep the two circles balanced at the card's ends.
/// Wider accessibility captions retain their width and use the horizontal fallback.
private struct OvernightPlanLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let column = sizes.map(\.width).max() ?? 0
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: max(proposedWidth, column * 2 + spacing),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        for (index, view) in subviews.enumerated() {
            let x = index == 0 ? bounds.minX + column / 2 : bounds.maxX - column / 2
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .top,
                       proposal: ProposedViewSize(width: column, height: nil))
        }
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
    @ScaledMetric(relativeTo: .body) private var overnightNodeDiameter: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var overnightCaptionSpacing: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var compactOvernightCaptionSpacing: CGFloat = 4
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var items: [SleepTimelineItem] { presentation.items }
    private var accent: Color { RecordingColor.accent }
    private var overnightCaptionPadding: CGFloat {
        dynamicType.isAccessibilitySize ? overnightCaptionSpacing : compactOvernightCaptionSpacing
    }
    private var overnightNight: SleepTimelineItem? {
        presentation.isOvernight ? items.first { $0.kind == .bedtime && $0.isActive } : nil
    }
    private var recordedCount: Int {
        items.filter {
            if case .recorded = $0.source { return $0.isActive || $0.visualState == .completed }
            return false
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if presentation.isOvernight {
                overnightHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { heading; Spacer(minLength: 4); detailsButton }
                    VStack(alignment: .leading, spacing: 4) { heading; detailsButton }
                }
            }
            if items.isEmpty && presentation.morningWake == nil {
                Text("No sleep recorded yet")
                    .recordingFont(12, weight: .medium).foregroundStyle(RecordingColor.secondary)
            } else if let night = overnightNight {
                ViewThatFits(in: .horizontal) {
                    overnightTimeline(night)
                    ScrollView(.horizontal) { overnightTimeline(night).fixedSize(horizontal: true, vertical: true) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.plan.scroll")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    timeline.fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal) { timeline.padding(.vertical, 2) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.plan.scroll")
                }
            }
            if presentation.predictionsUnavailable && items.isEmpty {
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

    private var overnightHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { title.fixedSize(); overnightBadge; Spacer(minLength: 4); overnightCount; detailsButton.fixedSize() }
            HStack(spacing: 8) { title.fixedSize(); overnightBadge; Spacer(minLength: 4); detailsButton.fixedSize() }
            HStack(spacing: 4) {
                compactOvernightTitle; overnightBadge; Spacer(minLength: 0); detailsButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack { title.fixedSize(); Spacer(minLength: 4); detailsButton.fixedSize() }
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        detailsButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { overnightBadge; Spacer(minLength: 4); overnightCount }
                    overnightBadge
                }
            }
        }
    }
    private var overnightBadge: some View {
        Label("Overnight", systemImage: "moon.fill")
            .recordingFont(11, weight: .semibold).foregroundStyle(accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(CoachColor.purple.opacity(0.11), in: Capsule()).fixedSize()
            .accessibilityIdentifier("home.plan.overnightBadge")
    }
    private var compactOvernightTitle: some View {
        Text("Today's Plan").recordingFont(18, weight: .bold, rounded: true).fixedSize()
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("home.plan.title")
    }
    @ViewBuilder private var overnightCount: some View {
        if recordedCount > 0 {
            Text("\(recordedCount) recorded").recordingFont(11, weight: .bold).foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(CoachColor.purple.opacity(0.11), in: Capsule()).fixedSize()
                .accessibilityLabel("\(recordedCount) recorded events")
                .accessibilityIdentifier("home.plan.progress")
        }
    }
    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { title; progress }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { title; progress }
        }
    }
    private var title: some View {
        Text("Today's Plan").recordingFont(20, weight: .bold, rounded: true)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("home.plan.title")
    }
    @ViewBuilder private var progress: some View {
        if presentation.availableEventCount > 0 {
            Group {
                if items.contains(where: { $0.source == .estimate && $0.isFuture }) {
                    Text("Today · \(presentation.completedEventCount) of \(presentation.availableEventCount)")
                        .accessibilityLabel("\(presentation.completedEventCount) completed of \(presentation.availableEventCount) available events")
                } else {
                    Text("\(presentation.availableEventCount) recorded")
                        .accessibilityLabel("\(presentation.availableEventCount) recorded events")
                }
            }
                .recordingFont(11, weight: .bold).foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(CoachColor.purple.opacity(0.11), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityValue(presentation.predictionsUnavailable && !items.isEmpty ? Text("Predictions unavailable") : Text(""))
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
    private func overnightTimeline(_ night: SleepTimelineItem) -> some View {
        OvernightPlanLayout(spacing: connectorGap) {
            node(night, overnight: true)
            if let wake = presentation.morningWake { morningWakeNode(wake) }
            else if let observed = items.first(where: { $0.kind == .wake }) { node(observed, overnight: true) }
        }
        .backgroundPreferenceValue(PlanNodeAnchors.self) { anchors in
            GeometryReader { proxy in
                let wakeID = presentation.morningWake?.id ?? items.first(where: { $0.kind == .wake })?.id
                if let left = anchors[night.id], let wakeID, let right = anchors[wakeID] {
                    let from = proxy[left]
                    let to = proxy[right]
                    connector(from: from, to: to, confirmed: false, gap: nil).accessibilityHidden(true)
                    if let elapsed = night.elapsedMinutes {
                        Text(TimeFormat.minutes(elapsed)).recordingFont(11, weight: .bold)
                            .foregroundStyle(RecordingColor.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(CoachColor.purple.opacity(0.11), in: Capsule()).fixedSize()
                            .accessibilityLabel(presentation.overnightEndUnconfirmed ?
                                "Night sleep, end unconfirmed, \(TimeFormat.minutes(elapsed)) elapsed since recorded start" :
                                "Night sleep, \(TimeFormat.minutes(elapsed)) elapsed since recorded start")
                            .accessibilityIdentifier("home.plan.overnight.elapsed")
                            .position(x: (from.midX + to.midX) / 2, y: from.midY + overnightNodeDiameter / 2)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
    private func node(_ item: SleepTimelineItem, overnight: Bool = false) -> some View {
        VStack(spacing: 3) {
            symbol(state: item.visualState, icon: TodayPlanPresentation.eventSymbol(for: item), overnight: overnight)
                .anchorPreference(key: PlanNodeAnchors.self, value: .bounds) { [item.id: $0] }
                .padding(.vertical, 6)
                .padding(.bottom, overnight ? overnightCaptionPadding : 0)
            eventTime(item).recordingFont(12, weight: .semibold)
                .foregroundStyle(RecordingColor.secondary).monospacedDigit().fixedSize()
            Group {
                if overnight && item.kind == .wake { Text("Morning wake") }
                else { eventTitle(item) }
            }.recordingFont(13, weight: .bold).fixedSize()
            if overnight && item.isActive {
                overnightPill(presentation.overnightEndUnconfirmed ? "End unconfirmed" : "Ongoing", emphasized: true)
            } else { status(item).recordingFont(11, weight: .semibold).fixedSize() }
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
        if !dynamicType.isAccessibilitySize, presentation.isOvernight, item.kind == .bedtime,
           calendar.isDate(time, inSameDayAs: now) { return Text("Today · \(short)") }
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
    private func symbol(state: SleepTimelineItem.VisualState, icon: String, overnight: Bool = false, muted: Bool = false) -> some View {
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
            Image(systemName: icon)
                .recordingFont(overnight ? 22 : 17, weight: .semibold)
                .foregroundStyle(active ? Color.white : (completed || muted ? CoachColor.muted : accent))
        }
        .frame(width: overnight ? overnightNodeDiameter : nodeDiameter,
               height: overnight ? overnightNodeDiameter : nodeDiameter).accessibilityHidden(true)
    }
    @ViewBuilder private func status(_ item: SleepTimelineItem) -> some View {
        switch item.visualState {
        case .completed: Text("Done").foregroundStyle(RecordingColor.secondary)
        case .active:
            Group {
                if presentation.isOvernight || dynamicType.isAccessibilitySize {
                    Text("\(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed")
                } else { Text("Sleeping now · \(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed") }
            }
            .accessibilityLabel("Sleeping now · \(TimeFormat.minutes(item.elapsedMinutes ?? 0)) elapsed")
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
            symbol(state: .unavailable, icon: "sunrise.fill", overnight: true, muted: true)
                .anchorPreference(key: PlanNodeAnchors.self, value: .bounds) { [wake.id: $0] }
                .padding(.vertical, 6)
                .padding(.bottom, overnightCaptionPadding)
            Group {
                if let time = wake.time {
                    if wake.source == .routine {
                        Text("Usual · ") + Text(time, format: .dateTime.hour().minute())
                    } else { Text(time, format: .dateTime.hour().minute()) }
                }
                else { Text("—") }
            }
            .recordingFont(12, weight: .semibold).foregroundStyle(RecordingColor.secondary).fixedSize()
            Text("Morning wake").recordingFont(13, weight: .bold).fixedSize()
            Group {
                switch wake.source {
                case .estimated: overnightPill("Estimated")
                case .routine: overnightPill("Routine")
                case .unavailable: overnightPill("Awaiting wake")
                }
            }
        }
        .frame(minWidth: minimumNodeWidth).fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(wake.time.map { Text("Unconfirmed planning reference: \($0.formatted(date: .abbreviated, time: .shortened)).") } ?? Text("No routine or eligible prediction is available. No wake has been confirmed."))
        .accessibilityIdentifier("home.plan.wakeReference")
    }
    private func overnightPill(_ label: LocalizedStringKey, emphasized: Bool = false) -> some View {
        Text(label).recordingFont(11, weight: .semibold)
            .foregroundStyle(emphasized ? accent : RecordingColor.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(CoachColor.purple.opacity(emphasized ? 0.13 : 0.08), in: Capsule()).fixedSize()
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
        if scenario == "night-before-midnight" {
            return Calendar.current.date(bySettingHour: 20, minute: 31, second: 0, of: eveningSessionStart)!
        }
        if scenario == "night-after-midnight" {
            let morning = Calendar.current.date(byAdding: .day, value: 1, to: eveningSessionStart)!
            return Calendar.current.date(bySettingHour: 1, minute: 55, second: 0, of: morning)!
        }
        let hour = scenario == "morning-grace" ? 7 :
            (["carryover", "overnight-routine", "overnight-estimate"].contains(scenario) ? 1 : 12)
        let minute = scenario == "morning-grace" ? 30 : (hour == 1 ? 55 : 7)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }
    static let parentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let historicalNapID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let completedNightID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let wakeID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    /// Both screenshots use the same persisted ID/start, with clocks on either side of midnight.
    private static var eveningSessionStart: Date {
        Calendar.current.date(bySettingHour: 19, minute: 5, second: 0, of: Date())!
    }
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
        if ["completed", "completed-event-icons", "active", "reference", "many"].contains(scenario) {
            wakes = [DailyWakeRecord(id: wakeID, day: Calendar.current.startOfDay(for: now), wakeTime: at(7, 15))]
        }
        switch scenario {
        case "completed", "completed-event-icons":
            let nap = SleepRecord(id: parentID, date: at(9), duration: 60, createdAt: at(9))
            records = [nap, SleepRecord(date: at(9, 15), duration: 10, kind: .break, parentNapID: parentID)]
            if scenario == "completed-event-icons" {
                records.append(SleepRecord(id: completedNightID, date: at(2), duration: 315,
                    kind: .nightSleep, createdAt: at(2), endDate: at(7, 15)))
            }
        case "active", "reference":
            records = [SleepRecord(id: parentID, date: at(11, 41), duration: 0, isOngoing: true, createdAt: at(11, 41))]
        case "many":
            wakes = [DailyWakeRecord(day: Calendar.current.startOfDay(for: now), wakeTime: at(4))]
            records = (1...5).map { SleepRecord(date: at(4 + $0), duration: 20, createdAt: at(4 + $0)) }
        case "carryover", "overnight-routine", "overnight-estimate", "morning-grace":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            let start = Calendar.current.date(bySettingHour: 18, minute: 45, second: 0, of: yesterday)!
            records = [SleepRecord(id: parentID, date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)]
        case "night-before-midnight", "night-after-midnight":
            let base = eveningSessionStart
            let wake = Calendar.current.date(bySettingHour: 7, minute: 15, second: 0, of: base)!
            let nap = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base)!
            wakes = [DailyWakeRecord(id: wakeID, day: Calendar.current.startOfDay(for: base), wakeTime: wake)]
            records = [SleepRecord(id: historicalNapID, date: nap, duration: 60, createdAt: nap),
                       SleepRecord(id: parentID, date: base, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: base)]
        default: break
        }
        if ["overnight-routine", "overnight-estimate", "morning-grace", "night-before-midnight", "night-after-midnight"].contains(scenario) {
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
