
import XCTest
@testable import BabySleepTracker

final class SegmentKindTests: XCTestCase {

    // MARK: - SegmentKind

    func testSegmentKindHasExpectedRawValues() {
        XCTAssertEqual(SegmentKind.sleep.rawValue, "sleep")
        XCTAssertEqual(SegmentKind.break.rawValue, "break")
    }

    func testSegmentKindCanBeEncodedAndDecoded() throws {
        let original: SegmentKind = .break

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            SegmentKind.self,
            from: data
        )

        XCTAssertEqual(decoded, original)
    }

    // MARK: - SleepSegment

    func testSleepSegmentStoresProvidedValues() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)

        let segment = SleepSegment(
            id: id,
            kind: .sleep,
            start: start,
            end: end
        )

        XCTAssertEqual(segment.id, id)
        XCTAssertEqual(segment.kind, .sleep)
        XCTAssertEqual(segment.start, start)
        XCTAssertEqual(segment.end, end)
    }

    func testSleepSegmentCanBeEncodedAndDecoded() throws {
        let original = SleepSegment(
            id: UUID(),
            kind: .break,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_600)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            SleepSegment.self,
            from: data
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.start, original.start)
        XCTAssertEqual(decoded.end, original.end)
    }

    // MARK: - SleepSession

    func testTotalSleepMinutesReturnsSleepDurationWhenThereAreNoBreaks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(90 * 60)

        let session = SleepSession(
            id: UUID(),
            kind: .dayNap,
            startDate: start,
            segments: [
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: start,
                    end: end
                )
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 90)
    }

    func testTotalSleepMinutesSubtractsBreakDuration() {
        let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)

        let sleep1Start = sessionStart
        let sleep1End = sessionStart.addingTimeInterval(60 * 60)

        let breakStart = sleep1End
        let breakEnd = breakStart.addingTimeInterval(15 * 60)

        let sleep2Start = breakEnd
        let sleep2End = sleep2Start.addingTimeInterval(45 * 60)

        let session = SleepSession(
            id: UUID(),
            kind: .nightSleep,
            startDate: sessionStart,
            segments: [
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: sleep1Start,
                    end: sleep1End
                ),
                SleepSegment(
                    id: UUID(),
                    kind: .break,
                    start: breakStart,
                    end: breakEnd
                ),
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: sleep2Start,
                    end: sleep2End
                )
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 90)
    }

    func testTotalSleepMinutesSumsMultipleSleepSegments() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let session = SleepSession(
            id: UUID(),
            kind: .dayNap,
            startDate: base,
            segments: [
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: base,
                    end: base.addingTimeInterval(30 * 60)
                ),
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: base.addingTimeInterval(40 * 60),
                    end: base.addingTimeInterval(100 * 60)
                )
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 90)
    }

    func testTotalSleepMinutesIgnoresZeroDurationSegments() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let session = SleepSession(
            id: UUID(),
            kind: .dayNap,
            startDate: base,
            segments: [
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: base,
                    end: base
                ),
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: base,
                    end: base.addingTimeInterval(30 * 60)
                )
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 30)
    }

    func testTotalSleepMinutesTreatsNegativeSegmentDurationAsZero() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let invalidSleepSegment = SleepSegment(
            id: UUID(),
            kind: .sleep,
            start: base.addingTimeInterval(60 * 60),
            end: base
        )

        let validSleepSegment = SleepSegment(
            id: UUID(),
            kind: .sleep,
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )

        let session = SleepSession(
            id: UUID(),
            kind: .dayNap,
            startDate: base,
            segments: [
                invalidSleepSegment,
                validSleepSegment
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 30)
    }

    func testTotalSleepMinutesReturnsZeroWhenBreaksExceedSleep() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let sleepSegment = SleepSegment(
            id: UUID(),
            kind: .sleep,
            start: base,
            end: base.addingTimeInterval(20 * 60)
        )

        let breakSegment = SleepSegment(
            id: UUID(),
            kind: .break,
            start: base.addingTimeInterval(20 * 60),
            end: base.addingTimeInterval(50 * 60)
        )

        let session = SleepSession(
            id: UUID(),
            kind: .dayNap,
            startDate: base,
            segments: [
                sleepSegment,
                breakSegment
            ]
        )

        XCTAssertEqual(session.totalSleepMinutes, 0)
    }

    func testSleepSessionCanBeEncodedAndDecoded() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let original = SleepSession(
            id: UUID(),
            kind: .nightSleep,
            startDate: base,
            segments: [
                SleepSegment(
                    id: UUID(),
                    kind: .sleep,
                    start: base,
                    end: base.addingTimeInterval(60 * 60)
                ),
                SleepSegment(
                    id: UUID(),
                    kind: .break,
                    start: base.addingTimeInterval(60 * 60),
                    end: base.addingTimeInterval(75 * 60)
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            SleepSession.self,
            from: data
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.startDate, original.startDate)
        XCTAssertEqual(decoded.segments.count, original.segments.count)
        XCTAssertEqual(decoded.totalSleepMinutes, original.totalSleepMinutes)
    }
}
