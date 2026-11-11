import SwiftUI

/// Semantic surfaces and scalable fonts keep all recording forms legible in both appearances.
enum RecordingStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.75, green: 0.67, blue: 1, alpha: 1)
            : UIColor(red: 0.40, green: 0.29, blue: 0.78, alpha: 1)
    })
}

struct RecordingDateField: View {
    let title: String
    let identifier: String
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            DatePicker("\(title) date", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .accessibilityLabel("\(title) date")
                .accessibilityIdentifier("\(identifier).date")
            DatePicker("\(title) time", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(title) time")
                .accessibilityIdentifier("\(identifier).time")
        }
        .datePickerStyle(.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(RecordingStyle.accent)
        .disabled(!enabled)
        .accessibilityIdentifier("recording.save")
        .listRowBackground(Color.clear)
    }
}
