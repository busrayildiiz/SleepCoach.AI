import Foundation
import XCTest
@testable import BabySleepTracker

final class CloudAITransportPrivacyTests: XCTestCase {
    func testNoConsentNeverStartsProviderRequest() async {
        let memory = CloudAIConsentTestMemory(values: ["smartSuggestions": true])
        var requestStarted = false
        let agent = DefaultSleepCoachLLMAgent(
            privacy: memory.makePrivacy(),
            developmentKey: { "test-key" },
            generateText: { _, _ in requestStarted = true; return nil }
        )

        let response = await agent.generateInsight(snapshot: snapshot(), records: [], trigger: .manualRefresh)

        XCTAssertNil(response)
        XCTAssertFalse(requestStarted)
    }

    func testMissingDevelopmentKeyNeverStartsProviderRequest() async throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        var requestStarted = false
        let agent = DefaultSleepCoachLLMAgent(
            privacy: privacy,
            developmentKey: { nil },
            generateText: { _, _ in requestStarted = true; return nil }
        )

        let response = await agent.generateInsight(snapshot: snapshot(), records: [], trigger: .manualRefresh)

        XCTAssertNil(response)
        XCTAssertFalse(requestStarted)
    }

    func testResponseIsDiscardedWhenConsentIsRevokedAndRegrantedDuringRequest() async throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        var requestStarted = false
        let agent = DefaultSleepCoachLLMAgent(
            privacy: privacy,
            developmentKey: { "test-key" },
            generateText: { _, _ in
                requestStarted = true
                try privacy.revokeConsent()
                try privacy.grantConsent()
                return "{\"coach_message\":\"Do not accept this old response.\"}"
            }
        )

        let response = await agent.generateInsight(snapshot: snapshot(), records: [], trigger: .manualRefresh)

        XCTAssertNil(response)
        #if DEBUG
        XCTAssertTrue(requestStarted)
        #else
        XCTAssertFalse(requestStarted, "Release must reject even an injected provider transport.")
        #endif
    }

    func testAllowedDevelopmentResponseStillParsesWithoutLiveNetwork() async throws {
        let memory = CloudAIConsentTestMemory()
        let privacy = memory.makePrivacy()
        try privacy.grantConsent()
        let agent = DefaultSleepCoachLLMAgent(
            privacy: privacy,
            developmentKey: { "test-key" },
            generateText: { _, _ in "{\"coach_message\":\"A test response.\"}" }
        )

        let response = await agent.generateInsight(snapshot: snapshot(), records: [], trigger: .manualRefresh)

        #if DEBUG
        XCTAssertEqual(response?.coachMessage, "A test response.")
        #else
        XCTAssertNil(response)
        #endif
    }

    func testPromptOmitsIdentifiersAndFreeTextWhileRetainingNeededSummary() {
        let agent = DefaultSleepCoachLLMAgent()
        let name = "PrivateName-DoNotTransmit"
        let privateText = "PrivateContext-DoNotTransmit"
        let value = snapshot(name: name, freeText: privateText)

        let prompt = agent.buildPrompt(snapshot: value, records: [], trigger: .manualRefresh)

        XCTAssertFalse(prompt.contains(name))
        XCTAssertFalse(prompt.contains(privateText))
        XCTAssertTrue(prompt.contains("your baby"))
        XCTAssertTrue(prompt.contains("Age: 9 months"))
        XCTAssertTrue(prompt.contains("Sleep Day completed-recorded subtotal: 1h 30m · Incomplete"))
        XCTAssertTrue(prompt.contains("Daily sleep status: Unavailable"))
        XCTAssertTrue(prompt.contains("Withhold daily deficit, surplus, bedtime compensation, personalized claims, and confidence"))
        XCTAssertTrue(prompt.contains("There is insufficient evidence to recommend a nap transition"))
        XCTAssertTrue(prompt.contains("Today: No naps logged. Nap coverage is unknown."))
        XCTAssertTrue(prompt.contains("6 day(s) ago: No naps logged. Nap coverage is unknown."))
        XCTAssertTrue(prompt.contains("Plausibility warning count: 1"))
    }

    private func snapshot(name: String = "Private Baby", freeText: String = "private context") -> OrchestratedSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return OrchestratedSnapshot(
            generatedAt: date, babyName: name, ageMonths: 9,
            phase: .baseline,
            readiness: PhaseReadinessReport(phase: .baseline, daysUntilPersonalized: 14,
                missingSignals: [], confidence: 40, progressLabel: freeText),
            pattern: nil,
            daytime: DaytimePredictionAgent(nextNapTime: date, windowStart: date, windowEnd: date,
                expectedDurationMinutes: 60, wakeWindowUsed: 180, confidence: 40,
                mode: .ageBaseline, reasoning: [freeText], usedDefaultWakeTime: true),
            night: NightPredictionAgent(optimalBedtimeStart: date, optimalBedtimeEnd: date,
                overtiredRiskTime: date, expectedNightSleepMinutes: 600, lastNapCutoffTime: date,
                daytimeSleepStatus: .onTrack, confidence: 40, reasoning: [freeText]),
            transition: NapTransitionAssessment(transitionType: .none, signalStrength: .moderate,
                signals: [], recommendation: freeText, isReadyToTransit: false),
            insights: SleepInsightBundle(headline: freeText, coachTip: name, alerts: [],
                weeklyPattern: freeText, progressMessage: name),
            dataQualityReport: DataQualityReport(score: 40, level: .fair, completenessScore: 40,
                consistencyScore: 40, rhythmStabilityScore: 40, plausibilityScore: 40,
                plausibilityAnomalyCount: 1, plausibilityWarnings: [freeText], timelinessScore: 40,
                contextRichnessScore: 40, contextSignals: [freeText], missingContextSignals: [freeText],
                averageLoggingDelayMinutes: nil, trackedDays: 1, completeDays: 1,
                consecutiveMissedDays: 0, missingCriticalFields: [freeText], warnings: [freeText],
                confidenceNote: name),
            todayTotalMinutes: 90, sleepStatus: .onTrack, nextSleepKind: .nap,
            recordedSleepDay: .incomplete(90, reason: .incomplete),
            recordedRolling24h: .incomplete(90, reason: .incomplete)
        )
    }
}
