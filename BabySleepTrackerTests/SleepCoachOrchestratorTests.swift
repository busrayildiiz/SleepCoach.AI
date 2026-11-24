
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
    private var defaults: TestPrivateDataStore!

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
        defaults = TestPrivateDataStore()
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
            profileProvider: profileProvider,
            defaults: defaults
        )

        defaults.set(
            "Test Baby",
            forKey: "babyName"
        )

        defaults.set(
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
        XCTAssertNil(snapshot.todayTotalMinutes)
        XCTAssertEqual(snapshot.recordedSleepDay, .incomplete(nil, reason: .missing))
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

    func testHistoricalSnapshotSeparatesSleepDayAndRolling24hWithoutMutatingRecords() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let night = SleepRecord(date: today.addingTimeInterval(-4 * 3600), duration: 660, kind: .nightSleep)
        let nap = SleepRecord(date: today.addingTimeInterval(8 * 3600), duration: 60)
        saveRecords([night, nap])
        let before = defaults.data(forKey: "sleepRecords")
        orchestrator.generate(now: now)
        let result = try XCTUnwrap(orchestrator.snapshot)
        XCTAssertEqual(result.todayTotalMinutes, 60)
        XCTAssertEqual(result.rolling24hMinutes, 720)
        XCTAssertEqual(result.daytimeMinutes, 60)
        XCTAssertTrue(result.sleepDayIsProvisional)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before)
    }

    func testConflictingClassificationsProduceQualityWarning() throws {
        let nap = SleepRecord(date: now.addingTimeInterval(-120 * 60), duration: 90)
        let night = SleepRecord(date: now.addingTimeInterval(-90 * 60), duration: 90, kind: .nightSleep)
        saveRecords([nap, night])
        orchestrator.generate(now: now)
        let result = try XCTUnwrap(orchestrator.snapshot)
        XCTAssertFalse(result.subtotalsAreReliable)
        XCTAssertEqual(result.todayTotalMinutes, 120)
        XCTAssertTrue(result.dataQualityReport.warnings.contains { $0.contains("Overlapping nap and night") })
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

    func testGeneratingWithStaleOngoingRecordDoesNotRewriteOrNotify() throws {
        let staleRecord = SleepRecord(
            date: now.addingTimeInterval(-2 * 24 * 60 * 60),
            duration: 0,
            kind: .nightSleep,
            isOngoing: true
        )
        saveRecords([staleRecord])

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .sleepRecordsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        orchestrator.generate(now: now)

        XCTAssertEqual(notificationCount, 0)
        let storedRecords = try loadStoredRecords()
        let storedRecord = try XCTUnwrap(storedRecords.first)
        XCTAssertEqual(storedRecord.id, staleRecord.id)
        XCTAssertTrue(storedRecord.isOngoing)
        XCTAssertEqual(storedRecord.duration, 0)
        XCTAssertNil(storedRecord.observedEnd)
        XCTAssertEqual(storedRecord.date, staleRecord.date)
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

    func testTwoRecordedNapsAtNineMonthsSelectBedtimeWithIncompleteCoverage() throws {
        let naps = [SleepRecord(date: planningTime(9), duration: 60), SleepRecord(date: planningTime(13), duration: 60)]
        let snapshot = try planningSnapshot(records: naps, at: planningTime(14, 15))

        XCTAssertEqual(snapshot.ageMonths, 9)
        XCTAssertEqual(snapshot.night.lastNapCutoffTime, planningTime(16))
        XCTAssertEqual(snapshot.daytime.recommendation.value, planningTime(17, 30))
        XCTAssertEqual(snapshot.nextSleepKind, .bedtime)
        XCTAssertEqual(snapshot.sleepAssessment?.anchor?.date, planningTime(14))
        XCTAssertEqual(snapshot.night.recommendation.value, planningTime(17, 30))
        XCTAssertEqual(snapshot.night.optimalBedtimeEnd, planningTime(18))
        XCTAssertEqual(snapshot.night.source, .recordedEstimate)
        XCTAssertEqual(snapshot.recordedDaytime, .incomplete(120, reason: .incomplete))
        XCTAssertEqual(snapshot.recordedSleepDay, .incomplete(120, reason: .incomplete))
        XCTAssertEqual(snapshot.recordedRolling24h, .incomplete(120, reason: .incomplete))
        XCTAssertEqual(snapshot.dataQualityReport.completeDays, 0)
        XCTAssertNil(snapshot.sleepStatus)
        XCTAssertNil(snapshot.night.daytimeSleepStatus)
        XCTAssertNil(snapshot.night.overtiredRiskTime)
        XCTAssertNil(snapshot.night.confidence)
        XCTAssertNil(snapshot.daytime.confidence)
        XCTAssertNil(SleepOverviewCalculator(records: naps, now: snapshot.generatedAt,
                                             calendar: planningCalendar, totalSleepReference: 660...840)
            .calculate().recordedGoalProgress)

        let prompt = DefaultSleepCoachLLMAgent().buildPrompt(snapshot: snapshot, records: naps, trigger: .manualRefresh)
        XCTAssertTrue(prompt.contains("Next planned sleep: Bedtime"))
        XCTAssertTrue(prompt.contains("Next nap guidance: Unavailable"))
        XCTAssertTrue(prompt.contains("Nap window: Unavailable"))
    }

    func testDistinctCompletedBoundariesCanSelectBedtimeBeforeCutoffWithoutExactNetSleep() throws {
        let first = SleepRecord(date: planningTime(9), duration: 60)
        let second = SleepRecord(date: planningTime(11), duration: 60)
        let unknownBreak = SleepRecord(date: planningTime(9, 15), duration: 0, kind: .break,
                                       parentNapID: first.id, isOngoing: true)
        let snapshot = try planningSnapshot(records: [first, second, unknownBreak], at: planningTime(12, 15))

        XCTAssertEqual(snapshot.daytime.recommendation.value, planningTime(15, 30))
        XCTAssertEqual(snapshot.nextSleepKind, .bedtime)
        XCTAssertEqual(snapshot.recordedDaytime, .incomplete(60, reason: .unresolvedBreak))
        XCTAssertEqual(snapshot.sleepAssessment?.anchor?.date, planningTime(12))
        XCTAssertNil(snapshot.night.daytimeSleepStatus)
    }

    func testOverlappingOrConflictingRecordsDoNotCountAsTwoNaps() throws {
        let first = SleepRecord(date: planningTime(9), duration: 60)
        let second = SleepRecord(date: planningTime(11), duration: 60)
        let cases: [(String, [SleepRecord], [DailyWakeRecord])] = [
            ("overlapping naps", [SleepRecord(date: planningTime(10, 30), duration: 60), second], []),
            ("overlapping night", [first, second, SleepRecord(date: planningTime(8, 30), duration: 90, kind: .nightSleep)], []),
            ("duplicated identity", [first, SleepRecord(id: first.id, date: second.date, duration: 60)], []),
            ("unresolved onset inside a nap", [first, second, SleepRecord(date: planningTime(9, 30), duration: 0)], []),
            ("wake inside a nap", [first, second], [DailyWakeRecord(day: planningTime(0), wakeTime: planningTime(9, 30))])
        ]
        for (description, records, wakes) in cases {
            let snapshot = try planningSnapshot(records: records, wakes: wakes, at: planningTime(12, 15))
            XCTAssertEqual(snapshot.daytime.recommendation.value, planningTime(15, 30), description)
            XCTAssertEqual(snapshot.nextSleepKind, .nap, description)
            XCTAssertTrue(snapshot.recordedDaytime.isIncomplete, description)
        }
    }

    func testProposedNapAtOrAfterCutoffSelectsBedtimeWithOnlyOneRecordedNap() throws {
        for (elapsed, expected) in [(29, NextSleepKind.nap), (30, .bedtime), (45, .bedtime)] {
            let nap = SleepRecord(date: planningTime(12), duration: elapsed)
            let snapshot = try planningSnapshot(records: [nap], at: planningTime(13))
            XCTAssertEqual(snapshot.daytime.recommendation.value, planningTime(15, 30).addingTimeInterval(Double(elapsed) * 60))
            XCTAssertEqual(snapshot.nextSleepKind, expected)
            XCTAssertEqual(snapshot.recordedDaytime, .incomplete(elapsed, reason: .incomplete))
        }
    }

    func testActiveNapTakesPrecedenceOverTheCountAndCutoff() throws {
        let naps = [SleepRecord(date: planningTime(9), duration: 60), SleepRecord(date: planningTime(13), duration: 60),
                    SleepRecord(date: planningTime(16), duration: 0, isOngoing: true)]
        let snapshot = try planningSnapshot(records: naps, at: planningTime(16, 15))

        XCTAssertEqual(snapshot.currentSleepKind, .dayNap)
        XCTAssertEqual(snapshot.nextSleepKind, .nap)
        XCTAssertNil(snapshot.night.recommendation.value)
        XCTAssertTrue(snapshot.recordedDaytime.isIncomplete)
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

    func testYesterdayNightRemainsOngoingAfterTypicalWakeTime() throws {
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

        defaults.set(
            7.0,
            forKey: "typicalWakeHour"
        )

        defaults.set(
            0.0,
            forKey: "typicalWakeMinute"
        )

        orchestrator.generate(now: now)

        let storedRecords = try loadStoredRecords()

        let closedRecord = try XCTUnwrap(
            storedRecords.first
        )

        XCTAssertTrue(closedRecord.isOngoing)
        XCTAssertEqual(closedRecord.duration, 0)
        XCTAssertNil(closedRecord.observedEnd)
        XCTAssertEqual(closedRecord.date, start)
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

    func testRecordedNightsAndWakesDoNotConfirmCoverageOrPersonalizedCoaching() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19)))
        let evaluation = day.addingTimeInterval(14 * 3600)
        let pairs = (0..<14).map { offset -> (SleepRecord, DailyWakeRecord) in
            let start = day.addingTimeInterval(Double(-offset) * 86400)
            let wake = start.addingTimeInterval(7 * 3600)
            return (SleepRecord(date: start, duration: 420, kind: .nightSleep, createdAt: start, endDate: wake),
                    DailyWakeRecord(day: start, wakeTime: wake))
        }
        let unresolved = SleepRecord(date: day.addingTimeInterval(8 * 3600), duration: 0, createdAt: day)
        let nap = SleepRecord(date: day.addingTimeInterval(12 * 3600), duration: 60, createdAt: day)
        let raw = pairs.map { $0.0 } + [unresolved, nap]
        saveRecords(raw)
        saveWakeRecords(pairs.map { $0.1 })
        defaults.set(day.addingTimeInterval(-270 * 86400), forKey: "babyBirthDate")
        let before = defaults.data(forKey: "sleepRecords")
        let beforeWake = defaults.data(forKey: "dailyWakeRecords_v1")
        let real = SleepCoachOrchestrator(llmAgent: llmAgent, calendar: calendar, defaults: defaults)
        real.generate(now: evaluation, requestCoaching: false)

        let snapshot = try XCTUnwrap(real.snapshot)
        XCTAssertEqual(snapshot.dataQualityReport.trackedDays, 14)
        XCTAssertEqual(snapshot.dataQualityReport.completeDays, 0)
        XCTAssertEqual(snapshot.dataQualityReport.completenessScore, 0)
        XCTAssertFalse(snapshot.dataQualityReport.contextSignals.contains("multi-day coverage"))
        XCTAssertEqual(snapshot.recordedDaytime, .incomplete(60, reason: .unresolved))
        XCTAssertEqual(snapshot.recordedSleepDay, .incomplete(480, reason: .unresolved))
        XCTAssertNil(snapshot.sleepStatus)
        XCTAssertNil(snapshot.daytime.confidence)
        XCTAssertNil(snapshot.night.confidence)
        XCTAssertNil(snapshot.night.overtiredRiskTime)
        XCTAssertNil(snapshot.night.daytimeSleepStatus)
        XCTAssertEqual(snapshot.night.source, .recordedEstimate)
        XCTAssertEqual(snapshot.night.recommendation.limitation, .unresolved)
        XCTAssertEqual(snapshot.sleepAssessment?.anchor?.date, nap.observedEnd)
        XCTAssertNil(snapshot.pattern?.averageWakeWindowMinutes)
        XCTAssertTrue(llmAgent.receivedTriggers.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), before)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), beforeWake)

        let builder = DefaultSleepCoachLLMAgent()
        let prompt = builder.buildPrompt(snapshot: snapshot, records: raw, trigger: .manualRefresh)
        let week = builder.buildLast7DaysSummary(records: raw, now: evaluation, calendar: calendar)
        XCTAssertTrue(prompt.contains("Sleep Days with confirmed recording coverage: 0"))
        XCTAssertTrue(prompt.contains("Prediction confidence: Unavailable"))
        XCTAssertTrue(prompt.contains("Daily sleep status: Unavailable"))
        XCTAssertTrue(prompt.contains("Overtired risk after: Unavailable"))
        XCTAssertTrue(prompt.contains("Bedtime planning source: Estimate from recorded sleep"))
        XCTAssertTrue(prompt.contains("Bedtime planning limitation: Sleep end unconfirmed"))
        XCTAssertTrue(prompt.contains("Withhold daily deficit, surplus, bedtime compensation, personalized claims, and confidence"))
        XCTAssertTrue(prompt.contains("Coverage of those days is unconfirmed"))
        XCTAssertTrue(prompt.contains(week), "The real primary prompt includes the separate production summary.")
        XCTAssertTrue(week.contains("1 completed nap(s). Completed-recorded subtotal: 1h · Incomplete. Sleep end unconfirmed."))
        XCTAssertEqual(week.components(separatedBy: "No naps logged. Nap coverage is unknown.").count - 1, 6)
        XCTAssertFalse(week.contains("0m"))
    }

    func testPromptLeavesClockTimesUnavailableWithoutAnAnchorAndLabelsSavedRoutine() throws {
        let calendar = Calendar.current
        let local = SleepCoachOrchestrator(llmAgent: llmAgent, calendar: calendar, defaults: defaults)
        let builder = DefaultSleepCoachLLMAgent()
        local.generate(now: now, requestCoaching: false)
        let missing = try XCTUnwrap(local.snapshot)
        let agePrompt = builder.buildPrompt(snapshot: missing, records: [], trigger: .manualRefresh)
        XCTAssertNil(missing.daytime.recommendation.value)
        XCTAssertNil(missing.night.recommendation.value)
        XCTAssertTrue(agePrompt.contains("Nap planning source: Age-based guidance"))
        XCTAssertTrue(agePrompt.contains("Bedtime planning source: Age-based guidance"))
        XCTAssertTrue(agePrompt.contains("Nap window: Unavailable"))
        XCTAssertTrue(agePrompt.contains("Rolling 24h completed-recorded subtotal: Unknown"))
        XCTAssertTrue(agePrompt.contains("Prediction confidence: Unavailable"))

        defaults.set(7.0, forKey: "typicalWakeHour")
        defaults.set(19.0, forKey: "typicalBedHour")
        defer { defaults.removeObject(forKey: "typicalBedHour") }
        local.generate(now: now, requestCoaching: false)
        let routine = try XCTUnwrap(local.snapshot)
        let routinePrompt = builder.buildPrompt(snapshot: routine, records: [], trigger: .manualRefresh)
        XCTAssertTrue(routinePrompt.contains("Nap planning source: Routine-based guidance"))
        XCTAssertTrue(routinePrompt.contains("Bedtime planning source: Routine-based guidance"))
        XCTAssertTrue(routinePrompt.contains("Bedtime planning limitation: Missing observations"))
        XCTAssertNil(routine.evaluationWake)
        XCTAssertNil(defaults.data(forKey: "dailyWakeRecords_v1"))
        XCTAssertTrue(llmAgent.receivedTriggers.isEmpty)
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
        let currentDay = now
        let triggerReceived = expectation(description: "Short nap trigger received")
        llmAgent.onTrigger = { trigger in
            if case .shortNapDetected = trigger {
                triggerReceived.fulfill()
            }
        }
        defaults.set(currentDay.timeIntervalSince1970, forKey: "llm_lastGenerated")

        orchestrator.generate(now: currentDay)
        XCTAssertNil(orchestrator.snapshot?.todayTotalMinutes)
        saveRecords([
            // A completed nap must end by the injected reference, not start at it.
            SleepRecord(date: currentDay.addingTimeInterval(-30 * 60), duration: 30,
                        kind: .dayNap, createdAt: currentDay)
        ])
        orchestrator.generate(now: currentDay)
        XCTAssertEqual(orchestrator.snapshot?.todayTotalMinutes, 30)
        await fulfillment(of: [triggerReceived], timeout: 1)

        XCTAssertEqual(llmAgent.receivedTriggers.count, 1)
        XCTAssertEqual(triggerName(llmAgent.receivedTriggers.first), "shortNapDetected")
    }

    func testElapsedUnconfirmedSleepDoesNotTriggerCoaching() async {
        let currentDay = now
        defaults.set(currentDay.timeIntervalSince1970, forKey: "llm_lastGenerated")
        orchestrator.generate(now: currentDay)
        saveRecords([
            SleepRecord(date: currentDay.addingTimeInterval(-2 * 3600), duration: 0,
                        kind: .nightSleep, isOngoing: true, createdAt: currentDay)
        ])

        orchestrator.generate(now: currentDay)
        XCTAssertEqual(orchestrator.snapshot?.recordedSleepDay, .incomplete(nil, reason: .unresolved))
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertTrue(llmAgent.receivedTriggers.isEmpty)
    }

    // MARK: - Helpers

    private var planningCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func planningTime(_ hour: Int, _ minute: Int = 0) -> Date {
        planningCalendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour, minute: minute))!
    }

    private func planningSnapshot(records: [SleepRecord], wakes: [DailyWakeRecord] = [], at time: Date) throws -> OrchestratedSnapshot {
        saveRecords(records)
        saveWakeRecords(wakes)
        let birth = planningCalendar.date(byAdding: .month, value: -9, to: planningTime(0))!
        defaults.set(birth, forKey: "babyBirthDate")
        let real = SleepCoachOrchestrator(llmAgent: llmAgent, calendar: planningCalendar, defaults: defaults)
        real.generate(now: time, requestCoaching: false)
        return try XCTUnwrap(real.snapshot)
    }

    private func saveRecords(
        _ records: [SleepRecord]
    ) {
        let data = try! JSONEncoder().encode(records)

        defaults.set(
            data,
            forKey: "sleepRecords"
        )
    }

    private func saveWakeRecords(
        _ records: [DailyWakeRecord]
    ) {
        let data = try! JSONEncoder().encode(records)

        defaults.set(
            data,
            forKey: "dailyWakeRecords_v1"
        )
    }

    private func loadStoredRecords() throws -> [SleepRecord] {
        guard let data = defaults.data(
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
            defaults.removeObject(
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
        now: Date,
        planning: SleepPredictionContext?
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
        now: Date,
        planning: SleepPredictionContext?
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

final class SleepGenerationCoalescerTests: XCTestCase {
    func testWakeAndSleepNotificationsShareOnePendingGeneration() {
        var scheduled: (() -> Void)?
        let coalescer = SleepGenerationCoalescer { scheduled = $0 }
        var generationCount = 0

        coalescer.request { generationCount += 1 }
        coalescer.request { generationCount += 1 }

        XCTAssertEqual(generationCount, 0)
        scheduled?()
        XCTAssertEqual(generationCount, 1)
    }

    func testWakeOnlyNotificationSchedulesOneGeneration() {
        var scheduled: (() -> Void)?
        let coalescer = SleepGenerationCoalescer { scheduled = $0 }
        var generationCount = 0

        coalescer.request { generationCount += 1 }
        scheduled?()

        XCTAssertEqual(generationCount, 1)
    }

    func testSleepRecordNotificationSchedulesOneGeneration() {
        var scheduled: (() -> Void)?
        let coalescer = SleepGenerationCoalescer { scheduled = $0 }
        var generationCount = 0

        coalescer.request { generationCount += 1 }
        scheduled?()

        XCTAssertEqual(generationCount, 1)
    }

    func testNewPendingCycleCanScheduleAnotherGeneration() {
        var scheduled: (() -> Void)?
        let coalescer = SleepGenerationCoalescer { scheduled = $0 }
        var generationCount = 0

        coalescer.request { generationCount += 1 }
        scheduled?()
        coalescer.request { generationCount += 1 }
        scheduled?()

        XCTAssertEqual(generationCount, 2)
    }
}

@MainActor
final class SleepCoachOrchestratorLLMLifecycleTests: XCTestCase {
    func testStoreResetWhileRequestRunsCannotPublishIntoNewProfile() async {
        let started = expectation(description: "Request started before reset")
        let completed = expectation(description: "Response returned after reset")
        llmAgent.onRequest = { _ in started.fulfill() }
        llmAgent.onCompletion = { _ in completed.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [started], timeout: 1)
        defaults.generationToken = UUID()
        defaults.set("New profile", forKey: "babyName")
        let attempts = defaults.writeAttempts

        llmAgent.release(0, with: response("old profile"))
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertNil(orchestrator.snapshot)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertEqual(defaults.string(forKey: "babyName"), "New profile")
        XCTAssertEqual(defaults.writeAttempts, attempts)
        XCTAssertNil(defaults.string(forKey: "llm_coachMessage"))
    }

    func testClearingPrivateStateRejectsAnAlreadyRunningResponseAndCacheWrite() async {
        let started = expectation(description: "Private request started")
        let completed = expectation(description: "Cancelled response returned")
        llmAgent.onRequest = { _ in started.fulfill() }
        llmAgent.onCompletion = { _ in completed.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNotNil(orchestrator.snapshot)

        orchestrator.clearPrivateState()
        llmAgent.release(0, with: response("must be discarded"))
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertNil(orchestrator.snapshot)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertEqual(orchestrator.llmCacheState, .expired)
        XCTAssertNil(defaults.string(forKey: "llm_coachMessage"))
        XCTAssertNil(defaults.object(forKey: "llm_lastGenerated"))
    }

    func testStorageBecomingUnavailableRejectsInFlightResponseWithoutWrites() async {
        let started = expectation(description: "Request started before lock")
        let completed = expectation(description: "Response returned after lock")
        llmAgent.onRequest = { _ in started.fulfill() }
        llmAgent.onCompletion = { _ in completed.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [started], timeout: 1)
        let attempts = defaults.writeAttempts
        defaults.isAvailable = false

        llmAgent.release(0, with: response("locked"))
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertNil(orchestrator.snapshot)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertEqual(defaults.writeAttempts, attempts)
        XCTAssertNil(defaults.values["llm_coachMessage"])
    }

    func testCacheWriteFailureClearsPrivateStateAndDoesNotClaimCurrentCache() async {
        let started = expectation(description: "Request started before cache failure")
        let completed = expectation(description: "Response cache failed")
        llmAgent.onRequest = { _ in started.fulfill() }
        llmAgent.onCompletion = { _ in completed.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [started], timeout: 1)
        defaults.failWrites = true

        llmAgent.release(0, with: response("unsaved"))
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertFalse(defaults.isAvailable)
        XCTAssertNil(orchestrator.snapshot)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertEqual(orchestrator.llmCacheState, .expired)
        XCTAssertNil(defaults.values["llm_lastGenerated"])
    }

    func testClearingCloudAIStateKeepsLocalGuidanceAndRejectsLateResponse() async {
        let started = expectation(description: "Cloud request started")
        let completed = expectation(description: "Cloud response returned after revoke")
        llmAgent.onRequest = { _ in started.fulfill() }
        llmAgent.onCompletion = { _ in completed.fulfill() }
        orchestrator.generate(now: now)
        await fulfillment(of: [started], timeout: 1)
        let localName = orchestrator.snapshot?.babyName

        orchestrator.clearCloudAIState()
        llmAgent.release(0, with: response("revoked"))
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertNotNil(orchestrator.snapshot)
        XCTAssertEqual(orchestrator.snapshot?.babyName, localName)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertNil(defaults.string(forKey: "llm_coachMessage"))
    }

    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 10))!
    }()

    private var llmAgent: ControlledLLMAgent!
    private var orchestrator: SleepCoachOrchestrator!
    private var defaults: TestPrivateDataStore!

    override func setUp() {
        super.setUp()
        defaults = TestPrivateDataStore()
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
            profileProvider: MockSleepProfileProvider(),
            defaults: defaults
        )
        defaults.set("Test Baby", forKey: "babyName")
        defaults.set(Calendar.current.date(byAdding: .month, value: -9, to: now)!, forKey: "babyBirthDate")
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
        XCTAssertEqual(defaults.string(forKey: "llm_coachMessage"), "normal")
        XCTAssertFalse(orchestrator.isLLMLoading)
    }

    func testCachingResponseWithoutAlertRemovesPreviousCachedAlert() async throws {
        let alertResponse = response("with alert", alert: "Take care")
        let alertRequestStarted = expectation(description: "Alert response request started")
        let alertRequestCompleted = expectation(description: "Alert response request completed")
        llmAgent.onRequest = { index in
            if index == 0 { alertRequestStarted.fulfill() }
        }
        llmAgent.onCompletion = { index in
            if index == 0 { alertRequestCompleted.fulfill() }
        }

        orchestrator.generate(now: Date())
        await fulfillment(of: [alertRequestStarted], timeout: 1)
        llmAgent.release(0, with: alertResponse)
        await fulfillment(of: [alertRequestCompleted], timeout: 1)
        XCTAssertEqual(defaults.string(forKey: "llm_alert"), "Take care")

        let clearAlertRequestStarted = expectation(description: "Alert-free response request started")
        let clearAlertRequestCompleted = expectation(description: "Alert-free response request completed")
        llmAgent.onRequest = { index in
            if index == 1 { clearAlertRequestStarted.fulfill() }
        }
        llmAgent.onCompletion = { index in
            if index == 1 { clearAlertRequestCompleted.fulfill() }
        }

        orchestrator.refreshLLM()
        await fulfillment(of: [clearAlertRequestStarted], timeout: 1)
        llmAgent.release(1, with: response("without alert"))
        await fulfillment(of: [clearAlertRequestCompleted], timeout: 1)

        XCTAssertNil(defaults.string(forKey: "llm_alert"))
        orchestrator.loadCachedLLMResponse()
        XCTAssertNil(orchestrator.llmResponse?.alert)
    }

    func testSameSourceWithDifferentTriggerRemainsCurrent() async throws {
        let started = expectation(description: "Initial request started")
        let completed = expectation(description: "Initial request completed")
        llmAgent.onRequest = { index in if index == 0 { started.fulfill() } }
        llmAgent.onCompletion = { index in if index == 0 { completed.fulfill() } }

        let testNow = Date()
        orchestrator.generate(now: testNow)
        await fulfillment(of: [started], timeout: 1)
        llmAgent.release(0, with: response("initial"))
        await fulfillment(of: [completed], timeout: 1)

        let refreshStarted = expectation(description: "Manual refresh started")
        let refreshCompleted = expectation(description: "Manual refresh completed")
        llmAgent.onRequest = { index in if index == 1 { refreshStarted.fulfill() } }
        llmAgent.onCompletion = { index in if index == 1 { refreshCompleted.fulfill() } }
        orchestrator.refreshLLM()
        await fulfillment(of: [refreshStarted], timeout: 1)
        llmAgent.release(1, with: nil)
        await fulfillment(of: [refreshCompleted], timeout: 1)
        XCTAssertEqual(orchestrator.llmCacheState, .current)
    }

    func testChangedSleepRecordsMarkCachedResponseStale() async throws {
        let started = expectation(description: "Initial request started")
        let completed = expectation(description: "Initial request completed")
        llmAgent.onRequest = { index in if index == 0 { started.fulfill() } }
        llmAgent.onCompletion = { index in if index == 0 { completed.fulfill() } }

        let testNow = Date()
        orchestrator.generate(now: testNow)
        await fulfillment(of: [started], timeout: 1)
        llmAgent.release(0, with: response("initial"))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(orchestrator.llmCacheState, .current)

        saveRecords([SleepRecord(date: testNow, duration: 30, kind: .dayNap)])
        orchestrator.generate(now: testNow)
        XCTAssertEqual(orchestrator.llmCacheState, .stale)
    }

    func testChangedProfileStateMarksCachedResponseStale() async throws {
        let started = expectation(description: "Initial request started")
        let completed = expectation(description: "Initial request completed")
        llmAgent.onRequest = { index in if index == 0 { started.fulfill() } }
        llmAgent.onCompletion = { index in if index == 0 { completed.fulfill() } }

        let testNow = Date()
        orchestrator.generate(now: testNow)
        await fulfillment(of: [started], timeout: 1)
        llmAgent.release(0, with: response("initial"))
        await fulfillment(of: [completed], timeout: 1)

        defaults.set(8.0, forKey: "typicalWakeHour")
        orchestrator.generate(now: testNow)
        XCTAssertEqual(orchestrator.llmCacheState, .stale)
    }

    func testExpiredCacheRemainsExpiredRegardlessOfFingerprint() {
        defaults.set(Date.distantPast.timeIntervalSince1970, forKey: "llm_lastGenerated")
        defaults.set("cached", forKey: "llm_coachMessage")
        defaults.set("arbitrary", forKey: "llm_sourceFingerprint")

        orchestrator.loadCachedLLMResponse()

        XCTAssertEqual(orchestrator.llmCacheState, .expired)
        XCTAssertNil(orchestrator.llmResponse)
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
        XCTAssertEqual(defaults.string(forKey: "llm_coachMessage"), "newer")
    }

    func testResponseAfterConfirmationExpiryCannotBecomeCurrentWithoutANewRequest() async throws {
        let day = Calendar.current.startOfDay(for: now)
        let oldNight = SleepRecord(date: day.addingTimeInterval(-25 * 3600), duration: 0,
                                   kind: .nightSleep, isOngoing: true)
        let nap = SleepRecord(date: day.addingTimeInterval(8 * 3600), duration: 60)
        saveRecords([oldNight, nap])
        let persisted = try XCTUnwrap(SleepRecordPersistence(defaults: defaults).load()?.first { $0.id == oldNight.id })
        let source = defaults.data(forKey: "sleepRecords")
        let confirmation = StillSleepingConfirmation(record: persisted, date: now)
        let started = expectation(description: "Snapshot A request started")
        let completed = expectation(description: "Cancelled request A still returned")
        llmAgent.onRequest = { index in
            XCTAssertEqual(index, 0, "Clock-only evaluation never launches a replacement request.")
            if index == 0 { started.fulfill() }
        }
        llmAgent.onCompletion = { index in if index == 0 { completed.fulfill() } }

        orchestrator.generate(now: now, confirmation: confirmation)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(orchestrator.snapshot?.currentSleepKind, .nightSleep)
        XCTAssertEqual(orchestrator.snapshot?.sleepAssessment?.active?.confirmation, now)
        XCTAssertTrue(orchestrator.isLLMLoading)

        let expiry = now.addingTimeInterval(90 * 60)
        orchestrator.generate(now: expiry, confirmation: confirmation, requestCoaching: false)
        XCTAssertEqual(orchestrator.snapshot?.generatedAt, expiry)
        XCTAssertNil(orchestrator.snapshot?.currentSleepKind)
        XCTAssertEqual(orchestrator.snapshot?.sleepAssessment?.reviewRecord?.id, oldNight.id)
        XCTAssertEqual(orchestrator.snapshot?.recordedSleepDay, .incomplete(60, reason: .incomplete))
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), source)

        llmAgent.release(0, with: response("Snapshot A"))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(llmAgent.receivedSnapshots.count, 1)
        XCTAssertNil(orchestrator.currentCoaching)
        XCTAssertNil(orchestrator.llmResponse)
        XCTAssertEqual(orchestrator.llmCacheState, .expired)
        XCTAssertFalse(orchestrator.isLLMLoading)
        XCTAssertNil(defaults.string(forKey: "llm_coachMessage"))
        XCTAssertNil(defaults.string(forKey: "llm_sourceFingerprint"))
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
        XCTAssertEqual(defaults.string(forKey: "llm_coachMessage"), "refresh")
    }

    func testManualRefreshUsesRecordsMatchedToPublishedSnapshot() async {
        let currentDay = Date()
        let requestStarted = expectation(description: "Manual LLM request started")
        let requestCompleted = expectation(description: "Manual LLM request completed")
        llmAgent.onRequest = { _ in requestStarted.fulfill() }
        llmAgent.onCompletion = { _ in requestCompleted.fulfill() }

        defaults.set(currentDay.timeIntervalSince1970, forKey: "llm_lastGenerated")
        orchestrator.generate(now: currentDay)
        let stateBRecord = SleepRecord(date: currentDay, duration: 30, kind: .dayNap)
        saveRecords([stateBRecord])

        orchestrator.refreshLLM()
        await fulfillment(of: [requestStarted], timeout: 1)

        guard let trigger = llmAgent.receivedTriggers.last else {
            return XCTFail("Expected a manual refresh trigger")
        }
        if case .manualRefresh = trigger {
            // Expected trigger.
        } else {
            XCTFail("Expected a manual refresh trigger")
        }
        XCTAssertNil(llmAgent.receivedSnapshots.last?.todayTotalMinutes)
        XCTAssertEqual(llmAgent.receivedSnapshots.last?.recordedSleepDay, .incomplete(nil, reason: .missing))
        XCTAssertEqual(llmAgent.receivedRecords.last?.count, 0)
        llmAgent.release(0, with: nil)
        await fulfillment(of: [requestCompleted], timeout: 1)
    }

    func testAutomaticGenerationUsesMatchingSnapshotAndRecords() async throws {
        let currentDay = now
        let requestStarted = expectation(description: "Automatic LLM request started")
        let requestCompleted = expectation(description: "Automatic LLM request completed")
        llmAgent.onRequest = { _ in requestStarted.fulfill() }
        llmAgent.onCompletion = { _ in requestCompleted.fulfill() }

        defaults.set(currentDay.timeIntervalSince1970, forKey: "llm_lastGenerated")
        orchestrator.generate(now: currentDay)
        // Keep the completed session entirely before the injected calculation time.
        let stateBRecord = SleepRecord(date: currentDay.addingTimeInterval(-30 * 60), duration: 30,
                                       kind: .dayNap, createdAt: currentDay)
        saveRecords([stateBRecord])

        orchestrator.generate(now: currentDay)
        await fulfillment(of: [requestStarted], timeout: 1)

        guard let trigger = llmAgent.receivedTriggers.last else {
            return XCTFail("Expected a short nap trigger")
        }
        if case .shortNapDetected = trigger {
            // Expected trigger.
        } else {
            XCTFail("Expected a short nap trigger")
        }
        XCTAssertEqual(llmAgent.receivedSnapshots.last?.todayTotalMinutes, 30)
        let capturedRecord = try XCTUnwrap(llmAgent.receivedRecords.last?.first)
        XCTAssertEqual(capturedRecord.id, stateBRecord.id)
        XCTAssertEqual(capturedRecord.date, stateBRecord.date)
        XCTAssertEqual(capturedRecord.duration, stateBRecord.duration)
        XCTAssertEqual(capturedRecord.kind, stateBRecord.kind)
        llmAgent.release(0, with: nil)
        await fulfillment(of: [requestCompleted], timeout: 1)
    }

    private func response(_ message: String, alert: String? = nil) -> LLMCoachResponse {
        LLMCoachResponse(patternInsight: "pattern", coachMessage: message, alert: alert, confidenceNote: "confidence", generatedAt: Date())
    }

    private func saveRecords(_ records: [SleepRecord]) {
        defaults.set(try! JSONEncoder().encode(records), forKey: "sleepRecords")
    }

    private func clearDefaults() {
        ["sleepRecords", "dailyWakeRecords_v1", "babyName", "babyBirthDate", "typicalWakeHour", "typicalWakeMinute", "llm_lastGenerated", "llm_coachMessage", "llm_patternInsight", "llm_confidenceNote", "llm_alert", "llm_sourceFingerprint"].forEach {
            defaults.removeObject(forKey: $0)
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
    private(set) var receivedSnapshots: [OrchestratedSnapshot] = []
    private(set) var receivedRecords: [[SleepRecord]] = []
    private(set) var receivedTriggers: [LLMTrigger] = []

    func generateInsight(snapshot: OrchestratedSnapshot, records: [SleepRecord], trigger: LLMTrigger) async -> LLMCoachResponse? {
        let index = nextRequestID
        nextRequestID += 1
        receivedSnapshots.append(snapshot)
        receivedRecords.append(records)
        receivedTriggers.append(trigger)
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
