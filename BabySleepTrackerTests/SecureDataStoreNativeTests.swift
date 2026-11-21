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

    func testEveryAtomicReplacementKeepsCompleteFileProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ProtectedVaultFile(directory: directory)
        for ciphertext in [Data("encrypted-one".utf8), Data("encrypted-two".utf8)] {
            try files.replace(with: ciphertext)
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("private-data-v1.bin").path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual(fileAttributes[.protectionKey] as? FileProtectionType, .complete)
            XCTAssertEqual(directoryAttributes[.protectionKey] as? FileProtectionType, .complete)
        }
    }
}
