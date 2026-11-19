//
//  NightPredictionAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 13.06.2026.
//

import Foundation

// MARK: - Night Prediction

struct NightPredictionAgent {
    let optimalBedtimeStart:      Date?
    let optimalBedtimeEnd:        Date?
    let overtiredRiskTime:        Date?
    let expectedNightSleepMinutes: Int
    let lastNapCutoffTime:        Date
    let daytimeSleepStatus:       DailySleepStatus?
    let confidence:               Int?
    let reasoning:                [String]
    var daytimeSubtotalIsReliable: Bool = true
    var source: SleepPlanningSource = .recordedEstimate
    var unavailableReason: SleepPlanningUnavailable = .missing
    var generalBedtimeHours: ClosedRange<Int>? = nil

    var recommendation: SleepPlanningValue<Date> {
        optimalBedtimeStart.map { .available($0, source: source) } ?? .unavailable(unavailableReason)
    }
}

// MARK: - Protocol

protocol NightPredictionAgentProtocol {
    func predictBedtime(
        pattern:          BabyPattern?,
        todayRecords:     [SleepRecord],
        wakeRecords:      [DailyWakeRecord],
        ageMonths:        Int,
        trackedDays:      Int,
        now:              Date,
        planning:         SleepPredictionContext?
    ) -> NightPredictionAgent
}

extension NightPredictionAgentProtocol {
    func predictBedtime(pattern: BabyPattern?, todayRecords: [SleepRecord], wakeRecords: [DailyWakeRecord],
                        ageMonths: Int, trackedDays: Int, now: Date) -> NightPredictionAgent {
        predictBedtime(pattern: pattern, todayRecords: todayRecords, wakeRecords: wakeRecords,
                       ageMonths: ageMonths, trackedDays: trackedDays, now: now, planning: nil)
    }
}

// MARK: - DefaultNightPredictionAgent

final class DefaultNightPredictionAgent: NightPredictionAgentProtocol {

    private let calendar:            Calendar
    private let profileProvider:     AgeBasedSleepProfileProviding
    private let overtiredCalculator: OvertiredCalculator

    init(
        profileProvider:     AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        overtiredCalculator: OvertiredCalculator? = nil,
        calendar:            Calendar = .current
    ) {
        self.profileProvider     = profileProvider
        self.overtiredCalculator = overtiredCalculator ?? OvertiredCalculator(profileProvider: profileProvider, calendar: calendar)
        self.calendar            = calendar
    }

    // MARK: - Predict Bedtime

    func predictBedtime(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date,
        planning:     SleepPredictionContext?
    ) -> NightPredictionAgent {
        let context = planning ?? SleepPredictionContext(records: todayRecords, wakes: wakeRecords,
            evaluation: .init(now: now, calendar: calendar, routine: .load(defaults: .standard)))
        let evaluation = context.evaluation
        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let totalDaytime = context.accounting.completedSubtotal(on: now, kind: .dayNap)
        let sleepStatus = totalDaytime.comparableMinutes.map {
            overtiredCalculator.daytimeSleepStatus(totalMinutes: $0, ageMonths: ageMonths)
        }
        let cutoff = overtiredCalculator.lastNapCutoffTime(ageMonths: ageMonths, on: now)
        let expectedNight = expectedNightSleep(profile: profile, pattern: pattern)
        if case .napEnd(_, let end) = context.assessment.anchor,
           let minutes = totalDaytime.comparableMinutes, let sleepStatus {
            let window = overtiredCalculator.bedtimeWindow(lastNapEndTime: end,
                totalDaytimeSleepMinutes: minutes, ageMonths: ageMonths, now: now)
            let confidence = calculateConfidence(trackedDays: trackedDays, hasLastNap: true,
                hasWakeRecord: context.assessment.recordedWake != nil, hasPattern: pattern != nil)
            return NightPredictionAgent(optimalBedtimeStart: window.earliest, optimalBedtimeEnd: window.latest,
                overtiredRiskTime: window.overtiredRisk, expectedNightSleepMinutes: expectedNight,
                lastNapCutoffTime: cutoff, daytimeSleepStatus: sleepStatus, confidence: confidence,
                reasoning: buildReasoning(profile: profile, lastNapEnd: end, bedtime: window.ideal,
                                          ageMonths: ageMonths, sleepStatus: sleepStatus, calendar: evaluation.calendar))
        }

        let routine = evaluation.routine?.bedtime(on: now, calendar: evaluation.calendar)
        let reason = totalDaytime.isIncomplete ? SleepPlanningUnavailable.incomplete : context.assessment.unavailableReason
        return NightPredictionAgent(optimalBedtimeStart: routine, optimalBedtimeEnd: nil,
            overtiredRiskTime: nil, expectedNightSleepMinutes: expectedNight, lastNapCutoffTime: cutoff,
            daytimeSleepStatus: sleepStatus, confidence: nil,
            reasoning: [routine == nil ? "\(reason.rawValue). General age-based bedtime guidance is available."
                                      : "Routine-based guidance from the saved usual bedtime."],
            daytimeSubtotalIsReliable: !totalDaytime.isIncomplete,
            source: routine == nil ? .ageGuidance : .routine, unavailableReason: reason,
            generalBedtimeHours: routine == nil ? profile.bedtimeHourRange : nil)
    }

    // MARK: - Expected Night Sleep

    private func expectedNightSleep(
        profile: AgeBasedSleepProfile,
        pattern: BabyPattern?
    ) -> Int {
        if let avg = pattern?.averageNightSleepMinutes { return avg }
        return (profile.nightSleepRange.lowerBound + profile.nightSleepRange.upperBound) / 2
    }

    // MARK: - Confidence

    private func calculateConfidence(
        trackedDays:   Int,
        hasLastNap:    Bool,
        hasWakeRecord: Bool,
        hasPattern:    Bool
    ) -> Int {
        var score = 40 + min(trackedDays, 14) * 2
        if hasLastNap    { score += 10 }
        if hasWakeRecord { score += 6  }
        if hasPattern    { score += 5  }
        return min(score, 94)
    }

    // MARK: - Reasoning

    private func buildReasoning(
        profile:      AgeBasedSleepProfile,
        lastNapEnd:   Date,
        bedtime:      Date,
        ageMonths:    Int,
        sleepStatus:  DailySleepStatus,
        calendar:     Calendar
    ) -> [String] {

        let fmt        = DateFormatter()
        fmt.locale     = Locale(identifier: "en_US_POSIX")
        fmt.calendar   = calendar
        fmt.timeZone   = calendar.timeZone
        fmt.dateFormat = "h:mm a"

        let ewwCenter = (profile.eveningWakeWindow.lowerBound + profile.eveningWakeWindow.upperBound) / 2
        var parts = [
            "Last nap ended at \(fmt.string(from: lastNapEnd)).",
            "Evening wake window for \(ageMonths)-month-old is ~\(ewwCenter) min."
        ]

        switch sleepStatus {
        case .below(let deficit):
            parts.append("Daytime sleep is \(TimeFormat.minutes(deficit)) short — bedtime moved earlier.")
        case .above(let excess):
            parts.append("Daytime sleep is \(TimeFormat.minutes(excess)) over — bedtime may be delayed.")
        case .onTrack:
            parts.append("Daytime sleep is on target.")
        }

        parts.append("Recommended bedtime: \(fmt.string(from: bedtime)).")
        return parts
    }

}
