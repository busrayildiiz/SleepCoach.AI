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
            let referenceCapture = ProcessInfo.processInfo.environment["RECORDING_REFERENCE_SCREENSHOTS"] == "1"
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date().addingTimeInterval(-86400)
            let referenceEnd = Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: yesterday) ?? yesterday
            let parent = SleepRecord(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                date: referenceCapture ? referenceEnd.addingTimeInterval(-8 * 3600) : Date().addingTimeInterval(-7200),
                duration: referenceCapture ? 480 : 60,
                kind: referenceCapture ? .nightSleep : .dayNap
            )
            var fixture = [parent]
            if referenceCapture {
                // A completed overnight session with an existing awake interval for ring review.
                fixture.append(SleepRecord(date: parent.date.addingTimeInterval(7200), duration: 37,
                                           kind: .break, parentNapID: parent.id))
            }
            SleepRecordPersistence().save(fixture)
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
