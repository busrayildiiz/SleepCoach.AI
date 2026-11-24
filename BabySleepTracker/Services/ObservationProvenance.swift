import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Additive sidecar. Canonical content is sensitive local data, never a log or network payload.
/// Revisions are opaque UUIDs, not timestamps or hashes with process-dependent seeds.
struct ObservationProvenance: Codable {
    static let key = "observationProvenance_v1"
    var version = 2
    var sleeps: [String: Entry] = [:]
    var wakes: [String: Entry] = [:]
    var links: [String: NightWakeLink] = [:]
    var daytime: [String: DaytimeAttestation] = [:]
    // Optional for decoding metadata produced before membership generations existed.
    var coverageGenerations: [String: CoverageGeneration]? = nil
    var invalidatedDaytimeReviews: Set<DaytimeReviewLabels>? = nil

    struct CoverageGeneration: Codable {
        let morningWakeID: UUID
        let followingWakeID: UUID
        var revision: UUID
        var calendars: [Calendar]? = nil
    }

    struct Entry: Codable, Equatable {
        let revision: UUID
        let content: String
        let source: String
        let intent: String?
        var coverageContent: String? = nil
        var coverageRevision: UUID? = nil
        var completedOperationID: UUID? = nil
        var completedInput: String? = nil
        var historicalWakeCalendar: Calendar? = nil
    }
    struct DaytimeAttestation: Codable, Equatable {
        let morningWakeID: UUID
        let followingWakeID: UUID
        let coverage: String
        let binding: String
        let intent: String
        var recordedCalendar: Calendar? = nil
        var answerRevision: UUID? = nil
        var labels: DaytimeReviewLabels? = nil
    }
    struct NightWakeLink: Codable {
        let nightID: UUID
        let wakeID: UUID
        let nightRevision: UUID
        let wakeRevision: UUID
        var recordedCalendar: Calendar? = nil
    }

    mutating func revokeUnfinishedHistoricalWake(_ pending: StandaloneWakePending) -> Bool {
        let key = pending.wake.id.uuidString
        guard let entry = wakes[key], entry.completedOperationID == pending.operationID,
              entry.historicalWakeCalendar != nil else { return false }
        var replacement = Self.entry(content: entry.content)
        replacement.coverageContent = entry.coverageContent
        replacement.coverageRevision = UUID()
        wakes[key] = replacement
        return true
    }

    static func sleepIdentity(_ r: SleepRecord) -> String {
        digest(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: r)))
    }
    static func wakeIdentity(_ r: DailyWakeRecord) -> String {
        digest(LearningEvidenceIdentity.wake(LearningWakeEvidence(record: r)))
    }
    static func digest(_ value: String) -> String {
        "sha256-v1:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sleepCoverageIdentity(_ r: SleepRecord) -> String {
        digest(LearningEvidenceIdentity.sleep(LearningSleepEvidence(record: r), includeLoggingTime: false))
    }
    static func load(_ defaults: any PrivateDataStore) -> Self? {
        guard defaults.isAvailable, let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 2 else { return nil }
        return value
    }
    static func entry(content: String) -> Entry {
        Entry(revision: UUID(), content: content,
              source: LearningEvidenceSource.recordedUnverified.rawValue, intent: nil)
    }

    /// Runs BEFORE record mutation: revocation survives a failed record write or edit/revert.
    /// Unknown/corrupt sidecars recover only as unverified, never from record plausibility.
    mutating func reconcile(sleeps records: [SleepRecord]) {
        let old = sleeps
        sleeps = [:]
        for r in records {
            let key = r.id.uuidString
            let content = Self.sleepIdentity(r)
            let coverage = Self.sleepCoverageIdentity(r)
            if let previous = old[key], previous.content == content {
                sleeps[key] = previous
            } else if let previous = old[key], previous.coverageContent == coverage {
                // Logging-only changes do not change the actual observed interval.
                sleeps[key] = Entry(revision: UUID(), content: content, source: previous.source,
                    intent: previous.intent, coverageContent: coverage, coverageRevision: previous.coverageRevision)
            } else {
                var entry = Self.entry(content: content)
                entry.coverageContent = coverage
                entry.coverageRevision = UUID()
                sleeps[key] = entry
            }
        }
        pruneLinks()
    }
    mutating func reconcile(wakes records: [DailyWakeRecord]) {
        let old = wakes
        wakes = [:]
        for r in records {
            let key = r.id.uuidString
            let content = Self.wakeIdentity(r)
            if let previous = old[key], previous.content == content,
               previous.historicalWakeCalendar.map({ calendar in
                   records.filter { calendar.isDate($0.day, inSameDayAs: r.day) }.count == 1
               }) != false { wakes[key] = previous }
            else {
                var entry = Self.entry(content: content)
                entry.coverageContent = content
                entry.coverageRevision = UUID()
                wakes[key] = entry
            }
        }
        pruneLinks()
        // Revoke before the wake collection write, including insertion of another
        // candidate that leaves the linked wake's own content/revision untouched.
        links = links.filter { _, link in
            guard let wake = records.first(where: { $0.id == link.wakeID }) else { return false }
            let calendar = link.recordedCalendar ?? .current
            return records.filter { calendar.isDate($0.day, inSameDayAs: wake.day) }.count == 1
        }
    }
    /// Remove affected assertions BEFORE record writes. Returning to an old membership
    /// cannot recreate a removed parent answer. Other cycles and logging-only edits survive.
    private var trackedCoverage: [String: CoverageGeneration] {
        var tracked = coverageGenerations ?? [:]
        for (key, assertion) in daytime where tracked[key] == nil {
            tracked[key] = .init(morningWakeID: assertion.morningWakeID, followingWakeID: assertion.followingWakeID, revision: UUID(),
                                  calendars: assertion.recordedCalendar.map { [$0] })
        }
        return tracked
    }
    mutating func revokeCoverage(old: [SleepRecord], new: [SleepRecord], wakes: [DailyWakeRecord]) {
        for (key, generation) in trackedCoverage {
            func state(_ records: [SleepRecord]) -> [String]? {
                guard let morning = wakes.first(where: { $0.id == generation.morningWakeID }),
                      let following = wakes.first(where: { $0.id == generation.followingWakeID }) else { return nil }
                let naps = records.filter {
                    DaytimeReviewWindow.affectsCoverage($0, start: morning.wakeTime, end: following.wakeTime)
                }
                let ids = Set(naps.map(\.id))
                let related = records.filter {
                    $0.id == morning.id || $0.id == following.id ||
                        DaytimeReviewWindow.isRelevantBreak($0, napIDs: ids, start: morning.wakeTime, end: following.wakeTime)
                }
                return (naps + related).map(Self.sleepCoverageIdentity).sorted()
            }
            if state(old) != state(new) || state(new) == nil {
                invalidateCoverage(key: key, generation: generation)
            }
        }
    }
    mutating func revokeCoverage(old: [DailyWakeRecord], new: [DailyWakeRecord]) {
        for (key, generation) in trackedCoverage {
            let calendars = generation.calendars ?? [.current]
            func pair(_ records: [DailyWakeRecord], in calendar: Calendar) -> [String]? {
                DaytimeReviewWindow.canonicalPair(in: records, morningID: generation.morningWakeID,
                    followingID: generation.followingWakeID, calendar: calendar)?.map(Self.wakeIdentity)
            }
            if calendars.contains(where: { pair(old, in: $0) != pair(new, in: $0) }) {
                invalidateCoverage(key: key, generation: generation)
            }
        }
    }

    private mutating func invalidateCoverage(key: String, generation: CoverageGeneration) {
        if let labels = daytime[key]?.labels {
            if invalidatedDaytimeReviews == nil { invalidatedDaytimeReviews = [] }
            invalidatedDaytimeReviews?.insert(labels)
        }
        rotateCoverage(key: key, generation: generation)
    }

    mutating func clearDaytimeInvalidation(_ labels: DaytimeReviewLabels) {
        invalidatedDaytimeReviews?.remove(labels)
        if invalidatedDaytimeReviews?.isEmpty == true { invalidatedDaytimeReviews = nil }
    }

    mutating func rotateCoverage(key: String, generation: CoverageGeneration) {
        var retired = generation
        retired.revision = UUID()
        coverageGenerations = coverageGenerations ?? [:]
        coverageGenerations?[key] = retired
        daytime.removeValue(forKey: key)
    }
    private mutating func pruneLinks() {
        links = links.filter { _, link in
            sleeps[link.nightID.uuidString]?.revision == link.nightRevision &&
            wakes[link.wakeID.uuidString]?.revision == link.wakeRevision
        }
    }
}

/// A form keeps this opaque capability across retries. The durable counter, rather
/// than an expiring per-record tombstone, prevents a spent capability being reused.
final class ObservationCreationIntent {
    let operationID = UUID()
    let recordID: UUID
    fileprivate(set) var reservation: ObservationCreationReservation?
    fileprivate(set) var isRetired = false
    fileprivate var storage: ObservationStorage?
    fileprivate var boundStoreID: ObjectIdentifier?
    fileprivate var boundStoreGeneration: UUID?
    fileprivate var resumedOperations: Set<UUID> = []
    fileprivate(set) var nightCompletionAcknowledgement: NightCompletionAcknowledgement? = nil
    init(recordID: UUID) { self.recordID = recordID }
    var requiresExplicitCancellation: Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        return storage != nil
    }
    @discardableResult
    func abandon() -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        isRetired = true
        guard let storage else { return true }
        guard boundStoreGeneration == storage.defaults.generationToken else { return false }
        var retired = storage.retireOperation(operationID, reservation: reservation)
        for operation in resumedOperations {
            if !storage.retireOperation(operation, reservation: nil) { retired = false }
        }
        return retired
    }
}

