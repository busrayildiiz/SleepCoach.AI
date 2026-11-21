import Foundation
@testable import BabySleepTracker

// Existing isolated preference fixtures remain test adapters only. Production
// targets cannot pass UserDefaults to the private-data persistence APIs.
extension UserDefaults: PrivateDataStore {}

final class TestPrivateDataStore: PrivateDataStore {
    var isAvailable = true
    var generationToken: UUID? = UUID()
    var failWrites = false
    private(set) var values: [String: Any] = [:]
    private(set) var writeAttempts = 0

    func object(forKey key: String) -> Any? {
        isAvailable ? values[key] : nil
    }

    func set(_ value: Any?, forKey key: String) {
        writeAttempts += 1
        guard isAvailable else { return }
        guard !failWrites else { isAvailable = false; return }
        values[key] = value
    }

    func removeObject(forKey key: String) {
        writeAttempts += 1
        guard isAvailable else { return }
        guard !failWrites else { isAvailable = false; return }
        values.removeValue(forKey: key)
    }
}
