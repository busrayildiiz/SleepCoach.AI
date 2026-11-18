import XCTest
@testable import BabySleepTracker

final class SleepWakeTimeWorkflowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SleepWakeTimeWorkflowTests-\(UUID().uuidString)")!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
    }

    func testNormalizesWakeTimeAndReplacesTodayOnly() throws {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let oldToday = DailyWakeRecord(day: today, wakeTime: today)
        let otherDay = DailyWakeRecord(day: yesterday, wakeTime: yesterday)
        let selected = calendar.date(bySettingHour: 8, minute: 25, second: 42, of: yesterday)!
        let result = workflow(selected: selected, wakeRecords: [oldToday, otherDay]).execute()
        let saved = try XCTUnwrap(result.updatedWakeRecords.first { calendar.isDate($0.day, inSameDayAs: today) })

        XCTAssertEqual(saved.day, today)
        XCTAssertEqual(calendar.component(.hour, from: saved.wakeTime), 8)
        XCTAssertEqual(calendar.component(.minute, from: saved.wakeTime), 25)
        XCTAssertEqual(calendar.component(.second, from: saved.wakeTime), 0)
        XCTAssertEqual(result.updatedWakeRecords.count, 2)
        XCTAssertTrue(result.updatedWakeRecords.contains { $0.id == otherDay.id })
    }

    func testPersistsWakeRecordsAndPostsNotification() {
        let expectation = expectation(forNotification: .dailyWakeRecordsDidChange, object: nil)
        let result = workflow(selected: now).execute()
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(result.wakePersistenceSucceeded)
        XCTAssertNotNil(defaults.data(forKey: "dailyWakeRecords_v1"))
    }

    func testSelectsLatestQualifyingNightAndPreservesMetadata() throws {
        let older = record(at: now.addingTimeInterval(-4 * 3600), kind: .nightSleep, ongoing: true)
        let latest = record(at: now.addingTimeInterval(-2 * 3600), kind: .nightSleep, ongoing: true, parent: UUID())
        let result = workflow(selected: now, sleepRecords: [older, latest]).execute()
        let closed = try XCTUnwrap(result.closedNightRecord)

        XCTAssertEqual(closed.id, latest.id)
        XCTAssertEqual(closed.date, latest.date)
        XCTAssertEqual(closed.kind, latest.kind)
        XCTAssertEqual(closed.parentNapID, latest.parentNapID)
        XCTAssertEqual(closed.createdAt, latest.createdAt)
        XCTAssertFalse(closed.isOngoing)
        XCTAssertEqual(closed.duration, 120)
        XCTAssertTrue(result.updatedSleepRecords.contains { $0.id == older.id && $0.isOngoing })
        XCTAssertTrue(result.sleepPersistenceSucceeded)
        XCTAssertNotNil(defaults.data(forKey: "sleepRecords"))
    }

    func testIgnoresDayNapCompletedNightAndFutureNight() {
        let nap = record(at: now.addingTimeInterval(-3600), kind: .dayNap, ongoing: true)
        let completed = record(at: now.addingTimeInterval(-2 * 3600), kind: .nightSleep, ongoing: false)
        let future = record(at: now.addingTimeInterval(3600), kind: .nightSleep, ongoing: true)
        let result = workflow(selected: now, sleepRecords: [nap, completed, future]).execute()

        XCTAssertNil(result.closedNightRecord)
        XCTAssertFalse(result.sleepPersistenceSucceeded)
        XCTAssertEqual(result.updatedSleepRecords.map(\.id), [nap.id, completed.id, future.id])
    }

    func testPreservesConfirmedEndBeyondTwelveHours() throws {
        let short = record(at: now.addingTimeInterval(-30), kind: .nightSleep, ongoing: true)
        XCTAssertEqual(workflow(selected: now, sleepRecords: [short]).execute().closedNightRecord?.duration, 1)

        let long = record(at: now.addingTimeInterval(-13 * 3600), kind: .nightSleep, ongoing: true)
        let result = workflow(selected: now, sleepRecords: [long]).execute()
        XCTAssertEqual(result.closedNightRecord?.duration, 780)
        XCTAssertEqual(result.closedNightRecord?.observedEnd, now)
        let data = try XCTUnwrap(defaults.data(forKey: "sleepRecords"))
        XCTAssertEqual(try JSONDecoder().decode([SleepRecord].self, from: data).first?.duration, 780)
    }

    func testHistoricalWakePreservesNightAndDoesNotInferLinkFromMatchingEnd() throws {
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let time = day.addingTimeInterval(7 * 3600)
        let start = time.addingTimeInterval(-8 * 3600)
        let night = SleepRecord(date: start, duration: 480, kind: .nightSleep, createdAt: start, endDate: time)
        let command = workflow(selected: time, sleepRecords: [night])
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: command.wakePersistence)
        let originalSleep = defaults.data(forKey: "sleepRecords")

        let confirmation = draft.confirmObservedWake(at: time)
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: confirmation), .saved)
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: confirmation), .confirmationRequired)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), originalSleep)
        let wake = try XCTUnwrap(command.wakePersistence.load()?.first)
        XCTAssertEqual(wake.day, day)
        XCTAssertEqual(wake.wakeTime, time)
        XCTAssertEqual(command.wakePersistence.load()?.count, 1)
        XCTAssertEqual(TrustedObservationAdapter(defaults: defaults).snapshot().wakes.first?.source, .verifiedObservation)
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
    }

    func testHistoricalWakeRejectsEditRevertAndAmbiguousWakes() {
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let original = DailyWakeRecord(day: day, wakeTime: day.addingTimeInterval(7 * 3600))
        let time = original.wakeTime.addingTimeInterval(1800)
        let command = workflow(selected: time, wakeRecords: [original])
        let persistence = command.wakePersistence
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        let corrected = DailyWakeRecord(id: original.id, day: day, wakeTime: time)
        XCTAssertTrue(persistence.save([corrected]))
        XCTAssertTrue(persistence.save([original]))
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .stale)

        XCTAssertTrue(persistence.save([original, DailyWakeRecord(day: day, wakeTime: time)]))
        let ambiguous = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        XCTAssertEqual(command.recoverHistoricalWake(ambiguous, confirmation: ambiguous.confirmObservedWake(at: time)), .ambiguous)
        XCTAssertEqual(persistence.load()?.count, 2)
    }

    func testHistoricalWakeResumesAfterRecordWriteFailure() throws {
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let time = day.addingTimeInterval(7 * 3600)
        let store = try XCTUnwrap(defaults)
        let failing = DailyWakeRecordPersistence(defaults: store, writer: { data, key in
            guard key != "dailyWakeRecords_v1" else { return false }
            store.set(data, forKey: key)
            return true
        })
        let sleeps = SleepRecordPersistence(defaults: store)
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: failing)
        let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: failing, sleepPersistence: sleeps)

        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .incomplete)
        XCTAssertNil(failing.load())
        let recovered = SleepWakeTimeWorkflow.resumePending(now: now,
            wakePersistence: DailyWakeRecordPersistence(defaults: store), sleepPersistence: sleeps)
        XCTAssertTrue(recovered?.evidencePublicationSucceeded == true)
        XCTAssertEqual(recovered?.updatedWakeRecords.first?.wakeTime, time)
        XCTAssertNil(store.data(forKey: "sleepRecords"))
    }

    func testRecoveringBothBoundariesMakesCoverageReviewableWithoutConfirmingIt() throws {
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -2, to: today)!
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let wakes = DailyWakeRecordPersistence(defaults: defaults)
        let sleeps = SleepRecordPersistence(defaults: defaults)
        for label in [day, next] {
            let command = SleepWakeTimeWorkflow(selectedWakeTime: label.addingTimeInterval(7 * 3600),
                now: now, calendar: calendar, wakeRecords: [], sleepRecords: [],
                wakePersistence: wakes, sleepPersistence: sleeps)
            let draft = HistoricalWakeDraft(day: label, calendar: calendar, persistence: wakes)
            XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: command.selectedWakeTime)), .saved)
        }
        let records = try XCTUnwrap(wakes.load()).sorted { $0.day < $1.day }
        guard records.count == 2 else { return XCTFail("Expected two canonical wakes") }
        let adapter = TrustedObservationAdapter(defaults: defaults)
        let review = try XCTUnwrap(adapter.prepareDaytimeReview(morningWakeID: records[0].id,
            followingWakeID: records[1].id, calendar: calendar))
        XCTAssertEqual(review.savedCoverage, .unknown)
        XCTAssertTrue(adapter.snapshot(calendar: calendar).daytime.isEmpty)
    }

    func testHistoricalWakeRejectsTimeOutsideSelectedDay() {
        let command = workflow(selected: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let draft = HistoricalWakeDraft(day: yesterday, calendar: calendar, persistence: command.wakePersistence)
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: now)), .invalidTime)
        XCTAssertEqual(command.wakePersistence.load()?.count, 0)
    }

    func testHistoricalServiceRejectsMissingForeignAndMismatchedConfirmation() {
        let day = calendar.startOfDay(for: now.addingTimeInterval(-86400))
        let time = day.addingTimeInterval(7 * 3600)
        let legacy = DailyWakeRecord(day: day, wakeTime: time)
        let command = workflow(selected: time, wakeRecords: [legacy])
        let persistence = command.wakePersistence
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        let foreign = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)

        XCTAssertEqual(command.recoverHistoricalWake(draft), .confirmationRequired)
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: foreign.confirmObservedWake(at: time)),
                       .confirmationRequired)
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time + 60)),
                       .confirmationRequired)
        let adapter = TrustedObservationAdapter(defaults: defaults)
        XCTAssertNotEqual(adapter.snapshot().wakes.first?.source, .verifiedObservation)

        let fresh = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        XCTAssertEqual(command.recoverHistoricalWake(fresh, confirmation: fresh.confirmObservedWake(at: time)), .saved)
        XCTAssertEqual(adapter.snapshot().wakes.first?.record.id, legacy.id)
        XCTAssertEqual(adapter.snapshot().wakes.first?.source, .verifiedObservation)
    }

    func testHistoricalAbsenceRejectsInsertDeleteButAllowsUnrelatedWrites() {
        let day = calendar.startOfDay(for: now.addingTimeInterval(-86400))
        let time = day.addingTimeInterval(7 * 3600)
        let command = workflow(selected: time)
        let persistence = command.wakePersistence
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        XCTAssertTrue(persistence.save([DailyWakeRecord(day: day, wakeTime: time)]))
        XCTAssertTrue(persistence.save([]))
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .stale)

        let fresh = HistoricalWakeDraft(day: day, calendar: calendar, persistence: persistence)
        let today = calendar.startOfDay(for: now)
        XCTAssertTrue(persistence.save([DailyWakeRecord(day: today, wakeTime: now)]))
        XCTAssertEqual(command.recoverHistoricalWake(fresh, confirmation: fresh.confirmObservedWake(at: time)), .saved)
        XCTAssertEqual(persistence.load()?.count, 2)
    }

    func testHistoricalDSTGapAndFoldPreserveSelectedInstantAndLocalDay() throws {
        var scope = Calendar(identifier: .gregorian)
        scope.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try XCTUnwrap(scope.date(from: DateComponents(year: 2025, month: 3, day: 9)))
        let fold = try XCTUnwrap(scope.date(from: DateComponents(year: 2025, month: 11, day: 2)))
        let gap = DateComponents(hour: 2, minute: 30)
        let repeated = DateComponents(hour: 1, minute: 30)
        let springEnd = try XCTUnwrap(scope.date(byAdding: .day, value: 1, to: spring))
        let first = try XCTUnwrap(scope.nextDate(after: fold - 1, matching: repeated,
            matchingPolicy: .strict, repeatedTimePolicy: .first))
        let last = try XCTUnwrap(scope.nextDate(after: fold - 1, matching: repeated,
            matchingPolicy: .strict, repeatedTimePolicy: .last))
        XCTAssertFalse(scope.nextDate(after: spring - 1, matching: gap, matchingPolicy: .strict)
            .map { $0 < springEnd } ?? false)
        XCTAssertEqual(last.timeIntervalSince(first), 3600)
        let wakes = DailyWakeRecordPersistence(defaults: defaults)
        let sleeps = SleepRecordPersistence(defaults: defaults)
        func save(_ time: Date, on day: Date) -> HistoricalWakeOutcome {
            let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: scope,
                wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps)
            let draft = HistoricalWakeDraft(day: day, calendar: scope, persistence: wakes)
            return command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time))
        }
        XCTAssertEqual(save(springEnd, on: spring), .invalidTime)
        XCTAssertEqual(save(spring, on: spring), .saved)
        XCTAssertEqual(save(first, on: fold), .saved)
        let firstRecord = try XCTUnwrap(wakes.load()?.first { $0.day == fold })
        XCTAssertEqual(save(last, on: fold), .saved)
        let corrected = try XCTUnwrap(wakes.load()?.first { $0.day == fold })
        XCTAssertEqual(corrected.id, firstRecord.id)
        XCTAssertEqual(corrected.wakeTime, last)
        XCTAssertEqual(wakes.load()?.count, 2)
    }

    func testHistoricalWakeCorrectionRotatesCoverageAndRejectsPreparedReview() throws {
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -2, to: today)!
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let wakes = DailyWakeRecordPersistence(defaults: defaults)
        let sleeps = SleepRecordPersistence(defaults: defaults)
        func save(_ label: Date, hour: Double) {
            let time = label.addingTimeInterval(hour * 3600)
            let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
                wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps)
            let draft = HistoricalWakeDraft(day: label, calendar: calendar, persistence: wakes)
            XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .saved)
        }
        save(day, hour: 7)
        save(next, hour: 7)
        let saved = try XCTUnwrap(wakes.load())
        let morning = try XCTUnwrap(saved.first { $0.day == day }).id
        let following = try XCTUnwrap(saved.first { $0.day == next }).id
        let adapter = TrustedObservationAdapter(defaults: defaults)
        let review = try XCTUnwrap(adapter.prepareDaytimeReview(morningWakeID: morning,
            followingWakeID: following, calendar: calendar))
        XCTAssertTrue(review.draft.submit(.allNapsRecorded, at: now, using: wakes.storage, calendar: calendar))
        let binding = adapter.daytimeRevisionIdentity(morningWakeID: morning, followingWakeID: following, calendar: calendar)
        save(day, hour: 8)
        save(day, hour: 7)
        XCTAssertNotEqual(adapter.daytimeRevisionIdentity(morningWakeID: morning,
            followingWakeID: following, calendar: calendar), binding)
        XCTAssertFalse(review.draft.submit(.allNapsRecorded, at: now, using: wakes.storage, calendar: calendar))
        XCTAssertTrue(adapter.snapshot(calendar: calendar).daytime.isEmpty)
    }

    func testHistoricalPublicationIsUntrustedUntilReplayClearsJournalInRecordedZone() throws {
        let suite = "HistoricalWakeReplay-\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        var zone = calendar!
        zone.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let localDay = zone.startOfDay(for: now - 86400)
        let time = localDay + 60
        XCTAssertFalse(calendar.isDate(time, inSameDayAs: localDay + 20 * 3600))
        let adapter = TrustedObservationAdapter(defaults: store)
        let writes = DailyWakeRecordPersistence(defaults: store, writer: { data, key in
            store.set(data, forKey: key)
            if key == ObservationProvenance.key,
               ObservationProvenance.load(store)?.wakes.values.contains(where: { $0.historicalWakeCalendar != nil }) == true {
                XCTAssertNotEqual(adapter.snapshot().wakes.first?.source, .verifiedObservation)
                return false // Simulate interruption after sidecar write, before cleanup.
            }
            return true
        })
        let draft = HistoricalWakeDraft(day: localDay, calendar: zone, persistence: writes)
        let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: writes, sleepPersistence: .init(defaults: store))
        XCTAssertEqual(command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .incomplete)
        XCTAssertNotNil(StandaloneWakePending.load(store))
        XCTAssertNotEqual(adapter.snapshot().wakes.first?.source, .verifiedObservation)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let result = SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: .init(defaults: reopened),
            sleepPersistence: .init(defaults: reopened))
        XCTAssertTrue(result?.evidencePublicationSucceeded == true)
        XCTAssertEqual(result?.updatedWakeRecords.first?.day, localDay)
        XCTAssertEqual(result?.updatedWakeRecords.first?.wakeTime, time)
        XCTAssertNil(StandaloneWakePending.load(reopened))
        XCTAssertEqual(TrustedObservationAdapter(defaults: reopened).snapshot().wakes.first?.source, .verifiedObservation)
    }

    func testHistoricalPersistenceNotificationsRejectDuplicateCorrectionDeletionAndRevert() {
        for stage in [Notification.Name.dailyWakeRecordsDidChange, .observationProvenanceDidChange] {
            for mutation in ["duplicate", "correct", "delete", "revert"] {
                let store = UserDefaults(suiteName: "HistoricalWakeMutation-\(UUID())")!
                let wakes = DailyWakeRecordPersistence(defaults: store)
                let adapter = TrustedObservationAdapter(defaults: store)
                let day = calendar.startOfDay(for: now - 86400)
                let time = day + 7 * 3600
                let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: wakes)
                let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
                    wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: .init(defaults: store))
                let once = HistoricalNotificationGate()
                let observer = NotificationCenter.default.addObserver(forName: stage, object: nil, queue: nil) { _ in
                    guard let wake = wakes.load()?.first,
                          (stage == .dailyWakeRecordsDidChange || StandaloneWakePending.load(wakes.defaults) == nil),
                          once.enter() else { return }
                    let correction = DailyWakeRecord(id: wake.id, day: day, wakeTime: time + 60)
                    switch mutation {
                    case "duplicate":
                        XCTAssertTrue(wakes.save([wake, DailyWakeRecord(day: day, wakeTime: time + 60)]))
                        XCTAssertTrue(wakes.save([wake]))
                    case "correct": XCTAssertTrue(wakes.save([correction]))
                    case "delete": XCTAssertTrue(wakes.save([]))
                    default:
                        XCTAssertTrue(wakes.save([correction]))
                        XCTAssertTrue(wakes.save([wake]))
                    }
                    XCTAssertFalse(adapter.snapshot().wakes.contains { $0.source == .verifiedObservation })
                }
                let capture = draft.confirmObservedWake(at: time)
                let result = command.recoverHistoricalWake(draft, confirmation: capture)
                NotificationCenter.default.removeObserver(observer)
                XCTAssertEqual(result, .stale, "\(stage) \(mutation)")
                XCTAssertFalse(result.canRetry)
                XCTAssertNil(StandaloneWakePending.load(store))
                XCTAssertTrue(draft.abandon())
                let reopened = HistoricalWakeDraft(day: day, calendar: calendar, persistence: wakes)
                XCTAssertEqual(command.recoverHistoricalWake(reopened, confirmation: capture), .confirmationRequired)
                XCTAssertFalse(adapter.snapshot().wakes.contains { $0.source == .verifiedObservation })
                XCTAssertNil(SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: wakes,
                    sleepPersistence: .init(defaults: store)))
            }
        }
    }

    func testDayDetailWakeEvidenceUsesLocalDayAndNeverPicksADuplicate() {
        let day = calendar.startOfDay(for: now - 4 * 86400)
        let first = DailyWakeRecord(day: day, wakeTime: day + 7 * 3600)
        let duplicate = DailyWakeRecord(day: day, wakeTime: day + 8 * 3600)
        let unrelated = DailyWakeRecord(day: day - 86400, wakeTime: day - 3600)
        XCTAssertEqual(DayDetailWakeEvidence(records: [unrelated], day: day, calendar: calendar), .missing)
        XCTAssertEqual(DayDetailWakeEvidence(records: [unrelated, first], day: day, calendar: calendar),
                       .recorded(first.wakeTime))
        XCTAssertEqual(DayDetailWakeEvidence(records: [duplicate, unrelated, first], day: day, calendar: calendar),
                       .ambiguous)
    }

    func testHistoricalFailedCompetingWriteRequiresFreshReviewEvenWithUnchangedWakeBytes() {
        let day = calendar.startOfDay(for: now - 4 * 86400)
        let time = day + 7 * 3600
        let command = workflow(selected: time)
        let wakes = command.wakePersistence
        let stale = HistoricalWakeDraft(day: day, calendar: calendar, persistence: wakes)
        let capture = stale.confirmObservedWake(at: time)
        let store = wakes.defaults
        let failing = DailyWakeRecordPersistence(defaults: store, writer: { data, key in
            guard key != "dailyWakeRecords_v1" else { return false }
            store.set(data, forKey: key)
            return true
        })
        let before = store.data(forKey: "dailyWakeRecords_v1")
        XCTAssertFalse(failing.save([DailyWakeRecord(day: day, wakeTime: time + 60)]))
        XCTAssertEqual(store.data(forKey: "dailyWakeRecords_v1"), before)
        let result = command.recoverHistoricalWake(stale, confirmation: capture)
        XCTAssertEqual(result, .stale)
        XCTAssertFalse(result.canRetry)
        XCTAssertTrue(stale.abandon())

        let fresh = HistoricalWakeDraft(day: day, calendar: calendar, persistence: wakes)
        XCTAssertEqual(command.recoverHistoricalWake(fresh, confirmation: capture), .confirmationRequired)
        XCTAssertEqual(command.recoverHistoricalWake(fresh, confirmation: fresh.confirmObservedWake(at: time)), .saved)
        XCTAssertEqual(wakes.load()?.first?.day, day)
    }

    func testHistoricalRetryCanBeCancelledAndCannotAuthorizeFreshDraft() {
        let day = calendar.startOfDay(for: now - 4 * 86400)
        let time = day + 7 * 3600
        let store = defaults!
        let fails = DailyWakeRecordPersistence(defaults: store, writer: { data, key in
            guard key != "dailyWakeRecords_v1" else { return false }
            store.set(data, forKey: key)
            return true
        })
        let sleeps = SleepRecordPersistence(defaults: store)
        let command = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: fails, sleepPersistence: sleeps)
        let original = HistoricalWakeDraft(day: day, calendar: calendar, persistence: fails)
        let capture = original.confirmObservedWake(at: time)
        let result = command.recoverHistoricalWake(original, confirmation: capture)
        XCTAssertEqual(result, .incomplete)
        XCTAssertTrue(result.canRetry)
        XCTAssertTrue(result.blocksEditing)
        XCTAssertTrue(original.abandon())
        XCTAssertNil(StandaloneWakePending.load(store))
        XCTAssertEqual(command.recoverHistoricalWake(original, confirmation: capture), .stale)
        let reopened = HistoricalWakeDraft(day: day, calendar: calendar, persistence: fails)
        XCTAssertEqual(command.recoverHistoricalWake(reopened, confirmation: capture), .confirmationRequired)
        XCTAssertEqual(command.recoverHistoricalWake(reopened), .confirmationRequired)
    }

    func testHistoricalUnreadableStorageBlocksEditingAndRetryWithoutChangingData() {
        let day = calendar.startOfDay(for: now - 4 * 86400)
        let time = day + 7 * 3600
        let command = workflow(selected: time)
        let invalid = Data("unreadable".utf8)
        defaults.set(invalid, forKey: "dailyWakeRecords_v1")
        let draft = HistoricalWakeDraft(day: day, calendar: calendar, persistence: command.wakePersistence)
        let result = command.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time))
        XCTAssertEqual(result, .recoveryFailed)
        XCTAssertTrue(result.blocksEditing)
        XCTAssertFalse(result.canRetry)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), invalid)
    }

    private final class HistoricalNotificationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false

        func enter() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !entered else { return false }
            entered = true
            return true
        }
    }

    private func workflow(selected: Date, wakeRecords: [DailyWakeRecord] = [], sleepRecords: [SleepRecord] = []) -> SleepWakeTimeWorkflow {
        _ = DailyWakeRecordPersistence(defaults: defaults).save(wakeRecords)
        _ = SleepRecordPersistence(defaults: defaults).save(sleepRecords)
        return SleepWakeTimeWorkflow(selectedWakeTime: selected, now: now, calendar: calendar, wakeRecords: wakeRecords, sleepRecords: sleepRecords, wakePersistence: DailyWakeRecordPersistence(defaults: defaults), sleepPersistence: SleepRecordPersistence(defaults: defaults))
    }

    private func record(at date: Date, kind: SleepKind, ongoing: Bool, parent: UUID? = nil) -> SleepRecord {
        SleepRecord(date: date, duration: 0, kind: kind, parentNapID: parent, isOngoing: ongoing, createdAt: date)
    }
}

