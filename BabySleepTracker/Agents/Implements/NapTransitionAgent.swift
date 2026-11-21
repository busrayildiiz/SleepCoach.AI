//
//  NapTransitionAgent.swift
//  BabySleepTracker
//

import Foundation

// MARK: - Nap Transition Types

enum NapTransitionType {
    case threeToTwo    // ~7–8 ay
    case twoToOne      // ~13–18 ay
    case none
}

// MARK: - Transition Signal Strength

enum TransitionSignalStrength {
    case insufficient
    case none        // hiç sinyal yok
    case weak        // 1–2 sinyal, izle
    case moderate    // 3 sinyal, geçiş yaklaşıyor
    case strong      // 4+ sinyal, geçiş zamanı
}

// MARK: - Transition Assessment

struct NapTransitionAssessment {
    let transitionType:   NapTransitionType
    let signalStrength:   TransitionSignalStrength
    let signals:          [TransitionSignal]
    let recommendation:   String
    let isReadyToTransit: Bool    // strong signal + yaş uygunsa true
}

// MARK: - Individual Signal

struct TransitionSignal {
    let type:        SignalType
    let description: String
    let weight:      Int          // 1–3, sinyalin ağırlığı
}

enum SignalType {
    case napRejection          // nap reddetti
    case delayedFirstNap       // ilk nap giderek geç alınıyor
    case shortenedNightSleep   // gece uykusu kısalıyor
    case excessiveDaytimeSleep // gündüz uykusu yaş normunun üstünde
    case earlyMorningWaking    // sabah çok erken kalkıyor
    case longWakeWindow        // WW'yi rahatça aşıyor
}

// MARK: - Protocol

protocol NapTransitionAgentProtocol {
    func assess(
        records:      [SleepRecord],
        wakeRecords:  [DailyWakeRecord],
        ageMonths:    Int,
        now:          Date
    ) -> NapTransitionAssessment
}

// MARK: - DefaultNapTransitionAgent

final class DefaultNapTransitionAgent: NapTransitionAgentProtocol {
    
    private let calendar: Calendar
    private let profileProvider: AgeBasedSleepProfileProviding
    
    init(profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider(), calendar: Calendar = .current) {
        self.calendar = calendar
        self.profileProvider = profileProvider
    }
    
    // MARK: - Assess
    
    func assess(
        records:     [SleepRecord],
        wakeRecords: [DailyWakeRecord],
        ageMonths:   Int,
        now:         Date
    ) -> NapTransitionAssessment {
        
        let dayNaps = records.filter { $0.kind == .dayNap && $0.date <= now && $0.date.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.date < $1.date }
        let nights = records.filter { $0.kind == .nightSleep && $0.completedEnd(at: now) != nil }
            .sorted { $0.date < $1.date }
        let accounting = SleepAccounting(records: records, now: now, calendar: calendar)
        
        // Hangi geçiş türü bekleniyor?
        let transitionType = expectedTransition(ageMonths: ageMonths)
        
        guard transitionType != .none else {
            return NapTransitionAssessment(
                transitionType:   .none,
                signalStrength:   .none,
                signals:          [],
                recommendation:   "Şu an geçiş beklenen bir dönemde değil.",
                isReadyToTransit: false
            )
        }
        
        // Sinyalleri topla
        var signals = [TransitionSignal]()
        
        if let s = checkNapRejection(dayNaps: dayNaps, accounting: accounting) { signals.append(s) }
        if let s = checkDelayedFirstNap(dayNaps: dayNaps, now: now) { signals.append(s) }
        if let s = checkShortenedNightSleep(nights: nights, ageMonths: ageMonths, accounting: accounting) { signals.append(s) }
        if let s = checkExcessiveDaytimeSleep(dayNaps: dayNaps, accounting: accounting, ageMonths: ageMonths) { signals.append(s) }
        if let s = checkEarlyMorningWaking(wakeRecords: wakeRecords, now: now) { signals.append(s) }
        if let s = checkLongWakeWindow(dayNaps: dayNaps, wakeRecords: wakeRecords, ageMonths: ageMonths, accounting: accounting) { signals.append(s) }
        
        // Toplam ağırlık
        let recentDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        let hasCoverage = recentDays.count == 7 &&
            recentDays.allSatisfy { accounting.completedSubtotal(on: $0, kind: .dayNap).comparableMinutes != nil }
        let totalWeight    = signals.map { $0.weight }.reduce(0, +)
        let signalStrength = signals.isEmpty && !hasCoverage ? .insufficient : strength(for: totalWeight)
        let isReady        = hasCoverage && signalStrength == .strong && ageInTransitionZone(ageMonths: ageMonths, type: transitionType)
        
        let recommendation = hasCoverage ? makeRecommendation(type: transitionType, strength: signalStrength, isReady: isReady)
            : "Recording coverage is incomplete. There is insufficient evidence to recommend a nap transition."
        
        return NapTransitionAssessment(
            transitionType:   transitionType,
            signalStrength:   signalStrength,
            signals:          signals,
            recommendation:   recommendation,
            isReadyToTransit: isReady
        )
    }
    
