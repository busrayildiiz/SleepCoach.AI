import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// A storage boundary shared by observations, profiles, journals and private caches.
/// UserDefaults conforms only in the test target, for isolated legacy fixtures.
protocol PrivateDataStore: AnyObject {
    var isAvailable: Bool { get }
    var generationToken: UUID? { get }
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension PrivateDataStore {
    var isAvailable: Bool { true }
    var generationToken: UUID? { nil }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
}

extension Notification.Name {
    static let secureDataStoreDidChange = Notification.Name("secureDataStoreDidChange")
}

enum SecureStorageFailure: Error, Equatable {
    case locked, keyUnavailable, missingKey, invalidKey, unsupportedVersion
    case corruptData, unavailable, invalidValue, writeFailed, staleOperation

    var message: String {
        switch self {
        case .locked:
            return "Unlock your device to access your private data."
        case .missingKey, .invalidKey, .corruptData, .unsupportedVersion:
            return "Your saved data could not be opened. It has not been replaced. Please try again."
        case .writeFailed, .invalidValue:
            return "Your changes could not be saved. Please try again."
        case .staleOperation:
            return "This edit is no longer active. Please open it again."
        case .keyUnavailable, .unavailable:
            return "Secure storage is temporarily unavailable. Please unlock your device and try again."
        }
    }
}

/// Only ciphertext crosses this boundary. Implementations must replace atomically.
protocol PrivateVaultFiles {
    func read() throws -> Data?
    func replace(with ciphertext: Data) throws
    func delete() throws
}

protocol PrivateVaultKeys {
    func read() throws -> Data?
    /// Returns the stored key, including the winner of a concurrent create.
    func create(_ proposed: Data) throws -> Data
    func delete() throws
}

/// One foreground writer per app container. The existing observation lock still
/// governs multi-step provenance operations; each underlying replacement is atomic.
final class SecureDataStore: PrivateDataStore {
    static let shared = SecureDataStore(
        files: ProtectedVaultFile(directory: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrivateData", isDirectory: true)),
        keys: KeychainVaultKey(service: (Bundle.main.bundleIdentifier ?? "SleepCoachAI") + ".private-data.v1"),
        legacyDefaults: .standard
    )

    private static let header = Data("SCAIPV1\0".utf8)
    private static let authenticatedContext = Data("SleepCoachAI|private-data-vault|schema-1".utf8)
    static let legacyResetMarker = "privateDataDemoReset_v1"

    // Includes abandoned/legacy stores and recovery copies, not just visible rows.
    static let legacySensitiveKeys: Set<String> = [
        "parentName", "babyName", "babyBirthDate", "babyGender", "avatarImageData",
        "typicalWakeHour", "typicalWakeMinute", "typicalBedHour", "typicalBedMinute",
        "sleepRecords", "sleep_records_v1", "dailyWakeRecords_v1", "overtiredLevel",
        "observationProvenance_v1", "observationCreationLedger_v1",
        "nightWakeCompletionPending_v1", "standaloneWakePending_v1",
        "observationProvenanceRecovery_v1", "nightWakeCompletionRecovery_v1",
        "observationRecoveryCleanupPending_v1", "orchestrator_lastGenerated",
        "llm_lastGenerated", "llm_coachMessage", "llm_patternInsight",
        "llm_confidenceNote", "llm_sourceFingerprint", "llm_alert"
    ]

    private let mutex = NSRecursiveLock()
    private let files: any PrivateVaultFiles
    private let keys: any PrivateVaultKeys
    private let legacyDefaults: UserDefaults?
    private var values: [String: Any] = [:]
    private var encryptionKey: SymmetricKey?
    private var failure: SecureStorageFailure? = .unavailable
    private var currentGeneration = UUID()

    init(files: any PrivateVaultFiles, keys: any PrivateVaultKeys, legacyDefaults: UserDefaults? = nil) {
        self.files = files
        self.keys = keys
        self.legacyDefaults = legacyDefaults
        reload()
    }

    var isAvailable: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return failure == nil && encryptionKey != nil
    }

    var failureMessage: String? {
        mutex.lock()
        defer { mutex.unlock() }
        return failure?.message
    }

