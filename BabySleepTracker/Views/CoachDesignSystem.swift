import SwiftUI

// Extracted unchanged from AI Coach. Keep its existing appearance as the reference.
enum CoachColor {
    static let background = Color(.systemGroupedBackground)
    static let ink = Color(.label)
    static let muted = Color(.secondaryLabel)
    static let purple = Color(red: 0.55, green: 0.45, blue: 0.96)
    static let purpleDeep = Color(red: 0.45, green: 0.35, blue: 0.92)
    static let sun = Color(red: 1.0, green: 0.68, blue: 0.12)
    static let green = Color(red: 0.16, green: 0.68, blue: 0.46)
    static let red = Color(red: 0.95, green: 0.22, blue: 0.32)
    static let stroke = Color(.separator)
}

struct CoachCardBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.systemBackground))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [CoachColor.purple.opacity(0.045), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
        }
        .shadow(color: CoachColor.purpleDeep.opacity(0.07), radius: 14, x: 0, y: 6)
    }
}

struct CoachCardBorder: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(CoachColor.purple.opacity(0.14), lineWidth: 1)
    }
}
