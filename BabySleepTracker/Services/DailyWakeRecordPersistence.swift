import Foundation

struct DailyWakeRecordPersistence {
    private let defaults: UserDefaults
    private let key = "dailyWakeRecords_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [DailyWakeRecord]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([DailyWakeRecord].self, from: data)
    }

    @discardableResult
    func save(_ records: [DailyWakeRecord]) -> Bool {
        guard let encoded = try? JSONEncoder().encode(records) else { return false }
        defaults.set(encoded, forKey: key)
        NotificationCenter.default.post(name: .dailyWakeRecordsDidChange, object: nil)
        return true
    }
}
