//
//  PhaseAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 12.06.2026.
//

import Foundation

// MARK: - CoachPhase

enum CoachPhase: Equatable {
    case tooYoung              // 0–4 months: safe-sleep info only
    case baseline              // 4+ months, 0 tracked days: general age-based tables
    case learning(day: Int)    // days 1–13: data collection, blending begins
    case personalized          // 14+ days: full personalization
}

// MARK: - MissingSignal

enum MissingSignal: String, CaseIterable, Equatable {
    case wakeTime        = "Add today's wake time"
    case nightSleep      = "Log last night's sleep"
    case consecutiveDays = "Track more consecutive days"
}

// MARK: - PhaseReadinessReport

struct PhaseReadinessReport {
    let phase: CoachPhase
    let daysUntilPersonalized: Int   // 0 if already personalized
    let missingSignals: [MissingSignal]
    let confidence: Int              // 0–100
    let progressLabel: String        // short label shown in the UI
}


// MARK: - DefaultPhaseAgent

final class DefaultPhaseAgent: PhaseAgentProtocol {

    // MARK: - currentPhase

    func currentPhase(ageMonths: Int, trackedDays: Int) -> CoachPhase {
        // No pattern is expected under 4 months
        guard ageMonths >= 4 else {
            return .tooYoung
        }

        switch trackedDays {
        case 0:
            return .baseline
        case 1...13:
            return .learning(day: trackedDays)
        default:
            return .personalized
        }
    }

    // MARK: - readinessReport

    func readinessReport(
        ageMonths: Int,
        trackedDays: Int,
        hasTodayWakeTime: Bool,
        hasYesterdayNightSleep: Bool
    ) -> PhaseReadinessReport {

        let phase = currentPhase(ageMonths: ageMonths, trackedDays: trackedDays)

        let daysUntilPersonalized: Int = {
            switch phase {
            case .tooYoung:              return -1   // not applicable
            case .baseline:              return 14
            case .learning(let day):     return 14 - day
            case .personalized:          return 0
            }
        }()

        // Missing signals
        var missing: [MissingSignal] = []
        if !hasTodayWakeTime        { missing.append(.wakeTime) }
        if !hasYesterdayNightSleep  { missing.append(.nightSleep) }
        if trackedDays < 3          { missing.append(.consecutiveDays) }

        // Confidence calculation
        let confidence = calculateConfidence(
            phase: phase,
            trackedDays: trackedDays,
            hasTodayWakeTime: hasTodayWakeTime,
            hasYesterdayNightSleep: hasYesterdayNightSleep
        )

        // Progress label
        let progressLabel = makeProgressLabel(
            phase: phase,
            trackedDays: trackedDays,
            daysUntilPersonalized: daysUntilPersonalized
        )

        return PhaseReadinessReport(
            phase: phase,
            daysUntilPersonalized: daysUntilPersonalized,
            missingSignals: missing,
            confidence: confidence,
            progressLabel: progressLabel
        )
    }

    // MARK: - Private Helpers

    private func calculateConfidence(
        phase: CoachPhase,
        trackedDays: Int,
        hasTodayWakeTime: Bool,
        hasYesterdayNightSleep: Bool
    ) -> Int {
        var score = 0

        switch phase {
        case .tooYoung:
            return 0
        case .baseline:
            score = 40
        case .learning(let day):
            // +3 points per day, up to +42 at day 14
            score = 40 + (day * 3)
        case .personalized:
            score = 82
        }

        // Bonus signals
        if hasTodayWakeTime       { score += 8 }
        if hasYesterdayNightSleep { score += 5 }

        return min(score, 94)  // max 94 — never claims 100%
    }

    private func makeProgressLabel(
        phase: CoachPhase,
        trackedDays: Int,
        daysUntilPersonalized: Int
    ) -> String {
        switch phase {
        case .tooYoung:
            return "Becomes active starting at 4 months"
        case .baseline:
            return "Log the first sleep — let learning begin"
        case .learning(let day):
            let remaining = 14 - day
            return "\(day)/14 days • personalizes in \(remaining) more days"
        case .personalized:
            return "Personalized mode active ✓"
        }
    }
}
