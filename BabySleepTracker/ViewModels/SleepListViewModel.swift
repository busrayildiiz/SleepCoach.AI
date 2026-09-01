import Foundation
import SwiftUI

@MainActor
final class SleepListViewModel: ObservableObject {

    @Published private(set) var records: [SleepRecord] = []
    @Published var errorMessage: String?

    private let store: SleepStoring
    private let api: SleepAPI

    init(store: SleepStoring = SleepStore(),
         api: SleepAPI = MockSleepAPI()) {
        self.store = store
        self.api = api

    }

    // MARK: - Lifecycle

    func onAppear() {
        load()
    }

    // MARK: - Load

    func load() {
        Task { await loadAsync() }
    }

    /// Awaitable entry point for `load()`. Exists so tests can `await` the
    /// real completion of the fetch instead of guessing at a fixed sleep
    /// duration, which is inherently flaky under CI/simulator load.
    @discardableResult
    func loadAsync() async -> Bool {
        do {
            let data = try await api.fetchRecords()
            self.records = data
            return true
        } catch {
            self.errorMessage = "Failed to load"
            return false
        }
    }

    // MARK: - CRUD

    func add(_ record: SleepRecord) {
        records.insert(record, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        persist()
    }

    // MARK: - Grouping

    func groupedByDay() -> [(day: Date, items: [SleepRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.date)
        }

        return grouped
            .map { (day: $0.key, items: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.day > $1.day }
    }

    func records(for day: Date) -> [SleepRecord] {
        let calendar = Calendar.current
        return records.filter {
            calendar.isDate($0.date, inSameDayAs: day)
        }
    }

    func totalMinutes(for day: Date) -> Int {
        records(for: day).map(\.duration).reduce(0, +)
    }

    // MARK: - Persist

    private func persist() {
        do {
            try store.save(records)
        } catch {
            errorMessage = "Failed to save records."
        }
    }
}
