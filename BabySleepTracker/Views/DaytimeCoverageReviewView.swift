import Combine
import SwiftUI

struct DaytimeCoverageReviewView: View {
    let initialDay: Date?
    let initialCalendar: Calendar
    let onRecordSaved: (SleepRecord) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState private var feedbackFocused: Bool
    @State private var model: DaytimeCoverageReviewModel
    @State private var calendar: Calendar
    @State private var date: Date
    @State private var latestPastDate: Date
    @State private var appeared = false
    @State private var editor: Editor?
    @State private var showWithdrawal = false
    @State private var isWriting = false
    @State private var recordChanged = false

    private enum Editor: Identifiable {
        case nap(SleepRecord?, day: Date)
        case wake(Date, Calendar)

        var id: String {
            switch self {
            case .nap(let record, _): return record?.id.uuidString ?? "new-nap"
            case .wake(let day, _): return "wake-\(day.timeIntervalSinceReferenceDate)"
            }
        }
    }

    init(initialDay: Date?, initialCalendar: Calendar, onRecordSaved: @escaping (SleepRecord) -> Bool) {
        self.initialDay = initialDay
        self.initialCalendar = initialCalendar
        self.onRecordSaved = onRecordSaved
        let calendar = DaytimeReviewWindow.capture(.current)
        let latestPastDate = calendar.startOfDay(for: Date()).addingTimeInterval(-1)
        _calendar = State(initialValue: calendar)
        _date = State(initialValue: calendar.startOfDay(for: latestPastDate))
        _latestPastDate = State(initialValue: latestPastDate)
        #if DEBUG && targetEnvironment(simulator)
        _model = State(initialValue: .init(storage: DaytimeCoverageUITestFixture.reviewStorage()))
        #else
        _model = State(initialValue: .init(storage: .init(defaults: SecureDataStore.shared)))
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let inspection = model.inspection {
                    reviewHeader(inspection)
                    if let morning = inspection.morning, let following = inspection.following {
                        reviewWindow(morning, following: following, day: inspection.day)
                        napSection(inspection)
                    }
                    if inspection.blocker == nil, let review = model.review {
                        answerSection(review, status: inspection.status)
                    }
                } else {
                    dateSelection
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .accessibilityIdentifier("daytimeReview.scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let inspection = model.inspection { reviewFooter(inspection) }
        }
        .foregroundStyle(RecordingColor.ink)
        .background(RecordingColor.background.ignoresSafeArea())
        .toolbarBackground(RecordingColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("Daytime review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Later") {
                    model.deferReview()
                    dismiss()
                }
                .disabled(isWriting)
                .accessibilityIdentifier("daytimeReview.later")
            }
        }
        .tint(RecordingColor.accent)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .onAppear(perform: appear)
        .onReceive(observationChanges) { _ in refresh() }
        .onChange(of: model.feedback) { value in if value != nil { feedbackFocused = true } }
        .confirmationDialog("Withdraw the saved daytime answer?", isPresented: $showWithdrawal, titleVisibility: .visible) {
            Button("Withdraw saved answer", role: .destructive) { write(withdrawing: true) }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Nap record changed", isPresented: $recordChanged) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Review the latest naps and open the record again.")
        }
        .fullScreenCover(item: $editor, onDismiss: refresh) { editor in
            switch editor {
            case .nap(let record, let day):
                AddRecordView(defaultDate: day, editingRecord: record, vm: AddRecordViewModel(),
                              endingOngoing: record?.isOngoing == true, napOnly: true, onSave: onRecordSaved)
            case .wake(let day, let calendar):
                HistoricalWakeEditor(day: day, calendar: calendar, fixedDay: true) { _, _ in }
            }
        }
    }

    private var observationChanges: some Publisher<Notification, Never> {
        let names: [Notification.Name] = [.observationProvenanceDidChange, .sleepRecordsDidChange, .dailyWakeRecordsDidChange,
                                         .secureDataStoreDidChange, .NSSystemTimeZoneDidChange,
                                         UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification]
        return Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            .debounce(for: .milliseconds(25), scheduler: RunLoop.main)
    }

    private var dateSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let feedback = model.feedback { feedbackText(feedback) }
            DatePicker("Review date", selection: $date, in: ...latestPastDate, displayedComponents: .date)
                .accessibilityIdentifier("daytimeReview.date")
                .padding(14)
                .reviewSurface()
            primaryAction("Review selected day", identifier: "daytimeReview.select", action: start)
        }
    }

    private func reviewHeader(_ inspection: DaytimeCoverageInspection) -> some View {
        let status = reviewStatus(inspection)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(inspection.day, format: dateStyle)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Text(inspection.day.formatted(dateStyle)))
                    .accessibilityIdentifier("daytimeReview.day")
                Button {
                    date = inspection.day
                    model.deferReview()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(RecordingColor.accent)
                .accessibilityLabel("Choose another date")
                .accessibilityIdentifier("daytimeReview.chooseDate")
                .disabled(isWriting)
            }
            HStack(spacing: 5) {
                Image(systemName: status.symbol).accessibilityHidden(true)
                Text(status.title).accessibilityIdentifier("daytimeReview.status")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(status.fill, in: RoundedRectangle(cornerRadius: 8))

            if let blocker = inspection.blocker {
                VStack(alignment: .leading, spacing: 5) {
                    if inspection.morning?.status == .missing {
                        Text("Morning wake is missing.").font(.subheadline.weight(.semibold))
                    } else if inspection.following?.status == .missing {
                        Text("Next morning wake is missing.").font(.subheadline.weight(.semibold))
                    }
                    Text(blockerMessage(blocker, hasWakeWindow: inspection.hasWakeWindow))
                    if inspection.status == .invalidated { Text("The previous answer needs a new review.") }
                }
                .reviewNotice()
            } else if inspection.status == .invalidated && model.review == nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your review is out of date.").font(.subheadline.weight(.semibold))
                    Text("Review the updated records before answering again.")
                }
                .reviewNotice()
            }
            if let feedback = model.feedback { feedbackText(feedback) }
        }
    }

    private func reviewStatus(_ inspection: DaytimeCoverageInspection)
        -> (title: LocalizedStringKey, symbol: String, color: Color, fill: Color) {
        if inspection.blocker != nil {
            return ("Review unavailable", "exclamationmark.circle", ObservationStatusColor.caution,
                    ObservationStatusColor.caution.opacity(0.10))
        }
        switch inspection.status {
        case .unknown:
            return ("Awaiting review", "clock", RecordingColor.secondary, RecordingColor.inset)
        case .incomplete:
            return ("Recording marked incomplete", "minus.circle", RecordingColor.secondary,
                    RecordingColor.secondary.opacity(0.08))
        case .confirmed:
            return (inspection.naps.isEmpty ? "Zero naps confirmed" : "Coverage confirmed by you",
                    "checkmark.circle", ObservationStatusColor.verified, ObservationStatusColor.verified.opacity(0.10))
        case .invalidated:
            return ("Needs review again", "arrow.counterclockwise.circle", ObservationStatusColor.caution,
                    ObservationStatusColor.caution.opacity(0.10))
        }
    }

    private func blockerMessage(_ blocker: DaytimeCoverageInspection.Blocker, hasWakeWindow: Bool) -> LocalizedStringKey {
        switch blocker {
        case .notHistorical: return "Choose a date before today."
        case .storageUnavailable: return "Saved observations could not be opened."
        case .wakeBoundaries: return "Each date needs one verified morning wake before you can save a review."
        case .conflictingEvidence:
            return hasWakeWindow
                ? "Conflicting records prevent a review of this day."
                : "The two wakes do not form a valid daytime interval. Use the wake editor to check past wake times."
        case .unresolvedNap: return "A nap needs an observed end before this day can be reviewed."
        case .crossingNap: return "A nap crosses a morning wake. Check the recorded times."
        case .crossingBreak: return "An awake break crosses a morning wake. Check the recorded times."
        case .unavailableRevision: return "A recorded observation could not be verified against its saved revision."
        }
    }

    private func reviewWindow(_ morning: DaytimeCoverageInspection.Boundary,
                              following: DaytimeCoverageInspection.Boundary, day: Date) -> some View {
        let zone = dateFormat.timeZone(.localizedGMT(.short))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Review window").accessibilityAddTraits(.isHeader)
                if !dynamicType.isAccessibilitySize {
                    Spacer()
                    Text(day, format: zone)
                }
            }
            .font(.footnote)
            .foregroundStyle(RecordingColor.secondary)
            if dynamicType.isAccessibilitySize {
                stackedBoundaries(morning, following: following)
                Text(day, format: zone).font(.footnote).foregroundStyle(RecordingColor.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        boundary(morning, title: "Morning wake", identifier: "daytimeReview.morning")
                        Divider()
                        boundary(following, title: "Next morning", identifier: "daytimeReview.following")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .reviewSurface()
                    stackedBoundaries(morning, following: following)
                }
            }
        }
    }

    private func stackedBoundaries(_ morning: DaytimeCoverageInspection.Boundary,
                                   following: DaytimeCoverageInspection.Boundary) -> some View {
        VStack(spacing: 8) {
            boundary(morning, title: "Morning wake", identifier: "daytimeReview.morning")
                .padding(12)
                .reviewSurface()
            boundary(following, title: "Next morning", identifier: "daytimeReview.following")
                .padding(12)
                .reviewSurface()
        }
    }

    private func boundary(_ boundary: DaytimeCoverageInspection.Boundary, title: LocalizedStringKey,
                          identifier: String) -> some View {
        let canEdit = boundary.day < calendar.startOfDay(for: Date()) &&
            [.missing, .unverified, .verified].contains(boundary.status)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(RecordingColor.secondary)
                    if let time = boundary.time {
                        Text(time, format: timeStyle)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                    } else {
                        Text(boundaryTimePlaceholder(boundary.status))
                            .font(.headline)
                            .foregroundStyle(ObservationStatusColor.caution)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            boundaryDate(boundary.day)
                            boundaryEvidence(boundary.status, canEdit: canEdit)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            boundaryDate(boundary.day)
                            boundaryEvidence(boundary.status, canEdit: canEdit)
                        }
                    }
                    .font(.caption)
                    if ![.verified, .missing, .unverified].contains(boundary.status) {
                        Text(wakeStatus(boundary.status))
                            .font(.footnote)
                            .foregroundStyle(ObservationStatusColor.caution)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)

                if canEdit {
                    Button {
                        refresh()
                        guard let current = model.inspection,
                              current.morning == boundary || current.following == boundary else { return }
                        editor = .wake(boundary.day, calendar)
                    } label: {
                        Image(systemName: boundary.status == .missing ? "plus" : "pencil")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RecordingColor.accent)
                    .accessibilityLabel(boundary.status == .missing ? "Record morning wake" : "Edit morning wake")
                    .accessibilityHint(Text(boundary.day, format: dateStyle))
                    .accessibilityIdentifier("\(identifier).edit")
                }
            }
            if !canEdit && (boundary.status == .missing || boundary.status == .unverified) {
                Text("Use Today’s Wake-up on Home to record an observed wake.")
                    .font(.footnote)
                    .foregroundStyle(RecordingColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boundaryDate(_ day: Date) -> some View {
        Text(day, format: shortDateStyle)
            .foregroundStyle(RecordingColor.secondary)
            .accessibilityLabel(Text(day, format: dateStyle))
    }

    @ViewBuilder
    private func boundaryEvidence(_ status: DaytimeCoverageInspection.Boundary.Status, canEdit: Bool) -> some View {
        switch status {
        case .verified:
            Label("Verified", systemImage: "checkmark.circle")
                .foregroundStyle(ObservationStatusColor.verified)
                .accessibilityLabel("Verified wake")
        case .missing where canEdit:
            Text("Record wake")
                .foregroundStyle(ObservationStatusColor.caution)
                .accessibilityLabel("Missing wake")
        case .missing, .unverified:
            Text(wakeStatus(status)).foregroundStyle(ObservationStatusColor.caution)
        default:
            EmptyView()
        }
    }

    private func boundaryTimePlaceholder(_ status: DaytimeCoverageInspection.Boundary.Status) -> LocalizedStringKey {
        switch status {
        case .missing: return "Missing"
        case .conflicting: return "Conflicting wakes"
        case .pending: return "Recovery pending"
        case .invalid, .future, .unverified, .verified: return "Unavailable"
        }
    }

    private func wakeStatus(_ status: DaytimeCoverageInspection.Boundary.Status) -> LocalizedStringKey {
        switch status {
        case .missing: return "Missing wake"
        case .conflicting: return "More than one morning wake is recorded for this date. Choose another date or review later."
        case .invalid: return "This wake cannot be used for the selected date."
        case .pending: return "Wake recovery is pending. Finish the original recording or reopen the app."
        case .unverified: return "Recorded wake needs verification"
        case .future: return "This wake time is still in the future."
        case .verified: return "Verified wake"
        }
    }

    private func napSection(_ inspection: DaytimeCoverageInspection) -> some View {
        let naps = model.review?.naps ?? inspection.naps
        let title: LocalizedStringKey = inspection.hasWakeWindow
            ? "Naps between wakes" : "Naps starting on \(inspection.day.formatted(shortDateStyle))"
        let heading = Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); addNapButton }
                VStack(alignment: .leading, spacing: 2) { heading; addNapButton }
            }
            if naps.isEmpty && inspection.blocker == nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No naps recorded").font(.headline).accessibilityIdentifier("daytimeReview.empty")
                    if inspection.status == .confirmed {
                        Text("You confirmed there were no naps.")
                    } else if inspection.status == .unknown {
                        Text("Your answer is still needed.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .reviewSurface()
            } else if !naps.isEmpty {
                VStack(spacing: dynamicType.isAccessibilitySize ? 8 : 0) {
                    ForEach(Array(naps.enumerated()), id: \.offset) { index, nap in
                        let row = napRow(nap, index: index, day: inspection.day).padding(12)
                        if dynamicType.isAccessibilitySize {
                            row.reviewSurface()
                        } else {
                            if index > 0 { Divider().padding(.leading, 42).padding(.trailing, 12) }
                            row
                        }
                    }
                }
                .background(alignment: .leading) {
                    if !dynamicType.isAccessibilitySize && naps.count > 1 {
                        Rectangle().fill(RecordingColor.border)
                            .frame(width: 1).padding(.leading, 23).padding(.vertical, 30)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
                .modifier(ReviewSurface(visible: !dynamicType.isAccessibilitySize))
            }
        }
    }

    private var addNapButton: some View {
        Button {
            refresh()
            guard let current = model.inspection, current.morning != nil else { return }
            editor = .nap(nil, day: current.morning?.time ?? current.day)
        } label: {
            Label("Add nap", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RecordingColor.accent)
        .accessibilityIdentifier("daytimeReview.addNap")
    }

    private func napRow(_ nap: DaytimeCoverageReview.Nap, index: Int, day: Date) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let end = nap.end {
                Text("\(nap.start.formatted(timeStyle))–\(end.formatted(timeStyle))")
                    .font(.headline)
                    .monospacedDigit()
            } else {
                Text("Started \(nap.start.formatted(timeStyle))").font(.headline).monospacedDigit()
                Text(nap.isOngoing ? "Ongoing nap" : "End missing").font(.footnote)
            }
            if !calendar.isDate(nap.start, inSameDayAs: day) {
                Text("Starts \(nap.start.formatted(shortDateStyle))").font(.caption)
            }
            if let end = nap.end, !calendar.isDate(end, inSameDayAs: nap.start) {
                Text("Ends \(end.formatted(shortDateStyle))").font(.caption)
            }
            if nap.usesLegacyDuration {
                Text("End calculated from the saved duration").font(.footnote)
            }
            napMetadata(nap)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daytimeReview.nap.\(index)")

        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            if !dynamicType.isAccessibilitySize {
                Text("\(index + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RecordingColor.secondary)
                    .padding(5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RecordingColor.inset, in: Circle())
                    .background(RecordingColor.background, in: Circle())
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editNap(nap)
            } label: {
                Text(nap.isOngoing ? "Record nap end" : (dynamicType.isAccessibilitySize ? "Edit nap" : "Edit"))
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44, alignment: dynamicType.isAccessibilitySize ? .leading : .trailing)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(RecordingColor.accent)
            .buttonStyle(.plain)
            .accessibilityLabel(nap.isOngoing ? "Record end of nap \(index + 1)" : "Edit nap \(index + 1)")
            .accessibilityHint(Text(nap.start, format: dateStyle.hour().minute()))
            .accessibilityIdentifier("daytimeReview.nap.\(index).edit")
        }
    }

    private func napMetadata(_ nap: DaytimeCoverageReview.Nap) -> some View {
        let isVerified = nap.source == .verifiedObservation
        let provenance = Label(isVerified ? "Verified recording" : "Unverified recording",
                               systemImage: isVerified ? "checkmark.circle" : "circle.dotted")
            .foregroundStyle(isVerified ? ObservationStatusColor.verified : ObservationStatusColor.caution)
        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return ViewThatFits(in: .horizontal) {
            layout {
                napInterval(nap)
                provenance
            }
            VStack(alignment: .leading, spacing: 3) {
                napInterval(nap)
                provenance
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func napInterval(_ nap: DaytimeCoverageReview.Nap) -> some View {
        if !nap.isOngoing, !nap.usesLegacyDuration, let end = nap.end, end > nap.start, end <= Date(),
           let minutes = Int(exactly: (end.timeIntervalSince(nap.start) / 60).rounded(.down)) {
            Text("\(minutes) min interval").foregroundStyle(RecordingColor.secondary)
        }
    }

    private func answerSection(_ review: DaytimeCoverageReview, status: DaytimeCoverageInspection.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.canWithdraw ? "Update your answer" :
                (review.naps.isEmpty ? "Were there any naps?" : "Were all naps recorded?"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                answerButton(review.naps.isEmpty ? "There were no naps" : "All naps are recorded",
                             answer: .allNapsRecorded, identifier: "daytimeReview.complete")
                Divider()
                answerButton("Recording is incomplete", answer: .notAllNapsRecorded, identifier: "daytimeReview.incomplete")
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .reviewSurface()
            Text("Individual recordings keep their verification status.")
                .font(.footnote)
                .foregroundStyle(RecordingColor.secondary)
            if model.canWithdraw {
                Button(status == .confirmed ? "Withdraw confirmation" : "Withdraw saved answer", role: .destructive) {
                    showWithdrawal = true
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(Color(uiColor: .systemRed))
                .frame(minHeight: 44)
                .disabled(isWriting)
                .accessibilityIdentifier("daytimeReview.withdraw")
            }
        }
    }

    private func answerButton(_ title: LocalizedStringKey, answer: ParentDaytimeAttestation,
                              identifier: String) -> some View {
        let selected = model.selection == answer
        return Button {
            model.choose(answer)
        } label: {
            Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? RecordingColor.accent : RecordingColor.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .background(selected ? RecordingColor.inset : .clear)
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(RecordingColor.accent).frame(width: 3)
                            .padding(.vertical, 10)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .disabled(isWriting)
    }

    private func reviewFooter(_ inspection: DaytimeCoverageInspection) -> some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                if inspection.blocker != nil {
                    if !dynamicType.isAccessibilitySize {
                        Text("A review can’t be saved yet.").font(.footnote)
                    }
                } else if model.review == nil {
                    if !dynamicType.isAccessibilitySize { Text("A fresh review is needed.").font(.footnote) }
                    primaryAction(model.feedback == .preparationFailed ? "Retry opening review" : "Review these records",
                                  identifier: "daytimeReview.reopen", disabled: isWriting) {
                        model.startAgain(at: Date(), calendar: .current)
                    }
                } else {
                    if !dynamicType.isAccessibilitySize {
                        Text(saveHint(inspection.status)).font(.footnote)
                    }
                    primaryAction(model.feedback == .saveFailed ? "Retry save" : "Save review",
                                  identifier: "daytimeReview.save", disabled: !model.canSave || isWriting) {
                        write(withdrawing: false)
                    }
                    .accessibilityHint(Text(saveHint(inspection.status)))
                }
            }
            .foregroundStyle(RecordingColor.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .background(RecordingColor.background)
    }

    private func saveHint(_ status: DaytimeCoverageInspection.Status) -> LocalizedStringKey {
        if model.selection != nil { return "Your answer is not saved yet." }
        if status == .confirmed || status == .incomplete { return "Answer saved. Select again to update." }
        return "Choose an answer to save."
    }

    private func primaryAction(_ title: LocalizedStringKey, identifier: String,
                               disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(disabled ? RecordingColor.secondary : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(disabled ? RecordingColor.inset : RecordingColor.actionFill,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }

    private func feedbackText(_ feedback: DaytimeCoverageReviewModel.Feedback) -> some View {
        let message: LocalizedStringKey
        switch feedback {
        case .preparationFailed: message = "Couldn’t open the review. Try again."
        case .changed: message = "The evidence or saved answer changed. Review the current records again."
        case .calendarChanged: message = "The calendar or time zone changed. Choose the review date again."
        case .saved: message = "Daytime answer saved."
        case .saveFailed: message = "Couldn’t verify the save. Check the current status and try again."
        case .withdrawn: message = "Daytime answer withdrawn."
        case .withdrawalFailed: message = "Couldn’t verify withdrawal. Check the current status and try again."
        }
        return Text(message)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("daytimeReview.feedback")
            .accessibilityFocused($feedbackFocused)
    }

    private var dateFormat: Date.FormatStyle {
        .init(date: .omitted, time: .omitted, locale: .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    private var dateStyle: Date.FormatStyle {
        dateFormat.weekday(.abbreviated).day().month(.abbreviated).year()
    }

    private var shortDateStyle: Date.FormatStyle { dateFormat.day().month(.abbreviated) }
    private var timeStyle: Date.FormatStyle { dateFormat.hour().minute() }

    private func appear() {
        if appeared {
            refresh()
            return
        }
        appeared = true
        if let initialDay, DaytimeReviewWindow.capture(initialCalendar) == calendar,
           calendar.startOfDay(for: initialDay) <= latestPastDate {
            date = initialDay
            start()
        }
    }

    private func start() {
        refresh()
        model.start(day: date, at: Date(), calendar: calendar)
    }

    private func refresh() {
        let now = Date()
        let current = DaytimeReviewWindow.capture(.current)
        model.refresh(at: now, calendar: current)
        latestPastDate = current.startOfDay(for: now).addingTimeInterval(-1)
        if current != calendar || date > latestPastDate {
            date = current.startOfDay(for: latestPastDate)
        }
        calendar = current
    }

    private func editNap(_ nap: DaytimeCoverageReview.Nap) {
        refresh()
        let matches = SleepRecordPersistence().load()?.filter { $0.id == nap.id } ?? []
        guard model.inspection?.naps.contains(nap) == true, matches.count == 1, let record = matches.first,
              record.kind == .dayNap, record.date == nap.start, record.observedEnd == nap.end,
              record.isOngoing == nap.isOngoing else {
            recordChanged = true
            return
        }
        editor = .nap(record, day: record.date)
    }

    private func write(withdrawing: Bool) {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        let now = Date()
        if withdrawing { model.withdraw(at: now, calendar: .current) }
        else { model.save(at: now, calendar: .current) }
    }
}

// These two observation screens share contrast-aware status inks.
enum ObservationStatusColor {
    static let verified = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.67, green: 0.85, blue: 0.77, alpha: 1)
            : UIColor(red: 0.14, green: 0.40, blue: 0.32, alpha: 1)
    })
    static let caution = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.79, blue: 0.54, alpha: 1)
            : UIColor(red: 0.51, green: 0.32, blue: 0.06, alpha: 1)
    })
}

private struct ReviewSurface: ViewModifier {
    var visible = true

    func body(content: Content) -> some View {
        if visible {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            content
                .background(RecordingColor.surface, in: shape)
                .overlay(shape.strokeBorder(RecordingColor.border, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
        }
    }
}

private extension View {
    func reviewSurface() -> some View { modifier(ReviewSurface()) }

    func reviewNotice() -> some View {
        font(.footnote)
            .foregroundStyle(ObservationStatusColor.caution)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(ObservationStatusColor.caution.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
