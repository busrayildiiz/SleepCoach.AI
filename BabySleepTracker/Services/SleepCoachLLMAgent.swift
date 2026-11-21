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

    func buildPrompt(
        snapshot: OrchestratedSnapshot,
        records:  [SleepRecord],
        trigger:  LLMTrigger
    ) -> String {

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = snapshot.evaluationCalendar.timeZone
        formatter.dateFormat = "h:mm a"
        func time(_ date: Date?) -> String { date.map(formatter.string) ?? "Unavailable" }

        let last7Summary = buildLast7DaysSummary(records: records, now: snapshot.generatedAt,
                                                calendar: snapshot.evaluationCalendar)
        let nap = snapshot.daytime
        let night = snapshot.night
        let napTiming = nap.recommendation.value.map { "\(time($0)) (\(nap.source.rawValue))" }
            ?? nap.generalWakeWindow.map { "Age-based wake window \($0.lowerBound)–\($0.upperBound) min" } ?? "Unavailable"
        let bedtimeTiming = night.recommendation.value.map { "\(time($0)) (\(night.source.rawValue))" }
            ?? night.generalBedtimeHours.map { "Age-based bedtime range \($0.lowerBound):00–\($0.upperBound):00 local" } ?? "Unavailable"
        let napWindow = nap.windowStart.flatMap { start in nap.windowEnd.map { "\(time(start)) – \(time($0))" } } ?? "Unavailable"
        let bedtimeWindow = night.optimalBedtimeEnd.map { "\(bedtimeTiming) – \(time($0))" } ?? bedtimeTiming
        let triggerContext = describeTrigger(trigger)

        let activeSleep: String
        switch snapshot.currentSleepKind {
        case .nightSleep: activeSleep = "Night sleep is current. Wait for an observed end before planning another sleep."
        case .dayNap: activeSleep = "A nap is current. Any projected timing is an estimate until an end is recorded."
        case .break, nil: activeSleep = "No current sleep is confirmed."
        }

        return """
        You are an expert baby sleep coach AI. Analyze the data below and respond ONLY with a JSON object.

        BABY PROFILE:
        - Name: \(snapshot.babyName)
        - Age: \(snapshot.ageMonths) months
        - Current sleep state: \(activeSleep)

        RULE ENGINE OUTPUT:
        - Next nap guidance: \(napTiming)
        - Nap window: \(napWindow)
        - Nap planning source: \(nap.source.rawValue)
        - Nap planning limitation: \(nap.recommendation.limitation?.rawValue ?? "None reported")
        - Prediction confidence: Unavailable
        - Bedtime: \(bedtimeWindow)
        - Bedtime planning source: \(night.source.rawValue)
        - Bedtime planning limitation: \(night.recommendation.limitation?.rawValue ?? "None reported")
        - Overtired risk after: \(time(night.overtiredRiskTime))
        - Sleep Day completed-recorded subtotal: \(snapshot.recordedSleepDay.display)
        - Rolling 24h completed-recorded subtotal: \(snapshot.recordedRolling24h.display)
        - Daily sleep status: \(snapshot.recordedRolling24h.isIncomplete ? "Unavailable" : snapshot.sleepStatus?.label ?? "Unavailable")
        Use general guidance. Distinguish observations, estimates, and saved routine references. Withhold daily deficit, surplus, bedtime compensation, personalized claims, and confidence when the evidence is incomplete. While current sleep is reported, avoid wake deadlines and bedtime preparation instructions.
        - Nap transition: \(snapshot.transition.recommendation)

        DATA QUALITY REPORT:
        \(buildDataQualitySection(snapshot.dataQualityReport))

        RECORDED SAMPLES:
        \(buildPatternSection(snapshot.pattern))

        LAST 7 DAYS SUMMARY:
        \(last7Summary)

        TRIGGER: \(triggerContext)

        Respond ONLY with this JSON, no other text, no markdown:
        {
          "pattern_insight": "1-2 sentences describing reliable recorded samples or the limits of the available observations",
          "coach_message": "2-3 warm, supportive sentences for the parent with a specific actionable tip",
          "alert": null or "1 sentence if there is something urgent",
          "confidence_note": "1 sentence about the limits of the evidence and the assumptions of the guidance"
        }
        """
    }

    // MARK: - Data Quality Section

    private func buildDataQualitySection(_ report: DataQualityReport) -> String {
        var lines = [
            "- Recent days with recorded observations: \(report.trackedDays) of 14",
            "- Sleep Days with confirmed recording coverage: \(report.completeDays)",
            "- Planning context: \(report.confidenceNote)",
            "- Logging freshness: \(loggingFreshnessSummary(for: report))"
        ]
        if !report.contextSignals.isEmpty {
            lines.append("- Recorded context: \(report.contextSignals.joined(separator: ", "))")
        }
        if !report.missingCriticalFields.isEmpty {
            lines.append("- Missing or unresolved observations: \(report.missingCriticalFields.joined(separator: ", "))")
        }
        if !report.warnings.isEmpty {
            lines.append("- Warnings: \(report.warnings.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private func loggingFreshnessSummary(for report: DataQualityReport) -> String {
        guard let delay = report.averageLoggingDelayMinutes else {
            return "unknown"
        }
        switch delay {
        case 0...30:     return "events are usually logged close to real time"
        case 31...180:   return "events are logged with a modest delay"
        case 181...720:  return "events are often reconstructed later"
        default:         return "events are usually logged much later, so recall error may be higher"
        }
    }

    private func buildPatternSection(_ pattern: BabyPattern?) -> String {
        guard let pattern, pattern.sampleSize > 0 else { return "There are no reliable duration samples yet." }
        var lines = ["Reliable session measurements on \(pattern.sampleSize) recorded day(s). Coverage of those days is unconfirmed."]
        if let gap = pattern.averageWakeWindowMinutes {
            lines.append("- Median gap between applicable recorded waking and sleep boundaries: \(gap) minutes")
        }
        if let minutes = pattern.averageNapDurationMinutes {
            lines.append("- Average net sleep among measured nap sessions: \(minutes) minutes")
        }
        if let minutes = pattern.averageNightSleepMinutes {
            lines.append("- Average net sleep among measured night sessions: \(minutes) minutes")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Last 7 Days Summary

    func buildLast7DaysSummary(records: [SleepRecord], now: Date, calendar: Calendar) -> String {
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE MMM d"

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let naps = records.filter {
                $0.kind == .dayNap && $0.date <= now && calendar.isDate($0.date, inSameDayAs: day)
            }
            let label = formatter.string(from: day)
            guard !naps.isEmpty else { return "- \(label): No naps logged. Nap coverage is unknown." }
            let count = naps.filter { $0.completedEnd(at: now) != nil }.count
            let subtotal = accounting.completedSubtotal(on: day, kind: .dayNap)
            let limitation = subtotal.unavailableReason.map { ". \($0.rawValue)." } ?? "."
            return "- \(label): \(count) completed nap(s). Completed-recorded subtotal: \(subtotal.display)\(limitation)"
        }.joined(separator: "\n")
    }

    // MARK: - Response Parser

    // internal (not private) so property tests can exercise the parser
    // directly, without needing a live network call to the model.
    func parseResponse(_ text: String) -> LLMCoachResponse? {
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

}
