//
//  PatternAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 12.06.2026.
//
import Foundation

// MARK: - Supporting Enums

enum Trend: Equatable {
    case increasing
    case stable
    case decreasing
    case insufficient
}



// MARK: - BabyPattern

struct BabyPattern {
    let averageWakeWindowMinutes: Int?
    let bestFirstNapHour: Int?
    let bestNapExtraMinutes: Int?
    let averageNapDurationMinutes: Int?
    let napCountPerDay: Double?
    let averageNightSleepMinutes: Int?
    let estimatedBedtimeShiftMinutes: Int?
    let wakingWindowTrend: Trend
    let napDurationTrend: Trend
    let sampleSize: Int
    let dataQuality: DataQuality
    let weekOverWeekNapChange: Int?
}
// MARK: - DefaultPatternAgent

final class PatternAgent: PatternAgentProtocol {
    private let calendar: Calendar

    init(calendar: Calendar = .current) { self.calendar = calendar }

    func analyze(records: [SleepRecord], wakeRecords: [DailyWakeRecord], ageMonths: Int, now: Date) -> BabyPattern {
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        let samples = records.compactMap { record -> (record: SleepRecord, minutes: Int)? in
            guard record.kind != .break, let minutes = accounting.completedMinutes(sleepIDs: [record.id]) else { return nil }
            return (record, minutes)
        }
        let naps = samples.filter { $0.record.kind == .dayNap }
        let nights = samples.filter { $0.record.kind == .nightSleep }
        let days = Set(samples.map { calendar.startOfDay(for: $0.record.date) })
        let wakeWindows = extractWakeWindows(naps: naps.map(\.record), wakeRecords: wakeRecords, accounting: accounting)

        // The individual samples describe recorded sessions. They do not measure
        // the child's complete day or establish a reliable personal trend.
        return BabyPattern(averageWakeWindowMinutes: median(wakeWindows), bestFirstNapHour: nil,
            bestNapExtraMinutes: nil, averageNapDurationMinutes: average(naps.map(\.minutes)), napCountPerDay: nil,
            averageNightSleepMinutes: average(nights.map(\.minutes)), estimatedBedtimeShiftMinutes: nil,
            wakingWindowTrend: .insufficient, napDurationTrend: .insufficient, sampleSize: days.count,
            dataQuality: .poor, weekOverWeekNapChange: nil)
    }

    private func extractWakeWindows(naps: [SleepRecord], wakeRecords: [DailyWakeRecord], accounting: SleepAccounting) -> [Int] {
        naps.compactMap { nap in
            let wake = DailyWakeRecord.uniqueObservation(in: wakeRecords, on: nap.date, at: nap.date, calendar: calendar)?.wakeTime
            let previousEnd = accounting.records.compactMap { record -> Date? in
                guard record.kind == .dayNap, record.date < nap.date,
                      let end = record.completedEnd(at: nap.date), calendar.isDate(end, inSameDayAs: nap.date) else { return nil }
                return end
            }.max()
            guard let anchor = [wake, previousEnd].compactMap({ $0 }).max(),
                  let gap = accounting.recordedAwakeMinutes(from: anchor, until: nap.date),
                  (30...600).contains(gap) else { return nil }
            return gap
        }
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
}
