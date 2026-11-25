import SwiftUI

@main
struct BabySleepTrackerApp: App {
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Explicit opt-in only in the UI-test runner's simulator app container.
        if DaytimeCoverageUITestFixture.enabled {
            DaytimeCoverageUITestFixture.prepare()
        } else if TodayPlanUITestFixture.enabled {
            TodayPlanUITestFixture.prepare()
        } else if HeroUITestFixture.enabled {
            HeroUITestFixture.prepare()
        } else if HomeCardTestFixture.enabled {
            HomeCardTestFixture.prepare()
        } else if ProcessInfo.processInfo.environment["RECORDING_UI_TESTS"] == "1" {
            let defaults = UserDefaults.standard
            do { try SecureDataStore.shared.eraseAll() }
            catch { return }
            if let domain = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: domain)
            }
            defaults.set("light", forKey: "appAppearance")
            defaults.set(true, forKey: "authComplete")
            defaults.set(true, forKey: "onboardingComplete")
            SecureDataStore.shared.set(true, forKey: "profileSetupComplete_v1")
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
            SecureDataStore.shared.removeObject(forKey: "dailyWakeRecords_v1")
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

#if DEBUG && targetEnvironment(simulator)
enum DaytimeCoverageUITestFixture {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DAYTIME_COVERAGE_UI_TESTS"] == "1" }

    static func prepare() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DAYTIME_COVERAGE_RESET"] != "0" else { return }
        let store = SecureDataStore.shared
        do {
            try store.eraseAll()
            try store.write(["profileSetupComplete_v1": true, "babyName": "Baby"])
        } catch { return }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UserDefaults.standard.set(true, forKey: "authComplete")
        UserDefaults.standard.set(true, forKey: "onboardingComplete")

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: yesterday) else { return }
        let wakes = DailyWakeRecordPersistence(defaults: store)
        let sleeps = SleepRecordPersistence(defaults: store)
        let historical = HistoricalWakeDraft(day: yesterday, calendar: calendar, persistence: wakes)
        let recovery = SleepWakeTimeWorkflow(selectedWakeTime: morning, now: now, calendar: calendar,
                                             wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps)
        guard recovery.recoverHistoricalWake(historical, confirmation: historical.confirmObservedWake(at: morning)) == .saved,
              environment["DAYTIME_COVERAGE_SCENARIO"] != "missingFollowing" else { return }

        var current = WakeObservationDraft(initial: today.addingTimeInterval(60))
        current.selected = today
        guard current.submit(save: { time, capture in
            SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
                                  wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps,
                                  capture: capture).execute().evidencePublicationSucceeded
        }) else { return }

        if environment["DAYTIME_COVERAGE_SCENARIO"] == "duplicateMorning", let existing = wakes.load() {
            let duplicate = DailyWakeRecord(day: yesterday, wakeTime: morning.addingTimeInterval(15 * 60))
            _ = wakes.save(existing + [duplicate])
        }

        if environment["DAYTIME_COVERAGE_SCENARIO"] == "withNaps" {
            let naps = [12, 9].compactMap { hour -> SleepRecord? in
                guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: yesterday) else { return nil }
                return SleepRecord(date: start, duration: 45, endDate: start.addingTimeInterval(45 * 60))
            }
            _ = sleeps.save(naps)
        }
    }

    static func reviewStorage() -> ObservationStorage {
        let storage = ObservationStorage(defaults: SecureDataStore.shared)
        guard enabled, ProcessInfo.processInfo.environment["DAYTIME_COVERAGE_FAIL_SAVE"] == "1" else { return storage }
        var failNextAnswer = true
        return ObservationStorage(defaults: storage.defaults, writer: { data, key in
            if failNextAnswer, key == ObservationProvenance.key,
               let metadata = try? JSONDecoder().decode(ObservationProvenance.self, from: data), !metadata.daytime.isEmpty {
                failNextAnswer = false
                return false
            }
            return storage.write(data, key)
        })
    }
}
#endif
