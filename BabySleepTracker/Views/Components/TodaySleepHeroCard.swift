import SwiftUI

struct TodaySleepHeroCard: View {
    let model: TodaySleepHeroModel
    let addNap: () -> Void
    let recordNight: () -> Void
    let endSleep: () -> Void
    let reviewEnd: (SleepRecord) -> Void
    let addBreak: () -> Void
    let viewDetails: () -> Void
    let viewPlan: () -> Void
    let confirmWake: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var readyCopyWidth: CGFloat = 157
    @State private var explainsEstimates = false

    private var warm: Bool { model.mode == .morningConfirmed || model.mode == .morningUnconfirmed }
    private var accent: Color { RecordingColor.accent }
    private var ink: Color {
        colorScheme == .dark ? .white : Color(red: 9.0 / 255, green: 9.0 / 255, blue: 19.0 / 255)
    }
    private var secondaryInk: Color {
        colorScheme == .dark ? Color(red: 160.0 / 255, green: 156.0 / 255, blue: 169.0 / 255) : RecordingColor.secondary
    }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            summaryRow
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.sleep.summary")

            information
            actions
            if let open = model.reviewRecord {
                if model.assessment.unresolvedRecords.count == 1 {
                    Text("\(open.kind == .nightSleep ? "Night sleep" : "Nap") end unconfirmed · Started \(time(open.date))")
                        .recordingFont(12, weight: .medium)
                        .foregroundStyle(secondaryInk)
                    action("Review end", symbol: "clock", id: "hero.reviewEnd", primary: false) { reviewEnd(open) }
                } else {
                    Menu {
                        ForEach(model.assessment.unresolvedRecords) { record in
                            Button("\(record.kind == .nightSleep ? "Night sleep" : "Nap") · \(time(record.date))") {
                                reviewEnd(record)
                            }
                        }
                    } label: {
                        Label("Review unconfirmed ends", systemImage: "clock")
                            .recordingFont(13, weight: .semibold)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("hero.reviewEnd")
                }
            }
        }
        .foregroundStyle(ink)
        .padding(16)
        .background { cardSurface }
        .overlay {
            cardShape.stroke(CoachColor.purple.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: CoachColor.purpleDeep.opacity(0.09), radius: 9, x: 0, y: 4)
        .alert("About estimates", isPresented: $explainsEstimates, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text("Estimates are guidance, not recorded sleep. Estimates may be unavailable until enough reliable sleep data is available. Routine times never confirm a wake or end a sleep session.")
        })
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(CoachColor.purple).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("TODAY'S SLEEP").tracking(0.1).recordingFont(10, weight: .bold)
            }
            .foregroundStyle(accent)
            Spacer()
            if model.mode == .nightActive {
                HStack(spacing: 6) {
                    Circle().frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Live").recordingFont(10, weight: .semibold)
                }
                .foregroundStyle(Color(uiColor: .systemGreen))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minWidth: 58, minHeight: 23)
                .background(CoachColor.green.opacity(0.12), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Live, confirmed ongoing night sleep")
            }
        }
        .frame(minHeight: 13)
    }

    private var cardSurface: some View {
        cardShape.fill(Color(.systemBackground))
            .overlay {
                if model.mode == .ready && colorScheme == .light {
                    Image(decorative: "TodaySleepHeroCardBackground")
                        .renderingMode(.original).resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [CoachColor.purple.opacity(0.025),
                                 (warm ? CoachColor.sun : CoachColor.purple)
                                     .opacity(model.mode == .nightActive ? 0.19 : 0.11)],
                        startPoint: .leading, endPoint: .topTrailing
                    )
                }
            }
            .clipShape(cardShape)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var summaryRow: some View {
        if model.mode == .ready && !dynamicType.isAccessibilitySize {
            ViewThatFits(in: .horizontal) {
                summaryRow(cloudWidth: 108)
                summaryRow(cloudWidth: 84)
                summaryRow(cloudWidth: 0)
            }
        } else {
            summaryRow(cloudWidth: 0)
        }
    }

    private func summaryRow(cloudWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            leadingArtwork
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title).tracking(-0.45).recordingFont(21, weight: .bold, rounded: true)
                summary.recordingFont(12, weight: .medium).foregroundStyle(secondaryInk)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(idealWidth: cloudWidth > 0 ? readyCopyWidth : nil, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, cloudWidth > 0 ? cloudWidth + 4 : 0)
        .frame(minHeight: model.mode == .ready ? 70 : 50, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if cloudWidth > 0 {
                Image(decorative: "TodaySleepZzzCloud")
                    .renderingMode(.original).resizable().scaledToFit()
                    .frame(width: cloudWidth)
                    .padding(.top, 2)
                    .padding(.trailing, -5)
                    .opacity(colorScheme == .dark ? 0.75 : 0.90)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }

    private var leadingArtwork: some View {
        let art = illustration
        return Image(decorative: art.name)
            .renderingMode(.original).resizable()
            .frame(width: art.canvasSize, height: art.canvasSize)
            .offset(art.offset)
            .frame(width: 48, height: 50)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    // The handoff sizes and offsets center each PNG's visible alpha bounds in the slot.
    private var illustration: (name: String, canvasSize: CGFloat, offset: CGSize) {
        switch model.mode {
        case .ready:
            return ("TodaySleepReadyBed", 68.477815700, CGSize(width: 2.102389078, height: -2.457337884))
        case .napActive:
            return ("TodaySleepNapActive", 62.962343096, CGSize(width: 0.527196653, height: 0.753138075))
        case .napCompleted:
            return ("TodaySleepNapCompleted", 68.300653595, CGSize(width: 0.326797386, height: 0.816993464))
        case .nightActive:
            return ("TodaySleepNightActive", 60.252252252, CGSize(width: 0.888888889, height: -1.201201201))
        case .morningConfirmed:
            return ("TodaySleepMorningConfirmed", 64.239060832, CGSize(width: 0.179295624, height: 0.870864461))
        case .morningUnconfirmed:
            return ("TodaySleepMorningUnconfirmed", 57, CGSize(width: 0.318181818, height: -0.636363636))
        case .likelyNext:
            return ("TodaySleepLikelyNext", 61.672131148, CGSize(width: 0.098360656, height: -0.639344262))
        case .bedtimeRoutine:
            return ("TodaySleepBedtimeRoutine", 58.652946679, CGSize(width: 1.005612722, height: -0.093545370))
        }
    }
    @ViewBuilder private var summary: some View {
        switch model.mode {
        case .ready:
            if model.assessment.unavailableReason == .conflict {
                Text("Review conflicting sleep or wake records.")
            } else {
                Text("Record \(model.babyName)'s first sleep of the day and follow their rhythm.")
            }
        case .napActive:
            VStack(alignment: .leading, spacing: 3) {
                if let elapsed = model.elapsedMinutes { Text("\(napLabel) · \(duration(elapsed)) elapsed since start") }
                else if let confirmed = model.confirmedAt { Text("Still sleeping confirmed at \(time(confirmed))") }
                if let start = model.record?.date { Text("Started \(time(start))") }
            }
        case .nightActive:
            if let elapsed = model.elapsedMinutes, let start = model.record?.date {
                Text("Since \(time(start)) · \(duration(elapsed)) elapsed")
            } else if let confirmed = model.confirmedAt {
                Text("Still sleeping confirmed at \(time(confirmed))")
            }
        case .napCompleted:
            VStack(alignment: .leading, spacing: 3) {
                if let net = model.netMinutes {
                    Text("\(napLabel) · \(TimeFormat.minutes(net)) net sleep")
                } else {
                    Text("\(napLabel) · Net sleep unknown")
                }
                if let start = model.record?.date, let end = model.record?.observedEnd {
                    Text("\(time(start)) – \(time(end))")
                }
            }
        case .morningConfirmed:
            if let wake = model.wakeTime { Text("\(model.babyName) woke up at \(time(wake)) today.") }
        case .morningUnconfirmed:
            Text("You haven't recorded \(model.babyName)'s wake time yet.")
        case .likelyNext:
            Text("An estimated sleep is expected soon. This is guidance, not an observed sleep session.")
        case .bedtimeRoutine:
            Text("It's around \(model.babyName)'s usual bedtime.")
        }
    }
    private var napLabel: String { model.napNumber.map { String(localized: "Nap \($0)") } ?? String(localized: "Nap") }
    private func duration(_ minutes: Int?) -> String { minutes.map(TimeFormat.minutes) ?? "—" }
    private func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDate(date, inSameDayAs: model.now) ? .omitted : .abbreviated, time: .shortened)
    }
    private var unavailable: String { String(localized: "Unavailable") }

    @ViewBuilder private var information: some View {
        switch model.mode {
        case .ready: EmptyView()
        case .bedtimeRoutine:
            tile("Usual bedtime", value: model.routineBedtime.map(time) ?? unavailable, symbol: "moon")
        case .napActive:
            tile("Estimated end", value: model.prediction(.napEnd)?.end.map(time) ?? unavailable, symbol: "clock", showsInfo: true)
        case .nightActive:
            tile("Estimated morning wake", value: model.prediction(.morningWake)?.end.map(time) ?? unavailable, symbol: "sun.max", showsInfo: true)
        case .napCompleted, .morningConfirmed:
            adaptive {
                tile("Expected wake window", value: windowText, symbol: "hourglass")
                tile(model.mode == .napCompleted ? "Likely next nap" : "Likely first nap",
                     value: model.prediction(.nextSleep)?.start.map(time) ?? unavailable, symbol: "bed.double",
                     showsInfo: model.prediction(.nextSleep) != nil)
            }
        case .morningUnconfirmed:
            tile("Usual wake time", value: model.routineWake.map(time) ?? unavailable, symbol: "clock", showsRoutine: true)
        case .likelyNext:
            if let prediction = model.prediction(.nextSleep), let start = prediction.start {
                adaptive {
                    tile("Next sleep", value: String(localized: "in \(TimeFormat.minutes(max(0, Int(start.timeIntervalSince(model.now) / 60))))"), symbol: "hourglass")
                    tile("Estimated sleep time", value: prediction.end.map { "\(time(start)) – \(time($0))" } ?? time(start), symbol: "bed.double")
                }
            }
        }
    }
    private var windowText: String {
        guard let range = model.prediction(.wakeWindow)?.wakeWindow else { return unavailable }
        return range.lowerBound == range.upperBound ? TimeFormat.minutes(range.lowerBound) :
            "\(TimeFormat.minutes(range.lowerBound))–\(TimeFormat.minutes(range.upperBound))"
    }
    private func tile(_ title: LocalizedStringKey, value: String, symbol: String,
                      showsInfo: Bool = false, showsRoutine: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 16, height: 16)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).recordingFont(10)
                Text(value).recordingFont(14, weight: .bold, rounded: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsInfo {
                Button { explainsEstimates = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17))
                        .frame(width: 30)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel("About estimates")
            } else if showsRoutine {
                Text("Routine").recordingFont(10, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(accent)
                    .padding(7)
                    .background(CoachColor.purple.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .background(CoachColor.purple.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private func adaptive<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(spacing: 8, content: content)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8, content: content)
                VStack(spacing: 8, content: content)
            }
        }
    }
    @ViewBuilder private var actions: some View {
        switch model.mode {
        case .ready: action("Add Nap", symbol: "bed.double", id: "hero.addNap", primary: true, addNap)
        case .bedtimeRoutine:
            action("Record night sleep", symbol: "moon", id: "hero.recordNight", primary: true, recordNight)
        case .napActive:
            adaptive {
                action("End Sleep", symbol: "stop.fill", id: "hero.endSleep", primary: true, endSleep)
                action("Add Break", symbol: "sun.max", id: "sleep.current.addBreak", primary: false, addBreak)
            }
        case .napCompleted: action("View details", symbol: "chevron.right", id: "hero.details", primary: false, viewDetails)
        case .nightActive:
            adaptive {
                action("End Sleep", symbol: "stop.fill", id: "hero.endSleep", primary: true, endSleep)
                action("View details", symbol: "chevron.right", id: "hero.details", primary: false, viewDetails)
            }
        case .morningUnconfirmed:
            VStack(spacing: 16) {
                action("Confirm wake time", symbol: "chevron.right", id: "hero.confirmWake", primary: false, confirmWake)
                action("Add Nap", symbol: "bed.double", id: "hero.addNap", primary: false, addNap)
            }
        case .morningConfirmed, .likelyNext:
            adaptive {
                action("Add Nap", symbol: "bed.double", id: "hero.addNap", primary: true, addNap)
                action("View today's plan", symbol: "chevron.right", id: "hero.plan", primary: false, viewPlan)
            }
        }
    }
    private func action(_ title: LocalizedStringKey, symbol: String, id: String, primary: Bool, _ perform: @escaping () -> Void) -> some View {
        let primaryStart = model.mode == .ready ? CoachColor.purpleDeep : CoachColor.purple
        let colors = primary ? [primaryStart, RecordingColor.actionFill] :
            [(warm ? CoachColor.sun : CoachColor.purple).opacity(0.08), CoachColor.purple.opacity(0.035)]
        return Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: symbol == "stop.fill" ? 11 : 15))
                    .accessibilityHidden(true)
                Text(title).recordingFont(13, weight: .semibold)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(primary ? Color.white : ink)
            .background {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                if !primary {
                    Capsule().stroke(CoachColor.purple.opacity(0.20), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
