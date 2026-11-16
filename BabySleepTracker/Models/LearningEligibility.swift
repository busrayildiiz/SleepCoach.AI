import Foundation

/// Evidence supplied by a future trusted adapter, never inferred from a persisted record's existence.
enum LearningEvidenceSource: String, Equatable {
    case verifiedObservation
    case recordedUnverified
    case reconstructedLegacy
    case routineDefault
    case predicted
    case llmGenerated
    case unknown
}

struct LearningSleepEvidence {
    let record: SleepRecord
    var source: LearningEvidenceSource = .unknown
}

struct LearningWakeEvidence {
    let record: DailyWakeRecord
    var source: LearningEvidenceSource = .unknown
    /// Explicit confirmation that this canonical awakening ended this night.
    /// An equal timestamp alone does not establish this semantic relationship.
    var completedNightID: UUID? = nil
}

enum LearningNapCoverage: String, Equatable {
    case confirmedComplete, incomplete, unknown
}

struct LearningDaytimeEvidence {
    let morningWakeID: UUID
    let followingWakeID: UUID
    let coverage: LearningNapCoverage
    let source: LearningEvidenceSource
    /// Exact observed nap identities covered by the confirmation, including an explicit empty set.
    let napIDs: Set<UUID>
    /// Binds confirmation to the observed boundaries and nap revisions, not just reusable IDs.
    /// Nil is intentionally insufficient for confirmed-complete coverage.
    let confirmedEvidenceIdentity: String?

    init(morningWakeID: UUID, followingWakeID: UUID, coverage: LearningNapCoverage,
         source: LearningEvidenceSource, napIDs: Set<UUID>, confirmedEvidenceIdentity: String? = nil) {
        self.morningWakeID = morningWakeID
        self.followingWakeID = followingWakeID
        self.coverage = coverage
        self.source = source
        self.napIDs = napIDs
        self.confirmedEvidenceIdentity = confirmedEvidenceIdentity
    }

    /// Capture only when a trusted source actually confirms the supplied snapshot.
    /// This initializer records an assertion; it does not verify the caller's provenance.
    init(morning: LearningWakeEvidence, following: LearningWakeEvidence,
         coverage: LearningNapCoverage, source: LearningEvidenceSource, naps: [LearningSleepEvidence]) {
        self.init(morningWakeID: morning.record.id, followingWakeID: following.record.id,
            coverage: coverage, source: source, napIDs: Set(naps.map { $0.record.id }),
            confirmedEvidenceIdentity: Self.identity(morning: morning, following: following, naps: naps))
    }

    static func identity(morning: LearningWakeEvidence, following: LearningWakeEvidence,
                         naps: [LearningSleepEvidence]) -> String {
        // Previous-night linkage is independent of this day's daytime coverage.
        // Logging time is not an observation timestamp and is not a coverage requirement.
        LearningEvidenceIdentity.pack([
            "daytime-confirmation-v1",
            LearningEvidenceIdentity.wake(morning, includeNightLink: false),
            LearningEvidenceIdentity.wake(following, includeNightLink: false),
            LearningEvidenceIdentity.pack(naps.map {
                LearningEvidenceIdentity.sleep($0, includeLoggingTime: false)
            }.sorted())])
    }
}

/// Canonical length framing avoids delimiter collisions and Swift Hasher randomization.
/// This is sensitive, lossless in-memory context, never a log value or an authorization token.
enum LearningEvidenceIdentity {
    static func pack(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }
    static func date(_ value: Date) -> String {
        String(value.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }
    static func sleep(_ evidence: LearningSleepEvidence, includeLoggingTime: Bool = true) -> String {
        let r = evidence.record
        return pack([r.id.uuidString, date(r.date), String(r.duration), r.kind.rawValue,
            r.parentNapID?.uuidString ?? "nil", String(r.isOngoing),
            includeLoggingTime ? date(r.createdAt) : "logging-time-excluded",
            r.endDate.map(date) ?? "nil", evidence.source.rawValue])
    }
    static func wake(_ evidence: LearningWakeEvidence, includeNightLink: Bool = true) -> String {
        pack([evidence.record.id.uuidString, date(evidence.record.day), date(evidence.record.wakeTime),
            evidence.source.rawValue,
            includeNightLink ? (evidence.completedNightID?.uuidString ?? "nil") : "night-link-excluded"])
    }
}

struct LearningEvidenceSnapshot {
    var sleeps: [LearningSleepEvidence]
    var wakes: [LearningWakeEvidence]
    var daytime: [LearningDaytimeEvidence] = []

