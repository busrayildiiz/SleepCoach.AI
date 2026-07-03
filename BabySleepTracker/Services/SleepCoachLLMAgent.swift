//
//  SleepCoachLLMAgent.swift
//  BabySleepTracker
//
//  Created by MacBook on 13.06.2026.
//

import Foundation
import GoogleGenerativeAI

// MARK: - LLM Response

struct LLMCoachResponse {
    let patternInsight:   String   // Örüntü analizi
    let coachMessage:     String   // Anneye kişisel mesaj
    let alert:            String?  // Varsa uyarı
    let confidenceNote:   String   // Tahmin hakkında not
    let generatedAt:      Date
}

// MARK: - LLM Trigger

enum LLMTrigger {
    case newDayStarted        // Her sabah bir kez
    case napLogged            // Nap kaydedilince
    case shortNapDetected     // 45 dk altı nap
    case transitionSignalHigh // Nap transition sinyali güçlü
    case weeklyReview         // 7 günde bir
    case manualRefresh        // Kullanıcı manuel yeniledi
}

// MARK: - Protocol

protocol SleepCoachLLMAgentProtocol {
    func generateInsight(
        snapshot:  OrchestratedSnapshot,
        records:   [SleepRecord],
        trigger:   LLMTrigger
    ) async -> LLMCoachResponse?
}

// MARK: - DefaultSleepCoachLLMAgent

final class DefaultSleepCoachLLMAgent: SleepCoachLLMAgentProtocol {

    private let model: GenerativeModel

    init() {
        // Ücretsiz ve hızlı olan gemini-1.5-flash modelini kullanıyoruz.
        // Key, APIConfig.swift üzerinden okunuyor.
        self.model = GenerativeModel(
            name: "gemini-2.5-flash",
            apiKey: APIConfig.geminiKey
        )
    }

    // MARK: - Generate Insight