/// Exercises the production End Sleep submission and B1 storage/journal boundaries.
final class NightSleepCompletionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var calendar: Calendar!
    private var endpoint: Date!
    private var now: Date!
    private var sleeps: SleepRecordPersistence { .init(defaults: defaults) }
    private var wakes: DailyWakeRecordPersistence { .init(defaults: defaults) }

    override func setUp() {
        super.setUp()
        suite = "NightSleepCompletionTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        endpoint = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 6, minute: 42))!.addingTimeInterval(0.123456)
        now = endpoint.addingTimeInterval(3600)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }
    @discardableResult
    private func night(verified: Bool = false) throws -> SleepRecord {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 19, minute: 30))!
        if verified {
            var draft = SleepRecordingDraft(defaultDate: start.addingTimeInterval(-600), now: now)
            draft.start = start; draft.isOngoing = true
            var submission = RecordingSubmission()
            submission.submit(draft: draft, kind: .nightSleep, now: now, save: { self.sleeps.saveRecording($0, now: self.now) }, dismiss: {})
            XCTAssertTrue(submission.isSubmitted)
        } else {
            XCTAssertTrue(sleeps.save([SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: start.addingTimeInterval(5))]))
        }
        return try XCTUnwrap(sleeps.load()?.first)
    }
    private func submitted(_ original: SleepRecord, attested: Bool = true) throws -> SleepRecord {
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: attested ? now : endpoint)
        draft.end = endpoint
        var submission = RecordingSubmission()
        var value: SleepRecord?
        submission.submit(draft: draft, kind: original.kind, editing: original, now: now, save: { value = $0; return true }, dismiss: {})
        return try XCTUnwrap(value)
    }
    private func complete(_ record: SleepRecord, writer: ((Data, String) -> Bool)? = nil) -> NightSleepCompletionResult {
        NightSleepCompletion(submitted: record, now: now, calendar: calendar,
            sleepPersistence: .init(defaults: defaults, writer: writer), wakePersistence: .init(defaults: defaults, writer: writer)).execute()
    }
    private func failing(_ key: String, afterWrite: Bool = false) -> (Data, String) -> Bool {
        { data, candidate in
            if candidate == key {
                if afterWrite { self.defaults.set(data, forKey: candidate) }
                return false
            }
            self.defaults.set(data, forKey: candidate); return true
        }
    }
    private func recover() -> SleepWakeTimeWorkflowResult? {
        let reloaded = UserDefaults(suiteName: suite)!
        return SleepWakeTimeWorkflow.resumePending(now: now, wakePersistence: .init(defaults: reloaded), sleepPersistence: .init(defaults: reloaded))
    }
    private var snapshot: LearningEvidenceSnapshot { TrustedObservationAdapter(defaults: defaults).snapshot() }

    func testHomeWakeAndNightCompletionCoordinateHistoricalJournals() throws {
        for homeAction in ["wake", "night"] {
            for status in ["active", "completed", "cancelled", "stale", "unwritable"] {
                defaults.removePersistentDomain(forName: suite)
                let historicalDay = calendar.startOfDay(for: now - 2 * 86400)
                let time = historicalDay + 7 * 3600
                let writes = DailyWakeRecordPersistence(defaults: defaults, writer: failing("dailyWakeRecords_v1"))
                let draft = HistoricalWakeDraft(day: historicalDay, calendar: calendar, persistence: writes)
                let historical = SleepWakeTimeWorkflow(selectedWakeTime: time, now: now, calendar: calendar,
                    wakeRecords: [], sleepRecords: [], wakePersistence: writes, sleepPersistence: sleeps)
                XCTAssertEqual(historical.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: time)), .incomplete)
                var pending = try XCTUnwrap(StandaloneWakePending.load(defaults))
                switch status {
                case "completed": XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
                case "cancelled":
                    pending.isCancelled = true
                    XCTAssertTrue(wakes.storage.standaloneJournal(pending))
                case "stale":
                    let replacement = DailyWakeRecord(day: historicalDay, wakeTime: time + 60)
                    defaults.set(try JSONEncoder().encode([replacement]), forKey: "dailyWakeRecords_v1")
                default: break
                }

                let writer = status == "unwritable" ? failing("dailyWakeRecords_v1") : nil
                if homeAction == "wake" {
                    let command = SleepWakeTimeWorkflow(selectedWakeTime: endpoint, now: now, calendar: calendar,
                        wakeRecords: [], sleepRecords: [], wakePersistence: .init(defaults: defaults, writer: writer),
                        sleepPersistence: sleeps)
                    let result = command.execute()
                    XCTAssertEqual(result.historicalRecovery, status == "unwritable" ? .failed : nil)
                    XCTAssertEqual(result.wakePersistenceSucceeded, status != "unwritable")
                } else {
                    let value = try submitted(night())
                    let result = complete(value, writer: writer)
                    if status == "unwritable" {
                        guard case .recoveryFailure = result.state else { return XCTFail("Expected recovery failure") }
                    }
                    else { XCTAssertTrue(result.succeeded, status) }
                }
                if status == "unwritable" {
                    XCTAssertEqual(StandaloneWakePending.load(defaults)?.operationID, pending.operationID)
                } else {
                    XCTAssertNil(StandaloneWakePending.load(defaults))
                    let historicalWakes = snapshot.wakes.filter { $0.record.day == historicalDay }
                    if status == "active" || status == "completed" {
                        XCTAssertEqual(historicalWakes.first?.record.wakeTime, time)
                        XCTAssertEqual(historicalWakes.first?.source, .verifiedObservation)
                    } else if status == "stale" {
                        XCTAssertEqual(historicalWakes.first?.record.wakeTime, time + 60)
                        XCTAssertNotEqual(historicalWakes.first?.source, .verifiedObservation)
                    } else {
                        XCTAssertTrue(historicalWakes.isEmpty)
                    }
                }
            }
        }
    }

    func testHistoricalConfirmationOfExistingVerifiedWakePreservesNightLinkAndRevision() throws {
        let original = try night(verified: true)
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        let wake = try XCTUnwrap(wakes.load()?.first)
        let metadata = try XCTUnwrap(ObservationProvenance.load(defaults))
        let nightBytes = defaults.data(forKey: "sleepRecords")
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        let draft = HistoricalWakeDraft(day: wake.day, calendar: calendar, persistence: wakes)
        let historical = SleepWakeTimeWorkflow(selectedWakeTime: wake.wakeTime, now: later, calendar: calendar,
            wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps)
        XCTAssertEqual(historical.recoverHistoricalWake(draft, confirmation: draft.confirmObservedWake(at: wake.wakeTime)), .saved)
        XCTAssertEqual(sleeps.load()?.first?.id, original.id)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), nightBytes)
        XCTAssertEqual(wakes.load()?.first?.persistedRevision, wake.persistedRevision)
        XCTAssertEqual(ObservationProvenance.load(defaults)?.sleeps, metadata.sleeps)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
    }

    func testHomeRecordingSubmissionPersistsExactNightAndCanonicalWakeOnce() throws {
        let original = try night()
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: now); draft.end = endpoint
        var submission = RecordingSubmission()
        var dismissals = 0
        var operation: SleepRecord?
        submission.submit(draft: draft, kind: .nightSleep, editing: original, now: now, save: {
            operation = $0; return self.complete($0).succeeded
        }, dismiss: { dismissals += 1 })
        XCTAssertEqual(dismissals, 1)
        let record = try XCTUnwrap(sleeps.load()?.first)
        let wake = try XCTUnwrap(wakes.load()?.first)
        XCTAssertEqual(record.id, original.id)
        XCTAssertEqual(record.date, original.date)
        XCTAssertEqual(record.createdAt, original.createdAt)
        XCTAssertEqual(record.endDate, endpoint)
        XCTAssertEqual(wake.wakeTime, endpoint)
        XCTAssertEqual(wake.day, calendar.startOfDay(for: endpoint))
        XCTAssertTrue(complete(try XCTUnwrap(operation)).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(wakes.load()?.first?.id, wake.id)
    }
    func testMatchingWakeReusesIdentityWithoutUpgradingTrustOrLink() throws {
        let original = try night(verified: true)
        let wake = DailyWakeRecord(day: calendar.startOfDay(for: endpoint), wakeTime: endpoint)
        XCTAssertTrue(wakes.save([wake]))
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        XCTAssertEqual(wakes.load()?.first?.id, wake.id)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testConflictingIndependentWakeIsPreservedBeforeAnyNightWrite() throws {
        let original = try night()
        let wake = DailyWakeRecord(day: calendar.startOfDay(for: endpoint), wakeTime: endpoint.addingTimeInterval(60))
        XCTAssertTrue(wakes.save([wake]))
        XCTAssertEqual(complete(try submitted(original)).state, .wakeConflict)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, wake.wakeTime)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
    }
    func testMultipleMatchingWakesAreAmbiguous() throws {
        let original = try night()
        XCTAssertTrue(wakes.save([DailyWakeRecord(day: calendar.startOfDay(for: endpoint), wakeTime: endpoint), DailyWakeRecord(day: calendar.startOfDay(for: endpoint), wakeTime: endpoint)]))
        XCTAssertEqual(complete(try submitted(original)).state, .ambiguousWakes)
        XCTAssertEqual(wakes.load()?.count, 2)
    }
    func testMultipleOngoingNightsOnlySelectedUUIDCompletes() throws {
        let original = try night()
        let other = SleepRecord(date: original.date.addingTimeInterval(3600), duration: 0, kind: .nightSleep, isOngoing: true)
        XCTAssertTrue(sleeps.save([original, other]))
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        XCTAssertTrue(sleeps.load()?.first { $0.id == other.id }?.isOngoing == true)
        XCTAssertFalse(try XCTUnwrap(sleeps.load()?.first { $0.id == original.id }).isOngoing)
    }
    func testStaleNightRevisionAfterEditRevertIsRejected() throws {
        let original = try night()
        let value = try submitted(original)
        let changed = SleepRecord(id: original.id, date: original.date.addingTimeInterval(-60), duration: 0, kind: .nightSleep, isOngoing: true, createdAt: original.createdAt)
        XCTAssertTrue(sleeps.save([changed])); XCTAssertTrue(sleeps.save([original]))
        XCTAssertEqual(complete(value).state, .staleNight)
        XCTAssertNil(wakes.load())
    }
    func testDeletedNightCannotBeResurrectedBySubmission() throws {
        let value = try submitted(night())
        XCTAssertTrue(sleeps.delete(ids: [value.id]))
        XCTAssertEqual(complete(value).state, .staleNight)
        XCTAssertEqual(sleeps.load()?.count, 0)
        XCTAssertNil(wakes.load())
    }
    func testCompletedReplayCannotResurrectDeletedWake() throws {
        let value = try submitted(night())
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertTrue(wakes.save([]))
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.count, 0)
    }
    func testUntouchedAutomaticPrefillCreatesOrdinaryRecordsOnly() throws {
        let value = try submitted(night(verified: true), attested: false)
        XCTAssertNil(value.observationCapture)
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testExplicitEndAttestsWakeAndVerifiedOnsetButNotLegacyOnset() throws {
        let original = try night(verified: true)
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        XCTAssertEqual(snapshot.sleeps.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
    }
    func testLegacyMissingSidecarStillCompletesWithoutVerifyingOnset() throws {
        _ = try night()
        defaults.removeObject(forKey: ObservationProvenance.key)
        let original = try XCTUnwrap(sleeps.load()?.first)
        XCTAssertNil(original.persistedRevision)
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
    }
    func testMalformedAndUnsupportedMetadataRetainsOrdinaryObservations() throws {
        for data in [Data("malformed".utf8), Data("{\"version\":999}".utf8)] {
            let original = try night()
            defaults.set(data, forKey: ObservationProvenance.key)
            let legacy = try XCTUnwrap(sleeps.load()?.first)
            XCTAssertTrue(complete(try submitted(legacy)).succeeded)
            XCTAssertEqual(sleeps.load()?.first?.id, original.id)
            XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
            XCTAssertTrue(wakes.save([]))
        }
    }
    func testDayNapAndOrdinaryEditsNeverCreateWake() throws {
        let nap = SleepRecord(date: endpoint.addingTimeInterval(-3600), duration: 0, kind: .dayNap, isOngoing: true)
        XCTAssertTrue(sleeps.save([nap]))
        let value = try submitted(try XCTUnwrap(sleeps.load()?.first))
        XCTAssertEqual(complete(value).state, .invalidSubmission)
        XCTAssertTrue(sleeps.saveRecording(value, now: now))
        XCTAssertNil(wakes.load())
    }
    func testChangedStartIsRejectedWithoutWritingWake() throws {
        let original = try night()
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: now)
        draft.start = original.date.addingTimeInterval(-60); draft.end = endpoint
        var value: SleepRecord?
        var submission = RecordingSubmission()
        submission.submit(draft: draft, kind: .nightSleep, editing: original, now: now, save: { value = $0; return true }, dismiss: {})
        XCTAssertFalse(complete(try XCTUnwrap(value)).succeeded)
        XCTAssertNil(wakes.load())
    }
    func testWakeWriteFailureLeavesNightOngoingAndRetryUsesStableIdentity() throws {
        let value = try submitted(night())
        let failed = complete(value, writer: failing("dailyWakeRecords_v1"))
        XCTAssertFalse(failed.succeeded); XCTAssertFalse(failed.sleepPersisted); XCTAssertFalse(failed.wakePersisted)
        let pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.first?.id, pending.wake.id)
    }
    func testNightWriteFailurePreservesWakeAndRestartCompletesExactOperation() throws {
        let value = try submitted(night())
        let failed = complete(value, writer: failing("sleepRecords"))
        XCTAssertFalse(failed.succeeded); XCTAssertTrue(failed.wakePersisted); XCTAssertFalse(failed.sleepPersisted)
        let pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.first?.id, pending.wake.id)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
        XCTAssertTrue(complete(value).succeeded)
    }
    func testUnattestedForwardJournalRecoversOrdinaryRecordsWithoutTrust() throws {
        let value = try submitted(night(), attested: false)
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testJournalFailurePreservesDraftAndWritesNoRecords() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing(ObservationCompletionPending.key)).succeeded)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertNil(wakes.load())
        XCTAssertTrue(complete(value).succeeded)
    }
    func testCreationReservationFailureWritesNoObservations() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing(ObservationCreationLedger.key)).succeeded)
        XCTAssertNil(wakes.load()); XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertTrue(complete(value).succeeded)
    }
    func testPublicationFailureKeepsBothRecordsAndDoesNotDismiss() throws {
        let original = try night(verified: true)
        var count = 0
        let writer: (Data, String) -> Bool = { data, key in
            if key == ObservationProvenance.key { count += 1; if count == 3 { return false } }
            self.defaults.set(data, forKey: key); return true
        }
        let value = try submitted(original)
        var submission = RecordingSubmission()
        var dismissed = false
        var failed: NightSleepCompletionResult?
        submission.submit(value, save: { failed = self.complete($0, writer: writer); return failed!.succeeded }, dismiss: { dismissed = true })
        XCTAssertFalse(dismissed); XCTAssertFalse(submission.isSubmitted)
        XCTAssertTrue(failed?.sleepPersisted == true); XCTAssertTrue(failed?.wakePersisted == true)
        XCTAssertFalse(failed?.evidencePublished == true)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, original.id)
    }
    func testAmbiguousNightWriteRetryUsesPersistedReceipt() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords", afterWrite: true)).succeeded)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testIndependentWakeCorrectionBlocksRecoveryAndKeepsSavedNightData() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        let saved = try XCTUnwrap(wakes.load()?.first)
        let corrected = DailyWakeRecord(id: saved.id, day: saved.day, wakeTime: endpoint.addingTimeInterval(120))
        XCTAssertTrue(wakes.save([corrected]))
        XCTAssertEqual(complete(value).state, .wakeConflict)
        XCTAssertNil(recover())
        XCTAssertEqual(wakes.load()?.first?.wakeTime, corrected.wakeTime)
    }
    func testDeletedNightAfterPartialWriteCancelsRecoveryWithoutDeletingWake() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        XCTAssertTrue(sleeps.delete(ids: [value.id]))
        XCTAssertNil(recover()); XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(sleeps.load()?.count, 0)
    }
    func testLaterNightEditAndDeletionInvalidateTrustedLink() throws {
        let value = try submitted(night(verified: true))
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertNotNil(snapshot.wakes.first?.completedNightID)
        let edited = SleepRecord(id: value.id, date: value.date, duration: value.duration + 1, kind: .nightSleep, createdAt: value.createdAt, endDate: endpoint.addingTimeInterval(60))
        XCTAssertTrue(sleeps.save([edited]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertTrue(sleeps.delete(ids: [value.id]))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testCancellationRetiresPartiallyPersistedCompletion() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        XCTAssertTrue(value.nightCompletionIntent?.abandon() == true)
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertNil(recover())
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testHistoricalCompletionKeepsEndpointDayAcrossRestart() throws {
        let value = try submitted(night())
        now = now.addingTimeInterval(7 * 86400)
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertEqual(wakes.load()?.first?.day, calendar.startOfDay(for: endpoint))
        XCTAssertEqual(wakes.load()?.first?.wakeTime, endpoint)
    }
    func testSpringAndAutumnDSTPreserveElapsedSecondsAndLocalWakeDay() throws {
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (month, day, expectedHours) in [(3, 8, 10), (11, 1, 12)] {
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day - 1, hour: 20))!
            // Autumn starts October 31, not November 31.
            let onset = month == 11 ? calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 20))! : start
            endpoint = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 7))!.addingTimeInterval(0.25)
            now = endpoint.addingTimeInterval(3600)
            let original = SleepRecord(date: onset, duration: 0, kind: .nightSleep, isOngoing: true, createdAt: onset)
            XCTAssertTrue(sleeps.save([original])); XCTAssertTrue(wakes.save([]))
            XCTAssertTrue(complete(try submitted(try XCTUnwrap(sleeps.load()?.first))).succeeded)
            XCTAssertEqual(sleeps.load()?.first?.duration, expectedHours * 60)
            XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
            XCTAssertEqual(wakes.load()?.first?.day, calendar.startOfDay(for: endpoint))
        }
    }
    func testTimezoneControlsWakeDayWithoutChangingInstantOrNightOwnership() throws {
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let original = try night()
        XCTAssertTrue(complete(try submitted(original)).succeeded)
        XCTAssertEqual(wakes.load()?.first?.day, calendar.startOfDay(for: endpoint))
        XCTAssertEqual(wakes.load()?.first?.wakeTime, endpoint)
        XCTAssertEqual(sleeps.load()?.first?.date, original.date)
    }
    func testTimelineUsesPersistedCanonicalWakeAndWakeWindowAnchor() throws {
        XCTAssertTrue(complete(try submitted(night())).succeeded)
        let nap = SleepRecord(date: endpoint.addingTimeInterval(7200), duration: 30, createdAt: now)
        XCTAssertTrue(sleeps.save((sleeps.load() ?? []) + [nap]))
        let items = SleepTimelineCalculator(records: sleeps.load() ?? [], wakeRecord: wakes.load()?.first,
            now: endpoint.addingTimeInterval(4 * 3600), calendar: calendar).calculate()
        let wake = try XCTUnwrap(items.first { $0.kind == .wake })
        XCTAssertEqual(wake.time, endpoint); XCTAssertEqual(wake.visualState, .completed)
        XCTAssertEqual(items.first { $0.id == "record:\(nap.id.uuidString)" }?.awakeBeforeMinutes, 120)
    }
}

