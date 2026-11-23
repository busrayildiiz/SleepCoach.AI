//
//  SettingView.swift
//  BabySleepTracker
//
//  Created by MacBook on 6.06.2026.
//

import Foundation
import SwiftUI
import PhotosUI

@MainActor
struct SettingsView: View {

    @State private var records: [SleepRecord] = []
    @State private var napRemindersOn = true
    @State private var smartSuggestionsOn = true
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var avatarImage: UIImage? = nil
    @State private var showAppearanceSheet = false
    @State private var showProfileEdit = false
    @State private var showDataHandling = false
    @State private var showDeleteConfirmation = false
    @State private var showCloudAIConsent = false
    @State private var cloudAIEnabled = CloudAIPrivacy.shared.hasConsent
    @State private var storageError: String? = nil
    @State private var avatarImportTask: Task<Void, Never>? = nil
    @SecureStorage("babyName") private var babyName: String = "Baby"
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private func loadRecords() {
        guard SecureDataStore.shared.isAvailable else {
            records = []
            avatarImage = nil
            return
        }
        records = SleepRecordPersistence().load() ?? []
        avatarImage = SecureDataStore.shared.data(forKey: "avatarImageData").flatMap { UIImage(data: $0) }
        cloudAIEnabled = CloudAIPrivacy.shared.hasConsent
    }

    // MARK: - Computed

    private var napsOnly: [SleepRecord] {
        records.filter { $0.kind != .break }
    }

    private func avgDailyNap(_ accounting: SleepAccounting) -> (minutes: Int, days: Int)? {
        let minutes = (0..<7).compactMap { offset -> Int? in
            guard let day = accounting.calendar.date(byAdding: .day, value: -offset, to: accounting.now) else { return nil }
            let subtotal = accounting.completedSubtotal(on: day, kind: .dayNap)
            if case .incomplete(let minutes, reason: .incomplete) = subtotal { return minutes }
            return subtotal.comparableMinutes
        }
        guard !minutes.isEmpty else { return nil }
        return (minutes.reduce(0, +) / minutes.count, minutes.count)
    }

    private func recordingFrequency(_ accounting: SleepAccounting) -> String {
        let days = (0..<7).compactMap {
            accounting.calendar.date(byAdding: .day, value: -$0, to: accounting.now)
        }
        let active = days.filter { day in
            napsOnly.contains { $0.date <= accounting.now && accounting.calendar.isDate($0.date, inSameDayAs: day) }
        }.count
        return "\(active) of 7 days"
    }

    private func weekVsLastWeek(_ accounting: SleepAccounting) -> Int? {
        func total(_ offsets: Range<Int>) -> Int? {
            let subtotals = offsets.compactMap { offset -> Int? in
                guard let day = accounting.calendar.date(byAdding: .day, value: -offset, to: accounting.now) else { return nil }
                return accounting.completedSubtotal(on: day).comparableMinutes
            }
            return subtotals.count == offsets.count ? subtotals.reduce(0, +) : nil
        }
        guard let recent = total(1..<8), let previous = total(8..<15), previous > 0 else { return nil }
        return Int(Double(recent - previous) / Double(previous) * 100)
    }

    private var appearanceLabel: String {
        switch appAppearance {
        case "light": return "Light"
        case "dark":  return "Dark"
        default:      return "System"
        }
    }

    private var babyGenderEmoji: String {
        let gender = SecureDataStore.shared.string(forKey: "babyGender") ?? "Prefer not to say"
        switch gender {
        case "Girl": return "👧"
        case "Boy":  return "👦"
        default:     return "👶"
        }
    }

    // MARK: - Body

