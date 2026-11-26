import XCTest
@testable import BabySleepTracker

final class DayDetailPresentationTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_795_392_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date { day.addingTimeInterval(14 * 3600) }

    private func morning(id: UUID = UUID(), offset: TimeInterval = 7 * 3600) -> DailyWakeRecord {
        DailyWakeRecord(id: id, day: day, wakeTime: day.addingTimeInterval(offset))
    }

    private func nap(id: UUID = UUID(), offset: TimeInterval = 9 * 3600) -> SleepRecord {
        let start = day.addingTimeInterval(offset)
        return SleepRecord(id: id, date: start, duration: 45, createdAt: start, endDate: start.addingTimeInterval(45 * 60))
    }

    func testWakeTimeAndVerificationComeFromTheSameSnapshot() {
        let wake = morning()
        let corrected = morning(id: wake.id, offset: 7 * 3600 + 15 * 60)
        let observed = DayDetailObservationProjection(snapshot: .init(sleeps: [],
            wakes: [.init(record: wake, source: .verifiedObservation)]))
        XCTAssertEqual(observed.wake(on: day, at: now, calendar: calendar), .recorded(wake.wakeTime, verified: true))

        let refreshed = DayDetailObservationProjection(snapshot: .init(sleeps: [],
            wakes: [.init(record: corrected, source: .recordedUnverified)]))
        XCTAssertEqual(refreshed.wake(on: day, at: now, calendar: calendar), .recorded(corrected.wakeTime, verified: false))
    }

    func testUnreadableSnapshotCannotVerifyWakesOrSleep() {
        let wake = morning()
        let sleep = nap()
        let projection = DayDetailObservationProjection(snapshot: .init(
            sleeps: [.init(record: sleep, source: .verifiedObservation)],
            wakes: [.init(record: wake, source: .verifiedObservation)], storageIsReadable: false))
        XCTAssertEqual(projection.wake(on: day, at: now, calendar: calendar), .unavailable)
        XCTAssertFalse(projection.isVerified(sleep))
    }

    func testDuplicateAndCollidingWakeIdentitiesNeverShowVerification() {
        let wake = morning()
        let verified = LearningWakeEvidence(record: wake, source: .verifiedObservation)
        let otherDay = day.addingTimeInterval(-86_400)
        let duplicateID = DailyWakeRecord(id: wake.id, day: otherDay, wakeTime: otherDay.addingTimeInterval(7 * 3600))
        for snapshot in [
            LearningEvidenceSnapshot(sleeps: [], wakes: [verified, .init(record: morning())]),
            LearningEvidenceSnapshot(sleeps: [], wakes: [verified, .init(record: duplicateID)]),
            LearningEvidenceSnapshot(sleeps: [.init(record: nap(id: wake.id))], wakes: [verified])
        ] {
            XCTAssertEqual(DayDetailObservationProjection(snapshot: snapshot).wake(on: day, at: now, calendar: calendar),
                           .ambiguous)
        }
    }

    func testFutureAndWrongDateWakesAreNotShownAsCurrentObservations() {
        for wake in [morning(offset: 16 * 3600), morning(offset: -3600)] {
            let projection = DayDetailObservationProjection(snapshot: .init(sleeps: [],
                wakes: [.init(record: wake, source: .verifiedObservation)]))
            XCTAssertEqual(projection.wake(on: day, at: now, calendar: calendar), .missing)
        }
    }

    func testSleepBadgeRequiresCurrentContentRevisionAndSource() {
        var observed = nap()
        observed.persistedRevision = UUID()
        let other = nap(offset: 12 * 3600)
        let wake = morning()
        let projection = DayDetailObservationProjection(snapshot: .init(
            sleeps: [.init(record: observed, source: .verifiedObservation), .init(record: other, source: .recordedUnverified)],
            wakes: [.init(record: wake, source: .recordedUnverified)]))
        XCTAssertTrue(projection.isVerified(observed))
        XCTAssertFalse(projection.isVerified(other))
        XCTAssertEqual(projection.wake(on: day, at: now, calendar: calendar), .recorded(wake.wakeTime, verified: false))

        var changed = nap(id: observed.id, offset: 9 * 3600 + 60)
        changed.persistedRevision = observed.persistedRevision
        XCTAssertFalse(projection.isVerified(changed))
        var stale = observed
        stale.persistedRevision = UUID()
        XCTAssertFalse(projection.isVerified(stale))

        let revoked = DayDetailObservationProjection(snapshot: .init(
            sleeps: [.init(record: observed, source: .recordedUnverified)], wakes: []))
        XCTAssertFalse(revoked.isVerified(observed))
        let duplicate = DayDetailObservationProjection(snapshot: .init(
            sleeps: [.init(record: observed, source: .verifiedObservation), .init(record: changed)], wakes: []))
        XCTAssertFalse(duplicate.isVerified(observed))
    }
}
