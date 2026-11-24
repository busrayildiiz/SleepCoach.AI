import Foundation

struct SleepStateCalculation {
    let activeSleepRecord: SleepRecord?
    let inferredNightSleepStart: Date?
    let inferredNightSleepRecord: SleepRecord?

    var isStillInNightSleep: Bool {
        activeSleepRecord != nil || inferredNightSleepRecord != nil
    }
}

struct SleepStateCalculator {
    let records: [SleepRecord]
    let now: Date
    let calendar: Calendar
    let typicalWakeHour: Int
    let typicalWakeMinute: Int
    let typicalBedHour: Int
    let typicalBedMinute: Int
    let averageNapDurationMinutes: Int?
    let predictedNextNapTime: Date?
    let recommendedWakeWindowMinutes: Int

    func calculate() -> SleepStateCalculation {
        let active = activeRecord
        let inferred = inferredNightSleepRecord(activeSleepRecord: active)
        return SleepStateCalculation(activeSleepRecord: active, inferredNightSleepStart: inferredNightSleepStart, inferredNightSleepRecord: inferred)
    }

    func expectedWakeTime(for ongoingSleep: SleepRecord?) -> Date {
        guard let ongoingSleep else {
            return wakeTime(on: now)
        }

        if ongoingSleep.kind == .dayNap {
            let expectedMinutes = ongoingSleep.duration > 0
                ? ongoingSleep.duration
                : (averageNapDurationMinutes ?? 75)
            return calendar.date(byAdding: .minute, value: expectedMinutes, to: ongoingSleep.date) ?? now
        }

        let candidate = wakeTime(on: now)
        if candidate > ongoingSleep.date { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    func nextSleepTimeAfterCurrentSleep(ongoingSleep: SleepRecord?, expectedWake: Date) -> Date? {
        guard let ongoingSleep else { return predictedNextNapTime }
        if ongoingSleep.kind == .nightSleep { return predictedNextNapTime }
        return calendar.date(byAdding: .minute, value: recommendedWakeWindowMinutes, to: expectedWake)
    }

    private var activeRecord: SleepRecord? {
        records
            .filter { $0.kind != .break && $0.isOngoing && $0.date <= now }
            .sorted { $0.date > $1.date }
            .first
    }

    private func inferredNightSleepRecord(activeSleepRecord: SleepRecord?) -> SleepRecord? {
        guard activeSleepRecord == nil, let start = inferredNightSleepStart else { return nil }
        return SleepRecord(id: UUID(), date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start)
    }

    private var inferredNightSleepStart: Date? {
        let today = calendar.startOfDay(for: now)
        let todayBedtime = calendar.date(bySettingHour: typicalBedHour, minute: typicalBedMinute, second: 0, of: today) ?? today.addingTimeInterval(TimeInterval(19 * 60 * 60 + 30 * 60))
        let todayWake = calendar.date(bySettingHour: typicalWakeHour, minute: typicalWakeMinute, second: 0, of: today) ?? today.addingTimeInterval(7 * 60 * 60)
        if now >= todayBedtime { return todayBedtime }
        if now < todayWake { return calendar.date(byAdding: .day, value: -1, to: todayBedtime) }
        return nil
    }

    private var hasPassedTypicalWakeTime: Bool {
        now >= wakeTime(on: now)
    }

    private func wakeTime(on date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: typicalWakeHour, minute: typicalWakeMinute, second: 0, of: day) ?? day.addingTimeInterval(7 * 60 * 60)
    }
}

struct SleepRoutine {
    let wakeHour: Int?
    var wakeMinute: Int = 0
    var bedHour: Int? = nil
    var bedMinute: Int = 0
    var graceMinutes: Int = 30

