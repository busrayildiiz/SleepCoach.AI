import XCTest
@testable import BabySleepTracker

final class RecordingIntervalPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { start.addingTimeInterval(10 * 3600) }

    private func awake(_ parent: SleepRecord, offset: Int, minutes: Int) -> SleepRecord {
        SleepRecord(date: parent.date.addingTimeInterval(Double(offset) * 60), duration: minutes,
                    kind: .break, parentNapID: parent.id)
    }

    func testExistingAndProposedAwakeHaveDistinctGeometryAndAccountingNet() throws {
        let parent = SleepRecord(date: start, duration: 480, kind: .nightSleep)
        let existing = [awake(parent, offset: 30, minutes: 10), awake(parent, offset: 120, minutes: 20)]
        let proposed = awake(parent, offset: 300, minutes: 5)
        let result = try XCTUnwrap(RecordingIntervalPresentation(parent: parent, existing: existing,
                                                                 proposed: proposed, now: now))
        XCTAssertEqual(result.netMinutes, 445)
        XCTAssertTrue(result.segments.contains { $0.kind == .awake })
        XCTAssertTrue(result.segments.contains { $0.kind == .proposedAwake })
        XCTAssertEqual(result.segments.first?.startFraction, 0)
        XCTAssertEqual(result.segments.last?.endFraction, 1)
        XCTAssertEqual(result.segments.reduce(0) { $0 + $1.endFraction - $1.startFraction }, 1, accuracy: 0.000001)
    }

    func testOverlappingLegacyAwakeIntervalsUseTheExistingUnionRule() throws {
        let parent = SleepRecord(date: start, duration: 60)
        let existing = [awake(parent, offset: 10, minutes: 20), awake(parent, offset: 20, minutes: 20)]
        let result = try XCTUnwrap(RecordingIntervalPresentation(parent: parent, existing: existing,
                                                                 proposed: nil, now: now))
        XCTAssertEqual(result.netMinutes, 30)
        let awakeFraction = result.segments.filter { $0.kind == .awake }
            .reduce(0) { $0 + $1.endFraction - $1.startFraction }
        XCTAssertEqual(awakeFraction, 0.5, accuracy: 0.000001)
    }

    func testMidnightCrossingUsesElapsedSessionTimeRatherThanClockModulo() throws {
        let midnight = ISO8601DateFormatter().date(from: "2023-11-15T00:00:00Z")!
        let parent = SleepRecord(date: midnight.addingTimeInterval(-3600), duration: 480, kind: .nightSleep)
        let proposed = awake(parent, offset: 90, minutes: 15)
        let result = try XCTUnwrap(RecordingIntervalPresentation(parent: parent, existing: [], proposed: proposed,
                                                                 now: midnight.addingTimeInterval(8 * 3600)))
        let selected = try XCTUnwrap(result.segments.first { $0.kind == .proposedAwake })
        XCTAssertEqual(selected.startFraction, 90.0 / 480, accuracy: 0.000001)
        XCTAssertEqual(selected.endFraction, 105.0 / 480, accuracy: 0.000001)
        XCTAssertEqual(result.netMinutes, 465)
    }

    func testOngoingUnknownEndAndFutureEndCannotBeRenderedAsCompletedSessions() {
        let ongoing = SleepRecord(date: start, duration: 0, kind: .nightSleep, isOngoing: true)
        let unknown = SleepRecord(date: start, duration: 0)
        let future = SleepRecord(date: start, duration: 24 * 60)
        for parent in [ongoing, unknown, future] {
            XCTAssertNil(RecordingIntervalPresentation(parent: parent, existing: [], proposed: nil, now: now))
        }
    }

    func testEditingBreakReplacesItsStoredGeometryWithoutDoubleCounting() throws {
        let parent = SleepRecord(date: start, duration: 60)
        let original = awake(parent, offset: 10, minutes: 20)
        let proposed = awake(parent, offset: 15, minutes: 5)
        let result = try XCTUnwrap(RecordingIntervalPresentation(parent: parent, existing: [original], proposed: proposed,
                                                                 editingID: original.id, now: now))
        XCTAssertEqual(result.netMinutes, 55)
        XCTAssertFalse(result.segments.contains { $0.kind == .awake })
    }

    func testForeignBreaksAreIgnoredAndLegacyBoundsAreClipped() throws {
        let parent = SleepRecord(date: start, duration: 60)
        let other = SleepRecord(date: start, duration: 60)
        let existing = [awake(parent, offset: -10, minutes: 20), awake(other, offset: 20, minutes: 10)]
        let result = try XCTUnwrap(RecordingIntervalPresentation(parent: parent, existing: existing,
                                                                 proposed: nil, now: now))
        XCTAssertEqual(result.netMinutes, 50)
        XCTAssertTrue(result.segments.allSatisfy { $0.startFraction >= 0 && $0.endFraction <= 1 })
    }
}
