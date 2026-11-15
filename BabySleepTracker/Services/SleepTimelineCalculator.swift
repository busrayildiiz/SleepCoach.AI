import Foundation

/// A projection of observations and explicitly supplied planning events, not a predictor.
struct SleepTimelineItem: Equatable, Identifiable {
    enum Kind: Equatable { case wake, nap(index: Int?), bedtime, plan }
    enum VisualState: Equatable { case completed, active, next, future, unavailable }
    enum Source: Equatable { case recorded(UUID), estimate, defaultValue, guidance, unavailable }
    enum UnavailableReason: Equatable {
        case missingRecord, invalidRecord, eligibilityUnverified, missingPrediction, overdue, notAnObservation
    }

    let id: String
    let kind: Kind
    /// The original start-date Sleep Day; never reassigned at midnight.
    let sleepDay: Date
    let source: Source
    let time: Date?
    let observedEnd: Date?
    /// Net recorded sleep, only for a valid completed interval.
    let durationMinutes: Int?
    /// Wall-clock elapsed time, not a predicted duration or remaining countdown.
    let elapsedMinutes: Int?
    let visualState: VisualState
    let unavailableReason: UnavailableReason?
    var awakeBeforeMinutes: Int? = nil
    /// Context only: this session still belongs to its original Sleep Day.
    var isCarryover: Bool = false

    var isOngoing: Bool { visualState == .active }
    var isActive: Bool { visualState == .active }
    var isFuture: Bool { visualState == .next || visualState == .future }
    var usesDashedConnector: Bool {
        if case .recorded = source { return visualState == .unavailable }
        return true
    }
}

struct SleepTimelineProposal {
    enum Source { case estimate, defaultValue, guidance }
    /// Stable identity supplied by the planning source.
    let id: String
    let kind: SleepTimelineItem.Kind
    let sleepDay: Date
    let time: Date
    let source: Source
}

struct SleepTimelineCalculator {
    /// This is an explicit input, not an implementation of the learning policy.
    /// The app must leave it unavailable until a verified source exists.
    enum PredictionEligibility { case unavailable, verified }

    let records: [SleepRecord]
    let wakeRecord: DailyWakeRecord?
    let now: Date
    let calendar: Calendar
    var day: Date? = nil
    var proposals: [SleepTimelineProposal] = []
    var predictionEligibility: PredictionEligibility = .unavailable

    func calculate() -> [SleepTimelineItem] {
        let sleepDay = calendar.startOfDay(for: day ?? now)
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        let selected = accounting.records(on: sleepDay)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: sleepDay)
        // Only today's row receives previous-day ongoing context. Historical rows
        // retain their own start-day records, and completed nights are never reassigned.
        let carryover = calendar.isDate(sleepDay, inSameDayAs: now) ? records.filter { record in
            record.kind != .break && record.isOngoing && record.date <= now &&
                previousDay.map { calendar.isDate(record.date, inSameDayAs: $0) } == true
        } : []
        let sleeps = (selected.filter { $0.kind != .break } + carryover).sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        var items = [wakeItem(on: sleepDay)]
        for record in sleeps {
            let completed = !record.isOngoing && record.date <= now &&
                record.observedEnd.map { $0 <= now } == true
            let active = record.isOngoing && record.date <= now
            let originalDay = calendar.startOfDay(for: record.date)
            let kind: SleepTimelineItem.Kind = record.kind == .nightSleep ? .bedtime :
                .nap(index: completed || active ? napNumber(for: record, accounting: accounting) : nil)
            items.append(SleepTimelineItem(
                id: "record:\(record.id.uuidString)", kind: kind, sleepDay: originalDay,
                source: .recorded(record.id), time: record.date,
                observedEnd: completed ? record.observedEnd : nil,
                durationMinutes: completed ? record.totalMinutes(breaks: selected.filter { $0.kind == .break }, at: now) : nil,
                elapsedMinutes: active ? max(0, Int(now.timeIntervalSince(record.date) / 60)) : nil,
                visualState: completed ? .completed : (active ? .active : .unavailable),
                unavailableReason: completed || active ? nil : .invalidRecord,
                isCarryover: originalDay != sleepDay))
        }

