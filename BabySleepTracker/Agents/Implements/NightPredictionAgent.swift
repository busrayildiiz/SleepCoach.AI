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
    var unavailableReason: SleepPlanningUnavailable? = nil
    var generalBedtimeHours: ClosedRange<Int>? = nil

    var recommendation: SleepPlanningValue<Date> {
        optimalBedtimeStart.map { .available($0, source: source, limitation: unavailableReason) } ?? .unavailable(unavailableReason ?? .missing)
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
        let totalDaytime = context.accounting.completedSubtotal(on: evaluation.now, kind: .dayNap)
        let comparable = totalDaytime.comparableMinutes
        let sleepStatus = comparable.map { overtiredCalculator.daytimeSleepStatus(totalMinutes: $0, ageMonths: ageMonths) }
        let cutoff = overtiredCalculator.lastNapCutoffTime(ageMonths: ageMonths, on: evaluation.now, using: evaluation.calendar)
        let expectedNight = (profile.nightSleepRange.lowerBound + profile.nightSleepRange.upperBound) / 2

        if context.assessment.active != nil {
            return NightPredictionAgent(optimalBedtimeStart: nil, optimalBedtimeEnd: nil, overtiredRiskTime: nil,
                expectedNightSleepMinutes: expectedNight, lastNapCutoffTime: cutoff, daytimeSleepStatus: nil, confidence: nil,
                reasoning: ["Baby is currently sleeping. Check the plan after an observed end."],
                daytimeSubtotalIsReliable: !totalDaytime.isIncomplete, source: .currentActivity, unavailableReason: .unresolved)
        }

        if case .napEnd(_, let end) = context.assessment.anchor {
            let window = overtiredCalculator.bedtimeWindow(lastNapEndTime: end,
                totalDaytimeSleepMinutes: comparable, ageMonths: ageMonths, now: evaluation.now, using: evaluation.calendar)
            let formatter = DateFormatter()
            formatter.calendar = evaluation.calendar
            formatter.timeZone = evaluation.calendar.timeZone
            formatter.timeStyle = .short
            return NightPredictionAgent(optimalBedtimeStart: window.earliest, optimalBedtimeEnd: window.latest,
                overtiredRiskTime: comparable == nil ? nil : window.overtiredRisk, expectedNightSleepMinutes: expectedNight,
                lastNapCutoffTime: cutoff, daytimeSleepStatus: sleepStatus, confidence: nil,
                reasoning: ["Last recorded nap ended at \(formatter.string(from: end)).",
                            "Estimated bedtime uses the age-based evening wake window."] +
                    (totalDaytime.unavailableReason.map { [$0.rawValue] } ?? []),
                daytimeSubtotalIsReliable: !totalDaytime.isIncomplete, unavailableReason: totalDaytime.unavailableReason)
        }

        let routine = evaluation.routine?.bedtime(on: evaluation.now, calendar: evaluation.calendar)
        let reason = context.assessment.anchor != nil ? (totalDaytime.unavailableReason ?? .missing) : context.assessment.unavailableReason
        return NightPredictionAgent(optimalBedtimeStart: routine, optimalBedtimeEnd: nil,
            overtiredRiskTime: nil, expectedNightSleepMinutes: expectedNight, lastNapCutoffTime: cutoff,
            daytimeSleepStatus: sleepStatus, confidence: nil,
            reasoning: [routine == nil ? "General age-based bedtime guidance is available."
                                      : "Routine-based guidance from the saved usual bedtime.", reason.rawValue],
            daytimeSubtotalIsReliable: !totalDaytime.isIncomplete,
            source: routine == nil ? .ageGuidance : .routine, unavailableReason: reason,
            generalBedtimeHours: routine == nil ? profile.bedtimeHourRange : nil)
    }
}
