//
//  UnknownWakeTimeConfirmationSheet.swift
//  BabySleepTracker
//
//  Created by MacBook on 19.06.2026.

//
//  Onboarding'de "Unknown" wake time seçildiğinde gösterilen,
//

import SwiftUI

struct UnknownWakeTimeConfirmationSheet: View {
    let onConfirm: () -> Void
    let onGoBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // İllüstrasyon
            ZStack {
                Circle()
                    .fill(Color(hex: "6B63D8").opacity(0.10))
                    .frame(width: 72, height: 72)
                Text("🌙")
                    .font(.system(size: 36))
            }
            .padding(.top, 28)

            VStack(spacing: 10) {
                Text("We'll use a default wake-up time")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Since you're not sure yet, we'll assume 7:00 AM as a starting point. You can log the actual wake-up time any day for more accurate predictions — and update this default anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            // Bilgi notu
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "6B63D8").opacity(0.7))
                    .padding(.top, 1)
                Text("Tip: Most parents find their baby settles into a rough daily rhythm after a couple of weeks of tracking — even if naps vary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hex: "6B63D8").opacity(0.06))
            )
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("Continue with default")
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

                Button(action: onGoBack) {
                    Text("Go back and set a time")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: "6B63D8"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
    }
}