    static func load(defaults: any PrivateDataStore) -> Self? {
        guard defaults.isAvailable else { return nil }
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

extension SleepRoutine {
    private func time(hour: Int?, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        guard let hour, (0...23).contains(hour), (0...59).contains(minute),
              let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                       matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              calendar.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }

    func wake(on day: Date, calendar: Calendar) -> Date? {
        time(hour: wakeHour, minute: wakeMinute, on: day, calendar: calendar)
    }

    func bedtime(on day: Date, calendar: Calendar) -> Date? {
        time(hour: bedHour, minute: bedMinute, on: day, calendar: calendar)
    }

    func wake(after start: Date, calendar: Calendar) -> Date? {
        if let wake = wake(on: start, calendar: calendar), wake > start { return wake }
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) else { return nil }
        return wake(on: next, calendar: calendar)
    }

    func graceBoundary(for wake: Date) -> Date? {
        guard (0..<1440).contains(graceMinutes) else { return nil }
        return wake.addingTimeInterval(Double(graceMinutes) * 60)
    }

    func morningContains(_ date: Date, boundary: Date, calendar: Calendar) -> Bool {
        guard date >= boundary, calendar.isDate(date, inSameDayAs: boundary) else { return false }
        if let bedtime = bedtime(on: boundary, calendar: calendar), bedtime > boundary {
            return date < bedtime
        }
        return true
    }

    func bedtimeWindow(at now: Date, calendar: Calendar) -> (bedtime: Date, start: Date)? {
        let day = calendar.startOfDay(for: now)
        guard let today = bedtime(on: day, calendar: calendar),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
              let bedtime = today <= now ? today : bedtime(on: yesterday, calendar: calendar) else { return nil }
        let bedDay = calendar.startOfDay(for: bedtime)
        guard let wake = wake(after: bedtime, calendar: calendar), let boundary = graceBoundary(for: wake) else {
            return calendar.isDate(now, inSameDayAs: bedtime) ? (bedtime, bedDay) : nil
        }
        guard now < boundary else { return nil }
        let precedingDay = calendar.date(byAdding: .day, value: -1, to: bedDay) ?? bedDay
        let wakeOnBedDay = self.wake(on: bedDay, calendar: calendar)
        let start = wakeOnBedDay.flatMap { $0 <= bedtime ? $0 : self.wake(on: precedingDay, calendar: calendar) }
        return (bedtime, start ?? bedDay)
    }
}

struct SleepRecordVersion: Equatable {
    let id: UUID
    let content: String
    let revision: UUID?

    init(_ record: SleepRecord) {
        id = record.id
        content = ObservationProvenance.sleepIdentity(record)
        revision = record.persistedRevision
    }

    func matches(_ record: SleepRecord) -> Bool {
        id == record.id && revision == record.persistedRevision && content == ObservationProvenance.sleepIdentity(record)
    }
}

struct StillSleepingConfirmation {
    let version: SleepRecordVersion
    let date: Date
    var instant: ContinuousClock.Instant? = nil

    init(record: SleepRecord, date: Date, instant: ContinuousClock.Instant? = nil) {
        self.init(version: SleepRecordVersion(record), date: date, instant: instant)
    }

    init(version: SleepRecordVersion, date: Date, instant: ContinuousClock.Instant? = nil) {
        self.version = version
        self.date = date
        self.instant = instant
    }
}

struct SleepEvaluation {
    let now: Date
    let calendar: Calendar
    var routine: SleepRoutine? = nil
    var confirmation: StillSleepingConfirmation? = nil
    var instant: ContinuousClock.Instant? = nil

    static func current(confirmation: StillSleepingConfirmation? = nil) -> Self {
        Self(now: Date(), calendar: .current, routine: .load(defaults: SecureDataStore.shared),
             confirmation: confirmation, instant: ContinuousClock.now)
    }
}

enum SleepPlanningSource: String, Equatable {
    case recorded = "Recorded"
    case currentActivity = "Current sleep"
    case routine = "Routine-based guidance"
    case ageGuidance = "Age-based guidance"
    case recordedEstimate = "Estimate from recorded sleep"
    case activityEstimate = "Estimate during current sleep"
}

enum SleepPlanningUnavailable: String, Equatable {
    case missing = "Missing observations"
    case unresolved = "Sleep end unconfirmed"
    case unresolvedBreak = "Awake break end unconfirmed"
    case conflict = "Conflicting observations"
    case incomplete = "Incomplete sleep totals"
}

enum SleepPlanningValue<Value> {
    case available(Value, source: SleepPlanningSource, limitation: SleepPlanningUnavailable? = nil)
    case unavailable(SleepPlanningUnavailable)

    var value: Value? {
        guard case .available(let value, _, _) = self else { return nil }
        return value
    }

    var source: SleepPlanningSource? {
        guard case .available(_, let source, _) = self else { return nil }
        return source
    }

