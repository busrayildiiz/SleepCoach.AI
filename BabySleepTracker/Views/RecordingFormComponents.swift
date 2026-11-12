import SwiftUI

// Recording-only values follow the approved image; AI Coach's tokens stay unchanged.
enum RecordingColor {
    static let accent = Color(red: 0.47, green: 0.28, blue: 0.82)
    static let ink = CoachColor.ink
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(red: 0.35, green: 0.34, blue: 0.49, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGroupedBackground : UIColor(red: 0.975, green: 0.956, blue: 0.997, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : UIColor.white.withAlphaComponent(0.74)
    })
    static let inset = accent.opacity(0.055)
    static let border = accent.opacity(0.07)
}

private struct RecordingFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let rounded: Bool

    init(size: CGFloat, weight: Font.Weight, rounded: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
        self.rounded = rounded
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
    }
}

extension View {
    func recordingFont(_ size: CGFloat, weight: Font.Weight = .regular, rounded: Bool = false) -> some View {
        modifier(RecordingFont(size: size, weight: weight, rounded: rounded))
    }
}

enum RecordingFormat {
    static func duration(_ minutes: Int) -> String {
        let value = max(0, minutes)
        let hours = value / 60
        let remainder = value % 60
        return hours == 0 ? "\(remainder) m" : "\(hours) h" + (remainder == 0 ? "" : " \(remainder) m")
    }

    static func date(_ value: Date, year: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = year ? "d MMM yyyy" : "d MMM"
        return formatter.string(from: value)
    }
}

private struct RecordingCompactHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var recordingCompactHeight: Bool {
        get { self[RecordingCompactHeightKey.self] }
        set { self[RecordingCompactHeightKey.self] = newValue }
    }
}

struct RecordingScreen<Content: View>: View {
    let title: String
    let saveTitle: String
    let saveEnabled: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    var spacing: CGFloat = 32
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: spacing, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .environment(\.recordingCompactHeight, geometry.size.height < 520)
        }
        .background(RecordingColor.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordingSaveButton(title: saveTitle, enabled: saveEnabled, action: onSave)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(RecordingColor.background)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RecordingColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("recording.cancel")
            }
        }
        .tint(RecordingColor.accent)
    }
}

struct RecordingSurface: View {
    var cornerRadius: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(RecordingColor.surface)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(RecordingColor.border, lineWidth: 1)
            }
            .shadow(color: RecordingColor.accent.opacity(0.065), radius: 5, x: 0, y: 2)
    }
}

struct RecordingCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecordingSurface())
    }
}

struct RecordingSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .recordingFont(11, weight: .bold)
            .tracking(0.5)
            .foregroundStyle(RecordingColor.secondary)
            .padding(.horizontal, 7)
            .accessibilityAddTraits(.isHeader)
    }
}

private enum RecordingEndpoint: String, Identifiable {
    case start, end
    var id: String { rawValue }
}

enum RecordingIntervalStyle { case sleep, awake }

