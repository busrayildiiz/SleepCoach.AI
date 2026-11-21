import Foundation

enum CompletedRecordedSubtotal: Equatable {
    case comparable(Int)
    case incomplete(Int?, reason: SleepPlanningUnavailable)

    var minutes: Int? {
        switch self {
        case .comparable(let minutes), .incomplete(let minutes?, _): return minutes
        case .incomplete(nil, _): return nil
        }
    }

    var comparableMinutes: Int? {
        guard case .comparable(let minutes) = self else { return nil }
        return minutes
    }

    var isIncomplete: Bool { comparableMinutes == nil }

    var unavailableReason: SleepPlanningUnavailable? {
        guard case .incomplete(_, let reason) = self else { return nil }
        return reason
    }

    var display: String {
        let amount = minutes.map(TimeFormat.minutes)
        if isIncomplete {
            return amount.map { "\($0) · Incomplete" } ?? (unavailableReason == .missing ? "Unknown" : "Incomplete")
        }
        return amount ?? "Unavailable"
    }
}

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
    var todayGoalProgress: Double? { recordedGoalProgress }
    var sleepDayIsProvisional: Bool = true
    var rolling24hMinutes: Int = 0
    var daytimeMinutes: Int = 0
    var subtotalsAreReliable: Bool = true
    var rolling24hIsProvisional: Bool = false
    var recordedSleepDay: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var recordedRolling24h: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var recordedDaytime: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var recordedGoalProgress: Double? = nil
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
        let recordedDay = accounting.completedSubtotal(on: today)
        let recordedRolling = accounting.completedRolling24h
        let todayTotal = summary.totalMinutes
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let yesterdayTotal = yesterday.map { yesterdayDate in
            totalMinutes(for: records.filter { record in
                calendar.isDate(record.date, inSameDayAs: yesterdayDate)
            })
        } ?? 0
        let sleeps = records.filter { $0.kind != .break && $0.completedEnd(at: now) != nil }.sorted { $0.date > $1.date }
        let measured = sleeps.compactMap { accounting.completedMinutes(sleepIDs: [$0.id]) }
        let latestSleepMinutes = measured.first ?? 95
        let comparable = measured.dropFirst()
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
            todayNapCount: todayRecords.filter { $0.kind == .dayNap && $0.completedEnd(at: now) != nil }.count,
            sleepDayIsProvisional: summary.isProvisional,
            rolling24hMinutes: accounting.rolling24hMinutes,
            daytimeMinutes: summary.daytimeMinutes,
            subtotalsAreReliable: summary.subtotalsAreReliable,
            rolling24hIsProvisional: accounting.rolling24hIsProvisional,
            recordedSleepDay: recordedDay,
            recordedRolling24h: recordedRolling,
            recordedDaytime: accounting.completedSubtotal(on: today, kind: .dayNap),
            recordedGoalProgress: recordedRolling.comparableMinutes.flatMap { minutes in
                totalSleepReference.map { min(Double(minutes) / Double(max(1, $0.lowerBound)), 1) }
            }
        )
    }

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let sleeps = items.filter { $0.kind != .break }
        let ids = Set(sleeps.map(\.id))
        return accountedMinutes(ids)
    }

    private func average(forOffsets offsets: Range<Int>, today: Date) -> Int {
        let days = offsets.map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
        let ids = Set(records.filter { record in
            record.kind != .break && days.contains { calendar.isDate(record.date, inSameDayAs: $0) }
        }.map(\.id))
        return accountedMinutes(ids) / max(days.count, 1)
    }

    private func accountedMinutes(_ ids: Set<UUID>) -> Int {
        let intervals = SleepAccounting(records: records, now: now, calendar: calendar).completedIntervals(sleepIDs: ids)
        return Int(intervals.reduce(0.0) { $0 + $1.duration } / 60)
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
        let conflicts = conflicts(affecting: sleeps)
        return SleepDaySummary(
            totalMinutes: Self.netMinutes(records: records, now: now, sleepIDs: Set(sleeps.map(\.id))),
            daytimeMinutes: Self.netMinutes(records: records, now: now, kind: .dayNap, sleepIDs: Set(sleeps.map(\.id))),
            nightMinutes: Self.netMinutes(records: records, now: now, kind: .nightSleep, sleepIDs: Set(sleeps.map(\.id))),
            isFinalized: !completedSubtotal(on: day).isIncomplete,
            hasClassificationConflict: conflicts.classification,
            hasSleepDayConflict: conflicts.assignment
        )
    }

    func completedIntervals(sleepIDs: Set<UUID>, window: DateInterval? = nil) -> [DateInterval] {
        let selected = records.filter { $0.kind != .break && sleepIDs.contains($0.id) }
        return measuredIntervals(for: measurableSleeps(in: selected, window: window), window: window)
    }

    /// Measures the requested recorded sessions without inferring coverage of a larger window.
    func completedMinutes(sleepIDs: Set<UUID>) -> Int? {
        let selected = records.filter { $0.kind != .break && sleepIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let measurable = measurableSleeps(in: selected, window: nil)
        let conflicts = conflicts(affecting: selected, completedOnly: true)
        guard measurable.count == selected.count, Set(measurable.map(\.id)) == sleepIDs,
              !conflicts.classification, !conflicts.assignment else { return nil }
        return Self.minutes(in: measuredIntervals(for: measurable, window: nil))
    }

    /// The start must come from a later, valid observed wake or sleep end. An
    /// unresolved onset inside the gap breaks continuity even without a usable duration.
    func recordedAwakeMinutes(from start: Date, until end: Date) -> Int? {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start <= end, end <= now else { return nil }
        let interrupted = records.contains { record in
            guard record.kind != .break, record.date < end else { return false }
            if let recordedEnd = record.completedEnd(at: now) { return recordedEnd > start }
            return record.date >= start
        }
        return interrupted ? nil : Int(end.timeIntervalSince(start) / 60)
    }

    func completedSubtotal(on day: Date, kind: SleepKind? = nil) -> CompletedRecordedSubtotal {
        let selected = records.filter {
            $0.kind != .break && (kind == nil || kind == $0.kind) &&
                calendar.isDate($0.date, inSameDayAs: day) && $0.date <= now
        }
        return completedSubtotal(for: selected)
    }

    var completedRolling24h: CompletedRecordedSubtotal {
        completedSubtotal(in: DateInterval(start: now.addingTimeInterval(-86400), end: now))
    }

    func completedSubtotal(in window: DateInterval) -> CompletedRecordedSubtotal {
        let selected = records.filter { record in
            guard record.kind != .break, record.date < min(now, window.end) else { return false }
            return record.completedEnd(at: now).map { $0 > window.start } ?? true
        }
        return completedSubtotal(for: selected, window: window)
    }

    private func completedSubtotal(for selected: [SleepRecord],
                                   window: DateInterval? = nil) -> CompletedRecordedSubtotal {
        guard !selected.isEmpty else { return .incomplete(nil, reason: .missing) }
        let completed = selected.filter { $0.completedEnd(at: now) != nil }
        let measurable = measurableSleeps(in: completed, window: window)
        let minutes = measurable.isEmpty ? nil : Self.minutes(in: measuredIntervals(for: measurable, window: window))
        let conflicts = conflicts(affecting: completed, completedOnly: true, window: window)
        if conflicts.classification || conflicts.assignment { return .incomplete(minutes, reason: .conflict) }
        if measurable.count < completed.count { return .incomplete(minutes, reason: .unresolvedBreak) }
        if completed.count < selected.count { return .incomplete(minutes, reason: .unresolved) }
        // A LearningDay attestation covers a different window. Accounting
        // has no coverage evidence for these Sleep Days or arbitrary intervals.
        return .incomplete(minutes, reason: .incomplete)
    }

    private func measurableSleeps(in selected: [SleepRecord], window: DateInterval?) -> [SleepRecord] {
        guard !selected.isEmpty else { return [] }
        let parents = Dictionary(records.filter { $0.kind != .break }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let possibleAwake = records.compactMap { record -> DateInterval? in
            guard record.kind == .break, record.needsEndReview(at: now),
                  let parent = record.parentNapID.flatMap({ parents[$0] }),
                  parent.date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let start = max(record.date, parent.date)
            let end = parent.completedEnd(at: now) ?? now
            guard end > start else { return nil }
            return Self.clip(DateInterval(start: start, end: end), to: window)
        }
        return selected.filter { record in
            guard let end = record.completedEnd(at: now),
                  let interval = Self.clip(DateInterval(start: record.date, end: end), to: window) else { return false }
            return !possibleAwake.contains { Self.clip($0, to: interval) != nil }
        }
    }

    private func measuredIntervals(for selected: [SleepRecord], window: DateInterval?) -> [DateInterval] {
        Self.netIntervals(records: records, now: now, window: window, sleepIDs: Set(selected.map(\.id)),
                          completedBreaksOnly: true)
    }

    private static func minutes(in intervals: [DateInterval]) -> Int {
        Int(intervals.reduce(0.0) { $0 + $1.duration } / 60)
    }

    /// No allocation rule is invented when user records disagree.
    func conflicts(affecting selected: [SleepRecord], completedOnly: Bool = false, window: DateInterval? = nil) -> (classification: Bool, assignment: Bool) {
        let ids = Set(selected.map(\.id))
        let sleeps = records.filter { $0.kind != .break && (!completedOnly || $0.completedEnd(at: now) != nil) }
        var classification = false
        var assignment = false
        for (index, first) in sleeps.enumerated() where ids.contains(first.id) {
            for (otherIndex, second) in sleeps.enumerated() where otherIndex != index {
                guard max(first.date, second.date, window?.start ?? .distantPast) <
                        min(first.observedEnd ?? now, second.observedEnd ?? now, now, window?.end ?? .distantFuture)
                else { continue }
                if first.kind != second.kind { classification = true }
                if !calendar.isDate(first.date, inSameDayAs: second.date) { assignment = true }
            }
        }
        return (classification, assignment)
    }

    var rolling24hIsProvisional: Bool { completedRolling24h.isIncomplete }

    var rolling24hMinutes: Int {
        // 24 elapsed hours, including on 23/25-hour daylight-saving calendar days.
        Self.netMinutes(records: records, now: now,
                        window: DateInterval(start: now.addingTimeInterval(-86400), end: now))
    }

    static func netMinutes(records: [SleepRecord], now: Date,
                           window: DateInterval? = nil, kind: SleepKind? = nil, sleepIDs: Set<UUID>? = nil,
                           completedBreaksOnly: Bool = false) -> Int {
        Int(netIntervals(records: records, now: now, window: window, kind: kind, sleepIDs: sleepIDs,
                         completedBreaksOnly: completedBreaksOnly)
            .reduce(0.0) { $0 + $1.duration } / 60)
    }

    // The raw interval primitive also supports legacy evidence validation. For
    // observed durations and recorded subtotals, use the completed projections.
    static func netIntervals(records: [SleepRecord], now: Date,
                             window: DateInterval? = nil, kind: SleepKind? = nil, sleepIDs: Set<UUID>? = nil,
                             completedBreaksOnly: Bool = false) -> [DateInterval] {
        let sleeps = records.filter { $0.kind != .break }
        func interval(_ record: SleepRecord, mayClipUnresolvedParent: Bool = false) -> DateInterval? {
            let end: Date
            if record.isOngoing { end = now }
            else if let observed = record.observedEnd { end = min(observed, now) }
            else if mayClipUnresolvedParent { end = now }
            else { return nil } // Unknown end is not a confirmed zero-length sleep.
            guard end > record.date else { return nil }
            return clip(DateInterval(start: record.date, end: end), to: window)
        }
        let sleepIntervals = union(sleeps.filter { (kind == nil || $0.kind == kind) && (sleepIDs?.contains($0.id) ?? true) }
            .compactMap { interval($0) })
        let parents = Dictionary(sleeps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let awakeIntervals = union(records.filter { $0.kind == .break }.compactMap { awake -> DateInterval? in
            guard !completedBreaksOnly || awake.completedEnd(at: now) != nil,
                  let parentID = awake.parentNapID,
                  let parent = parents[parentID],
                  let parentInterval = interval(parent, mayClipUnresolvedParent: completedBreaksOnly),
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
