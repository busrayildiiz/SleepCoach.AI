import Foundation

struct SleepTimelineItem: Equatable {
    enum Kind: Equatable { case wake, nap(index: Int), bedtime }
    enum VisualState: Equatable { case completed, active, upcoming }

    let kind: Kind
    let time: Date
    let durationMinutes: Int?
    let isOngoing: Bool
    let visualState: VisualState
    let isActive: Bool
    let isFuture: Bool
    let awakeBeforeMinutes: Int
}

struct SleepTimelineCalculator {
    let records: [SleepRecord]
    let wakeRecord: DailyWakeRecord?
    let snapshot: OrchestratedSnapshot?
    let defaultWakeTime: Date
    let now: Date
    let profileProvider: AgeBasedSleepProfileProviding

    func calculate() -> [SleepTimelineItem] {
        let naps = records.filter { $0.kind == .dayNap }.sorted { $0.date < $1.date }
        let wake = wakeAnchor(sortedNaps: naps)
        let expectedDuration = expectedNapDuration
        var items = [SleepTimelineItem(kind: .wake, time: wake, durationMinutes: nil, isOngoing: false, visualState: wake <= now ? .completed : .upcoming, isActive: false, isFuture: wake > now, awakeBeforeMinutes: 0)]
        var anchorEnd = wake

        for (index, nap) in naps.enumerated() {
            guard items.count < 4 else { return items }
            let end = nap.date.addingTimeInterval(TimeInterval(nap.duration * 60))
            let active = nap.isOngoing || (nap.date <= now && end > now)
            let state: SleepTimelineItem.VisualState = active ? .active : (end <= now ? .completed : .upcoming)
            items.append(SleepTimelineItem(kind: .nap(index: index + 1), time: nap.date, durationMinutes: nap.isOngoing ? nil : nap.totalMinutes(breaks: records.filter { $0.kind == .break }), isOngoing: nap.isOngoing, visualState: state, isActive: active, isFuture: nap.date > now, awakeBeforeMinutes: max(0, Int(nap.date.timeIntervalSince(anchorEnd) / 60))))
            anchorEnd = end
        }

        let expectedCount = snapshot?.ageMonths.map { profileProvider.profile(forAgeMonths: $0).expectedNapCount.upperBound } ?? 2
        var predictedIndex = naps.count + 1
        while snapshot?.nextSleepKind != .bedtime && items.count < 4 && predictedIndex <= expectedCount {
            let start = predictedNapStart(index: predictedIndex, anchorEnd: anchorEnd)
            items.append(SleepTimelineItem(kind: .nap(index: predictedIndex), time: start, durationMinutes: expectedDuration, isOngoing: false, visualState: .upcoming, isActive: false, isFuture: true, awakeBeforeMinutes: max(0, Int(start.timeIntervalSince(anchorEnd) / 60))))
            anchorEnd = start.addingTimeInterval(TimeInterval(expectedDuration * 60))
            predictedIndex += 1
        }

        if items.count < 4 {
            let bedtime = bedtime(after: anchorEnd, expectedNapCount: expectedCount)
            items.append(SleepTimelineItem(kind: .bedtime, time: bedtime, durationMinutes: nil, isOngoing: false, visualState: bedtime <= now ? .completed : .upcoming, isActive: false, isFuture: bedtime > now, awakeBeforeMinutes: max(0, Int(bedtime.timeIntervalSince(anchorEnd) / 60))))
        }
        return items
    }

    private var completedNapCount: Int { records.filter { $0.kind == .dayNap }.count }
    private var profile: AgeBasedSleepProfile { profileProvider.profile(forAgeMonths: snapshot?.ageMonths ?? 10) }
    private var expectedNapDuration: Int {
        if let value = snapshot?.daytime.expectedDurationMinutes { return value }
        let target = profile.daytimeSleepRange.lowerBound / max(profile.expectedNapCount.upperBound, 1)
        return min(profile.maxSingleNapMinutes, max(45, target))
    }

    private func wakeAnchor(sortedNaps: [SleepRecord]) -> Date {
        if let wakeRecord { return wakeRecord.wakeTime }
        if let first = sortedNaps.first { return first.date.addingTimeInterval(TimeInterval(-wakeWindow(index: 1) * 60)) }
        return defaultWakeTime
    }

    private func wakeWindow(index: Int) -> Int {
        if index == completedNapCount + 1, let used = snapshot?.daytime.wakeWindowUsed { return used }
        if index <= 1 { return (profile.morningWakeWindow.lowerBound + profile.morningWakeWindow.upperBound) / 2 }
        if index >= profile.expectedNapCount.upperBound + 1 { return (profile.eveningWakeWindow.lowerBound + profile.eveningWakeWindow.upperBound) / 2 }
        return (profile.wakeWindowRange.lowerBound + profile.wakeWindowRange.upperBound) / 2
    }

    private func predictedNapStart(index: Int, anchorEnd: Date) -> Date {
        if index == completedNapCount + 1, let next = snapshot?.daytime.nextNapTime { return next }
        return anchorEnd.addingTimeInterval(TimeInterval(wakeWindow(index: index) * 60))
    }

    private func bedtime(after anchorEnd: Date, expectedNapCount: Int) -> Date {
        if let value = snapshot?.night.optimalBedtimeStart { return value }
        let proposed = anchorEnd.addingTimeInterval(TimeInterval(wakeWindow(index: expectedNapCount + 1) * 60))
        let hour = Calendar.current.component(.hour, from: proposed)
        guard hour < profile.bedtimeHourRange.lowerBound || hour > profile.bedtimeHourRange.upperBound else { return proposed }
        return Calendar.current.date(bySettingHour: min(max(hour, profile.bedtimeHourRange.lowerBound), profile.bedtimeHourRange.upperBound), minute: Calendar.current.component(.minute, from: proposed), second: 0, of: proposed) ?? proposed
    }
}
