import Foundation

struct DailyWakeRecord: Identifiable, Codable {
    let id: UUID
    let day: Date
    let wakeTime: Date

    init(id: UUID = UUID(), day: Date, wakeTime: Date) {
        self.id = id
        self.day = day
        self.wakeTime = wakeTime
    }
}

enum SleepCoachMode: String, Codable {
    case baseline
    case learning
    case personalized
}

struct SleepGuideline: Codable {
    let minimumDailyMinutes: Int
    let maximumDailyMinutes: Int
    let sourceName: String
    let sourceURL: String
}

struct SleepCoachPrediction: Codable {
    let recommendedTime: Date
    let windowStart: Date
    let windowEnd: Date
    let confidence: Int
    let wakeWindowMinutes: Int
    let expectedNapMinutes: Int
    let mode: SleepCoachMode
    let trackedDays: Int
    let anchorTime: Date
    let hasTodayWakeTime: Bool
    let reasons: [String]
}

struct SleepCoachInsight: Identifiable, Codable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let value: String
    let tone: String
}

struct SleepCoachPlanItem: Identifiable, Codable {
    let id: String
    let time: Date
    let title: String
    let detail: String
    let icon: String
    let isPrediction: Bool
}

struct SleepCoachSnapshot: Codable {
    let generatedAt: Date
    let babyName: String
    let ageMonths: Int
    let guideline: SleepGuideline
    let prediction: SleepCoachPrediction
    let plan: [SleepCoachPlanItem]
    let insights: [SleepCoachInsight]
    let coachTip: String
}

private struct PersonalSleepProfile {
    let observedWakeWindow: Int?
    let averageNapMinutes: Int?
    let bestNapHour: Int?
    let bestNapExtraMinutes: Int?
    let bedtimeShiftMinutes: Int?
    let weekOverWeekNapChange: Int?
}

protocol PediatricSleepGuidelineProviding {
    func guideline(forAgeMonths ageMonths: Int) -> SleepGuideline
}

protocol WakeWindowBaselineProviding {
    func wakeWindow(forAgeMonths ageMonths: Int) -> ClosedRange<Int>
}