/// Transient acknowledgement capability. It is bound to an adopted operation's
/// persisted receipts and this editor's exact input; it grants no new attestation.
struct NightCompletionAcknowledgement {
    let operationID: UUID
    let persistedInput: String
    let submissionInput: String
    let nightID: UUID
    let wakeID: UUID
    let nightRevision: UUID
    let wakeRevision: UUID
    let calendar: Calendar
}

struct ObservationCreationReservation: Codable, Equatable {
    let ledgerID: UUID
    let serial: UInt64
    let operationID: UUID
    let recordID: UUID
    let collection: String
    let content: String
}

/// Constant retired-operation state plus at most 64 unresolved creations. No TTL:
/// removing a pending slot spends its serial permanently. Capacity fails closed;
/// it never evicts another form's valid retry or grows with deleted observations.
struct ObservationCreationLedger: Codable {
    static let key = "observationCreationLedger_v1"
    static let capacity = 64
    static let processID = UUID()
    let version: Int
    let id: UUID
    var next: UInt64
    var pending: [ObservationCreationReservation]
    var processID: UUID? = nil

    static func load(_ defaults: any PrivateDataStore) -> Self? {
        guard defaults.isAvailable, let raw = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: raw), value.version == 1,
              value.pending.count <= capacity,
              Set(value.pending.map(\.serial)).count == value.pending.count,
              value.pending.allSatisfy({ $0.ledgerID == value.id && $0.serial < value.next &&
                  ["sleepRecords", "dailyWakeRecords_v1"].contains($0.collection) &&
                  $0.content.hasPrefix("sha256-v1:") && $0.content.count == 74 }) else { return nil }
        return value
    }
    static func contains(_ reservation: ObservationCreationReservation, defaults: any PrivateDataStore) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        return !ObservationStorage.retirementRequests.contains(reservation.operationID) &&
            load(defaults)?.pending.contains(reservation) == true
    }
}

/// Local recovery journal, never evidence or an atomic transaction.
struct ObservationCompletionPending: Codable {
    static let key = "nightWakeCompletionPending_v1"
    let version: Int
    let originalNight: SleepRecord
    let wake: DailyWakeRecord
    let originalWakeContent: String?
    let originalWakeRevision: UUID?
    var operationID = UUID()
    var recordedCalendar: Calendar? = nil
    var wakeAttested = false
    var onset: ObservationProvenance.Entry? = nil
    var originalNightRevision: UUID? = nil
    var expectedWake: ObservationProvenance.Entry? = nil
    var expectedNight: ObservationProvenance.Entry? = nil
    var isCancelled = false
    var creation: ObservationCreationReservation? = nil
    var selectedInput: Date? = nil
    /// Additive discriminator: forward End Sleep commands also recover ordinary,
    /// unattested completions. Older wake-editor journals retain their contract.
    var nightCompletionInput: String? = nil

    static func completionInput(baseline: String, revision: UUID?, completed: SleepRecord) -> String {
        ObservationProvenance.digest(LearningEvidenceIdentity.pack([
            "night-completion-input-v1", baseline, revision?.uuidString ?? "",
            ObservationProvenance.sleepIdentity(completed)
        ]))
    }
    var originalNightContent: String { ObservationProvenance.sleepIdentity(originalNight) }
    var night: SleepRecord {
        let minutes = wake.wakeTime.timeIntervalSince(originalNight.date) / 60
        let duration = minutes.isFinite && minutes > 0 && minutes < Double(Int.max) ? max(1, Int(minutes)) : 0
        return SleepRecord(id: originalNight.id, date: originalNight.date, duration: duration,
            kind: originalNight.kind, parentNapID: originalNight.parentNapID,
            isOngoing: false, createdAt: originalNight.createdAt, endDate: wake.wakeTime)
    }
    func isValid(now: Date, calendar: Calendar) -> Bool {
        guard version == 3, let recordedCalendar, now.timeIntervalSinceReferenceDate.isFinite,
              originalNight.kind == .nightSleep, originalNight.isOngoing, originalNight.endDate == nil,
              originalNight.date.timeIntervalSinceReferenceDate.isFinite,
              originalNight.createdAt.timeIntervalSinceReferenceDate.isFinite,
              wake.wakeTime.timeIntervalSinceReferenceDate.isFinite,
              selectedInput.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              wake.day == recordedCalendar.startOfDay(for: wake.wakeTime),
              wake.wakeTime > originalNight.date, wake.wakeTime <= now, night.duration > 0 else { return false }
        if let input = nightCompletionInput,
           input != Self.completionInput(baseline: originalNightContent, revision: originalNightRevision, completed: night) {
            return false
        }
        if let creation {
            guard creation.recordID == wake.id, creation.collection == "dailyWakeRecords_v1",
                  creation.content == ObservationProvenance.wakeIdentity(wake) else { return false }
        }
        return (expectedWake.map { $0.content == ObservationProvenance.wakeIdentity(wake) } ?? true) &&
            (expectedNight.map { $0.content == ObservationProvenance.sleepIdentity(night) } ?? true)
    }
    func canResume(defaults: any PrivateDataStore, now: Date) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable, !ObservationStorage.retirementRequests.contains(operationID),
              creation.map({ !ObservationStorage.retirementRequests.contains($0.operationID) }) ?? true else { return false }
        guard !isCancelled, isValid(now: now, calendar: recordedCalendar ?? .current),
              let sleeps = SleepRecordPersistence(defaults: defaults).load(),
              let actualNight = sleeps.first(where: { $0.id == originalNight.id }),
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || DailyWakeRecordPersistence(defaults: defaults).load() != nil else { return false }
        // Pre-B1 arrays have no sidecar. Empty metadata confers no verification;
        // the first persistence write initializes it (quarantining bad envelopes).
        let metadata = ObservationProvenance.load(defaults) ?? ObservationProvenance()
        let nightEntry = metadata.sleeps[originalNight.id.uuidString]
        let actualContent = ObservationProvenance.sleepIdentity(actualNight)
        if actualContent == originalNightContent {
            guard (nightEntry?.content == originalNightContent && nightEntry?.revision == originalNightRevision) ||
                    (expectedNight != nil && nightEntry == expectedNight) || (nightEntry == nil && originalNightRevision == nil) else { return false }
        } else {
            guard actualContent == ObservationProvenance.sleepIdentity(night),
                  let expectedNight, nightEntry?.revision == expectedNight.revision,
                  nightEntry?.content == expectedNight.content else { return false }
        }
        let currentWakes = DailyWakeRecordPersistence(defaults: defaults).load() ?? []
        let scope = recordedCalendar ?? .current
        guard !currentWakes.contains(where: { scope.isDate($0.day, inSameDayAs: wake.day) && $0.id != wake.id }) else { return false }
        let actualWake = currentWakes.first { $0.id == wake.id }
        if let creation, actualWake == nil,
           !ObservationCreationLedger.contains(creation, defaults: defaults) { return false }
        let wakeEntry = metadata.wakes[wake.id.uuidString]
        if actualWake.map(ObservationProvenance.wakeIdentity) == originalWakeContent {
            return wakeEntry?.revision == originalWakeRevision || (expectedWake != nil && wakeEntry == expectedWake)
        }
        return actualWake.map(ObservationProvenance.wakeIdentity) == ObservationProvenance.wakeIdentity(wake) &&
            expectedWake != nil && wakeEntry?.revision == expectedWake?.revision && wakeEntry?.content == expectedWake?.content
    }
    static func load(_ defaults: any PrivateDataStore) -> Self? {
        guard defaults.isAvailable, let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(Self.self, from: data), pending.version == 3 else { return nil }
        return pending
    }
}

/// Standalone wake publication has its own exact receipt. An unchanged editor can
/// resume this original intent; it cannot manufacture a new parent confirmation.
struct StandaloneWakePending: Codable {
    static let key = "standaloneWakePending_v1"
    var version = 1
    let operationID: UUID
    let wake: DailyWakeRecord
    let originalContent: String?
    let originalRevision: UUID?
    let calendar: Calendar
    let attested: Bool
    var expected: ObservationProvenance.Entry? = nil
    var creation: ObservationCreationReservation? = nil
    var isCancelled = false
    var historical: Bool? = nil
    var selectedInput: Date? = nil

    static func load(_ defaults: any PrivateDataStore) -> Self? {
        guard defaults.isAvailable, let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return nil }
        return value
    }
    func canResume(defaults: any PrivateDataStore, now: Date) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable, !ObservationStorage.retirementRequests.contains(operationID),
              creation.map({ !ObservationStorage.retirementRequests.contains($0.operationID) }) ?? true else { return false }
        guard !isCancelled, wake.wakeTime.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, wake.wakeTime <= now,
              selectedInput.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              historical != true || (attested && creation != nil && selectedInput == wake.wakeTime &&
                  wake.day < calendar.startOfDay(for: now) &&
                  (defaults.data(forKey: ObservationProvenance.key) == nil || ObservationProvenance.load(defaults) != nil)),
              wake.day == calendar.startOfDay(for: wake.wakeTime),
              expected.map({ $0.content == ObservationProvenance.wakeIdentity(wake) }) ?? true,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || DailyWakeRecordPersistence(defaults: defaults).load() != nil else { return false }
        if let creation {
            guard historical != true || creation.operationID == operationID,
                  creation.recordID == wake.id, creation.collection == "dailyWakeRecords_v1",
                  creation.content == ObservationProvenance.wakeIdentity(wake) else { return false }
        }
        let wakes = DailyWakeRecordPersistence(defaults: defaults).load() ?? []
        guard wakes.filter({ $0.id == wake.id }).count <= 1,
              !wakes.contains(where: { $0.id != wake.id && calendar.isDate($0.day, inSameDayAs: wake.day) }) else { return false }
        let actual = wakes.first { $0.id == wake.id }
        if let creation, actual == nil, !ObservationCreationLedger.contains(creation, defaults: defaults) { return false }
        let entry = ObservationProvenance.load(defaults)?.wakes[wake.id.uuidString]
        if actual.map(ObservationProvenance.wakeIdentity) == originalContent {
            return entry?.revision == originalRevision ||
                (expected != nil && entry?.revision == expected?.revision && entry?.content == expected?.content)
        }
        return actual.map(ObservationProvenance.wakeIdentity) == ObservationProvenance.wakeIdentity(wake) &&
            expected != nil && entry?.revision == expected?.revision && entry?.content == expected?.content
    }
}

