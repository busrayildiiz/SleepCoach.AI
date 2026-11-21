//
//  DailyWakeRecord.swift
//  BabySleepTracker
//

import Foundation

struct DailyWakeRecord: Identifiable, Codable {
    let id: UUID
    let day: Date
    let wakeTime: Date
    var persistedRevision: UUID? = nil

    enum CodingKeys: String, CodingKey { case id, day, wakeTime }

    init(id: UUID = UUID(), day: Date, wakeTime: Date) {
        self.id = id
        self.day = day
        self.wakeTime = wakeTime
    }

    func isObserved(on day: Date, at now: Date, calendar: Calendar) -> Bool {
        self.day.timeIntervalSinceReferenceDate.isFinite && wakeTime.timeIntervalSinceReferenceDate.isFinite &&
            wakeTime <= now && calendar.isDate(self.day, inSameDayAs: day) &&
            calendar.isDate(wakeTime, inSameDayAs: day)
    }

    static func uniqueObservation(in records: [Self], on day: Date, at now: Date, calendar: Calendar) -> Self? {
        let candidates = records.filter {
            $0.day.timeIntervalSinceReferenceDate.isFinite && calendar.isDate($0.day, inSameDayAs: day)
        }
        guard candidates.count == 1, let wake = candidates.first, wake.isObserved(on: day, at: now, calendar: calendar)
        else { return nil }
        return wake
    }
}