struct RecordingIntervalCard: View {
    @Binding var start: Date
    @Binding var end: Date
    var ongoing: Binding<Bool>? = nil
    var style: RecordingIntervalStyle = .sleep
    let feedback: (Date, Date) -> String
    let validation: (Date, Date) -> String?
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.recordingCompactHeight) private var compactHeight
    @State private var endpoint: RecordingEndpoint?

    private var isOngoing: Bool { ongoing?.wrappedValue ?? false }
    private var crossesMidnight: Bool { !isOngoing && !Calendar.current.isDate(start, inSameDayAs: end) }

    private var dateContext: String {
        let first = RecordingFormat.date(start)
        if crossesMidnight { return first + " – " + RecordingFormat.date(end) }
        return (Calendar.current.isDateInToday(start) ? "Today, " : "") + first
    }

    var body: some View {
        VStack(spacing: 0) {
            if style == .sleep {
                Button { endpoint = .start } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").recordingFont(18, weight: .medium)
                            .foregroundStyle(RecordingColor.secondary)
                        Text(dateContext).recordingFont(14, weight: .semibold)
                            .foregroundStyle(RecordingColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").recordingFont(13, weight: .medium)
                            .foregroundStyle(RecordingColor.secondary)
                    }
                    .frame(minHeight: 28)
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recording date")
                .accessibilityValue(dateContext)
                .accessibilityHint("Opens the date and time editor")
                .accessibilityIdentifier("recording.date.edit")
                Divider().overlay(RecordingColor.border)
            }
            if let ongoing {
                Toggle("Still Sleeping", isOn: ongoing)
                    .recordingFont(14, weight: .semibold)
                    .foregroundStyle(RecordingColor.ink)
                    .accessibilityIdentifier("recording.ongoing")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { endpoints }
                } else {
                    HStack(spacing: 12) {
                        startButton
                        Rectangle().fill(RecordingColor.border).frame(width: 1, height: style == .sleep ? 44 : 48)
                            .accessibilityHidden(true)
                        endControl
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .background(RecordingSurface())
        .sheet(item: $endpoint) { endpoint in
            RecordingTimeEditor(
                title: endpoint == .start ? "Start time" : "End time",
                identifier: "recording.\(endpoint.rawValue)",
                initialValue: endpoint == .start ? start : end,
                feedback: { value in feedback(endpoint == .start ? value : start, endpoint == .end ? value : end) },
                validation: { value in validation(endpoint == .start ? value : start, endpoint == .end ? value : end) },
                onDone: { value in
                    if endpoint == .start { start = value } else { end = value }
                }
            )
            .presentationDetents(dynamicType.isAccessibilitySize || compactHeight ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private var endpoints: some View { startButton; endControl }

    private var startButton: some View {
        RecordingTimeButton(title: "Start", date: start, showsDate: style == .awake && crossesMidnight,
                            style: style, identifier: "recording.start.edit") { endpoint = .start }
    }

    @ViewBuilder private var endControl: some View {
        if isOngoing {
            VStack(alignment: .leading, spacing: 6) {
                Text("End").recordingFont(12, weight: .medium).foregroundStyle(RecordingColor.secondary)
                Text("Not recorded").recordingFont(14, weight: .semibold)
                    .foregroundStyle(RecordingColor.secondary)
                    .accessibilityIdentifier("recording.ongoingNotice")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            RecordingTimeButton(title: "End", date: end, showsDate: style == .awake && crossesMidnight,
                                style: style, identifier: "recording.end.edit") { endpoint = .end }
        }
    }
}

private struct RecordingTimeButton: View {
    let title: String
    let date: Date
    let showsDate: Bool
    let style: RecordingIntervalStyle
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                if style == .awake { label.padding(.horizontal, 8) }
                VStack(alignment: .leading, spacing: 6) {
                    if style == .sleep { label }
                    HStack(spacing: 4) {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .recordingFont(style == .sleep ? 22 : 20, weight: .semibold, rounded: true)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").recordingFont(12, weight: .medium)
                            .foregroundStyle(RecordingColor.secondary)
                    }
                    .foregroundStyle(RecordingColor.ink)
                    if showsDate {
                        Text(RecordingFormat.date(date)).recordingFont(11)
                            .foregroundStyle(RecordingColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, style == .sleep ? 12 : 10)
                .frame(maxWidth: .infinity, minHeight: style == .sleep ? 76 : 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(RecordingColor.inset))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) time")
        .accessibilityValue(date.formatted(date: .complete, time: .shortened))
        .accessibilityHint("Opens the time and date editor")
        .accessibilityIdentifier(identifier)
    }

    private var label: some View {
        Text(title).recordingFont(12, weight: .medium).foregroundStyle(RecordingColor.secondary)
    }
}

private struct RecordingTimeEditor: View {
    let title: String
    let identifier: String
    let feedback: (Date) -> String
    let validation: (Date) -> String?
    let onDone: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(title: String, identifier: String, initialValue: Date,
         feedback: @escaping (Date) -> String, validation: @escaping (Date) -> String?,
         onDone: @escaping (Date) -> Void) {
        self.title = title
        self.identifier = identifier
        self.feedback = feedback
        self.validation = validation
        self.onDone = onDone
        _selection = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("Date", selection: $selection, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("\(identifier).date")
                    DatePicker(title, selection: $selection, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .accessibilityLabel(title)
                        .accessibilityIdentifier("\(identifier).time")
                        .frame(maxWidth: .infinity)
                    Text(feedback(selection)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(RecordingColor.accent)
                        .accessibilityIdentifier("recording.editor.feedback")
                    if let message = validation(selection) {
                        RecordingValidation(message: message)
                    }
                }
                .padding(16)
            }
            .background(RecordingColor.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("recording.time.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(selection); dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("recording.time.done")
                }
            }
        }
        .tint(RecordingColor.accent)
    }
}

struct RecordingValidation: View {
    let message: String
    var body: some View {
        Label {
            Text(message).accessibilityIdentifier("recording.validation")
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.caption)
        .foregroundStyle(CoachColor.red)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RecordingSaveButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .recordingFont(16, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(enabled ? Color.white : RecordingColor.secondary)
                .background(Capsule().fill(enabled ? RecordingColor.accent : RecordingColor.inset))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("recording.save")
    }
}

struct RecordingKindPicker: View {
    @Binding var selection: SleepKind
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: 6) { choices }
            } else {
                HStack(spacing: 6) { choices }
            }
        }
        .padding(6)
        .background(RecordingSurface(cornerRadius: dynamicType.isAccessibilitySize ? 18 : 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.kind")
    }

    @ViewBuilder private var choices: some View {
        choice(.dayNap, title: "Nap", icon: "bed.double", identifier: "recording.kind.nap")
        choice(.nightSleep, title: "Night Sleep", icon: "moon", identifier: "recording.kind.night")
    }

    private func choice(_ kind: SleepKind, title: String, icon: String, identifier: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selection = kind }
        } label: {
            Label(title, systemImage: icon)
                .recordingFont(14, weight: selection == kind ? .semibold : .medium)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .foregroundStyle(selection == kind ? RecordingColor.accent : RecordingColor.secondary)
                .background(Capsule().fill(selection == kind ? RecordingColor.accent.opacity(0.10) : Color.clear))
                .overlay(Capsule().stroke(selection == kind ? RecordingColor.accent.opacity(0.10) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == kind ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
