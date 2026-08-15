import SwiftUI

struct AddRecordView: View {
    
    let defaultDate: Date
    let editingRecord: SleepRecord?
    let onSave: (SleepRecord) -> Void

    @Environment(\.dismiss) var dismiss

    @State private var selectedDate: Date
    @State private var startTime: Date
    @State private var endTime: Date
    @ObservedObject var vm: AddRecordViewModel
    @State private var endManuallyEdited = false
    @State private var isProgrammaticChange = false
    @State private var isOngoing = false

    // Expanded picker state
    @State private var expandedField: ExpandedField? = nil

    enum ExpandedField { case date, start, end }

    init(defaultDate: Date, editingRecord: SleepRecord? = nil, vm: AddRecordViewModel, onSave: @escaping (SleepRecord) -> Void) {
        self.defaultDate = defaultDate
        self.editingRecord = editingRecord
        self.onSave = onSave
        self.vm = vm
        
        if let record = editingRecord {
            _selectedDate      = State(initialValue: Calendar.current.startOfDay(for: record.date))
            _startTime         = State(initialValue: record.date)
            _endTime           = State(initialValue: record.date.addingTimeInterval(TimeInterval(record.duration * 60)))
            _isOngoing         = State(initialValue: record.isOngoing)
            _endManuallyEdited = State(initialValue: true)
            vm.kind = record.kind
        } else {
            _selectedDate = State(initialValue: Calendar.current.startOfDay(for: defaultDate))
            _startTime    = State(initialValue: defaultDate)
            _endTime      = State(initialValue: defaultDate.addingTimeInterval(60 * 60))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // ── Kind Selector ──────────────────────
                    kindSelector
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    
                    // ── Still Sleeping Toggle ───────────────
                    if vm.kind != .break {
                        stillSleepingToggle
                            .padding(.horizontal, 16)
                    }

                    // ── Info Banner ────────────────────────
                    infoBanner
                        .padding(.horizontal, 16)

                    // ── WHEN section ───────────────────────
                    whenSection

                    // ── Sleep Summary ──────────────────────
                    sleepSummaryCard

                }
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(editingRecord != nil ? "Edit Sleep Session" : "Add Sleep Session")            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        save()
                    } label: {
                        Text(editingRecord != nil ? "Update" : "Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(saveEnabled ? Color.indigo : Color.secondary)
                            )
                    }
                    .disabled(!saveEnabled)
                }
            }
            .onAppear {
                if vm.kind == .nightSleep, !endManuallyEdited {
                    applyDefaultEndFromStart()
                }
            }
            .onChange(of: vm.kind) { _ in
                if !endManuallyEdited { applyDefaultEndFromStart() }
                validateTimesAfterStartChange()
            }
            .onChange(of: startTime) { _ in
                if isProgrammaticChange { return }
                validateTimesAfterStartChange()
            }
            .onChange(of: endTime) { _ in
                if isProgrammaticChange { return }
                endManuallyEdited = true
                validateTimesAfterEndChange()
            }
            .onChange(of: selectedDate) { _ in
                validateTimesAfterStartChange()
            }
        }
        .tint(.indigo)
    }
    
    private var saveEnabled: Bool {
        isOngoing || durationMinutes > 0
    }

    // MARK: - Kind Selector

    private var kindSelector: some View {
        HStack(spacing: 0) {
            kindButton(.dayNap)
            kindButton(.nightSleep)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var stillSleepingToggle: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.indigo.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Still sleeping")
                    .font(.subheadline.weight(.semibold))
                Text("Baby hasn't woken up yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOngoing.animation(.easeInOut(duration: 0.2))) // Geçişlerin yumuşak olması için animasyon eklendi
                .labelsHidden()
                .tint(.indigo)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func kindButton(_ kind: SleepKind) -> some View {
        let isSelected = vm.kind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { vm.kind = kind }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.indigo : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("😴")
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 3) {
                Text("Track your baby's sleep")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("We'll automatically subtract any breaks (wake periods) from the total sleep time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.indigo.opacity(0.06))
        )
    }

    // MARK: - WHEN Section

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHEN")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                // Date row
                fieldRow(
                    icon: "calendar.badge.clock",
                    label: "Date",
                    value: selectedDate.formatted(.dateTime.month(.abbreviated).day().year()),
                    isExpanded: expandedField == .date,
                    onTap: { toggle(.date) }
                )
                if expandedField == .date {
                    DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.wheel)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().padding(.leading, 52)

                // Start Time row
                fieldRow(
                    icon: "clock",
                    label: "Start Time",
                    value: TimeFormat.ampm(startTime),
                    isExpanded: expandedField == .start,
                    onTap: { toggle(.start) }
                )
                if expandedField == .start {
                    DatePicker("", selection: $startTime, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.wheel)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // ── End Time / In Progress Bölümü ──────────────────────
                if !isOngoing {
                    Divider().padding(.leading, 52)

                    fieldRow(
                        icon: "clock.badge.checkmark",
                        label: "End Time",
                        value: TimeFormat.ampm(endTime),
                        isExpanded: expandedField == .end,
                        onTap: { toggle(.end) }
                    )
                    if expandedField == .end {
                        DatePicker("", selection: $endTime, displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.wheel)
                            .environment(\.locale, Locale(identifier: "en_US"))
                            .frame(maxWidth: .infinity)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    Divider().padding(.leading, 52)
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.indigo.opacity(0.10))
                                .frame(width: 32, height: 32)
                            Image(systemName: "hourglass")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.indigo)
                        }
                        Text("End time")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("In progress")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                if vm.kind == .nightSleep {
                    Divider().padding(.leading, 52)
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 36)
                        Text("The selected date is the sleep start date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            // .animation takibine isOngoing durumu da eklendi:
            .animation(.easeInOut(duration: 0.2), value: expandedField)
            .animation(.easeInOut(duration: 0.2), value: isOngoing)
        }
    }

    private func fieldRow(icon: String, label: String, value: String,
                          isExpanded: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.indigo.opacity(0.10))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.indigo)
                }

                Text(label)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ field: ExpandedField) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedField = expandedField == field ? nil : field
        }
    }

    // MARK: - Sleep Summary Card

    private var sleepSummaryCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sleep Summary")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.indigo.opacity(0.6))
                }

                // Stats row
                HStack(spacing: 0) {
                    summaryStatCell(
                        label: "In Bed",
                        value: isOngoing ? "—" : TimeFormat.minutes(durationMinutes),
                        color: .primary
                    )
                    Divider().frame(height: 44)
                    summaryStatCell(label: "Breaks", value: "0m", color: .secondary)
                    Divider().frame(height: 44)
                    summaryStatCell(
                        label: "Net Sleep",
                        value: isOngoing ? "In progress" : TimeFormat.minutes(durationMinutes),
                        color: .indigo
                    )
                }

                if !isOngoing && crossesMidnight {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars")
                            .font(.system(size: 12))
                            .foregroundStyle(.indigo.opacity(0.7))
                        Text("Sleep crosses midnight (+1 day)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Tip
                HStack(alignment: .top, spacing: 8) {
                    Text("💡")
                        .font(.system(size: 14))
                    Text("Breaks are periods when your baby was awake between sleep.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }

        private func summaryStatCell(label: String, value: String, color: Color) -> some View {
            VStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Logic

        private var defaultEndMinutes: Int {
            switch vm.kind {
            case .dayNap:     return 60
            case .nightSleep: return 8 * 60
            case .break:      return 15
            }
        }

        private var crossesMidnight: Bool {
            !Calendar.current.isDate(startDateTime, inSameDayAs: endDateTime)
        }

        private func applyDefaultEndFromStart() {
            isProgrammaticChange = true
            defer { isProgrammaticChange = false }
            if let newEnd = Calendar.current.date(byAdding: .minute, value: defaultEndMinutes, to: startTime) {
                endTime = newEnd
            }
        }

        private func validateTimesAfterStartChange() {
            if vm.kind == .dayNap, endDateTime <= startDateTime { applyDefaultEndFromStart() }
            if vm.kind == .nightSleep, durationMinutes <= 0, !endManuallyEdited { applyDefaultEndFromStart() }
        }

        private func validateTimesAfterEndChange() {
            if vm.kind == .dayNap, endDateTime <= startDateTime { applyDefaultEndFromStart() }
        }

    private func save() {
        let record = SleepRecord(
            id: editingRecord?.id ?? UUID(),
            date: startDateTime,
            duration: isOngoing ? 0 : durationMinutes,
            kind: vm.kind,
            parentNapID: editingRecord?.parentNapID,
            isOngoing: isOngoing,
            createdAt: editingRecord?.createdAt ?? Date()
        )
        onSave(record)
        dismiss()
    }

        private func combine(date: Date, time: Date) -> Date {
            let cal = Calendar.current
            let d = cal.dateComponents([.year, .month, .day], from: date)
            let t = cal.dateComponents([.hour, .minute], from: time)
            var merged = DateComponents()
            merged.year = d.year; merged.month = d.month; merged.day = d.day
            merged.hour = t.hour; merged.minute = t.minute
            return cal.date(from: merged) ?? date
        }

        private var startDateTime: Date {
            let start = combine(date: selectedDate, time: startTime)
            guard shouldTreatNightStartAsPreviousEvening(start) else { return start }
            return Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start
        }

        private func shouldTreatNightStartAsPreviousEvening(_ start: Date) -> Bool {
            guard vm.kind == .nightSleep else { return false }
            guard Calendar.current.isDateInToday(selectedDate) else { return false }
            guard start > Date() else { return false }

            let startHour = Calendar.current.component(.hour, from: start)
            guard startHour >= 12 else { return false }

            let wakeHour = UserDefaults.standard.object(forKey: "typicalWakeHour") as? Double ?? 7.0
            let wakeMinute = UserDefaults.standard.object(forKey: "typicalWakeMinute") as? Double ?? 0.0
            let today = Calendar.current.startOfDay(for: Date())
            let typicalWake = Calendar.current.date(
                bySettingHour: Int(wakeHour),
                minute: Int(wakeMinute),
                second: 0,
                of: today
            ) ?? today.addingTimeInterval(7 * 60 * 60)

            return Date() < typicalWake
        }

        private var endDateTime: Date {
            var end = combine(date: selectedDate, time: endTime)
            if end < startDateTime {
                end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
            }
            return end
        }

        private var durationMinutes: Int {
            max(0, Int(endDateTime.timeIntervalSince(startDateTime) / 60))
        }
    }
