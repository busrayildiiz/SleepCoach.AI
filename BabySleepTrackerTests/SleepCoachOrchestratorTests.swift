
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

    func testIncreasedTodaySleepTriggersShortNapLLMCall() async {
        let currentDay = Date()
        let triggerReceived = expectation(description: "Short nap trigger received")
        llmAgent.onTrigger = { trigger in
            if case .shortNapDetected = trigger {
                triggerReceived.fulfill()
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "llm_lastGenerated")

        orchestrator.generate(now: currentDay)
        saveRecords([
            SleepRecord(date: currentDay, duration: 30, kind: .dayNap)
        ])
        orchestrator.generate(now: currentDay)
        await fulfillment(of: [triggerReceived], timeout: 1)

        XCTAssertEqual(llmAgent.receivedTriggers.count, 1)
        XCTAssertEqual(triggerName(llmAgent.receivedTriggers.first), "shortNapDetected")
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
    var onTrigger: ((LLMTrigger) -> Void)?

    private(set) var receivedTriggers: [LLMTrigger] = []

    func generateInsight(
        snapshot: OrchestratedSnapshot,
        records: [SleepRecord],
        trigger: LLMTrigger
    ) async -> LLMCoachResponse? {

        receivedTriggers.append(trigger)
        onTrigger?(trigger)
        return response
    }
}

@MainActor
final class SleepCoachOrchestratorLLMLifecycleTests: XCTestCase {
    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 10))!
    }()

    private var llmAgent: ControlledLLMAgent!
    private var orchestrator: SleepCoachOrchestrator!

    override func setUp() {
        super.setUp()
        clearDefaults()
        llmAgent = ControlledLLMAgent()
        orchestrator = SleepCoachOrchestrator(
            phaseAgent: MockPhaseAgent(),
            patternAgent: MockPatternAgent(),
            daytimeAgent: MockDaytimeAgent(),
            nightAgent: MockNightAgent(),
            transitionAgent: MockTransitionAgent(),
            insightAgent: MockInsightAgent(),
            llmAgent: llmAgent,
            overtiredCalc: OvertiredCalculator(profileProvider: MockSleepProfileProvider()),
            profileProvider: MockSleepProfileProvider()
        )
        UserDefaults.standard.set("Test Baby", forKey: "babyName")
        UserDefaults.standard.set(Calendar.current.date(byAdding: .month, value: -9, to: now)!, forKey: "babyBirthDate")
    }

    override func tearDown() {
        clearDefaults()
        orchestrator = nil
        llmAgent = nil
        super.tearDown()
    }

    func testNormalResponseUpdatesStateAndCache() async throws {
        let response = response("normal")
        let requestStarted = expectation(description: "LLM request started")
        let requestCompleted = expectation(description: "LLM request completed")
        llmAgent.onRequest = { _ in requestStarted.fulfill() }
        llmAgent.onCompletion = { _ in requestCompleted.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [requestStarted], timeout: 1)
        llmAgent.release(0, with: response)
        await fulfillment(of: [requestCompleted], timeout: 1)

        XCTAssertEqual(orchestrator.llmResponse?.coachMessage, "normal")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "llm_coachMessage"), "normal")
        XCTAssertFalse(orchestrator.isLLMLoading)
    }

    func testStaleResponseCannotOverwriteStateOrCache() async throws {
        let older = response("older")
        let newer = response("newer")
        let firstRequestStarted = expectation(description: "First LLM request started")
        let secondRequestStarted = expectation(description: "Second LLM request started")
        let newerCompleted = expectation(description: "Newer LLM request completed")
        let olderCompleted = expectation(description: "Older LLM request completed")
        llmAgent.onRequest = { index in
            if index == 0 { firstRequestStarted.fulfill() }
            if index == 1 { secondRequestStarted.fulfill() }
        }
        llmAgent.onCompletion = { index in
            if index == 1 { newerCompleted.fulfill() }
            if index == 0 { olderCompleted.fulfill() }
        }
        orchestrator.generate(now: now)
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        orchestrator.refreshLLM()
        await fulfillment(of: [secondRequestStarted], timeout: 1)

        llmAgent.release(1, with: newer)
        await fulfillment(of: [newerCompleted], timeout: 1)
        llmAgent.release(0, with: older)
        await fulfillment(of: [olderCompleted], timeout: 1)

        XCTAssertEqual(orchestrator.llmResponse?.coachMessage, "newer")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "llm_coachMessage"), "newer")
    }

    func testStaleCompletionDoesNotClearLoadingForNewerRequest() async throws {
        let firstRequestStarted = expectation(description: "First LLM request started")
        let secondRequestStarted = expectation(description: "Second LLM request started")
        let olderCompleted = expectation(description: "Older LLM request completed")
        let newerCompleted = expectation(description: "Newer LLM request completed")
        llmAgent.onRequest = { index in
            if index == 0 { firstRequestStarted.fulfill() }
            if index == 1 { secondRequestStarted.fulfill() }
        }
        llmAgent.onCompletion = { index in
            if index == 0 { olderCompleted.fulfill() }
            if index == 1 { newerCompleted.fulfill() }
        }
        orchestrator.generate(now: now)
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        orchestrator.refreshLLM()
        await fulfillment(of: [secondRequestStarted], timeout: 1)

        llmAgent.release(0, with: response("older"))
        await fulfillment(of: [olderCompleted], timeout: 1)
        XCTAssertTrue(orchestrator.isLLMLoading)

        llmAgent.release(1, with: response("newer"))
        await fulfillment(of: [newerCompleted], timeout: 1)
        XCTAssertFalse(orchestrator.isLLMLoading)
    }

    func testRefreshUsesSameStaleResultProtectionWhenCancellationIsIgnored() async throws {
        let firstRequestStarted = expectation(description: "First LLM request started")
        let secondRequestStarted = expectation(description: "Second LLM request started")
        let refreshCompleted = expectation(description: "Refresh request completed")
        let automaticCompleted = expectation(description: "Cancelled automatic request completed")
        llmAgent.onRequest = { index in
            if index == 0 { firstRequestStarted.fulfill() }
            if index == 1 { secondRequestStarted.fulfill() }
        }
        llmAgent.onCompletion = { index in
            if index == 0 { automaticCompleted.fulfill() }
            if index == 1 { refreshCompleted.fulfill() }
        }
        orchestrator.generate(now: now)
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        orchestrator.refreshLLM()
        await fulfillment(of: [secondRequestStarted], timeout: 1)

        llmAgent.release(1, with: response("refresh"))
        await fulfillment(of: [refreshCompleted], timeout: 1)
        llmAgent.release(0, with: response("cancelled automatic"))
        await fulfillment(of: [automaticCompleted], timeout: 1)

        XCTAssertEqual(orchestrator.llmResponse?.coachMessage, "refresh")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "llm_coachMessage"), "refresh")
    }

    private func response(_ message: String) -> LLMCoachResponse {
        LLMCoachResponse(patternInsight: "pattern", coachMessage: message, alert: nil, confidenceNote: "confidence", generatedAt: now)
    }

    private func clearDefaults() {
        ["sleepRecords", "dailyWakeRecords_v1", "babyName", "babyBirthDate", "typicalWakeHour", "typicalWakeMinute", "llm_lastGenerated", "llm_coachMessage", "llm_patternInsight", "llm_confidenceNote", "llm_alert"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }
}

@MainActor
private final class ControlledLLMAgent: SleepCoachLLMAgentProtocol {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<LLMCoachResponse?, Never>] = [:]
    private var pendingResponses: [Int: LLMCoachResponse?] = [:]
    var onRequest: ((Int) -> Void)?
    var onCompletion: ((Int) -> Void)?

    func generateInsight(snapshot: OrchestratedSnapshot, records: [SleepRecord], trigger: LLMTrigger) async -> LLMCoachResponse? {
        let index = nextRequestID
        nextRequestID += 1
        let response = await withCheckedContinuation { continuation in
            if let pendingResponse = pendingResponses.removeValue(forKey: index) {
                continuation.resume(returning: pendingResponse)
            } else {
                continuations[index] = continuation
                onRequest?(index)
            }
        }
        onCompletion?(index)
        return response
    }

    func release(_ index: Int, with response: LLMCoachResponse?) {
        if let continuation = continuations.removeValue(forKey: index) {
            continuation.resume(returning: response)
        } else {
            pendingResponses[index] = response
        }
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
