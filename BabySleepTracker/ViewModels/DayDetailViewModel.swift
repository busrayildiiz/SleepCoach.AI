//
//  DayDetailViewModel.swift
//  BabySleepTracker
//
//  Created by MacBook on 25.02.2026.
//

import Foundation

struct DayDetailViewModel {

    let records: [SleepRecord]

    var totalMinutes: Int
    
    func totalMinutes(for nap: SleepRecord, in records: [SleepRecord]) -> Int {
        let breaks = records.filter {
            $0.parentNapID == nap.id && $0.kind == .break
        }
        let totalBreak = breaks.reduce(0) { $0 + $1.duration }
        return max(0, nap.duration - totalBreak)    }

    var formattedTotal: String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) h \(minutes)m"
    }
}
