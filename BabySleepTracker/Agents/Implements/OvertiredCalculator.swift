//
//  OvertiredCalculator.swift
//  BabySleepTracker
//

import Foundation

// MARK: - Overtired Risk

enum OvertiredRisk: Equatable {
    case healthy           // WW içinde, sorun yok
    case slightlyTired     // WW'nin %90'ına gelindi, dikkat
    case moderate          // WW aşıldı, yakında yatırılmalı
    case significant       // WW ciddi aşıldı
    case criticallyTired   // Kortizol devrede, acil yatış
}

// MARK: - Bedtime Window

struct BedtimeWindow {
    let earliest: Date       // overtired olmadan en erken yatış
    let ideal: Date          // en iyi yatış saati
    let latest: Date         // bu saatten geç kalma
    let overtiredRisk: Date  // bu saatten sonra kritik
    let risk: OvertiredRisk
    let reasoning: String
}

// MARK: - OvertiredCalculator

final class OvertiredCalculator {

    private let calendar = Calendar.current
    private let profileProvider: AgeBasedSleepProfileProviding

    init(profileProvider: AgeBasedSleepProfileProviding = DefaultAgeBasedSleepProfileProvider()) {
        self.profileProvider = profileProvider
    }

    // MARK: - Overtired Risk

    /// Bebeğin şu an ne kadar süredir uyanık olduğuna ve
    /// yaşına göre overtired riskini hesaplar.
    func overtiredRisk(
        awakeSinceDate: Date,
        ageMonths: Int,
        isEveningPeriod: Bool,
        now: Date = Date()
    ) -> OvertiredRisk {

        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let awakenMinutes = Int(now.timeIntervalSince(awakeSinceDate) / 60)

        // Akşam mı, gündüz mü? — farklı WW kullan
        let wwRange = isEveningPeriod
            ? profile.eveningWakeWindow
            : profile.wakeWindowRange

        let wwMax    = wwRange.upperBound
        let wwCenter = (wwRange.lowerBound + wwRange.upperBound) / 2

        switch awakenMinutes {
        case ..<wwCenter:
            // Henüz WW'nin ortasına bile gelmedi
            return .healthy
        case wwCenter..<wwMax:
            // WW'nin son çeyreğine yaklaşıyor
            let progress = Double(awakenMinutes - wwCenter) / Double(wwMax - wwCenter)
            return progress > 0.7 ? .slightlyTired : .healthy
        case wwMax..<(wwMax + 20):
            return .moderate
        case (wwMax + 20)..<(wwMax + 45):
            return .significant
        default:
            return .criticallyTired
        }
    }

    // MARK: - Bedtime Window

    /// Son nap bitiş saati + yaşa göre akşam WW = bedtime window
    ///
    /// Örnek: 9 aylık bebek, son nap 15:30'da bitti
    /// Akşam WW: 210–240 dk → ideal yatış: 18:45–19:30
    func bedtimeWindow(
        lastNapEndTime: Date,
        totalDaytimeSleepMinutes: Int,
        ageMonths: Int,
        now: Date = Date()
    ) -> BedtimeWindow {

        let profile  = profileProvider.profile(forAgeMonths: ageMonths)
        let ewwMin   = profile.eveningWakeWindow.lowerBound
        let ewwMax   = profile.eveningWakeWindow.upperBound
        let ewwIdeal = (ewwMin + ewwMax) / 2

        // Temel hesap: son nap bitişi + akşam WW
        let earliest = lastNapEndTime.addingMinutes(ewwMin)
        let ideal    = lastNapEndTime.addingMinutes(ewwIdeal)
        let latest   = lastNapEndTime.addingMinutes(ewwMax)
        let critical = lastNapEndTime.addingMinutes(ewwMax + 20)

        // Gündüz uykusu eksikse yatışı erkene al
        // Kural: her 3 dk eksik gündüz uykusu = 1 dk erken yatış
        let daytimeDeficit = max(0, profile.daytimeSleepRange.lowerBound - totalDaytimeSleepMinutes)
        let adjustment     = daytimeDeficit / 3

        let adjustedEarliest = earliest.addingMinutes(-adjustment)
        let adjustedIdeal    = ideal.addingMinutes(-adjustment)
        let adjustedLatest   = latest   // latest'i öteleme — bu sınır sabit

        // Şu anki risk
        let risk = overtiredRisk(
            awakeSinceDate: lastNapEndTime,
            ageMonths: ageMonths,
            isEveningPeriod: true,
            now: now
        )

        // Anneye gösterilecek açıklama
        let reasoning = makeReasoning(
            lastNapEnd:        lastNapEndTime,
            idealBedtime:      adjustedIdeal,
            ewwMinutes:        ewwIdeal - adjustment,
            daytimeDeficit:    daytimeDeficit,
            adjustment:        adjustment,
            ageMonths:         ageMonths
        )

        return BedtimeWindow(
            earliest:     adjustedEarliest,
            ideal:        adjustedIdeal,
            latest:       adjustedLatest,
            overtiredRisk: critical,
            risk:         risk,
            reasoning:    reasoning
        )
    }

    // MARK: - Last Nap Cutoff

    /// Bu saatten sonra nap başlarsa gece uykusunu bozar
    func lastNapCutoffTime(ageMonths: Int, on date: Date = Date()) -> Date {
        let profile    = profileProvider.profile(forAgeMonths: ageMonths)
        let cutoffHour = profile.lastNapCutoffHour
        return calendar.date(
            bySettingHour:   cutoffHour,
            minute:          0,
            second:          0,
            of:              date
        ) ?? date
    }

    // MARK: - Daily Sleep Check

    /// Bebeğin bugünkü toplam uykusu AAP normunun neresinde?
    func dailySleepStatus(
        totalMinutes: Int,
        ageMonths: Int
    ) -> DailySleepStatus {

        let profile = profileProvider.profile(forAgeMonths: ageMonths)
        let range   = profile.totalSleep24hRange

        if totalMinutes < range.lowerBound {
            let deficit = range.lowerBound - totalMinutes
            return .below(deficitMinutes: deficit)
        } else if totalMinutes > range.upperBound {
            let excess = totalMinutes - range.upperBound
            return .above(excessMinutes: excess)
        } else {
            return .onTrack
        }
    }

    // MARK: - Private Helpers

    private func makeReasoning(
        lastNapEnd:     Date,
        idealBedtime:   Date,
        ewwMinutes:     Int,
        daytimeDeficit: Int,
        adjustment:     Int,
        ageMonths:      Int
    ) -> String {

        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"

        var parts = [String]()
        parts.append("Son nap \(formatter.string(from: lastNapEnd))'de bitti.")
        parts.append("\(ageMonths) aylık için akşam uyanıklık penceresi ~\(ewwMinutes) dk.")

        if adjustment > 0 {
            parts.append("Gündüz uykusu \(daytimeDeficit) dk eksik — yatış \(adjustment) dk öne alındı.")
        }

        parts.append("İdeal yatış: \(formatter.string(from: idealBedtime)).")
        return parts.joined(separator: " ")
    }
}

// MARK: - Daily Sleep Status

enum DailySleepStatus: Equatable {
    case onTrack
    case below(deficitMinutes: Int)
    case above(excessMinutes: Int)

    var label: String {
        switch self {
        case .onTrack:
            return "Günlük uyku hedefte ✓"
        case .below(let deficit):
            return "Günlük uyku \(TimeFormat.minutes(deficit)) eksik"
        case .above(let excess):
            return "Günlük uyku \(TimeFormat.minutes(excess)) fazla"
        }
    }
}
