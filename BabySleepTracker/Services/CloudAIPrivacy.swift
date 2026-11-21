import Foundation

extension Notification.Name {
    static let cloudAIConsentDidChange = Notification.Name("cloudAIConsentDidChange")
}

/// Explicit, versioned permission for transmitting a minimized sleep summary.
/// General feature preferences, including smartSuggestions, are not consent.
final class CloudAIPrivacy {
    struct Permission: Equatable {
        fileprivate let receiptID: String
    }

    static let currentDisclosureVersion = 1
    static let consentKey = "cloudAIConsent_v1"
    static let sharingEnabledKey = "cloudAISharingEnabled"
    static let cachedResponseKeys: Set<String> = [
        "llm_lastGenerated", "llm_coachMessage", "llm_patternInsight",
        "llm_confidenceNote", "llm_sourceFingerprint", "llm_alert"
    ]
    static let disclosureTitle = "Share a sleep summary with Google Gemini?"
    static let disclosureMessage = """
    Cloud AI coaching sends your baby's age in months, recent sleep totals, sleep timing predictions, and data-quality summaries to Google Gemini to generate coaching text. Names, birth dates, gender, photos, and account details are not sent.

    This information is processed by Google outside your device. Turning this off stops future requests and removes saved cloud coaching from this device; it cannot recall information already sent to Google. Sleep tracking and on-device guidance remain available without sharing.
    """

    static let shared = CloudAIPrivacy(
        read: { SecureDataStore.shared.object(forKey: $0) },
        write: { try SecureDataStore.shared.write($0, removing: $1) },
        sharingEnabled: { UserDefaults.standard.bool(forKey: sharingEnabledKey) },
        setSharingEnabled: { UserDefaults.standard.set($0, forKey: sharingEnabledKey) }
    )

    static var isCloudAIAvailable: Bool {
        APIConfig.allowsDirectGeminiRequests && APIConfig.geminiKey != nil
    }

    private let read: (String) -> Any?
    private let write: ([String: Any], Set<String>) throws -> Void
    private let sharingEnabled: () -> Bool
    private let setSharingEnabled: (Bool) -> Void
    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    private let lock = NSRecursiveLock()
    // A failed disk write must not revive permission during this process.
    private var revokedInThisSession = false

    init(read: @escaping (String) -> Any?,
         write: @escaping ([String: Any], Set<String>) throws -> Void,
         sharingEnabled: @escaping () -> Bool,
         setSharingEnabled: @escaping (Bool) -> Void,
         now: @escaping () -> Date = Date.init,
         notificationCenter: NotificationCenter = .default) {
        self.read = read
        self.write = write
        self.sharingEnabled = sharingEnabled
        self.setSharingEnabled = setSharingEnabled
        self.now = now
        self.notificationCenter = notificationCenter
    }

    var hasConsent: Bool { permissionForRequest() != nil }

    /// Call only after the parent accepts the current disclosure in the UI.
    func grantConsent() throws {
        lock.lock()
        defer {
            lock.unlock()
            // Observers may read permission or dispatch to the main actor.
            // Never invoke them while retaining the permission lock.
            notificationCenter.post(name: .cloudAIConsentDidChange, object: self)
        }
        // The non-sensitive preference is deny-by-default and is never sufficient
        // on its own: a current protected receipt is still required below.
        setSharingEnabled(false)
        revokedInThisSession = true
        let receipt: [String: Any] = [
            "version": Self.currentDisclosureVersion,
            "receiptID": UUID().uuidString,
            "grantedAt": now().timeIntervalSince1970
        ]
        try write([Self.consentKey: receipt], Self.cachedResponseKeys)
        setSharingEnabled(true)
        revokedInThisSession = false
    }

    func revokeConsent() throws {
        lock.lock()
        defer {
            lock.unlock()
            // Notify on success and failure, after the independent deny switch
            // is set and without holding a lock across observer callbacks.
            notificationCenter.post(name: .cloudAIConsentDidChange, object: self)
        }
        // Persist the independent deny switch before touching a potentially
        // unavailable encrypted store. A later launch must not revive an old receipt.
        setSharingEnabled(false)
        revokedInThisSession = true
        try write([:], Self.cachedResponseKeys.union([Self.consentKey]))
    }

    func permissionForRequest() -> Permission? {
        lock.lock()
        defer { lock.unlock() }
        guard !revokedInThisSession, sharingEnabled(),
              let value = read(Self.consentKey) as? [String: Any],
              let version = value["version"] as? Int,
              version == Self.currentDisclosureVersion,
              let receipt = value["receiptID"] as? String,
              UUID(uuidString: receipt) != nil else { return nil }
        return Permission(receiptID: receipt)
    }

    /// A new grant never authorizes accepting an older in-flight response.
    func stillAllows(_ permission: Permission) -> Bool {
        permissionForRequest() == permission
    }

    /// Serialize a synchronous final cache/publication commit with revocation.
    /// No async work or network requests belong inside this critical section.
    func performIfAllowed(_ permission: Permission, action: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stillAllows(permission) else { return false }
        let completed = action()
        return completed && stillAllows(permission)
    }
}
