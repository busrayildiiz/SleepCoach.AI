import Foundation

struct SleepOverviewMetrics {
    let todayTotal: Int
    let yesterdayTotal: Int
    let todayDelta: Int
    let last7DaysAverage: Int
    let previous7DaysAverage: Int
    let averageNapMinutes: Int
    let latestNapDelta: Int
    let consistencyPercent: Int
    let todayNapCount: Int
    let todayGoalProgress: Double
    var sleepDayIsProvisional: Bool = true
    var rolling24hMinutes: Int = 0
    var daytimeMinutes: Int = 0
    var subtotalsAreReliable: Bool = true
    var rolling24hIsProvisional: Bool = false
}

struct SleepOverviewCalculator {
    private let records: [SleepRecord]
    private let now: Date
    private let calendar: Calendar
    private let totalSleepReference: ClosedRange<Int>?

    init(records: [SleepRecord], now: Date = Date(), calendar: Calendar = .current, totalSleepReference: ClosedRange<Int>? = nil) {
        self.totalSleepReference = totalSleepReference
        self.records = records
        self.now = now
        self.calendar = calendar
    }

    func calculate() -> SleepOverviewMetrics {
        let today = calendar.startOfDay(for: now)
        let todayRecords = records.filter { calendar.isDate($0.date, inSameDayAs: today) }
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        let summary = accounting.sleepDay(on: today)
        let todayTotal = summary.totalMinutes
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let yesterdayTotal = yesterday.map { yesterdayDate in
            totalMinutes(for: records.filter { record in
                calendar.isDate(record.date, inSameDayAs: yesterdayDate)
            })
        } ?? 0
        let sleeps = records.filter { $0.kind != .break }.sorted { $0.date > $1.date }
        let breaks = records.filter { $0.kind == .break }
        let latestSleepMinutes = sleeps.first?.totalMinutes(breaks: breaks, at: now) ?? 95
        let comparable = sleeps.dropFirst().map { $0.totalMinutes(breaks: breaks, at: now) }
        let averageNapMinutes = comparable.isEmpty ? 80 : comparable.reduce(0, +) / comparable.count

        return SleepOverviewMetrics(
            todayTotal: todayTotal,
            yesterdayTotal: yesterdayTotal,
            todayDelta: todayTotal - yesterdayTotal,
            last7DaysAverage: average(forOffsets: 0..<7, today: today),
            previous7DaysAverage: average(forOffsets: 7..<14, today: today),
            averageNapMinutes: averageNapMinutes,
            latestNapDelta: latestSleepMinutes - averageNapMinutes,
            consistencyPercent: consistency(today: today),
            todayNapCount: todayRecords.filter { $0.kind == .dayNap }.count,
            todayGoalProgress: totalSleepReference.map { min(Double(accounting.rolling24hMinutes) / Double(max(1, $0.lowerBound)), 1.0) } ?? 0,
            sleepDayIsProvisional: summary.isProvisional,
            rolling24hMinutes: accounting.rolling24hMinutes,
            daytimeMinutes: summary.daytimeMinutes,
            subtotalsAreReliable: summary.subtotalsAreReliable,
            rolling24hIsProvisional: accounting.rolling24hIsProvisional
        )
    }

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let sleeps = items.filter { $0.kind != .break }
        let ids = Set(sleeps.map(\.id))
        return SleepAccounting.netMinutes(records: records, now: now, sleepIDs: ids)
    }

    private func average(forOffsets offsets: Range<Int>, today: Date) -> Int {
        let days = offsets.map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
        let ids = Set(records.filter { record in
            record.kind != .break && days.contains { calendar.isDate(record.date, inSameDayAs: $0) }
        }.map(\.id))
        return SleepAccounting.netMinutes(records: records, now: now, sleepIDs: ids) / max(days.count, 1)
    }

    private func consistency(today: Date) -> Int {
        let totals = (0..<7).compactMap { offset -> Int? in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let total = totalMinutes(for: records.filter { calendar.isDate($0.date, inSameDayAs: day) })
            return total > 0 ? total : nil
        }
        guard totals.count > 1 else { return records.isEmpty ? 87 : 74 }
        let average = Double(totals.reduce(0, +)) / Double(totals.count)
        let variance = totals.reduce(0.0) { $0 + pow(Double($1) - average, 2) } / Double(totals.count)
        let deviation = sqrt(variance)
        return max(55, min(97, Int(100 - (deviation / max(average, 1) * 100))))
    }
}

/// Calendar grouping and elapsed-time accounting are deliberately separate.
/// All intervals are half-open; touching endpoints contribute no extra time.
struct SleepDaySummary {
    let totalMinutes: Int
    // These values retain original labels. Consumers must check subtotalsAreReliable
    // before presenting them as an additive partition when source records conflict.
    let daytimeMinutes: Int
    let nightMinutes: Int
    let isFinalized: Bool
    let hasClassificationConflict: Bool
    let hasSleepDayConflict: Bool
    var subtotalsAreReliable: Bool { !hasClassificationConflict && !hasSleepDayConflict }
    var isProvisional: Bool { !isFinalized }
}

