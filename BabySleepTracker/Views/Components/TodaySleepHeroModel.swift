import Foundation

/// Hero-specific projection. Does not duplicate or merge PR #20's timeline model.
/// No prediction engine or LLM is invoked here; callers must supply verified outputs.
struct HeroPrediction: Equatable {
    enum Kind: Equatable { case nextSleep, napEnd, morningWake, wakeWindow }
    enum Provenance: Equatable { case ruleEngine, ageGuidance, llm }
    enum Eligibility: Equatable { case unavailable, verified }
    enum Unavailability: Equatable { case eligibilityUnverified, invalidSource, stale, invalidTime, wrongAnchor }
    let kind: Kind
    let sleepKind: SleepKind
    let start: Date?
    let end: Date?
    let wakeWindow: ClosedRange<Int>?
    let anchorRecordID: UUID?
    let anchorDate: Date?
    let provenance: Provenance
    let eligibility: Eligibility
    let generatedAt: Date
    let validUntil: Date
    var confidence: Double? = nil

    func unavailableReason(now: Date, record: SleepRecord?, wake: Date?) -> Unavailability? {
        guard eligibility == .verified else { return .eligibilityUnverified }
        guard provenance == .ruleEngine else { return .invalidSource }
        guard generatedAt <= now, validUntil > now else { return .stale }
        if let record {
            guard anchorRecordID == record.id else { return .wrongAnchor }
            if !record.isOngoing, anchorDate != record.observedEnd { return .wrongAnchor }
        } else if let wake {
            guard anchorRecordID == nil, anchorDate == wake else { return .wrongAnchor }
        } else if anchorRecordID != nil || anchorDate != nil { return .wrongAnchor }
        switch kind {
        case .nextSleep:
            guard let start, start > now,
                  end.map({ $0 > start }) ?? true else { return .invalidTime }
        case .napEnd, .morningWake:
            let requiredKind: SleepKind = kind == .napEnd ? .dayNap : .nightSleep
            guard let end, end > now, record?.isOngoing == true,
                  record?.kind == requiredKind, sleepKind == requiredKind else { return .invalidTime }
        case .wakeWindow:
            guard let wakeWindow, wakeWindow.lowerBound > 0, wake != nil || record?.observedEnd != nil else { return .invalidTime }
        }
        return nil
    }
}

struct TodaySleepHeroModel {
    enum Mode: String, CaseIterable {
        case ready, napActive, napCompleted, nightActive, morningConfirmed, morningUnconfirmed, likelyNext, bedtimeRoutine
    }
    typealias Routine = SleepRoutine
    let mode: Mode
    let assessment: SleepStateAssessment
    var reviewRecord: SleepRecord? { assessment.reviewRecord }
    var confirmedAt: Date? { assessment.active?.confirmation }
    /// Remains an original persisted observation, even when the mode is morningUnconfirmed.
    let record: SleepRecord?
    let sleepDay: Date?
    let wakeTime: Date?
    let routineWake: Date?
    let now: Date
    let napNumber: Int?
    let netMinutes: Int?
    let elapsedMinutes: Int?
    let predictions: [HeroPrediction]
    let displayName: String
    let babyName: String
    let predictionUnavailableReason: HeroPrediction.Unavailability?
    /// Local routine reference only, never an observed or predicted sleep start.
    let routineBedtime: Date?
    var isNightOpen: Bool { record?.kind == .nightSleep && record?.isOngoing == true }
    var canAddBreak: Bool { mode == .napActive && record != nil }
    var title: String {
        switch mode {
        case .ready: return String(localized: "Ready to record")
        case .napActive: return String(localized: "Sleeping now")
        case .napCompleted: return String(localized: "Nap completed")
        case .nightActive: return String(localized: "Night sleep in progress")
        case .morningConfirmed, .morningUnconfirmed: return String(localized: "Good morning, \(displayName)!")
        case .likelyNext: return String(localized: "Likely next sleep")
        case .bedtimeRoutine: return String(localized: "Bedtime routine")
        }
    }
    func prediction(_ kind: HeroPrediction.Kind) -> HeroPrediction? { predictions.first { $0.kind == kind } }

