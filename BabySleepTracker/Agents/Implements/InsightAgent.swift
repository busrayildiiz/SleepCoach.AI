//
//  InsightAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 11.06.2026.

import Foundation

// MARK: - Alert Types

enum AlertSeverity { case info, warning, critical }
enum AlertAction   { case addWakeTime, addNap, addNightSleep }

struct SleepAlert {
    let severity:    AlertSeverity
    let message:     String
    let actionTitle: String?
    let actionType:  AlertAction?
}

// MARK: - Insight Bundle

struct SleepInsightBundle {
    let headline:        String
    let coachTip:        String
    let alerts:          [SleepAlert]
    let weeklyPattern:   String?
    let progressMessage: String
}

// MARK: - Protocol

protocol InsightAgentProtocol {
    func buildInsights(
        phase:         CoachPhase,
        pattern:       BabyPattern?,
        trackedDays:   Int,
        babyName:      String
    ) -> SleepInsightBundle
}

// MARK: - DefaultInsightAgent

final class DefaultInsightAgent: InsightAgentProtocol {
    func buildInsights(phase: CoachPhase, pattern: BabyPattern?, trackedDays: Int, babyName: String) -> SleepInsightBundle {
        let coachTip: String
        if phase == .tooYoung {
            coachTip = "Follow \(babyName)'s sleep cues and record actual sleep and wake times when you can."
        } else {
            coachTip = "Use the recorded wake or nap end when available. General age guidance can help plan the next sleep."
        }
        let recordedNap = pattern?.averageNapDurationMinutes.map { "Recorded naps averaged \(TimeFormat.minutes($0))." }
        return SleepInsightBundle(headline: "General sleep guidance", coachTip: coachTip, alerts: [],
            weeklyPattern: recordedNap, progressMessage: "Recorded on \(trackedDays) day(s). Daily coverage is unconfirmed.")
    }
}
