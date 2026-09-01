import Foundation

struct SleepWakeTimeWorkflowResult {
    let updatedWakeRecords: [DailyWakeRecord]
    let updatedSleepRecords: [SleepRecord]
    let normalizedWakeTime: Date?
    let closedNightRecord: SleepRecord?
    let wakePersistenceSucceeded: Bool
    let sleepPersistenceSucceeded: Bool
}

struct SleepWakeTimeWorkflow {
    let selectedWakeTime: Date
    let now: Date
    let calendar: Calendar
    let wakeRecords: [DailyWakeRecord]
    let sleepRecords: [SleepRecord]
    let wakePersistence: DailyWakeRecordPersistence
    let sleepPersistence: SleepRecordPersistence

    func execute() -> SleepWakeTimeWorkflowResult {
        let today = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.hour, .minute], from: selectedWakeTime)
        guard let wakeTime = calendar.date(
            bySettingHour: components.hour ?? 7,
            minute: components.minute ?? 0,
            second: 0,
            of: today
        ) else {
            return SleepWakeTimeWorkflowResult(
                updatedWakeRecords: wakeRecords,
                updatedSleepRecords: sleepRecords,
                normalizedWakeTime: nil,
                closedNightRecord: nil,
                wakePersistenceSucceeded: false,
                sleepPersistenceSucceeded: false
            )
        }

        var updatedWakeRecords = wakeRecords
        updatedWakeRecords.removeAll { calendar.isDate($0.day, inSameDayAs: today) }
        updatedWakeRecords.append(DailyWakeRecord(day: today, wakeTime: wakeTime))
        let wakeSaved = wakePersistence.save(updatedWakeRecords)

        var updatedSleepRecords = sleepRecords
        var closedNightRecord: SleepRecord?
        var sleepSaved = false

        if let ongoing = sleepRecords
            .filter({ $0.kind == .nightSleep && $0.isOngoing && wakeTime > $0.date })
            .sorted(by: { $0.date > $1.date })
            .first {
            let duration = max(1, Int(wakeTime.timeIntervalSince(ongoing.date) / 60))
            let closed = SleepRecord(
                id: ongoing.id,
                date: ongoing.date,
                duration: min(duration, 12 * 60),
                kind: ongoing.kind,
                parentNapID: ongoing.parentNapID,
                isOngoing: false,
                createdAt: ongoing.createdAt
            )
            closedNightRecord = closed
            if let index = updatedSleepRecords.firstIndex(where: { $0.id == closed.id }) {
                updatedSleepRecords[index] = closed
            } else {
                updatedSleepRecords.append(closed)
            }
            sleepSaved = sleepPersistence.save(updatedSleepRecords)
        }

        return SleepWakeTimeWorkflowResult(
            updatedWakeRecords: updatedWakeRecords,
            updatedSleepRecords: updatedSleepRecords,
            normalizedWakeTime: wakeTime,
            closedNightRecord: closedNightRecord,
            wakePersistenceSucceeded: wakeSaved,
            sleepPersistenceSucceeded: sleepSaved
        )
    }
}
