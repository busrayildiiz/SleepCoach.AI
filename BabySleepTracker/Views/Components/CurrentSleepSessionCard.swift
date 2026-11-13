import SwiftUI

/// Presentation only. Production deliberately supplies no estimate until the
/// approved seven-valid-recording-day eligibility policy is implemented.
struct HomeSleepCardPresentation {
    enum Status { case missing, confirmed, estimated, completed }
    struct Estimate {
        let kind: SleepKind
        let start: Date
        let wake: Date
    }
    let status: Status
    let kind: SleepKind?
    let napNumber: Int?
    let start: Date?
    let elapsedMinutes: Int?
    let expectedWake: Date?
    let progress: Double?

    static func make(records: [SleepRecord], now: Date, calendar: Calendar,
                     estimate: Estimate? = nil, eligibilityVerified: Bool = false) -> Self {
        let active = records.filter { $0.kind != .break && $0.isOngoing && $0.date <= now }
            .max { $0.date < $1.date }
        if let active {
            return session(record: active, records: records, now: now, calendar: calendar)
        }
        if eligibilityVerified, let estimate, estimate.kind != .break,
           estimate.start <= now, estimate.wake > now, estimate.wake > estimate.start {
            let elapsed = max(0, Int(now.timeIntervalSince(estimate.start) / 60))
            return Self(status: .estimated, kind: estimate.kind,
                        napNumber: estimate.kind == .dayNap ? napSequence(records: records, start: estimate.start, id: nil, now: now, calendar: calendar) : nil,
                        start: estimate.start, elapsedMinutes: elapsed, expectedWake: estimate.wake,
                        progress: min(1, max(0, now.timeIntervalSince(estimate.start) / estimate.wake.timeIntervalSince(estimate.start))))
        }
        return Self(status: .missing, kind: nil, napNumber: nil, start: nil,
                    elapsedMinutes: nil, expectedWake: nil, progress: nil)
    }

    static func session(record: SleepRecord, records: [SleepRecord], now: Date, calendar: Calendar) -> Self {
        guard record.kind != .break, record.date <= now,
              record.isOngoing || record.observedEnd != nil else {
            return make(records: [], now: now, calendar: calendar)
        }
        let end = record.isOngoing ? now : min(record.observedEnd ?? now, now)
        return Self(status: record.isOngoing ? .confirmed : .completed, kind: record.kind,
                    napNumber: record.kind == .dayNap ? napSequence(records: records, start: record.date, id: record.id, now: now, calendar: calendar) : nil,
                    start: record.date, elapsedMinutes: max(0, Int(end.timeIntervalSince(record.date) / 60)),
                    expectedWake: nil, progress: nil)
    }

    private static func napSequence(records: [SleepRecord], start: Date, id: UUID?, now: Date, calendar: Calendar) -> Int {
        let day = SleepAccounting(records: records, now: now, calendar: calendar).records(on: start)
        let preceding = day.filter {
            $0.kind == .dayNap && $0.id != id && $0.date < start && $0.date <= now &&
            ($0.isOngoing || $0.observedEnd != nil)
        }
        return Set(preceding.map(\.id)).count + 1
    }

    var classification: String {
        guard let kind else { return "SLEEP RECORDING" }
        if kind == .nightSleep { return "NIGHT SLEEP" }
        switch napNumber {
        case 1: return "FIRST NAP"
        case 2: return "SECOND NAP"
        case 3: return "THIRD NAP"
        default: return "NAP \(napNumber ?? 1)"
        }
    }
    var section: String {
        switch status {
        case .missing: return classification
        case .estimated: return "LIKELY " + classification
        case .confirmed: return "LIVE " + classification
        case .completed: return "COMPLETED " + classification
        }
    }
    var title: String {
        switch status {
        case .missing: return "Ready to record"
        case .estimated: return "Likely sleeping"
        case .confirmed: return kind == .nightSleep ? "Sleeping tonight" : "Sleeping now"
        case .completed: return "Sleep recorded"
        }
    }
    var duration: String { elapsedMinutes.map(TimeFormat.minutes) ?? "—" }
    var durationLabel: String { status == .estimated ? "estimated" : "elapsed" }
    func time(_ date: Date, relativeTo now: Date, calendar: Calendar) -> String {
        date.formatted(date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }
    func detail(now: Date, calendar: Calendar) -> String {
        guard let start else { return "Record sleep to follow your baby's day." }
        return "\(status == .estimated ? "Expected start" : "Started") \(time(start, relativeTo: now, calendar: calendar)) · \(duration) \(durationLabel)"
    }
    func accessibility(now: Date, calendar: Calendar) -> String {
        "\(section). \(title). \(detail(now: now, calendar: calendar)) Expected wake: \(expectedWake.map { time($0, relativeTo: now, calendar: calendar) } ?? "not estimated")."
    }
}

struct HomeWakeCardState {
    private(set) var records: [DailyWakeRecord]
    func isVisible(now: Date, calendar: Calendar) -> Bool {
        !records.contains { calendar.isDate($0.day, inSameDayAs: now) }
    }
    mutating func accept(_ result: SleepWakeTimeWorkflowResult) {
        if result.wakePersistenceSucceeded { records = result.updatedWakeRecords }
    }
}

private enum HomeCardColor {
    // Exact AI Coach accents; adaptive system surfaces/ink preserve dark mode.
    static let purple = Color(red: 0.55, green: 0.45, blue: 0.96)
    static let deep = Color(red: 0.45, green: 0.35, blue: 0.92)
    static let sun = Color(red: 1.0, green: 0.68, blue: 0.12)
}

private struct HomeCardSurface: ViewModifier {
    var warm = false
    func body(content: Content) -> some View {
        let accent = warm ? HomeCardColor.sun : HomeCardColor.purple
        content
            .background(Color(.secondarySystemGroupedBackground))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(accent.opacity(0.14), lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: HomeCardColor.deep.opacity(0.07), radius: 9, x: 0, y: 4)
    }
}

struct CurrentSleepSessionCard<Artwork: View>: View {
    let presentation: HomeSleepCardPresentation
    let now: Date
    var onAddBreak: (() -> Void)? = nil
    @ViewBuilder let artwork: () -> Artwork
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var ringSize = 80.0

