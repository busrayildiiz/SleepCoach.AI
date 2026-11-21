//
//  LandingView.swift
//  BabySleepTracker
//
//  Created by MacBook on 6.06.2026.
//

import Foundation
import SwiftUI

struct LandingView: View {
    @Binding var authState: AuthState

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Color(hex: "EEF0FF"), Color(hex: "F8F0FF")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Stars decoration
            starsDecoration

            VStack(spacing: 0) {
                // Moon illustration
                Spacer()
                moonIllustration
                    .padding(.top, 60)

                // Title
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        Text("Baby")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color(hex: "1A1A2E"))
                        Text("Sleep")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color(hex: "6B63D8"))
                        Text("Tracker")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color(hex: "1A1A2E"))
                    }

                    VStack(spacing: 4) {
                        Text("Understand your baby's sleep.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("Empower")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(hex: "6B63D8"))
                            Text("every day.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Page dots
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "6B63D8")).frame(width: 8, height: 8)
                        Circle().fill(Color(hex: "6B63D8").opacity(0.3)).frame(width: 8, height: 8)
                    }
                    .padding(.top, 4)
                }

                Spacer()

                // This version uses a protected local profile, not an online account.
                VStack(spacing: 16) {
                    Text("Create a local profile to start tracking sleep.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button { authState = .creatingAccount } label: {
                        Label("Create a Profile", systemImage: "person.crop.circle.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(hex: "6B63D8"))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.create")

                    Text("No email or password required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .background(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
    }

    // MARK: - Moon illustration

    private var moonIllustration: some View {
        ZStack {
            // Stars
            Text("⭐️").font(.system(size: 28)).offset(x: -90, y: -20)
            Text("⭐️").font(.system(size: 36)).offset(x: 100, y: -40)
            Text("✦").font(.system(size: 14)).foregroundStyle(Color(hex: "6B63D8").opacity(0.4)).offset(x: 60, y: 20)
            Text("✦").font(.system(size: 10)).foregroundStyle(Color(hex: "6B63D8").opacity(0.3)).offset(x: -60, y: 30)
            Text("✦").font(.system(size: 8)).foregroundStyle(Color(hex: "6B63D8").opacity(0.25)).offset(x: 120, y: 30)

            // Moon + Cloud
            VStack(spacing: -20) {
                Text("🌙")
                    .font(.system(size: 130))
                    .scaleEffect(x: -1) // flip
                HStack(spacing: -20) {
                    Text("☁️").font(.system(size: 70)).opacity(0.7)
                    Text("☁️").font(.system(size: 90)).opacity(0.5)
                }
            }
        }
        .frame(height: 260)
    }

    // MARK: - Stars

    private var starsDecoration: some View {
        ZStack {
            Text("✦").font(.system(size: 12))
                .foregroundStyle(Color(hex: "6B63D8").opacity(0.2))
                .position(x: 40, y: 120)
            Text("✦").font(.system(size: 8))
                .foregroundStyle(Color(hex: "6B63D8").opacity(0.15))
                .position(x: 340, y: 160)
            Text("✦").font(.system(size: 10))
                .foregroundStyle(Color(hex: "6B63D8").opacity(0.18))
                .position(x: 60, y: 300)
        }
    }
}