/// Observation writes still span separate commits. The sidecar is revoked first;
/// records are written second; positive attestations are published only after read-back.
/// Read-back verifies the storage result; it does not make a multi-key operation atomic.
/// Notifications run only at finalized write boundaries, without retaining any
/// recursive ownership. Receipts are rechecked by callers after observers return.
final class ObservationPersistenceLock {
    private let mutex = NSRecursiveLock()
    private let depthKey = "SleepCoach.ObservationPersistenceLock.depth." + UUID().uuidString
    func lock() {
        mutex.lock()
        Thread.current.threadDictionary[depthKey] = depth + 1
    }
    func unlock() {
        precondition(depth > 0)
        Thread.current.threadDictionary[depthKey] = depth - 1
        mutex.unlock()
    }
    private var depth: Int { Thread.current.threadDictionary[depthKey] as? Int ?? 0 }
    func withoutLock(_ body: () -> Void) {
        let held = depth
        for _ in 0..<held { unlock() }
        defer { for _ in 0..<held { lock() } }
        body()
    }
}

struct ObservationStorage {
    static let lock = ObservationPersistenceLock()
    /// Cleanup hints only. Durable authority remains in the monotonic ledger and
    /// cancellation journals. Failed retirement is retried with the next writer.
    fileprivate static var retirementRequests: Set<UUID> = []
    private final class WeakIntent {
        weak var value: ObservationCreationIntent?
        init(_ value: ObservationCreationIntent) { self.value = value }
    }
    // Only live form capabilities, never a second durable operation history.
    private static var boundIntents: [UUID: WeakIntent] = [:]
    private func track(_ intent: ObservationCreationIntent) {
        Self.boundIntents = Self.boundIntents.filter { $0.value.value != nil }
        Self.boundIntents[intent.operationID] = WeakIntent(intent)
    }
    static func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        lock.withoutLock { NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo) }
    }
    static func completionIsActive(_ operation: UUID, defaults: any PrivateDataStore) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.isAvailable, !retirementRequests.contains(operation) else { return false }
        if let pending = ObservationCompletionPending.load(defaults), pending.operationID == operation {
            return !pending.isCancelled && (pending.creation.map { !retirementRequests.contains($0.operationID) } ?? true)
        }
        if let pending = StandaloneWakePending.load(defaults), pending.operationID == operation {
            return !pending.isCancelled && (pending.creation.map { !retirementRequests.contains($0.operationID) } ?? true)
        }
        return false
    }
    let defaults: any PrivateDataStore
    /// Serialized synchronous storage I/O, not an application callback. Notifications
    /// and receipt callbacks use the unlocked boundaries below.
    let write: (Data, String) -> Bool
    private let writeForGeneration: (Data, String, UUID?) -> Bool
    let clock: () -> Date

    init(defaults: any PrivateDataStore, writer: ((Data, String) -> Bool)? = nil, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.defaults = defaults
        let performWrite: (Data, String, UUID?) -> Bool = { data, key, generation in
            guard defaults.isAvailable, defaults.generationToken == generation else { return false }
            if let writer {
                guard writer(data, key) else { return false }
            } else if let protectedStore = defaults as? SecureDataStore {
                do { try protectedStore.write([key: data], ifGeneration: generation) }
                catch { return false }
            } else {
                defaults.set(data, forKey: key)
            }
            return defaults.isAvailable && defaults.generationToken == generation && defaults.data(forKey: key) == data
        }
        writeForGeneration = performWrite
        write = { data, key in performWrite(data, key, defaults.generationToken) }
    }

    private func creationLedger() -> ObservationCreationLedger? {
        guard defaults.isAvailable else { return nil }
        if defaults.data(forKey: ObservationCreationLedger.key) == nil {
            return .init(version: 1, id: UUID(), next: 0, pending: [], processID: ObservationCreationLedger.processID)
        }
        guard var ledger = ObservationCreationLedger.load(defaults) else { return nil }
        if ledger.processID != ObservationCreationLedger.processID {
            // Forms are transient, not decoded after process death. Retire abandoned
            // reservations permanently, retaining both journals' restartable intents.
            let night = ObservationCompletionPending.load(defaults)
            let standalone = StandaloneWakePending.load(defaults)
            let recoverable = [night?.isCancelled == false ? night?.creation?.operationID : nil,
                               standalone?.isCancelled == false ? standalone?.creation?.operationID : nil].compactMap { $0 }
            ledger.pending.removeAll { !recoverable.contains($0.operationID) }
            ledger.processID = ObservationCreationLedger.processID
            guard saveCreationLedger(ledger) else { return nil }
        }
        return ledger
    }
    private func saveCreationLedger(_ ledger: ObservationCreationLedger) -> Bool {
        guard let data = try? JSONEncoder().encode(ledger), write(data, ObservationCreationLedger.key),
              defaults.data(forKey: ObservationCreationLedger.key) == data else { return false }
        return true
    }
    func reserveCreation(_ intent: ObservationCreationIntent, collection: String,
                         content: String) -> ObservationCreationReservation? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable, acceptsStore(for: intent), !intent.isRetired,
              drainRetirements(), var ledger = creationLedger() else { return nil }
        intent.storage = self
        track(intent)
        let reservation: ObservationCreationReservation
        if let bound = intent.reservation {
            guard bound.ledgerID == ledger.id, bound.recordID == intent.recordID,
                  bound.collection == collection, bound.content == content else { return nil }
            if ledger.pending.contains(bound) { return bound }
            // A failed counter write may be retried only before another allocation.
            guard bound.serial == ledger.next else { return nil }
            reservation = bound
        } else {
            reservation = .init(ledgerID: ledger.id, serial: ledger.next, operationID: intent.operationID,
                                recordID: intent.recordID, collection: collection, content: content)
            intent.reservation = reservation
        }
        guard ledger.next < UInt64.max, ledger.pending.count < ObservationCreationLedger.capacity else { return nil }
        ledger.next += 1
        ledger.pending.append(reservation)
        guard saveCreationLedger(ledger) else {
            if defaults.data(forKey: ObservationCreationLedger.key) == nil { intent.reservation = nil }
            return nil
        }
        return reservation
    }
    func bind(_ intent: ObservationCreationIntent) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable, acceptsStore(for: intent), !intent.isRetired, drainRetirements() else { return false }
        intent.storage = self
        track(intent)
        return true
    }
    private func acceptsStore(for intent: ObservationCreationIntent) -> Bool {
        let identity = ObjectIdentifier(defaults)
        if let previous = intent.boundStoreID {
            // Protected stores expose an epoch. Legacy test adapters have none
            // and may reopen the same isolated preferences suite as a new object.
            if intent.boundStoreGeneration != nil || defaults.generationToken != nil {
                guard previous == identity, intent.boundStoreGeneration == defaults.generationToken else {
                    intent.isRetired = true
                    return false
                }
            }
        } else {
            intent.boundStoreID = identity
            intent.boundStoreGeneration = defaults.generationToken
        }
        return true
    }
    func adopt(_ operation: UUID, by intent: ObservationCreationIntent?) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        intent?.resumedOperations.insert(operation)
    }
    private func drainRetirements() -> Bool {
        guard defaults.isAvailable else { return false }
        guard !Self.retirementRequests.isEmpty else { return true }
        var candidates: [(UUID, ObservationCreationReservation?)] = []
        for entry in ObservationCreationLedger.load(defaults)?.pending ?? [] {
            candidates.append((entry.operationID, entry))
        }
        if let pending = ObservationCompletionPending.load(defaults) {
            candidates.append((pending.operationID, pending.creation))
        }
        if let pending = StandaloneWakePending.load(defaults) {
            candidates.append((pending.operationID, pending.creation))
        }
        for (operation, reservation) in candidates {
            guard finishRetirementIfRequested(operation, reservation: reservation) else { return false }
        }
        return true
    }
    func finishRetirementIfRequested(_ operation: UUID, reservation: ObservationCreationReservation?) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable else { return false }
        if Self.retirementRequests.contains(operation) { return retireOperation(operation, reservation: reservation) }
        if let reservation, Self.retirementRequests.contains(reservation.operationID) {
            return retireOperation(reservation.operationID, reservation: reservation)
        }
        return true
    }
    private func cancelOperationJournals(_ operation: UUID) -> Bool {
        guard defaults.isAvailable else { return false }
        if var pending = ObservationCompletionPending.load(defaults),
           pending.operationID == operation || pending.creation?.operationID == operation {
            pending.isCancelled = true
            guard journal(pending) else { return false }
        }
        if var pending = StandaloneWakePending.load(defaults),
           pending.operationID == operation || pending.creation?.operationID == operation {
            pending.isCancelled = true
            guard standaloneJournal(pending) else { return false }
        }
        return true
    }
    fileprivate func retireOperation(_ operation: UUID, reservation: ObservationCreationReservation?,
                                      useJournalReservation: Bool = true) -> Bool {
        Self.retirementRequests.insert(operation)
        Self.boundIntents[operation]?.value?.isRetired = true
        let reservation = reservation ?? (useJournalReservation ? (
            ObservationCompletionPending.load(defaults).flatMap { $0.operationID == operation ? $0.creation : nil } ??
            StandaloneWakePending.load(defaults).flatMap { $0.operationID == operation ? $0.creation : nil }) : nil)
        guard cancelOperationJournals(operation) else { return false }
        var sleepRevisionChanged = false
        var wakeRevisionChanged = false
        if let pending = ObservationCompletionPending.load(defaults), pending.operationID == operation,
           pending.nightCompletionInput != nil {
            // Cancellation and automatic retirement share the same repair. A failed
            // record write may have left metadata for a record that never reached disk.
            guard defaults.data(forKey: "sleepRecords") == nil || SleepRecordPersistence(defaults: defaults).load() != nil,
                  defaults.data(forKey: "dailyWakeRecords_v1") == nil || DailyWakeRecordPersistence(defaults: defaults).load() != nil else { return false }
            var metadata = ObservationProvenance.load(defaults) ?? ObservationProvenance()
            let oldSleeps = metadata.sleeps
            let oldWakes = metadata.wakes
            metadata.reconcile(sleeps: SleepRecordPersistence(defaults: defaults).load() ?? [])
            metadata.reconcile(wakes: DailyWakeRecordPersistence(defaults: defaults).load() ?? [])
            sleepRevisionChanged = metadata.sleeps != oldSleeps
            wakeRevisionChanged = metadata.wakes != oldWakes
            guard self.metadata(metadata, notify: false) else { return false }
        }
        if let pending = StandaloneWakePending.load(defaults), pending.historical == true,
           pending.operationID == operation, var metadata = ObservationProvenance.load(defaults),
           metadata.revokeUnfinishedHistoricalWake(pending) {
            guard publishHistoricalWake(metadata) else { return false }
            wakeRevisionChanged = true
        }
        if let reservation {
            guard let ledger = ObservationCreationLedger.load(defaults), ledger.id == reservation.ledgerID else { return false }
            // A full ledger or a failed allocation may leave a tentative, never-issued
            // serial on the form. It has no durable authority to consume.
            if reservation.serial < ledger.next {
                guard finishCreation(reservation) else { return false }
            } else if reservation.serial != ledger.next { return false }
        }
        guard removeCancelledJournals(operation) else { return false }
        Self.retirementRequests.remove(operation)
        Self.boundIntents.removeValue(forKey: operation)
        // Generic refresh events, after durable retirement; no completion is claimed.
        if sleepRevisionChanged { Self.post(.sleepRecordsDidChange) }
        if wakeRevisionChanged { Self.post(.dailyWakeRecordsDidChange) }
        return true
    }
    private func removeCancelledJournals(_ operation: UUID) -> Bool {
        guard defaults.isAvailable else { return false }
        if let pending = ObservationCompletionPending.load(defaults), pending.isCancelled,
           pending.operationID == operation || pending.creation?.operationID == operation {
            defaults.removeObject(forKey: ObservationCompletionPending.key)
            guard defaults.isAvailable, defaults.data(forKey: ObservationCompletionPending.key) == nil else { return false }
        }
        if let pending = StandaloneWakePending.load(defaults), pending.isCancelled,
           pending.operationID == operation || pending.creation?.operationID == operation {
            defaults.removeObject(forKey: StandaloneWakePending.key)
            guard defaults.isAvailable, defaults.data(forKey: StandaloneWakePending.key) == nil else { return false }
        }
        return true
    }
    /// A nonresumable forward journal is retired, not repaired into fresh evidence.
    /// Quarantine precedes durable cancellation and ledger consumption; a failed
    /// boundary keeps the journal blocking until a later safe retirement attempt.
    func retireInvalidForwardCompletion(now: Date) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable else { return false }
        guard let raw = defaults.data(forKey: ObservationCompletionPending.key) else { return true }
        guard let pending = ObservationCompletionPending.load(defaults) else {
            // Existing B1 maintenance quarantines malformed/unsupported envelopes.
            return pruneRecoveryArchives()
        }
        guard pending.nightCompletionInput != nil else { return true }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              defaults.data(forKey: "sleepRecords") == nil || SleepRecordPersistence(defaults: defaults).load() != nil,
              defaults.data(forKey: "dailyWakeRecords_v1") == nil || DailyWakeRecordPersistence(defaults: defaults).load() != nil else { return false }
        // A clock rollback alone does not retire an otherwise legitimate operation.
        let validationTime = pending.wake.wakeTime.timeIntervalSinceReferenceDate.isFinite ? max(now, pending.wake.wakeTime) : now
        if pending.canResume(defaults: defaults, now: validationTime) { return true }
        guard preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1"),
              defaults.data(forKey: ObservationCompletionPending.key) == raw else { return false }
        let ledger = ObservationCreationLedger.load(defaults)
        guard defaults.data(forKey: ObservationCreationLedger.key) == nil || ledger != nil else { return false }
        // Consult the actual ledger, rather than trusting a corrupt journal's
        // reservation to retire some other form's serial or operation.
        let reservations = ledger?.pending.filter { $0.operationID == pending.operationID } ?? []
        guard reservations.count <= 1 else { return false }
        return retireOperation(pending.operationID, reservation: reservations.first, useJournalReservation: false)
    }

    func retireHistoricalWake(_ pending: StandaloneWakePending) -> Bool {
        guard pending.historical == true,
              StandaloneWakePending.load(defaults)?.operationID == pending.operationID,
              let raw = defaults.data(forKey: StandaloneWakePending.key),
              preserve(raw, recoveryKey: "nightWakeCompletionRecovery_v1"),
              defaults.data(forKey: StandaloneWakePending.key) == raw else { return false }
        let ledger = ObservationCreationLedger.load(defaults)
        guard defaults.data(forKey: ObservationCreationLedger.key) == nil || ledger != nil else { return false }
        let reservations = ledger?.pending.filter { $0.operationID == pending.operationID } ?? []
        guard reservations.count <= 1 else { return false }
        return retireOperation(pending.operationID, reservation: reservations.first, useJournalReservation: false)
    }

    func rememberNightCompletion(_ pending: ObservationCompletionPending, submissionInput: String,
                                 by intent: ObservationCreationIntent) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !intent.isRetired, intent.operationID == pending.operationID || intent.resumedOperations.contains(pending.operationID),
              let input = pending.nightCompletionInput, let calendar = pending.recordedCalendar,
              let metadata = ObservationProvenance.load(defaults),
              let night = SleepRecordPersistence(defaults: defaults).load()?.first(where: { $0.id == pending.night.id }),
              let wake = DailyWakeRecordPersistence(defaults: defaults).load()?.first(where: { $0.id == pending.wake.id }),
              let nightEntry = metadata.sleeps[night.id.uuidString], let wakeEntry = metadata.wakes[wake.id.uuidString],
              nightEntry.completedOperationID == pending.operationID, nightEntry.completedInput == input,
              wakeEntry.completedOperationID == pending.operationID, wakeEntry.completedInput == input,
              nightEntry.revision == night.persistedRevision, wakeEntry.revision == wake.persistedRevision,
              nightEntry.content == ObservationProvenance.sleepIdentity(pending.night),
              nightEntry.content == ObservationProvenance.sleepIdentity(night),
              wakeEntry.content == ObservationProvenance.wakeIdentity(pending.wake),
              wakeEntry.content == ObservationProvenance.wakeIdentity(wake) else { return }
        intent.nightCompletionAcknowledgement = .init(operationID: pending.operationID, persistedInput: input,
            submissionInput: submissionInput, nightID: night.id, wakeID: wake.id,
            nightRevision: nightEntry.revision, wakeRevision: wakeEntry.revision, calendar: calendar)
    }

    func finishCreation(_ reservation: ObservationCreationReservation) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var ledger = ObservationCreationLedger.load(defaults), ledger.id == reservation.ledgerID,
              reservation.serial < ledger.next else { return false }
        guard ledger.pending.contains(reservation) else { return true }
        ledger.pending.removeAll { $0 == reservation }
        return saveCreationLedger(ledger)
    }
    /// Revoke before deleting, even if the observation write later fails. No serial
    /// can be allocated again, and unrelated pending operations remain resumable.
    func cancelCreations(collection: String, deletedIDs: Set<UUID>) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable else { return false }
        guard !deletedIDs.isEmpty, defaults.data(forKey: ObservationCreationLedger.key) != nil else { return true }
        guard var ledger = ObservationCreationLedger.load(defaults) else { return false }
        let oldCount = ledger.pending.count
        ledger.pending.removeAll { $0.collection == collection && deletedIDs.contains($0.recordID) }
        return oldCount == ledger.pending.count || saveCreationLedger(ledger)
    }
    // Bounded quarantine, not a second observation history. Unsupported journal payloads
    // retain only digest/size; metadata raw bytes are limited to 8 KiB for seven days.
    // Purging runs on writes/startup; there is no background disk-expiry guarantee.
    struct RecoveryEntry: Codable {
        let digest: String
        let savedAt: Date
        let byteCount: Int
        var raw: Data?
    }
    static let archiveKeys = ["observationProvenanceRecovery_v1", "nightWakeCompletionRecovery_v1"]
    static let archiveTTL: TimeInterval = 7 * 86400
    static let archiveCount = 4
    static let archiveBytes = 32768
    // Digest-only journal diagnostics have a fixed 2 KiB share. Together the two
    // archives never exceed 32 KiB after successful maintenance.
    private func archiveByteLimit(_ key: String) -> Int {
        key == Self.archiveKeys[0] ? Self.archiveBytes - 2048 : 2048
    }
    static let cleanupRequestKey = "observationRecoveryCleanupPending_v1"

    /// Written before a deletion. A failed cleanup is retried on subsequent writes
    /// and Home startup; the marker contains no observation or parent information.
    func requestRecoveryCleanup() -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let data = Data("true".utf8)
        return write(data, Self.cleanupRequestKey) && defaults.data(forKey: Self.cleanupRequestKey) == data
    }

    private func reportMaintenanceFailures(_ stores: [String]) {
        _ = requestRecoveryCleanup()
        Self.post(.observationRecoveryMaintenanceDidFail, userInfo: ["stores": stores])
    }

    private func bounded(_ entries: [RecoveryEntry], now: Date, removingRaw: Bool = false, byteLimit: Int) -> [RecoveryEntry] {
        var result = entries.filter { $0.savedAt <= now && now.timeIntervalSince($0.savedAt) < Self.archiveTTL }
            .sorted { $0.savedAt == $1.savedAt ? $0.digest < $1.digest : $0.savedAt > $1.savedAt }
        result = result.map { var entry = $0; if (entry.raw?.count ?? 0) > 8192 { entry.raw = nil }; return entry }
        if removingRaw { result = result.map { var entry = $0; entry.raw = nil; return entry } }
        result = Array(result.prefix(Self.archiveCount))
        while !result.isEmpty && ((try? JSONEncoder().encode(result).count) ?? Int.max) > byteLimit { result.removeLast() }
        return result
    }
    private func recovery(_ key: String) -> [RecoveryEntry]? {
        guard defaults.isAvailable else { return nil }
        guard let data = defaults.data(forKey: key) else { return [] }
        if let entries = try? JSONDecoder().decode([RecoveryEntry].self, from: data) { return entries }
        // Bound the previous uncommitted archive format on first access; don't invent an
        // observation time. savedAt is explicitly the time of quarantine conversion.
        if let legacy = try? JSONDecoder().decode([String: Data].self, from: data) {
            return legacy.sorted { $0.key < $1.key }.map {
                RecoveryEntry(digest: $0.key, savedAt: clock(), byteCount: $0.value.count,
                    raw: key == Self.archiveKeys[0] && $0.value.count <= 8192 ? $0.value : nil)
            }
        }
        return nil
    }
    @discardableResult
    func pruneRecoveryArchives(removingRaw: Bool = false, retireCancelled: Bool = true) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard defaults.isAvailable else { return false }
        let failures = maintainRecoveryArchives(removingRaw: removingRaw, retireCancelled: retireCancelled)
        if !failures.isEmpty { reportMaintenanceFailures(failures) }
        return failures.isEmpty
    }
    /// No callbacks: observation writers collect failures here and deliver them only
    /// after their observation write attempt, including when that attempt fails.
    private func maintainRecoveryArchives(removingRaw: Bool, retireCancelled: Bool) -> [String] {
        guard defaults.isAvailable else { return Self.archiveKeys }
        // Metadata is written before observations. Do not retire a cancellation
        // tombstone during that pre-write phase of a deletion that may still fail.
        let removingRaw = removingRaw || defaults.data(forKey: Self.cleanupRequestKey) != nil
        let mayRetireCancelled = retireCancelled
        var failures: [String] = []
        for key in Self.archiveKeys where defaults.data(forKey: key) != nil {
            var entries = recovery(key)
            if entries == nil, removingRaw, let raw = defaults.data(forKey: key) {
                // A successful user deletion may retire an unreadable derived archive as
                // a digest-only diagnostic; it never tries to restore its unknown contents.
                entries = [RecoveryEntry(digest: ObservationProvenance.digest(raw.base64EncodedString()),
                    savedAt: clock(), byteCount: raw.count, raw: nil)]
            }
            guard let entries, let data = try? JSONEncoder().encode(bounded(entries, now: clock(),
                removingRaw: removingRaw || key == Self.archiveKeys[1], byteLimit: archiveByteLimit(key))),
                  write(data, key), defaults.data(forKey: key) == data else {
                failures.append(key)
                continue
            }
        }
        let pending = ObservationCompletionPending.load(defaults)
        if let raw = defaults.data(forKey: ObservationCompletionPending.key),
           pending == nil || (mayRetireCancelled && pending?.isCancelled == true) {
            if preserve(raw, recoveryKey: Self.archiveKeys[1]) {
                defaults.removeObject(forKey: ObservationCompletionPending.key)
                if !defaults.isAvailable || defaults.data(forKey: ObservationCompletionPending.key) != nil { failures.append(ObservationCompletionPending.key) }
            } else { failures.append(ObservationCompletionPending.key) }
        }
        let standalone = StandaloneWakePending.load(defaults)
        if let raw = defaults.data(forKey: StandaloneWakePending.key),
           standalone == nil ||
            (mayRetireCancelled && standalone?.isCancelled == true && standalone?.historical != true) {
            if preserve(raw, recoveryKey: Self.archiveKeys[1]) {
                defaults.removeObject(forKey: StandaloneWakePending.key)
                if !defaults.isAvailable || defaults.data(forKey: StandaloneWakePending.key) != nil { failures.append(StandaloneWakePending.key) }
            } else { failures.append(StandaloneWakePending.key) }
        }
        if failures.isEmpty, retireCancelled {
            defaults.removeObject(forKey: Self.cleanupRequestKey)
            if !defaults.isAvailable || defaults.data(forKey: Self.cleanupRequestKey) != nil { failures.append(Self.cleanupRequestKey) }
        }
        return failures
    }
    func preserve(_ raw: Data, recoveryKey: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard Self.archiveKeys.contains(recoveryKey), let existing = recovery(recoveryKey) else { return false }
        let digest = ObservationProvenance.digest(raw.base64EncodedString())
        var entries = existing.filter { $0.digest != digest }
        entries.append(RecoveryEntry(digest: digest, savedAt: existing.first(where: { $0.digest == digest })?.savedAt ?? clock(), byteCount: raw.count,
            raw: recoveryKey == Self.archiveKeys[0] && raw.count <= 8192 ? raw : nil))
        guard let data = try? JSONEncoder().encode(bounded(entries, now: clock(), byteLimit: archiveByteLimit(recoveryKey))), write(data, recoveryKey),
              defaults.data(forKey: recoveryKey) == data else { return false }
        return true
    }
    func journal(_ pending: ObservationCompletionPending) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try? JSONEncoder().encode(pending), write(data, ObservationCompletionPending.key),
              defaults.data(forKey: ObservationCompletionPending.key) == data else { return false }
        return true
    }
    func standaloneJournal(_ pending: StandaloneWakePending) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try? JSONEncoder().encode(pending), write(data, StandaloneWakePending.key),
              defaults.data(forKey: StandaloneWakePending.key) == data else { return false }
        return true
    }
    func updateJournal(_ pending: ObservationCompletionPending) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let current = ObservationCompletionPending.load(defaults),
              current.operationID == pending.operationID, !current.isCancelled else { return false }
        return journal(pending)
    }
    func updateJournal(_ pending: StandaloneWakePending) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let current = StandaloneWakePending.load(defaults),
              current.operationID == pending.operationID, !current.isCancelled else { return false }
        return standaloneJournal(pending)
    }
    /// Historical completion owns the lock and posts only after validating the
    /// receipt and removing its journal. Archive maintenance is a separate write.
    func publishHistoricalWake(_ value: ObservationProvenance) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return write(data, ObservationProvenance.key) && defaults.data(forKey: ObservationProvenance.key) == data
    }

    func metadata(_ value: ObservationProvenance, notify: Bool = true) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return metadata(value, notify: notify, ifStoreGeneration: defaults.generationToken)
    }

    // The caller holds the observation lock from reading the generation through the write.
    fileprivate func metadata(_ value: ObservationProvenance, notify: Bool = true, ifStoreGeneration generation: UUID?) -> Bool {
        let outcome = writeMetadata(value, generation: generation)
        if !outcome.failures.isEmpty { reportMaintenanceFailures(outcome.failures) }
        if outcome.saved && notify { Self.post(.observationProvenanceDidChange) }
        return defaults.isAvailable && defaults.generationToken == generation && outcome.saved
    }
    private func writeMetadata(_ value: ObservationProvenance, generation: UUID?) -> (saved: Bool, failures: [String]) {
        guard defaults.isAvailable, defaults.generationToken == generation else { return (false, []) }
        // Preserve malformed/unsupported metadata for local recovery before replacing it.
        // The observation arrays are never migrated or erased during this recovery.
        if let raw = defaults.data(forKey: ObservationProvenance.key), ObservationProvenance.load(defaults) == nil {
            guard preserve(raw, recoveryKey: "observationProvenanceRecovery_v1") else { return (false, []) }
        }
        guard let data = try? JSONEncoder().encode(value), writeForGeneration(data, ObservationProvenance.key, generation)
        else { return (false, []) }
        return (true, maintainRecoveryArchives(removingRaw: false, retireCancelled: false))
    }
    func save<T: Encodable>(_ records: T, key: String, provenance: ObservationProvenance, expectedData: Data?) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let generation = defaults.generationToken
        guard defaults.isAvailable, let data = try? JSONEncoder().encode(records),
              defaults.data(forKey: key) == expectedData else { return false }
        let outcome = writeMetadata(provenance, generation: generation)
        // Internal receipt/journal callbacks must not permit a stale collection write.
        let saved = defaults.isAvailable && defaults.generationToken == generation && outcome.saved && defaults.data(forKey: key) == expectedData &&
            writeForGeneration(data, key, generation)
        if !outcome.failures.isEmpty { reportMaintenanceFailures(outcome.failures) }
        if outcome.saved { Self.post(.observationProvenanceDidChange) }
        return defaults.isAvailable && defaults.generationToken == generation && saved
    }
}

