import Foundation

/// Home-only horizon and display metadata over the existing timeline projection.
/// Does not generate predictions, change recorded states, or write sleep/wake data.
struct TodayPlanPresentation {
    struct MorningWake: Equatable, Identifiable {
        enum Source: Equatable { case estimated, routine, unavailable }
        let id: String
        let source: Source
        let time: Date?
    }

    let items: [SleepTimelineItem]
    let isOvernight: Bool
    let morningWake: MorningWake?
    let predictionsUnavailable: Bool
    /// Presentation wording follows the existing Hero, never a new wake-time rule.
    let overnightEndUnconfirmed: Bool

    init(items: [SleepTimelineItem], isOvernight: Bool = false, morningWake: MorningWake? = nil,
         overnightEndUnconfirmed: Bool = false) {
        // Unavailable/default predictions are an indicator, never a scheduled node.
        self.items = items.filter { item in
            switch item.source {
            case .recorded: return true
            case .estimate: return item.isFuture
            default: return false
            }
        }
        self.isOvernight = isOvernight
        self.morningWake = morningWake
        self.overnightEndUnconfirmed = overnightEndUnconfirmed
        predictionsUnavailable = !isOvernight && items.contains {
            $0.kind == .plan || $0.source == .defaultValue || $0.source == .guidance ||
                ($0.source == .estimate && $0.visualState == .unavailable)
        }
    }

    /// The Hero supplies the current confirmed context, including its morning transition.
    /// Historical projection reuses SleepTimelineCalculator to retain IDs and Sleep Days.
    static func make(records: [SleepRecord], wakes: [DailyWakeRecord], hero: TodaySleepHeroModel,
                     now: Date, calendar: Calendar, routine: TodaySleepHeroModel.Routine?,
                     proposals: [SleepTimelineProposal] = [],
                     eligibility: SleepTimelineCalculator.PredictionEligibility = .unavailable) -> Self {
        let day = calendar.startOfDay(for: now)
        let dayWakes = wakes.filter { calendar.isDate($0.day, inSameDayAs: now) }
        let confirmedWake = dayWakes.filter { calendar.isDate($0.wakeTime, inSameDayAs: now) && $0.wakeTime <= now }
            .max { $0.wakeTime < $1.wakeTime }
        let wake = confirmedWake ?? dayWakes.max { $0.wakeTime < $1.wakeTime }
        let today = SleepTimelineCalculator(records: records, wakeRecord: wake, now: now,
            calendar: calendar, proposals: proposals, predictionEligibility: eligibility).calculate()
        func projected(_ record: SleepRecord) -> SleepTimelineItem? {
            var result = SleepTimelineCalculator(records: records, wakeRecord: nil, now: now,
                calendar: calendar, day: record.date).calculate().first { $0.source == .recorded(record.id) }
            result?.isCarryover = !calendar.isDate(record.date, inSameDayAs: now)
            return result
        }
        if let context = hero.record, let night = records.first(where: { $0.id == context.id }),
           night.isOngoing, night.kind == .nightSleep, night.date < day,
           let event = projected(night) {
            let endUnconfirmed = hero.mode == .morningUnconfirmed || hero.mode == .morningConfirmed
            // A separately saved wake never silently closes an unresolved sleep.
            if let confirmedWake, let observed = today.first(where: { $0.source == .recorded(confirmedWake.id) }) {
                return Self(items: [event, observed], isOvernight: true, overnightEndUnconfirmed: endUnconfirmed)
            }
            let predicted = hero.predictions.first {
                $0.kind == .morningWake && $0.unavailableReason(now: now, record: night, wake: nil) == nil
            }?.end
            let reference: MorningWake
            let id = "morning-wake:\(night.id.uuidString)"
            if let predicted {
                reference = .init(id: id, source: .estimated, time: predicted)
            } else if let routine, (0...23).contains(routine.wakeHour), (0...59).contains(routine.wakeMinute),
                      let morning = calendar.date(byAdding: .day, value: 1,
                          to: calendar.startOfDay(for: night.date)),
                      let time = calendar.date(bySettingHour: routine.wakeHour, minute: routine.wakeMinute,
                          second: 0, of: morning) {
                // Anchor to this night, not "the next time after now". A missed routine
                // wake remains an unconfirmed past reference after the grace boundary.
                reference = .init(id: id, source: .routine, time: time)
            } else {
                reference = .init(id: id, source: .unavailable, time: nil)
            }
            return Self(items: [event], isOvernight: true, morningWake: reference,
                        overnightEndUnconfirmed: endUnconfirmed)
        }
        // The planning horizon may retain the completed overnight context after wake
        // confirmation. Ownership/accounting still belongs to its original start day.
        let completedNight = records.filter {
            $0.kind == .nightSleep && !$0.isOngoing && $0.date < day &&
                $0.observedEnd.map { $0 <= now && calendar.isDate($0, inSameDayAs: now) } == true
        }.max { ($0.observedEnd ?? $0.date) < ($1.observedEnd ?? $1.date) }
        var events = today
        if let night = completedNight, !events.contains(where: { $0.source == .recorded(night.id) }),
           let context = projected(night) { events.append(context) }
        events.sort {
            let left = $0.time ?? .distantFuture
            let right = $1.time ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
        return Self(items: events)
    }

    /// Unconfirmed routine references and unavailable entries never inflate progress.
    var availableEventCount: Int {
        items.filter { item in
            switch item.source {
            case .recorded: return item.visualState == .completed || item.visualState == .active
            case .estimate: return item.isFuture
            default: return false
            }
        }.count + (morningWake?.source == .estimated ? 1 : 0)
    }
    var completedEventCount: Int {
        items.filter { item in
            if case .recorded = item.source { return item.visualState == .completed }
            return false
        }.count
    }
    func isConfirmedConnector(after index: Int) -> Bool {
        guard items.indices.contains(index), items.indices.contains(index + 1) else { return false }
        let previous = items[index]
        let next = items[index + 1]
        guard case .recorded = previous.source, case .recorded = next.source,
              previous.visualState == .completed,
              next.visualState == .completed || next.visualState == .active,
              let end = previous.kind == .wake ? previous.time : previous.observedEnd,
              let start = next.time, end <= start else { return false }
        return true
    }
    func minutesUntil(_ item: SleepTimelineItem, now: Date) -> Int? {
        guard item.source == .estimate, item.isFuture, let time = item.time, time > now else { return nil }
        return max(1, Int(ceil(time.timeIntervalSince(now) / 60)))
    }
}
