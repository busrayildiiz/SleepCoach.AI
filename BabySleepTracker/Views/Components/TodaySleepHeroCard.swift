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
    @ScaledMetric(relativeTo: .body) private var readyCopyWidth: CGFloat = 162
    @State private var explainsEstimates = false

    private var warm: Bool { model.mode == .morningConfirmed || model.mode == .morningUnconfirmed }
    private var accent: Color { RecordingColor.accent }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(CoachColor.purple).frame(width: 6, height: 6)
                    Text("TODAY'S SLEEP").recordingFont(10, weight: .bold)
                }.foregroundStyle(accent)
                Spacer()
                if model.mode == .nightActive {
                    Label("Live", systemImage: "circle.fill")
                        .recordingFont(10, weight: .semibold)
                        .foregroundStyle(Color(uiColor: .systemGreen))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(CoachColor.green.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Live, confirmed ongoing night sleep")
                }
            }
            summaryRow
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.sleep.summary")

            information
            actions
            if let open = model.reviewRecord {
                if model.assessment.unresolvedRecords.count == 1 {
                    Text("\(open.kind == .nightSleep ? "Night sleep" : "Nap") end unconfirmed · Started \(time(open.date))")
                        .recordingFont(12, weight: .medium)
                        .foregroundStyle(RecordingColor.secondary)
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
        .foregroundStyle(RecordingColor.ink)
        .padding(16)
        .background {
            ZStack(alignment: .topTrailing) {
                cardShape.fill(Color(.systemBackground))
                if model.mode == .ready && colorScheme == .light {
                    cardShape.fill(.clear)
                        .overlay { Image("TodaySleepHeroCardBackground").resizable().scaledToFill() }
                        .clipShape(cardShape)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                } else {
                    cardShape.fill(LinearGradient(colors: [CoachColor.purple.opacity(0.025),
                        (warm ? CoachColor.sun : CoachColor.purple).opacity(model.mode == .nightActive ? 0.19 : 0.11)],
                        startPoint: .leading, endPoint: .topTrailing))
                }
                if model.mode != .ready && !dynamicType.isAccessibilitySize {
                    HeroSky(warm: warm, sleeping: model.mode == .napActive)
                        .frame(width: 116, height: 105).opacity(colorScheme == .dark ? 0.35 : 0.75)
                        .padding(.top, 28).accessibilityHidden(true).allowsHitTesting(false)
                }
            }
        }
        .overlay(cardShape.stroke(CoachColor.purple.opacity(0.15), lineWidth: 1))
        .shadow(color: CoachColor.purpleDeep.opacity(0.09), radius: 9, x: 0, y: 4)
        .alert("About estimates", isPresented: $explainsEstimates, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text("Estimates are guidance, not recorded sleep. Estimates may be unavailable until enough reliable sleep data is available. Routine times never confirm a wake or end a sleep session.")
        })
    }

    @ViewBuilder private var summaryRow: some View {
        if model.mode == .ready {
            if dynamicType.isAccessibilitySize {
                readySummary(artworkWidth: 0)
            } else {
                ViewThatFits(in: .horizontal) {
                    readySummary(artworkWidth: 108)
                    readySummary(artworkWidth: 84)
                    readySummary(artworkWidth: 0)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .recordingFont(25, weight: .semibold)
                    .foregroundStyle(warm ? CoachColor.sun : accent)
                    .frame(width: 42, height: 42)
                    .background((warm ? CoachColor.sun : CoachColor.purple).opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                summaryCopy
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, dynamicType.isAccessibilitySize ? 0 : 30)
            }
        }
    }

    private var summaryCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).recordingFont(21, weight: .bold, rounded: true)
            summary.recordingFont(12, weight: .medium)
                .foregroundStyle(RecordingColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readySummary(artworkWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Center the visible bed within the supplied PNG's transparent margins.
            Image("TodaySleepBed").resizable().scaledToFit()
                .frame(width: 78, height: 78)
                .offset(x: -5, y: -1)
                .frame(width: 48, height: 50)
                .clipped()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            summaryCopy
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: readyCopyWidth, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, artworkWidth > 0 ? artworkWidth + 4 : 0)
        .background(alignment: .bottomTrailing) {
            if artworkWidth > 0 {
                Image("TodaySleepZzzCloud").resizable().scaledToFit()
                    .frame(width: artworkWidth, alignment: .trailing)
                    .padding(.trailing, -5)
                    .opacity(colorScheme == .dark ? 0.55 : 0.9)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }

    private var symbol: String {
        switch model.mode {
        case .ready, .napActive: return "bed.double.fill"
        case .napCompleted: return "checkmark.circle.fill"
        case .nightActive, .bedtimeRoutine: return "moon.fill"
        case .morningConfirmed: return "sun.max.fill"
        case .morningUnconfirmed: return "sunrise.fill"
        case .likelyNext: return "sparkles"
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
            HStack(spacing: 10) {
                Image(systemName: "clock").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usual wake time").recordingFont(11)
                    Text(model.routineWake.map(time) ?? unavailable).recordingFont(15, weight: .bold, rounded: true)
                }
                Spacer(minLength: 0)
                Text("Routine").recordingFont(10, weight: .semibold).foregroundStyle(accent)
                    .padding(7).background(CoachColor.purple.opacity(0.1), in: Capsule())
            }.padding(10).background(CoachColor.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
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
    private func tile(_ title: LocalizedStringKey, value: String, symbol: String, showsInfo: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).recordingFont(10)
                Text(value).recordingFont(14, weight: .bold, rounded: true).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsInfo {
                Button { explainsEstimates = true } label: {
                    Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
                }.foregroundStyle(accent).accessibilityLabel("About estimates")
            }
        }.padding(.horizontal, 10).padding(.vertical, 5)
            .background(CoachColor.purple.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private func adaptive<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicType.isAccessibilitySize { VStack(spacing: 10, content: content) }
        else { ViewThatFits(in: .horizontal) { HStack(spacing: 8, content: content); VStack(spacing: 8, content: content) } }
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
            action("Confirm wake time", symbol: "chevron.right", id: "hero.confirmWake", primary: false, confirmWake)
            action("Add Nap", symbol: "bed.double", id: "hero.addNap", primary: false, addNap)
        case .morningConfirmed, .likelyNext:
            adaptive {
                action("Add Nap", symbol: "bed.double", id: "hero.addNap", primary: true, addNap)
                action("View today's plan", symbol: "chevron.right", id: "hero.plan", primary: false, viewPlan)
            }
        }
    }
    private func action(_ title: LocalizedStringKey, symbol: String, id: String, primary: Bool, _ perform: @escaping () -> Void) -> some View {
        let primaryStart = model.mode == .ready ? CoachColor.purpleDeep : CoachColor.purple
        return Button(action: perform) {
            Label(title, systemImage: symbol).recordingFont(13, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 10)
                .foregroundStyle(primary ? Color.white : RecordingColor.ink)
                .background {
                    Capsule().fill(LinearGradient(colors: primary ? [primaryStart, RecordingColor.actionFill] :
                        [(warm ? CoachColor.sun : CoachColor.purple).opacity(0.08), CoachColor.purple.opacity(0.035)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(Capsule().stroke(CoachColor.purple.opacity(primary ? 0 : 0.2), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

private struct HeroSky: View {
    let warm: Bool
    let sleeping: Bool
    var body: some View {
        ZStack {
            Image(systemName: warm ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 46)).foregroundStyle(CoachColor.sun.opacity(0.8))
                .offset(x: 17, y: -18)
            Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(CoachColor.sun.opacity(0.6)).offset(x: -26, y: -24)
            Image(systemName: "cloud.fill").font(.system(size: 74)).foregroundStyle(CoachColor.purple.opacity(0.11)).offset(x: 8, y: 20)
            Image(systemName: "cloud.fill").font(.system(size: 56)).foregroundStyle(Color(.systemBackground).opacity(0.85)).offset(x: -18, y: 28)
            if sleeping { Text("zZ").font(.system(size: 19, weight: .medium, design: .rounded)).foregroundStyle(CoachColor.purple.opacity(0.4)).offset(x: 26, y: -34) }
        }.clipped()
    }
}