/// Projects stored observations and the parent's daytime answer. Prediction authorization
/// is separate from this evidence boundary.
struct TrustedObservationAdapter {
    let defaults: any PrivateDataStore

    /// Inspects a local date without registering a coverage generation.
    func inspectDaytimeReview(for day: Date, at now: Date, calendar: Calendar = .current) -> DaytimeCoverageInspection {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let generation = defaults.generationToken
        let inspection = inspectDaytimeState(for: day, at: now, calendar: DaytimeReviewWindow.capture(calendar),
                                             storeGeneration: generation).inspection
        guard defaults.isAvailable, defaults.generationToken == generation else {
            return DaytimeCoverageInspection(day: inspection.day, blocker: .storageUnavailable)
        }
        return inspection
    }

    func prepareDaytimeReview(for day: Date, at now: Date, calendar: Calendar = .current,
                              using storage: ObservationStorage? = nil) -> DaytimeCoverageReview? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let generation = defaults.generationToken
        let calendar = DaytimeReviewWindow.capture(calendar)
        let storage = storage ?? ObservationStorage(defaults: defaults)
        guard storage.defaults === defaults,
              let initial = inspectDaytimeState(for: day, at: now, calendar: calendar,
                                                storeGeneration: generation).state,
              let review = prepareDaytimeReview(initial, calendar: calendar, using: storage, storeGeneration: generation),
              review.day == initial.window.day, review.followingWakeTime <= now else { return nil }
        return review
    }

    private func inspectDaytimeState(for day: Date, at now: Date, calendar: Calendar, storeGeneration: UUID?)
        -> (inspection: DaytimeCoverageInspection, state: DaytimeReviewState?) {
        var inspection = DaytimeCoverageInspection(day: day, blocker: .notHistorical)
        guard day.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else {
            return (inspection, nil)
        }
        let label = calendar.startOfDay(for: day)
        inspection.day = label
        guard label < calendar.startOfDay(for: now),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: label) else { return (inspection, nil) }
        let followingLabel = calendar.startOfDay(for: nextDay)
        let input = loadEvidence()
        inspection.blocker = .storageUnavailable
        guard input.readable, defaults.isAvailable, defaults.generationToken == storeGeneration,
              input.metadata != nil || defaults.object(forKey: ObservationProvenance.key) == nil
        else { return (inspection, nil) }

        let labels = DaytimeReviewLabels(day: label, followingDay: followingLabel)
        if input.metadata?.invalidatedDaytimeReviews?.contains(labels) == true { inspection.status = .invalidated }
        let evidence = input.evidence
        func boundary(on day: Date) -> (status: DaytimeCoverageInspection.Boundary, id: UUID?) {
            let candidates = evidence.wakes.filter { calendar.isDate($0.record.day, inSameDayAs: day) }
            if candidates.count > 1 { return (.init(day: day, status: .conflicting), nil) }
            let pending = input.historicalPending.map { calendar.isDate($0.wake.day, inSameDayAs: day) } == true
            guard let wake = candidates.first else {
                return (.init(day: day, status: pending ? .pending : .missing), nil)
            }
            let time = wake.record.wakeTime
            guard time.timeIntervalSinceReferenceDate.isFinite, calendar.isDate(time, inSameDayAs: day),
                  evidence.wakes.filter({ $0.record.id == wake.record.id }).count == 1,
                  !evidence.sleeps.contains(where: { $0.record.id == wake.record.id }) else {
                return (.init(day: day, status: .invalid), nil)
            }
            if time > now { return (.init(day: day, status: .future, time: time), nil) }
            guard wake.source == .verifiedObservation else {
                return (.init(day: day, status: pending ? .pending : .unverified, time: time), nil)
            }
            return (.init(day: day, status: .verified, time: time), wake.record.id)
        }
        let morning = boundary(on: label)
        let following = boundary(on: followingLabel)
        inspection.morning = morning.status
        inspection.following = following.status
        guard let morningID = morning.id, let followingID = following.id,
              let pair = DaytimeReviewWindow.canonicalWakes(morning: morningID, following: followingID,
                                                            calendar: calendar, evidence: evidence) else {
            inspection.blocker = morning.id != nil && following.id != nil ? .conflictingEvidence : .wakeBoundaries
            inspection.naps = DaytimeReviewWindow.sortedNaps(evidence.sleeps.filter {
                $0.record.kind == .dayNap && calendar.isDate($0.record.date, inSameDayAs: label)
            }).map(DaytimeCoverageReview.Nap.init)
            return (inspection, nil)
        }

        let observations = DaytimeReviewWindow.Observations(evidence.sleeps, start: pair.morning.record.wakeTime,
                                                              end: pair.following.record.wakeTime)
        inspection.hasWakeWindow = true
        inspection.naps = observations.naps.map(DaytimeCoverageReview.Nap.init)
        inspection.blocker = observations.blocker
        guard let window = DaytimeReviewWindow(morning: pair.morning, following: pair.following,
                                               calendar: calendar, observations: observations) else { return (inspection, nil) }
        guard let metadata = input.metadata, let state = DaytimeReviewState(window: window, calendar: calendar,
                                                                           evidence: evidence, metadata: metadata) else {
            inspection.blocker = .unavailableRevision
            return (inspection, nil)
        }
        switch state.coverage {
        case .incomplete: inspection.status = .incomplete
        case .confirmedComplete: inspection.status = .confirmed
        case .unknown: break
        }
        return (inspection, state)
    }

    func beginDaytimeConfirmation(morningWakeID: UUID, followingWakeID: UUID,
                                  calendar: Calendar = .current) -> DaytimeCoverageDraft? {
        prepareDaytimeReview(morningWakeID: morningWakeID, followingWakeID: followingWakeID,
                             calendar: calendar)?.draft
    }

    /// Preparing registers a generation for invalidation. Dropping the draft defers review.
    /// The presentation and its draft are projected from the same locked evidence snapshot.
    func prepareDaytimeReview(morningWakeID: UUID, followingWakeID: UUID,
                              calendar: Calendar = .current,
                              using storage: ObservationStorage? = nil) -> DaytimeCoverageReview? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let storage = storage ?? ObservationStorage(defaults: defaults)
        let calendar = DaytimeReviewWindow.capture(calendar)
        let generation = defaults.generationToken
        guard storage.defaults === defaults,
              let initial = reviewState(morning: morningWakeID, following: followingWakeID, calendar: calendar)
        else { return nil }
        return prepareDaytimeReview(initial, calendar: calendar, using: storage, storeGeneration: generation)
    }

    private func prepareDaytimeReview(_ initial: DaytimeReviewState, calendar: Calendar,
                                      using storage: ObservationStorage, storeGeneration: UUID?) -> DaytimeCoverageReview? {
        let morningWakeID = initial.window.morning.record.id
        let followingWakeID = initial.window.following.record.id
        let key = DaytimeReviewWindow.key(morningWakeID, followingWakeID)
        var metadata = initial.metadata
        var generation = metadata.coverageGenerations?[key] ??
            .init(morningWakeID: morningWakeID, followingWakeID: followingWakeID, revision: UUID())
        let current: DaytimeReviewState
        if generation.calendars?.contains(calendar) != true {
            generation.calendars = (generation.calendars ?? []) + [calendar]
            metadata.coverageGenerations = metadata.coverageGenerations ?? [:]
            metadata.coverageGenerations?[key] = generation
            // Maintenance notifications can release the lock. Re-read after registration.
            guard storage.metadata(metadata, notify: false, ifStoreGeneration: storeGeneration),
                  let registered = reviewState(morning: morningWakeID, following: followingWakeID, calendar: calendar),
                  registered.metadata.coverageGenerations?[key]?.calendars?.contains(calendar) == true
            else { return nil }
            current = registered
        } else {
            current = initial
        }
        guard defaults.isAvailable, defaults.generationToken == storeGeneration else { return nil }
        let draft = DaytimeCoverageDraft(defaults: defaults, morning: morningWakeID, following: followingWakeID,
                                        calendar: calendar, binding: current.binding, storeGeneration: storeGeneration,
                                        expectedAnswer: current.metadata.daytime[key])
        return DaytimeCoverageReview(day: current.window.day, calendar: calendar,
            morningWakeTime: current.window.morning.record.wakeTime,
            followingWakeTime: current.window.following.record.wakeTime,
            naps: current.window.naps.map(DaytimeCoverageReview.Nap.init),
            savedCoverage: current.coverage, draft: draft)
    }

    func daytimeRevisionIdentity(morningWakeID: UUID, followingWakeID: UUID,
                                 calendar: Calendar = .current) -> String? {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        return reviewState(morning: morningWakeID, following: followingWakeID, calendar: calendar)?.binding
    }

    // The caller holds the observation lock through any subsequent write.
    fileprivate func reviewState(morning: UUID, following: UUID, calendar: Calendar,
                                 matching recordedCalendar: Calendar? = nil) -> DaytimeReviewState? {
        let input = loadEvidence()
        guard input.readable, let metadata = input.metadata else { return nil }
        return DaytimeReviewState(morning: morning, following: following, calendar: calendar,
                                  evidence: input.evidence, metadata: metadata, matching: recordedCalendar)
    }

    private func loadEvidence()
        -> (evidence: LearningEvidenceSnapshot, metadata: ObservationProvenance?, readable: Bool, historicalPending: StandaloneWakePending?) {
        let generation = defaults.generationToken
        guard defaults.isAvailable else {
            return (LearningEvidenceSnapshot(sleeps: [], wakes: [], storageIsReadable: false), nil, false, nil)
        }
        let loadedSleeps = SleepRecordPersistence(defaults: defaults).load()
        let loadedWakes = DailyWakeRecordPersistence(defaults: defaults).load()
        let readable = defaults.isAvailable && (loadedSleeps != nil || defaults.object(forKey: "sleepRecords") == nil) &&
            (loadedWakes != nil || defaults.object(forKey: "dailyWakeRecords_v1") == nil)
        let sleeps = loadedSleeps ?? []
        let wakes = loadedWakes ?? []
        let metadata = ObservationProvenance.load(defaults)
        func source(_ entry: ObservationProvenance.Entry?, content: String, intents: Set<String>) -> LearningEvidenceSource {
            guard let entry, entry.content == content,
                  let source = LearningEvidenceSource(rawValue: entry.source) else { return .reconstructedLegacy }
            if source == .verifiedObservation && !intents.contains(entry.intent ?? "") {
                return .recordedUnverified
            }
            return source
        }
        let sleepEvidence = sleeps.map { r in
            LearningSleepEvidence(record: r, source: source(metadata?.sleeps[r.id.uuidString],
                                                          content: ObservationProvenance.sleepIdentity(r),
                                                          intents: r.kind == .break ? ["parent-entered-awake-break-v1"] :
                                                            ["parent-entered-sleep-boundaries-v1", "parent-confirmed-night-completion-v1"]))
        }
        let standalone = StandaloneWakePending.load(defaults)
        let wakeEvidence = wakes.map { r -> LearningWakeEvidence in
            let entry = metadata?.wakes[r.id.uuidString]
            let historicalReady = entry?.historicalWakeCalendar.map { calendar in
                (standalone == nil || standalone?.operationID != entry?.completedOperationID) &&
                    wakes.filter { calendar.isDate($0.day, inSameDayAs: r.day) }.count == 1
            } ?? true
            let wakeSource = source(historicalReady ? entry : nil, content: ObservationProvenance.wakeIdentity(r),
                                    intents: ["parent-entered-morning-wake-v1"])
            var linkedNight: UUID?
            if let link = metadata?.links[r.id.uuidString], link.wakeID == r.id,
               let night = sleeps.first(where: { $0.id == link.nightID }),
               night.kind == .nightSleep, !night.isOngoing, night.observedEnd == r.wakeTime,
               let nightEntry = metadata?.sleeps[night.id.uuidString],
               nightEntry.content == ObservationProvenance.sleepIdentity(night),
               nightEntry.revision == link.nightRevision,
               let wakeEntry = metadata?.wakes[r.id.uuidString],
               wakeEntry.content == ObservationProvenance.wakeIdentity(r),
               wakeEntry.revision == link.wakeRevision,
               wakes.filter({ (link.recordedCalendar ?? .current).isDate($0.day, inSameDayAs: r.day) }).count == 1 {
                linkedNight = night.id
            }
            return LearningWakeEvidence(record: r, source: wakeSource, completedNightID: linkedNight)
        }
        guard defaults.isAvailable, defaults.generationToken == generation else {
            return (LearningEvidenceSnapshot(sleeps: [], wakes: [], storageIsReadable: false), nil, false, nil)
        }
        let historicalPending = standalone.flatMap { $0.historical == true && !$0.isCancelled ? $0 : nil }
        return (LearningEvidenceSnapshot(sleeps: sleepEvidence, wakes: wakeEvidence, storageIsReadable: readable),
                metadata, readable, historicalPending)
    }

    func snapshot(includeDaytime: Bool = true, calendar: Calendar = .current) -> LearningEvidenceSnapshot {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        let generation = defaults.generationToken
        let input = loadEvidence()
        var evidence = input.evidence
        if includeDaytime, input.readable, let metadata = input.metadata {
            evidence.daytime = metadata.daytime.keys.sorted().compactMap { key in
                guard let saved = metadata.daytime[key],
                      key == DaytimeReviewWindow.key(saved.morningWakeID, saved.followingWakeID),
                      let state = DaytimeReviewState(morning: saved.morningWakeID, following: saved.followingWakeID,
                          calendar: calendar, evidence: input.evidence, metadata: metadata),
                      state.coverage != .unknown else { return nil }
                return LearningDaytimeEvidence(morning: state.window.morning, following: state.window.following,
                    coverage: state.coverage, source: .verifiedObservation, naps: state.window.naps)
            }
        }
        guard defaults.isAvailable, defaults.generationToken == generation else {
            return LearningEvidenceSnapshot(sleeps: [], wakes: [], storageIsReadable: false)
        }
        return evidence
    }
}