    // MARK: - Expected Transition
    
    private func expectedTransition(ageMonths: Int) -> NapTransitionType {
        switch ageMonths {
        case 6...9: return .threeToTwo
        case 12...20:
            return .twoToOne
        default:
            return .none
        }
    }
    
    // MARK: - Signal Checks
    
    /// Son 7 günde nap reddi kaç kez oldu?
    private func checkNapRejection(
        dayNaps: [SleepRecord],
        accounting: SleepAccounting
    ) -> TransitionSignal? {
        
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: accounting.now) else { return nil }
        
        // Nap reddi = 30 dk'dan kısa nap (bebeğin karyolada uyumadığı)
        let recentNaps      = dayNaps.filter { $0.date >= weekAgo }
        let rejections = recentNaps.filter { nap in
            accounting.completedMinutes(sleepIDs: [nap.id]).map { $0 < 30 } == true
        }.count
        
        guard rejections >= 3 else { return nil }
        
        return TransitionSignal(
            type:        .napRejection,
            description: "\(rejections) recorded naps were shorter than 30 minutes in the last seven days.",
            weight:      min(rejections, 3)   // max ağırlık 3
        )
    }
    
    /// İlk nap saati giderek gecikiyor mu?
    private func checkDelayedFirstNap(
        dayNaps: [SleepRecord],
        now:     Date
    ) -> TransitionSignal? {
        
        guard let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: now) else { return nil }
        
        // Günlük ilk napları al
        let byDay = Dictionary(grouping: dayNaps.filter { $0.date >= twoWeeksAgo }) {
            calendar.startOfDay(for: $0.date)
        }
        
        let firstNapHours = byDay.values
            .compactMap { $0.sorted { $0.date < $1.date }.first }
            .sorted { $0.date < $1.date }
            .map { calendar.component(.hour, from: $0.date) * 60 + calendar.component(.minute, from: $0.date) }
        
        guard firstNapHours.count >= 6 else { return nil }
        
        // İlk yarı vs ikinci yarı karşılaştır
        let half      = firstNapHours.count / 2
        let olderAvg  = firstNapHours.prefix(half).reduce(0, +) / half
        let recentAvg = firstNapHours.suffix(half).reduce(0, +) / half
        
        // 30+ dk gecikme varsa sinyal
        guard recentAvg - olderAvg >= 30 else { return nil }
        
        let delayMinutes = recentAvg - olderAvg
        return TransitionSignal(
            type:        .delayedFirstNap,
            description: "First recorded nap starts shifted later by about \(delayMinutes) minutes.",
            weight:      2
        )
    }
    
    /// Gece uykusu kısalıyor mu?
    private func checkShortenedNightSleep(
        nights:    [SleepRecord],
        ageMonths: Int,
        accounting: SleepAccounting
    ) -> TransitionSignal? {
        
        guard nights.count >= 6 else { return nil }
        
        let profile      = profileProvider.profile(forAgeMonths: ageMonths)
        let nightTarget  = profile.nightSleepRange.lowerBound
        
        let recentDays = Set(nights.suffix(7).map { calendar.startOfDay(for: $0.date) })
        let recentNights = recentDays.compactMap { accounting.completedSubtotal(on: $0, kind: .nightSleep).comparableMinutes }
        guard recentNights.count >= 6 else { return nil }
        let recentAvg    = recentNights.reduce(0, +) / recentNights.count
        
        // Hedefin %85'inin altına düştüyse sinyal
        guard recentAvg < Int(Double(nightTarget) * 0.85) else { return nil }
        
        let deficit = nightTarget - recentAvg
        return TransitionSignal(
            type:        .shortenedNightSleep,
            description: "Gece uykusu hedefin \(deficit) dk altında.",
            weight:      2
        )
    }
    
    /// Gündüz uykusu yaş normunun üstünde mi?
    private func checkExcessiveDaytimeSleep(
        dayNaps: [SleepRecord],
        accounting: SleepAccounting,
        ageMonths: Int
    ) -> TransitionSignal? {
        
        let profile    = profileProvider.profile(forAgeMonths: ageMonths)
        let dayMax     = profile.daytimeSleepRange.upperBound
        
        
        // Son 7 günün günlük gündüz toplamları
        let byDay = Dictionary(grouping: dayNaps) {
            calendar.startOfDay(for: $0.date)
        }
        let dailyTotals = byDay.keys.compactMap {
            accounting.completedSubtotal(on: $0, kind: .dayNap).comparableMinutes
        }
        guard !dailyTotals.isEmpty else { return nil }
        let avg = dailyTotals.reduce(0, +) / dailyTotals.count
        
        guard avg > dayMax + 15 else { return nil }
        
        return TransitionSignal(
            type:        .excessiveDaytimeSleep,
            description: "Ortalama gündüz uykusu yaş normunun \(avg - dayMax) dk üstünde.",
            weight:      1
        )
    }
    
    /// Sabah çok erken kalkıyor mu? (06:00'dan önce)
    private func checkEarlyMorningWaking(
        wakeRecords: [DailyWakeRecord],
        now:         Date
    ) -> TransitionSignal? {
        
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
        
        let days = Set(wakeRecords.filter { $0.day >= weekAgo && $0.day <= now }
            .map { calendar.startOfDay(for: $0.day) })
        let recentWakes = days.compactMap {
            DailyWakeRecord.uniqueObservation(in: wakeRecords, on: $0, at: now, calendar: calendar)
        }
        let earlyWakings  = recentWakes.filter {
            calendar.component(.hour, from: $0.wakeTime) < 6
        }.count
        
        guard earlyWakings >= 3 else { return nil }
        
        return TransitionSignal(
            type:        .earlyMorningWaking,
            description: "Son 7 günde \(earlyWakings) kez 06:00'dan önce kalktı.",
            weight:      2
        )
    }
    
    /// Wake window'u rahatça aşıyor mu?
       private func checkLongWakeWindow(
           dayNaps:     [SleepRecord],
           wakeRecords: [DailyWakeRecord],
           ageMonths:   Int,
           accounting: SleepAccounting
       ) -> TransitionSignal? {

           let profile    = profileProvider.profile(forAgeMonths: ageMonths)
           let wwMax      = profile.wakeWindowRange.upperBound

           // İlk nap'tan önceki WW'leri hesapla
           var longWindows = 0
           let byDay = Dictionary(grouping: dayNaps) {
               calendar.startOfDay(for: $0.date)
           }

           for (day, naps) in byDay {
               guard let firstNap = naps.sorted(by: { $0.date < $1.date }).first,
                     let wakeRecord = DailyWakeRecord.uniqueObservation(in: wakeRecords, on: day,
                                                                       at: firstNap.date, calendar: calendar),
                     let gap = accounting.recordedAwakeMinutes(from: wakeRecord.wakeTime, until: firstNap.date)
               else { continue }

               if gap > wwMax + 15 { longWindows += 1 }
           }

           guard longWindows >= 4 else { return nil }

           return TransitionSignal(
               type:        .longWakeWindow,
               description: "Son dönemde \(longWindows) kez önerilen WW'yi rahatça aştı.",
               weight:      2
           )
       }
    // MARK: - Helpers

       private func strength(for totalWeight: Int) -> TransitionSignalStrength {
           switch totalWeight {
           case 0:      return .none
           case 1...2:  return .weak
           case 3...4:  return .moderate
           default:     return .strong
           }
       }

       private func ageInTransitionZone(
           ageMonths: Int,
           type:      NapTransitionType
       ) -> Bool {
           switch type {
           case .threeToTwo: return (6...9).contains(ageMonths)
           case .twoToOne:   return (13...20).contains(ageMonths)
           case .none:       return false
           }
       }

       private func makeRecommendation(
           type:     NapTransitionType,
           strength: TransitionSignalStrength,
           isReady:  Bool
       ) -> String {

           switch (type, strength) {
           case (.none, _):
               return "Şu an geçiş beklenen bir dönemde değil."

           case (_, .none):
               return "Geçiş sinyali yok. Mevcut nap düzenine devam et."

           case (_, .insufficient):
               return "There is insufficient evidence to assess a nap transition."

           case (_, .weak):
               return "Erken geçiş sinyalleri görülüyor. Birkaç gün daha izle."

           case (.threeToTwo, .moderate):
               return "3→2 nap geçişi yaklaşıyor. Wake window'u 15'er dk artırmayı dene."

           case (.twoToOne, .moderate):
               return "2→1 nap geçişi yaklaşıyor. İkinci napı ötelemeyi dene."

           case (.threeToTwo, .strong) where isReady:
               return "3→2 nap geçiş zamanı. İkinci napı bırak, yatışı erkene al."

           case (.twoToOne, .strong) where isReady:
               return "2→1 nap geçiş zamanı. Tek nap düzenine geç, yatışı erkene al."

           default:
               return "Geçiş sinyalleri güçleniyor. Uyku koçunuzla görüşmeyi düşünün."
           }
       }
   }
