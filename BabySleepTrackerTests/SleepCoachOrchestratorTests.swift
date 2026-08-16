
import XCTest
@testable import BabySleepTracker

@MainActor
final class SleepCoachOrchestratorTests: XCTestCase {

    private var phaseAgent: MockPhaseAgent!
    private var patternAgent: MockPatternAgent!
    private var daytimeAgent: MockDaytimeAgent!
    private var nightAgent: MockNightAgent!
    private var transitionAgent: MockTransitionAgent!
    private var insightAgent: MockInsightAgent!
    private var llmAgent: MockLLMAgent!
    private var profileProvider: MockSleepProfileProvider!
    private var orchestrator: SleepCoachOrchestrator!

    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 17
        components.hour = 10
        components.minute = 0
        components.second = 0

        return calendar.date(from: components)!
    }()
    
    override func setUp() {
        super.setUp()

        clearOrchestratorDefaults()

        phaseAgent = MockPhaseAgent()
        patternAgent = MockPatternAgent()
        daytimeAgent = MockDaytimeAgent()
        nightAgent = MockNightAgent()
        transitionAgent = MockTransitionAgent()
        insightAgent = MockInsightAgent()
        llmAgent = MockLLMAgent()
        profileProvider = MockSleepProfileProvider()

        orchestrator = SleepCoachOrchestrator(
            phaseAgent: phaseAgent,
            patternAgent: patternAgent,
            daytimeAgent: daytimeAgent,
            nightAgent: nightAgent,
            transitionAgent: transitionAgent,
            insightAgent: insightAgent,
            llmAgent: llmAgent,
            overtiredCalc: OvertiredCalculator(
                profileProvider: profileProvider
            ),
            profileProvider: profileProvider
        )

        UserDefaults.standard.set(
            "Test Baby",
            forKey: "babyName"
        )

        UserDefaults.standard.set(
            Calendar.current.date(
                byAdding: .month,
                value: -9,
                to: now
            )!,
            forKey: "babyBirthDate"
        )
    }

    override func tearDown() {
        clearOrchestratorDefaults()

        orchestrator = nil
        phaseAgent = nil
        patternAgent = nil
        daytimeAgent = nil
        nightAgent = nil
        transitionAgent = nil
        insightAgent = nil
        llmAgent = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - Snapshot Generation

    func testGenerateCreatesSnapshotWithExpectedCoreValues() async throws {
        orchestrator.generate(now: now)

        let snapshot = try XCTUnwrap(orchestrator.snapshot)

        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(snapshot.babyName, "Test Baby")
        XCTAssertEqual(snapshot.ageMonths, 9)
        XCTAssertEqual(snapshot.nextSleepKind, .nap)
        XCTAssertEqual(snapshot.todayTotalMinutes, 0)
        XCTAssertEqual(snapshot.phase, .baseline)

        XCTAssertFalse(orchestrator.isLoading)
    }

    func testGeneratePassesTrackedDaysToPhaseAgent() {
        let yesterday = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: now
        )!

        let sleepRecord = SleepRecord(
            date: yesterday,
            duration: 60,
            kind: .dayNap
        )

        let wakeRecord = DailyWakeRecord(
            day: now,
            wakeTime: now
        )

        saveRecords([sleepRecord])
        saveWakeRecords([wakeRecord])

        orchestrator.generate(now: now)

        XCTAssertEqual(
            phaseAgent.lastTrackedDays,
            2
        )
    }

    // MARK: - Too Young Routing

    func testTooYoungPhaseSkipsPatternAnalysis() {
        phaseAgent.phase = .tooYoung

        orchestrator.generate(now: now)

        XCTAssertEqual(
            phaseAgent.currentPhaseCallCount,
            1
        )

        XCTAssertEqual(
            patternAgent.analyzeCallCount,
            0
        )

        XCTAssertNil(orchestrator.snapshot?.pattern)
    }

    func testNonTooYoungPhaseRunsPatternAnalysis() {
        phaseAgent.phase = .learning(day: 5)

        orchestrator.generate(now: now)

        XCTAssertEqual(
            patternAgent.analyzeCallCount,
            1
        )

        XCTAssertNotNil(orchestrator.snapshot?.pattern)
    }

    // MARK: - nextSleepKind

    func testNextSleepKindIsNapWhenNapCountIsBelowExpectedMaximum() {
        let firstNap = SleepRecord(
            date: now.addingTimeInterval(-3 * 60 * 60),
            duration: 60,
            kind: .dayNap
        )

        saveRecords([firstNap])

        orchestrator.generate(now: now)

        XCTAssertEqual(
            orchestrator.snapshot?.nextSleepKind,
            .nap
        )
    }

    func testNextSleepKindIsBedtimeWhenExpectedNapCountIsReached() {
        let firstNap = SleepRecord(
            date: now.addingTimeInterval(-4 * 60 * 60),
            duration: 60,
            kind: .dayNap
        )

        let secondNap = SleepRecord(
            date: now.addingTimeInterval(-2 * 60 * 60),
            duration: 60,
            kind: .dayNap
        )

        saveRecords([firstNap, secondNap])

        orchestrator.generate(now: now)

        XCTAssertEqual(
            orchestrator.snapshot?.nextSleepKind,
            .bedtime
        )
    }

    func testNextSleepKindIsBedtimeAfterNapCutoff() {
        let calendar = Calendar.current

        let lateNow = calendar.date(
            bySettingHour: 17,
            minute: 0,
            second: 0,
            of: now
        )!

        orchestrator.generate(now: lateNow)

        XCTAssertEqual(
            orchestrator.snapshot?.nextSleepKind,
            .bedtime
        )
    }

    // MARK: - Stale Ongoing Records

    func testYesterdayOngoingNightSleepIsClosedAfterTypicalWakeTime() throws {
        let calendar = Calendar.current

        let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        )!

        let start = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: yesterday
        )!

        let record = SleepRecord(
            id: UUID(),
            date: start,
            duration: 0,
            kind: .nightSleep,
            isOngoing: true
        )

        saveRecords([record])

        UserDefaults.standard.set(
            7.0,
            forKey: "typicalWakeHour"
        )

        UserDefaults.standard.set(
            0.0,
            forKey: "typicalWakeMinute"
        )

        orchestrator.generate(now: now)

        let storedRecords = try loadStoredRecords()

        let closedRecord = try XCTUnwrap(
            storedRecords.first
        )

        XCTAssertFalse(closedRecord.isOngoing)
        XCTAssertGreaterThan(closedRecord.duration, 0)
        XCTAssertLessThanOrEqual(
            closedRecord.duration,
            12 * 60
        )
    }

    // MARK: - Data Quality

    func testGeneratedSnapshotContainsDataQualityReport() throws {
        let today = Calendar.current.startOfDay(for: now)

        let wake = DailyWakeRecord(
            day: today,
            wakeTime: today.addingTimeInterval(7 * 60 * 60)
        )

        let nap = SleepRecord(
            date: today.addingTimeInterval(9 * 60 * 60),
            duration: 60,
            kind: .dayNap
        )

        let night = SleepRecord(
            date: today.addingTimeInterval(-8 * 60 * 60),
            duration: 480,
            kind: .nightSleep
        )

        saveWakeRecords([wake])
        saveRecords([nap, night])

        orchestrator.generate(now: now)

        let report = try XCTUnwrap(
            orchestrator.snapshot?.dataQualityReport
        )

        XCTAssertGreaterThanOrEqual(report.score, 0)
        XCTAssertLessThanOrEqual(report.score, 100)

        XCTAssertEqual(
            report.trackedDays,
            2
        )

        XCTAssertTrue(
            report.contextSignals.contains("wake times")
        )

        XCTAssertTrue(
            report.contextSignals.contains("day naps")
        )

        XCTAssertTrue(
            report.contextSignals.contains("night sleep")
        )
    }

    // MARK: - LLM Trigger

    func testFirstGenerationTriggersNewDayLLMCall() async throws {
        let expectedResponse = LLMCoachResponse(
            patternInsight: "Test pattern",
            coachMessage: "Test coach message",
            alert: nil,
            confidenceNote: "Test confidence",
            generatedAt: now
        )

        llmAgent.response = expectedResponse

        orchestrator.generate(now: now)

        for _ in 0..<100 {
            if llmAgent.receivedTriggers.count == 1 {
                break
            }

            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }

        XCTAssertEqual(
            llmAgent.receivedTriggers.count,
            1
        )

        XCTAssertEqual(
            triggerName(llmAgent.receivedTriggers.first),
            "newDayStarted"
        )

        for _ in 0..<100 {
            if orchestrator.llmResponse != nil {
                break
            }

            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }

        XCTAssertEqual(
            orchestrator.llmResponse?.coachMessage,
            "Test coach message"
        )

        XCTAssertFalse(orchestrator.isLLMLoading)
    }

    // MARK: - Helpers

    private func saveRecords(
        _ records: [SleepRecord]
    ) {
        let data = try! JSONEncoder().encode(records)

        UserDefaults.standard.set(
            data,
            forKey: "sleepRecords"
        )
    }

    private func saveWakeRecords(
        _ records: [DailyWakeRecord]
    ) {
        let data = try! JSONEncoder().encode(records)

        UserDefaults.standard.set(
            data,
            forKey: "dailyWakeRecords_v1"
        )
    }

    private func loadStoredRecords() throws -> [SleepRecord] {
        guard let data = UserDefaults.standard.data(
            forKey: "sleepRecords"
        ) else {
            return []
        }

        return try JSONDecoder().decode(
            [SleepRecord].self,
            from: data
        )
    }

    private func clearOrchestratorDefaults() {
        let keys = [
            "sleepRecords",
            "dailyWakeRecords_v1",
            "babyName",
            "babyBirthDate",
            "typicalWakeHour",
            "typicalWakeMinute",
            "llm_lastGenerated",
            "llm_coachMessage",
            "llm_patternInsight",
            "llm_confidenceNote",
            "llm_alert"
        ]

        keys.forEach {
            UserDefaults.standard.removeObject(
                forKey: $0
            )
        }
    }

    private func triggerName(
        _ trigger: LLMTrigger?
    ) -> String {
        switch trigger {
        case .newDayStarted:
            return "newDayStarted"
        case .napLogged:
            return "napLogged"
        case .shortNapDetected:
            return "shortNapDetected"
        case .transitionSignalHigh:
            return "transitionSignalHigh"
        case .weeklyReview:
            return "weeklyReview"
        case .manualRefresh:
            return "manualRefresh"
        case nil:
            return "nil"
        }
    }
}