    var generation: UUID {
        mutex.lock()
        defer { mutex.unlock() }
        return currentGeneration
    }

    var generationToken: UUID? { generation }

    func object(forKey key: String) -> Any? {
        mutex.lock()
        defer { mutex.unlock() }
        guard failure == nil else { return nil }
        return values[key]
    }

    /// These compatibility methods never fall back to unencrypted storage.
    /// Mutation callers must check isAvailable and their persisted receipt.
    func set(_ value: Any?, forKey key: String) {
        do {
            if let value { try write([key: value]) }
            else { try write([:], removing: [key]) }
        } catch { /* write has published an unavailable state; no payload is logged. */ }
    }

    func removeObject(forKey key: String) {
        do { try write([:], removing: [key]) }
        catch { /* See set(_:forKey:). */ }
    }

    /// A profile/photo/consent update either reaches disk in full or reports failure.
    func write(_ updates: [String: Any], removing removedKeys: Set<String> = [],
               ifGeneration expectedGeneration: UUID? = nil) throws {
        mutex.lock()
        if let expectedGeneration, expectedGeneration != currentGeneration {
            mutex.unlock()
            throw SecureStorageFailure.staleOperation
        }
        do {
            guard failure == nil, let encryptionKey else {
                throw failure ?? SecureStorageFailure.unavailable
            }
            var proposed = values
            for key in removedKeys { proposed.removeValue(forKey: key) }
            for (key, value) in updates { proposed[key] = value }
            let ciphertext = try Self.seal(proposed, using: encryptionKey)
            do { try files.replace(with: ciphertext) }
            catch { throw SecureStorageFailure.writeFailed }
            // Do not publish uncommitted values if encryption or disk I/O fails.
            values = proposed
            mutex.unlock()
            announceChange()
        } catch {
            let reason = error as? SecureStorageFailure ?? .unavailable
            becomeUnavailable(reason)
            mutex.unlock()
            announceChange()
            throw reason
        }
    }

    /// Retry is explicit. Corrupt/unreadable ciphertext never creates an empty store.
    func reload() {
        mutex.lock()
        currentGeneration = UUID()
        do {
            let ciphertext = try files.read()
            let rawKey: Data
            if let existing = try keys.read() {
                rawKey = existing
            } else {
                guard ciphertext == nil else { throw SecureStorageFailure.missingKey }
                let proposed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                rawKey = try keys.create(proposed)
            }
            guard rawKey.count == 32 else { throw SecureStorageFailure.invalidKey }
            let key = SymmetricKey(data: rawKey)
            let loaded: [String: Any]
            if let ciphertext {
                loaded = try Self.open(ciphertext, using: key)
            } else {
                loaded = [:]
                try files.replace(with: Self.seal(loaded, using: key))
            }
            values = loaded
            encryptionKey = key
            failure = nil
            discardLegacyDemoValuesIfNeeded()
        } catch {
            becomeUnavailable(error as? SecureStorageFailure ?? .unavailable)
        }
        mutex.unlock()
        announceChange()
    }

    /// Called on background/lock. Swift does not guarantee physical memory zeroing;
    /// this drops the app's retained plaintext and blocks subsequent mutations.
    func lock() {
        mutex.lock()
        currentGeneration = UUID()
        becomeUnavailable(.locked)
        mutex.unlock()
        announceChange()
    }

    /// User-confirmed deletion covers the entire graph, including private caches,
    /// operation journals and avatar. Deleting the vault precedes key deletion so
    /// interruption cannot expose an old graph as a newly initialized profile.
    func eraseAll() throws {
        mutex.lock()
        currentGeneration = UUID()
        do {
            try files.delete()
            try keys.delete()
            let proposed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let rawKey = try keys.create(proposed)
            guard rawKey.count == 32 else { throw SecureStorageFailure.invalidKey }
            let key = SymmetricKey(data: rawKey)
            try files.replace(with: Self.seal([:], using: key))
            values = [:]
            encryptionKey = key
            failure = nil
            mutex.unlock()
            announceChange()
        } catch {
            let reason = error as? SecureStorageFailure ?? .unavailable
            becomeUnavailable(reason)
            mutex.unlock()
            announceChange()
            throw reason
        }
    }