struct DaytimeReviewWindow {
    let day: LearningDay
    let followingLabel: Date
    let morning: LearningWakeEvidence
    let following: LearningWakeEvidence
    let naps: [LearningSleepEvidence]
    let breaks: [LearningSleepEvidence]

    static func capture(_ calendar: Calendar) -> Calendar {
        var captured = Calendar(identifier: calendar.identifier)
        captured.locale = calendar.locale
        let zone = calendar.timeZone
        captured.timeZone = TimeZone(identifier: zone.identifier) ?? zone
        captured.firstWeekday = calendar.firstWeekday
        captured.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return captured
    }

    static func key(_ morning: UUID, _ following: UUID) -> String {
        LearningEvidenceIdentity.pack([morning.uuidString, following.uuidString])
    }

    fileprivate var labels: DaytimeReviewLabels { .init(day: day.id, followingDay: followingLabel) }

    static func canonicalPair(in wakes: [DailyWakeRecord], morningID: UUID,
                              followingID: UUID, calendar: Calendar) -> [DailyWakeRecord]? {
        let mornings = wakes.filter { $0.id == morningID }
        let followings = wakes.filter { $0.id == followingID }
        guard mornings.count == 1, followings.count == 1,
              let morning = mornings.first, let following = followings.first,
              [morning.day, morning.wakeTime, following.day, following.wakeTime]
                .allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              morning.wakeTime < following.wakeTime else { return nil }
        let label = calendar.startOfDay(for: morning.day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: label),
              calendar.isDate(following.day, inSameDayAs: next),
              [morning, following].allSatisfy({ wake in
                  calendar.isDate(wake.day, inSameDayAs: wake.wakeTime) &&
                  wakes.filter { calendar.isDate($0.day, inSameDayAs: wake.day) }.count == 1
              }) else { return nil }
        return [morning, following]
    }

