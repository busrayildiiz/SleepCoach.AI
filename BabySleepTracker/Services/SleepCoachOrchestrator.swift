//
//  SleepCoachOrchestrator.swift
//  BabySleepTracker
//
//  Created by MacBook on 13.06.2026.
//

import Foundation
import CryptoKit

enum LLMCacheState: Equatable {
    case current
    case stale
    case expired
}

enum NextSleepKind {
    case nap
    case bedtime
}
enum DataQuality: Equatable {
    case poor
    case fair
    case good
    case excellent
}

struct DataQualityReport {
    let score: Int
    let level: DataQuality
    let completenessScore: Int
    let consistencyScore: Int
    let rhythmStabilityScore: Int
    let plausibilityScore: Int
    let plausibilityAnomalyCount: Int
    let plausibilityWarnings: [String]
    let timelinessScore: Int
    let contextRichnessScore: Int
    let contextSignals: [String]
    let missingContextSignals: [String]
    let averageLoggingDelayMinutes: Int?
    let trackedDays: Int
    let completeDays: Int
    let consecutiveMissedDays: Int
    let missingCriticalFields: [String]
    let warnings: [String]
    let confidenceNote: String
}

struct OrchestratedSnapshot {
       let generatedAt:        Date
       let babyName:           String
       let ageMonths:          Int

       // Ajanlardan gelen çıktılar
       let phase:              CoachPhase
       let readiness:          PhaseReadinessReport
       let pattern:            BabyPattern?
       let daytime:            DaytimePredictionAgent
       let night:              NightPredictionAgent
       let transition:         NapTransitionAssessment
       let insights:           SleepInsightBundle
       let dataQualityReport:  DataQualityReport

       // Günlük uyku durumu
       let todayTotalMinutes:  Int
       let sleepStatus:        DailySleepStatus
       let nextSleepKind:      NextSleepKind


}

// MARK: - SleepCoachOrchestrator

@MainActor
final class SleepCoachOrchestrator: ObservableObject {

    // MARK: - Published State