    static func make(records: [SleepRecord], wakeRecords: [DailyWakeRecord], now: Date,
                     calendar: Calendar, routine: Routine?, displayName: String, babyName: String,
                     proposals: [HeroPrediction] = [], confirmation: StillSleepingConfirmation? = nil,
                     instant: ContinuousClock.Instant? = nil) -> Self {
        let evaluation = SleepEvaluation(now: now, calendar: calendar, routine: routine,
                                         confirmation: confirmation, instant: instant)
        let assessment = SleepStateCalculator.assess(records: records, wakes: wakeRecords, evaluation: evaluation)
        let bedtime = routine?.bedtimeWindow(at: now, calendar: calendar)
        let nightAlreadyRecorded = bedtime.map { window in
            records.contains { record in
                guard record.kind == .nightSleep, let end = record.completedEnd(at: now) else { return false }
                return record.date >= window.start || end >= window.bedtime
            }
        } ?? false
        let showsBedtime = bedtime.map { window in
            assessment.active == nil && !assessment.morningReminder && !nightAlreadyRecorded &&
                assessment.latestWake.map { $0 >= window.bedtime } != true
        } ?? false
        let mode: Mode
        let context: SleepRecord?
        let observedWake: Date?
        if let active = assessment.active {
            context = active.record
            mode = active.record.kind == .dayNap ? .napActive : .nightActive
            observedWake = nil
        } else if showsBedtime {
            context = nil
            mode = .bedtimeRoutine
            observedWake = nil
        } else if case .napEnd(let nap, _) = assessment.anchor {
            context = nap
            mode = .napCompleted
            observedWake = assessment.latestWake
        } else if case .wake(let wake) = assessment.anchor {
            context = nil
            mode = .morningConfirmed
            observedWake = wake
        } else if assessment.morningReminder {
            context = assessment.reminderNight
            mode = .morningUnconfirmed
            observedWake = nil
        } else {
            context = nil
            observedWake = nil
            mode = assessment.reviewRecord == nil && assessment.unavailableReason != .conflict &&
                proposals.contains { $0.kind == .nextSleep && $0.unavailableReason(now: now, record: nil, wake: nil) == nil }
                ? .likelyNext : .ready
        }
        let valid = proposals.filter { mode != .bedtimeRoutine && (context?.isOngoing != true || assessment.active != nil) && $0.unavailableReason(now: now, record: context, wake: observedWake) == nil }
            .sorted { $0.generatedAt > $1.generatedAt }
        let napNumber = context.flatMap { record -> Int? in
            guard record.kind == .dayNap else { return nil }
            // Reuse the existing Home presentation's validated start-day nap sequencing.
            return HomeSleepCardPresentation.session(record: record, records: records, now: now, calendar: calendar).napNumber
        }
        return Self(mode: mode, assessment: assessment, record: context,
            sleepDay: context.map { calendar.startOfDay(for: $0.date) }, wakeTime: observedWake,
            routineWake: (assessment.reminderNight ?? assessment.active?.record).flatMap {
                $0.kind == .nightSleep ? routine?.wake(after: $0.date, calendar: calendar) : nil
            } ?? routine?.wake(on: now, calendar: calendar), now: now, napNumber: napNumber,
            netMinutes: context.flatMap {
                $0.isOngoing ? nil : SleepAccounting(records: records, now: now, calendar: calendar).completedMinutes(sleepIDs: [$0.id])
            },
            elapsedMinutes: assessment.active?.elapsed,
            predictions: valid,
            displayName: displayName.isEmpty ? String(localized: "there") : displayName,
            babyName: babyName.isEmpty ? String(localized: "Baby") : babyName,
            predictionUnavailableReason: valid.isEmpty ? (proposals.first.flatMap {
                $0.unavailableReason(now: now, record: context, wake: observedWake)
            } ?? .eligibilityUnverified) : nil,
            routineBedtime: bedtime?.bedtime)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Explicitly labeled, offline simulator fixtures; not production eligibility.
enum HeroUITestFixture {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SLEEP_HERO_UI_TESTS"] == "1" }
    static var scenario: String { ProcessInfo.processInfo.environment["SLEEP_HERO_SCENARIO"] ?? "ready" }
    static var now: Date {
        if ProcessInfo.processInfo.environment["SLEEP_HERO_LIVE_CLOCK"] == "1" { return Date() }
        if scenario.hasPrefix("bedtime") {
            return Calendar.current.date(bySettingHour: scenario == "bedtimeBefore" ? 18 : 20,
                                         minute: scenario == "bedtimeBefore" ? 59 : 33, second: 0, of: Date())!
        }
        let hour = scenario.hasPrefix("morning") ? 8 : (scenario == "nightActive" ? 3 : 12)
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }
    static let parentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static func prepare() {
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        defaults.set(ProcessInfo.processInfo.environment["SLEEP_HERO_DARK"] == "1" ? "dark" : "light", forKey: "appAppearance")
        defaults.set(true, forKey: "authComplete")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set("Alex", forKey: "parentName")
        defaults.set("Baby", forKey: "babyName")
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let usesLiveNight = scenario == "nightActive" && ProcessInfo.processInfo.environment["SLEEP_HERO_LIVE_CLOCK"] == "1"
        let nightStart = usesLiveNight ? now.addingTimeInterval(-7200) :
            cal.date(bySettingHour: 20, minute: 12, second: 0, of: yesterday)!
        var records: [SleepRecord] = []
        var wakes: [DailyWakeRecord] = []
        switch scenario {
        case "napActive":
            records = [SleepRecord(id: parentID, date: now.addingTimeInterval(-4320), duration: 0, isOngoing: true, createdAt: now.addingTimeInterval(-4320))]
        case "bedtimeBefore", "bedtimeRoutine":
            records = [SleepRecord(id: parentID, date: now.addingTimeInterval(-3 * 3600), duration: 60,
                                   createdAt: now.addingTimeInterval(-3 * 3600))]
        case "napCompleted":
            records = [SleepRecord(id: parentID, date: now.addingTimeInterval(-7200), duration: 96,
                                   createdAt: now.addingTimeInterval(-7200)),
                       SleepRecord(date: now.addingTimeInterval(-6600), duration: 10, kind: .break, parentNapID: parentID)]
        case "staleNight":
            let start = now.addingTimeInterval(-121 * 3600)
            records = [SleepRecord(id: parentID, date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)]
        case "nightActive", "morningUnconfirmed":
            records = [SleepRecord(id: parentID, date: nightStart, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: nightStart)]
        case "morningConfirmed":
            let wake = cal.date(bySettingHour: 7, minute: 15, second: 0, of: now)!
            records = [SleepRecord(id: parentID, date: nightStart, duration: Int(wake.timeIntervalSince(nightStart) / 60), kind: .nightSleep, createdAt: nightStart, endDate: wake)]
            wakes = [DailyWakeRecord(day: cal.startOfDay(for: now), wakeTime: wake)]
        default: break
        }
        SleepRecordPersistence().save(records)
        DailyWakeRecordPersistence().save(wakes)
    }
    static func model(records: [SleepRecord], wakes: [DailyWakeRecord],
                      confirmation: StillSleepingConfirmation? = nil) -> TodaySleepHeroModel {
        let now = self.now
        var routine: TodaySleepHeroModel.Routine? = scenario.hasPrefix("morning") || scenario.hasPrefix("bedtime") ? .init(wakeHour: 7, bedHour: 19) : nil
        if scenario.hasPrefix("bedtime"), ProcessInfo.processInfo.environment["SLEEP_HERO_LIVE_CLOCK"] == "1" {
            // Navigation/save tests use actual recording time; keep the offline routine
            // around that clock so saved records cannot become future fixture observations.
            let cal = Calendar.current
            let bed = cal.date(byAdding: .hour, value: -2, to: now)!
            let wake = cal.date(byAdding: .hour, value: 8, to: now)!
            routine = .init(wakeHour: cal.component(.hour, from: wake), wakeMinute: cal.component(.minute, from: wake),
                            bedHour: cal.component(.hour, from: bed), bedMinute: cal.component(.minute, from: bed))
        }
        var proposals: [HeroPrediction] = []
        let parent = records.first { $0.id == parentID }
        if scenario == "napActive" {
            proposals.append(prediction(kind: .napEnd, now: now, start: nil, end: now.addingTimeInterval(1980), record: parent))
        } else if scenario == "nightActive" {
            proposals.append(prediction(kind: .morningWake, now: now, start: nil, end: now.addingTimeInterval(4 * 3600), record: parent, sleepKind: .nightSleep))
        } else if scenario == "napCompleted", let parent, let end = parent.observedEnd {
            proposals.append(HeroPrediction(kind: .wakeWindow, sleepKind: .dayNap, start: nil, end: nil,
                wakeWindow: 135...135, anchorRecordID: parent.id, anchorDate: end, provenance: .ruleEngine,
                eligibility: .verified, generatedAt: now, validUntil: now.addingTimeInterval(8 * 3600)))
            let start = end.addingTimeInterval(135 * 60)
            proposals.append(prediction(kind: .nextSleep, now: now, start: start, end: nil, record: parent))
        } else if scenario == "morningConfirmed", let wake = wakes.first?.wakeTime {
            proposals.append(HeroPrediction(kind: .wakeWindow, sleepKind: .dayNap, start: nil, end: nil,
                wakeWindow: 195...195, anchorRecordID: nil, anchorDate: wake, provenance: .ruleEngine,
                eligibility: .verified, generatedAt: now, validUntil: now.addingTimeInterval(8 * 3600)))
            proposals.append(HeroPrediction(kind: .nextSleep, sleepKind: .dayNap,
                start: wake.addingTimeInterval(195 * 60), end: nil, wakeWindow: nil, anchorRecordID: nil,
                anchorDate: wake, provenance: .ruleEngine, eligibility: .verified,
                generatedAt: now, validUntil: now.addingTimeInterval(8 * 3600)))
        } else if scenario == "likelyNext" {
            let start = now.addingTimeInterval(1680)
            proposals.append(prediction(kind: .nextSleep, now: now, start: start, end: start.addingTimeInterval(4500)))
        }
        return TodaySleepHeroModel.make(records: records, wakeRecords: wakes, now: now, calendar: .current,
            routine: routine, displayName: "Alex", babyName: "Baby", proposals: proposals,
            confirmation: confirmation, instant: ContinuousClock.now)
    }
    static func prediction(kind: HeroPrediction.Kind, now: Date, start: Date?, end: Date?,
                           record: SleepRecord? = nil, sleepKind: SleepKind = .dayNap) -> HeroPrediction {
        .init(kind: kind, sleepKind: sleepKind, start: start, end: end, wakeWindow: nil,
              anchorRecordID: record?.id, anchorDate: record?.observedEnd, provenance: .ruleEngine,
              eligibility: .verified, generatedAt: now, validUntil: now.addingTimeInterval(8 * 3600))
    }
    static func legacyModel(records: [SleepRecord], wakes: [DailyWakeRecord]) -> TodaySleepHeroModel {
        let now = HomeCardTestFixture.now
        let predicts = HomeCardTestFixture.scenario == "first-nap" || HomeCardTestFixture.scenario == "night"
        let start = now.addingTimeInterval(1680)
        let proposals = predicts ? [prediction(kind: .nextSleep, now: now, start: start,
            end: start.addingTimeInterval(4500), sleepKind: HomeCardTestFixture.scenario == "night" ? .nightSleep : .dayNap)] : []
        return TodaySleepHeroModel.make(records: records, wakeRecords: wakes, now: now, calendar: .current,
            routine: nil, displayName: "Alex", babyName: "Baby", proposals: proposals)
    }
}
#endif
