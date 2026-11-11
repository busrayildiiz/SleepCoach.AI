import SwiftUI

/// Presentation geometry only. The accounting engine remains the source of net intervals.
struct RecordingIntervalPresentation {
    enum Kind: Equatable { case sleep, awake, proposedAwake }
    struct Segment: Identifiable {
        let id: Int
        let startFraction: Double
        let endFraction: Double
        let kind: Kind
    }

    let segments: [Segment]
    let netMinutes: Int

    init?(parent: SleepRecord, existing: [SleepRecord], proposed: SleepRecord?,
          editingID: UUID? = nil, now: Date) {
        guard parent.kind != .break, !parent.isOngoing,
              let end = parent.observedEnd, end <= now, end > parent.date else { return nil }
        let window = DateInterval(start: parent.date, end: end)
        let attached = existing.filter {
            $0.kind == .break && $0.parentNapID == parent.id && $0.id != editingID
        }
        let candidate = proposed.flatMap { record -> SleepRecord? in
            guard record.kind == .break, record.parentNapID == parent.id,
                  !record.isOngoing, record.observedEnd != nil else { return nil }
            return record
        }
        let records = [parent] + attached + (candidate.map { [$0] } ?? [])
        let sleeps = SleepAccounting.netIntervals(records: records, now: now, sleepIDs: [parent.id])
        netMinutes = SleepAccounting.netMinutes(records: records, now: now, sleepIDs: [parent.id])

        var selected: DateInterval?
        if let candidate, let candidateEnd = candidate.observedEnd {
            let low = max(candidate.date, window.start)
            let high = min(candidateEnd, window.end)
            if high > low { selected = DateInterval(start: low, end: high) }
        }
        var boundaries = Set([window.start, window.end])
        for interval in sleeps {
            boundaries.insert(interval.start)
            boundaries.insert(interval.end)
        }
        if let selected {
            boundaries.insert(selected.start)
            boundaries.insert(selected.end)
        }
        let ordered = boundaries.sorted()
        segments = zip(ordered, ordered.dropFirst()).enumerated().map { index, pair in
            let midpoint = pair.0.addingTimeInterval(pair.1.timeIntervalSince(pair.0) / 2)
            let kind: Kind
            if selected?.contains(midpoint) == true { kind = .proposedAwake }
            else if sleeps.contains(where: { $0.contains(midpoint) }) { kind = .sleep }
            else { kind = .awake }
            return Segment(id: index,
                           startFraction: pair.0.timeIntervalSince(window.start) / window.duration,
                           endFraction: pair.1.timeIntervalSince(window.start) / window.duration,
                           kind: kind)
        }
    }
}

struct RecordingIntervalRing: View {
    let presentation: RecordingIntervalPresentation

    var body: some View {
        ZStack {
            ForEach(presentation.segments) { segment in
                Circle()
                    .trim(from: CGFloat(segment.startFraction), to: CGFloat(segment.endFraction))
                    .stroke(color(segment.kind), style: StrokeStyle(
                        lineWidth: 8, lineCap: .butt,
                        dash: segment.kind == .proposedAwake ? [3, 2] : []
                    ))
                    .rotationEffect(.degrees(-90))
                    .accessibilityHidden(true)
            }
            VStack(spacing: 3) {
                Text(TimeFormat.minutes(presentation.netMinutes))
                    .font(.system(.headline, design: .rounded).bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Net sleep after saving")
                    .accessibilityValue("\(presentation.netMinutes) minutes")
                    .accessibilityIdentifier("recording.netSleep")
                Text("Net sleep").font(.caption2).foregroundStyle(CoachColor.muted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(CoachColor.ink)
            .padding(12)
        }
        .padding(5)
        .frame(width: 104, height: 104)
    }

    private func color(_ kind: RecordingIntervalPresentation.Kind) -> Color {
        switch kind {
        case .sleep: return CoachColor.purple
        case .awake: return CoachColor.sun.opacity(0.42)
        case .proposedAwake: return CoachColor.sun
        }
    }
}

struct RecordingIntervalStrip: View {
    let presentation: RecordingIntervalPresentation

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(presentation.segments) { segment in
                    Rectangle()
                        .fill(segment.kind == .sleep ? CoachColor.purple : CoachColor.sun.opacity(0.42))
                        .overlay {
                            if segment.kind == .proposedAwake {
                                Rectangle().strokeBorder(CoachColor.sun, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                            }
                        }
                        .frame(width: geometry.size.width * CGFloat(segment.endFraction - segment.startFraction))
                        .offset(x: geometry.size.width * CGFloat(segment.startFraction))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