    @Published private(set) var snapshot: OrchestratedSnapshot?
    private var latestGeneratedRecords: [SleepRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var llmResponse: LLMCoachResponse?
    @Published private(set) var isLLMLoading = false
    private(set) var llmCacheState: LLMCacheState = .expired
    private var currentLLMSourceFingerprint: String?
    private var cachedLLMSourceFingerprint: String?

    // MARK: - Agents

    private let phaseAgent:      PhaseAgentProtocol
    private let patternAgent:    PatternAgentProtocol
    private let daytimeAgent:    DaytimePredictionAgentProtocol
    private let nightAgent:      NightPredictionAgentProtocol
    private let transitionAgent: NapTransitionAgentProtocol
    private let insightAgent:    InsightAgentProtocol
    private let overtiredCalc:   OvertiredCalculator
    private let profileProvider: AgeBasedSleepProfileProviding
    private let llmAgent: SleepCoachLLMAgentProtocol
    private let ageCalculator: BabyAgeCalculating
    private var activeLLMTask: Task<Void, Never>?
    private var llmRequestToken = 0

    
    // MARK: - Singleton

       static let shared = SleepCoachOrchestrator()

       // MARK: - Init

       init(
           phaseAgent:      PhaseAgentProtocol      = DefaultPhaseAgent(),
           patternAgent:    PatternAgentProtocol     = PatternAgent(),
           daytimeAgent:    DaytimePredictionAgentProtocol = DefaultDaytimePredictionAgent(),
           nightAgent:      NightPredictionAgentProtocol   = DefaultNightPredictionAgent(),
           transitionAgent: NapTransitionAgentProtocol     = DefaultNapTransitionAgent(),
           insightAgent:    InsightAgentProtocol     = DefaultInsightAgent(),
           llmAgent:        SleepCoachLLMAgentProtocol     = DefaultSleepCoachLLMAgent(),
           overtiredCalc:   OvertiredCalculator      = OvertiredCalculator(),
           profileProvider: AgeBasedSleepProfileProviding  = DefaultAgeBasedSleepProfileProvider(),
           ageCalculator: BabyAgeCalculating = DefaultBabyAgeCalculator()

       ) {
           self.phaseAgent      = phaseAgent
           self.patternAgent    = patternAgent
           self.daytimeAgent    = daytimeAgent
           self.nightAgent      = nightAgent
           self.transitionAgent = transitionAgent
           self.insightAgent    = insightAgent
           self.llmAgent        = llmAgent
           self.overtiredCalc   = overtiredCalc
           self.profileProvider = profileProvider
           self.ageCalculator = ageCalculator

       }

       // MARK: - Generate Snapshot
    func generate(now: Date = Date()) {
        isLoading = true
        defer { isLoading = false }

        // 1. Veriyi yükle ve stale ongoing kayıtları temizle
        let rawRecords     = loadRecords()
        let records        = closeStaleOngoingRecords(rawRecords, now: now)

        let hasChanges = zip(rawRecords, records).contains { old, new in
            old.isOngoing != new.isOngoing || old.duration != new.duration
        }
        if hasChanges {
            saveRecords(records)
        }

        let wakeRecords = loadWakeRecords()
        let babyName = loadBabyName()

        guard let birthDate = loadBabyBirthDate() else {
            snapshot = nil
            return
        }

        let ageMonths = ageCalculator.ageInMonths(
            birthDate: birthDate,
            on: now
        )

        // 2. Temel metrikler
        let breaks    = records.filter { $0.kind == .break }
        let todayRecs = records.filter { Calendar.current.isDateInToday($0.date) }

        let trackedDays = countTrackedDays(
            records:     records,
            wakeRecords: wakeRecords
        )

        let todayTotal = todayRecs
            .filter { $0.kind != .break }
            .reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }

        // 3. Phase
        let phase = phaseAgent.currentPhase(
            ageMonths:   ageMonths,
            trackedDays: trackedDays
        )

        // Wake time ve gece uykusu sinyalleri
        let hasTodayWake = wakeRecords.contains {
            Calendar.current.isDateInToday($0.day)
        }
        let hasYesterdayNight: Bool = {
            guard let yesterday = Calendar.current.date(
                byAdding: .day, value: -1, to: now
            ) else { return false }
            return records.contains {
                $0.kind == .nightSleep &&
                Calendar.current.isDate($0.date, inSameDayAs: yesterday)
            }
        }()

        let readiness = phaseAgent.readinessReport(
            ageMonths:              ageMonths,
            trackedDays:            trackedDays,
            hasTodayWakeTime:       hasTodayWake,
            hasYesterdayNightSleep: hasYesterdayNight
        )

        // 4. Pattern — tooYoung değilse analiz et
        let pattern: BabyPattern?
        if case .tooYoung = phase {
            pattern = nil
        } else {
            pattern = patternAgent.analyze(
                records:     records,
                wakeRecords: wakeRecords,
                ageMonths:   ageMonths,
                now:         now
            )
        }

        // 5. Daytime prediction
        let daytime = daytimeAgent.predictNextNap(
            pattern:      pattern,
            todayRecords: todayRecs,
            wakeRecords:  wakeRecords,
            ageMonths:    ageMonths,
            trackedDays:  trackedDays,
            now:          now
        )

        // 6. Night prediction
        let night = nightAgent.predictBedtime(
            pattern:      pattern,
            todayRecords: todayRecs,
            wakeRecords:  wakeRecords,
            ageMonths:    ageMonths,
            trackedDays:  trackedDays,
            now:          now
        )

        // 7. nextSleepKind
        let todayDayNapsCount = todayRecs.filter { $0.kind == .dayNap }.count
        let profile           = profileProvider.profile(forAgeMonths: ageMonths)
        let expectedNaps      = profile.expectedNapCount

        let nextSleepKind: NextSleepKind = {
            let cutoff = overtiredCalc.lastNapCutoffTime(ageMonths: ageMonths, on: now)
            guard now < cutoff else { return .bedtime }
            if todayDayNapsCount >= expectedNaps.upperBound { return .bedtime }
            return .nap
        }()

        // 8. Nap transition
        let transition = transitionAgent.assess(
            records:     records,
            wakeRecords: wakeRecords,
            ageMonths:   ageMonths,
            now:         now
        )

        // 9. Insights
        let insights = insightAgent.buildInsights(
            phase:       phase,
            pattern:     pattern,
            trackedDays: trackedDays,
            babyName:    babyName
        )

        let dataQualityReport = makeDataQualityReport(
            records: records,
            wakeRecords: wakeRecords,
            now: now
        )

        // 10. Sleep status
        let sleepStatus = overtiredCalc.dailySleepStatus(
            totalMinutes: todayTotal,
            ageMonths:    ageMonths
        )

        // 11. Snapshot oluştur
        let result = OrchestratedSnapshot(
            generatedAt:       now,
            babyName:          babyName,
            ageMonths:         ageMonths,
            phase:             phase,
            readiness:         readiness,
            pattern:           pattern,
            daytime:           daytime,
            night:             night,
            transition:        transition,
            insights:          insights,
            dataQualityReport: dataQualityReport,
            todayTotalMinutes: todayTotal,
            sleepStatus:       sleepStatus,
            nextSleepKind:     nextSleepKind
        )
        let previousSnapshot = snapshot
        self.snapshot = result
        latestGeneratedRecords = records
        currentLLMSourceFingerprint = llmSourceFingerprint(
            snapshot: result,
            records: records
        )

        let trigger = determineTrigger(
            records:  records,
            snapshot: result,
            previous: previousSnapshot
        )

        if let trigger {
            startLLMRequest(snapshot: result, records: records, trigger: trigger)
        }
        updateLLMCacheState()
    }