    /// Compatibility bridge only. Legacy storage does not prove provenance or complete nap coverage.
    init(records: [SleepRecord], wakeRecords: [DailyWakeRecord]) {
        sleeps = records.map { LearningSleepEvidence(record: $0) }
        wakes = wakeRecords.map { LearningWakeEvidence(record: $0) }
    }

    init(sleeps: [LearningSleepEvidence], wakes: [LearningWakeEvidence],
         daytime: [LearningDaytimeEvidence] = []) {
        self.sleeps = sleeps
        self.wakes = wakes
        self.daytime = daytime
    }
}

/// Engineering policy, not a pediatric quality score. Nil policy means unconfigured.
struct LearningEligibilityPolicy: Equatable {
    let version: String
    let minimumQualifyingDays: Int
    let historicalDayCount: Int
    let recentDayCount: Int
    let minimumRecentQualifyingDays: Int
    let maximumLatestDayAge: Int
    let supportedAgeMonths: ClosedRange<Int>

    static let engineeringV01 = LearningEligibilityPolicy(
        version: "engineering-v0.1", minimumQualifyingDays: 7, historicalDayCount: 21,
        recentDayCount: 7, minimumRecentQualifyingDays: 3, maximumLatestDayAge: 3,
        supportedAgeMonths: 4...24)

    var isConfigured: Bool {
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        minimumQualifyingDays > 0 && historicalDayCount >= minimumQualifyingDays &&
        recentDayCount > 0 && recentDayCount <= historicalDayCount &&
        minimumRecentQualifyingDays > 0 && minimumRecentQualifyingDays <= recentDayCount &&
        maximumLatestDayAge >= 1 && supportedAgeMonths.lowerBound >= 0
    }
}

struct LearningDay: Equatable, Identifiable {
    /// Local midnight label under the evaluation's explicit calendar and timezone.
    let id: Date
    let morningWakeID: UUID?
    let followingWakeID: UUID?
    let nightID: UUID?
}

struct LearningEvidenceFinding: Equatable {
    enum Dimension: String { case completeness, consistency, coherence }
    enum Severity: String { case missingEvidence, blockingIntegrity, warning }
    enum Reason: String {
        case missingMorningWake, missingFollowingWake, missingNightOnset, missingCompletedEnd
        case ongoingSession, futureObservation, invalidDuration, invalidWakeDay
        case duplicateIdentity, duplicateEvent, overlappingSleep, overlappingAwakeIntervals, orphanBreak, invalidParent
        case wakeNightMismatch, unverifiedNightWakeLink, ambiguousOwnership
        case unknownNapCoverage, incompleteNapCoverage, staleNapConfirmation
        case unverifiedSource, unsupportedHistoricalAge, legacyEndUnverified
    }
    let dimension: Dimension
    let severity: Severity
    let reason: Reason
    let observationIDs: [UUID]
}

struct DailyDataQualityResult: Equatable {
    let day: LearningDay
    let ageMonths: Int
    let napCoverage: LearningNapCoverage
    let observationIDs: [UUID]
    /// Computed using elapsed seconds and existing interval-union / awake-subtraction accounting.
    let netSleepSeconds: TimeInterval?
    let findings: [LearningEvidenceFinding]
    var qualifies: Bool { findings.allSatisfy { $0.severity == .warning } }
}

struct LearningEligibilityEvaluation: Equatable {
    enum Status: Equatable {
        case unavailable, eligibleUnderPolicy, unconfiguredPolicy, invalidPolicy, unsupportedAge, invalidEvidence
    }
    enum Reason: String, Equatable {
        case policyUnavailable, policyInvalid, invalidTimestamp, unsupportedAge, insufficientQualifyingDays
        case insufficientRecentDays, latestQualifyingDayTooOld, noQualifyingDays
    }
    let evaluatedAt: Date
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let policyVersion: String?
    let status: Status
    let reasons: [Reason]
    /// Half-open local label window [today - historicalDayCount, today).
    let historicalWindow: DateInterval?
    let recentWindow: DateInterval?
    let dailyResults: [DailyDataQualityResult]
    let requiredDayCount: Int?
    let recentQualifyingDayCount: Int
    let latestQualifyingDayAge: Int?
    /// Canonical, lossless identity, not a randomized Swift Hasher or an authorization token.
    /// Sensitive derived context: keep in memory; do not log or transfer it.
    let evidenceIdentity: String
    var qualifyingDays: [LearningDay] { dailyResults.filter(\.qualifies).map(\.day) }
    var qualifyingDayCount: Int { qualifyingDays.count }
    // Intentionally no prediction authorization or subscription entitlement fields.
}