// MARK: - Mock Agents

private final class MockPhaseAgent: PhaseAgentProtocol {

    var phase: CoachPhase = .baseline

    private(set) var currentPhaseCallCount = 0
    private(set) var lastTrackedDays = -1

    func currentPhase(
        ageMonths: Int,
        trackedDays: Int
    ) -> CoachPhase {
        currentPhaseCallCount += 1
        lastTrackedDays = trackedDays
        return phase
    }

    func readinessReport(
        ageMonths: Int,
        trackedDays: Int,
        hasTodayWakeTime: Bool,
        hasYesterdayNightSleep: Bool
    ) -> PhaseReadinessReport {
        PhaseReadinessReport(
            phase: phase,
            daysUntilPersonalized: phase == .personalized ? 0 : 14,
            missingSignals: [],
            confidence: 80,
            progressLabel: "Test"
        )
    }
}

private final class MockPatternAgent: PatternAgentProtocol {

    private(set) var analyzeCallCount = 0

    func analyze(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths: Int,
        now: Date
    ) -> BabyPattern {

        analyzeCallCount += 1

        return BabyPattern(
            averageWakeWindowMinutes: 180,
            bestFirstNapHour: 10,
            bestNapExtraMinutes: 10,
            averageNapDurationMinutes: 60,
            napCountPerDay: 2,
            averageNightSleepMinutes: 600,
            estimatedBedtimeShiftMinutes: 0,
            wakingWindowTrend: .stable,
            napDurationTrend: .stable,
            sampleSize: 7,
            dataQuality: .good,
            weekOverWeekNapChange: 0
        )
    }
}

