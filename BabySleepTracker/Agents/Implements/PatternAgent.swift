//
//  PatternAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 12.06.2026.
//
import Foundation

// MARK: - Supporting Enums

enum Trend {
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

    private let calendar = Calendar.current

    func analyze(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths: Int,
        now: Date
    ) -> BabyPattern {

        let breaks  = records.filter { $0.kind == .break }
        let dayNaps = records.filter { $0.kind == .dayNap }.sorted { $0.date < $1.date }
        let nights  = records.filter { $0.kind == .nightSleep }.sorted { $0.date < $1.date }

        let sampleSize  = trackedDayCount(records: records, wakeRecords: wakeRecords)

        let wakeWindows    = extractWakeWindows(dayNaps: dayNaps, wakeRecords: wakeRecords)
        let avgWakeWindow  = median(wakeWindows)

        let napDurations   = dayNaps.map { $0.totalMinutes(breaks: breaks) }.filter { $0 > 0 }
        let avgNapDuration = average(napDurations)

        let (bestHour, bestExtra) = bestNapHour(
            dayNaps: dayNaps,
            breaks: breaks,
            overall: avgNapDuration
        )

        let napCount = averageNapCount(dayNaps: dayNaps)

        let nightDurations = nights.map { $0.totalMinutes(breaks: breaks) }.filter { $0 > 0 }
        let avgNight       = average(nightDurations)

        let bedtimeShift = estimateBedtimeShift(
            dayNaps: dayNaps,
            nights: nights,
            breaks: breaks,
            overallAvgNap: avgNapDuration
        )

        let wwTrend  = trend(for: recentVsOlder(values: wakeWindows))
        let napTrend = trend(for: recentVsOlder(values: napDurations))

        let wow = weekOverWeekChange(dayNaps: dayNaps, breaks: breaks, now: now)
        let quality = dataQuality(sampleSize: sampleSize)

        return BabyPattern(
            averageWakeWindowMinutes:       avgWakeWindow,
            bestFirstNapHour:               bestHour,
            bestNapExtraMinutes:            bestExtra,
            averageNapDurationMinutes:      avgNapDuration,
            napCountPerDay:                 napCount,
            averageNightSleepMinutes:       avgNight,
            estimatedBedtimeShiftMinutes:   bedtimeShift,
            wakingWindowTrend:              wwTrend,
            napDurationTrend:               napTrend,
            sampleSize:                     sampleSize,
            dataQuality:                    quality,
            weekOverWeekNapChange:          wow
        )
    }

    // MARK: - Data Quality

    private func dataQuality(sampleSize: Int) -> DataQuality {
        switch sampleSize {
        case 0...3:  return .poor
        case 4...7:  return .fair
        case 8...13: return .good
        default:      return .excellent
        }
    }

    // MARK: - Wake Windows

    private func extractWakeWindows(
        dayNaps: [SleepRecord],
        wakeRecords: [DailyWakeRecord]
    ) -> [Int] {
        var windows: [Int] = []

        for nap in dayNaps {
            let dayStart = calendar.startOfDay(for: nap.date)

            let previousNap = dayNaps.last {
                $0.date < nap.date &&
                calendar.isDate($0.date, inSameDayAs: nap.date)
            }

            let anchor: Date?
            if let prev = previousNap {
                anchor = calendar.date(
                    byAdding: .minute,
                    value: prev.duration,
                    to: prev.date
                )
            } else {
                anchor = wakeRecords.first {
                    calendar.isDate($0.day, inSameDayAs: dayStart) &&
                    $0.wakeTime <= nap.date
                }?.wakeTime
            }

            guard let anchor else { continue }
            let minutes = Int(nap.date.timeIntervalSince(anchor) / 60)
            if (30...600).contains(minutes) {
                windows.append(minutes)
            }
        }
        return windows
    }

    // MARK: - Best Nap Hour