    var limitation: SleepPlanningUnavailable? {
        switch self {
        case .available(_, _, let reason): return reason
        case .unavailable(let reason): return reason
        }
    }
}

struct SleepStateAssessment {
    enum Anchor {
        case wake(Date)
        case napEnd(SleepRecord, Date)

        var date: Date {
            switch self {
            case .wake(let date), .napEnd(_, let date): return date
            }
        }
    }

    enum State {
        case active(SleepRecord, confirmation: Date?, elapsed: Int?)
        case observed(Anchor)
        case unconfirmed
        case missing
        case conflicting
    }

    let state: State
    let recordedWake: DailyWakeRecord?
    let latestWake: Date?
    let unresolvedRecords: [SleepRecord]
    var reviewRecord: SleepRecord? { unresolvedRecords.first }
    let reminderNight: SleepRecord?
    let morningReminder: Bool

    var active: (record: SleepRecord, confirmation: Date?, elapsed: Int?)? {
        guard case .active(let record, let confirmation, let elapsed) = state else { return nil }
        return (record, confirmation, elapsed)
    }

    var anchor: Anchor? {
        guard case .observed(let anchor) = state else { return nil }
        return anchor
    }

    var unavailableReason: SleepPlanningUnavailable {
        switch state {
        case .active, .unconfirmed: return .unresolved
        case .conflicting: return .conflict
        case .observed, .missing: return .missing
        }
    }
}

extension SleepStateCalculator {
    static func assess(records: [SleepRecord], wakes: [DailyWakeRecord],
                       evaluation: SleepEvaluation) -> SleepStateAssessment {
        let now = evaluation.now
        let calendar = evaluation.calendar
        let routine = evaluation.routine
        let ordered = records.filter { $0.kind != .break && $0.date.timeIntervalSinceReferenceDate.isFinite && $0.date <= now }
            .sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
        let unresolved = ordered.filter { $0.needsEndReview(at: now) }
        let open = unresolved.filter(\.isOngoing)
        let dayWakes = wakes.filter {
            $0.day.timeIntervalSinceReferenceDate.isFinite && calendar.isDate($0.day, inSameDayAs: now)
        }
        let validWakes = dayWakes.filter { $0.isObserved(on: now, at: now, calendar: calendar) }
        let wake = dayWakes.count == 1 ? validWakes.first : nil
        let completed = ordered.compactMap { record -> (SleepRecord, Date)? in
            guard let end = record.completedEnd(at: now), calendar.isDate(end, inSameDayAs: now) else { return nil }
            return (record, end)
        }
        let latestNightEnd = completed.filter { $0.0.kind == .nightSleep }.map { $0.1 }.max()
        let latestWake = [wake?.wakeTime, latestNightEnd].compactMap { $0 }.max()
        var anchors = completed.map { record, end -> SleepStateAssessment.Anchor in
            record.kind == .nightSleep ? .wake(end) : .napEnd(record, end)
        }
        if let wake { anchors.append(.wake(wake.wakeTime)) }
        let observed = anchors.max { $0.date < $1.date }
        let confirmation = evaluation.confirmation.flatMap { candidate in
            open.contains { candidate.version.matches($0) && candidate.date >= $0.date } && candidate.date <= now
                ? candidate : nil
        }
        let fresh = confirmation.flatMap { confirmed -> StillSleepingConfirmation? in
            if let instant = confirmed.instant, let current = evaluation.instant {
                return current >= instant && current < instant.advanced(by: .seconds(90 * 60)) ? confirmed : nil
            }
            return now.timeIntervalSince(confirmed.date) < 90 * 60 ? confirmed : nil
        }
        func boundary(_ record: SleepRecord) -> Date? {
            guard let wake = routine?.wake(after: record.date, calendar: calendar) else { return nil }
            return routine?.graceBoundary(for: wake)
        }
        func deadline(_ record: SleepRecord) -> Date {
            let expires = record.date.addingTimeInterval((record.kind == .nightSleep ? 24 : 4) * 3600)
            return boundary(record).map { record.kind == .nightSleep ? min($0, expires) : expires } ?? expires
        }

        let latestUnresolved = unresolved.first
        let confirmedOpen = fresh.flatMap { confirmation in open.first { $0.id == confirmation.version.id } }
        let activeCandidate = confirmedOpen.flatMap { record in
            latestUnresolved.map { $0.date > (fresh?.date ?? record.date) } == true ? nil : record
        } ?? latestUnresolved.flatMap { $0.isOngoing ? $0 : nil }
        let confirmedAt = activeCandidate.flatMap { fresh?.version.id == $0.id ? fresh?.date : nil }
        let sleepEvent = confirmedAt ?? latestUnresolved?.date
        let conflictTime = dayWakes.count > 1 ? validWakes.map(\.wakeTime).max() ?? now : nil
        let overlappingEnds = completed.enumerated().compactMap { index, first -> Date? in
            completed.dropFirst(index + 1).compactMap { second -> Date? in
                guard first.0.id != second.0.id, first.0.kind != second.0.kind,
                      first.0.date < second.1, second.0.date < first.1 else { return nil }
                return max(first.1, second.1)
            }.max()
        }.max()
        let wakeConflictEnd = wake.flatMap { wake in
            completed.filter { record, end in record.date < wake.wakeTime && wake.wakeTime < end }.map { $0.1 }.max()
        }
        let simultaneousStarts = latestUnresolved.flatMap { latest in
            unresolved.dropFirst().first(where: { $0.date == latest.date })?.date
        }
        let conflict = [conflictTime, overlappingEnds, wakeConflictEnd, simultaneousStarts].compactMap { $0 }.max()
        let equalAndIncompatible: Bool
        if case .wake = observed {
            equalAndIncompatible = observed?.date == sleepEvent && sleepEvent != nil
        } else {
            equalAndIncompatible = confirmedAt != nil && observed?.date == confirmedAt
        }
        let state: SleepStateAssessment.State
        if let conflict, [observed?.date, sleepEvent].compactMap({ $0 }).max().map({ $0 <= conflict }) ?? true {
            state = .conflicting
        } else if equalAndIncompatible {
            state = .conflicting
        } else if let activeCandidate, let sleepEvent, observed.map({ $0.date > sleepEvent }) != true,
                  confirmedAt != nil || now < deadline(activeCandidate) {
            let interrupted = observed.map { $0.date > activeCandidate.date } == true ||
                unresolved.contains { $0.date > activeCandidate.date }
            let elapsed = now < deadline(activeCandidate) && !interrupted
                ? Int(now.timeIntervalSince(activeCandidate.date) / 60) : nil
            state = .active(activeCandidate, confirmation: confirmedAt, elapsed: elapsed)
        } else if let observed, latestUnresolved.map({ $0.date >= observed.date }) != true,
                  confirmation.map({ $0.date >= observed.date }) != true {
            state = .observed(observed)
        } else {
            state = unresolved.isEmpty ? .missing : .unconfirmed
        }

        let activeID: UUID?
        if case .active(let record, _, _) = state { activeID = record.id } else { activeID = nil }
        let reminder = open.first { record in
            guard record.kind == .nightSleep, let boundary = boundary(record),
                  latestUnresolved?.id == record.id,
                  observed.map({ $0.date >= record.date }) != true,
                  conflict == nil, activeID == nil,
                  routine?.morningContains(now, boundary: boundary, calendar: calendar) == true else { return false }
            return true
        }
        let routineMorning = routine?.wake(on: now, calendar: calendar).flatMap { routine?.graceBoundary(for: $0) }
            .map { routine?.morningContains(now, boundary: $0, calendar: calendar) == true } ?? false
        return .init(state: state, recordedWake: wake, latestWake: latestWake,
                     unresolvedRecords: unresolved.filter { $0.id != activeID }, reminderNight: reminder,
                     morningReminder: reminder != nil || (unresolved.isEmpty && observed == nil && conflict == nil && routineMorning))
    }
}

struct SleepPredictionContext {
    let evaluation: SleepEvaluation
    let assessment: SleepStateAssessment
    let accounting: SleepAccounting

    init(records: [SleepRecord], wakes: [DailyWakeRecord], evaluation: SleepEvaluation) {
        self.evaluation = evaluation
        assessment = SleepStateCalculator.assess(records: records, wakes: wakes, evaluation: evaluation)
        accounting = SleepAccounting(records: records, now: evaluation.now, calendar: evaluation.calendar)
    }
}
