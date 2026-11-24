import Foundation

protocol SleepStoring {
    func load() throws -> [SleepRecord]
    func save(_ records: [SleepRecord]) throws
}

enum SleepStoreError: Error {
    case decodingFailed
    case encodingFailed
    case storageUnavailable
    case writeFailed
}

final class SleepStore: SleepStoring {
    private let key = "sleep_records_v1"
    private let defaults: any PrivateDataStore

    init(defaults: any PrivateDataStore = SecureDataStore.shared) {
        self.defaults = defaults
    }

    func load() throws -> [SleepRecord] {
        guard defaults.isAvailable else { throw SleepStoreError.storageUnavailable }
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([SleepRecord].self, from: data)
        } catch {
            throw SleepStoreError.decodingFailed
        }
    }

    func save(_ records: [SleepRecord]) throws {
        guard defaults.isAvailable else { throw SleepStoreError.storageUnavailable }
        let data: Data
        do {
            data = try JSONEncoder().encode(records)
        } catch {
            throw SleepStoreError.encodingFailed
        }
        defaults.set(data, forKey: key)
        guard defaults.isAvailable, defaults.data(forKey: key) == data else { throw SleepStoreError.writeFailed }
    }
}
