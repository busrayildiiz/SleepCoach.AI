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
        
        let breaks  = records.filter { $0.kind == .break }
        let dayNaps = records.filter { $0.kind == .dayNap }.sorted { $0.date < $1.date }
        let nights  = records.filter { $0.kind == .nightSleep }.sorted { $0.date < $1.date }
        
        // Hangi geçiş türü bekleniyor?
        let transitionType = expectedTransition(ageMonths: ageMonths, dayNaps: dayNaps)
        
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
        
        if let s = checkNapRejection(dayNaps: dayNaps, now: now) { signals.append(s) }
        if let s = checkDelayedFirstNap(dayNaps: dayNaps, now: now) { signals.append(s) }
        if let s = checkShortenedNightSleep(nights: nights, ageMonths: ageMonths, breaks: breaks, now: now) { signals.append(s) }
        if let s = checkExcessiveDaytimeSleep(dayNaps: dayNaps, breaks: breaks, ageMonths: ageMonths, now: now) { signals.append(s) }
        if let s = checkEarlyMorningWaking(wakeRecords: wakeRecords, now: now) { signals.append(s) }
        if let s = checkLongWakeWindow(dayNaps: dayNaps, wakeRecords: wakeRecords, ageMonths: ageMonths) { signals.append(s) }
        
        // Toplam ağırlık
        let totalWeight    = signals.map { $0.weight }.reduce(0, +)
        let signalStrength = strength(for: totalWeight)
        let isReady        = signalStrength == .strong && ageInTransitionZone(ageMonths: ageMonths, type: transitionType)
        
        let recommendation = makeRecommendation(
            type:     transitionType,
            strength: signalStrength,
            isReady:  isReady
        )
        
        return NapTransitionAssessment(
            transitionType:   transitionType,
            signalStrength:   signalStrength,
            signals:          signals,
            recommendation:   recommendation,
            isReadyToTransit: isReady
        )
    }
    
    // MARK: - Expected Transition
    
    private func expectedTransition(
        ageMonths: Int,
        dayNaps:   [SleepRecord]
    ) -> NapTransitionType {
        
        // Son 7 günün ortalama nap sayısına bak
        let recentNapCount = averageNapCountLastWeek(dayNaps: dayNaps)
        
        switch ageMonths {
        case 6...9:
            // Ortalama nap sayısı 3'e yakınsa 3→2 geçiş bakıyoruz
            if let count = recentNapCount, count >= 2.5 {
                return .threeToTwo
            }
            return .threeToTwo   // bu yaşta default beklenti
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
        now:     Date
    ) -> TransitionSignal? {
        
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
        
        // Nap reddi = 30 dk'dan kısa nap (bebeğin karyolada uyumadığı)
        let recentNaps      = dayNaps.filter { $0.date >= weekAgo }
        let rejections      = recentNaps.filter { $0.duration < 30 }.count
        
        guard rejections >= 3 else { return nil }
        
        return TransitionSignal(
            type:        .napRejection,
            description: "Son 7 günde \(rejections) kez nap reddi görüldü.",
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
            description: "İlk nap saati son 2 haftada ~\(delayMinutes) dk gecikti.",
            weight:      2
        )
    }
    
    /// Gece uykusu kısalıyor mu?
    private func checkShortenedNightSleep(
        nights:    [SleepRecord],
        ageMonths: Int,
        breaks:    [SleepRecord],
        now: Date
    ) -> TransitionSignal? {
        
        guard nights.count >= 6 else { return nil }
        
        let profile      = profileProvider.profile(forAgeMonths: ageMonths)
        let nightTarget  = profile.nightSleepRange.lowerBound
        
        let recentNights = nights.suffix(7).map { $0.totalMinutes(breaks: breaks, at: now) }
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
        dayNaps:   [SleepRecord],
        breaks:    [SleepRecord],
        ageMonths: Int,
        now: Date
    ) -> TransitionSignal? {
        
        let profile    = profileProvider.profile(forAgeMonths: ageMonths)
        let dayMax     = profile.daytimeSleepRange.upperBound
        
        
        // Son 7 günün günlük gündüz toplamları
        let byDay = Dictionary(grouping: dayNaps) {
            calendar.startOfDay(for: $0.date)
        }
        let dailyTotals = byDay.values.map { naps in
            SleepAccounting.netMinutes(records: naps + breaks, now: now)
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
        
        let recentWakes   = wakeRecords.filter { $0.day >= weekAgo }
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
           ageMonths:   Int
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
                     let wakeRecord = wakeRecords.first(where: {
                         calendar.isDate($0.day, inSameDayAs: day)
                     })
               else { continue }

               let ww = Int(firstNap.date.timeIntervalSince(wakeRecord.wakeTime) / 60)
               if ww > wwMax + 15 { longWindows += 1 }
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

       private func averageNapCountLastWeek(dayNaps: [SleepRecord]) -> Double? {
           let byDay = Dictionary(grouping: dayNaps) {
               calendar.startOfDay(for: $0.date)
           }
           guard !byDay.isEmpty else { return nil }
           let total = byDay.values.map { $0.count }.reduce(0, +)
           return Double(total) / Double(byDay.count)
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
