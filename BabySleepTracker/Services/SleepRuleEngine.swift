import Foundation

enum SleepRuleDecision: Equatable {
    case normalNap
    case recoveryNap
    case bedtime
    case earlyBedtime
    case ongoingNap
}

enum SleepNapStructure: Equatable {
    case incomplete
    case transition
    case complete
}

struct SleepRuleEngineResult {
    let decision: SleepRuleDecision
    let structure: SleepNapStructure
    let expectedNapCount: ClosedRange<Int>
    let completedNapCount: Int
    let completedNaps: [SleepRecord]
    let ongoingNap: SleepRecord?
    let latestCompletedNap: SleepRecord?
    let latestCompletedNapEnd: Date?
    let now: Date
    let ageBasedLastNapCutoffTime: Date
    let recoveryNapLatestEndTime: Date
    let recoveryNapDurationMinutes: Int?
    let recoveryNapCanFinishInTime: Bool?
    let overtiredRisk: OvertiredRisk?
}

final class SleepRuleEngine {
    private let profileProvider: AgeBasedSleepProfileProviding
    private let overtiredCalculator: OvertiredCalculator
    private let calendar: Calendar

    init(
        profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        overtiredCalculator: OvertiredCalculator? = nil,
        calendar: Calendar = .current
    ) {
        self.profileProvider = profileProvider
        self.overtiredCalculator = overtiredCalculator ?? OvertiredCalculator(profileProvider: profileProvider)
        self.calendar = calendar
    }

    func decide(
        records: [SleepRecord],
        ageMonths: Int,
        now: Date,
        recoveryNapLatestEndTime: Date,
        recoveryNapDurationMinutes: Int?
    ) -> SleepRuleEngineResult {
        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let today = records.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let naps = today.filter { $0.kind == .dayNap }
        let completed = naps.filter { !$0.isOngoing }.sorted { $0.date < $1.date }
        let ongoing = naps.filter { $0.isOngoing }.sorted { $0.date < $1.date }.last
        let latest = completed.last
        let breaks = today.filter { $0.kind == .break }
        let latestEnd = latest.map { calendar.date(byAdding: .minute, value: $0.totalMinutes(breaks: breaks), to: $0.date) ?? $0.date }
        let structure: SleepNapStructure
        if completed.count < profile.expectedNapCount.lowerBound { structure = .incomplete }
        else if completed.count < profile.expectedNapCount.upperBound { structure = .transition }
        else { structure = .complete }

        let cutoff = overtiredCalculator.lastNapCutoffTime(ageMonths: ageMonths, on: now)
        let feasible: Bool?
        if let recoveryNapDurationMinutes {
            feasible = now < cutoff && now.addingTimeInterval(TimeInterval(max(0, recoveryNapDurationMinutes) * 60)) <= recoveryNapLatestEndTime
        } else {
            feasible = nil
        }
        let risk = latestEnd.map {
            overtiredCalculator.overtiredRisk(awakeSinceDate: $0, ageMonths: ageMonths, isEveningPeriod: now >= cutoff, now: now)
        }

        let decision: SleepRuleDecision
        if ongoing != nil {
            decision = .ongoingNap
        } else if now >= cutoff {
            decision = structure == .incomplete ? .earlyBedtime : .bedtime
        } else if structure == .complete {
            decision = .bedtime
        } else if structure == .incomplete {
            decision = feasible == false ? .earlyBedtime : .recoveryNap
        } else {
            decision = .normalNap
        }

        return SleepRuleEngineResult(
            decision: decision,
            structure: structure,
            expectedNapCount: profile.expectedNapCount,
            completedNapCount: completed.count,
            completedNaps: completed,
            ongoingNap: ongoing,
            latestCompletedNap: latest,
            latestCompletedNapEnd: latestEnd,
            now: now,
            ageBasedLastNapCutoffTime: cutoff,
            recoveryNapLatestEndTime: recoveryNapLatestEndTime,
            recoveryNapDurationMinutes: recoveryNapDurationMinutes,
            recoveryNapCanFinishInTime: feasible,
            overtiredRisk: risk
        )
    }
}
