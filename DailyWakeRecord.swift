//
//  DailyWakeRecord.swift
//  BabySleepTracker
//
//  Created by MacBook on 20.06.2026.
//

import Foundation

struct DailyWakeRecord: Identifiable, Codable {
    let id: UUID
    let day: Date
    let wakeTime: Date

    init(id: UUID = UUID(), day: Date, wakeTime: Date) {
        self.id = id
        self.day = day
        self.wakeTime = wakeTime
    }
}

struct SleepGuideline: Codable {
    let minimumDailyMinutes: Int
    let maximumDailyMinutes: Int
    let sourceName: String
    let sourceURL: String
}

protocol PediatricSleepGuidelineProviding {
    func guideline(forAgeMonths ageMonths: Int) -> SleepGuideline
}

protocol WakeWindowBaselineProviding {
    func wakeWindow(forAgeMonths ageMonths: Int) -> ClosedRange<Int>
}

 
