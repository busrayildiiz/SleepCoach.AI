import SwiftUI

/// A safe destination for the historical login route. Remote authentication is
/// not implemented, so this view never collects or accepts credentials.
struct LogInView: View {
    @Binding var authState: AuthState

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(hex: "6B63D8"))
                Text("Your profile lives here")
                    .font(.title2.weight(.semibold))
                Text("This version uses a local profile on this device. You don't need an email address or password to track sleep.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Create a Profile") { authState = .creatingAccount }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "6B63D8"))
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") { authState = .landing }
                }
            }
        }
    }
}
