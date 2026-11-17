//
//  SleepMemoryStore.swift
//  BabySleepTracker
//
//  Created by MacBook on 11.06.2026.
//

import Foundation
import UIKit

/// Merkezi depolama yöneticisi - tüm UserDefaults çağrıları buradan geçer
final class SleepMemoryStore {
    static let shared = SleepMemoryStore()

    private let defaults = UserDefaults.standard

    // MARK: - Storage Keys

    private enum Keys: String {
        case sleepRecords     = "sleepRecords"
        case dailyWakeRecords = "dailyWakeRecords_v1"
        case babyName         = "babyName"
        case babyBirthDate    = "babyBirthDate"
        case avatarImageData  = "avatarImageData"
        case overtiredLevel   = "overtiredLevel"
    }

    // MARK: - Sleep Records

    func loadSleepRecords() -> [SleepRecord] {
        SleepRecordPersistence(defaults: defaults).load() ?? []
    }

    func saveSleepRecords(_ records: [SleepRecord]) {
        SleepRecordPersistence(defaults: defaults).save(records)
    }

    // MARK: - Daily Wake Records

    func loadDailyWakeRecords() -> [DailyWakeRecord] {
        DailyWakeRecordPersistence(defaults: defaults).load() ?? []
    }

    func saveDailyWakeRecords(_ records: [DailyWakeRecord]) {
        DailyWakeRecordPersistence(defaults: defaults).save(records)
    }

    // MARK: - Baby Info

    func getBabyName() -> String {
        let value = defaults.string(forKey: Keys.babyName.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Baby" : value
    }

    func setBabyName(_ name: String) {
        defaults.set(name, forKey: Keys.babyName.rawValue)
    }

    func getBabyBirthDate() -> Date? {
        if let saved = defaults.object(forKey: Keys.babyBirthDate.rawValue) as? Date {
            return saved
        } else if let seconds = defaults.object(forKey: Keys.babyBirthDate.rawValue) as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    func setBabyBirthDate(_ date: Date) {
        defaults.set(date, forKey: Keys.babyBirthDate.rawValue)
    }

    // MARK: - Avatar Image

    func loadAvatarImage() -> UIImage? {
        guard let data = defaults.data(forKey: Keys.avatarImageData.rawValue) else { return nil }
        return UIImage(data: data)
    }

    func saveAvatarImage(_ imageData: Data) {
        defaults.set(imageData, forKey: Keys.avatarImageData.rawValue)
    }

    // MARK: - Overtired Level

    func getOvertiredLevel() -> Double {
        defaults.double(forKey: Keys.overtiredLevel.rawValue)
    }

    func setOvertiredLevel(_ level: Double) {
        defaults.set(level, forKey: Keys.overtiredLevel.rawValue)
    }
}