private struct MockDaytimeAgent: DaytimePredictionAgentProtocol {

    func predictNextNap(
        pattern: BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths: Int,
        trackedDays: Int,
        now: Date
    ) -> DaytimePredictionAgent {

        DaytimePredictionAgent(
            nextNapTime: now.addingTimeInterval(2 * 60 * 60),
            windowStart: now.addingTimeInterval(2 * 60 * 60),
            windowEnd: now.addingTimeInterval(3 * 60 * 60),
            expectedDurationMinutes: 90,
            wakeWindowUsed: 180,
            confidence: 80,
            mode: .ageBaseline,
            reasoning: ["Test daytime prediction"],
            usedDefaultWakeTime: true
        )
    }
}

private struct MockNightAgent: NightPredictionAgentProtocol {

    func predictBedtime(
        pattern: BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths: Int,
        trackedDays: Int,
        now: Date
    ) -> NightPredictionAgent {

        NightPredictionAgent(
            optimalBedtimeStart: now.addingTimeInterval(8 * 60 * 60),
            optimalBedtimeEnd: now.addingTimeInterval(9 * 60 * 60),
            overtiredRiskTime: now.addingTimeInterval(10 * 60 * 60),
            expectedNightSleepMinutes: 660,
            lastNapCutoffTime: now.addingTimeInterval(4 * 60 * 60),
            daytimeSleepStatus: .onTrack,
            confidence: 80,
            reasoning: ["Test night prediction"]
        )
    }
}