    private func becomeUnavailable(_ reason: SecureStorageFailure) {
        values.removeAll()
        encryptionKey = nil
        failure = reason
    }

    private func discardLegacyDemoValuesIfNeeded() {
        guard let defaults = legacyDefaults, !defaults.bool(forKey: Self.legacyResetMarker) else { return }
        for key in Self.legacySensitiveKeys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: "cloudAISharingEnabled")
        // A missing marker after an interrupted launch must never reset a new profile.
        if values.isEmpty {
            defaults.removeObject(forKey: "authComplete")
            defaults.removeObject(forKey: "onboardingComplete")
        }
        defaults.set(true, forKey: Self.legacyResetMarker)
    }

    private func announceChange() {
        NotificationCenter.default.post(name: .secureDataStoreDidChange, object: self)
    }

    private static func seal(_ values: [String: Any], using key: SymmetricKey) throws -> Data {
        guard PropertyListSerialization.propertyList(values, isValidFor: .binary) else {
            throw SecureStorageFailure.invalidValue
        }
        let plaintext = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        // CryptoKit chooses a fresh random nonce for every replacement.
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedContext)
        guard let combined = box.combined else { throw SecureStorageFailure.writeFailed }
        return header + combined
    }

    private static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> [String: Any] {
        guard ciphertext.starts(with: header) else { throw SecureStorageFailure.unsupportedVersion }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(ciphertext.dropFirst(header.count)))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: authenticatedContext)
            guard let values = try PropertyListSerialization.propertyList(
                from: plaintext, options: [], format: nil) as? [String: Any] else {
                throw SecureStorageFailure.corruptData
            }
            return values
        } catch { throw SecureStorageFailure.corruptData }
    }
}

/// User-created records remain eligible for encrypted device backups. The Keychain
/// key uses WhenUnlocked (not ThisDeviceOnly), so backup restores are not knowingly
/// paired with a non-migrating key. This is not a cloud sync implementation.
struct ProtectedVaultFile: PrivateVaultFiles {
    let directory: URL?
    private let fileManager: FileManager
    private let writeData: (Data, URL, Data.WritingOptions) throws -> Void
    private var url: URL? { directory?.appendingPathComponent("private-data-v1.bin") }

    init(directory: URL?, fileManager: FileManager = .default,
         writeData: @escaping (Data, URL, Data.WritingOptions) throws -> Void = {
             try $0.write(to: $1, options: $2)
         }) {
        self.directory = directory
        self.fileManager = fileManager
        self.writeData = writeData
    }

    func read() throws -> Data? {
        guard let url else { throw SecureStorageFailure.unavailable }
        do { return try Data(contentsOf: url) }
        catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code) { return nil }
            throw SecureStorageFailure.unavailable
        }
    }

    func replace(with ciphertext: Data) throws {
        guard let directory, let url else { throw SecureStorageFailure.unavailable }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try fileManager.setAttributes(attributes, ofItemAtPath: directory.path)
        try writeData(ciphertext, url, [.atomic, .completeFileProtection])
        #else
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try writeData(ciphertext, url, .atomic)
        #endif
    }

    func delete() throws {
        guard let url else { throw SecureStorageFailure.unavailable }
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code) else { throw error }
        }
    }
}

struct KeychainVaultKey: PrivateVaultKeys {
    let service: String
    private let account = "private-data-encryption-key"

    func read() throws -> Data? {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw mapped(status) }
        guard let data = item as? Data else { throw SecureStorageFailure.invalidKey }
        return data
        #else
        throw SecureStorageFailure.keyUnavailable
        #endif
    }

    func create(_ proposed: Data) throws -> Data {
        #if canImport(Security)
        var query = baseQuery
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData as String] = proposed
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try read() else { throw SecureStorageFailure.keyUnavailable }
            return existing
        }
        guard status == errSecSuccess else { throw mapped(status) }
        return proposed
        #else
        throw SecureStorageFailure.keyUnavailable
        #endif
    }

    func delete() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw mapped(status) }
        #else
        throw SecureStorageFailure.keyUnavailable
        #endif
    }

    #if canImport(Security)
    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func mapped(_ status: OSStatus) -> SecureStorageFailure {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed ? .locked : .keyUnavailable
    }
    #endif
}
