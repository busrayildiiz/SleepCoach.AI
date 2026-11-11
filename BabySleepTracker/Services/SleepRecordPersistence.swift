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

    /// Re-read before saving so a presented form cannot overwrite newer records.
    /// Break validation uses the latest parent, not a stale sheet snapshot.
    @discardableResult
    func saveRecording(_ record: SleepRecord, now: Date = Date()) -> Bool {
        if defaults.data(forKey: key) != nil && load() == nil { return false }
        var records = load() ?? []
        if record.kind == .break {
            guard let parent = records.first(where: { $0.id == record.parentNapID }),
                  let end = record.observedEnd else { return false }
            var draft = AwakeBreakDraft(parent: parent, now: now)
            draft.start = record.date
            draft.end = end
            guard draft.validationMessage(existing: records.filter { $0.id != record.id }, now: now) == nil else {
                return false
            }
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        return save(records)
    }

    @discardableResult
    func save(_ records: [SleepRecord]) -> Bool {
        guard let encoded = try? JSONEncoder().encode(records) else { return false }
        defaults.set(encoded, forKey: key)
        NotificationCenter.default.post(name: .sleepRecordsDidChange, object: nil)
        return true
    }
}
