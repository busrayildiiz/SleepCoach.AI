//
//  SleepMemoryStore.swift
//  BabySleepTracker
//
//  Created by MacBook on 11.06.2026.
//

import Foundation
import UIKit

/// Sensitive app data uses the shared protected store.
final class SleepMemoryStore {
    static let shared = SleepMemoryStore()

    private let defaults: any PrivateDataStore

    init(defaults: any PrivateDataStore = SecureDataStore.shared) {
        self.defaults = defaults
    }

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

    @discardableResult
    func saveSleepRecords(_ records: [SleepRecord]) -> Bool {
        SleepRecordPersistence(defaults: defaults).save(records)
    }

    // MARK: - Daily Wake Records

    func loadDailyWakeRecords() -> [DailyWakeRecord] {
        DailyWakeRecordPersistence(defaults: defaults).load() ?? []
    }

    @discardableResult
    func saveDailyWakeRecords(_ records: [DailyWakeRecord]) -> Bool {
        DailyWakeRecordPersistence(defaults: defaults).save(records)
    }

    // MARK: - Baby Info

    func getBabyName() -> String {
        let value = defaults.string(forKey: Keys.babyName.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Baby" : value
    }

    @discardableResult
    func setBabyName(_ name: String) -> Bool {
        guard defaults.isAvailable else { return false }
        defaults.set(name, forKey: Keys.babyName.rawValue)
        return defaults.isAvailable && defaults.string(forKey: Keys.babyName.rawValue) == name
    }

    func getBabyBirthDate() -> Date? {
        if let saved = defaults.object(forKey: Keys.babyBirthDate.rawValue) as? Date {
            return saved
        } else if let seconds = defaults.object(forKey: Keys.babyBirthDate.rawValue) as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    @discardableResult
    func setBabyBirthDate(_ date: Date) -> Bool {
        guard defaults.isAvailable else { return false }
        defaults.set(date, forKey: Keys.babyBirthDate.rawValue)
        return defaults.isAvailable && defaults.object(forKey: Keys.babyBirthDate.rawValue) as? Date == date
    }

    // MARK: - Avatar Image

    func loadAvatarImage() -> UIImage? {
        guard let data = defaults.data(forKey: Keys.avatarImageData.rawValue) else { return nil }
        return UIImage(data: data)
    }

    @discardableResult
    func saveAvatarImage(_ imageData: Data) -> Bool {
        guard defaults.isAvailable else { return false }
        defaults.set(imageData, forKey: Keys.avatarImageData.rawValue)
        return defaults.isAvailable && defaults.data(forKey: Keys.avatarImageData.rawValue) == imageData
    }

    // MARK: - Overtired Level

    func getOvertiredLevel() -> Double {
        defaults.double(forKey: Keys.overtiredLevel.rawValue)
    }

    @discardableResult
    func setOvertiredLevel(_ level: Double) -> Bool {
        guard defaults.isAvailable else { return false }
        defaults.set(level, forKey: Keys.overtiredLevel.rawValue)
        return defaults.isAvailable && defaults.object(forKey: Keys.overtiredLevel.rawValue) as? Double == level
    }
}