struct SleepAccounting {
    let records: [SleepRecord]
    let now: Date
    let calendar: Calendar

    func records(on day: Date) -> [SleepRecord] {
        let sleeps = records.filter { $0.kind != .break && calendar.isDate($0.date, inSameDayAs: day) }
        let ids = Set(sleeps.map(\.id))
        return sleeps + records.filter { $0.kind == .break && $0.parentNapID.map(ids.contains) == true }
    }

    func sleepDay(on day: Date) -> SleepDaySummary {
        let selected = records(on: day)
        let sleeps = selected.filter { $0.kind != .break }
        let nights = sleeps.filter { $0.kind == .nightSleep }
        let conflicts = conflicts(affecting: sleeps)
        return SleepDaySummary(
            totalMinutes: Self.netMinutes(records: records, now: now, sleepIDs: Set(sleeps.map(\.id))),
            daytimeMinutes: Self.netMinutes(records: records, now: now, kind: .dayNap, sleepIDs: Set(sleeps.map(\.id))),
            nightMinutes: Self.netMinutes(records: records, now: now, kind: .nightSleep, sleepIDs: Set(sleeps.map(\.id))),
            isFinalized: !nights.isEmpty && sleeps.allSatisfy {
                $0.observedEnd.map { $0 <= now } == true
            },
            hasClassificationConflict: conflicts.classification,
            hasSleepDayConflict: conflicts.assignment
        )
    }

    /// No allocation rule is invented when user records disagree.
    func conflicts(affecting selected: [SleepRecord]) -> (classification: Bool, assignment: Bool) {
        let ids = Set(selected.map(\.id))
        let sleeps = records.filter { $0.kind != .break }
        var classification = false
        var assignment = false
        for (index, first) in sleeps.enumerated() {
            for second in sleeps.dropFirst(index + 1) {
                guard ids.contains(first.id) || ids.contains(second.id),
                      first.date < min(second.observedEnd ?? now, now),
                      second.date < min(first.observedEnd ?? now, now) else { continue }
                if first.kind != second.kind { classification = true }
                if !calendar.isDate(first.date, inSameDayAs: second.date) { assignment = true }
            }
        }
        return (classification, assignment)
    }

    var rolling24hIsProvisional: Bool {
        records.contains { record in
            record.kind != .break && record.date < now &&
            (record.isOngoing || record.observedEnd == nil) &&
            (record.isOngoing || record.date >= now.addingTimeInterval(-86400))
        }
    }

    var rolling24hMinutes: Int {
        // 24 elapsed hours, including on 23/25-hour daylight-saving calendar days.
        Self.netMinutes(records: records, now: now,
                        window: DateInterval(start: now.addingTimeInterval(-86400), end: now))
    }

    static func netMinutes(records: [SleepRecord], now: Date,
                           window: DateInterval? = nil, kind: SleepKind? = nil, sleepIDs: Set<UUID>? = nil) -> Int {
        Int(netIntervals(records: records, now: now, window: window, kind: kind, sleepIDs: sleepIDs)
            .reduce(0.0) { $0 + $1.duration } / 60)
    }

    static func netIntervals(records: [SleepRecord], now: Date,
                             window: DateInterval? = nil, kind: SleepKind? = nil, sleepIDs: Set<UUID>? = nil) -> [DateInterval] {
        let sleeps = records.filter { $0.kind != .break }
        func interval(_ record: SleepRecord) -> DateInterval? {
            let end: Date
            if record.isOngoing { end = now }
            else if let observed = record.observedEnd { end = min(observed, now) }
            else { return nil } // Unknown end is not a confirmed zero-length sleep.
            guard end > record.date else { return nil }
            return clip(DateInterval(start: record.date, end: end), to: window)
        }
        let sleepIntervals = union(sleeps.filter { (kind == nil || $0.kind == kind) && (sleepIDs?.contains($0.id) ?? true) }.compactMap(interval))
        let awakeIntervals = union(records.filter { $0.kind == .break }.compactMap { awake -> DateInterval? in
            guard let parentID = awake.parentNapID,
                  let parent = sleeps.first(where: { $0.id == parentID }),
                  let parentInterval = interval(parent),
                  let awakeInterval = interval(awake) else { return nil }
            return clip(awakeInterval, to: parentInterval)
        })
        // A valid explicit awake interval wins even when another record says sleep.
        return sleepIntervals.flatMap { sleep -> [DateInterval] in
            var pieces = [sleep]
            for awake in awakeIntervals {
                pieces = pieces.flatMap { piece -> [DateInterval] in
                    guard let overlap = clip(piece, to: awake) else { return [piece] }
                    var remainder: [DateInterval] = []
                    if piece.start < overlap.start { remainder.append(DateInterval(start: piece.start, end: overlap.start)) }
                    if overlap.end < piece.end { remainder.append(DateInterval(start: overlap.end, end: piece.end)) }
                    return remainder
                }
            }
            return pieces
        }
    }

    private static func clip(_ interval: DateInterval, to window: DateInterval?) -> DateInterval? {
        let start = max(interval.start, window?.start ?? interval.start)
        let end = min(interval.end, window?.end ?? interval.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
}