    static func affectsCoverage(_ nap: SleepRecord, start: Date, end: Date) -> Bool {
        guard nap.kind == .dayNap, nap.date < end else { return false }
        // An earlier nap without an observed end may still overlap this window.
        return nap.date >= start || (nap.observedEnd.map { $0 > start } ?? true)
    }

    static func isRelevantBreak(_ record: SleepRecord, napIDs: Set<UUID>, start: Date, end: Date) -> Bool {
        record.kind == .break && (record.parentNapID.map(napIDs.contains) == true ||
            crossesBoundary(record, start: start, end: end))
    }

    private static func crossesBoundary(_ record: SleepRecord, start: Date, end: Date) -> Bool {
        [start, end].contains { boundary in
            record.date < boundary && (record.isOngoing || (record.observedEnd ?? record.date) > boundary)
        }
    }

    fileprivate static func canonicalWakes(morning morningID: UUID, following followingID: UUID,
                                            calendar: Calendar, evidence: LearningEvidenceSnapshot)
        -> (morning: LearningWakeEvidence, following: LearningWakeEvidence)? {
        guard canonicalPair(in: evidence.wakes.map(\.record), morningID: morningID,
                                 followingID: followingID, calendar: calendar) != nil,
              let morning = evidence.wakes.first(where: { $0.record.id == morningID }),
              let following = evidence.wakes.first(where: { $0.record.id == followingID }),
              morning.source == .verifiedObservation, following.source == .verifiedObservation,
              !evidence.sleeps.contains(where: { $0.record.id == morningID || $0.record.id == followingID })
        else { return nil }
        return (morning, following)
    }

