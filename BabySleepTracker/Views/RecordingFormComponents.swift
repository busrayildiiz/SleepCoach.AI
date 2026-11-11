import SwiftUI

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
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .environment(\.recordingCompactHeight, geometry.size.height < 520)
        }
        .background(CoachColor.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordingSaveButton(title: saveTitle, enabled: saveEnabled, action: onSave)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(CoachColor.background)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel).accessibilityIdentifier("recording.cancel")
            }
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(CoachColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .tint(CoachColor.purpleDeep)
    }
}

struct RecordingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachCardBackground())
            .overlay(CoachCardBorder())
    }
}

struct RecordingSectionLabel: View {
    let title: String
    @ScaledMetric(relativeTo: .caption2) private var size = 10

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(CoachColor.purpleDeep)
            .accessibilityAddTraits(.isHeader)
    }
}

private enum RecordingEndpoint: String, Identifiable {
    case start, end
    var id: String { rawValue }
}

struct RecordingIntervalCard: View {
    let title: String
    @Binding var start: Date
    @Binding var end: Date
    var ongoing: Binding<Bool>? = nil
    let feedback: (Date, Date) -> String
    let validation: (Date, Date) -> String?
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var endpoint: RecordingEndpoint?

    private var isOngoing: Bool { ongoing?.wrappedValue ?? false }

    private var dateContext: String {
        let first = start.formatted(date: .abbreviated, time: .omitted)
        guard !isOngoing, !Calendar.current.isDate(start, inSameDayAs: end) else { return first }
        return first + " → " + end.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        RecordingCard {
            RecordingSectionLabel(title: title)
            Label(dateContext, systemImage: "calendar")
                .font(.caption.weight(.medium))
                .foregroundStyle(CoachColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let ongoing {
                Toggle(isOn: ongoing) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Still Sleeping").font(.subheadline.weight(.semibold))
                        Text("Leave the end unrecorded until your baby wakes.")
                            .font(.caption).foregroundStyle(CoachColor.muted)
                    }
                }
                .accessibilityIdentifier("recording.ongoing")
            }
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) { endpoints }
            } else {
                HStack(alignment: .top, spacing: 16) { endpoints }
            }
        }
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private var endpoints: some View {
        RecordingTimeButton(title: "Start", date: start, identifier: "recording.start.edit") { endpoint = .start }
        if isOngoing {
            VStack(alignment: .leading, spacing: 6) {
                Text("END").font(.caption.weight(.bold)).foregroundStyle(CoachColor.muted)
                Label("Not recorded", systemImage: "moon.zzz.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CoachColor.purpleDeep)
                    .accessibilityIdentifier("recording.ongoingNotice")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RecordingTimeButton(title: "End", date: end, identifier: "recording.end.edit") { endpoint = .end }
        }
    }
}

private struct RecordingTimeButton: View {
    let title: String
    let date: Date
    let identifier: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size = 24

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(CoachColor.muted)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: size, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(CoachColor.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) time")
        .accessibilityValue(date.formatted(date: .complete, time: .shortened))
        .accessibilityHint("Opens the time and date editor")
        .accessibilityIdentifier(identifier)
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
                        .foregroundStyle(CoachColor.purpleDeep)
                        .accessibilityIdentifier("recording.editor.feedback")
                    if let message = validation(selection) {
                        RecordingValidation(message: message)
                    }
                }
                .padding(16)
            }
            .background(CoachColor.background)
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
        .tint(CoachColor.purpleDeep)
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
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 22)
                .padding(.vertical, 14)
                .foregroundStyle(enabled ? Color.white : CoachColor.muted)
                .background(Capsule().fill(enabled ? CoachColor.purpleDeep : CoachColor.purple.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("recording.save")
    }
}

struct RecordingKindPicker: View {
    @Binding var selection: SleepKind
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .caption) private var size = 12

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: 3) { choices }
            } else {
                HStack(spacing: 6) { choices }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(.systemBackground)))
        .overlay(Capsule().stroke(CoachColor.purple.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.kind")
    }

    @ViewBuilder private var choices: some View {
        choice(.dayNap, title: "Nap", identifier: "recording.kind.nap")
        choice(.nightSleep, title: "Night Sleep", identifier: "recording.kind.night")
    }

    private func choice(_ kind: SleepKind, title: String, identifier: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selection = kind }
        } label: {
            Label(title, systemImage: kind.icon)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(selection == kind ? CoachColor.purpleDeep : CoachColor.muted)
                .background(Capsule().fill(selection == kind ? CoachColor.purple.opacity(0.12) : Color.clear))
                .overlay(Capsule().stroke(selection == kind ? CoachColor.purple.opacity(0.18) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == kind ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
