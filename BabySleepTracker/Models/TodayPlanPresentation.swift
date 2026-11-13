import Foundation

/// Display metadata derived from PR #20's timeline. Does not generate events or eligibility.
struct TodayPlanPresentation {
    let items: [SleepTimelineItem]

    /// Missing/invalid observations and unavailable predictions are not planned steps.
    var availableEventCount: Int {
        items.filter { item in
            switch item.source {
            case .recorded: return item.visualState == .completed || item.visualState == .active
            case .estimate: return item.visualState == .next || item.visualState == .future
            default: return false
            }
        }.count
    }

    var completedEventCount: Int {
        items.filter { item in
            if case .recorded = item.source { return item.visualState == .completed }
            return false
        }.count
    }

    /// A solid link requires observed progress on both sides; time passing is insufficient.
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