private struct MockTransitionAgent: NapTransitionAgentProtocol {

    func assess(
        records: [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths: Int,
        now: Date
    ) -> NapTransitionAssessment {

        NapTransitionAssessment(
            transitionType: .none,
            signalStrength: .none,
            signals: [],
            recommendation: "No transition",
            isReadyToTransit: false
        )
    }
}

private struct MockInsightAgent: InsightAgentProtocol {

    func buildInsights(
        phase: CoachPhase,
        pattern: BabyPattern?,
        trackedDays: Int,
        babyName: String
    ) -> SleepInsightBundle {

        SleepInsightBundle(
            headline: "Test headline",
            coachTip: "Test tip",
            alerts: [],
            weeklyPattern: nil,
            progressMessage: "Test progress"
        )
    }
}

private final class MockLLMAgent: SleepCoachLLMAgentProtocol {

    var response: LLMCoachResponse?

    private(set) var receivedTriggers: [LLMTrigger] = []

    func generateInsight(
        snapshot: OrchestratedSnapshot,
        records: [SleepRecord],
        trigger: LLMTrigger
    ) async -> LLMCoachResponse? {

        receivedTriggers.append(trigger)
        return response
    }
}

private final class MockSleepProfileProvider: AgeBasedSleepProfileProviding {

    private let profile = AgeBasedSleepProfile(
        ageRange: 9...11,
        totalSleep24hRange: 660...840,
        wakeWindowRange: 180...240,
        morningWakeWindow: 180...210,
        eveningWakeWindow: 210...240,
        expectedNapCount: 2...2,
        maxSingleNapMinutes: 120,
        daytimeSleepRange: 120...180,
        nightSleepRange: 600...720,
        bedtimeHourRange: 18...20,
        lastNapCutoffHour: 16
    )

    func profile(
        forAgeMonths age: Int
    ) -> AgeBasedSleepProfile {
        profile
    }

    func wakeWindowCenter(
        forAgeMonths age: Int
    ) -> Int {
        210
    }

    func eveningWakeWindowCenter(
        forAgeMonths age: Int
    ) -> Int {
        225
    }
}
