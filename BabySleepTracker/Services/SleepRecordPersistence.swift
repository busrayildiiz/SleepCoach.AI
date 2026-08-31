import Foundation

struct SleepRecordPersistence {
    private let defaults: UserDefaults
    private let key = "sleepRecords"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SleepRecord]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([SleepRecord].self, from: data)
    }

    @discardableResult
    func save(_ records: [SleepRecord]) -> Bool {
        guard let encoded = try? JSONEncoder().encode(records) else { return false }
        defaults.set(encoded, forKey: key)
        NotificationCenter.default.post(name: .sleepRecordsDidChange, object: nil)
        return true
    }
}
