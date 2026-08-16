import XCTest
@testable import BabySleepTracker

final class NapTransitionAgentTests: XCTestCase {

    private var profileProvider: MockTransitionProfileProvider!
    private var agent: DefaultNapTransitionAgent!

    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        return calendar.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: Date()
        )!
    }()

    override func setUp() {
        super.setUp()

        profileProvider = MockTransitionProfileProvider()
        agent = DefaultNapTransitionAgent(
            profileProvider: profileProvider
        )
    }

    override func tearDown() {
        agent = nil
        profileProvider = nil

        super.tearDown()
    }

    // MARK: - Expected Transition

    func testAgeOutsideTransitionRangeReturnsNone() {
        let result = agent.assess(
            records: [],
            wakeRecords: [],
            ageMonths: 10,
            now: now
        )

        XCTAssertEqual(result.transitionType, .none)
        XCTAssertEqual(result.signalStrength, .none)
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertFalse(result.isReadyToTransit)
        XCTAssertEqual(
            result.recommendation,
            "Şu an geçiş beklenen bir dönemde değil."
        )
    }

    func testAgeSixToNineUsesThreeToTwoTransition() {
        let result = agent.assess(
            records: [],
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertEqual(result.transitionType, .threeToTwo)
    }

    func testAgeTwelveToTwentyUsesTwoToOneTransition() {
        let result = agent.assess(
            records: [],
            wakeRecords: [],
            ageMonths: 15,
            now: now
        )

        XCTAssertEqual(result.transitionType, .twoToOne)
    }

    // MARK: - Nap Rejection

    func testThreeRecentShortNapsProduceNapRejectionSignal() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .napRejection
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 3)
        XCTAssertEqual(
            signal?.description,
            "Son 7 günde 3 kez nap reddi görüldü."
        )
    }

    func testFewerThanThreeShortNapsDoNotProduceNapRejectionSignal() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .napRejection
            }
        )
    }

    // MARK: - Delayed First Nap

    func testDelayedFirstNapProducesSignalWhenDelayExceedsThirtyMinutes() {
        var records: [SleepRecord] = []

        // İlk 3 gün: 09:00
        records.append(
            makeNap(daysAgo: 12, hour: 9, minute: 0, duration: 60)
        )
        records.append(
            makeNap(daysAgo: 11, hour: 9, minute: 0, duration: 60)
        )
        records.append(
            makeNap(daysAgo: 10, hour: 9, minute: 0, duration: 60)
        )

        // Son 3 gün: 10:00
        records.append(
            makeNap(daysAgo: 3, hour: 10, minute: 0, duration: 60)
        )
        records.append(
            makeNap(daysAgo: 2, hour: 10, minute: 0, duration: 60)
        )
        records.append(
            makeNap(daysAgo: 1, hour: 10, minute: 0, duration: 60)
        )

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .delayedFirstNap
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 2)
        XCTAssertEqual(
            signal?.description,
            "İlk nap saati son 2 haftada ~60 dk gecikti."
        )
    }

    func testDelayedFirstNapDoesNotTriggerWithInsufficientDays() {
        let records = [
            makeNap(daysAgo: 1, hour: 10, duration: 60),
            makeNap(daysAgo: 2, hour: 10, duration: 60),
            makeNap(daysAgo: 3, hour: 10, duration: 60),
            makeNap(daysAgo: 4, hour: 9, duration: 60),
            makeNap(daysAgo: 5, hour: 9, duration: 60)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .delayedFirstNap
            }
        )
    }

    // MARK: - Shortened Night Sleep

    func testShortenedNightSleepProducesSignal() {
        let records = (1...6).map {
            makeNight(daysAgo: $0, hour: 20, duration: 480)
        }

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .shortenedNightSleep
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 2)
        XCTAssertEqual(
            signal?.description,
            "Gece uykusu hedefin 120 dk altında."
        )
    }

    func testAdequateNightSleepDoesNotProduceShortenedNightSignal() {
        let records = (1...6).map {
            makeNight(daysAgo: $0, hour: 20, duration: 600)
        }

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .shortenedNightSleep
            }
        )
    }

    // MARK: - Excessive Daytime Sleep

    func testExcessiveDaytimeSleepProducesSignal() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 130),
            makeNap(daysAgo: 1, hour: 14, duration: 110),
            makeNap(daysAgo: 2, hour: 9, duration: 130),
            makeNap(daysAgo: 2, hour: 14, duration: 110)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .excessiveDaytimeSleep
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 1)
        XCTAssertEqual(
            signal?.description,
            "Ortalama gündüz uykusu yaş normunun 30 dk üstünde."
        )
    }

    func testNormalDaytimeSleepDoesNotProduceExcessiveSleepSignal() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 90),
            makeNap(daysAgo: 1, hour: 14, duration: 90)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .excessiveDaytimeSleep
            }
        )
    }

    // MARK: - Early Morning Waking

    func testEarlyMorningWakingProducesSignalAfterThreeOccurrences() {
        let wakeRecords = [
            makeWake(daysAgo: 1, hour: 5, minute: 30),
            makeWake(daysAgo: 2, hour: 5, minute: 15),
            makeWake(daysAgo: 3, hour: 5, minute: 45)
        ]

        let result = agent.assess(
            records: [],
            wakeRecords: wakeRecords,
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .earlyMorningWaking
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 2)
        XCTAssertEqual(
            signal?.description,
            "Son 7 günde 3 kez 06:00'dan önce kalktı."
        )
    }

    func testOnlyTwoEarlyMorningWakeupsDoNotProduceSignal() {
        let wakeRecords = [
            makeWake(daysAgo: 1, hour: 5, minute: 30),
            makeWake(daysAgo: 2, hour: 5, minute: 15)
        ]

        let result = agent.assess(
            records: [],
            wakeRecords: wakeRecords,
            ageMonths: 7,
            now: now
        )

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .earlyMorningWaking
            }
        )
    }

    // MARK: - Long Wake Window

    func testLongWakeWindowProducesSignalAfterFourOccurrences() {
        var naps: [SleepRecord] = []
        var wakes: [DailyWakeRecord] = []

        for day in 1...4 {
            let wake = makeWake(
                daysAgo: day,
                hour: 7,
                minute: 0
            )

            let nap = makeNap(
                daysAgo: day,
                hour: 10,
                minute: 0,
                duration: 60
            )

            wakes.append(wake)
            naps.append(
                makeNap(
                    daysAgo: day,
                    hour: 12,
                    minute: 0,
                    duration: 60
                )
            )        }

        let result = agent.assess(
            records: naps,
            wakeRecords: wakes,
            ageMonths: 7,
            now: now
        )

        let signal = result.signals.first {
            $0.type == .longWakeWindow
        }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.weight, 2)
        XCTAssertEqual(
            signal?.description,
            "Son dönemde 4 kez önerilen WW'yi rahatça aştı."
        )
    }
    
    func testShortWakeWindowDoesNotProduceLongWakeWindowSignal() {
        var naps: [SleepRecord] = []
        var wakes: [DailyWakeRecord] = []

        for day in 1...4 {
            wakes.append(
                makeWake(
                    daysAgo: day,
                    hour: 7,
                    minute: 0
                )
            )

            naps.append(
                makeNap(
                    daysAgo: day,
                    hour: 9,
                    minute: 30,
                    duration: 60
                )
            )
        }

        let result = agent.assess(
            records: naps,
            wakeRecords: wakes,
            ageMonths: 7,
            now: now
        )

        print("Signals:", result.signals.map { "\($0.type) - \($0.description)" })

        XCTAssertFalse(
            result.signals.contains {
                $0.type == .longWakeWindow
            }
        )
    }

    // MARK: - Signal Strength

    func testThreeWeightProducesModerateStrength() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertEqual(
            result.signalStrength,
            .moderate
        )
    }

    func testStrongSignalsMarkBabyReadyInThreeToTwoTransitionZone() {
        let naps = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let wakes = [
            makeWake(daysAgo: 1, hour: 5, minute: 30),
            makeWake(daysAgo: 2, hour: 5, minute: 15),
            makeWake(daysAgo: 3, hour: 5, minute: 45)
        ]

        let result = agent.assess(
            records: naps,
            wakeRecords: wakes,
            ageMonths: 7,
            now: now
        )

        XCTAssertEqual(
            result.signalStrength,
            .strong
        )
        XCTAssertTrue(result.isReadyToTransit)
        XCTAssertEqual(
            result.recommendation,
            "3→2 nap geçiş zamanı. İkinci napı bırak, yatışı erkene al."
        )
    }

    func testStrongSignalsOutsideThreeToTwoAgeZoneDoNotMarkReady() {
        let naps = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let wakes = [
            makeWake(daysAgo: 1, hour: 5, minute: 30),
            makeWake(daysAgo: 2, hour: 5, minute: 15),
            makeWake(daysAgo: 3, hour: 5, minute: 45)
        ]

        let result = agent.assess(
            records: naps,
            wakeRecords: wakes,
            ageMonths: 10,
            now: now
        )

        // 10 months is outside the expected transition age.
        XCTAssertEqual(result.transitionType, .none)
        XCTAssertFalse(result.isReadyToTransit)
    }

    // MARK: - Two To One

    func testStrongSignalsCanMakeBabyReadyForTwoToOneTransition() {
        let naps = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let wakes = [
            makeWake(daysAgo: 1, hour: 5, minute: 30),
            makeWake(daysAgo: 2, hour: 5, minute: 15),
            makeWake(daysAgo: 3, hour: 5, minute: 45)
        ]

        let result = agent.assess(
            records: naps,
            wakeRecords: wakes,
            ageMonths: 15,
            now: now
        )

        XCTAssertEqual(
            result.transitionType,
            .twoToOne
        )

        XCTAssertEqual(
            result.signalStrength,
            .strong
        )

        XCTAssertTrue(
            result.isReadyToTransit
        )

        XCTAssertEqual(
            result.recommendation,
            "2→1 nap geçiş zamanı. Tek nap düzenine geç, yatışı erkene al."
        )
    }

    func testModerateThreeToTwoRecommendation() {
        let records = [
            makeNap(daysAgo: 1, hour: 9, duration: 20),
            makeNap(daysAgo: 2, hour: 9, duration: 15),
            makeNap(daysAgo: 3, hour: 9, duration: 25)
        ]

        let result = agent.assess(
            records: records,
            wakeRecords: [],
            ageMonths: 7,
            now: now
        )

        XCTAssertEqual(
            result.signalStrength,
            .moderate
        )

        XCTAssertEqual(
            result.recommendation,
            "3→2 nap geçişi yaklaşıyor. Wake window'u 15'er dk artırmayı dene."
        )
    }

    // MARK: - Helper Methods

    private func makeNap(
        daysAgo: Int,
        hour: Int,
        minute: Int = 0,
        duration: Int
    ) -> SleepRecord {
        let date = day(daysAgo: daysAgo, hour: hour, minute: minute)

        return SleepRecord(
            id: UUID(),
            date: date,
            duration: duration,
            kind: .dayNap
        )
    }

    private func makeNight(
        daysAgo: Int,
        hour: Int,
        duration: Int
    ) -> SleepRecord {
        let date = day(daysAgo: daysAgo, hour: hour)

        return SleepRecord(
            id: UUID(),
            date: date,
            duration: duration,
            kind: .nightSleep
        )
    }

    private func makeWake(
        daysAgo: Int,
        hour: Int,
        minute: Int
    ) -> DailyWakeRecord {
        let date = day(daysAgo: daysAgo, hour: hour, minute: minute)

        return DailyWakeRecord(
            id: UUID(),
            day: date,
            wakeTime: date
        )
    }

    private func day(
        daysAgo: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        let calendar = Calendar.current

        let base = calendar.date(
            byAdding: .day,
            value: -daysAgo,
            to: calendar.startOfDay(for: now)
        )!

        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: base
        )!
    }
}

// MARK: - Mock Profile Provider

private final class MockTransitionProfileProvider:
    AgeBasedSleepProfileProviding {

    private let profile = AgeBasedSleepProfile(
        ageRange: 6...20,
        totalSleep24hRange: 660...840,
        wakeWindowRange: 150...210,
        morningWakeWindow: 150...180,
        eveningWakeWindow: 180...210,
        expectedNapCount: 2...3,
        maxSingleNapMinutes: 150,
        daytimeSleepRange: 150...210,
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
        180
    }

    func eveningWakeWindowCenter(
        forAgeMonths age: Int
    ) -> Int {
        195
    }
}
