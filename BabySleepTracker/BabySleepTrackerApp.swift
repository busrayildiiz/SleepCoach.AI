import SwiftUI

@main
struct BabySleepTrackerApp: App {
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Explicit opt-in only in the UI-test runner's simulator app container.
        if HomeCardTestFixture.enabled {
            HomeCardTestFixture.prepare()
        } else if ProcessInfo.processInfo.environment["RECORDING_UI_TESTS"] == "1" {
            let defaults = UserDefaults.standard
            if let domain = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: domain)
            }
            defaults.set("light", forKey: "appAppearance")
            defaults.set(true, forKey: "authComplete")
            defaults.set(true, forKey: "onboardingComplete")
            let parent = SleepRecord(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                date: Date().addingTimeInterval(-7200), duration: 60
            )
            SleepRecordPersistence().save([parent])
            defaults.removeObject(forKey: "dailyWakeRecords_v1")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil // sistem ayarına uy
        }
    }
}