        let selectedProposals = proposals.filter { calendar.isDate($0.sleepDay, inSameDayAs: sleepDay) }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
        var hasNext = false
        for proposal in selectedProposals {
            let source: SleepTimelineItem.Source
            switch proposal.source {
            case .estimate: source = .estimate
            case .defaultValue: source = .defaultValue
            case .guidance: source = .guidance
            }
            let state: SleepTimelineItem.VisualState
            let reason: SleepTimelineItem.UnavailableReason?
            let visibleTime: Date?
            if proposal.source != .estimate {
                state = .unavailable; reason = .notAnObservation; visibleTime = nil
            } else if predictionEligibility != .verified {
                state = .unavailable; reason = .eligibilityUnverified; visibleTime = nil
            } else if proposal.time <= now {
                state = .unavailable; reason = .overdue; visibleTime = proposal.time
            } else {
                state = hasNext ? .future : .next; reason = nil; visibleTime = proposal.time
                hasNext = true
            }
            items.append(SleepTimelineItem(
                id: "proposal:\(proposal.id)", kind: proposal.kind, sleepDay: sleepDay,
                source: source, time: visibleTime, observedEnd: nil, durationMinutes: nil,
                elapsedMinutes: nil, visualState: state, unavailableReason: reason))
        }
        if selectedProposals.isEmpty {
            items.append(SleepTimelineItem(
                id: "plan:\(sleepDay.timeIntervalSince1970)", kind: .plan, sleepDay: sleepDay,
                source: .unavailable, time: nil, observedEnd: nil, durationMinutes: nil,
                elapsedMinutes: nil, visualState: .unavailable,
                unavailableReason: predictionEligibility == .verified ? .missingPrediction : .eligibilityUnverified))
        }
        // Nil-time wake/plan placeholders bookend the chronological observed/eligible events.
        items.sort {
            let left = $0.time ?? ($0.kind == .wake ? .distantPast : .distantFuture)
            let right = $1.time ?? ($1.kind == .wake ? .distantPast : .distantFuture)
            return left == right ? $0.id < $1.id : left < right
        }
        for index in items.indices.dropFirst() {
            let previous = items[index - 1]
            // An ongoing/unknown interval has no observed ending to anchor awake time.
            let end = previous.kind == .wake && previous.visualState == .completed ? previous.time : previous.observedEnd
            if let end, let start = items[index].time, start >= end,
               items[index].visualState != .unavailable {
                items[index].awakeBeforeMinutes = Int(start.timeIntervalSince(end) / 60)
            }
        }
        return items
    }

    private func napNumber(for record: SleepRecord, accounting: SleepAccounting) -> Int? {
        let naps = accounting.records(on: record.date).filter {
            $0.kind == .dayNap && $0.date <= now &&
                ($0.isOngoing || $0.observedEnd.map { $0 <= now } == true)
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        return naps.firstIndex { $0.id == record.id }.map { $0 + 1 }
    }

    private func wakeItem(on day: Date) -> SleepTimelineItem {
        guard let record = wakeRecord, calendar.isDate(record.day, inSameDayAs: day) else {
            return SleepTimelineItem(id: "wake:\(day.timeIntervalSince1970)", kind: .wake,
                sleepDay: day, source: .unavailable, time: nil, observedEnd: nil,
                durationMinutes: nil, elapsedMinutes: nil, visualState: .unavailable,
                unavailableReason: .missingRecord)
        }
        let valid = calendar.isDate(record.wakeTime, inSameDayAs: day) && record.wakeTime <= now
        return SleepTimelineItem(id: "record:\(record.id.uuidString)", kind: .wake,
            sleepDay: day, source: .recorded(record.id), time: record.wakeTime, observedEnd: nil,
            durationMinutes: nil, elapsedMinutes: nil,
            visualState: valid ? .completed : .unavailable, unavailableReason: valid ? nil : .invalidRecord)
    }
}
