//
//  CreateAccountView.swift
//  BabySleepTracker
//
//  Created by MacBook on 6.06.2026.
//

import Foundation
import SwiftUI

struct CreateAccountView: View {
    @Binding var authState: AuthState

    @State private var step: Int = 1

    // Step 1
    @State private var fullName = ""

    // Step 2
    @State private var babyName = ""
    @State private var babyBirthDate = Calendar.current.date(byAdding: .month, value: -9, to: Date()) ?? Date()
    @State private var babyGender: BabyGender = .notSay

    // Step 3
    @State private var napReminders = true
    @State private var smartSuggestions = true
    @State private var napWindowTracking = true

    // Errors
    @State private var nameError: String? = nil
    @State private var babyNameError: String? = nil
    @State private var storageError: String? = nil

    enum BabyGender: String, CaseIterable {
        case girl = "Girl"
        case boy = "Boy"
        case notSay = "Prefer not to say"

        var icon: String {
            switch self {
            case .girl: return "👧"
            case .boy: return "👦"
            case .notSay: return "🙂"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Nav bar
                    navBar

                    // Content
                    switch step {
                    case 1: step1View
                    case 2: step2View
                    case 3: step3View
                    default: EmptyView()
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .privacySensitive()
        .alert("Couldn't save your profile", isPresented: Binding(
            get: { storageError != nil },
            set: { if !$0 { storageError = nil } }
        )) {
            Button("OK", role: .cancel) { storageError = nil }
        } message: {
            Text(storageError ?? "Please unlock your device and try again.")
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack {
            Button {
                if step == 1 { authState = .landing }
                else { withAnimation { step -= 1 } }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "6B63D8"))
                    .frame(width: 36, height: 36)
            }

            Spacer()

            Text("Step \(step) of 3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: "6B63D8"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Step 1: Local Profile

    private var step1View: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Illustration
                Text("🌙").font(.system(size: 60)).padding(.top, 8)

                VStack(spacing: 8) {
                    Text("Create Your Profile")
                        .font(.title2.weight(.bold))
                    Text("Let's get started with your\nprofile information.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Form
                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("Your Information")

                    inputField(
                        icon: "person",
                        placeholder: "Your Name",
                        text: $fullName,
                        error: $nameError,
                        isSecure: false
                    )

                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("No email or password is needed for your local profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                primaryButton("Continue") { validateStep1() }
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 2: Baby Info

    private var step2View: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Tell us about your baby")
                        .font(.title2.weight(.bold))
                    Text("This helps us personalize your baby's\nsleep experience.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("Baby Profile")

                    // Baby Name
                    inputField(
                        icon: "face.smiling",
                        placeholder: "Baby Name",
                        text: $babyName,
                        error: $babyNameError,
                        isSecure: false
                    )

                    // Birth Date
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .foregroundStyle(Color(hex: "6B63D8").opacity(0.6))
                                .frame(width: 20)
                            DatePicker("", selection: $babyBirthDate,
                                       in: ...Date(),
                                       displayedComponents: [.date])
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "en_US"))
                            Spacer()
                            Image(systemName: "calendar.badge.plus")
                                .foregroundStyle(Color(hex: "6B63D8").opacity(0.5))
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        Text("Date of Birth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }

                    // Gender
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Gender")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text("(Optional)")
                                .font(.caption)
                                .foregroundStyle(Color(hex: "6B63D8"))
                        }

                        HStack(spacing: 10) {
                            ForEach(BabyGender.allCases, id: \.self) { gender in
                                let isSelected = babyGender == gender
                                Button { babyGender = gender } label: {
                                    VStack(spacing: 6) {
                                        Text(gender.icon)
                                            .font(.system(size: 24))
                                        Text(gender.rawValue)
                                            .font(.caption.weight(isSelected ? .semibold : .regular))
                                            .foregroundStyle(isSelected ? Color(hex: "6B63D8") : .secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(isSelected ? Color(hex: "6B63D8").opacity(0.08) : Color(.systemBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(isSelected ? Color(hex: "6B63D8") : Color.primary.opacity(0.1),
                                                    lineWidth: isSelected ? 1.5 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Privacy note
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("We use this information to provide age-appropriate insights and recommendations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                primaryButton("Continue") { validateStep2() }
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 3: Smart Features

    private var step3View: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("⭐️").font(.system(size: 48)).padding(.top, 8)
                    Text("Enable Smart Features")
                        .font(.title2.weight(.bold))
                    Text("Get the most out of BabySleepTracker\nwith these intelligent features.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    featureToggle(
                        icon: "bell.fill", iconColor: Color(hex: "6B63D8"),
                        title: "Nap Reminders",
                        subtitle: "Get notified before expected naps based on wake windows.",
                        isOn: $napReminders
                    )
                    featureToggle(
                        icon: "sparkles", iconColor: Color(hex: "6B63D8"),
                        title: "Smart Suggestions",
                        subtitle: "Receive personalized tips and sleep insights.",
                        isOn: $smartSuggestions
                    )
                    featureToggle(
                        icon: "clock.fill", iconColor: Color(hex: "6B63D8"),
                        title: "Nap Window Tracking",
                        subtitle: "Track and analyze optimal wake windows.",
                        isOn: $napWindowTracking
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("You can change these settings anytime in the Settings page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                primaryButton("Create Profile") { completeSignup() }
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Reusable Components

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6B63D8"))
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: "6B63D8"))
        }
    }

    private func inputField(icon: String, placeholder: String,
                            text: Binding<String>, error: Binding<String?>,
                            isSecure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color(hex: "6B63D8").opacity(0.6))
                    .frame(width: 20)

                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .onChange(of: text.wrappedValue) { _ in error.wrappedValue = nil }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(error.wrappedValue != nil ? Color.red : Color.primary.opacity(0.1), lineWidth: 1)
            )

            if let err = error.wrappedValue {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption)
                    Text(err).font(.caption)
                }
                .foregroundStyle(.red)
            }
        }
    }

    private func featureToggle(icon: String, iconColor: Color,
                               title: String, subtitle: String,
                               isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn).labelsHidden().tint(Color(hex: "6B63D8"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: "6B63D8"))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Validation

    private func validateStep1() {
        var valid = true

        let name = fullName.trimmingCharacters(in: .whitespaces)
        if name.count < 2 {
            nameError = "Please enter your name (min 2 chars)."
            valid = false
        }

        if valid {
            withAnimation { step = 2 }
        }
    }

    private func validateStep2() {
        let name = babyName.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else {
            babyNameError = "Please enter your baby's name (min 2 chars)."
            return
        }
        guard name.count <= 30 else {
            babyNameError = "Name is too long (max 30 characters)."
            return
        }
        withAnimation { step = 3 }
    }

    private func completeSignup() {
        do {
            // Commit the complete profile together. No partial profile is saved
            // while the user is moving between setup steps.
            try SecureDataStore.shared.write([
                "parentName": fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                "babyName": babyName.trimmingCharacters(in: .whitespacesAndNewlines),
                "babyBirthDate": babyBirthDate,
                "babyGender": babyGender.rawValue,
                "profileSetupComplete_v1": true
            ])
        } catch {
            storageError = SecureDataStore.shared.failureMessage
                ?? "Your profile could not be saved. Please try again."
            return
        }
        UserDefaults.standard.set(napReminders, forKey: "napReminders")
        UserDefaults.standard.set(smartSuggestions, forKey: "smartSuggestions")
        UserDefaults.standard.set(napWindowTracking, forKey: "napWindowTracking")
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        UserDefaults.standard.set(true, forKey: "authComplete")
        authState = .loggedIn
    }
}
