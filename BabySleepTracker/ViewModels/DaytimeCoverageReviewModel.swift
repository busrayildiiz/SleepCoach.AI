import Foundation

struct DaytimeCoverageReviewModel {
    enum Feedback: Equatable {
        case preparationFailed, changed, calendarChanged, saved, saveFailed, withdrawn, withdrawalFailed
    }

    private let storage: ObservationStorage
    private var adapter: TrustedObservationAdapter { .init(defaults: storage.defaults) }
    private var reviewCalendar: Calendar?
    private(set) var inspection: DaytimeCoverageInspection?
    private(set) var review: DaytimeCoverageReview?
    private(set) var selection: ParentDaytimeAttestation?
    private(set) var feedback: Feedback?

    init(storage: ObservationStorage) {
        self.storage = storage
    }

    var canSave: Bool { review != nil && selection != nil }

    var canWithdraw: Bool {
        guard review != nil, let status = inspection?.status else { return false }
        return status == .confirmed || status == .incomplete
    }

    mutating func start(day: Date, at now: Date, calendar: Calendar) {
        let calendar = DaytimeReviewWindow.capture(calendar)
        reviewCalendar = calendar
        selection = nil
        feedback = nil
        review = adapter.prepareDaytimeReview(for: day, at: now, calendar: calendar, using: storage)
        inspection = adapter.inspectDaytimeReview(for: day, at: now, calendar: calendar)
        if let review {
            if inspection?.blocker != nil || !review.draft.isCurrent(at: now, calendar: calendar) {
                expireReview()
            }
        } else if inspection?.blocker == nil {
            feedback = .preparationFailed
        }
    }

    mutating func startAgain(at now: Date, calendar: Calendar) {
        refresh(at: now, calendar: calendar)
        if let day = inspection?.day { start(day: day, at: now, calendar: calendar) }
    }

    mutating func choose(_ answer: ParentDaytimeAttestation) {
        guard review != nil else { return }
        selection = answer
        feedback = nil
    }

    mutating func deferReview() {
        inspection = nil
        review = nil
        reviewCalendar = nil
        selection = nil
        feedback = nil
    }

    mutating func refresh(at now: Date, calendar: Calendar) {
        guard let day = inspection?.day, let reviewCalendar else { return }
        guard reviewCalendar == DaytimeReviewWindow.capture(calendar) else {
            deferReview()
            feedback = .calendarChanged
            return
        }
        let updated = adapter.inspectDaytimeReview(for: day, at: now, calendar: reviewCalendar)
        if let review, updated.blocker != nil || !review.draft.isCurrent(at: now, calendar: reviewCalendar) {
            expireReview()
        } else if feedback == .withdrawn, inspection?.status != updated.status {
            feedback = nil
        }
        inspection = updated
    }

    mutating func save(at now: Date, calendar: Calendar) {
        refresh(at: now, calendar: calendar)
        guard let review, let selection else { return }
        let result = review.draft.saveAnswer(selection, at: now, using: storage, calendar: calendar)
        refresh(at: now, calendar: calendar)
        switch result {
        case .committed:
            self.selection = nil
            if self.review != nil { feedback = .saved }
        case .failed: feedback = .saveFailed
        case .stale: expireReview()
        }
    }

    mutating func withdraw(at now: Date, calendar: Calendar) {
        refresh(at: now, calendar: calendar)
        guard canWithdraw, let review else { return }
        let result = review.draft.withdrawAnswer(using: storage, calendar: calendar)
        if result == .committed {
            self.review = nil
            selection = nil
        }
        refresh(at: now, calendar: calendar)
        switch result {
        case .committed:
            feedback = inspection?.status == .unknown ? .withdrawn : .changed
        case .failed: feedback = .withdrawalFailed
        case .stale: expireReview()
        }
    }

    private mutating func expireReview() {
        review = nil
        selection = nil
        feedback = .changed
    }
}
