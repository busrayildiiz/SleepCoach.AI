import Foundation

// MARK: - Daytime Prediction

struct DaytimePredictionAgent {
    let nextNapTime:             Date?
    let windowStart:             Date?
    let windowEnd:               Date?
    let expectedDurationMinutes: Int
    let wakeWindowUsed:          Int
    let confidence:              Int?      // 0–94
    let mode:                    PredictionMode
    let reasoning:               [String]
    let usedDefaultWakeTime:     Bool
    var source: SleepPlanningSource = .recordedEstimate
    var unavailableReason: SleepPlanningUnavailable? = nil
    var generalWakeWindow: ClosedRange<Int>? = nil

    var recommendation: SleepPlanningValue<Date> {
        nextNapTime.map { .available($0, source: source, limitation: unavailableReason) } ?? .unavailable(unavailableReason ?? .missing)
    }
}
enum PredictionMode {
    case ageBaseline      // 0–6 gün
    case blended          // 7–13 gün
    case personalized     // 14+ gün
}

// MARK: - Protocol

protocol DaytimePredictionAgentProtocol {
    func predictNextNap(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date,
        planning:     SleepPredictionContext?
    ) -> DaytimePredictionAgent
}

extension DaytimePredictionAgentProtocol {
    func predictNextNap(pattern: BabyPattern?, todayRecords: [SleepRecord], wakeRecords: [DailyWakeRecord],
                        ageMonths: Int, trackedDays: Int, now: Date) -> DaytimePredictionAgent {
        predictNextNap(pattern: pattern, todayRecords: todayRecords, wakeRecords: wakeRecords,
                       ageMonths: ageMonths, trackedDays: trackedDays, now: now, planning: nil)
    }
}

// MARK: - DefaultDaytimePredictionAgent

final class DefaultDaytimePredictionAgent: DaytimePredictionAgentProtocol {

    private let calendar:        Calendar
    private let defaults: any PrivateDataStore
    private let profileProvider: AgeBasedSleepProfileProviding

    init(
        profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        calendar:        Calendar = .current,
        defaults: any PrivateDataStore = SecureDataStore.shared
    ) {
        self.defaults = defaults
        self.profileProvider = profileProvider
        self.calendar        = calendar
    }

    // MARK: - Predict Next Nap

    func predictNextNap(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date,
        planning:     SleepPredictionContext?
    ) -> DaytimePredictionAgent {
        let context = planning ?? SleepPredictionContext(records: todayRecords, wakes: wakeRecords,
            evaluation: .init(now: now, calendar: calendar, routine: .load(defaults: defaults)))
        let evaluation = context.evaluation
        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let assessment = context.assessment
        let anchor: Date?
        let source: SleepPlanningSource
        let limitation: SleepPlanningUnavailable
        let explanation: String
        if let active = assessment.active {
            limitation = .unresolved
            if active.record.kind == .dayNap, let elapsed = active.elapsed {
                anchor = active.record.date.addingMinutes(max(45, elapsed + 30))
                source = .activityEstimate
                explanation = "Baby is currently sleeping. This estimate uses a possible nap end and age-based timing."
            } else {
                anchor = nil
                source = .currentActivity
                explanation = "Baby is currently sleeping. The next sleep time needs an observed end."
            }
        } else if let observed = assessment.anchor {
            anchor = observed.date
            source = .recordedEstimate
            let subtotal = context.accounting.completedSubtotal(on: evaluation.now, kind: .dayNap)
            limitation = subtotal.unavailableReason ?? .incomplete
            switch observed {
            case .wake: explanation = "Estimated from the recorded wake using general age guidance."
            case .napEnd: explanation = "Estimated from the last recorded nap end using general age guidance."
            }
        } else if let wake = evaluation.routine?.wake(on: evaluation.now, calendar: evaluation.calendar) {
            anchor = wake
            source = .routine
            limitation = assessment.unavailableReason
            explanation = "Routine-based guidance from the saved usual wake time."
        } else {
            anchor = nil
            source = .ageGuidance
            limitation = assessment.unavailableReason
            explanation = "General age-based wake window guidance is available."
        }

        let range = profile.wakeWindowRange
        let wakeWindow = (range.lowerBound + range.upperBound) / 2
        let target = anchor?.addingMinutes(wakeWindow)
        return DaytimePredictionAgent(
            nextNapTime: target, windowStart: target?.addingMinutes(-20), windowEnd: target?.addingMinutes(20),
            expectedDurationMinutes: Int(Double(profile.maxSingleNapMinutes) * 0.75), wakeWindowUsed: wakeWindow,
            confidence: nil, mode: .ageBaseline, reasoning: [explanation, limitation.rawValue],
            usedDefaultWakeTime: source == .routine, source: source, unavailableReason: limitation,
            generalWakeWindow: source == .ageGuidance ? range : nil
        )
    }
}
