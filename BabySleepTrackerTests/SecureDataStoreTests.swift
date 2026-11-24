import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import BabySleepTracker

final class SecureDataStoreTests: XCTestCase {
    private func makeStore(_ files: VaultTestFiles = VaultTestFiles(), _ keys: VaultTestKeys = VaultTestKeys(),
                           defaults: UserDefaults? = nil) -> SecureDataStore {
        SecureDataStore(files: files, keys: keys, legacyDefaults: defaults)
    }

    func testProfileRecordsPhotoAndJournalsRoundTripWithoutPlaintextOnDisk() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        let birth = Date(timeIntervalSince1970: 1_700_000_000)
        let records = Data("[{\"privateSleepObservation\":\"night\"}]".utf8)
        let photo = Data([0xff, 0xd8, 0xff]) + Data("private-photo-pixels".utf8)
        try store.write(["babyName": "Private Demo Child", "parentName": "Private Parent",
                         "babyBirthDate": birth, "babyGender": "Girl", "avatarImageData": photo,
                         "sleepRecords": records, "observationProvenance_v1": records,
                         "nightWakeCompletionPending_v1": records, "typicalWakeHour": 7.5])

        let disk = try XCTUnwrap(files.ciphertext)
        for privateBytes in [Data("Private Demo Child".utf8), Data("Private Parent".utf8), records, photo] {
            XCTAssertNil(disk.range(of: privateBytes))
        }
        let reopened = makeStore(files, keys)
        XCTAssertTrue(reopened.isAvailable)
        XCTAssertEqual(reopened.string(forKey: "babyName"), "Private Demo Child")
        XCTAssertEqual(reopened.object(forKey: "babyBirthDate") as? Date, birth)
        XCTAssertEqual(reopened.string(forKey: "babyGender"), "Girl")
        XCTAssertEqual(reopened.data(forKey: "avatarImageData"), photo)
        XCTAssertEqual(reopened.data(forKey: "sleepRecords"), records)
        XCTAssertEqual(reopened.data(forKey: "observationProvenance_v1"), records)
        XCTAssertEqual(reopened.data(forKey: "nightWakeCompletionPending_v1"), records)
        XCTAssertEqual(reopened.double(forKey: "typicalWakeHour"), 7.5)
        XCTAssertEqual(keys.value?.count, 32)
    }

    func testRepeatedPlaintextUsesFreshCiphertext() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Same Value"])
        let first = files.ciphertext
        try store.write(["babyName": "Same Value"])
        XCTAssertNotEqual(files.ciphertext, first)
        XCTAssertEqual(makeStore(files, keys).string(forKey: "babyName"), "Same Value")
    }

    func testTamperingBlocksReadsAndWritesWithoutReplacingEvidence() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Keep"])
        var damaged = try XCTUnwrap(files.ciphertext)
        damaged[damaged.count - 1] ^= 1
        files.ciphertext = damaged
        let creates = keys.creates

        store.reload()
        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(store.string(forKey: "babyName"))
        XCTAssertThrowsError(try store.write(["babyName": "Replacement"]))
        XCTAssertEqual(files.ciphertext, damaged)
        XCTAssertEqual(keys.creates, creates)
    }

    func testWrongKeyDoesNotOverwriteCiphertext() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["sleepRecords": Data("private record".utf8)])
        let disk = files.ciphertext
        keys.value = Data(repeating: 9, count: 32)
        store.reload()
        XCTAssertFalse(store.isAvailable)
        store.removeObject(forKey: "sleepRecords")
        XCTAssertEqual(files.ciphertext, disk)
    }

    func testCiphertextFromAnotherContextIsRejected() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        _ = makeStore(files, keys)
        let key = SymmetricKey(data: try XCTUnwrap(keys.value))
        let body = try PropertyListSerialization.data(fromPropertyList: ["babyName": "Swap"], format: .binary, options: 0)
        let box = try AES.GCM.seal(body, using: key, authenticating: Data("another-vault".utf8))
        files.ciphertext = Data("SCAIPV1\0".utf8) + (try XCTUnwrap(box.combined))
        let disk = files.ciphertext

        XCTAssertFalse(makeStore(files, keys).isAvailable)
        XCTAssertEqual(files.ciphertext, disk)
    }

    func testUnsupportedVersionFailsClosed() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        _ = makeStore(files, keys)
        var unknown = try XCTUnwrap(files.ciphertext)
        unknown[6] = Character("2").asciiValue!
        files.ciphertext = unknown

        XCTAssertFalse(makeStore(files, keys).isAvailable)
        XCTAssertEqual(files.ciphertext, unknown)
    }

    func testMissingKeyForExistingVaultNeverGeneratesReplacement() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Existing"])
        let disk = files.ciphertext, creates = keys.creates
        keys.value = nil
        store.reload()

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(keys.creates, creates)
        XCTAssertNil(keys.value)
        XCTAssertEqual(files.ciphertext, disk)
    }

    func testUnavailableKeyDoesNotCreateKeyOrEmptyFile() {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        keys.readError = .locked
        let store = makeStore(files, keys)

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(keys.creates, 0)
        XCTAssertNil(files.ciphertext)
    }

    func testInvalidStoredKeyIsNotSilentlyReplaced() {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        keys.value = Data(repeating: 4, count: 16)
        XCTAssertFalse(makeStore(files, keys).isAvailable)
        XCTAssertEqual(keys.creates, 0)
        XCTAssertNil(files.ciphertext)
    }

    func testUnreadableFileIsNotTreatedAsFirstLaunch() {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        files.readError = true
        let store = makeStore(files, keys)

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(keys.creates, 0)
        XCTAssertEqual(files.replacements, 0)
    }

    func testDiskFailureRetainsCommittedStateAndRequiresRetry() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Saved", "babyGender": "Girl"])
        let disk = files.ciphertext
        files.failWrites = true

        XCTAssertThrowsError(try store.write(["babyName": "Unsaved", "babyGender": "Boy"]))
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(files.ciphertext, disk)
        files.failWrites = false
        store.reload()
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.string(forKey: "babyName"), "Saved")
        XCTAssertEqual(store.string(forKey: "babyGender"), "Girl")
    }

    func testInvalidPayloadNeverReachesDiskOrPartiallyUpdatesProfile() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Saved"])
        let disk = files.ciphertext
        XCTAssertThrowsError(try store.write(["babyName": "Unsaved", "invalid": URL(string: "https://example.test")!]))
        XCTAssertEqual(files.ciphertext, disk)
        store.reload()
        XCTAssertEqual(store.string(forKey: "babyName"), "Saved")
    }

    func testLockDropsPlaintextAndRejectsMutationUntilReload() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Saved"])
        let disk = files.ciphertext, generation = store.generation
        store.lock()

        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(store.object(forKey: "babyName"))
        XCTAssertNotEqual(store.generation, generation)
        store.set("Unsaved", forKey: "babyName")
        XCTAssertEqual(files.ciphertext, disk)
        store.reload()
        XCTAssertEqual(store.string(forKey: "babyName"), "Saved")
    }

    func testDelayedPhotoCannotReappearAfterDeletion() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        let importGeneration = store.generation
        try store.eraseAll()
        let disk = files.ciphertext

        XCTAssertThrowsError(try store.write(["avatarImageData": Data("old photo".utf8)], ifGeneration: importGeneration)) {
            XCTAssertEqual($0 as? SecureStorageFailure, .staleOperation)
        }
        XCTAssertTrue(store.isAvailable, "Rejecting stale work must not disable the newly empty store.")
        XCTAssertNil(store.data(forKey: "avatarImageData"))
        XCTAssertEqual(files.ciphertext, disk)
    }

    func testLegacyDemoResetIsScopedAndDoesNotRepeat() throws {
        let suite = "SecureDataStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in SecureDataStore.legacySensitiveKeys { defaults.set("old private demo", forKey: key) }
        defaults.set("dark", forKey: "appAppearance")
        defaults.set(true, forKey: "napReminders")
        defaults.set(true, forKey: "authComplete")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(true, forKey: "cloudAISharingEnabled")
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys, defaults: defaults)

        for key in SecureDataStore.legacySensitiveKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")
        XCTAssertTrue(defaults.bool(forKey: "napReminders"))
        XCTAssertFalse(defaults.bool(forKey: "authComplete"))
        XCTAssertFalse(defaults.bool(forKey: "cloudAISharingEnabled"))
        XCTAssertTrue(defaults.bool(forKey: SecureDataStore.legacyResetMarker))
        XCTAssertNil(store.object(forKey: "babyName"), "Demo data is intentionally discarded, not migrated.")

        try store.write(["babyName": "New Profile", "profileSetupComplete_v1": true])
        defaults.set(true, forKey: "authComplete")
        let reopened = makeStore(files, keys, defaults: defaults)
        XCTAssertEqual(reopened.string(forKey: "babyName"), "New Profile")
        XCTAssertTrue(defaults.bool(forKey: "authComplete"))
    }

    func testMissingResetMarkerDoesNotEraseNewSecureProfile() throws {
        let suite = "SecureDataStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys, defaults: defaults)
        try store.write(["babyName": "New Profile"])
        defaults.set(true, forKey: "authComplete")
        defaults.removeObject(forKey: SecureDataStore.legacyResetMarker)

        let reopened = makeStore(files, keys, defaults: defaults)
        XCTAssertEqual(reopened.string(forKey: "babyName"), "New Profile")
        XCTAssertTrue(defaults.bool(forKey: "authComplete"))
    }

    func testFailedBootstrapDoesNotDeleteLegacyDataOrMarkResetComplete() throws {
        let suite = "SecureDataStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old private demo", forKey: "babyName")
        let files = VaultTestFiles(), keys = VaultTestKeys()
        keys.readError = .locked
        _ = makeStore(files, keys, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "babyName"), "old private demo")
        XCTAssertFalse(defaults.bool(forKey: SecureDataStore.legacyResetMarker))
    }

    func testCompleteDeletionRemovesGraphAndRotatesKey() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        var privateGraph: [String: Any] = [:]
        for key in SecureDataStore.legacySensitiveKeys { privateGraph[key] = "private graph" }
        privateGraph["cloudAIConsent_v1"] = ["receiptID": UUID().uuidString]
        privateGraph["profileSetupComplete_v1"] = true
        try store.write(privateGraph)
        let oldKey = keys.value
        try store.eraseAll()

        XCTAssertTrue(store.isAvailable)
        XCTAssertNotEqual(keys.value, oldKey)
        let reopened = makeStore(files, keys)
        for key in privateGraph.keys { XCTAssertNil(reopened.object(forKey: key), key) }
        XCTAssertEqual(files.deletions, 1)
        XCTAssertEqual(keys.deletions, 1)
    }

    func testFailedDeletionDoesNotClaimSuccessOrExposeData() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Retained until retry"])
        let disk = files.ciphertext
        files.failDeletes = true

        XCTAssertThrowsError(try store.eraseAll())
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(files.ciphertext, disk)
        XCTAssertEqual(keys.deletions, 0)
        files.failDeletes = false
        try store.eraseAll()
        XCTAssertTrue(store.isAvailable)
        XCTAssertNil(store.object(forKey: "babyName"))
    }

    func testConcurrentWritesKeepEveryCommittedField() {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            store.set(index, forKey: "record-\(index)")
        }
        let reopened = makeStore(files, keys)
        for index in 0..<24 { XCTAssertEqual(reopened.object(forKey: "record-\(index)") as? Int, index) }
    }

    func testKeyDeletionFailureRemainsUnavailableUntilExplicitDeletionRetry() throws {
        let files = VaultTestFiles(), keys = VaultTestKeys()
        let store = makeStore(files, keys)
        try store.write(["babyName": "Delete Me"])
        let oldKey = keys.value
        keys.failDeletes = true

        XCTAssertThrowsError(try store.eraseAll())
        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(files.ciphertext, "The private graph was removed before the Keychain failure.")
        XCTAssertEqual(keys.value, oldKey)
        keys.failDeletes = false
        try store.eraseAll()
        XCTAssertTrue(store.isAvailable)
        XCTAssertNotEqual(keys.value, oldKey)
        XCTAssertNil(makeStore(files, keys).object(forKey: "babyName"))
    }

    func testRealFileBackendPersistsOnlyEncryptedVault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ProtectedVaultFile(directory: directory), keys = VaultTestKeys()
        let store = SecureDataStore(files: files, keys: keys)
        try store.write(["babyName": "Never in a plaintext file"])

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries, ["private-data-v1.bin"])
        let disk = try XCTUnwrap(files.read())
        XCTAssertNil(disk.range(of: Data("Never in a plaintext file".utf8)))
        XCTAssertEqual(SecureDataStore(files: files, keys: keys).string(forKey: "babyName"), "Never in a plaintext file")
    }
}

private final class VaultTestFiles: PrivateVaultFiles {
    var ciphertext: Data?
    var readError = false
    var failWrites = false
    var failDeletes = false
    var replacements = 0
    var deletions = 0
    func read() throws -> Data? {
        if readError { throw SecureStorageFailure.unavailable }
        return ciphertext
    }
    func replace(with ciphertext: Data) throws {
        if failWrites { throw SecureStorageFailure.writeFailed }
        replacements += 1
        self.ciphertext = ciphertext
    }
    func delete() throws {
        if failDeletes { throw SecureStorageFailure.unavailable }
        deletions += 1
        ciphertext = nil
    }
}

private final class VaultTestKeys: PrivateVaultKeys {
    var value: Data?
    var readError: SecureStorageFailure?
    var creates = 0
    var deletions = 0
    var failDeletes = false
    func read() throws -> Data? {
        if let readError { throw readError }
        return value
    }
    func create(_ proposed: Data) throws -> Data {
        creates += 1
        if let value { return value }
        value = proposed
        return proposed
    }
    func delete() throws {
        if failDeletes { throw SecureStorageFailure.keyUnavailable }
        deletions += 1
        value = nil
    }
}
