//
//  NightPredictionAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 13.06.2026.
//

import Foundation

// MARK: - Night Prediction

struct NightPredictionAgent {
    let optimalBedtimeStart:      Date
    let optimalBedtimeEnd:        Date
    let overtiredRiskTime:        Date
    let expectedNightSleepMinutes: Int
    let lastNapCutoffTime:        Date
    let daytimeSleepStatus:       DailySleepStatus
    let confidence:               Int
    let reasoning:                [String]
}

// MARK: - Protocol

protocol NightPredictionAgentProtocol {
    func predictBedtime(
        pattern:          BabyPattern?,
        todayRecords:     [SleepRecord],
        wakeRecords:      [DailyWakeRecord],
        ageMonths:        Int,
        trackedDays:      Int,
        now:              Date
    ) -> NightPredictionAgent
}

// MARK: - DefaultNightPredictionAgent

final class DefaultNightPredictionAgent: NightPredictionAgentProtocol {

    private let calendar:            Calendar
    private let profileProvider:     AgeBasedSleepProfileProviding
    private let overtiredCalculator: OvertiredCalculator

    init(
        profileProvider:     AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        overtiredCalculator: OvertiredCalculator = OvertiredCalculator(),
        calendar:            Calendar = .current
    ) {
        self.profileProvider     = profileProvider
        self.overtiredCalculator = overtiredCalculator
        self.calendar            = calendar
    }

    // MARK: - Predict Bedtime

    func predictBedtime(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date
    ) -> NightPredictionAgent {

        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let breaks  = todayRecords.filter { $0.kind == .break }
        let dayNaps = todayRecords
            .filter { $0.kind == .dayNap }
            .sorted { $0.date < $1.date }

        // Yeterli nap tamamlandıysa gerçek son naptan hesapla,
        // aksi halde fallback (typicalBedtime veya profil saati)
        let completedNapCount = dayNaps.filter { !$0.isOngoing }.count
        let minExpectedNaps   = profile.expectedNapCount.lowerBound

        let lastNapEnd: Date?
        if completedNapCount >= minExpectedNaps {
            lastNapEnd = dayNaps.last(where: { !$0.isOngoing }).map { nap in
                calendar.date(byAdding: .minute, value: nap.duration, to: nap.date) ?? nap.date
            }
        } else {
            lastNapEnd = nil
        }

        // Toplam gündüz uykusu
        let totalDaytime = dayNaps
            .map { $0.totalMinutes(breaks: breaks) }
            .reduce(0, +)

        // Bedtime window hesabı
        let bedtimeWindow: BedtimeWindow

        if let lastNapEnd {
            // Yeterli nap var → son nap bitişinden evening WW ekle
            bedtimeWindow = overtiredCalculator.bedtimeWindow(
                lastNapEndTime:           lastNapEnd,
                totalDaytimeSleepMinutes: totalDaytime,
                ageMonths:                ageMonths,
                now:                      now
            )
        } else {
            // Henüz yeterli nap tamamlanmadı → sabit bedtime göster
            bedtimeWindow = fixedBedtimeWindow(profile: profile, now: now)
        }

        let cutoff = overtiredCalculator.lastNapCutoffTime(ageMonths: ageMonths, on: now)

        let expectedNight = expectedNightSleep(profile: profile, pattern: pattern)

        let sleepStatus = overtiredCalculator.dailySleepStatus(
            totalMinutes: totalDaytime,
            ageMonths:    ageMonths
        )

        let confidence = calculateConfidence(
            trackedDays:   trackedDays,
            hasLastNap:    lastNapEnd != nil,
            hasWakeRecord: todayWakeRecord(wakeRecords: wakeRecords, now: now) != nil,
            hasPattern:    pattern != nil
        )

        let reasoning = buildReasoning(
            profile:      profile,
            lastNapEnd:   lastNapEnd,
            totalDaytime: totalDaytime,
            bedtime:      bedtimeWindow.ideal,
            ageMonths:    ageMonths,
            sleepStatus:  sleepStatus
        )

        return NightPredictionAgent(
            optimalBedtimeStart:       bedtimeWindow.earliest,
            optimalBedtimeEnd:         bedtimeWindow.latest,
            overtiredRiskTime:         bedtimeWindow.overtiredRisk,
            expectedNightSleepMinutes: expectedNight,
            lastNapCutoffTime:         cutoff,
            daytimeSleepStatus:        sleepStatus,
            confidence:                confidence,
            reasoning:                 reasoning
        )
    }

    // MARK: - Fixed Bedtime Window
    // Yeterli nap tamamlanmadan kullanılır.
    // Wake time'a değil, kullanıcının kaydettiği
    // typicalBedtime'a veya profil saatine dayanır.

    private func fixedBedtimeWindow(
        profile: AgeBasedSleepProfile,
        now:     Date
    ) -> BedtimeWindow {

        let today = calendar.startOfDay(for: now)

        let idealBedtime: Date

        let hasSavedBedtime = UserDefaults.standard.object(forKey: "typicalBedHour") != nil

        if hasSavedBedtime {
            let bedHour   = UserDefaults.standard.double(forKey: "typicalBedHour")
            let bedMinute = UserDefaults.standard.double(forKey: "typicalBedMinute")
            idealBedtime  = calendar.date(
                bySettingHour: Int(bedHour),
                minute:        Int(bedMinute),
                second:        0,
                of:            today
            ) ?? today
        } else {
            // Profildeki bedtime range'in ortasını kullan
            let midHour  = (profile.bedtimeHourRange.lowerBound + profile.bedtimeHourRange.upperBound) / 2
            idealBedtime = calendar.date(
                bySettingHour: midHour,
                minute:        0,
                second:        0,
                of:            today
            ) ?? today
        }

        return BedtimeWindow(
            earliest:      idealBedtime.addingMinutes(-30),
            ideal:         idealBedtime,
            latest:        idealBedtime.addingMinutes(30),
            overtiredRisk: idealBedtime.addingMinutes(50),
            risk:          .healthy,
            reasoning:     hasSavedBedtime
                ? "Naps still in progress — showing your saved typical bedtime."
                : "Naps still in progress — showing age-based typical bedtime."
        )
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
        lastNapEnd:   Date?,
        totalDaytime: Int,
        bedtime:      Date,
        ageMonths:    Int,
        sleepStatus:  DailySleepStatus
    ) -> [String] {

        let fmt        = DateFormatter()
        fmt.locale     = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "h:mm a"

        var parts = [String]()

        if let napEnd = lastNapEnd {
            parts.append("Last nap ended at \(fmt.string(from: napEnd)).")
            let ewwCenter = (profile.eveningWakeWindow.lowerBound + profile.eveningWakeWindow.upperBound) / 2
            parts.append("Evening wake window for \(ageMonths)-month-old is ~\(ewwCenter) min.")
        } else {
            parts.append("Not enough naps completed yet — showing estimated bedtime.")
        }

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

    // MARK: - Helper

    private func todayWakeRecord(
        wakeRecords: [DailyWakeRecord],
        now:         Date
    ) -> DailyWakeRecord? {
        wakeRecords.first { calendar.isDate($0.day, inSameDayAs: now) }
    }
}
