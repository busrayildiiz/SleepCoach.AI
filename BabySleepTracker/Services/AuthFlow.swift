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

struct RootView: View {
    @AppStorage("authComplete") private var authComplete: Bool = false
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    @State private var authState: AuthState = .landing

    var body: some View {
        Group {
            if authComplete {
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
                        onboardingComplete = true
                        authComplete = true
                        authState = .loggedIn
                    }
                case .loggedIn:
                    ContentView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authState)
    }
}

// MARK: - Welcome View (after signup)

struct WelcomeView: View {
    @AppStorage("babyName") private var babyName: String = "Baby"
    @AppStorage("babyBirthDate") private var babyBirthDate: Double = Date().timeIntervalSince1970
    let onContinue: () -> Void

    private var babyAge: String {
        BabyAgeFormatter.string(
            from: Date(timeIntervalSince1970: babyBirthDate),
            to: Date()
        )
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
