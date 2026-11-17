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
}
