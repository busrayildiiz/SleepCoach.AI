import Foundation

struct APIConfig {
    /// A released client must never carry the provider's server credential.
    /// Cloud coaching stays disabled until an authenticated backend is supplied.
    static var allowsDirectGeminiRequests: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var geminiKey: String? {
        geminiKey(environment: ProcessInfo.processInfo.environment)
    }

    /// Development-only injection through the launching process. No bundle,
    /// UserDefaults, source-code, or xcconfig fallback is allowed.
    static func geminiKey(environment: [String: String]) -> String? {
        #if DEBUG
        guard let value = environment["GEMINI_API_KEY"] else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains("$("),
              key != "BURAYA_KENDI_GEMINI_API_KEYINI_YAPISTIR" else { return nil }
        return key
        #else
        return nil
        #endif
    }
}
