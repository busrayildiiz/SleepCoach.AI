//
//  AuthFlow.swift
//  BabySleepTracker
//
//  Created by MacBook on 6.06.2026.
//

import Foundation
import SwiftUI

// MARK: - Auth State

enum AuthState {
    case landing
    case creatingAccount
    case loggingIn
    case onboarding
    case loggedIn
}

// MARK: - Root Router

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("authComplete") private var authComplete: Bool = false
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    @SecureStorage("profileSetupComplete_v1") private var hasLocalProfile = false
    @State private var authState: AuthState = .landing
    @State private var storageAvailable = SecureDataStore.shared.isAvailable
    @State private var storageFailure = SecureDataStore.shared.failureMessage

    var body: some View {
        // Keep lifecycle and privacy modifiers on one stable hosting container,
        // rather than forwarding them through the conditional route's children.
        ZStack {
            if storageAvailable {
                routedContent
            } else {
                protectedDataUnavailable
            }
        }
        .privacySensitive()
        .background(AppPrivacyShield())
        .overlay {
            if scenePhase != .active {
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay {
                        Image(systemName: "moon.stars.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.indigo)
                    }
                    .accessibilityLabel("SleepCoach")
            }
        }
        .onAppear { reopenPrivateData() }
        .onReceive(NotificationCenter.default.publisher(for: .secureDataStoreDidChange)
            .receive(on: RunLoop.main)) { _ in
            refreshStorageStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            closePrivateData()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            if scenePhase == .active { reopenPrivateData() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { closePrivateData() }
            else if phase == .active { reopenPrivateData() }
        }
        .onChange(of: authComplete) { complete in
            if !complete { authState = .landing }
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        if hasLocalProfile {
            ContentView()
        } else {
            switch authState {
            case .landing:
                LandingView(authState: $authState)
            case .creatingAccount:
                CreateAccountView(authState: $authState)
            case .loggingIn:
                LogInView(authState: $authState)
            case .onboarding:
                WelcomeView {
                    guard SecureDataStore.shared.bool(forKey: "profileSetupComplete_v1") else {
                        authState = .creatingAccount
                        return
                    }
                    onboardingComplete = true
                    authComplete = true
                    authState = .loggedIn
                }
            case .loggedIn:
                // Routing preferences are not proof that a local profile exists.
                CreateAccountView(authState: $authState)
            }
        }
    }

    private var protectedDataUnavailable: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.indigo)
            Text("Your data is protected")
                .font(.title2.weight(.semibold))
            Text(storageFailure ?? "Unlock your device to open your saved profile and sleep records.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again") { reopenPrivateData() }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("protectedDataUnavailable")
    }

    private func refreshStorageStatus() {
        storageAvailable = SecureDataStore.shared.isAvailable
        storageFailure = SecureDataStore.shared.failureMessage
    }

    private func closePrivateData() {
        SleepCoachOrchestrator.shared.clearPrivateState()
        SecureDataStore.shared.lock()
        refreshStorageStatus()
    }

    private func reopenPrivateData() {
        guard UIApplication.shared.isProtectedDataAvailable else {
            closePrivateData()
            return
        }
        // A temporary inactive phase (for example the photo picker) does not
        // rotate the vault generation while an allowed import is still running.
        if !SecureDataStore.shared.isAvailable { SecureDataStore.shared.reload() }
        refreshStorageStatus()
    }
}

/// A scene-level cover also hides presented sheets and full-screen editors from
/// app-switcher snapshots. A root SwiftUI overlay alone sits below those views.
private struct AppPrivacyShield: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.onSceneChange = { [weak coordinator = context.coordinator] scene in
            coordinator?.attach(to: scene)
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) { }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class AnchorView: UIView {
        var onSceneChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(window?.windowScene)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scene: UIWindowScene?
        private var cover: UIWindow?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(show),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(hide),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        func attach(to scene: UIWindowScene?) {
            guard self.scene !== scene else { return }
            hide()
            self.scene = scene
            // didMoveToWindow runs while SwiftUI is attaching its navigation
            // controllers. Presenting another window inside that traversal can
            // reenter UIKit's navigation-bar layout before containment is ready.
            DispatchQueue.main.async { [weak self, weak scene] in
                guard let self, let scene, self.scene === scene else { return }
                if scene.activationState != .foregroundActive { self.show() }
            }
        }

        @objc private func show() {
            guard cover == nil, let scene else { return }
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            let symbol = UIImageView(image: UIImage(systemName: "moon.stars.fill"))
            symbol.tintColor = .systemIndigo
            symbol.contentMode = .scaleAspectFit
            symbol.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(symbol)
            NSLayoutConstraint.activate([
                symbol.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                symbol.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
                symbol.widthAnchor.constraint(equalToConstant: 44),
                symbol.heightAnchor.constraint(equalToConstant: 44)
            ])
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.rootViewController = controller
            window.isUserInteractionEnabled = false
            window.accessibilityViewIsModal = true
            // Install the guard before UIKit emits any visibility callbacks.
            cover = window
            window.isHidden = false
        }

        @objc private func hide() {
            cover?.isHidden = true
            cover = nil
        }

        func stop() {
            hide()
            scene = nil // Invalidate any deferred initial presentation.
            NotificationCenter.default.removeObserver(self)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// MARK: - Welcome View (after signup)

struct WelcomeView: View {
    @SecureStorage("babyName") private var babyName: String = "Baby"
    let onContinue: () -> Void

    private var babyAge: String {
        guard let birthDate = SecureDataStore.shared.object(forKey: "babyBirthDate") as? Date else {
            return "—"
        }
        return BabyAgeFormatter.string(from: birthDate, to: Date())
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "EEF0FF"), Color(hex: "F8F0FF")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Illustration
                Text("🌙").font(.system(size: 80))

                VStack(spacing: 8) {
                    Text("Welcome, \(babyName)! 💜")
                        .font(.title.weight(.bold))
                    Text("We're ready to help you understand\nyour baby's sleep better.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Summary card
                VStack(spacing: 0) {
                    summaryRow(icon: "face.smiling", iconColor: Color(hex: "6B63D8"),
                               title: "Age", value: babyAge)
                    Divider().padding(.leading, 52)
                    summaryRow(icon: "sparkles", iconColor: Color(hex: "6B63D8"),
                               title: "Smart Features", value: "3 features enabled",
                               valueColor: .green)
                    Divider().padding(.leading, 52)
                    summaryRow(icon: "star.fill", iconColor: Color(hex: "6B63D8"),
                               title: "First Steps", value: "Track today's naps and sleep")
                }
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(.systemBackground))
                )
                .padding(.horizontal, 24)

                Spacer()

                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Text("Start Tracking Sleep")
                            .font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(hex: "6B63D8"))
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    private func summaryRow(icon: String, iconColor: Color,
                            title: String, value: String,
                            valueColor: Color = .secondary) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

enum BabyAgeFormatter {
    static func string(from birthDate: Date, to currentDate: Date) -> String {
        let months = Calendar.current
            .dateComponents([.month], from: birthDate, to: currentDate)
            .month ?? 0

        if months < 1 {
            return "Newborn"
        }

        if months < 24 {
            return "\(months) months"
        }

        return "\(months / 12) years"
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}
