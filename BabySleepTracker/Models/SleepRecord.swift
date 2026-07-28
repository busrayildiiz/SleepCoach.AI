//
//  SleepRecord.swift
//  SleepTracker
//

import Foundation

struct SleepRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let duration: Int
    let kind: SleepKind
    let parentNapID: UUID?
    let isOngoing: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        duration: Int,
        kind: SleepKind = .dayNap,
        parentNapID: UUID? = nil,
        isOngoing: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.kind = kind
        self.parentNapID = parentNapID
        self.isOngoing = isOngoing
        self.createdAt = createdAt
    }

    // Eski kayıtlarda isOngoing/createdAt alanı yok — geriye dönük uyumluluk için
    enum CodingKeys: String, CodingKey {
        case id, date, duration, kind, parentNapID, isOngoing, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        date        = try c.decode(Date.self, forKey: .date)
        duration    = try c.decode(Int.self, forKey: .duration)
        kind        = try c.decode(SleepKind.self, forKey: .kind)
        parentNapID = try c.decodeIfPresent(UUID.self, forKey: .parentNapID)
        isOngoing   = try c.decodeIfPresent(Bool.self, forKey: .isOngoing) ?? false
        createdAt   = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? date
    }

    /// Devam eden uyku için canlı süre, bitmiş uyku için kayıtlı süre
    var effectiveDuration: Int {
        isOngoing ? max(0, Int(Date().timeIntervalSince(date) / 60)) : duration
    }

    func totalMinutes(breaks: [SleepRecord]) -> Int {
        let totalBreak = breaks
            .filter { $0.parentNapID == self.id && $0.kind == .break }
            .reduce(0) { $0 + $1.duration }
        return max(0, effectiveDuration - totalBreak)
    }

    var formattedDuration: String {
        let m = effectiveDuration
        let hours = m / 60
        let minutes = m % 60
        return "\(hours) h \(minutes)m"
    }

    var displayDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
