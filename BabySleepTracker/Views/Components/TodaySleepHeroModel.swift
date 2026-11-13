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
    struct Routine {
        let wakeHour: Int?
        var wakeMinute: Int = 0
        var bedHour: Int? = nil
        var bedMinute: Int = 0
        var graceMinutes: Int = 30

        static func load(defaults: UserDefaults) -> Self? {
            func component(_ key: String, maximum: Double) -> Int? {
                guard let value = defaults.object(forKey: key) as? Double,
                      value.isFinite, value >= 0, value <= maximum, value.rounded() == value else { return nil }
                return Int(value)
            }
            let hour = component("typicalWakeHour", maximum: 23)
            let minute = defaults.object(forKey: "typicalWakeMinute") == nil ? 0 : component("typicalWakeMinute", maximum: 59)
            let bedHour = component("typicalBedHour", maximum: 23)
            let bedMinute = defaults.object(forKey: "typicalBedMinute") == nil ? 0 : component("typicalBedMinute", maximum: 59)
            // Either explicitly configured routine can stand alone; never invent a wake time.
            let validWake = minute == nil ? nil : hour
            let validBed = bedMinute == nil ? nil : bedHour
            guard validWake != nil || validBed != nil else { return nil }
            return Self(wakeHour: validWake, wakeMinute: minute ?? 0,
                        bedHour: validBed, bedMinute: bedMinute ?? 0)
        }
    }
    struct StillSleepingConfirmation {
        let recordID: UUID
        let date: Date
    }
    let mode: Mode
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

    /// Precedence: explicit later wake / still-sleeping observation; confirmed active
    /// (overnight may present a morning prompt); eligible bedtime routine; latest same-day nap completion;
    /// confirmed morning wake; routine transition; eligible next estimate; neutral.
    static func make(records: [SleepRecord], wakeRecords: [DailyWakeRecord], now: Date,
                     calendar: Calendar, routine: Routine?, displayName: String, babyName: String,
                     proposals: [HeroPrediction] = [], confirmation: StillSleepingConfirmation? = nil) -> Self {
        let day = calendar.startOfDay(for: now)
        let ordered = records.filter { $0.kind != .break && $0.date <= now }.sorted {
            $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date
        }
        let active = ordered.first { $0.isOngoing }
        let naps = ordered.filter { record in
            record.kind == .dayNap && !record.isOngoing && record.observedEnd.map { end in
                end <= now && (calendar.isDate(end, inSameDayAs: day) || calendar.isDate(record.date, inSameDayAs: day))
            } == true
        }
        let latestNap = naps.max { ($0.observedEnd ?? $0.date) < ($1.observedEnd ?? $1.date) }
        let wake = wakeRecords.filter { calendar.isDate($0.day, inSameDayAs: day) &&
            calendar.isDate($0.wakeTime, inSameDayAs: day) && $0.wakeTime <= now }.map(\.wakeTime).max()
        let nightEnd = ordered.filter { $0.kind == .nightSleep && !$0.isOngoing }
            .compactMap(\.observedEnd).filter { $0 <= now && calendar.isDate($0, inSameDayAs: day) }.max()
        let observedWake = [wake, nightEnd].compactMap { $0 }.max()
        func routineCycle(on base: Date) -> (wake: Date, transition: Date, end: Date)? {
            guard let routine, let wakeHour = routine.wakeHour, (0...23).contains(wakeHour), (0...59).contains(routine.wakeMinute),
                  (0..<1440).contains(routine.graceMinutes),
                  let wake = calendar.date(bySettingHour: wakeHour, minute: routine.wakeMinute, second: 0, of: base),
                  let transition = calendar.date(byAdding: .minute, value: routine.graceMinutes, to: wake) else { return nil }
            var end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: base))!
            if let bedHour = routine.bedHour, (0...23).contains(bedHour), (0...59).contains(routine.bedMinute) {
                end = calendar.date(bySettingHour: bedHour, minute: routine.bedMinute, second: 0, of: base)!
            }
            if end <= transition { end = calendar.date(byAdding: .day, value: 1, to: end)! }
            return (wake, transition, end)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        let cycles = [day, yesterday].compactMap { routineCycle(on: $0) }
        let cycle = cycles.first { now >= $0.transition && now < $0.end } ?? cycles.first
        let usual = cycle?.wake
        let transition = cycle?.transition
        let morning = cycle.map { now >= $0.transition && now < $0.end } ?? false
        // The most recent local bedtime belongs to one overnight window. Its morning
        // boundary is the next configured wake + grace, not a rolling 24-hour comparison.
        func bedtimeWindow() -> (bedtime: Date, start: Date)? {
            guard let routine, let hour = routine.bedHour, (0...23).contains(hour),
                  (0...59).contains(routine.bedMinute),
                  let todayBed = calendar.date(bySettingHour: hour, minute: routine.bedMinute, second: 0, of: day),
                  let bedtime = todayBed <= now ? todayBed : calendar.date(bySettingHour: hour, minute: routine.bedMinute, second: 0, of: yesterday)
            else { return nil }
            let bedDay = calendar.startOfDay(for: bedtime)
            var start = bedDay
            var end = calendar.date(byAdding: .day, value: 1, to: bedDay)!
            if let wakeHour = routine.wakeHour, (0...23).contains(wakeHour),
               (0...59).contains(routine.wakeMinute), (0..<1440).contains(routine.graceMinutes),
               let nextWake = calendar.nextDate(after: bedtime,
                   matching: DateComponents(hour: wakeHour, minute: routine.wakeMinute, second: 0),
                   matchingPolicy: .nextTime, repeatedTimePolicy: .first),
               let transition = calendar.date(byAdding: .minute, value: routine.graceMinutes, to: nextWake),
               let wakeOnBedDay = calendar.date(bySettingHour: wakeHour, minute: routine.wakeMinute, second: 0, of: bedDay) {
                end = transition
                start = wakeOnBedDay <= bedtime ? wakeOnBedDay :
                    calendar.date(bySettingHour: wakeHour, minute: routine.wakeMinute, second: 0,
                                  of: calendar.date(byAdding: .day, value: -1, to: bedDay)!)!
            }
            // Without a configured wake, stop at midnight rather than inventing a morning boundary.
            guard now >= bedtime, now < end else { return nil }
            return (bedtime, start)
        }
        let bedtime = bedtimeWindow()
        let nightAlreadyRecorded = bedtime.map { window in
            ordered.contains { record in
                guard record.kind == .nightSleep, let end = record.observedEnd, end <= now else { return false }
                return record.date >= window.start || end >= window.bedtime
            }
        } ?? false
        let showsBedtime = bedtime.map { window in
            active == nil && !morning && !nightAlreadyRecorded &&
                observedWake.map { $0 >= window.bedtime } != true
        } ?? false
        let recentConfirmation = active.map { record in
            guard let transition else { return true }
            if record.date >= transition || (record.createdAt >= transition && record.createdAt <= now) { return true }
            return confirmation.map { $0.recordID == record.id && $0.date >= transition && $0.date <= now &&
                calendar.isDate($0.date, inSameDayAs: now) } ?? false
        } ?? false
        let explicitSleepObservation = active.map { record in
            var dates = [record.date]
            if record.createdAt >= record.date && record.createdAt <= now { dates.append(record.createdAt) }
            if let confirmation, confirmation.recordID == record.id,
               confirmation.date >= record.date, confirmation.date <= now,
               calendar.isDate(confirmation.date, inSameDayAs: now) { dates.append(confirmation.date) }
            return dates.max()!
        }
        let mode: Mode
        let context: SleepRecord?
        if let active, observedWake.map({ $0 > (explicitSleepObservation ?? active.date) }) != true {
            context = active
            mode = active.kind == .dayNap ? .napActive :
                (morning && !recentConfirmation ? .morningUnconfirmed : .nightActive)
        } else if showsBedtime {
            context = nil; mode = .bedtimeRoutine
        } else if let latestNap, observedWake.map({ $0 > (latestNap.observedEnd ?? latestNap.date) }) != true {
            context = latestNap; mode = .napCompleted
        } else if observedWake != nil {
            context = active; mode = .morningConfirmed
        } else if morning {
            context = active; mode = .morningUnconfirmed
        } else {
            context = nil
            mode = proposals.contains { $0.kind == .nextSleep && $0.unavailableReason(now: now, record: nil, wake: nil) == nil } ? .likelyNext : .ready
        }
        let valid = proposals.filter { mode != .bedtimeRoutine && $0.unavailableReason(now: now, record: context, wake: observedWake) == nil }
            .sorted { $0.generatedAt > $1.generatedAt }
        let napNumber = context.flatMap { record -> Int? in
            guard record.kind == .dayNap else { return nil }
            // Reuse the existing Home presentation's validated start-day nap sequencing.
            return HomeSleepCardPresentation.session(record: record, records: records, now: now, calendar: calendar).napNumber
        }
        return Self(mode: mode, record: context,
            sleepDay: context.map { calendar.startOfDay(for: $0.date) }, wakeTime: observedWake,
            routineWake: usual, now: now, napNumber: napNumber,
            netMinutes: context.flatMap { $0.isOngoing ? nil : $0.totalMinutes(breaks: records.filter { $0.kind == .break }, at: now) },
            elapsedMinutes: context.flatMap { $0.isOngoing ? max(0, Int(now.timeIntervalSince($0.date) / 60)) : nil },
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
        let nightStart = cal.date(bySettingHour: 20, minute: 12, second: 0, of: yesterday)!
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
    static func model(records: [SleepRecord], wakes: [DailyWakeRecord]) -> TodaySleepHeroModel {
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
            routine: routine, displayName: "Alex", babyName: "Baby", proposals: proposals)
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
