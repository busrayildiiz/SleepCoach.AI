import Foundation
import XCTest
@testable import BabySleepTracker

final class CloudAIPrivacyTests: XCTestCase {
    func testGeneralFeaturePreferenceDoesNotAuthorizeSharing() {
        let memory = CloudAIConsentTestMemory(values: ["smartSuggestions": true])
        let privacy = memory.makePrivacy()

        XCTAssertFalse(privacy.hasConsent)
        XCTAssertNil(privacy.permissionForRequest())
    }

    func testExplicitGrantPersistsVersionedReceiptAndSurvivesRecreation() throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()

        let permission = try XCTUnwrap(privacy.permissionForRequest())
        let stored = try XCTUnwrap(memory.values[CloudAIPrivacy.consentKey] as? [String: Any])
        XCTAssertEqual(stored["version"] as? Int, CloudAIPrivacy.currentDisclosureVersion)
        XCTAssertNotNil(stored["grantedAt"] as? TimeInterval)
        XCTAssertTrue(memory.makePrivacy().stillAllows(permission))
    }

    func testOlderDisclosureRequiresFreshPermission() {
        let memory = CloudAIConsentTestMemory(values: [CloudAIPrivacy.consentKey: [
            "version": CloudAIPrivacy.currentDisclosureVersion - 1,
            "receiptID": UUID().uuidString
        ]])
        memory.sharingEnabled = true

        XCTAssertFalse(memory.makePrivacy().hasConsent)
    }

    func testMalformedReceiptCannotAuthorizeSharing() {
        let memory = CloudAIConsentTestMemory(values: [CloudAIPrivacy.consentKey: [
            "version": CloudAIPrivacy.currentDisclosureVersion,
            "receiptID": ""
        ]])
        memory.sharingEnabled = true

        XCTAssertFalse(memory.makePrivacy().hasConsent)
    }

    func testRevocationRemovesConsentAndCloudCacheButKeepsSleepRecords() throws {
        let memory = CloudAIConsentTestMemory(values: ["sleepRecords": Data([1, 2, 3])])
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        let permission = try XCTUnwrap(privacy.permissionForRequest())
        for key in CloudAIPrivacy.cachedResponseKeys { memory.values[key] = "cached" }

        try privacy.revokeConsent()

        XCTAssertFalse(privacy.hasConsent)
        XCTAssertFalse(privacy.stillAllows(permission))
        XCTAssertNil(memory.values[CloudAIPrivacy.consentKey])
        for key in CloudAIPrivacy.cachedResponseKeys { XCTAssertNil(memory.values[key], key) }
        XCTAssertEqual(memory.values["sleepRecords"] as? Data, Data([1, 2, 3]))
    }

    func testRegrantDoesNotAuthorizeEarlierInFlightResponse() throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        let oldPermission = try XCTUnwrap(privacy.permissionForRequest())

        try privacy.revokeConsent()
        try privacy.grantConsent()

        XCTAssertTrue(privacy.hasConsent)
        XCTAssertFalse(privacy.stillAllows(oldPermission))
    }

    func testFailedGrantDoesNotAuthorizeSharing() {
        let memory = CloudAIConsentTestMemory()
        memory.failWrites = true
        let privacy = memory.makePrivacy()

        XCTAssertThrowsError(try privacy.grantConsent())
        XCTAssertFalse(privacy.hasConsent)
    }

    func testFailedRevocationImmediatelyBlocksRequestsAndNotifiesObservers() throws {
        let center = NotificationCenter()
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy(notificationCenter: center)
        try privacy.grantConsent()
        let permission = try XCTUnwrap(privacy.permissionForRequest())
        memory.failWrites = true
        let deniedAtNotification = expectation(description: "Revocation observers see permission denied")
        let token = center.addObserver(forName: .cloudAIConsentDidChange, object: nil, queue: nil) { _ in
            XCTAssertFalse(privacy.hasConsent)
            deniedAtNotification.fulfill()
        }
        defer { center.removeObserver(token) }

        XCTAssertThrowsError(try privacy.revokeConsent())

        wait(for: [deniedAtNotification], timeout: 1)
        XCTAssertFalse(privacy.hasConsent)
        XCTAssertFalse(privacy.stillAllows(permission))
        XCTAssertNotNil(memory.values[CloudAIPrivacy.consentKey], "Simulate the old encrypted receipt surviving the failed write.")
        XCTAssertFalse(memory.makePrivacy().hasConsent, "Recreating the controller must not revive a failed revocation.")
    }

    func testTemporaryProtectedStoreLockDoesNotPermanentlyRevokeConsent() throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        let permission = try XCTUnwrap(privacy.permissionForRequest())

        memory.failReads = true
        XCTAssertFalse(privacy.hasConsent)
        XCTAssertFalse(privacy.stillAllows(permission))
        XCTAssertTrue(memory.sharingEnabled)

        memory.failReads = false
        XCTAssertTrue(privacy.stillAllows(permission))
    }

    func testEnabledPreferenceWithoutProtectedReceiptIsInsufficient() {
        let memory = CloudAIConsentTestMemory()
        memory.sharingEnabled = true

        XCTAssertFalse(memory.makePrivacy().hasConsent)
    }

    func testRevocationNotificationObservesRemovedProtectedReceiptAndCache() throws {
        let center = NotificationCenter()
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy(notificationCenter: center)
        try privacy.grantConsent()
        memory.values["llm_coachMessage"] = "Previously saved cloud response"
        let revoked = expectation(description: "Observers see completed revocation cleanup")
        let observer = center.addObserver(forName: .cloudAIConsentDidChange, object: nil, queue: nil) { _ in
            XCTAssertFalse(privacy.hasConsent)
            XCTAssertNil(memory.values[CloudAIPrivacy.consentKey])
            XCTAssertNil(memory.values["llm_coachMessage"])
            revoked.fulfill()
        }
        defer { center.removeObserver(observer) }

        try privacy.revokeConsent()

        wait(for: [revoked], timeout: 1)
    }

    func testProtectedPublicationRejectsOldPermissionWithoutRunningAction() throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        let oldPermission = try XCTUnwrap(privacy.permissionForRequest())
        var published = false
        XCTAssertTrue(privacy.performIfAllowed(oldPermission) {
            memory.values["llm_coachMessage"] = "Allowed response"
            published = true
            return true
        })
        XCTAssertTrue(published)

        try privacy.revokeConsent()
        try privacy.grantConsent()
        published = false
        XCTAssertFalse(privacy.performIfAllowed(oldPermission) {
            memory.values["llm_coachMessage"] = "Stale response must not return"
            published = true
            return true
        })
        XCTAssertFalse(published)
        XCTAssertNil(memory.values["llm_coachMessage"])
    }

    func testDevelopmentKeyOnlyUsesExplicitEnvironmentAndRejectsPlaceholders() {
        XCTAssertNil(APIConfig.geminiKey(environment: [:]))
        XCTAssertNil(APIConfig.geminiKey(environment: ["GEMINI_API_KEY": " \n "]))
        XCTAssertNil(APIConfig.geminiKey(environment: ["GEMINI_API_KEY": "$(GEMINI_API_KEY)"]))
        XCTAssertNil(APIConfig.geminiKey(environment: ["GEMINI_API_KEY": "BURAYA_KENDI_GEMINI_API_KEYINI_YAPISTIR"]))
        XCTAssertNil(APIConfig.geminiKey(environment: ["GeminiApiKey": "test-key"]))
        #if DEBUG
        XCTAssertEqual(APIConfig.geminiKey(environment: ["GEMINI_API_KEY": " test-key \n"]), "test-key")
        XCTAssertTrue(APIConfig.allowsDirectGeminiRequests)
        #else
        XCTAssertNil(APIConfig.geminiKey(environment: ["GEMINI_API_KEY": "test-key"]))
        XCTAssertFalse(APIConfig.allowsDirectGeminiRequests)
        #endif
    }

}

final class CloudAIConsentTestMemory {
    enum Failure: Error { case protectedStoreUnavailable }
    var values: [String: Any]
    var failWrites = false
    var failReads = false
    var sharingEnabled = false

    init(values: [String: Any] = [:]) { self.values = values }

    func makePrivacy(notificationCenter: NotificationCenter = .default) -> CloudAIPrivacy {
        CloudAIPrivacy(
            read: { self.failReads ? nil : self.values[$0] },
            write: { values, removals in
                if self.failWrites { throw Failure.protectedStoreUnavailable }
                for key in removals { self.values.removeValue(forKey: key) }
                self.values.merge(values, uniquingKeysWith: { _, new in new })
            },
            sharingEnabled: { self.sharingEnabled },
            setSharingEnabled: { self.sharingEnabled = $0 },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            notificationCenter: notificationCenter
        )
    }
}
