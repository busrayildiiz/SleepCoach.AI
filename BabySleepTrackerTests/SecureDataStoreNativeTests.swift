import Foundation
import XCTest
import Security
@testable import BabySleepTracker

/// These tests require the hosted iOS XCTest target. Portable crypto tests do not
/// establish real Keychain entitlements or iOS file-protection behavior.
final class SecureDataStoreNativeTests: XCTestCase {
    func testRealKeychainRoundTripDuplicateCreateAndDeletion() throws {
        let service = "SleepCoachAI.SecurityTests." + UUID().uuidString
        let keys = KeychainVaultKey(service: service)
        defer { try? keys.delete() }
        XCTAssertNil(try keys.read())
        let original = Data(repeating: 7, count: 32)
        XCTAssertEqual(try keys.create(original), original)
        XCTAssertEqual(try keys.create(Data(repeating: 8, count: 32)), original)
        XCTAssertEqual(try keys.read(), original)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)

        try keys.delete()
        XCTAssertNil(try keys.read())
    }

    func testEveryAtomicReplacementRequestsCompleteProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vaultURL = directory.appendingPathComponent("private-data-v1.bin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = RecordingProtectionFileManager()
        var writes: [(url: URL, options: Data.WritingOptions, data: Data)] = []
        let files = ProtectedVaultFile(directory: directory, fileManager: fileManager) { data, url, options in
            writes.append((url, options, data))
            try data.write(to: url, options: options)
        }

        for (index, ciphertext) in [Data("encrypted-one".utf8), Data("encrypted-two".utf8)].enumerated() {
            try files.replace(with: ciphertext)
            XCTAssertEqual(fileManager.creations.count, index + 1)
            XCTAssertEqual(fileManager.attributeUpdates.count, index + 1)
            XCTAssertEqual(writes.count, index + 1)
            let creation = try XCTUnwrap(fileManager.creations.last)
            let update = try XCTUnwrap(fileManager.attributeUpdates.last)
            let write = try XCTUnwrap(writes.last)
            XCTAssertEqual(creation.url, directory)
            XCTAssertTrue(creation.intermediates)
            XCTAssertEqual(try protectionValue(creation.attributes), FileProtectionType.complete.rawValue)
            XCTAssertEqual(update.path, directory.path)
            XCTAssertEqual(try protectionValue(update.attributes), FileProtectionType.complete.rawValue)
            XCTAssertEqual(write.url, vaultURL)
            XCTAssertEqual(write.options, [.atomic, .completeFileProtection])
            XCTAssertEqual(write.data, ciphertext)
            XCTAssertEqual(try Data(contentsOf: vaultURL), ciphertext)
            XCTAssertEqual(try files.read(), ciphertext)
        }
    }

    func testEveryAtomicReplacementKeepsCompleteFileProtectionOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("iOS Simulator does not provide the on-device file-protection metadata. " +
                      "The protection-request contract runs here; verify persisted Complete protection on a physical device.")
        #else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ProtectedVaultFile(directory: directory)
        for ciphertext in [Data("encrypted-one".utf8), Data("encrypted-two".utf8)] {
            try files.replace(with: ciphertext)
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("private-data-v1.bin").path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let fileProtection = try protectionValue(fileAttributes)
            let directoryProtection = try protectionValue(directoryAttributes)
            XCTAssertEqual(fileProtection, FileProtectionType.complete.rawValue)
            XCTAssertEqual(directoryProtection, FileProtectionType.complete.rawValue)
        }
        #endif
    }

    private func protectionValue(_ attributes: [FileAttributeKey: Any]) throws -> String {
        try XCTUnwrap((attributes[.protectionKey] as? FileProtectionType)?.rawValue
                     ?? attributes[.protectionKey] as? String)
    }
}

private final class RecordingProtectionFileManager: FileManager, @unchecked Sendable {
    var creations: [(url: URL, intermediates: Bool, attributes: [FileAttributeKey: Any])] = []
    var attributeUpdates: [(path: String, attributes: [FileAttributeKey: Any])] = []

    override func createDirectory(at url: URL, withIntermediateDirectories intermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        creations.append((url, intermediates, attributes ?? [:]))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediates,
                                                attributes: attributes)
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        attributeUpdates.append((path, attributes))
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }
}
