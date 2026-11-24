import Foundation

/// Phase A only: pure evidence evaluation. No provider, persistence, entitlement, or UI activation.
struct LearningEligibilityEvaluator {
    let calendar: Calendar

    init(calendar: Calendar, timeZone: TimeZone) {
        var context = calendar
        context.timeZone = timeZone
        self.calendar = context
    }

    func evaluate(_ evidence: LearningEvidenceSnapshot, birthDate: Date, now: Date,
                  policy: LearningEligibilityPolicy?) -> LearningEligibilityEvaluation {
        let identity = evidenceIdentity(evidence, birthDate: birthDate, now: now, policy: policy)
        func result(_ status: LearningEligibilityEvaluation.Status,
                    _ reasons: [LearningEligibilityEvaluation.Reason],
                    window: DateInterval? = nil, recent: DateInterval? = nil,
                    days: [DailyDataQualityResult] = [], recentCount: Int = 0,
                    latestAge: Int? = nil) -> LearningEligibilityEvaluation {
            LearningEligibilityEvaluation(evaluatedAt: now,
                calendarIdentifier: String(describing: calendar.identifier),
                timeZoneIdentifier: calendar.timeZone.identifier, policyVersion: policy?.version,
                status: status, reasons: reasons, historicalWindow: window, recentWindow: recent,
                dailyResults: days, requiredDayCount: policy?.minimumQualifyingDays,
                recentQualifyingDayCount: recentCount, latestQualifyingDayAge: latestAge,
                evidenceIdentity: identity)
        }
        guard evidence.storageIsReadable else { return result(.invalidEvidence, [.storageUnavailable]) }
        guard let policy else { return result(.unconfiguredPolicy, [.policyUnavailable]) }
        guard policy.isConfigured else { return result(.invalidPolicy, [.policyInvalid]) }
        // Calendar operations require finite timestamps. Reject malformed explicit input before
        // invoking Foundation calendar arithmetic or interpreting any daily evidence.
        let sleepDates = evidence.sleeps.flatMap {
            [$0.record.date, $0.record.createdAt] + [$0.record.endDate].compactMap { $0 }
        }
        let wakeDates = evidence.wakes.flatMap { [$0.record.day, $0.record.wakeTime] }
        guard ([now, birthDate] + sleepDates + wakeDates).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return result(.invalidEvidence, [.invalidTimestamp])
        }
        let ageCalculator = DefaultBabyAgeCalculator(calendar: calendar)
        guard birthDate <= now,
              policy.supportedAgeMonths.contains(ageCalculator.ageInMonths(birthDate: birthDate, on: now)) else {
            return result(.unsupportedAge, [.unsupportedAge])
        }
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -policy.historicalDayCount, to: today),
              let recentStart = calendar.date(byAdding: .day, value: -policy.recentDayCount, to: today) else {
            return result(.invalidPolicy, [.policyInvalid])
        }
        let issues = integrityFindings(evidence, now: now)
        let days = (0..<policy.historicalDayCount).compactMap { offset -> DailyDataQualityResult? in
            guard let label = calendar.date(byAdding: .day, value: offset, to: first),
                  let nextLabel = calendar.date(byAdding: .day, value: 1, to: label) else { return nil }
            return evaluateDay(label, nextLabel: nextLabel, evidence: evidence, issues: issues,
                birthDate: birthDate, now: now, policy: policy)
        }
        let qualifying = days.filter(\.qualifies)
        let recentCount = qualifying.filter { $0.day.id >= recentStart }.count
        let latestAge = qualifying.last.flatMap { calendar.dateComponents([.day], from: $0.day.id, to: today).day }
        var reasons: [LearningEligibilityEvaluation.Reason] = []
        if qualifying.count < policy.minimumQualifyingDays { reasons.append(.insufficientQualifyingDays) }
        if recentCount < policy.minimumRecentQualifyingDays { reasons.append(.insufficientRecentDays) }
        if let age = latestAge {
            if age > policy.maximumLatestDayAge { reasons.append(.latestQualifyingDayTooOld) }
        } else { reasons.append(.noQualifyingDays) }
        return result(reasons.isEmpty ? .eligibleUnderPolicy : .unavailable, reasons,
            window: DateInterval(start: first, end: today), recent: DateInterval(start: recentStart, end: today),
            days: days, recentCount: recentCount, latestAge: latestAge)
    }

    private func evaluateDay(_ label: Date, nextLabel: Date, evidence: LearningEvidenceSnapshot,
                             issues: [LearningEvidenceFinding], birthDate: Date, now: Date,
                             policy: LearningEligibilityPolicy) -> DailyDataQualityResult {
        typealias Finding = LearningEvidenceFinding
        var findings: [Finding] = []
        func add(_ reason: Finding.Reason, _ dimension: Finding.Dimension = .completeness,
                 _ severity: Finding.Severity = .missingEvidence, _ ids: [UUID] = []) {
            findings.append(finding(reason, dimension, severity, ids))
        }
        // Every label requires its own observed morning, and the next local label's morning.
        // A gap is unresolved, never silently bridged into a multi-day learning cycle.
        let starts = evidence.wakes.filter { calendar.isDate($0.record.day, inSameDayAs: label) }
        let ends = evidence.wakes.filter { calendar.isDate($0.record.day, inSameDayAs: nextLabel) }
        let morning = starts.count == 1 ? starts.first : nil
        let following = ends.count == 1 ? ends.first : nil
        if starts.isEmpty { add(.missingMorningWake) }
        if ends.isEmpty { add(.missingFollowingWake) }
        if starts.count > 1 || ends.count > 1 {
            add(.ambiguousOwnership, .coherence, .blockingIntegrity, (starts + ends).map { $0.record.id })
        }
        let start = morning?.record.wakeTime ?? label
        let end = following?.record.wakeTime ?? nextLabel
        if end <= start { add(.ambiguousOwnership, .coherence, .blockingIntegrity) }
        let records = evidence.sleeps.map(\.record)
        // Chronology owns learning evidence. Accounting's start-date ownership is untouched.
        let sleeps = records.filter { record in
            guard record.kind != .break else { return false }
            return (record.date >= start && record.date < end) ||
                (record.date < start && (record.observedEnd ?? (record.isOngoing ? now : record.date)) > start)
        }
        let sleepIDs = Set(sleeps.map(\.id))
        let breaks = records.filter {
            $0.kind == .break && ($0.parentNapID.map(sleepIDs.contains) == true || ($0.date >= start && $0.date < end))
        }
        let naps = sleeps.filter { $0.kind == .dayNap }
        let nights = sleeps.filter { $0.kind == .nightSleep }
        let night = nights.count == 1 ? nights.first : nil
        if nights.isEmpty { add(.missingNightOnset) }
        if nights.count > 1 { add(.ambiguousOwnership, .coherence, .blockingIntegrity, nights.map(\.id)) }
        for sleep in sleeps {
            if sleep.date < start || sleep.observedEnd.map({ $0 > end }) == true {
                add(.ambiguousOwnership, .coherence, .blockingIntegrity, [sleep.id])
            }
            if let observedEnd = sleep.observedEnd, observedEnd <= now,
               SleepAccounting.netIntervals(records: records, now: now, sleepIDs: Set([sleep.id])).isEmpty {
                // A fully awake interval contains no observed sleep. This is a structural check,
                // not a minimum pediatric duration; positive subminute sleep remains representable.
                add(.invalidDuration, .coherence, .blockingIntegrity, [sleep.id])
            }
        }
        // A link describes the preceding cycle, not the independently confirmed next morning.
        // Scope link validation to this cycle's following wake; don't require out-of-window nights.
        if let following, let linkedID = following.completedNightID {
            let linkedNights = records.filter { $0.id == linkedID && $0.kind == .nightSleep }
            if linkedNights.count != 1 || linkedNights.first?.observedEnd != following.record.wakeTime {
                add(.wakeNightMismatch, .consistency, .blockingIntegrity, [following.record.id, linkedID])
            }
        }
        if let night {
            if naps.contains(where: { ($0.observedEnd ?? $0.date) > night.date }) {
                add(.ambiguousOwnership, .coherence, .blockingIntegrity, naps.map(\.id) + [night.id])
            }
            if let following {
                if let observedEnd = night.observedEnd, observedEnd != following.record.wakeTime {
                    add(.wakeNightMismatch, .consistency, .blockingIntegrity, [night.id, following.record.id])
                }
                if following.completedNightID != night.id {
                    add(.unverifiedNightWakeLink, .coherence, .missingEvidence, [night.id, following.record.id])
                }
            }
        }
        let confirmations = evidence.daytime.filter {
            $0.morningWakeID == morning?.record.id && $0.followingWakeID == following?.record.id
        }
        var coverage: LearningNapCoverage = .unknown
        if confirmations.count == 1, let confirmation = confirmations.first {
            coverage = confirmation.coverage
            if confirmation.source != .verifiedObservation {
                add(.unverifiedSource, .completeness, .missingEvidence, [confirmation.morningWakeID, confirmation.followingWakeID])
            }
            if confirmation.coverage == .confirmedComplete, let morning, let following {
                let napEvidence = evidence.sleeps.filter { $0.record.kind == .dayNap && sleepIDs.contains($0.record.id) }
                let currentIdentity = LearningDaytimeEvidence.identity(morning: morning, following: following, naps: napEvidence)
                if confirmation.confirmedEvidenceIdentity != currentIdentity {
                    add(.staleNapConfirmation, .consistency, .blockingIntegrity, naps.map(\.id) +
                        [morning.record.id, following.record.id])
                }
            }
            if confirmation.napIDs != Set(naps.map(\.id)) {
                add(.staleNapConfirmation, .consistency, .blockingIntegrity, Array(confirmation.napIDs) + naps.map(\.id))
            }
        } else if confirmations.count > 1 {
            add(.ambiguousOwnership, .coherence, .blockingIntegrity)
        }
        switch coverage {
        case .unknown: add(.unknownNapCoverage)
        case .incomplete: add(.incompleteNapCoverage)
        case .confirmedComplete: break
        }
        let ids = Set(sleeps.map(\.id) + breaks.map(\.id) + (starts + ends).map { $0.record.id })
        findings += issues.filter { issue in issue.observationIDs.contains(where: ids.contains) }
        let age = DefaultBabyAgeCalculator(calendar: calendar).ageInMonths(birthDate: birthDate, on: morning?.record.wakeTime ?? label)
        if birthDate > start || !policy.supportedAgeMonths.contains(age) { add(.unsupportedHistoricalAge) }
        return DailyDataQualityResult(
            day: LearningDay(id: label, morningWakeID: morning?.record.id,
                             followingWakeID: following?.record.id, nightID: night?.id),
            ageMonths: age, napCoverage: coverage, observationIDs: sortedIDs(Array(ids)),
            netSleepSeconds: findings.contains(where: { $0.severity == .blockingIntegrity }) ? nil :
                SleepAccounting.netIntervals(records: records, now: now, sleepIDs: sleepIDs)
                    .reduce(0) { $0 + $1.duration }, findings: sortedFindings(findings))
    }

    private func integrityFindings(_ evidence: LearningEvidenceSnapshot, now: Date) -> [LearningEvidenceFinding] {
        typealias Finding = LearningEvidenceFinding
        var findings: [Finding] = []
        func add(_ reason: Finding.Reason, _ ids: [UUID],
                 _ dimension: Finding.Dimension = .consistency,
                 _ severity: Finding.Severity = .blockingIntegrity) {
            findings.append(finding(reason, dimension, severity, ids))
        }
        let records = evidence.sleeps.map(\.record)
        for item in evidence.sleeps {
            let record = item.record
            let ids = [record.id]
            if item.source != .verifiedObservation { add(.unverifiedSource, ids, .completeness, .missingEvidence) }
            if record.duration < 0 || record.endDate.map({ $0 <= record.date }) == true { add(.invalidDuration, ids) }
            if record.isOngoing { add(.ongoingSession, ids, .completeness, .missingEvidence) }
            if record.observedEnd == nil { add(.missingCompletedEnd, ids, .completeness, .missingEvidence) }
            if !record.isOngoing && record.endDate == nil && record.observedEnd != nil {
                add(.legacyEndUnverified, ids, .completeness, .missingEvidence)
            }
            if record.date > now || record.endDate.map({ $0 > now }) == true { add(.futureObservation, ids) }
            if record.kind == .break {
                let parents = records.filter { $0.id == record.parentNapID }
                if parents.isEmpty { add(.orphanBreak, ids, .coherence) }
                else if parents.count != 1 || parents[0].kind == .break || parents[0].parentNapID != nil {
                    add(.invalidParent, ids + parents.map(\.id), .coherence)
                } else {
                    let parent = parents[0]
                    if record.date < parent.date || record.observedEnd.flatMap({ end in parent.observedEnd.map { end > $0 } }) == true {
                        add(.invalidParent, ids + [parent.id], .coherence)
                    }
                }
            } else if record.parentNapID != nil { add(.invalidParent, ids, .coherence) }
        }
        // Compare every pair, including nested intervals; adjacency-only detection is insufficient.
        for (index, first) in records.enumerated() {
            for second in records.dropFirst(index + 1) {
                let ids = [first.id, second.id]
                if first.id == second.id { add(.duplicateIdentity, ids) }
                if first.kind == second.kind && first.date == second.date &&
                    first.observedEnd == second.observedEnd && first.parentNapID == second.parentNapID {
                    add(.duplicateEvent, ids)
                }
                let firstEnd = first.observedEnd ?? (first.isOngoing ? now : first.date)
                let secondEnd = second.observedEnd ?? (second.isOngoing ? now : second.date)
                if first.kind != .break && second.kind != .break &&
                    first.date < secondEnd && second.date < firstEnd { add(.overlappingSleep, ids) }
                // Attached awake intervals may overlap; existing accounting subtracts their union.
                if first.kind == .break && second.kind == .break && first.parentNapID == second.parentNapID &&
                    first.date < secondEnd && second.date < firstEnd {
                    add(.overlappingAwakeIntervals, ids, .consistency, .warning)
                }
                if first.kind == .break && second.kind == .break && first.parentNapID != second.parentNapID &&
                    first.date < secondEnd && second.date < firstEnd { add(.invalidParent, ids, .coherence) }
            }
        }
        for (index, item) in evidence.wakes.enumerated() {
            let wake = item.record
            if records.contains(where: { $0.id == wake.id }) { add(.duplicateIdentity, [wake.id]) }
            if item.source != .verifiedObservation { add(.unverifiedSource, [wake.id], .completeness, .missingEvidence) }
            if wake.wakeTime > now { add(.futureObservation, [wake.id]) }
            if !calendar.isDate(wake.day, inSameDayAs: wake.wakeTime) { add(.invalidWakeDay, [wake.id]) }
            for other in evidence.wakes.dropFirst(index + 1) {
                if wake.id == other.record.id { add(.duplicateIdentity, [wake.id]) }
                if wake.wakeTime == other.record.wakeTime { add(.duplicateEvent, [wake.id, other.record.id]) }
            }
        }
        return findings
    }

    private func finding(_ reason: LearningEvidenceFinding.Reason,
                         _ dimension: LearningEvidenceFinding.Dimension,
                         _ severity: LearningEvidenceFinding.Severity, _ ids: [UUID]) -> LearningEvidenceFinding {
        LearningEvidenceFinding(dimension: dimension, severity: severity, reason: reason,
                                observationIDs: sortedIDs(Array(Set(ids))))
    }

    private func sortedIDs(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }

    private func sortedFindings(_ findings: [LearningEvidenceFinding]) -> [LearningEvidenceFinding] {
        var result: [LearningEvidenceFinding] = []
        for item in findings.sorted(by: {
            let left = [$0.dimension.rawValue, $0.severity.rawValue, $0.reason.rawValue] + $0.observationIDs.map(\.uuidString)
            let right = [$1.dimension.rawValue, $1.severity.rawValue, $1.reason.rawValue] + $1.observationIDs.map(\.uuidString)
            return left.lexicographicallyPrecedes(right)
        }) where !result.contains(item) { result.append(item) }
        return result
    }

    private func evidenceIdentity(_ evidence: LearningEvidenceSnapshot, birthDate: Date, now: Date,
                                  policy: LearningEligibilityPolicy?) -> String {
        func pack(_ values: [String]) -> String { LearningEvidenceIdentity.pack(values) }
        func date(_ value: Date) -> String { LearningEvidenceIdentity.date(value) }
        let sleeps = evidence.sleeps.map { LearningEvidenceIdentity.sleep($0) }.sorted()
        let wakes = evidence.wakes.map { LearningEvidenceIdentity.wake($0) }.sorted()
        let confirmations = evidence.daytime.map {
            pack([$0.morningWakeID.uuidString, $0.followingWakeID.uuidString, $0.coverage.rawValue,
                  $0.source.rawValue, pack($0.napIDs.map(\.uuidString).sorted()),
                  $0.confirmedEvidenceIdentity ?? "nil"])
        }.sorted()
        let policyParts = policy.map {
            [$0.version, String($0.minimumQualifyingDays), String($0.historicalDayCount),
             String($0.recentDayCount), String($0.minimumRecentQualifyingDays), String($0.maximumLatestDayAge),
             String($0.supportedAgeMonths.lowerBound), String($0.supportedAgeMonths.upperBound)]
        } ?? ["unconfigured"]
        return pack([evidence.storageIsReadable ? "learning-evidence-v2" : "learning-evidence-unreadable-v1", date(birthDate), date(now), String(describing: calendar.identifier),
                     calendar.timeZone.identifier, calendar.locale?.identifier ?? "nil",
                     String(calendar.firstWeekday), String(calendar.minimumDaysInFirstWeek),
                     pack(policyParts), pack(sleeps), pack(wakes), pack(confirmations)])
    }
}
