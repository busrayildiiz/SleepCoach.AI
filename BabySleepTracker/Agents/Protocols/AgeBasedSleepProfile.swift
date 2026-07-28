//
//  AgeBasedSleepProfile.swift
//  BabySleepTracker
//

import Foundation

// MARK: - AgeBasedSleepProfile

struct AgeBasedSleepProfile {

    let ageRange: ClosedRange<Int>          // ay cinsinden

    // ── Toplam uyku (AASM 2016, AAP onaylı) ─────────────────
    let totalSleep24hRange: ClosedRange<Int> // dakika (ör. 720...960)

    // ── Wake windows (Taking Cara Babies + Huckleberry) ──────
    let wakeWindowRange: ClosedRange<Int>    // genel WW dakika
    let morningWakeWindow: ClosedRange<Int>  // günün ilk WW — her zaman en kısa
    let eveningWakeWindow: ClosedRange<Int>  // yatıştan önceki WW — her zaman en uzun

    // ── Nap yapısı ────────────────────────────────────────────
    let expectedNapCount: ClosedRange<Int>   // günlük nap sayısı aralığı
    let maxSingleNapMinutes: Int             // tek napın önerilen max süresi
    let daytimeSleepRange: ClosedRange<Int>  // hedef toplam gündüz uykusu (dk)
    let nightSleepRange: ClosedRange<Int>    // hedef gece uykusu (dk)

    // ── Bedtime ───────────────────────────────────────────────
    let bedtimeHourRange: ClosedRange<Int>   // 18...20 = 18:00–20:00 arası

    // ── Son nap cutoff ────────────────────────────────────────
    let lastNapCutoffHour: Int               // bu saatten sonra nap önerilmez
}

// MARK: - Provider Protocol

protocol AgeBasedSleepProfileProviding {
    func profile(forAgeMonths age: Int) -> AgeBasedSleepProfile
    func wakeWindowCenter(forAgeMonths age: Int) -> Int
    func eveningWakeWindowCenter(forAgeMonths age: Int) -> Int
}

// MARK: - DefaultAgeBasedSleepProfileProvider

final class DefaultAgeBasedSleepProfileProvider: AgeBasedSleepProfileProviding {

    // MARK: - Profile Lookup
        
        func profile(forAgeMonths age: Int) -> AgeBasedSleepProfile {

            let birthDate: Date?
            if let saved = UserDefaults.standard.object(forKey: "babyBirthDate") as? Date {
                birthDate = saved
            } else if let seconds = UserDefaults.standard.object(forKey: "babyBirthDate") as? Double {
                birthDate = Date(timeIntervalSince1970: seconds)
            } else {
                birthDate = nil
            }
            
            // Eğer doğum tarihi yoksa dışarıdan gelen fallback parametreyi kullan veya en son profili dön
            guard let babyBirthDate = birthDate else {
                let match = Self.profiles.first { $0.ageRange.contains(age) }
                return match ?? Self.profiles.last!
            }
            
            let calendar = Calendar.current
            let components = calendar.dateComponents([.month], from: babyBirthDate, to: Date())
            let calculatedAgeMonths = components.month ?? 0
            
            let match = Self.profiles.first { $0.ageRange.contains(calculatedAgeMonths) }
            return match ?? Self.profiles.last!
        }
        
        func wakeWindowCenter(forAgeMonths age: Int) -> Int {

            let p = profile(forAgeMonths: age)
            return (p.wakeWindowRange.lowerBound + p.wakeWindowRange.upperBound) / 2
        }
        
        func eveningWakeWindowCenter(forAgeMonths age: Int) -> Int {
            let p = profile(forAgeMonths: age)
            return (p.eveningWakeWindow.lowerBound + p.eveningWakeWindow.upperBound) / 2
        }

    // MARK: - Data Table
    // Kaynaklar:
    // • Toplam uyku: AASM 2016 (AAP onaylı) — Journal of Clinical Sleep Medicine
    // • Wake windows: Taking Cara Babies, Huckleberry, Rachel Mitchell konsensüsü

    static let profiles: [AgeBasedSleepProfile] = [

        // 4 ay
        AgeBasedSleepProfile(
            ageRange:            4...4,
            totalSleep24hRange:  720...960,    // 12–16 saat
            wakeWindowRange:     90...120,
            morningWakeWindow:   75...90,
            eveningWakeWindow:   90...120,
            expectedNapCount:    3...5,
            maxSingleNapMinutes: 120,
            daytimeSleepRange:   210...270,    // 3.5–4.5 saat
            nightSleepRange:     600...720,    // 10–12 saat
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   17
        ),

        // 5–6 ay
        AgeBasedSleepProfile(
            ageRange:            5...6,
            totalSleep24hRange:  720...900,    // 12–15 saat
            wakeWindowRange:     120...180,
            morningWakeWindow:   105...135,
            eveningWakeWindow:   150...180,
            expectedNapCount:    3...3,
            maxSingleNapMinutes: 120,
            daytimeSleepRange:   180...240,
            nightSleepRange:     600...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   17
        ),

        // 7–8 ay
        AgeBasedSleepProfile(
            ageRange:            7...8,
            totalSleep24hRange:  690...870,    // 11.5–14.5 saat
            wakeWindowRange:     150...210,
            morningWakeWindow:   150...180,
            eveningWakeWindow:   180...210,
            expectedNapCount:    2...3,        // 3→2 geçiş dönemi
            maxSingleNapMinutes: 150,
            daytimeSleepRange:   150...210,
            nightSleepRange:     600...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   16
        ),

        // 9–11 ay
        AgeBasedSleepProfile(
            ageRange:            9...11,
            totalSleep24hRange:  660...840,    // 11–14 saat
            wakeWindowRange:     180...240,
            morningWakeWindow:   180...210,
            eveningWakeWindow:   210...240,
            expectedNapCount:    2...2,
            maxSingleNapMinutes: 120,
            daytimeSleepRange:   120...180,
            nightSleepRange:     600...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   16
        ),

        // 12–14 ay
        AgeBasedSleepProfile(
            ageRange:            12...14,
            totalSleep24hRange:  660...840,
            wakeWindowRange:     210...270,
            morningWakeWindow:   210...240,
            eveningWakeWindow:   240...270,
            expectedNapCount:    1...2,        // 2→1 geçiş başlıyor
            maxSingleNapMinutes: 150,
            daytimeSleepRange:   90...150,
            nightSleepRange:     600...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   15
        ),

        // 15–18 ay
        AgeBasedSleepProfile(
            ageRange:            15...18,
            totalSleep24hRange:  660...840,
            wakeWindowRange:     270...360,
            morningWakeWindow:   270...330,
            eveningWakeWindow:   330...360,
            expectedNapCount:    1...1,
            maxSingleNapMinutes: 180,
            daytimeSleepRange:   60...120,
            nightSleepRange:     630...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   14
        ),

        // 19–24 ay
        AgeBasedSleepProfile(
            ageRange:            19...24,
            totalSleep24hRange:  660...840,
            wakeWindowRange:     300...420,
            morningWakeWindow:   300...360,
            eveningWakeWindow:   360...420,
            expectedNapCount:    1...1,
            maxSingleNapMinutes: 180,
            daytimeSleepRange:   60...90,
            nightSleepRange:     660...720,
            bedtimeHourRange:    18...20,
            lastNapCutoffHour:   14
        )
    ]
}
