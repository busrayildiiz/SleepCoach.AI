//
//  ProfileEditSheet.swift
//  BabySleepTracker
//

import SwiftUI

struct ProfileEditSheet: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - Stored values (AppStorage)
    @AppStorage("parentName")        private var parentName:        String = ""
    @AppStorage("babyName")          private var babyName:          String = ""
    @AppStorage("babyGender")        private var babyGender:        String = "Prefer not to say"
    @AppStorage("typicalWakeHour")   private var typicalWakeHour:   Double = 07.0
    @AppStorage("typicalWakeMinute") private var typicalWakeMinute: Double = 0.0
    @AppStorage("typicalBedHour")    private var typicalBedHour:    Double = 19.0  // 19:00
    @AppStorage("typicalBedMinute")  private var typicalBedMinute:  Double = 30.0

    // MARK: - Local edit state
    @State private var editParentName:  String = ""
    @State private var editBabyName:    String = ""
    @State private var editBabyGender:  String = "Prefer not to say"
    @State private var editBirthDate:   Date   = Date()
    @State private var editWakeTime:    Date   = Date()
    @State private var editBedtime:     Date   = Date()

    // MARK: - UI state
    @State private var parentNameError: String? = nil
    @State private var babyNameError:   String? = nil
    @State private var showSavedBanner  = false

    // Doğum tarihi UserDefaults'ta Date olarak saklanıyor
    private let birthDateKey = "babyBirthDate"

    // MARK: - Computed

    private var babyAgeText: String {
        let months = Calendar.current.dateComponents([.month], from: editBirthDate, to: Date()).month ?? 0
        if months < 1  { return "Newborn" }
        if months < 24 { return "\(months) months old" }
        return "\(months / 12) years old"
    }

    private var expectedNapCount: String {
        let months = Calendar.current.dateComponents([.month], from: editBirthDate, to: Date()).month ?? 0
        switch months {
        case 0...3:   return "Variable (newborn)"
        case 4...5:   return "3–4 naps/day"
        case 6...7:   return "2–3 naps/day"
        case 8...14:  return "2 naps/day"
        case 15...17: return "1–2 naps/day (transition)"
        default:      return "1 nap/day"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    avatarHeader
                    parentSection
                    babySection
                    sleepDefaultsSection
                    infoCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveIfValid() }
                        .font(.headline)
                        .foregroundStyle(Color(hex: "6B63D8"))
                }
            }
            .overlay(savedBanner, alignment: .top)
        }
        .onAppear { loadCurrentValues() }
    }

    // MARK: - Avatar Header

    private var avatarHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(hex: "6B63D8").opacity(0.10))
                    .frame(width: 72, height: 72)
                Text(genderEmoji(editBabyGender))
                    .font(.system(size: 40))
            }
            Text(editBabyName.isEmpty ? "Baby" : editBabyName)
                .font(.title3.weight(.bold))
            Text(babyAgeText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Parent Section

    private var parentSection: some View {
        formSection(title: "PARENT") {
            formRow(icon: "person.fill", label: "Your Name") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Full name", text: $editParentName)
                        .onChange(of: editParentName) { _ in parentNameError = nil }
                    if let err = parentNameError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Baby Section

    private var babySection: some View {
        formSection(title: "BABY") {
            formRow(icon: "face.smiling", label: "Baby's Name") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $editBabyName)
                        .onChange(of: editBabyName) { _ in babyNameError = nil }
                    if let err = babyNameError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Divider().padding(.leading, 52)

            formRow(icon: "calendar", label: "Date of Birth") {
                DatePicker(
                    "",
                    selection: $editBirthDate,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "en_US"))
            }

            Divider().padding(.leading, 52)

            // Gender picker
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "6B63D8").opacity(0.10))
                            .frame(width: 32, height: 32)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: "6B63D8"))
                    }
                    Text("Gender")
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                HStack(spacing: 8) {
                    ForEach(["Girl", "Boy", "Prefer not to say"], id: \.self) { gender in
                        let isSelected = editBabyGender == gender
                        Button { editBabyGender = gender } label: {
                            VStack(spacing: 4) {
                                Text(genderEmoji(gender))
                                    .font(.system(size: 20))
                                Text(gender == "Prefer not to say" ? "–" : gender)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color(hex: "6B63D8") : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected
                                          ? Color(hex: "6B63D8").opacity(0.08)
                                          : Color(.systemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        isSelected ? Color(hex: "6B63D8") : Color.primary.opacity(0.1),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider().padding(.leading, 52)

            // Age-based nap count (read-only, otomatik)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.10))
                        .frame(width: 32, height: 32)
                    Image(systemName: "moon.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Text("Expected Naps")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(expectedNapCount)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Sleep Defaults Section

    private var sleepDefaultsSection: some View {
        formSection(title: "TYPICAL SLEEP TIMES") {

            // Wake time
            formRow(icon: "sunrise.fill", label: "Usually wakes up") {
                DatePicker("", selection: $editWakeTime, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "en_US"))
            }

            Divider().padding(.leading, 52)

            // Bedtime
            formRow(icon: "moon.stars.fill", label: "Usually goes to bed") {
                DatePicker("", selection: $editBedtime, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "en_US"))
            }

            Divider().padding(.leading, 52)

            // Açıklama
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "6B63D8").opacity(0.7))
                    .padding(.top, 1)
                Text("These times are used as defaults when no daily record is added. They improve nap and bedtime predictions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("💡")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 4) {
                Text("Why do we ask?")
                    .font(.subheadline.weight(.semibold))
                Text("Typical wake and bedtimes help the AI Coach predict naps even on days you forget to log. The more data, the better the predictions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "6B63D8").opacity(0.06))
        )
    }

    // MARK: - Saved Banner

    private var savedBanner: some View {
        Group {
            if showSavedBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Profile saved!")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: showSavedBanner)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func formSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func formRow(icon: String, label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "6B63D8").opacity(0.10))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "6B63D8"))
            }
            Text(label)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func genderEmoji(_ gender: String) -> String {
        switch gender {
        case "Girl": return "👧"
        case "Boy":  return "👦"
        default:     return "🙂"
        }
    }

    // MARK: - Load / Save

    private func loadCurrentValues() {
        editParentName = UserDefaults.standard.string(forKey: "parentName") ?? ""
        editBabyName   = UserDefaults.standard.string(forKey: "babyName") ?? ""
        editBabyGender = UserDefaults.standard.string(forKey: "babyGender") ?? "Prefer not to say"

        // Doğum tarihi
        if let saved = UserDefaults.standard.object(forKey: birthDateKey) as? Date {
            editBirthDate = saved
        } else if let ts = UserDefaults.standard.object(forKey: birthDateKey) as? Double {
            editBirthDate = Date(timeIntervalSince1970: ts)
        } else {
            editBirthDate = Calendar.current.date(byAdding: .month, value: -9, to: Date()) ?? Date()
        }

        // Wake time
        editWakeTime = makeTime(
            hour:   Int(typicalWakeHour),
            minute: Int(typicalWakeMinute)
        )

        // Bedtime
        editBedtime = makeTime(
            hour:   Int(typicalBedHour),
            minute: Int(typicalBedMinute)
        )
    }

    private func saveIfValid() {
        var valid = true

        let pName = editParentName.trimmingCharacters(in: .whitespaces)
        if pName.count < 2 {
            parentNameError = "Please enter your name (min 2 chars)."
            valid = false
        }

        let bName = editBabyName.trimmingCharacters(in: .whitespaces)
        if bName.count < 2 {
            babyNameError = "Please enter baby's name (min 2 chars)."
            valid = false
        }

        guard valid else { return }

        // AppStorage'a yaz
        parentName = pName
        babyName   = bName
        babyGender = editBabyGender

        // Doğum tarihi
        UserDefaults.standard.set(editBirthDate, forKey: birthDateKey)

        // Wake time bileşenleri
        let wakeComps = Calendar.current.dateComponents([.hour, .minute], from: editWakeTime)
        typicalWakeHour   = Double(wakeComps.hour   ?? 7)
        typicalWakeMinute = Double(wakeComps.minute  ?? 0)

        // Bedtime bileşenleri
        let bedComps = Calendar.current.dateComponents([.hour, .minute], from: editBedtime)
        typicalBedHour   = Double(bedComps.hour   ?? 19)
        typicalBedMinute = Double(bedComps.minute  ?? 30)

        // Orchestrator'ı tetikle — yeni profil verisi ile snapshot yenile
        // SleepListView .onReceive ile bu notification'ı dinleyip generate() çağırıyor.
        NotificationCenter.default.post(name: .babyProfileDidChange, object: nil)
        
        // Banner göster, kapat
        withAnimation { showSavedBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { showSavedBanner = false }
            dismiss()
        }
    }

    private func makeTime(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour:   hour,
            minute:          minute,
            second:          0,
            of:              Date()
        ) ?? Date()
    }
}