    fileprivate static func sortedNaps(_ naps: [LearningSleepEvidence]) -> [LearningSleepEvidence] {
        naps.sorted {
            $0.record.date == $1.record.date ? $0.record.id.uuidString < $1.record.id.uuidString :
                $0.record.date < $1.record.date
        }
    }

    fileprivate struct Observations {
        let naps: [LearningSleepEvidence]
        let breaks: [LearningSleepEvidence]
        let blocker: DaytimeCoverageInspection.Blocker?

        init(_ sleeps: [LearningSleepEvidence], start: Date, end: Date) {
            naps = sortedNaps(sleeps.filter { affectsCoverage($0.record, start: start, end: end) })
            let napIDs = Set(naps.map { $0.record.id })
            breaks = sleeps.filter { isRelevantBreak($0.record, napIDs: napIDs, start: start, end: end) }
            let ids = (naps + breaks).map { $0.record.id }
            if Set(ids).count != ids.count {
                blocker = .conflictingEvidence
            } else if naps.contains(where: { $0.record.observedEnd == nil }) {
                blocker = .unresolvedNap
            } else if naps.contains(where: { $0.record.date < start || ($0.record.observedEnd ?? $0.record.date) > end }) {
                blocker = .crossingNap
            } else if breaks.contains(where: { crossesBoundary($0.record, start: start, end: end) }) {
                blocker = .crossingBreak
            } else {
                blocker = nil
            }
        }
    }

    init?(morning morningID: UUID, following followingID: UUID,
          calendar: Calendar, evidence: LearningEvidenceSnapshot) {
        guard let pair = Self.canonicalWakes(morning: morningID, following: followingID, calendar: calendar,
                                              evidence: evidence) else { return nil }
        let observations = Observations(evidence.sleeps, start: pair.morning.record.wakeTime, end: pair.following.record.wakeTime)
        self.init(morning: pair.morning, following: pair.following, calendar: calendar, observations: observations)
    }

    fileprivate init?(morning: LearningWakeEvidence, following: LearningWakeEvidence, calendar: Calendar,
                      observations: Observations) {
        guard observations.blocker == nil else { return nil }
        self.morning = morning
        self.following = following
        day = LearningDay(id: calendar.startOfDay(for: morning.record.day), morningWakeID: morning.record.id,
                          followingWakeID: following.record.id, nightID: nil)
        followingLabel = calendar.startOfDay(for: following.record.day)
        naps = observations.naps
        breaks = observations.breaks
    }
}

