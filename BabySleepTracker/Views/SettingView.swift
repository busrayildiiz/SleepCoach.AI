//
//  SettingView.swift
//  BabySleepTracker
//
//  Created by MacBook on 6.06.2026.
//

import Foundation
import SwiftUI
import PhotosUI

struct SettingsView: View {

    @State private var records: [SleepRecord] = []
    @State private var napRemindersOn = true
    @State private var smartSuggestionsOn = true
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var avatarImage: UIImage? = nil
    @State private var showAppearanceSheet = false
    @State private var showProfileEdit = false
    @AppStorage("babyName") private var babyName: String = "Baby"
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private func loadRecords() {
        if let data = UserDefaults.standard.data(forKey: "sleepRecords"),
           let decoded = try? JSONDecoder().decode([SleepRecord].self, from: data) {
            records = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "avatarImageData") {
            avatarImage = UIImage(data: data)
        }
    }

    // MARK: - Computed

    private var napsOnly: [SleepRecord] {
        records.filter { $0.kind != .break }
    }

    private var breaksOnly: [SleepRecord] {
        records.filter { $0.kind == .break }
    }

    private var avgDailyNap: Int {
        let sevenAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let thisWeek = napsOnly.filter { $0.date >= sevenAgo }
        guard !thisWeek.isEmpty else { return 0 }
        let total = thisWeek.reduce(0) { $0 + $1.totalMinutes(breaks: breaksOnly) }
        return total / max(1, Set(thisWeek.map {
            Calendar.current.startOfDay(for: $0.date)
        }).count)
    }

    private var consistencyLabel: String {
        let days = (0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }
        let active = days.filter { day in
            napsOnly.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
        }.count
        let pct = Double(active) / 7.0
        switch pct {
        case 0.86...: return "Excellent"
        case 0.57...: return "Good"
        case 0.29...: return "Fair"
        default:      return "Low"
        }
    }

    private var weekVsLastWeek: Int {
        let cal = Calendar.current
        let now = Date()
        let thisStart  = cal.date(byAdding: .day, value: -7,  to: now)!
        let lastStart  = cal.date(byAdding: .day, value: -14, to: now)!
        func total(_ from: Date, _ to: Date) -> Int {
            let recs = napsOnly.filter { $0.date >= from && $0.date < to }
            return recs.reduce(0) { $0 + $1.totalMinutes(breaks: breaksOnly) }
        }
        let t = total(thisStart, now)
        let l = total(lastStart, thisStart)
        guard l > 0 else { return 0 }
        return Int(Double(t - l) / Double(l) * 100)
    }

    private var appearanceLabel: String {
        switch appAppearance {
        case "light": return "Light"
        case "dark":  return "Dark"
        default:      return "System"
        }
    }

    private var babyGenderEmoji: String {
        let gender = UserDefaults.standard.string(forKey: "babyGender") ?? "Prefer not to say"
        switch gender {
        case "Girl": return "👧"
        case "Boy":  return "👦"
        default:     return "👶"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    profileCard
                    sleepInsightCard
                    atAGlanceCard
                    napRemindersSection
                    babyProfileSection
                    preferencesAndQuickActions
                    supportSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .onAppear { loadRecords() }
            .onReceive(NotificationCenter.default.publisher(for: .sleepRecordsDidChange)) { _ in
                loadRecords()
            }
        }
        .confirmationDialog("Appearance", isPresented: $showAppearanceSheet, titleVisibility: .visible) {
            Button("System") { appAppearance = "system" }
            Button("Light")  { appAppearance = "light" }
            Button("Dark")   { appAppearance = "dark" }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showProfileEdit) {
            ProfileEditSheet()
        }
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
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        avatarImage = image
                        UserDefaults.standard.set(data, forKey: "avatarImageData")
                    }
                }
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

    private var sleepInsightCard: some View {
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

                let pct = abs(weekVsLastWeek)
                let direction = weekVsLastWeek >= 0 ? "longer" : "shorter"
                Text(pct > 0
                     ? "\(babyName) slept \(pct)% \(direction) this week than last week."
                     : "Keep tracking to see weekly insights.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    // MARK: - At a Glance

    private var atAGlanceCard: some View {
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
                           label: "Avg Daily Nap",
                           value: avgDailyNap > 0 ? TimeFormat.minutes(avgDailyNap) : "–")
                Divider().frame(height: 44)
                glanceCell(icon: "chart.line.uptrend.xyaxis", iconColor: .green,
                           label: "Consistency",
                           value: consistencyLabel,
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
                Divider().padding(.leading, 14)
                compactRow(icon: "person.2", iconColor: .indigo,
                           title: "Caregivers", subtitle: "3 members")
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
            settingsRowChevron(
                icon: "checkmark.shield", iconColor: .indigo,
                title: "Privacy & Policy",
                subtitle: "Your data is safe with us"
            )
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
           if let saved = UserDefaults.standard.object(forKey: "babyBirthDate") as? Date {
               birthDate = saved
           } else if let seconds = UserDefaults.standard.object(forKey: "babyBirthDate") as? Double {
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