    var body: some View {
        let accounting = SleepAccounting(records: records, now: Date(), calendar: .current)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                profileCard
                sleepInsightCard(change: weekVsLastWeek(accounting))
                atAGlanceCard(averageNap: avgDailyNap(accounting), frequency: recordingFrequency(accounting))
                napRemindersSection
                babyProfileSection
                preferencesAndQuickActions
                privacySection
                supportSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .accessibilityIdentifier("settings.scroll")
        .background(Color(.systemGroupedBackground))
        .onAppear { loadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)
            .receive(on: RunLoop.main)) { _ in
            loadRecords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .secureDataStoreDidChange)
            .receive(on: RunLoop.main)) { _ in
            loadRecords()
        }
        .onDisappear { avatarImportTask?.cancel() }
        .confirmationDialog("Appearance", isPresented: $showAppearanceSheet, titleVisibility: .visible) {
            Button("System") { appAppearance = "system" }
            Button("Light")  { appAppearance = "light" }
            Button("Dark")   { appAppearance = "dark" }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showProfileEdit) {
            ProfileEditSheet()
        }
        .sheet(isPresented: $showDataHandling) {
            DataHandlingSheet()
        }
        .confirmationDialog("Delete all data on this device?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All Local Data", role: .destructive) { deleteLocalData() }
                .accessibilityIdentifier("privacy.delete.confirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes this app's profile, photo, sleep records, and saved coaching on this device. This action cannot be undone.")
        }
        .confirmationDialog(CloudAIPrivacy.disclosureTitle, isPresented: $showCloudAIConsent,
                            titleVisibility: .visible) {
            Button("Allow Google Gemini") { updateCloudAIConsent(allowed: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(CloudAIPrivacy.disclosureMessage)
        }
        .alert("Couldn't complete this change", isPresented: Binding(
            get: { storageError != nil },
            set: { if !$0 { storageError = nil } }
        )) {
            Button("OK", role: .cancel) { storageError = nil }
        } message: {
            Text(storageError ?? "Please unlock your device and try again.")
        }
        .privacySensitive()
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("Settings")
                .font(.largeTitle.weight(.bold))
        }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        HStack(spacing: 14) {

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 64, height: 64)

                    if let img = avatarImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                    } else {
                        Text(babyGenderEmoji)
                            .font(.system(size: 36))
                    }
                }

                PhotosPicker(selection: $selectedPhoto,
                             matching: .images,
                             photoLibrary: .shared()) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo)
                            .frame(width: 22, height: 22)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .onChange(of: selectedPhoto) { newItem in
                importAvatar(newItem)
            }

            Button {
                showProfileEdit = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(babyName) & You")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text("Keep tracking, keep growing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("💜")
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Sleep Insight Card

    private func sleepInsightCard(change: Int?) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.indigo.opacity(0.07))

            Text("🌙")
                .font(.system(size: 64))
                .opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 16)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.indigo)
                    Text("Sleep Insight")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.indigo)
                }

                Text(change.map { change in
                    if change == 0 { return "Recorded sleep was the same across the last two weeks." }
                    return "Recorded sleep was \(abs(change))% \(change > 0 ? "longer" : "shorter") over the last seven days than the previous seven."
                } ?? "Weekly comparisons need confirmed recording coverage.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    // MARK: - At a Glance

    private func atAGlanceCard(averageNap: (minutes: Int, days: Int)?, frequency: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(babyName) at a Glance")
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 14)

            Divider()

            HStack(spacing: 0) {
                glanceCell(icon: "face.smiling", iconColor: .indigo,
                           label: "Age", value:  babyAgeText)
                Divider().frame(height: 44)
                glanceCell(icon: "moon.fill", iconColor: .indigo,
                           label: "Avg recorded naps",
                           value: averageNap.map { "\(TimeFormat.minutes($0.minutes)) · \($0.days) d" } ?? "Unknown")
                Divider().frame(height: 44)
                glanceCell(icon: "chart.line.uptrend.xyaxis", iconColor: .green,
                           label: "Recording frequency",
                           value: frequency,
                           valueColor: .green)
            }
            .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func glanceCell(icon: String, iconColor: Color,
                            label: String, value: String,
                            valueColor: Color = .primary) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor.opacity(0.7))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Nap & Reminders Section

    private var napRemindersSection: some View {
        settingsSection(title: "NAP & REMINDERS") {
            settingsRowToggle(
                icon: "clock.fill", iconColor: .indigo,
                title: "Nap Reminders",
                subtitle: "Schedule and alerts",
                isOn: $napRemindersOn
            )
            Divider().padding(.leading, 52)
            settingsRowToggle(
                icon: "bell.fill", iconColor: .indigo,
                title: "Smart Suggestions",
                subtitle: "Get personalized nap tips",
                isOn: $smartSuggestionsOn
            )
            Divider().padding(.leading, 52)
            settingsRowChevron(
                icon: "calendar", iconColor: .indigo,
                title: "Nap Window",
                subtitle: "Set daily nap windows"
            )
        }
    }

    // MARK: - Baby Profile Section

    private var babyProfileSection: some View {
        settingsSection(title: "BABY PROFILE") {
            Button {
                showProfileEdit = true
            } label: {
                settingsRowChevron(
                    icon: "face.smiling", iconColor: .indigo,
                    title: "\(babyName)'s Profile",
                    subtitle: "Age, sleep needs, and more"
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 52)
            settingsRowChevron(
                icon: "list.clipboard", iconColor: .indigo,
                title: "Development Info",
                subtitle: "Milestones & insights"
            )
        }
    }

    // MARK: - Preferences & Quick Actions (2 column)

    private var preferencesAndQuickActions: some View {
        HStack(alignment: .top, spacing: 10) {
            // Preferences
            VStack(spacing: 0) {
                Text("PREFERENCES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                Button {
                    showAppearanceSheet = true
                } label: {
                    compactRow(icon: "circle.lefthalf.filled", iconColor: .indigo,
                               title: "Appearance", subtitle: appearanceLabel)
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 14)
                compactRow(icon: "globe", iconColor: .indigo,
                           title: "Language", subtitle: "English")
                Divider().padding(.leading, 14)
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.indigo.opacity(0.10))
                            .frame(width: 30, height: 30)
                        Image(systemName: "bell.slash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Quiet Hours")
                            .font(.caption.weight(.medium))
                        Text("10 PM – 7 AM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .padding(.bottom, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )

            // Quick Actions
            VStack(spacing: 0) {
                Text("QUICK ACTIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                compactRow(icon: "doc.badge.arrow.up", iconColor: .indigo,
                           title: "Export Sleep", subtitle: "PDF / CSV")
                Divider().padding(.leading, 14)
                compactRow(icon: "square.grid.2x2", iconColor: .indigo,
                           title: "Widget Settings", subtitle: "Lock & Home Screen")
                    .padding(.bottom, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        settingsSection(title: "PRIVACY & DATA") {
            VStack(alignment: .leading, spacing: 8) {
                if CloudAIPrivacy.isCloudAIAvailable {
                    Toggle("Cloud AI coaching", isOn: Binding(
                        get: { cloudAIEnabled },
                        set: { allowed in
                            if allowed { showCloudAIConsent = true }
                            else { updateCloudAIConsent(allowed: false) }
                        }
                    ))
                    .tint(.indigo)
                    Text("Optional sleep summaries are shared with Google Gemini only after you allow it. You can turn this off at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("On-device guidance")
                        .font(.subheadline.weight(.medium))
                    Text("Cloud AI coaching is not enabled in this version. Sleep tracking and on-device guidance remain available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider().padding(.leading, 14)
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete All Local Data", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .accessibilityIdentifier("deleteAllLocalData")
        }
    }

    private func updateCloudAIConsent(allowed: Bool) {
        do {
            if allowed {
                try CloudAIPrivacy.shared.grantConsent()
            } else {
                try CloudAIPrivacy.shared.revokeConsent()
                SleepCoachOrchestrator.shared.clearCloudAIState()
            }
            cloudAIEnabled = CloudAIPrivacy.shared.hasConsent
        } catch {
            cloudAIEnabled = CloudAIPrivacy.shared.hasConsent
            storageError = SecureDataStore.shared.failureMessage
                ?? "Your privacy preference could not be saved. Please try again."
        }
    }

    private func importAvatar(_ item: PhotosPickerItem?) {
        avatarImportTask?.cancel()
        guard let item else { return }
        let generation = SecureDataStore.shared.generation
        avatarImportTask = Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      !Task.isCancelled,
                      let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
                // Render a bounded copy: imported location/camera metadata never
                // enters the private store or an outbound AI request.
                let scale = min(1, 512 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let sanitized = rendered.pngData(), !Task.isCancelled else { return }
                try SecureDataStore.shared.write(["avatarImageData": sanitized], ifGeneration: generation)
                avatarImage = rendered
            } catch {
                guard !Task.isCancelled else { return }
                storageError = SecureDataStore.shared.failureMessage
                    ?? "Your photo could not be saved. Please try again."
            }
        }
    }

    private func deleteLocalData() {
        avatarImportTask?.cancel()
        // Permission is withdrawn immediately, even if secure deletion needs retry.
        UserDefaults.standard.set(false, forKey: "cloudAISharingEnabled")
        SleepCoachOrchestrator.shared.clearPrivateState()
        do {
            try SecureDataStore.shared.eraseAll()
            records = []
            avatarImage = nil
            selectedPhoto = nil
            cloudAIEnabled = false
            UserDefaults.standard.set(false, forKey: "onboardingComplete")
            UserDefaults.standard.set(false, forKey: "authComplete")
        } catch {
            storageError = SecureDataStore.shared.failureMessage
                ?? "Your data could not be deleted. Please try again."
        }
    }

    // MARK: - Support Section

    private var supportSection: some View {
        settingsSection(title: "SUPPORT") {
            settingsRowChevron(
                icon: "questionmark.circle", iconColor: .indigo,
                title: "Help Center",
                subtitle: "Articles and guides"
            )
            Divider().padding(.leading, 52)
            settingsRowChevron(
                icon: "message", iconColor: .indigo,
                title: "Contact Us",
                subtitle: "We're here to help"
            )
            Divider().padding(.leading, 52)
            Button {
                showDataHandling = true
            } label: {
                settingsRowChevron(
                    icon: "checkmark.shield", iconColor: .indigo,
                    title: "How Your Data Is Used",
                    subtitle: "Storage, sharing, and deletion"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("privacy.dataHandling")
            Divider().padding(.leading, 52)
            settingsRowChevron(
                icon: "info.circle", iconColor: .indigo,
                title: "About",
                subtitle: "Version 1.0.0"
            )
        }
    }

    // MARK: - Reusable components

    @ViewBuilder
    private func settingsSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func settingsRowChevron(icon: String, iconColor: Color,
                                    title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func settingsRowToggle(icon: String, iconColor: Color,
                                   title: String, subtitle: String,
                                   isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(isOn.wrappedValue ? "On" : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOn.wrappedValue ? .indigo : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }
    
    private var babyAgeText: String {
           let birthDate: Date?
           if let saved = SecureDataStore.shared.object(forKey: "babyBirthDate") as? Date {
               birthDate = saved
           } else if let seconds = SecureDataStore.shared.object(forKey: "babyBirthDate") as? Double {
               birthDate = Date(timeIntervalSince1970: seconds)
           } else {
               birthDate = nil
           }
           guard let birth = birthDate else { return "—" }
           let months = Calendar.current.dateComponents([.month], from: birth, to: Date()).month ?? 0
           if months < 1 { return "Newborn" }
           if months < 24 { return "\(months) months" }
           return "\(months / 12) years"
       }

    private func compactRow(icon: String, iconColor: Color,
                            title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}


private struct DataHandlingSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("On this device", text: "Your profile, photo, sleep and wake records, and saved coaching are stored in encrypted files. The encryption key is kept in the device's Keychain. Photo location and camera metadata are removed before the photo is saved.")

                    section("App preferences", text: "Appearance and general feature preferences are saved as ordinary app settings. These settings do not contain your profile, photo, or sleep history.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cloud AI")
                            .font(.headline)
                        if CloudAIPrivacy.isCloudAIAvailable {
                            Text("This development build can use cloud AI only after you allow sharing in Settings.")
                            Text(CloudAIPrivacy.disclosureMessage)
                        } else {
                            Text("Cloud AI coaching is disabled in this version. Sleep tracking and on-device guidance remain available without sending summaries to an AI provider.")
                        }
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                    section("Deleting local data", text: "Delete All Local Data removes this app's profile, photo, sleep records, private caches, and saved coaching from this device. It also stops future cloud AI requests. It cannot recall information previously sent to Google.")

                    section("Device backups", text: "Your device's backup settings may include the app's encrypted files and Keychain items. Earlier backups can retain copies after local deletion. Cloud sync and shared caregiver accounts are not available in this version.")
                }
                .padding(20)
            }
            .navigationTitle("How Your Data Is Used")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("privacy.dataHandling.done")
                }
            }
        }
        .accessibilityIdentifier("privacy.dataHandling.sheet")
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