    func generateInsight(
        snapshot: OrchestratedSnapshot,
        records:  [SleepRecord],
        trigger:  LLMTrigger
    ) async -> LLMCoachResponse? {

        // Key hâlâ placeholder ise çağrı yapmadan çık — gereksiz hata/log önler
        guard APIConfig.geminiKey != "BURAYA_KENDI_GEMINI_API_KEYINI_YAPISTIR",
              !APIConfig.geminiKey.isEmpty else {
            print("⚠️ Gemini API key tanımlı değil. APIConfig.swift dosyasını kontrol et.")
            return nil
        }

        let prompt = buildPrompt(snapshot: snapshot, records: records, trigger: trigger)

        do {
            let response = try await model.generateContent(prompt)

            guard let responseText = response.text else {
                print("LLM Error: Boş yanıt döndü.")
                return nil
            }

            return parseResponse(responseText)

        } catch {
            print("Gemini API Error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Prompt Builder

    private func buildPrompt(
        snapshot: OrchestratedSnapshot,
        records:  [SleepRecord],
        trigger:  LLMTrigger
    ) -> String {

        let formatter        = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"

        let breaks  = records.filter { $0.kind == .break }
        let dayNaps = records.filter { $0.kind == .dayNap }

        let last7Summary = buildLast7DaysSummary(
            dayNaps: dayNaps,
            breaks:  breaks
        )

        let triggerContext = describeTrigger(trigger)

        let phaseDescription: String
        switch snapshot.phase {
        case .tooYoung:           phaseDescription = "Baby is under 4 months, no pattern expected."
        case .baseline:           phaseDescription = "Day 0 — using age baseline only."
        case .learning(let day):  phaseDescription = "Learning phase, day \(day) of 14."
        case .personalized:       phaseDescription = "Personalized mode — 14+ days of data."
        }

        let transitionNote: String
        switch snapshot.transition.signalStrength {
        case .none:     transitionNote = "No transition signals."
        case .weak:     transitionNote = "Weak transition signals — monitor."
        case .moderate: transitionNote = "Moderate transition signals — \(snapshot.transition.recommendation)"
        case .strong:   transitionNote = "Strong transition signals — \(snapshot.transition.recommendation)"
        }

        return """
        You are an expert baby sleep coach AI. Analyze the data below and respond ONLY with a JSON object.

        BABY PROFILE:
        - Name: \(snapshot.babyName)
        - Age: \(snapshot.ageMonths) months
        - Phase: \(phaseDescription)
        - Tracked days: \(snapshot.readiness.daysUntilPersonalized == 0 ? "14+" : String(14 - (snapshot.readiness.daysUntilPersonalized)))

        RULE ENGINE OUTPUT:
        - Next nap prediction: \(formatter.string(from: snapshot.daytime.nextNapTime))
        - Prediction window: \(formatter.string(from: snapshot.daytime.windowStart)) – \(formatter.string(from: snapshot.daytime.windowEnd))
        - Confidence: \(snapshot.daytime.confidence)%
        - Wake window used: \(snapshot.daytime.wakeWindowUsed) minutes
        - Bedtime window: \(formatter.string(from: snapshot.night.optimalBedtimeStart)) – \(formatter.string(from: snapshot.night.optimalBedtimeEnd))
        - Overtired risk after: \(formatter.string(from: snapshot.night.overtiredRiskTime))
        - Today's total sleep: \(snapshot.todayTotalMinutes) minutes
        - Daily sleep status: \(snapshot.sleepStatus.label)
        - Nap transition: \(transitionNote)

        DATA QUALITY REPORT:
        \(buildDataQualitySection(snapshot.dataQualityReport))

        PATTERN ANALYSIS:
        \(buildPatternSection(snapshot.pattern, babyName: snapshot.babyName))

        LAST 7 DAYS SUMMARY:
        \(last7Summary)

        TRIGGER: \(triggerContext)

        Respond ONLY with this JSON, no other text, no markdown:
        {
          "pattern_insight": "1-2 sentences about the baby's sleep pattern trend",
          "coach_message": "2-3 warm, supportive sentences for the parent with a specific actionable tip",
          "alert": null or "1 sentence if there is something urgent",
          "confidence_note": "1 sentence about prediction reliability, explicitly considering the data quality report"
        }
        """
    }

    // MARK: - Data Quality Section

    private func buildDataQualitySection(_ report: DataQualityReport) -> String {
        var lines = [
            "- Overall score: \(report.score)/100 (\(describeQuality(report.level)))",
            "- Completeness: \(report.completenessScore)/100",
            "- Timeliness: \(report.timelinessScore)/100",
            "- Consistency: \(report.consistencyScore)/100",
            "- Rhythm stability: \(report.rhythmStabilityScore)/100",
            "- Plausibility: \(report.plausibilityScore)/100",
            "- Plausibility anomalies: \(report.plausibilityAnomalyCount)",
            "- Tracked days in last 14 days: \(report.trackedDays)",
            "- Complete days in last 14 days: \(report.completeDays)",
            "- Consecutive missed days: \(report.consecutiveMissedDays)",
            "- Reliability note: \(report.confidenceNote)"
        ]

        if let averageDelay = report.averageLoggingDelayMinutes {
            lines.append("- Average logging delay: \(averageDelay) minutes")
        }

        if !report.missingCriticalFields.isEmpty {
            lines.append("- Missing critical fields: \(report.missingCriticalFields.joined(separator: ", "))")
        }
        if !report.warnings.isEmpty {
            lines.append("- Warnings: \(report.warnings.joined(separator: " | "))")
        }
        if !report.plausibilityWarnings.isEmpty {
            lines.append("- Plausibility warnings: \(report.plausibilityWarnings.joined(separator: " | "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Pattern Section

    private func buildPatternSection(_ pattern: BabyPattern?, babyName: String) -> String {
        guard let pattern else {
            return "No pattern data yet — insufficient records."
        }

        var lines = [String]()

        if let ww = pattern.averageWakeWindowMinutes {
            lines.append("- Observed wake window: \(ww) min")
        }
        if let napDur = pattern.averageNapDurationMinutes {
            lines.append("- Average nap duration: \(napDur) min")
        }
        if let napCount = pattern.napCountPerDay {
            lines.append("- Average naps per day: \(String(format: "%.1f", napCount))")
        }
        if let bestHour = pattern.bestFirstNapHour {
            let suffix = bestHour >= 12 ? "PM" : "AM"
            let h      = bestHour > 12 ? bestHour - 12 : (bestHour == 0 ? 12 : bestHour)
            lines.append("- Best nap hour: \(h) \(suffix)")
        }
        if let extra = pattern.bestNapExtraMinutes, extra > 5 {
            lines.append("- Naps at best hour are ~\(extra) min longer than average")
        }
        if let night = pattern.averageNightSleepMinutes {
            lines.append("- Average night sleep: \(night) min")
        }
        if let wow = pattern.weekOverWeekNapChange {
            let direction = wow >= 0 ? "+" : ""
            lines.append("- Week-over-week nap change: \(direction)\(wow) min")
        }

        lines.append("- Wake window trend: \(describeTrend(pattern.wakingWindowTrend))")
        lines.append("- Nap duration trend: \(describeTrend(pattern.napDurationTrend))")
        lines.append("- Data quality: \(describeQuality(pattern.dataQuality)) (\(pattern.sampleSize) days)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Last 7 Days Summary

    private func buildLast7DaysSummary(
        dayNaps: [SleepRecord],
        breaks:  [SleepRecord]
    ) -> String {

        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())

        var lines = [String]()
        let formatter        = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d"

        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let naps = dayNaps
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date < $1.date }

            if naps.isEmpty {
                lines.append("- \(formatter.string(from: day)): No naps logged")
            } else {
                let total = naps.map { $0.totalMinutes(breaks: breaks) }.reduce(0, +)
                lines.append("- \(formatter.string(from: day)): \(naps.count) nap(s), \(total) min total")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parser

    private func parseResponse(_ text: String) -> LLMCoachResponse? {
        // Gemini bazen JSON'u markdown içinde (```json ... ```) döndürebilir, temizliyoruz.
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let data   = cleaned.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("Parsing Error: LLM'den gelen metin JSON'a çevrilemedi -> \(text)")
            return nil
        }

        return LLMCoachResponse(
            patternInsight:  parsed["pattern_insight"]  as? String ?? "",
            coachMessage:    parsed["coach_message"]    as? String ?? "",
            alert:           parsed["alert"]            as? String,
            confidenceNote:  parsed["confidence_note"]  as? String ?? "",
            generatedAt:     Date()
        )
    }

    // MARK: - Helpers

    private func describeTrigger(_ trigger: LLMTrigger) -> String {
        switch trigger {
        case .newDayStarted:        return "New day started — daily summary requested."
        case .napLogged:            return "New nap was just logged."
        case .shortNapDetected:     return "A short nap (under 45 min) was detected."
        case .transitionSignalHigh: return "Strong nap transition signals detected."
        case .weeklyReview:         return "Weekly review requested."
        case .manualRefresh:        return "Parent manually refreshed the coach."
        }
    }

    private func describeTrend(_ trend: Trend) -> String {
        switch trend {
        case .increasing:   return "increasing"
        case .stable:       return "stable"
        case .decreasing:   return "decreasing"
        case .insufficient: return "insufficient data"
        }
    }

    private func describeQuality(_ quality: DataQuality) -> String {
        switch quality {
        case .poor:      return "poor"
        case .fair:      return "fair"
        case .good:      return "good"
        case .excellent: return "excellent"
        }
    }
}