    private func bestNapHour(
        dayNaps: [SleepRecord],
        breaks: [SleepRecord],
        overall: Int?
    ) -> (hour: Int?, extraMinutes: Int?) {
        guard !dayNaps.isEmpty else { return (nil, nil) }

        let byHour = Dictionary(grouping: dayNaps) {
            calendar.component(.hour, from: $0.date)
        }
        let hourAverages = byHour.mapValues { naps -> Int in
            let durations = naps.map { $0.totalMinutes(breaks: breaks) }
            return durations.reduce(0, +) / max(durations.count, 1)
        }
        guard let best = hourAverages.max(by: { $0.value < $1.value }) else {
            return (nil, nil)
        }
        let extra = overall.map { max(0, best.value - $0) }
        return (best.key, extra)
    }

    // MARK: - Average Nap Count

    private func averageNapCount(dayNaps: [SleepRecord]) -> Double? {
        guard !dayNaps.isEmpty else { return nil }
        let byDay = Dictionary(grouping: dayNaps) {
            calendar.startOfDay(for: $0.date)
        }
        let total = byDay.values.map { $0.count }.reduce(0, +)
        return Double(total) / Double(byDay.count)
    }

    // MARK: - Bedtime Shift

    private func estimateBedtimeShift(
        dayNaps: [SleepRecord],
        nights: [SleepRecord],
        breaks: [SleepRecord],
        overallAvgNap: Int?
    ) -> Int? {
        guard let avgNap = overallAvgNap, !nights.isEmpty else { return nil }

        var longDayBedtimes: [Int] = []
        var normalDayBedtimes: [Int] = []

        for night in nights {
            let napsThisDay = dayNaps.filter {
                calendar.isDate($0.date, inSameDayAs: night.date)
            }
            guard !napsThisDay.isEmpty else { continue }

            let totalDaySleep = napsThisDay
                .map { $0.totalMinutes(breaks: breaks) }
                .reduce(0, +)

            let bedtimeMinute =
                calendar.component(.hour,   from: night.date) * 60 +
                calendar.component(.minute, from: night.date)

            if totalDaySleep > avgNap + 30 {
                longDayBedtimes.append(bedtimeMinute)
            } else {
                normalDayBedtimes.append(bedtimeMinute)
            }
        }

        guard let longAvg   = average(longDayBedtimes),
              let normalAvg = average(normalDayBedtimes)
        else { return nil }

        return max(0, longAvg - normalAvg)
    }

    // MARK: - Week Over Week

    private func weekOverWeekChange(
        dayNaps: [SleepRecord],
        breaks: [SleepRecord],
        now: Date
    ) -> Int? {
        guard let thisStart = calendar.date(byAdding: .day, value: -7,  to: now),
              let lastStart = calendar.date(byAdding: .day, value: -14, to: now)
        else { return nil }

        let thisWeek = dayNaps
            .filter { $0.date >= thisStart && $0.date < now }
            .map { $0.totalMinutes(breaks: breaks) }

        let lastWeek = dayNaps
            .filter { $0.date >= lastStart && $0.date < thisStart }
            .map { $0.totalMinutes(breaks: breaks) }

        guard let thisAvg = average(thisWeek),
              let lastAvg = average(lastWeek)
        else { return nil }

        return thisAvg - lastAvg
    }

    // MARK: - Trend

    private func recentVsOlder(values: [Int]) -> Double? {
        guard values.count >= 4 else { return nil }
        let half   = values.count / 2
        let older  = Array(values.prefix(half))
        let recent = Array(values.suffix(half))
        guard let oldAvg = average(older),
              let newAvg = average(recent)
        else { return nil }
        return Double(newAvg - oldAvg)
    }

    private func trend(for delta: Double?) -> Trend {
        guard let delta else { return .insufficient }
        if delta >  10 { return .increasing }
        if delta < -10 { return .decreasing }
        return .stable
    }

 

    // MARK: - Tracked Day Count

    private func trackedDayCount(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord]
    ) -> Int {
        let sleepDays = records.map { calendar.startOfDay(for: $0.date) }
        let wakeDays  = wakeRecords.map { calendar.startOfDay(for: $0.day) }
        return Set(sleepDays + wakeDays).count
    }

    // MARK: - Math Helpers

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid    = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
}