    var body: some View {
        VStack(spacing: 12) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) { summary; if presentation.start != nil { ring } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    if presentation.start != nil { ring }
                }
            }
            if presentation.start != nil {
                Divider().overlay(HomeCardColor.purple.opacity(0.12))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Expected wake", systemImage: "sunrise.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer(minLength: 0)
                    Text(presentation.expectedWake.map { presentation.time($0, relativeTo: now, calendar: .current) } ?? "Not estimated")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.trailing)
                }
            }
            if let onAddBreak, presentation.status == .confirmed {
                Button(action: onAddBreak) {
                    Label("Add Awake Break", systemImage: "plus").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(HomeCardColor.deep)
                .accessibilityIdentifier("sleep.current.addBreak")
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [HomeCardColor.purple.opacity(0.025), HomeCardColor.purple.opacity(0.065)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .modifier(HomeCardSurface())
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(HomeCardColor.purple).frame(width: 6, height: 6)
                Text(presentation.section).font(.system(.caption2, design: .rounded, weight: .bold)).tracking(0.7)
            }.foregroundStyle(HomeCardColor.deep)
            HStack(spacing: 10) {
                artwork().frame(width: 40, height: 40).accessibilityHidden(true)
                Text(presentation.title).font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color(.label)).fixedSize(horizontal: false, vertical: true)
            }
            Label(presentation.detail(now: now, calendar: .current), systemImage: "clock")
                .font(.caption).foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibility(now: now, calendar: .current))
        .accessibilityIdentifier("home.sleep.summary")
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(HomeCardColor.purple.opacity(0.17), lineWidth: 6)
            if let progress = presentation.progress {
                Circle().trim(from: 0, to: progress)
                    .stroke(HomeCardColor.purple, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(HomeCardColor.purple)
                Text(presentation.duration).font(.system(.subheadline, design: .rounded, weight: .bold)).monospacedDigit()
                Text(presentation.durationLabel).font(.caption2).foregroundStyle(Color(.secondaryLabel))
            }.padding(5)
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityLabel("\(presentation.duration) \(presentation.durationLabel)")
    }
}

struct HomeWakeTimeCard: View {
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { content; addLabel }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                HStack(spacing: 12) { content; Spacer(minLength: 0); addLabel }.padding(14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Wake Time. Record when your baby wakes up.")
        .accessibilityHint("Opens today's wake-time editor")
        .accessibilityIdentifier("home.wake.add")
        .background(LinearGradient(colors: [HomeCardColor.sun.opacity(0.025), HomeCardColor.sun.opacity(0.11)], startPoint: .top, endPoint: .bottom))
        .modifier(HomeCardSurface(warm: true))
    }
    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "sunrise.fill").font(.system(size: 30)).foregroundStyle(HomeCardColor.sun).accessibilityHidden(true)
            Rectangle().fill(HomeCardColor.sun.opacity(0.3)).frame(width: 1, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Wake Time").font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Color(.label))
                Text("Record when your baby wakes up.").font(.caption).foregroundStyle(Color(.secondaryLabel))
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private var addLabel: some View {
        Label("Add", systemImage: "plus").font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(HomeCardColor.sun).padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().stroke(HomeCardColor.sun.opacity(0.2), lineWidth: 1))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Explicit UI-test opt-in only; never a production eligibility bypass.
enum HomeCardTestFixture {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HOME_CARD_UI_TESTS"] == "1" }
    static var scenario: String { ProcessInfo.processInfo.environment["HOME_CARD_SCENARIO"] ?? "missing" }
    static var now: Date {
        if scenario == "confirmed" { return Date() }
        return Calendar.current.date(bySettingHour: 21, minute: 49, second: 0, of: Date())!
    }
    static func presentation(records: [SleepRecord]) -> HomeSleepCardPresentation {
        let kind: SleepKind = scenario == "night" ? .nightSleep : .dayNap
        let start = now.addingTimeInterval(scenario == "night" ? -8340 : -2700)
        let wake = start.addingTimeInterval(scenario == "night" ? 41400 : 5400)
        return HomeSleepCardPresentation.make(records: records, now: now, calendar: .current,
            estimate: .init(kind: kind, start: start, wake: wake),
            eligibilityVerified: scenario == "first-nap" || scenario == "night")
    }
    static func prepare() {
        let defaults = UserDefaults.standard
        guard ProcessInfo.processInfo.environment["HOME_CARD_RESET"] == "1" else { return }
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        defaults.set("light", forKey: "appAppearance")
        defaults.set(true, forKey: "authComplete")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(23.0, forKey: "typicalBedHour")
        defaults.set(0.0, forKey: "typicalWakeHour")
        let records: [SleepRecord] = scenario == "confirmed" ? [
            SleepRecord(date: now.addingTimeInterval(-3600), duration: 0, kind: .nightSleep, isOngoing: true)
        ] : []
        SleepRecordPersistence().save(records)
        defaults.removeObject(forKey: "dailyWakeRecords_v1")
    }
}
#endif
