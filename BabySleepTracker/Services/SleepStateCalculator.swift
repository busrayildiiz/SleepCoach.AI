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
        let active = normalizedActiveSleepRecord(activeRecord)
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
            .filter { $0.kind != .break && $0.isOngoing }
            .sorted { $0.date > $1.date }
            .first
    }

    private func normalizedActiveSleepRecord(_ record: SleepRecord?) -> SleepRecord? {
        guard let record else { return nil }
        guard record.kind == .nightSleep,
              record.date > now,
              hasPassedTypicalWakeTime == false else { return record }
        guard calendar.isDate(record.date, inSameDayAs: now) else { return record }
        guard let adjustedDate = calendar.date(byAdding: .day, value: -1, to: record.date) else { return record }
        return SleepRecord(id: record.id, date: adjustedDate, duration: record.duration, kind: record.kind, parentNapID: record.parentNapID, isOngoing: record.isOngoing, createdAt: record.createdAt)
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