fileprivate struct DaytimeReviewState {
    let window: DaytimeReviewWindow
    let metadata: ObservationProvenance
    let binding: String
    let coverage: LearningNapCoverage

    init?(morning: UUID, following: UUID, calendar: Calendar,
          evidence: LearningEvidenceSnapshot, metadata: ObservationProvenance,
          matching recordedCalendar: Calendar? = nil) {
        guard let window = DaytimeReviewWindow(morning: morning, following: following,
                                              calendar: calendar, evidence: evidence) else { return nil }
        self.init(window: window, calendar: calendar, evidence: evidence, metadata: metadata, matching: recordedCalendar)
    }

    init?(window: DaytimeReviewWindow, calendar: Calendar, evidence: LearningEvidenceSnapshot,
          metadata: ObservationProvenance, matching recordedCalendar: Calendar? = nil) {
        let morning = window.morning.record.id
        let following = window.following.record.id
        func matches(_ recordedCalendar: Calendar) -> Bool {
            if recordedCalendar == calendar { return true }
            guard let recorded = DaytimeReviewWindow(morning: morning, following: following,
                                                     calendar: recordedCalendar, evidence: evidence) else { return false }
            return recorded.day == window.day && recorded.followingLabel == window.followingLabel
        }
        guard recordedCalendar.map(matches) != false else { return nil }
        let key = DaytimeReviewWindow.key(morning, following)
        var parts = ["daytime-revisions-v4",
                     LearningEvidenceIdentity.date(window.day.id),
                     LearningEvidenceIdentity.date(window.followingLabel),
                     LearningDaytimeEvidence.identity(morning: window.morning, following: window.following, naps: window.naps),
                     metadata.coverageGenerations?[key]?.revision.uuidString ?? "unprepared-membership"]
        for wake in [window.morning, window.following] {
            guard let revision = metadata.wakes[wake.record.id.uuidString]?.coverageRevision else { return nil }
            parts.append(revision.uuidString)
        }
        let relevant = window.naps + window.breaks
        for sleep in relevant.sorted(by: { $0.record.id.uuidString < $1.record.id.uuidString }) {
            guard let entry = metadata.sleeps[sleep.record.id.uuidString],
                  entry.content == ObservationProvenance.sleepIdentity(sleep.record),
                  let revision = entry.coverageRevision else { return nil }
            parts.append(revision.uuidString)
        }
        self.window = window
        self.metadata = metadata
        binding = ObservationProvenance.digest(LearningEvidenceIdentity.pack(parts))
        if let saved = metadata.daytime[key], saved.binding == binding,
           saved.morningWakeID == morning, saved.followingWakeID == following,
           saved.intent == ParentDaytimeAttestation.intent,
           let recordedCalendar = saved.recordedCalendar,
           metadata.coverageGenerations?[key]?.calendars?.contains(recordedCalendar) == true,
           matches(recordedCalendar) {
            coverage = LearningNapCoverage(rawValue: saved.coverage) ?? .unknown
        } else {
            coverage = .unknown
        }
    }
}

struct DaytimeReviewLabels: Codable, Hashable {
    let day: Date
    let followingDay: Date
}

/// Read-only state, including evidence the parent can correct when a day is blocked.
struct DaytimeCoverageInspection: Equatable {
    enum Status: Equatable { case unknown, incomplete, confirmed, invalidated }
    enum Blocker: Equatable {
        case notHistorical, storageUnavailable, wakeBoundaries, conflictingEvidence
        case unresolvedNap, crossingNap, crossingBreak, unavailableRevision
    }
    struct Boundary: Equatable {
        enum Status: Equatable { case missing, conflicting, invalid, pending, unverified, future, verified }
        let day: Date
        let status: Status
        var time: Date? = nil
    }

    var day: Date
    var blocker: Blocker?
    var status: Status = .unknown
    var morning: Boundary?
    var following: Boundary?
    var naps: [DaytimeCoverageReview.Nap] = []
    var hasWakeWindow = false
}

/// Immutable presentation of the daytime review. Night linkage is evaluated separately.
struct DaytimeCoverageReview {
    struct Nap: Equatable, Identifiable {
        let id: UUID
        let start: Date
        let end: Date?
        let source: LearningEvidenceSource
        let isOngoing: Bool
        let usesLegacyDuration: Bool

        fileprivate init(_ evidence: LearningSleepEvidence) {
            id = evidence.record.id
            start = evidence.record.date
            end = evidence.record.observedEnd
            source = evidence.source
            isOngoing = evidence.record.isOngoing
            usesLegacyDuration = end != nil && evidence.record.endDate == nil
        }
    }

    let day: LearningDay
    let calendar: Calendar
    let morningWakeTime: Date
    let followingWakeTime: Date
    let naps: [Nap]
    let savedCoverage: LearningNapCoverage
    let draft: DaytimeCoverageDraft
}

extension Notification.Name {
    /// Diagnostics contain storage-key names only, never raw data or record IDs.
    static let observationRecoveryMaintenanceDidFail = Notification.Name("observationRecoveryMaintenanceDidFail")
    static let observationProvenanceDidChange = Notification.Name("observationProvenanceDidChange")
}

/// Deferral has no answer. Withdrawal is a separate action on an existing assertion.
enum ParentDaytimeAttestation: Equatable {
    case allNapsRecorded, notAllNapsRecorded

    fileprivate static let intent = "parent-attested-daytime-coverage-v1"

    fileprivate var coverage: LearningNapCoverage {
        self == .allNapsRecorded ? .confirmedComplete : .incomplete
    }
}

enum DaytimeCoverageWriteResult: Equatable {
    case committed, stale, failed
}

/// A draft carries the reviewed evidence and the exact answer it can replace.
/// Answer receipts are read and updated under the observation lock.
final class DaytimeCoverageDraft {
    private let defaults: any PrivateDataStore
    private let morning: UUID
    private let following: UUID
    private let calendar: Calendar
    private let binding: String
    private let storeGeneration: UUID?
    private var expectedAnswer: ObservationProvenance.DaytimeAttestation?

    fileprivate init(defaults: any PrivateDataStore, morning: UUID, following: UUID, calendar: Calendar, binding: String,
                     storeGeneration: UUID?, expectedAnswer: ObservationProvenance.DaytimeAttestation?) {
        self.defaults = defaults
        self.morning = morning
        self.following = following
        self.calendar = calendar
        self.binding = binding
        self.storeGeneration = storeGeneration
        self.expectedAnswer = expectedAnswer
    }

    private var key: String { DaytimeReviewWindow.key(morning, following) }
    private var storeIsCurrent: Bool { defaults.isAvailable && defaults.generationToken == storeGeneration }

    private func currentState(calendar: Calendar) -> DaytimeReviewState? {
        guard storeIsCurrent else { return nil }
        let adapter = TrustedObservationAdapter(defaults: defaults)
        guard let current = adapter.reviewState(morning: morning, following: following, calendar: calendar, matching: self.calendar),
              current.binding == binding, storeIsCurrent else { return nil }
        return current
    }

    func isCurrent(at now: Date, calendar: Calendar) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard let current = currentState(calendar: calendar) else { return false }
        return current.window.following.record.wakeTime <= now && current.metadata.daytime[key] == expectedAnswer
    }

    @discardableResult
    func submit(_ answer: ParentDaytimeAttestation, at now: Date, using storage: ObservationStorage,
                calendar: Calendar = .current) -> Bool {
        saveAnswer(answer, at: now, using: storage, calendar: calendar) == .committed
    }

    func saveAnswer(_ answer: ParentDaytimeAttestation, at now: Date, using storage: ObservationStorage,
                    calendar: Calendar) -> DaytimeCoverageWriteResult {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable else { return .failed }
        guard storage.defaults === defaults, now.timeIntervalSinceReferenceDate.isFinite,
              let current = currentState(calendar: calendar),
              current.window.following.record.wakeTime <= now,
              current.metadata.daytime[key] == expectedAnswer else { return .stale }
        var metadata = current.metadata
        let receipt = ObservationProvenance.DaytimeAttestation(morningWakeID: morning, followingWakeID: following,
            coverage: answer.coverage.rawValue, binding: binding,
            intent: ParentDaytimeAttestation.intent, recordedCalendar: self.calendar,
            answerRevision: UUID(), labels: current.window.labels)
        metadata.daytime[key] = receipt
        metadata.clearDaytimeInvalidation(current.window.labels)
        _ = storage.metadata(metadata, ifStoreGeneration: storeGeneration)
        guard defaults.isAvailable else { return .failed }
        guard let persisted = currentState(calendar: calendar) else { return .stale }
        if persisted.coverage == answer.coverage, persisted.metadata.daytime[key] == receipt {
            expectedAnswer = receipt
            return .committed
        }
        return persisted.metadata.daytime[key] == expectedAnswer ? .failed : .stale
    }

    /// Verifies the requested answer against this exact binding and current evidence.
    func verifiesPersistedAnswer(_ answer: ParentDaytimeAttestation, calendar: Calendar = .current) -> Bool {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard let current = currentState(calendar: calendar) else { return false }
        return current.coverage == answer.coverage && current.metadata.daytime[key] == expectedAnswer
    }

    @discardableResult
    func withdraw(using storage: ObservationStorage, calendar: Calendar = .current) -> Bool {
        withdrawAnswer(using: storage, calendar: calendar) == .committed
    }

    func withdrawAnswer(using storage: ObservationStorage, calendar: Calendar) -> DaytimeCoverageWriteResult {
        ObservationStorage.lock.lock()
        defer { ObservationStorage.lock.unlock() }
        guard defaults.isAvailable else { return .failed }
        guard storage.defaults === defaults, let current = currentState(calendar: calendar),
              current.metadata.daytime[key] == expectedAnswer,
              current.coverage != .unknown, let generation = current.metadata.coverageGenerations?[key]
        else { return .stale }
        var metadata = current.metadata
        metadata.rotateCoverage(key: key, generation: generation)
        metadata.clearDaytimeInvalidation(current.window.labels)
        _ = storage.metadata(metadata, ifStoreGeneration: storeGeneration)
        guard defaults.isAvailable else { return .failed }
        guard storeIsCurrent, let persisted = ObservationProvenance.load(defaults), storeIsCurrent else { return .stale }
        if persisted.daytime[key] == nil,
           persisted.coverageGenerations?[key]?.revision == metadata.coverageGenerations?[key]?.revision {
            return .committed
        }
        if let latest = currentState(calendar: calendar), latest.metadata.daytime[key] == expectedAnswer { return .failed }
        return .stale
    }
}
