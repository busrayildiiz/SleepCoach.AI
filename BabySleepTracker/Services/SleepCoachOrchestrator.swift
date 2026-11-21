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
    let rhythmStabilityScore: Int?
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
       let todayTotalMinutes:  Int?
       let sleepStatus:        DailySleepStatus?
       let nextSleepKind:      NextSleepKind
    var sleepDayIsProvisional: Bool = true
    var rolling24hMinutes: Int? = nil
    var daytimeMinutes: Int? = nil
    var subtotalsAreReliable: Bool = true
    var rolling24hIsProvisional: Bool = false
    var recordedSleepDay: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var recordedRolling24h: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var recordedDaytime: CompletedRecordedSubtotal = .incomplete(nil, reason: .missing)
    var evaluationCalendar: Calendar = .current
    var evaluationRoutine: SleepRoutine? = nil
    var evaluationWake: Date? = nil
    var sleepAssessment: SleepStateAssessment? = nil
    var currentSleepKind: SleepKind? { sleepAssessment?.active?.record.kind }
    var hasCurrentSleep: Bool { currentSleepKind != nil }


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
    @Published private(set) var llmCacheState: LLMCacheState = .expired
    var currentCoaching: LLMCoachResponse? { llmCacheState == .current ? llmResponse : nil }
    private var currentLLMSourceFingerprint: String?
    private var cachedLLMSourceFingerprint: String?

    // MARK: - Agents

    private let phaseAgent:      PhaseAgentProtocol
    private let patternAgent:    PatternAgentProtocol?
    private let daytimeAgent:    DaytimePredictionAgentProtocol
    private let nightAgent:      NightPredictionAgentProtocol
    private let transitionAgent: NapTransitionAgentProtocol?
    private let insightAgent:    InsightAgentProtocol
    private let overtiredCalc:   OvertiredCalculator
    private let profileProvider: AgeBasedSleepProfileProviding
    private let llmAgent: SleepCoachLLMAgentProtocol
    private let ageCalculator: BabyAgeCalculating?
    private let calendar: Calendar
    private var activeLLMTask: Task<Void, Never>?
    private var llmRequestToken = 0
    private var previousTriggerSleepMinutes: Int?

    
    // MARK: - Singleton

       static let shared: SleepCoachOrchestrator = {
           #if DEBUG && targetEnvironment(simulator)
           if ProcessInfo.processInfo.environment["RECORDING_UI_TESTS"] == "1" {
               return SleepCoachOrchestrator(llmAgent: RecordingUITestLLMAgent())
           }
           #endif
           return SleepCoachOrchestrator()
       }()

       // MARK: - Init

       init(
           phaseAgent:      PhaseAgentProtocol      = DefaultPhaseAgent(),
           patternAgent:    PatternAgentProtocol? = nil,
           daytimeAgent:    DaytimePredictionAgentProtocol? = nil,
           nightAgent:      NightPredictionAgentProtocol? = nil,
           transitionAgent: NapTransitionAgentProtocol? = nil,
           insightAgent:    InsightAgentProtocol     = DefaultInsightAgent(),
           llmAgent:        SleepCoachLLMAgentProtocol     = DefaultSleepCoachLLMAgent(),
           overtiredCalc:   OvertiredCalculator? = nil,
           profileProvider: AgeBasedSleepProfileProviding  = DefaultAgeBasedSleepProfileProvider(),
           ageCalculator: BabyAgeCalculating? = nil,
           calendar: Calendar = .autoupdatingCurrent

       ) {
           self.phaseAgent      = phaseAgent
           self.patternAgent    = patternAgent
           self.daytimeAgent    = daytimeAgent ?? DefaultDaytimePredictionAgent(profileProvider: profileProvider, calendar: calendar)
           self.nightAgent      = nightAgent ?? DefaultNightPredictionAgent(profileProvider: profileProvider, calendar: calendar)
           self.transitionAgent = transitionAgent
           self.insightAgent    = insightAgent
           self.llmAgent        = llmAgent
           self.overtiredCalc   = overtiredCalc ?? OvertiredCalculator(profileProvider: profileProvider, calendar: calendar)
           self.profileProvider = profileProvider
           self.ageCalculator = ageCalculator
           self.calendar = calendar

       }

       // MARK: - Generate Snapshot
    func generate(now: Date = Date(), confirmation: StillSleepingConfirmation? = nil,
                  requestCoaching: Bool = true) {
        isLoading = true
        defer { isLoading = false }

        // Analytics never converts a presumed wake time into a confirmed observation.
        let records = loadRecords()

        let wakeRecords = loadWakeRecords()
        let babyName = loadBabyName()

        guard let birthDate = loadBabyBirthDate() else {
            if requestCoaching { previousTriggerSleepMinutes = nil }
            updateLLMSource(nil)
            latestGeneratedRecords = []
            snapshot = nil
            return
        }

        let evaluationCalendar = DaytimeReviewWindow.capture(calendar)
        let ageMonths = (ageCalculator ?? DefaultBabyAgeCalculator(calendar: evaluationCalendar)).ageInMonths(
            birthDate: birthDate,
            on: now
        )

        // 2. Temel metrikler
        let evaluation = SleepEvaluation(now: now, calendar: evaluationCalendar, routine: .load(defaults: .standard),
                                         confirmation: confirmation, instant: ContinuousClock.now)
        let planning = SleepPredictionContext(records: records, wakes: wakeRecords, evaluation: evaluation)
        let accounting = planning.accounting
        let todayRecs = accounting.records(on: now)
        let recordedDay = accounting.completedSubtotal(on: now)
        let rolling = accounting.completedRolling24h
        let recordedDaytime = accounting.completedSubtotal(on: now, kind: .dayNap)

        let trackedDays = countTrackedDays(
            records:     records,
            wakeRecords: wakeRecords, calendar: evaluationCalendar
        )


        // Legacy phase information only gates age-appropriate pattern summaries.
        // Tracking frequency is not personalization authority.
        let phase = phaseAgent.currentPhase(
            ageMonths:   ageMonths,
            trackedDays: trackedDays
        )

        // Wake time ve gece uykusu sinyalleri
        let hasTodayWake = planning.assessment.recordedWake != nil
        let hasYesterdayNight: Bool = {
            guard let yesterday = evaluationCalendar.date(
                byAdding: .day, value: -1, to: now
            ) else { return false }
            return records.contains {
                $0.kind == .nightSleep &&
                $0.completedEnd(at: now) != nil && evaluationCalendar.isDate($0.date, inSameDayAs: yesterday)
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
            pattern = (patternAgent ?? PatternAgent(calendar: evaluationCalendar)).analyze(
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
            now:          now,
            planning:     planning
        )

        // 6. Night prediction
        let night = nightAgent.predictBedtime(
            pattern:      pattern,
            todayRecords: todayRecs,
            wakeRecords:  wakeRecords,
            ageMonths:    ageMonths,
            trackedDays:  trackedDays,
            now:          now,
            planning:     planning
        )

        // 7. nextSleepKind
        let nextSleepKind: NextSleepKind = {
            if let current = planning.assessment.active { return current.record.kind == .nightSleep ? .bedtime : .nap }
            let cutoff = overtiredCalc.lastNapCutoffTime(ageMonths: ageMonths, on: now, using: evaluationCalendar)
            guard now < cutoff else { return .bedtime }
            if let proposedNap = daytime.recommendation.value, proposedNap >= cutoff { return .bedtime }
            let expectedNaps = profileProvider.profile(forAgeMonths: ageMonths).expectedNapCount
            return recordedNapCountForPlanning(accounting: accounting, wakeRecords: wakeRecords) >= expectedNaps.upperBound
                ? .bedtime : .nap
        }()

        // 8. Nap transition
        let transition = (transitionAgent ?? DefaultNapTransitionAgent(profileProvider: profileProvider,
                                                                       calendar: evaluationCalendar)).assess(
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
            accounting: accounting, wakeRecords: wakeRecords
        )

        // 10. Sleep status
        let sleepStatus = rolling.comparableMinutes.map {
            overtiredCalc.dailySleepStatus(totalMinutes: $0, ageMonths: ageMonths)
        }
        let uncertainTotals = [recordedDay, rolling, recordedDaytime].contains {
            $0.unavailableReason == .conflict || $0.unavailableReason == .unresolvedBreak
        }

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
            todayTotalMinutes: recordedDay.minutes,
            sleepStatus:       sleepStatus,
            nextSleepKind:     nextSleepKind,
            sleepDayIsProvisional: recordedDay.isIncomplete,
            rolling24hMinutes: rolling.minutes,
            daytimeMinutes: recordedDaytime.minutes,
            subtotalsAreReliable: !uncertainTotals,
            rolling24hIsProvisional: rolling.isIncomplete,
            recordedSleepDay: recordedDay, recordedRolling24h: rolling, recordedDaytime: recordedDaytime,
            evaluationCalendar: evaluationCalendar, evaluationRoutine: evaluation.routine,
            evaluationWake: planning.assessment.recordedWake?.wakeTime,
            sleepAssessment: planning.assessment
        )
        latestGeneratedRecords = records
        updateLLMSource(llmSourceFingerprint(snapshot: result, records: records))
        self.snapshot = result

        if requestCoaching {
            let trigger = determineTrigger(records: records, snapshot: result, previousMinutes: previousTriggerSleepMinutes)
            previousTriggerSleepMinutes = recordedDaytime.minutes
            if let trigger { startLLMRequest(snapshot: result, records: records, trigger: trigger) }
        }
        updateLLMCacheState()
    }

    /// Completed boundaries can inform the next plan even when net duration or day coverage is unknown.
    private func recordedNapCountForPlanning(accounting: SleepAccounting, wakeRecords: [DailyWakeRecord]) -> Int {
        let now = accounting.now
        let calendar = accounting.calendar
        let sleeps = accounting.records.filter { $0.kind != .break }
        let wakes = wakeRecords.filter { $0.isObserved(on: now, at: now, calendar: calendar) }
        return sleeps.indices.filter { index in
            let nap = sleeps[index]
            guard nap.kind == .dayNap, let end = nap.completedEnd(at: now),
                  calendar.isDate(nap.date, inSameDayAs: now),
                  !wakes.contains(where: { nap.date < $0.wakeTime && $0.wakeTime < end })
            else { return false }
            return !sleeps.indices.contains { otherIndex in
                guard otherIndex != index else { return false }
                let other = sleeps[otherIndex]
                if other.id == nap.id { return true }
                guard other.date < end else { return false }
                if let otherEnd = other.completedEnd(at: now) { return otherEnd > nap.date }
                // A known onset inside the nap conflicts. An older open record has no observed end.
                return other.date >= nap.date
            }
        }.count
    }

            // MARK: - Data Loaders

            private func loadRecords() -> [SleepRecord] {
                SleepRecordPersistence().load() ?? []
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
                wakeRecords: [DailyWakeRecord],
                calendar: Calendar
            ) -> Int {
                let sleepDays = records.map { calendar.startOfDay(for: $0.date) }
                let wakeDays  = wakeRecords.map { calendar.startOfDay(for: $0.day) }
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
    
    // MARK: - Data Quality

    private func makeDataQualityReport(accounting: SleepAccounting, wakeRecords: [DailyWakeRecord]) -> DataQualityReport {
        let now = accounting.now
        let calendar = accounting.calendar
        let records = accounting.records
        let lookbackDays = 14
        let today = calendar.startOfDay(for: now)
        var dailyObservationPoints: [Int] = []
        var completeDays = 0
        var trackedDays = 0
        var missedStreak = 0
        var longestRecentMissedStreak = 0
        var missingCriticalFields = Set<String>()

        for offset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayRecords = accounting.records(on: day).filter { $0.date <= now && $0.kind != .break }
            let naps = dayRecords.filter { $0.kind == .dayNap }
            let nights = dayRecords.filter { $0.kind == .nightSleep }
            let hasWake = DailyWakeRecord.uniqueObservation(in: wakeRecords, on: day, at: now, calendar: calendar) != nil
            var observationPoints = 0
            if hasWake { observationPoints += 25 } else { missingCriticalFields.insert("daily wake time") }
            if !naps.isEmpty, naps.allSatisfy({ $0.completedEnd(at: now) != nil }) {
                observationPoints += 25
            } else { missingCriticalFields.insert("day naps") }
            if !nights.isEmpty, nights.allSatisfy({ $0.completedEnd(at: now) != nil }) {
                observationPoints += 35
            } else { missingCriticalFields.insert("night sleep") }
            if !dayRecords.isEmpty { observationPoints += 15 }
            dailyObservationPoints.append(observationPoints)

            let hasWakeEntry = wakeRecords.contains {
                $0.day.timeIntervalSinceReferenceDate.isFinite && calendar.isDate($0.day, inSameDayAs: day)
            }
            if !dayRecords.isEmpty || hasWakeEntry {
                trackedDays += 1
                missedStreak = 0
            } else {
                missedStreak += 1
                longestRecentMissedStreak = max(longestRecentMissedStreak, missedStreak)
            }
            if accounting.completedSubtotal(on: day).comparableMinutes != nil { completeDays += 1 }
        }

        let observationScore = dailyObservationPoints.reduce(0, +) / max(1, dailyObservationPoints.count)
        let completeness = completeDays * 100 / lookbackDays
        let recordingFrequency = trackedDays * 100 / lookbackDays
        let rhythmStability = rhythmStabilityScore(accounting: accounting, wakeRecords: wakeRecords)
        let plausibility = plausibilityResult(accounting: accounting)
        let timeliness = timelinessResult(records: records)
        let contextRichness = contextRichnessResult(records: records, wakeRecords: wakeRecords, completeDays: completeDays)
        let score = clamp(Int(Double(observationScore) * 0.30 + Double(timeliness.score) * 0.20 +
            Double(recordingFrequency) * 0.20 + Double(plausibility.score) * 0.20 + Double(contextRichness.score) * 0.10))

        var warnings: [String] = []
        if completeDays == 0 { warnings.append("No recent Sleep Day has confirmed recording coverage.") }
        if longestRecentMissedStreak >= 2 { warnings.append("There are gaps in recent recording activity.") }
        warnings.append(contentsOf: plausibility.warnings.prefix(3))
        let conflicts = accounting.conflicts(affecting: records, completedOnly: true)
        if conflicts.classification { warnings.append("Overlapping nap and night records make sleep subtotals unreliable.") }
        if conflicts.assignment { warnings.append("Overlapping records assigned to different Sleep Days make day subtotals unreliable.") }
        if let reason = accounting.completedRolling24h.unavailableReason {
            warnings.append("Rolling 24-hour coverage is unconfirmed. \(reason.rawValue).")
        }
        if timeliness.score < 70, let averageDelay = timeliness.averageDelayMinutes {
            warnings.append("Average delay between sleep start and logging is \(averageDelay) minutes.")
        }

        return DataQualityReport(score: score, level: quality(forScore: score), completenessScore: completeness,
            consistencyScore: recordingFrequency, rhythmStabilityScore: rhythmStability,
            plausibilityScore: plausibility.score, plausibilityAnomalyCount: plausibility.anomalyCount,
            plausibilityWarnings: plausibility.warnings, timelinessScore: timeliness.score,
            contextRichnessScore: contextRichness.score, contextSignals: contextRichness.signals,
            missingContextSignals: contextRichness.missingSignals, averageLoggingDelayMinutes: timeliness.averageDelayMinutes,
            trackedDays: trackedDays, completeDays: completeDays, consecutiveMissedDays: longestRecentMissedStreak,
            missingCriticalFields: Array(missingCriticalFields).sorted(), warnings: warnings,
            confidenceNote: "Recording coverage is unconfirmed. Guidance uses recorded boundaries, saved routines, or general age ranges.")
    }

    private func plausibilityResult(accounting: SleepAccounting) -> (score: Int, anomalyCount: Int, warnings: [String]) {
        let now = accounting.now
        let records = accounting.records
        guard !records.isEmpty else { return (0, 0, []) }

        var warnings = Set<String>()
        var anomalyCount = 0
        let sleepRecords = records.filter { $0.kind != .break && $0.completedEnd(at: now) != nil }

        for record in records {
            let netMinutes = accounting.completedMinutes(sleepIDs: [record.id])
            let hasNegativeDuration = record.duration < 0
            let startsInFuture = record.date > now.addingTimeInterval(5 * 60)

            let durationIsImplausible: Bool
            switch record.kind {
            case .dayNap:
                durationIsImplausible = netMinutes.map { !(5...240).contains($0) } ?? false
            case .nightSleep:
                durationIsImplausible = netMinutes.map { !(120...780).contains($0) } ?? false
            case .break:
                durationIsImplausible = record.completedEnd(at: now).map { !(60...10800).contains($0.timeIntervalSince(record.date)) } ?? false
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
                let exceedsObservedEnd = parent.completedEnd(at: now).map { parentEnd in
                    record.completedEnd(at: now).map { $0 > parentEnd } ?? false
                } ?? false
                if record.date < parent.date || exceedsObservedEnd {
                    anomalyCount += 1
                    warnings.insert("A wake period falls outside its parent sleep interval.")
                }
            }
        }

        let sortedSleepRecords = sleepRecords.sorted { $0.date < $1.date }
        for pair in zip(sortedSleepRecords, sortedSleepRecords.dropFirst()) {
            if let firstEnd = pair.0.completedEnd(at: now), pair.1.date < firstEnd {
                anomalyCount += 1
                warnings.insert("Two sleep records overlap in time.")
            }
        }

        let days = Set(sleepRecords.map { accounting.calendar.startOfDay(for: $0.date) })
        for day in days {
            if let dayTotal = accounting.completedSubtotal(on: day).comparableMinutes, dayTotal > 20 * 60 {
                anomalyCount += 1
                warnings.insert("A day has more than 20 hours of total sleep.")
            }
        }

        let penalty = min(70, anomalyCount * 15)
        return (max(0, 100 - penalty), anomalyCount, Array(warnings).sorted())
    }

    private func timelinessResult(records: [SleepRecord]) -> (score: Int, averageDelayMinutes: Int?) {
        let delays = records.compactMap { record -> Int? in
            let minutes = record.createdAt.timeIntervalSince(record.date) / 60
            guard record.kind != .break, minutes.isFinite, minutes < Double(Int.max) else { return nil }
            return Int(max(0, minutes))
        }
        guard !delays.isEmpty else { return (0, nil) }
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

    private func rhythmStabilityScore(accounting: SleepAccounting, wakeRecords: [DailyWakeRecord]) -> Int? {
        let calendar = accounting.calendar
        let now = accounting.now
        guard let windowStart = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)) else { return nil }
        let days = Set(wakeRecords.filter { $0.day >= windowStart && $0.day <= now }.map { calendar.startOfDay(for: $0.day) })
        let wakeMinutes = days.compactMap {
            DailyWakeRecord.uniqueObservation(in: wakeRecords, on: $0, at: now, calendar: calendar)?.wakeTime
        }.map { $0.timeIntervalSince(calendar.startOfDay(for: $0)) / 60 }.map(Int.init)
        let nightStartMinutes = accounting.records.filter {
            $0.kind == .nightSleep && $0.date >= windowStart && accounting.completedMinutes(sleepIDs: [$0.id]) != nil
        }.map { $0.date.timeIntervalSince(calendar.startOfDay(for: $0.date)) / 60 }.map(Int.init)
        let components = [stabilityScore(for: wakeMinutes, excellentSpread: 30, poorSpread: 150),
                          stabilityScore(for: nightStartMinutes, excellentSpread: 45, poorSpread: 180)].compactMap { $0 }
        guard !components.isEmpty else { return nil }
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
            missingSignals.append("confirmed daily recording coverage")
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

    private func quality(forScore score: Int) -> DataQuality {
        switch score {
        case 0..<50:  return .poor
        case 50..<70: return .fair
        case 70..<90: return .good
        default:      return .excellent
        }
    }

    private func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
    // MARK: - LLM

    private func updateLLMSource(_ fingerprint: String?) {
        if currentLLMSourceFingerprint != fingerprint {
            currentLLMSourceFingerprint = fingerprint
            if activeLLMTask != nil {
                activeLLMTask?.cancel()
                activeLLMTask = nil
                llmRequestToken += 1
                isLLMLoading = false
            }
        }
        updateLLMCacheState()
    }

    private func startLLMRequest(
        snapshot: OrchestratedSnapshot,
        records: [SleepRecord],
        trigger: LLMTrigger
    ) {
        guard let sourceFingerprint = currentLLMSourceFingerprint else { return }
        activeLLMTask?.cancel()
        llmRequestToken += 1
        let requestToken = llmRequestToken
        isLLMLoading = true
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
        defer {
            isLLMLoading = false
            activeLLMTask = nil
        }
        guard sourceFingerprint == currentLLMSourceFingerprint else { return }

        if let response {
            llmResponse = response
            cacheLLMResponse(response, sourceFingerprint: sourceFingerprint)
        }

    }

    private func determineTrigger(
        records:  [SleepRecord],
        snapshot: OrchestratedSnapshot,
        previousMinutes: Int?
    ) -> LLMTrigger? {

        // Daha önce hiç LLM çağrısı yapılmadıysa
        guard let lastGenerated = loadLastLLMDate() else {
            return .newDayStarted
        }

        let cal   = snapshot.evaluationCalendar
        let now   = snapshot.generatedAt

        // Yeni gün başladıysa
        if !cal.isDate(lastGenerated, inSameDayAs: now) {
            return .newDayStarted
        }

        // Yeni nap eklendiyse — önceki snapshot'tan fazla kayıt var mı?
        if let current = snapshot.recordedDaytime.minutes,
           previousMinutes.map({ current > $0 }) ?? (current > 0) {
            // Kısa nap mı?
            let todayNaps = records
                .filter { $0.kind == .dayNap && cal.isDate($0.date, inSameDayAs: now) && $0.completedEnd(at: now) != nil }
                .sorted { $0.date > $1.date }

            if let lastNap = todayNaps.first,
               let minutes = SleepAccounting(records: records, now: now, calendar: cal).completedMinutes(sleepIDs: [lastNap.id]) {
                return minutes < 45 ? .shortNapDetected : .napLogged
            }
        }

        // Transition sinyali güçlendiyse
        if snapshot.transition.isReadyToTransit && snapshot.transition.signalStrength == .strong {
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
        if let alert = response.alert {
            UserDefaults.standard.set(alert, forKey: "llm_alert")
        } else {
            UserDefaults.standard.removeObject(forKey: "llm_alert")
        }
        updateLLMCacheState()
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
        guard let llmResponse, Date().timeIntervalSince(llmResponse.generatedAt) < 86400 else {
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
        var source = "prompt-version:4|model:gemini-2.5-flash"
        source += "|snapshot:" + canonicalSnapshot(snapshot)
        source += "|records:"
        for record in records.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            source += "\(record.id.uuidString),\(record.date.timeIntervalSince1970),\(record.duration),\(String(reflecting: record.kind)),\(record.parentNapID?.uuidString ?? "nil"),\(record.isOngoing),\(record.createdAt.timeIntervalSince1970),\(record.endDate.map { String($0.timeIntervalSince1970) } ?? "legacy");"
        }
        source += "|profile:"
        source += UserDefaults.standard.string(forKey: "babyName") ?? ""
        source += "|birthDate:\(UserDefaults.standard.object(forKey: "babyBirthDate") as? Date ?? Date.distantPast)"
        if let routine = snapshot.evaluationRoutine {
            let calendar = snapshot.evaluationCalendar
            let day = snapshot.generatedAt
            let wake = routine.wake(on: day, calendar: calendar)?.timeIntervalSince1970
            let bed = routine.bedtime(on: day, calendar: calendar)?.timeIntervalSince1970
            source += "|routineWake:\(wake.map(String.init(describing:)) ?? "none")"
            source += "|routineBedtime:\(bed.map(String.init(describing:)) ?? "none")"
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalSnapshot(_ snapshot: OrchestratedSnapshot) -> String {
        let currentState: String
        switch snapshot.sleepAssessment?.state {
        case .active(let record, let confirmation, _):
            currentState = "active:\(record.id):\(confirmation?.timeIntervalSince1970.description ?? "-")"
        case .observed(.wake(let time)):
            currentState = "wake:\(time.timeIntervalSince1970)"
        case .observed(.napEnd(let record, let end)):
            currentState = "napEnd:\(record.id):\(end.timeIntervalSince1970)"
        case .unconfirmed: currentState = "unconfirmed"
        case .conflicting: currentState = "conflicting"
        case .missing, nil: currentState = "missing"
        }
        return [
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
            "sleepDay=\(snapshot.recordedSleepDay)",
            "rolling24h=\(snapshot.recordedRolling24h)",
            "daytime=\(snapshot.recordedDaytime)",
            "timeZone=\(snapshot.evaluationCalendar.timeZone.identifier)",
            "evaluationDay=\(snapshot.evaluationCalendar.startOfDay(for: snapshot.generatedAt).timeIntervalSince1970)",
            "currentSleepState=\(currentState)",
            "wake=\(snapshot.evaluationWake?.timeIntervalSince1970.description ?? "-")",
            "sleepDayIsProvisional=\(snapshot.sleepDayIsProvisional)",
            "rolling24hIsProvisional=\(snapshot.rolling24hIsProvisional)",
            "subtotalsAreReliable=\(snapshot.subtotalsAreReliable)",
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