extension NightSleepCompletionTests {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func enter() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }; used = true; return true
        }
    }
    func testReentrantWakeCorrectionDoesNotCloseNightOrPublishLink() throws {
        let value = try submitted(night(verified: true))
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter(), let wake = self.wakes.load()?.first else { return }
            XCTAssertTrue(self.wakes.save([DailyWakeRecord(id: wake.id, day: wake.day, wakeTime: wake.wakeTime.addingTimeInterval(60))]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, endpoint.addingTimeInterval(60))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testReentrantNightRevisionChangeCannotInheritAttestation() throws {
        let value = try submitted(night(verified: true))
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter(), let night = self.sleeps.load()?.first else { return }
            let corrected = SleepRecord(id: night.id, date: night.date, duration: night.duration + 1, kind: .nightSleep,
                createdAt: night.createdAt, endDate: self.endpoint.addingTimeInterval(60))
            XCTAssertTrue(self.sleeps.save([corrected]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint.addingTimeInterval(60))
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testReentrantUnrelatedInsertIsPreservedByNightWrite() throws {
        let value = try submitted(night())
        let extra = SleepRecord(date: value.date.addingTimeInterval(-7200), duration: 20, createdAt: value.date)
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter() else { return }
            XCTAssertTrue(self.sleeps.save((self.sleeps.load() ?? []) + [extra]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertEqual(sleeps.load()?.count, 2)
        XCTAssertTrue(sleeps.load()?.contains { $0.id == extra.id } == true)
    }
    func testReentrantWakeRevisionEditRevertBlocksInheritedLinkage() throws {
        let value = try submitted(night(verified: true))
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter(), let wake = self.wakes.load()?.first else { return }
            XCTAssertTrue(self.wakes.save([DailyWakeRecord(id: wake.id, day: wake.day, wakeTime: wake.wakeTime.addingTimeInterval(60))]))
            XCTAssertTrue(self.wakes.save([wake]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }
    func testNotificationsReloadBothCanonicalArrays() throws {
        let value = try submitted(night())
        let sleepChanged = expectation(description: "sleep records reloaded")
        let wakeChanged = expectation(description: "wake records reloaded")
        let sleepObserver = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            XCTAssertEqual(self.sleeps.load()?.first?.endDate, self.endpoint)
            sleepChanged.fulfill()
        }
        let wakeObserver = NotificationCenter.default.addObserver(forName: .dailyWakeRecordsDidChange, object: nil, queue: nil) { _ in
            XCTAssertEqual(self.wakes.load()?.first?.wakeTime, self.endpoint)
            wakeChanged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(sleepObserver); NotificationCenter.default.removeObserver(wakeObserver) }
        XCTAssertTrue(complete(value).succeeded)
        wait(for: [sleepChanged, wakeChanged], timeout: 1)
    }
}

extension NightSleepCompletionTests {
    func testRetryAfterTimezoneChangeUsesOriginalJournalCalendarAndIdentity() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        let journal = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertTrue(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.first?.day, journal.wake.day)
        XCTAssertEqual(wakes.load()?.first?.id, journal.wake.id)
        XCTAssertTrue(complete(value).succeeded)
    }
    func testReopenedEditorResumesOriginalJournalWithoutMintingNewAttestation() throws {
        let original = try night()
        let first = try submitted(original)
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let journal = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        let reopened = try submitted(try XCTUnwrap(sleeps.load()?.first), attested: false)
        XCTAssertTrue(complete(reopened).succeeded)
        XCTAssertEqual(wakes.load()?.first?.id, journal.wake.id)
        // Recovery retains the first submission's actual capture, not the new prefill.
        XCTAssertEqual(snapshot.wakes.first?.source, .verifiedObservation)
        XCTAssertEqual(snapshot.sleeps.first?.source, .recordedUnverified)
    }
    func testJournalReceiptUpdateFailurePreventsRecordWriteAndRetriesSafely() throws {
        let value = try submitted(night())
        var journals = 0
        let writer: (Data, String) -> Bool = { data, key in
            if key == ObservationCompletionPending.key { journals += 1; if journals == 2 { return false } }
            self.defaults.set(data, forKey: key); return true
        }
        XCTAssertFalse(complete(value, writer: writer).succeeded)
        XCTAssertNil(wakes.load()); XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertTrue(complete(value).succeeded)
    }
    func testAdditionalWakeDuringNightNotificationBlocksTrustedPublication() throws {
        let value = try submitted(night(verified: true))
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter() else { return }
            let extra = DailyWakeRecord(day: self.calendar.startOfDay(for: self.endpoint), wakeTime: self.endpoint.addingTimeInterval(60))
            XCTAssertTrue(self.wakes.save((self.wakes.load() ?? []) + [extra]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let failed = complete(value)
        XCTAssertFalse(failed.succeeded); XCTAssertTrue(failed.sleepPersisted); XCTAssertTrue(failed.wakePersisted)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        XCTAssertNil(recover())
        XCTAssertEqual(wakes.load()?.count, 2)
    }
    func testNightWriteThenWakeDeletionKeepsNightButCannotPublishOrResurrectWake() throws {
        let value = try submitted(night(verified: true))
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            guard once.enter() else { return }
            XCTAssertTrue(self.wakes.save([]))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let failed = complete(value)
        XCTAssertFalse(failed.succeeded); XCTAssertTrue(failed.sleepPersisted); XCTAssertFalse(failed.wakePersisted)
        XCTAssertNil(recover()); XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.count, 0)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
    }
    func testUnreadableRecordArraysAreNeverReplacedByCompletion() throws {
        let value = try submitted(night())
        let broken = Data("unreadable".utf8)
        defaults.set(broken, forKey: "dailyWakeRecords_v1")
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), broken)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        defaults.removeObject(forKey: "dailyWakeRecords_v1")
        defaults.set(broken, forKey: "sleepRecords")
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), broken)
        XCTAssertNil(wakes.load())
    }
}

extension NightSleepCompletionTests {
    func testMalformedForwardJournalDiscriminatorFailsClosedWithoutLosingRecords() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        var pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        pending.nightCompletionInput = "unsupported-input"
        XCTAssertTrue(wakes.storage.journal(pending))
        XCTAssertNil(recover())
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertTrue(sleeps.load()?.first?.isOngoing == true)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
}

extension NightSleepCompletionTests {
    func testRestartAfterPublicationBeforeJournalCleanupIsIdempotent() throws {
        let value = try submitted(night(verified: true))
        var lastJournal: Data?
        let writer: (Data, String) -> Bool = { data, key in
            if key == ObservationCompletionPending.key { lastJournal = data }
            self.defaults.set(data, forKey: key); return true
        }
        XCTAssertTrue(complete(value, writer: writer).succeeded)
        let wake = try XCTUnwrap(wakes.load()?.first)
        // Model a process interruption after final metadata publication but before
        // journal removal, using the exact durable journal emitted by production.
        defaults.set(try XCTUnwrap(lastJournal), forKey: ObservationCompletionPending.key)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(wakes.load()?.first?.id, wake.id)
        XCTAssertEqual(snapshot.wakes.first?.completedNightID, value.id)
        XCTAssertTrue(complete(value).succeeded)
    }
}

extension NightSleepCompletionTests {
    private enum FinalWakeMutation { case insert, correct, delete, editRevert }
    private func checkFinalPublicationMutation(_ mutation: FinalWakeMutation, reverse: Bool) throws {
        endpoint = calendar.date(bySettingHour: 6, minute: 42, second: 0, of: endpoint)!
        let original = try night(verified: true)
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .observationProvenanceDidChange, object: nil, queue: nil) { _ in
            guard ObservationProvenance.load(self.defaults)?.links.values.contains(where: { $0.nightID == original.id }) == true,
                  once.enter(), let wake = self.wakes.load()?.first else { return }
            switch mutation {
            case .insert:
                XCTAssertTrue(self.wakes.save([wake, DailyWakeRecord(day: wake.day, wakeTime: wake.wakeTime.addingTimeInterval(60))]))
            case .correct, .editRevert:
                XCTAssertTrue(self.wakes.save([DailyWakeRecord(id: wake.id, day: wake.day, wakeTime: wake.wakeTime.addingTimeInterval(60))]))
                if mutation == .editRevert { XCTAssertTrue(self.wakes.save([wake])) }
            case .delete: XCTAssertTrue(self.wakes.save([]))
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        if reverse {
            var draft = WakeObservationDraft(initial: endpoint.addingTimeInterval(-3600), nightRecords: sleeps.load())
            draft.selected = endpoint
            var capture: WakeObservationCapture?
            XCTAssertTrue(draft.submit { _, value in capture = value; return true })
            let result = SleepWakeTimeWorkflow(selectedWakeTime: endpoint, now: now, calendar: calendar,
                wakeRecords: [], sleepRecords: [], wakePersistence: wakes, sleepPersistence: sleeps, capture: capture).execute()
            XCTAssertFalse(result.evidencePublicationSucceeded)
        } else {
            let result = complete(try submitted(original))
            XCTAssertFalse(result.succeeded)
            XCTAssertFalse(result.evidencePublished)
            XCTAssertTrue(result.sleepPersisted)
        }
        XCTAssertEqual(sleeps.load()?.first?.id, original.id)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
        XCTAssertEqual(wakes.load()?.count, mutation == .insert ? 2 : (mutation == .delete ? 0 : 1))
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
        XCTAssertTrue(snapshot.wakes.allSatisfy { $0.completedNightID == nil })
        if mutation == .insert {
            let pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
            XCTAssertFalse(pending.canResume(defaults: defaults, now: now))
            XCTAssertNotNil(pending.expectedWake); XCTAssertNotNil(pending.expectedNight)
        } else {
            XCTAssertNil(ObservationCompletionPending.load(defaults))
        }
    }
    func testFindingOneForwardFinalPublicationInsertionFailsClosed() throws {
        try checkFinalPublicationMutation(.insert, reverse: false)
    }
    func testFindingOneReverseFinalPublicationInsertionFailsClosed() throws {
        try checkFinalPublicationMutation(.insert, reverse: true)
    }
    func testFindingOneForwardFinalPublicationCorrectionPreservesObservation() throws {
        try checkFinalPublicationMutation(.correct, reverse: false)
    }
    func testFindingOneReverseFinalPublicationCorrectionPreservesObservation() throws {
        try checkFinalPublicationMutation(.correct, reverse: true)
    }
    func testFindingOneForwardFinalPublicationDeletionPreventsReplay() throws {
        try checkFinalPublicationMutation(.delete, reverse: false)
    }
    func testFindingOneReverseFinalPublicationDeletionPreventsReplay() throws {
        try checkFinalPublicationMutation(.delete, reverse: true)
    }
    func testFindingOneFinalPublicationEditRevertCannotInheritReceipt() throws {
        try checkFinalPublicationMutation(.editRevert, reverse: false)
    }
    func testFindingTwoInvalidForwardJournalRestartDoesNotBlockOtherNight() throws {
        let original = try night()
        let value = try submitted(original)
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        var broken = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        broken.nightCompletionInput = "invalid-input"
        XCTAssertTrue(wakes.storage.journal(broken))
        XCTAssertNil(recover())
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertNotNil(defaults.data(forKey: "nightWakeCompletionRecovery_v1"))
        var reopened = SleepRecordingDraft(defaultDate: original.date, editing: try XCTUnwrap(sleeps.load()?.first), now: now)
        reopened.prepareForEnding(at: now)
        XCTAssertTrue(reopened.abandon())
        XCTAssertEqual(wakes.load()?.first?.id, broken.wake.id)
        XCTAssertEqual(sleeps.load()?.first?.id, original.id)
        XCTAssertTrue(snapshot.wakes.allSatisfy { $0.completedNightID == nil })
        let other = SleepRecord(date: original.date.addingTimeInterval(86400), duration: 0, kind: .nightSleep,
            isOngoing: true, createdAt: original.createdAt.addingTimeInterval(86400))
        XCTAssertTrue(sleeps.save((sleeps.load() ?? []) + [other]))
        endpoint = endpoint.addingTimeInterval(86400); now = now.addingTimeInterval(86400)
        let selected = try XCTUnwrap(sleeps.load()?.first { $0.id == other.id })
        XCTAssertTrue(complete(try submitted(selected)).succeeded)
        XCTAssertEqual(wakes.load()?.count, 2)
        XCTAssertTrue(sleeps.load()?.first { $0.id == original.id }?.isOngoing == true)
        XCTAssertEqual(wakes.load()?.first { $0.id == broken.wake.id }?.wakeTime, broken.wake.wakeTime)
        XCTAssertFalse(complete(value).succeeded)
    }
    func testFindingFourAdoptedRecoveryReplayAcknowledgesWithoutWrites() throws {
        let first = try submitted(night())
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let originalOperation = try XCTUnwrap(ObservationCompletionPending.load(defaults)?.operationID)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reopened = try submitted(try XCTUnwrap(SleepRecordPersistence(defaults: reloaded).load()?.first), attested: false)
        XCTAssertNotEqual(reopened.nightCompletionIntent?.operationID, originalOperation)
        XCTAssertTrue(complete(reopened).succeeded)
        let before = Dictionary(uniqueKeysWithValues: ["sleepRecords", "dailyWakeRecords_v1", ObservationProvenance.key, ObservationCreationLedger.key].map { ($0, defaults.data(forKey: $0)) })
        var writes = 0
        let result = complete(reopened, writer: { _, _ in writes += 1; return false })
        XCTAssertTrue(result.succeeded); XCTAssertTrue(result.sleepPersisted); XCTAssertTrue(result.wakePersisted)
        XCTAssertEqual(writes, 0)
        for (key, data) in before { XCTAssertEqual(defaults.data(forKey: key), data) }
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
    }
}

extension NightSleepCompletionTests {
    private func invalidForwardJournal() throws -> ObservationCompletionPending {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        var pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        pending.nightCompletionInput = "invalid-input"
        XCTAssertTrue(wakes.storage.journal(pending))
        return pending
    }
    private func checkRetirementFailure(_ key: String) throws {
        let pending = try invalidForwardJournal()
        let original = try XCTUnwrap(sleeps.load()?.first)
        let reopened = try submitted(original, attested: false)
        let sleepData = defaults.data(forKey: "sleepRecords")
        let wakeData = defaults.data(forKey: "dailyWakeRecords_v1")
        let result = complete(reopened, writer: failing(key))
        XCTAssertEqual(result.state, .recoveryFailure)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), sleepData)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakeData)
        let retained = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(retained.operationID, pending.operationID)
        XCTAssertFalse(retained.canResume(defaults: defaults, now: now))
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
        let retry = complete(reopened)
        XCTAssertEqual(retry.state, .staleNight) // Retirement repaired an abandoned prepared revision.
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        let refreshed = try submitted(try XCTUnwrap(sleeps.load()?.first), attested: false)
        XCTAssertTrue(complete(refreshed).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(wakes.load()?.first?.id, pending.wake.id)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(snapshot.wakes.first?.source, .recordedUnverified)
    }
    func testFindingTwoQuarantineFailureKeepsJournalAndObservationsUntilRetry() throws {
        try checkRetirementFailure("nightWakeCompletionRecovery_v1")
    }
    func testFindingTwoCancellationWriteFailureKeepsJournalUntilRetry() throws {
        try checkRetirementFailure(ObservationCompletionPending.key)
    }
    func testFindingTwoRetirementLedgerFailureKeepsCancelledJournalUntilRetry() throws {
        try checkRetirementFailure(ObservationCreationLedger.key)
    }
    func testFindingTwoValidJournalSurvivesUnrelatedEditorCancellation() throws {
        let original = try night()
        let other = SleepRecord(date: original.date.addingTimeInterval(-86400), duration: 0, kind: .nightSleep,
            isOngoing: true, createdAt: original.createdAt.addingTimeInterval(-86400))
        XCTAssertTrue(sleeps.save((sleeps.load() ?? []) + [other]))
        let first = try submitted(try XCTUnwrap(sleeps.load()?.first { $0.id == original.id }))
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let pending = try XCTUnwrap(defaults.data(forKey: ObservationCompletionPending.key))
        let selected = try XCTUnwrap(sleeps.load()?.first { $0.id == other.id })
        var draft = SleepRecordingDraft(defaultDate: selected.date, editing: selected, now: now)
        draft.prepareForEnding(at: now)
        draft.end = endpoint.addingTimeInterval(-86400)
        var submission = RecordingSubmission()
        var result: NightSleepCompletionResult?
        submission.submit(draft: draft, kind: .nightSleep, editing: selected, now: now,
            save: { result = self.complete($0); return result!.succeeded }, dismiss: {})
        XCTAssertEqual(result?.state, .recoveryPending)
        XCTAssertTrue(draft.abandon())
        XCTAssertEqual(defaults.data(forKey: ObservationCompletionPending.key), pending)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
        XCTAssertTrue(sleeps.load()?.first { $0.id == other.id }?.isOngoing == true)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testFindingTwoClockRollbackDoesNotRetireLegitimateForwardJournal() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        let pending = defaults.data(forKey: ObservationCompletionPending.key)
        XCTAssertTrue(wakes.storage.retireInvalidForwardCompletion(now: endpoint.addingTimeInterval(-60)))
        XCTAssertEqual(defaults.data(forKey: ObservationCompletionPending.key), pending)
        XCTAssertTrue(recover()?.evidencePublicationSucceeded == true)
    }
    func testFindingTwoRetiredLiveFormCannotRebuildItsInvalidJournal() throws {
        let value = try submitted(night())
        XCTAssertFalse(complete(value, writer: failing("sleepRecords")).succeeded)
        var pending = try XCTUnwrap(ObservationCompletionPending.load(defaults))
        pending.nightCompletionInput = "invalid-input"
        XCTAssertTrue(wakes.storage.journal(pending))
        XCTAssertNil(recover())
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertTrue(value.nightCompletionIntent?.isRetired == true)
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testFindingThreeStillSleepingUsesProductionDispatchAndConfirmationWithoutWake() throws {
        let original = try night()
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: now)
        draft.isOngoing = true
        let confirmation = expectation(description: "Still Sleeping confirmation")
        let observer = NotificationCenter.default.addObserver(forName: .sleepStillSleepingConfirmed, object: nil, queue: nil) { event in
            XCTAssertEqual(event.object as? UUID, original.id)
            XCTAssertEqual(event.userInfo?["confirmedAt"] as? Date, self.now)
            confirmation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var submission = RecordingSubmission()
        var dismissed = false
        var completions = 0
        submission.submit(draft: draft, kind: .nightSleep, editing: original, now: now, save: { record in
            RecordingSubmission.saveHomeRecord(record, now: self.now,
                onSave: { self.sleeps.saveRecording($0, now: self.now) },
                onNightCompletion: { completions += 1; return self.complete($0) }).succeeded
        }, dismiss: { dismissed = true })
        wait(for: [confirmation], timeout: 1)
        XCTAssertTrue(dismissed); XCTAssertTrue(submission.isSubmitted); XCTAssertEqual(completions, 0)
        let saved = try XCTUnwrap(sleeps.load()?.first)
        XCTAssertEqual(saved.id, original.id); XCTAssertEqual(saved.date, original.date)
        XCTAssertTrue(saved.isOngoing); XCTAssertNil(saved.endDate)
        XCTAssertEqual(saved.persistedRevision, original.persistedRevision)
        XCTAssertNil(wakes.load()); XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertTrue(ObservationProvenance.load(defaults)?.links.isEmpty == true)
    }
    func testFindingThreeActualEndStillUsesCompletionDispatch() throws {
        let value = try submitted(night())
        let result = RecordingSubmission.saveHomeRecord(value, now: now,
            onSave: { _ in XCTFail("Completed night bypassed its completion command"); return false },
            onNightCompletion: { self.complete($0) })
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, endpoint)
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
    }
    private func adoptedCompletion() throws -> SleepRecord {
        let first = try submitted(night())
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reopened = try submitted(try XCTUnwrap(SleepRecordPersistence(defaults: reloaded).load()?.first), attested: false)
        XCTAssertTrue(complete(reopened).succeeded)
        return reopened
    }
    func testFindingFourIndependentWakeCorrectionRejectsAdoptedAcknowledgement() throws {
        let value = try adoptedCompletion()
        let wake = try XCTUnwrap(wakes.load()?.first)
        let corrected = DailyWakeRecord(id: wake.id, day: wake.day, wakeTime: endpoint.addingTimeInterval(60))
        XCTAssertTrue(wakes.save([corrected]))
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.first?.wakeTime, corrected.wakeTime)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testFindingFourEditRevertRejectsAdoptedAcknowledgement() throws {
        let value = try adoptedCompletion()
        let wake = try XCTUnwrap(wakes.load()?.first)
        XCTAssertTrue(wakes.save([DailyWakeRecord(id: wake.id, day: wake.day, wakeTime: endpoint.addingTimeInterval(60))]))
        XCTAssertTrue(wakes.save([wake]))
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertNotEqual(wakes.load()?.first?.persistedRevision, wake.persistedRevision)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
    }
    func testFindingFourDeletedWakeCannotBeRecreatedByAdoptedAcknowledgement() throws {
        let value = try adoptedCompletion()
        XCTAssertTrue(wakes.save([]))
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(wakes.load()?.count, 0)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
    }
    func testFindingFourDeletedNightCannotBeRecreatedByAdoptedAcknowledgement() throws {
        let value = try adoptedCompletion()
        XCTAssertTrue(sleeps.delete(ids: [value.id]))
        XCTAssertFalse(complete(value).succeeded)
        XCTAssertEqual(sleeps.load()?.count, 0)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testFindingFourUnrelatedIntentCannotClaimAdoptedOperation() throws {
        let original = try night()
        let first = try submitted(original)
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let reopened = try submitted(try XCTUnwrap(sleeps.load()?.first), attested: false)
        let unrelated = try submitted(try XCTUnwrap(sleeps.load()?.first), attested: false)
        XCTAssertTrue(complete(reopened).succeeded)
        XCTAssertFalse(complete(unrelated).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
    func testFindingFourAdditionalWakeRejectsAdoptedAcknowledgement() throws {
        let value = try adoptedCompletion()
        let extra = DailyWakeRecord(day: calendar.startOfDay(for: endpoint), wakeTime: endpoint.addingTimeInterval(60))
        XCTAssertTrue(wakes.save((wakes.load() ?? []) + [extra]))
        XCTAssertEqual(complete(value).state, .ambiguousWakes)
        XCTAssertEqual(wakes.load()?.count, 2)
        XCTAssertTrue(snapshot.wakes.allSatisfy { $0.completedNightID == nil })
    }
}

extension NightSleepCompletionTests {
    func testFindingTwoMalformedAndUnsupportedJournalsUseExistingQuarantine() throws {
        for raw in [Data("malformed".utf8), Data("{\"version\":999}".utf8)] {
            let original = try night()
            let selected = try submitted(original)
            defaults.set(raw, forKey: ObservationCompletionPending.key)
            XCTAssertTrue(complete(selected).succeeded)
            XCTAssertNil(ObservationCompletionPending.load(defaults))
            XCTAssertNotNil(defaults.data(forKey: "nightWakeCompletionRecovery_v1"))
            XCTAssertEqual(sleeps.load()?.first?.id, original.id)
            XCTAssertEqual(wakes.load()?.count, 1)
            XCTAssertTrue(wakes.save([]))
        }
    }
    func testFindingFourChangedEndpointCannotReuseAdoptedAcknowledgement() throws {
        let first = try submitted(night())
        XCTAssertFalse(complete(first, writer: failing("sleepRecords")).succeeded)
        let selected = try XCTUnwrap(sleeps.load()?.first)
        var draft = SleepRecordingDraft(defaultDate: selected.date, editing: selected, now: now)
        draft.prepareForEnding(at: now); draft.end = endpoint
        var originalSubmission = RecordingSubmission()
        originalSubmission.submit(draft: draft, kind: .nightSleep, editing: selected, now: now,
            save: { self.complete($0).succeeded }, dismiss: {})
        XCTAssertTrue(originalSubmission.isSubmitted)
        let sleepData = defaults.data(forKey: "sleepRecords")
        let wakeData = defaults.data(forKey: "dailyWakeRecords_v1")
        let metadata = defaults.data(forKey: ObservationProvenance.key)
        draft.end = endpoint.addingTimeInterval(60)
        var correction = RecordingSubmission()
        correction.submit(draft: draft, kind: .nightSleep, editing: selected, now: now,
            save: { self.complete($0).succeeded }, dismiss: { XCTFail("Changed endpoint incorrectly acknowledged") })
        XCTAssertFalse(correction.isSubmitted)
        XCTAssertEqual(defaults.data(forKey: "sleepRecords"), sleepData)
        XCTAssertEqual(defaults.data(forKey: "dailyWakeRecords_v1"), wakeData)
        XCTAssertEqual(defaults.data(forKey: ObservationProvenance.key), metadata)
        XCTAssertEqual(wakes.load()?.count, 1)
    }
}

extension NightSleepCompletionTests {
    func testFindingThreeStillSleepingAfterPartialCompletionRetiresAndAllowsReopening() throws {
        let original = try night()
        var draft = SleepRecordingDraft(defaultDate: original.date, editing: original, now: now)
        draft.prepareForEnding(at: now); draft.end = endpoint
        var failed = RecordingSubmission()
        failed.submit(draft: draft, kind: .nightSleep, editing: original, now: now,
            save: { self.complete($0, writer: self.failing("sleepRecords")).succeeded }, dismiss: {})
        XCTAssertFalse(failed.isSubmitted)
        let wake = try XCTUnwrap(wakes.load()?.first)
        draft.isOngoing = true
        var confirmed = RecordingSubmission()
        confirmed.submit(draft: draft, kind: .nightSleep, editing: original, now: now, save: { record in
            RecordingSubmission.saveHomeRecord(record, now: self.now,
                onSave: { self.sleeps.saveRecording($0, now: self.now) },
                onNightCompletion: { _ in XCTFail("Still Sleeping entered completion"); return self.complete(record) }).succeeded
        }, dismiss: {})
        XCTAssertTrue(confirmed.isSubmitted)
        let refreshed = expectation(description: "Retired prepared revision refresh")
        let observer = NotificationCenter.default.addObserver(forName: .sleepRecordsDidChange, object: nil, queue: nil) { _ in
            XCTAssertTrue(self.sleeps.load()?.first?.isOngoing == true)
            XCTAssertNotNil(self.sleeps.load()?.first?.persistedRevision)
            refreshed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(draft.abandon())
        wait(for: [refreshed], timeout: 1)
        XCTAssertNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(wakes.load()?.count, 1); XCTAssertEqual(wakes.load()?.first?.id, wake.id)
        XCTAssertNil(snapshot.wakes.first?.completedNightID)
        NotificationCenter.default.removeObserver(observer)
        let selected = try XCTUnwrap(sleeps.load()?.first)
        XCTAssertTrue(complete(try submitted(selected)).succeeded)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertEqual(wakes.load()?.first?.id, wake.id)
    }
}

extension NightSleepCompletionTests {
    func testFindingOneFinalPublicationReceiptRevocationCannotReportAcknowledgement() throws {
        let original = try night(verified: true)
        let once = Once()
        let observer = NotificationCenter.default.addObserver(forName: .observationProvenanceDidChange, object: nil, queue: nil) { _ in
            guard var metadata = ObservationProvenance.load(self.defaults),
                  let wakeID = metadata.links.values.first(where: { $0.nightID == original.id })?.wakeID,
                  once.enter() else { return }
            metadata.sleeps[original.id.uuidString]?.completedOperationID = nil
            metadata.wakes[wakeID.uuidString]?.completedOperationID = nil
            XCTAssertTrue(self.wakes.storage.metadata(metadata))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result = complete(try submitted(original))
        XCTAssertFalse(result.succeeded); XCTAssertFalse(result.evidencePublished)
        XCTAssertTrue(result.sleepPersisted); XCTAssertTrue(result.wakePersisted)
        XCTAssertNotNil(ObservationCompletionPending.load(defaults))
        XCTAssertEqual(sleeps.load()?.first?.endDate, endpoint)
        XCTAssertEqual(wakes.load()?.count, 1)
        XCTAssertNil(ObservationProvenance.load(defaults)?.sleeps[original.id.uuidString]?.completedOperationID)
    }
}
