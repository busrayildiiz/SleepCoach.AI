import SwiftUI

struct CurrentSleepSessionCard: View {
    let ongoingNight: SleepRecord?
    let expectedWakeTime: Date
    let nextSleepTime: Date?

    @State private var pulse = false
    @State private var starOpacity1: Double = 0.3
    @State private var starOpacity2: Double = 0.6
    @State private var starOpacity3: Double = 0.2

    private let deepPurple = Color(red: 0.18, green: 0.12, blue: 0.45)
    private let midPurple  = Color(red: 0.32, green: 0.22, blue: 0.72)
    private let lilac      = Color(red: 0.72, green: 0.65, blue: 0.98)
    private let gold       = Color(red: 1.0,  green: 0.80, blue: 0.30)

    private struct CardTheme {
        let bg: [Color]
        let border: Color
        let shadow: Color
        let label: Color
        let title: Color
        let subtitle: Color
        let ringTrack: Color
        let ringArc: [Color]
        let ringText: Color
        let mutedText: Color
        let accent: Color
        let divider: Color
        let showStars: Bool
    }

    private var shouldUseNightTheme: Bool {
        if ongoingNight?.kind == .nightSleep { return true }
        if ongoingNight == nil { return true }

        let bedHour = UserDefaults.standard.object(forKey: "typicalBedHour") as? Double ?? 19.0
        let bedMinute = UserDefaults.standard.object(forKey: "typicalBedMinute") as? Double ?? 30.0
        let bedtime = Calendar.current.date(
            bySettingHour: Int(bedHour),
            minute: Int(bedMinute),
            second: 0,
            of: Date()
        ) ?? Date()

        return Date() >= bedtime
    }

    private var theme: CardTheme {
        if shouldUseNightTheme {
            return CardTheme(
                bg: [Color(red: 0.12, green: 0.08, blue: 0.35), Color(red: 0.08, green: 0.05, blue: 0.25)],
                border: midPurple.opacity(0.4),
                shadow: deepPurple.opacity(0.6),
                label: lilac,
                title: .white,
                subtitle: gold,
                ringTrack: Color.white.opacity(0.10),
                ringArc: [gold.opacity(0.7), lilac, Color.white],
                ringText: .white,
                mutedText: lilac.opacity(0.85),
                accent: gold,
                divider: Color.white.opacity(0.08),
                showStars: true
            )
        }

        return CardTheme(
            bg: [Color(red: 0.99, green: 0.98, blue: 1.0), Color(red: 1.0, green: 0.96, blue: 0.88)],
            border: Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.18),
            shadow: Color(red: 0.45, green: 0.35, blue: 0.92).opacity(0.10),
            label: Color(red: 0.45, green: 0.35, blue: 0.86),
            title: Color(red: 0.17, green: 0.13, blue: 0.32),
            subtitle: Color(red: 0.42, green: 0.38, blue: 0.58),
            ringTrack: Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.14),
            ringArc: [Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.55), Color(red: 0.45, green: 0.35, blue: 0.92), Color(red: 1.0, green: 0.72, blue: 0.30)],
            ringText: Color(red: 0.17, green: 0.13, blue: 0.32),
            mutedText: Color(red: 0.42, green: 0.38, blue: 0.58),
            accent: Color(red: 0.45, green: 0.35, blue: 0.86),
            divider: Color(red: 0.55, green: 0.45, blue: 0.98).opacity(0.10),
            showStars: false
        )
    }

    private var startTime: Date {
        ongoingNight?.date ?? Calendar.current.date(byAdding: .hour, value: -9, to: expectedWakeTime) ?? Date()
    }

    private var elapsedMinutes: Int {
        max(0, Int(Date().timeIntervalSince(startTime) / 60))
    }

    private var sleepStateTitle: String {
        ongoingNight?.kind == .nightSleep ? "Sleeping tonight" : "Sleeping..."
    }

    private var sleepProgress: Double {
        let total = max(1, Int(expectedWakeTime.timeIntervalSince(startTime) / 60))
        return min(1.0, max(0.05, Double(elapsedMinutes) / Double(total)))
    }

    private var ringCenterText: String {
        TimeFormat.minutes(elapsedMinutes)
    }

    var body: some View {
        let t = theme
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: t.bg,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            if t.showStars {
                starsLayer
            }

            VStack(spacing: 0) {
                topRow(t)
                Divider()
                    .background(t.divider)
                    .padding(.horizontal, 16)
                bottomRow(t)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(t.border, lineWidth: 1)
        )
        .shadow(color: t.shadow, radius: 16, x: 0, y: 8)
        .onAppear {
            pulse = true
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { starOpacity1 = 0.9 }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.4)) { starOpacity2 = 0.2 }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(0.9)) { starOpacity3 = 0.8 }
        }
    }

    private func topRow(_ t: CardTheme) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(t.label)
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulse ? 1.4 : 0.8)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    Text("LIVE SLEEP SESSION")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(t.label)
                        .tracking(0.5)
                }

                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(sleepStateTitle)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(t.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.mutedText.opacity(0.75))
                    Text("Started \(ampm(startTime)) · \(TimeFormat.minutes(elapsedMinutes)) asleep")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.mutedText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                HStack(spacing: 4) {
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.accent)
                    Text("Expected wake around \(ampm(expectedWakeTime))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer()
            sleepProgressRing(t)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func sleepProgressRing(_ t: CardTheme) -> some View {
        ZStack {
            Circle()
                .stroke(t.ringTrack, lineWidth: 5)
                .frame(width: 72, height: 72)

            Circle()
                .trim(from: 0, to: sleepProgress)
                .stroke(
                    AngularGradient(colors: t.ringArc, center: .center),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .frame(width: 72, height: 72)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1.0), value: sleepProgress)

            VStack(spacing: 1) {
                Text(ringCenterText)
                    .font(.system(size: ringCenterText.count > 4 ? 12 : 15, weight: .bold, design: .rounded))
                    .foregroundStyle(t.ringText)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text("asleep")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(t.label.opacity(0.7))
            }
        }
    }

    private func bottomRow(_ t: CardTheme) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.mutedText.opacity(0.75))

                Text(nextSleepTime == nil ? "Next sleep plan" : "Next nap estimate")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            Text(nextSleepTime.map { ampm($0) } ?? "After wake")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var starsLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle().fill(Color.white).frame(width: 2.5, height: 2.5).position(x: w * 0.15, y: h * 0.22).opacity(starOpacity1)
                Circle().fill(Color.white).frame(width: 1.5, height: 1.5).position(x: w * 0.75, y: h * 0.15).opacity(starOpacity2)
                Circle().fill(Color.white).frame(width: 2, height: 2).position(x: w * 0.88, y: h * 0.40).opacity(starOpacity3)
                Circle().fill(Color.white).frame(width: 1.5, height: 1.5).position(x: w * 0.25, y: h * 0.70).opacity(starOpacity2)
                Circle().fill(Color.white).frame(width: 1, height: 1).position(x: w * 0.60, y: h * 0.25).opacity(starOpacity1)
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .position(x: w * 0.82, y: h * 0.38)
            }
        }
    }

    private func ampm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
