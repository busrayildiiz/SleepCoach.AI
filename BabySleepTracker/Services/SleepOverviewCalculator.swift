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
}

struct SleepOverviewCalculator {
    private let records: [SleepRecord]
    private let now: Date
    private let calendar: Calendar

    init(records: [SleepRecord], now: Date = Date(), calendar: Calendar = .current) {
        self.records = records
        self.now = now
        self.calendar = calendar
    }

    func calculate() -> SleepOverviewMetrics {
        let today = calendar.startOfDay(for: now)
        let todayRecords = records.filter { calendar.isDate($0.date, inSameDayAs: today) }
        let todayTotal = totalMinutes(for: todayRecords)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let yesterdayTotal = yesterday.map { yesterdayDate in
            totalMinutes(for: records.filter { record in
                calendar.isDate(record.date, inSameDayAs: yesterdayDate)
            })
        } ?? 0
        let sleeps = records.filter { $0.kind != .break }.sorted { $0.date > $1.date }
        let breaks = records.filter { $0.kind == .break }
        let latestSleepMinutes = sleeps.first?.totalMinutes(breaks: breaks) ?? 95
        let comparable = sleeps.dropFirst().map { $0.totalMinutes(breaks: breaks) }
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
            todayGoalProgress: min(Double(todayTotal) / 840.0, 1.0)
        )
    }

    private func totalMinutes(for items: [SleepRecord]) -> Int {
        let naps = items.filter { $0.kind != .break }
        let breaks = items.filter { $0.kind == .break }
        return naps.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
    }

    private func average(forOffsets offsets: Range<Int>, today: Date) -> Int {
        let totals = offsets.map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return totalMinutes(for: records.filter { calendar.isDate($0.date, inSameDayAs: day) })
        }
        return totals.reduce(0, +) / max(totals.count, 1)
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
