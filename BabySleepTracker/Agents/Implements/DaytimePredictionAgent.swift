import Foundation

// MARK: - Daytime Prediction

struct DaytimePredictionAgent {
    let nextNapTime:             Date
    let windowStart:             Date
    let windowEnd:               Date
    let expectedDurationMinutes: Int
    let wakeWindowUsed:          Int
    let confidence:              Int      // 0–94
    let mode:                    PredictionMode
    let reasoning:               [String]
    let usedDefaultWakeTime:     Bool     
}
enum PredictionMode {
    case ageBaseline      // 0–6 gün
    case blended          // 7–13 gün
    case personalized     // 14+ gün
}

// MARK: - Protocol

protocol DaytimePredictionAgentProtocol {
    func predictNextNap(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date
    ) -> DaytimePredictionAgent
}

// MARK: - DefaultDaytimePredictionAgent

final class DefaultDaytimePredictionAgent: DaytimePredictionAgentProtocol {

    private let calendar:        Calendar
    private let profileProvider: AgeBasedSleepProfileProviding

    init(
        profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(),
        calendar:        Calendar = .current
    ) {
        self.profileProvider = profileProvider
        self.calendar        = calendar
    }

    // MARK: - Predict Next Nap

    func predictNextNap(
        pattern:      BabyPattern?,
        todayRecords: [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        trackedDays:  Int,
        now:          Date
    ) -> DaytimePredictionAgent {

        let profile  = profileProvider.profile(forAgeMonths: ageMonths)
        let breaks   = todayRecords.filter { $0.kind == .break }

        let todayNaps = todayRecords
            .filter { $0.kind == .dayNap && !$0.isOngoing }
            .sorted { $0.date < $1.date }

        let ongoingNap = todayRecords.first { $0.kind == .dayNap && $0.isOngoing }

        // 1. Anchor
        let anchor = predictionAnchor(
            todayNaps:   todayNaps,
            ongoingNap:  ongoingNap,
            breaks:      breaks,
            wakeRecords: wakeRecords,
            now:         now
        )

        // 2. Wake window
        let wakeWindow = blendedWakeWindow(
            profile:     profile,
            pattern:     pattern,
            trackedDays: trackedDays
        )

        // 3. Tahmin zamanı
        let nextNapTime = anchor.time.addingMinutes(wakeWindow)

        // 4. Mod ve pencere
        let mode         = predictionMode(trackedDays: trackedDays, pattern: pattern)
        let windowRadius = windowRadius(for: mode)

        let windowStart = nextNapTime.addingMinutes(-windowRadius)
        let windowEnd   = nextNapTime.addingMinutes(windowRadius)

        // 5. Beklenen süre
        let expectedDuration = expectedNapDuration(
            profile:  profile,
            pattern:  pattern,
            napIndex: todayNaps.count
        )

        // 6. Güven skoru
        let confidence = calculateConfidence(
            mode:          mode,
            trackedDays:   trackedDays,
            hasWakeTime:   anchor.hasTodayWakeTime,
            hasPattern:    pattern != nil,
            hasOngoingNap: ongoingNap != nil
        )

        // 7. Gerekçeler
        let reasoning = buildReasoning(
            mode:          mode,
            anchor:        anchor,
            wakeWindow:    wakeWindow,
            ageMonths:     ageMonths,
            trackedDays:   trackedDays,
            hasOngoingNap: ongoingNap != nil
        )

        return DaytimePredictionAgent (
            nextNapTime:             nextNapTime,
            windowStart:             windowStart,
            windowEnd:               windowEnd,
            expectedDurationMinutes: expectedDuration,
            wakeWindowUsed:          wakeWindow,
            confidence:              confidence,
            mode:                    mode,
            reasoning:               reasoning,
            usedDefaultWakeTime:     !anchor.hasTodayWakeTime
        )
    }

    // MARK: - Anchor

    private func predictionAnchor(
        todayNaps:   [SleepRecord],
        ongoingNap:  SleepRecord?,
        breaks:      [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        now:         Date
    ) -> (time: Date, hasTodayWakeTime: Bool) {

        // Ongoing nap — bebek hâlâ uyuyor
        if let ongoing = ongoingNap {
            let elapsed      = max(0, Int(now.timeIntervalSince(ongoing.date) / 60))
            let estimatedEnd = ongoing.date.addingMinutes(max(45, elapsed + 30))
            let anchorTime   = estimatedEnd > now ? estimatedEnd : now
            return (anchorTime, true)
        }

        // Tamamlanmış son napın net bitiş saati
        if let lastNap = todayNaps.last {
            let net      = lastNap.totalMinutes(breaks: breaks)
            let duration = net > 0 ? net : lastNap.duration
            return (lastNap.date.addingMinutes(duration), true)
        }

        // Bugünün wake record'u — en son girileni kullan
        let todayWakes = wakeRecords
            .filter { calendar.isDate($0.day, inSameDayAs: now) }
            .sorted { $0.wakeTime < $1.wakeTime }

        if let latestWake = todayWakes.last {
            return (latestWake.wakeTime, true)
        }

        // Hiç kayıt yoksa — Settings'te kaydedilen "typical wake time"ı her zaman kullan.
        // "now" kullanılmaz çünkü kayıt eksikliği "şimdi uyandı" anlamına gelmez,
        // "muhtemelen typicalWake'de uyandı ama henüz loglanmadı" anlamına gelir.
        let today = calendar.startOfDay(for: now)

        let wakeHour   = UserDefaults.standard.object(forKey: "typicalWakeHour")   as? Double ?? 7.0
        let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0

        let typicalWake = calendar.date(
            bySettingHour: Int(wakeHour),
            minute:        Int(wakeMinute),
            second:        0,
            of:            today
        ) ?? now

        return (typicalWake, false)   // false = bu gerçek bir kayıt değil, varsayım
    }

    // MARK: - Blended Wake Window

    private func blendedWakeWindow(
        profile:     AgeBasedSleepProfile,
        pattern:     BabyPattern?,
        trackedDays: Int
    ) -> Int {
        let baselineCenter =
            (profile.wakeWindowRange.lowerBound + profile.wakeWindowRange.upperBound) / 2

        guard let observed = pattern?.averageWakeWindowMinutes else {
            return baselineCenter
        }

        let weight  = min(1.0, Double(trackedDays) / 14.0)
        let blended = Double(baselineCenter) * (1 - weight) + Double(observed) * weight

        let minWW = profile.wakeWindowRange.lowerBound - 30
        let maxWW = profile.wakeWindowRange.upperBound + 45
        return max(minWW, min(maxWW, Int(blended.rounded())))
    }

    // MARK: - Expected Nap Duration

    private func expectedNapDuration(
        profile:  AgeBasedSleepProfile,
        pattern:  BabyPattern?,
        napIndex: Int
    ) -> Int {
        if let avg = pattern?.averageNapDurationMinutes {
            let adjustment = napIndex > 0 ? -10 : 0
            return max(30, avg + adjustment)
        }
        return Int(Double(profile.maxSingleNapMinutes) * 0.75)
    }

    // MARK: - Prediction Mode

    private func predictionMode(
        trackedDays: Int,
        pattern:     BabyPattern?
    ) -> PredictionMode {
        switch trackedDays {
        case 0...6:  return .ageBaseline
        case 7...13: return .blended
        default:     return pattern != nil ? .personalized : .blended
        }
    }

    // MARK: - Window Radius

    private func windowRadius(for mode: PredictionMode) -> Int {
        switch mode {
        case .ageBaseline:  return 20
        case .blended:      return 15
        case .personalized: return 10
        }
    }

    // MARK: - Confidence

    private func calculateConfidence(
        mode:          PredictionMode,
        trackedDays:   Int,
        hasWakeTime:   Bool,
        hasPattern:    Bool,
        hasOngoingNap: Bool
    ) -> Int {
        var score: Int
        switch mode {
        case .ageBaseline:  score = 44 + trackedDays * 2
        case .blended:      score = 58 + (trackedDays - 7) * 2
        case .personalized: score = 76
        }
        if hasWakeTime    { score += 8 }
        if hasPattern     { score += 5 }
        if hasOngoingNap  { score -= 10 }
        return min(max(score, 0), 94)
    }

    // MARK: - Reasoning

    private func buildReasoning(
        mode:          PredictionMode,
        anchor:        (time: Date, hasTodayWakeTime: Bool),
        wakeWindow:    Int,
        ageMonths:     Int,
        trackedDays:   Int,
        hasOngoingNap: Bool
    ) -> [String] {
        var parts = [String]()

        if hasOngoingNap {
            parts.append("Baby is currently sleeping — prediction based on estimated nap end time.")
        } else if anchor.hasTodayWakeTime {
            parts.append("Calculated from today's wake-up or last nap end time.")
        } else {
            parts.append("No wake time logged today — using your saved typical wake-up time as a default.")
        }

        switch mode {
        case .ageBaseline:
            parts.append("Using age baseline for \(ageMonths)-month-old (\(wakeWindow) min wake window).")
        case .blended:
            parts.append("Blending age baseline with \(trackedDays) days of data (\(wakeWindow) min).")
        case .personalized:
            parts.append("Personalized from \(loadBabyName())'s own sleep pattern (\(wakeWindow) min).")
        }

        if trackedDays < 14 {
            let remaining = 14 - trackedDays
            parts.append("\(remaining) more tracked day\(remaining == 1 ? "" : "s") until fully personalized.")
        }

        return parts
    }

    private func loadBabyName() -> String {
        let name = UserDefaults.standard.string(forKey: "babyName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Baby" : name
    }
}