            // MARK: - Data Loaders

            private func loadRecords() -> [SleepRecord] {
                guard let data = UserDefaults.standard.data(forKey: "sleepRecords"),
                      let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data)
                else { return [] }
                return decoded
            }
    private func closeStaleOngoingRecords(
        _ records: [SleepRecord],
        now: Date
    ) -> [SleepRecord] {
        let calendar = Calendar.current
        let wakeHour   = UserDefaults.standard.object(forKey: "typicalWakeHour")   as? Double ?? 7.0
        let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0

        let today = calendar.startOfDay(for: now)
        let typicalWake = calendar.date(
            bySettingHour:   Int(wakeHour),
            minute:          Int(wakeMinute),
            second:          0,
            of:              today
        ) ?? today

        return records.map { record in
            guard record.isOngoing else { return record }
            let startedToday = calendar.isDate(record.date, inSameDayAs: now)

            // Night sleep özel case: dün gece başlamış, bugün typicalWake'den önce → kapat
            let startedYesterday: Bool = {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
                return calendar.isDate(record.date, inSameDayAs: yesterday)
            }()

            let shouldClose: Bool
            if startedToday {
                // Bugün başlamış → yarının typicalWake'ini bekle
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return record }
                let tomorrowWake = calendar.date(
                    bySettingHour: Int(wakeHour), minute: Int(wakeMinute), second: 0, of: tomorrow
                ) ?? tomorrow
                shouldClose = now >= tomorrowWake

            } else if startedYesterday && record.kind == .nightSleep {
                // Dün gece başlamış night sleep → bugünün typicalWake'ini geçtiyse kapat
                shouldClose = now >= typicalWake

            } else {
                // 2+ gün önce başlamış → kesinlikle kapat
                shouldClose = true
            }

            guard shouldClose else { return record }

            // Makul bir süre hesapla
            let rawMinutes = Int(now.timeIntervalSince(record.date) / 60)
            let maxMinutes: Int
            switch record.kind {
            case .nightSleep: maxMinutes = 12 * 60   // max 12 saat
            case .dayNap:     maxMinutes = 3  * 60   // max 3 saat
            default:          maxMinutes = 60
            }
            let duration = min(rawMinutes, maxMinutes)

            return SleepRecord(
                id:          record.id,
                date:        record.date,
                duration:    duration,
                kind:        record.kind,
                parentNapID: record.parentNapID,
                isOngoing:   false,             // ← kapatıldı
                createdAt:   record.createdAt
            )
        }
    }

            private func loadWakeRecords() -> [DailyWakeRecord] {
                guard let data = UserDefaults.standard.data(forKey: "dailyWakeRecords_v1"),
                      let decoded = try? JSONDecoder().decode([DailyWakeRecord].self, from: data)
                else { return [] }
                return decoded
            }

            private func loadBabyName() -> String {
                let name = UserDefaults.standard.string(forKey: "babyName")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty ? "Baby" : name
            }

    private func loadBabyBirthDate() -> Date? {
        if let date = UserDefaults.standard.object(forKey: "babyBirthDate") as? Date {
            return date
        }

        if let timestamp = UserDefaults.standard.object(forKey: "babyBirthDate") as? Double {
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }

            private func countTrackedDays(
                records:     [SleepRecord],
                wakeRecords: [DailyWakeRecord]
            ) -> Int {
                let sleepDays = records.map { Calendar.current.startOfDay(for: $0.date) }
                let wakeDays  = wakeRecords.map { Calendar.current.startOfDay(for: $0.day) }
                return Set(sleepDays + wakeDays).count
            }

            // MARK: - Cache

            private func cache(_ snapshot: OrchestratedSnapshot) {
                // Sadece basit değerleri cache'le — Date'ler UserDefaults'a direkt gider
                UserDefaults.standard.set(
                    snapshot.generatedAt.timeIntervalSince1970,
                    forKey: "orchestrator_lastGenerated"
                )
            }
    
    // MARK: - Save Records
    
    private func saveRecords(_ records: [SleepRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: "sleepRecords")
        // View'ları tetikle
        NotificationCenter.default.post(name: .sleepRecordsDidChange, object: nil)
    }
    // MARK: - Data Quality

    private func makeDataQualityReport(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        now: Date
    ) -> DataQualityReport {
        let calendar = Calendar.current
        let breaks = records.filter { $0.kind == .break }
        let lookbackDays = 14
        let today = calendar.startOfDay(for: now)

        var dailyScores: [Int] = []
        var completeDays = 0
        var trackedDays = 0
        var missedStreak = 0
        var longestRecentMissedStreak = 0
        var missingCriticalFields = Set<String>()

        for offset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }

            let dayRecords = records.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let naps = dayRecords.filter { $0.kind == .dayNap }
            let nightSleeps = dayRecords.filter { $0.kind == .nightSleep }
            let hasWake = wakeRecords.contains { calendar.isDate($0.day, inSameDayAs: day) }

            var dayScore = 0
            if hasWake { dayScore += 25 } else { missingCriticalFields.insert("daily wake time") }
            if !naps.isEmpty { dayScore += 25 } else { missingCriticalFields.insert("day naps") }
            if !nightSleeps.isEmpty { dayScore += 35 } else { missingCriticalFields.insert("night sleep") }
            if dayRecords.contains(where: { $0.kind != .break }) { dayScore += 15 }

            dailyScores.append(dayScore)

            if dayScore > 0 {
                trackedDays += 1
                missedStreak = 0
            } else {
                missedStreak += 1
                longestRecentMissedStreak = max(longestRecentMissedStreak, missedStreak)
            }

            if dayScore >= 70 {
                completeDays += 1
            }
        }

        let completeness = dailyScores.isEmpty ? 0 : dailyScores.reduce(0, +) / dailyScores.count
        let coverageConsistency = Int((Double(completeDays) / Double(lookbackDays)) * 100)
        let rhythmStability = rhythmStabilityScore(
            records: records,
            wakeRecords: wakeRecords,
            now: now
        )
        let consistency = clamp(Int(Double(coverageConsistency) * 0.55 + Double(rhythmStability) * 0.45))
        let plausibility = plausibilityResult(records: records, breaks: breaks, now: now)
        let timeliness = timelinessResult(records: records)
        let contextRichness = contextRichnessResult(
            records: records,
            wakeRecords: wakeRecords,
            completeDays: completeDays
        )

        let score = clamp(
            Int(
                Double(completeness) * 0.30 +
                Double(timeliness.score) * 0.20 +
                Double(consistency) * 0.20 +
                Double(plausibility.score) * 0.20 +
                Double(contextRichness.score) * 0.10
            )
        )

        let warnings = dataQualityWarnings(
            records: records,
            breaks: breaks,
            completeDays: completeDays,
            missedStreak: longestRecentMissedStreak,
            consistency: consistency,
            rhythmStability: rhythmStability,
            plausibility: plausibility.score,
            plausibilityWarnings: plausibility.warnings,
            contextRichness: contextRichness.score
        )

        return DataQualityReport(
            score: score,
            level: quality(forScore: score),
            completenessScore: clamp(completeness),
            consistencyScore: clamp(consistency),
            rhythmStabilityScore: rhythmStability,
            plausibilityScore: plausibility.score,
            plausibilityAnomalyCount: plausibility.anomalyCount,
            plausibilityWarnings: plausibility.warnings,
            timelinessScore: timeliness.score,
            contextRichnessScore: contextRichness.score,
            contextSignals: contextRichness.signals,
            missingContextSignals: contextRichness.missingSignals,
            averageLoggingDelayMinutes: timeliness.averageDelayMinutes,
            trackedDays: trackedDays,
            completeDays: completeDays,
            consecutiveMissedDays: longestRecentMissedStreak,
            missingCriticalFields: Array(missingCriticalFields).sorted(),
            warnings: warnings,
            confidenceNote: confidenceNote(forScore: score, warnings: warnings)
        )
    }

    private func plausibilityResult(
        records: [SleepRecord],
        breaks: [SleepRecord],
        now: Date
    ) -> (score: Int, anomalyCount: Int, warnings: [String]) {
        guard !records.isEmpty else { return (0, 0, []) }

        var warnings = Set<String>()
        var anomalyCount = 0
        let sleepRecords = records.filter { $0.kind != .break }

        for record in records {
            let netMinutes = record.totalMinutes(breaks: breaks)
            let hasNegativeDuration = record.duration < 0
            let startsInFuture = record.date > now.addingTimeInterval(5 * 60)

            let durationIsImplausible: Bool
            switch record.kind {
            case .dayNap:
                durationIsImplausible = !record.isOngoing && !(5...240).contains(netMinutes)
            case .nightSleep:
                durationIsImplausible = !record.isOngoing && !(120...780).contains(netMinutes)
            case .break:
                durationIsImplausible = !(1...180).contains(record.duration)
            }

            if hasNegativeDuration {
                anomalyCount += 1
                warnings.insert("A record has negative duration.")
            }
            if startsInFuture {
                anomalyCount += 1
                warnings.insert("A record starts in the future.")
            }
            if durationIsImplausible {
                anomalyCount += 1
                switch record.kind {
                case .dayNap:
                    warnings.insert("A day nap duration is outside the expected 5-240 minute range.")
                case .nightSleep:
                    warnings.insert("A night sleep duration is outside the expected 2-13 hour range.")
                case .break:
                    warnings.insert("A wake period duration is outside the expected 1-180 minute range.")
                }
            }

            if record.kind == .break, record.parentNapID == nil {
                anomalyCount += 1
                warnings.insert("A wake period is not attached to a sleep record.")
            }

            if record.kind == .break,
               let parentNapID = record.parentNapID,
               let parent = records.first(where: { $0.id == parentNapID }) {
                let parentEnd = parent.date.addingTimeInterval(Double(parent.effectiveDuration) * 60)
                let breakEnd = record.date.addingTimeInterval(Double(record.duration) * 60)
                if record.date < parent.date || breakEnd > parentEnd {
                    anomalyCount += 1
                    warnings.insert("A wake period falls outside its parent sleep interval.")
                }
            }
        }

        let sortedSleepRecords = sleepRecords.sorted { $0.date < $1.date }
        for pair in zip(sortedSleepRecords, sortedSleepRecords.dropFirst()) {
            let firstEnd = pair.0.date.addingTimeInterval(Double(pair.0.effectiveDuration) * 60)
            if pair.1.date < firstEnd {
                anomalyCount += 1
                warnings.insert("Two sleep records overlap in time.")
            }
        }

        let dailyGroups = Dictionary(grouping: sleepRecords) { Calendar.current.startOfDay(for: $0.date) }
        for dayRecords in dailyGroups.values {
            let dayTotal = dayRecords.reduce(0) { $0 + $1.totalMinutes(breaks: breaks) }
            if dayTotal > 20 * 60 {
                anomalyCount += 1
                warnings.insert("A day has more than 20 hours of total sleep.")
            }
        }

        let penalty = min(70, anomalyCount * 15)
        return (max(0, 100 - penalty), anomalyCount, Array(warnings).sorted())
    }

    private func timelinessResult(records: [SleepRecord]) -> (score: Int, averageDelayMinutes: Int?) {
        let sleepRecords = records.filter { $0.kind != .break }
        guard !sleepRecords.isEmpty else { return (0, nil) }

        let delays = sleepRecords.map { record in
            max(0, Int(record.createdAt.timeIntervalSince(record.date) / 60))
        }
        let averageDelay = delays.reduce(0, +) / delays.count

        let scoredDelays = delays.map { delay -> Int in
            switch delay {
            case 0...30:     return 100
            case 31...180:   return 75
            case 181...720:  return 50
            case 721...1440: return 25
            default:         return 10
            }
        }

        return (scoredDelays.reduce(0, +) / scoredDelays.count, averageDelay)
    }

    private func rhythmStabilityScore(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        now: Date
    ) -> Int {
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)) else {
            return 0
        }

        let recentRecords = records.filter { $0.date >= windowStart && $0.kind != .break }
        let recentWakeRecords = wakeRecords.filter { $0.day >= windowStart }

        var components: [Int] = []

        let wakeMinutes = recentWakeRecords.map { minutesSinceStartOfDay($0.wakeTime) }
        if let score = stabilityScore(for: wakeMinutes, excellentSpread: 30, poorSpread: 150) {
            components.append(score)
        }

        let nightStartMinutes = recentRecords
            .filter { $0.kind == .nightSleep }
            .map { minutesSinceStartOfDay($0.date) }
        if let score = stabilityScore(for: nightStartMinutes, excellentSpread: 45, poorSpread: 180) {
            components.append(score)
        }

        let dayNaps = recentRecords.filter { $0.kind == .dayNap }
        let napsByDay = Dictionary(grouping: dayNaps) { calendar.startOfDay(for: $0.date) }
        let napCounts = napsByDay.values.map { $0.count }
        if let score = stabilityScore(for: napCounts, excellentSpread: 1, poorSpread: 3) {
            components.append(score)
        }

        guard !components.isEmpty else { return 0 }
        return clamp(components.reduce(0, +) / components.count)
    }

    private func contextRichnessResult(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        completeDays: Int
    ) -> (score: Int, signals: [String], missingSignals: [String]) {
        var score = 0
        var signals: [String] = []
        var missingSignals: [String] = []

        if !wakeRecords.isEmpty {
            score += 25
            signals.append("wake times")
        } else {
            missingSignals.append("wake times")
        }

        if records.contains(where: { $0.kind == .dayNap }) {
            score += 20
            signals.append("day naps")
        } else {
            missingSignals.append("day naps")
        }

        if records.contains(where: { $0.kind == .nightSleep }) {
            score += 20
            signals.append("night sleep")
        } else {
            missingSignals.append("night sleep")
        }

        if records.contains(where: { $0.kind == .break }) {
            score += 15
            signals.append("wake periods")
        } else {
            missingSignals.append("wake periods")
        }

        if completeDays >= 7 {
            score += 20
            signals.append("multi-day coverage")
        } else {
            missingSignals.append("7+ complete days")
        }

        return (clamp(score), signals, missingSignals)
    }

    private func stabilityScore(
        for values: [Int],
        excellentSpread: Double,
        poorSpread: Double
    ) -> Int? {
        guard values.count >= 3 else { return nil }
        let spread = standardDeviation(values)
        if spread <= excellentSpread { return 100 }
        if spread >= poorSpread { return 35 }

        let normalized = (spread - excellentSpread) / (poorSpread - excellentSpread)
        return clamp(Int(100 - normalized * 65))
    }

    private func standardDeviation(_ values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = Double(values.reduce(0, +)) / Double(values.count)
        let variance = values
            .map { pow(Double($0) - average, 2) }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    private func minutesSinceStartOfDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func dataQualityWarnings(
        records: [SleepRecord],
        breaks: [SleepRecord],
        completeDays: Int,
        missedStreak: Int,
        consistency: Int,
        rhythmStability: Int,
        plausibility: Int,
        plausibilityWarnings: [String],
        contextRichness: Int
    ) -> [String] {
        var warnings: [String] = []

        if completeDays < 7 {
            warnings.append("Fewer than 7 complete days in the last 14 days.")
        }
        if missedStreak >= 2 {
            warnings.append("\(missedStreak) consecutive missed day(s) increase prediction variance.")
        }
        if consistency < 70 {
            warnings.append("Tracking consistency is low across the last 14 days.")
        }
        if rhythmStability < 70 {
            warnings.append("Sleep timing varies enough to make pattern learning less stable.")
        }
        if plausibility < 80 {
            warnings.append("Some sleep durations look unusual and should be reviewed.")
        }
        warnings.append(contentsOf: plausibilityWarnings.prefix(3))
        if contextRichness < 60 {
            warnings.append("Context is thin, so recommendations should stay more general.")
        }
        let timeliness = timelinessResult(records: records)
        if timeliness.score < 70, let averageDelay = timeliness.averageDelayMinutes {
            warnings.append("Average logging delay is \(averageDelay) minutes, which lowers prediction reliability.")
        }
        if !records.contains(where: { $0.kind == .nightSleep }) {
            warnings.append("Night sleep is missing, so bedtime predictions should stay conservative.")
        }
        if !records.contains(where: { $0.kind == .dayNap }) {
            warnings.append("Day naps are missing, so wake-window learning is limited.")
        }

        return warnings
    }

    private func quality(forScore score: Int) -> DataQuality {
        switch score {
        case 0..<50:  return .poor
        case 50..<70: return .fair
        case 70..<90: return .good
        default:      return .excellent
        }
    }

    private func confidenceNote(forScore score: Int, warnings: [String]) -> String {
        if score >= 90 {
            return "High reliability: recent sleep data is complete and consistent."
        }
        if score >= 70 {
            return "Good reliability: predictions can be personalized, with a few caveats."
        }
        if score >= 50 {
            return "Medium reliability: use a blend of personal pattern and age baseline."
        }
        return "Low reliability: keep guidance general until more complete daily records are logged."
    }

    private func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
    // MARK: - LLM

    private func startLLMRequest(
        snapshot: OrchestratedSnapshot,
        records: [SleepRecord],
        trigger: LLMTrigger
    ) {
        activeLLMTask?.cancel()
        llmRequestToken += 1
        let requestToken = llmRequestToken
        isLLMLoading = true
        let sourceFingerprint = llmSourceFingerprint(
            snapshot: snapshot,
            records: records
        )

        activeLLMTask = Task { [weak self] in
            await self?.callLLM(
                snapshot: snapshot,
                records: records,
                trigger: trigger,
                sourceFingerprint: sourceFingerprint,
                requestToken: requestToken
            )
        }
    }

    private func callLLM(
        snapshot: OrchestratedSnapshot,
        records:  [SleepRecord],
        trigger:  LLMTrigger,
        sourceFingerprint: String,
        requestToken: Int
    ) async {
        let response = await llmAgent.generateInsight(
            snapshot: snapshot,
            records:  records,
            trigger:  trigger
        )

        guard requestToken == llmRequestToken else { return }

        if let response {
            llmResponse = response
            cacheLLMResponse(response, sourceFingerprint: sourceFingerprint)
        }

        isLLMLoading = false
        activeLLMTask = nil
    }

    private func determineTrigger(
        records:  [SleepRecord],
        snapshot: OrchestratedSnapshot,
        previous: OrchestratedSnapshot?
    ) -> LLMTrigger? {

        // Daha önce hiç LLM çağrısı yapılmadıysa
        guard let lastGenerated = loadLastLLMDate() else {
            return .newDayStarted
        }

        let cal   = Calendar.current
        let now   = Date()

        // Yeni gün başladıysa
        if !cal.isDate(lastGenerated, inSameDayAs: now) {
            return .newDayStarted
        }

        // Yeni nap eklendiyse — önceki snapshot'tan fazla kayıt var mı?
        let prevCount    = previous?.todayTotalMinutes ?? 0
        let currentCount = snapshot.todayTotalMinutes
        if currentCount > prevCount {
            // Kısa nap mı?
            let todayNaps = records
                .filter { $0.kind == .dayNap && cal.isDateInToday($0.date) }
                .sorted { $0.date > $1.date }

            if let lastNap = todayNaps.first, lastNap.duration < 45 {
                return .shortNapDetected
            }
            return .napLogged
        }

        // Transition sinyali güçlendiyse
        if snapshot.transition.signalStrength == .strong {
            return .transitionSignalHigh
        }

        // Haftalık review — son LLM'den 7 gün geçtiyse
        let daysSinceLast = cal.dateComponents([.day], from: lastGenerated, to: now).day ?? 0
        if daysSinceLast >= 7 {
            return .weeklyReview
        }

        // Trigger yok — LLM çağırma
        return nil
    }

    // MARK: - LLM Cache

    private func cacheLLMResponse(_ response: LLMCoachResponse, sourceFingerprint: String) {
        UserDefaults.standard.set(
            response.generatedAt.timeIntervalSince1970,
            forKey: "llm_lastGenerated"
        )
        // Mesajları da sakla
        UserDefaults.standard.set(response.coachMessage,   forKey: "llm_coachMessage")
        UserDefaults.standard.set(response.patternInsight, forKey: "llm_patternInsight")
        UserDefaults.standard.set(response.confidenceNote, forKey: "llm_confidenceNote")
        UserDefaults.standard.set(sourceFingerprint, forKey: "llm_sourceFingerprint")
        cachedLLMSourceFingerprint = sourceFingerprint
        llmCacheState = .current
        if let alert = response.alert {
            UserDefaults.standard.set(alert, forKey: "llm_alert")
        } else {
            UserDefaults.standard.removeObject(forKey: "llm_alert")
        }
    }

    private func loadLastLLMDate() -> Date? {
        let ts = UserDefaults.standard.double(forKey: "llm_lastGenerated")
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    // Uygulama açılışında cached LLM response'u yükle
    func loadCachedLLMResponse() {
        guard let coachMessage = UserDefaults.standard.string(forKey: "llm_coachMessage"),
              !coachMessage.isEmpty,
              let lastDate = loadLastLLMDate()
        else {
            llmCacheState = .expired
            return
        }

        // 24 saatten eski cache'i yükleme
        guard Date().timeIntervalSince(lastDate) < 86400 else {
            llmCacheState = .expired
            return
        }

        cachedLLMSourceFingerprint = UserDefaults.standard.string(forKey: "llm_sourceFingerprint")

        llmResponse = LLMCoachResponse(
            patternInsight: UserDefaults.standard.string(forKey: "llm_patternInsight") ?? "",
            coachMessage:   coachMessage,
            alert:          UserDefaults.standard.string(forKey: "llm_alert"),
            confidenceNote: UserDefaults.standard.string(forKey: "llm_confidenceNote") ?? "",
            generatedAt:    lastDate
        )
        updateLLMCacheState()
    }

    private func updateLLMCacheState() {
        guard llmResponse != nil else {
            llmCacheState = .expired
            return
        }
        guard let cachedLLMSourceFingerprint else {
            llmCacheState = .stale
            return
        }
        llmCacheState = cachedLLMSourceFingerprint == currentLLMSourceFingerprint ? .current : .stale
    }

    private func llmSourceFingerprint(
        snapshot: OrchestratedSnapshot,
        records: [SleepRecord]
    ) -> String {
        var source = "prompt-version:1|model:gemini-2.5-flash"
        source += "|snapshot:" + canonicalSnapshot(snapshot)
        source += "|records:"
        for record in records.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            source += "\(record.id.uuidString),\(record.date.timeIntervalSince1970),\(record.duration),\(String(reflecting: record.kind)),\(record.parentNapID?.uuidString ?? "nil"),\(record.isOngoing),\(record.createdAt.timeIntervalSince1970);"
        }
        source += "|profile:"
        source += UserDefaults.standard.string(forKey: "babyName") ?? ""
        source += "|birthDate:\(UserDefaults.standard.object(forKey: "babyBirthDate") as? Date ?? Date.distantPast)"
        source += "|wakeHour:\(UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0)"
        source += "|wakeMinute:\(UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalSnapshot(_ snapshot: OrchestratedSnapshot) -> String {
        [
            "babyName=\(snapshot.babyName)",
            "ageMonths=\(snapshot.ageMonths)",
            "phase=\(String(reflecting: snapshot.phase))",
            "readiness=\(String(reflecting: snapshot.readiness))",
            "pattern=\(String(reflecting: snapshot.pattern))",
            "daytime=\(String(reflecting: snapshot.daytime))",
            "night=\(String(reflecting: snapshot.night))",
            "transition=\(String(reflecting: snapshot.transition))",
            "insights=\(String(reflecting: snapshot.insights))",
            "quality=\(String(reflecting: snapshot.dataQualityReport))",
            "todayTotalMinutes=\(snapshot.todayTotalMinutes)",
            "sleepStatus=\(String(reflecting: snapshot.sleepStatus))",
            "nextSleepKind=\(String(reflecting: snapshot.nextSleepKind))"
        ].joined(separator: "|")
    }

    // Manuel refresh — kullanıcı istediğinde
    func refreshLLM() {
        guard let current = snapshot else { return }

        startLLMRequest(
            snapshot: current,
            records: latestGeneratedRecords,
            trigger: .manualRefresh
        )
    }
        }
