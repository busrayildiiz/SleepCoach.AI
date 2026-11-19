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
    var unavailableReason: SleepPlanningUnavailable = .missing
    var generalWakeWindow: ClosedRange<Int>? = nil

    var recommendation: SleepPlanningValue<Date> {
        nextNapTime.map { .available($0, source: source) } ?? .unavailable(unavailableReason)
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
    private let profileProvider: AgeBasedSleepProfileProviding

    init(
        profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        calendar:        Calendar = .current
    ) {
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
            evaluation: .init(now: now, calendar: calendar, routine: .load(defaults: .standard)))
        let evaluation = context.evaluation
        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let todayNaps = todayRecords.filter { $0.kind == .dayNap && $0.completedEnd(at: now) != nil }
        let assessment = context.assessment
        let anchor: Date?
        let source: SleepPlanningSource
        if let active = assessment.active {
            if active.record.kind == .dayNap, let elapsed = active.elapsed {
                anchor = active.record.date.addingMinutes(max(45, elapsed + 30))
                source = .activityEstimate
            } else {
                anchor = nil
                source = .ageGuidance
            }
        } else if let observed = assessment.anchor {
            anchor = observed.date
            source = .recordedEstimate
        } else if let wake = evaluation.routine?.wake(on: now, calendar: evaluation.calendar) {
            anchor = wake
            source = .routine
        } else {
            anchor = nil
            source = .ageGuidance
        }

        let usesPattern = source == .recordedEstimate || source == .activityEstimate
        let wakeWindow = blendedWakeWindow(profile: profile, pattern: usesPattern ? pattern : nil, trackedDays: trackedDays)
        let mode = predictionMode(trackedDays: trackedDays, pattern: pattern)
        let radius = windowRadius(for: mode)
        let target = anchor.map { $0.addingMinutes(wakeWindow) }
        let confidence = usesPattern ? calculateConfidence(mode: mode, trackedDays: trackedDays,
            hasWakeTime: source == .recordedEstimate, hasPattern: pattern != nil,
            hasOngoingNap: source == .activityEstimate) : nil
        let reasoning: [String]
        if usesPattern {
            reasoning = buildReasoning(mode: mode, wakeWindow: wakeWindow, ageMonths: ageMonths,
                trackedDays: trackedDays, hasOngoingNap: source == .activityEstimate)
        } else if source == .routine {
            reasoning = ["Routine-based guidance from the saved usual wake time."]
        } else {
            reasoning = ["\(assessment.unavailableReason.rawValue). General age-based wake window guidance is available."]
        }
        return DaytimePredictionAgent(
            nextNapTime: target,
            windowStart: target.map { $0.addingMinutes(-radius) },
            windowEnd: target.map { $0.addingMinutes(radius) },
            expectedDurationMinutes: expectedNapDuration(profile: profile, pattern: usesPattern ? pattern : nil,
                                                        napIndex: todayNaps.count),
            wakeWindowUsed: wakeWindow, confidence: confidence, mode: mode, reasoning: reasoning,
            usedDefaultWakeTime: source == .routine, source: source, unavailableReason: assessment.unavailableReason,
            generalWakeWindow: target == nil ? profile.wakeWindowRange : nil
        )
    }

    // MARK: - Blended Wake Window

    private func blendedWakeWindow(
        profile:     AgeBasedSleepProfile,
        pattern:     BabyPattern?,
        trackedDays: Int
    ) -> Int {
        let baselineCenter =
            (profile.wakeWindowRange.lowerBound + profile.wakeWindowRange.upperBound) / 2

        guard let observed = pattern?.averageWakeWindowMinutes else {
            return baselineCenter
        }

        let weight  = min(1.0, Double(trackedDays) / 14.0)
        let blended = Double(baselineCenter) * (1 - weight) + Double(observed) * weight

        let minWW = profile.wakeWindowRange.lowerBound - 30
        let maxWW = profile.wakeWindowRange.upperBound + 45
        return max(minWW, min(maxWW, Int(blended.rounded())))
    }

    // MARK: - Expected Nap Duration

    private func expectedNapDuration(
        profile:  AgeBasedSleepProfile,
        pattern:  BabyPattern?,
        napIndex: Int
    ) -> Int {
        if let avg = pattern?.averageNapDurationMinutes {
            let adjustment = napIndex > 0 ? -10 : 0
            return max(30, avg + adjustment)
        }
        return Int(Double(profile.maxSingleNapMinutes) * 0.75)
    }

    // MARK: - Prediction Mode

    private func predictionMode(
        trackedDays: Int,
        pattern:     BabyPattern?
    ) -> PredictionMode {
        switch trackedDays {
        case 0...6:  return .ageBaseline
        case 7...13: return .blended
        default:     return pattern != nil ? .personalized : .blended
        }
    }

    // MARK: - Window Radius

    private func windowRadius(for mode: PredictionMode) -> Int {
        switch mode {
        case .ageBaseline:  return 20
        case .blended:      return 15
        case .personalized: return 10
        }
    }

    // MARK: - Confidence

    private func calculateConfidence(
        mode:          PredictionMode,
        trackedDays:   Int,
        hasWakeTime:   Bool,
        hasPattern:    Bool,
        hasOngoingNap: Bool
    ) -> Int {
        var score: Int
        switch mode {
        case .ageBaseline:  score = 44 + trackedDays * 2
        case .blended:      score = 58 + (trackedDays - 7) * 2
        case .personalized: score = 76
        }
        if hasWakeTime    { score += 8 }
        if hasPattern     { score += 5 }
        if hasOngoingNap  { score -= 10 }
        return min(max(score, 0), 94)
    }

    // MARK: - Reasoning

    private func buildReasoning(
        mode:          PredictionMode,
        wakeWindow:    Int,
        ageMonths:     Int,
        trackedDays:   Int,
        hasOngoingNap: Bool
    ) -> [String] {
        var parts = [String]()

        if hasOngoingNap {
            parts.append("Baby is currently sleeping — prediction based on estimated nap end time.")
        } else {
            parts.append("Calculated from today's wake-up or last nap end time.")
        }

        switch mode {
        case .ageBaseline:
            parts.append("Using age baseline for \(ageMonths)-month-old (\(wakeWindow) min wake window).")
        case .blended:
            parts.append("Blending age baseline with \(trackedDays) days of data (\(wakeWindow) min).")
        case .personalized:
            parts.append("Personalized from \(loadBabyName())'s own sleep pattern (\(wakeWindow) min).")
        }

        if trackedDays < 14 {
            let remaining = 14 - trackedDays
            parts.append("\(remaining) more tracked day\(remaining == 1 ? "" : "s") until fully personalized.")
        }

        return parts
    }

    private func loadBabyName() -> String {
        let name = UserDefaults.standard.string(forKey: "babyName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Baby" : name
    }
}
