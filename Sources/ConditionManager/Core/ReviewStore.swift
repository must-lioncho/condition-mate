import Foundation

// Persists the value-confirmation pipeline data:
//   - goals (priority list, global)
//   - per-day review: self-score + per-goal contribution, AI filter result,
//     admin score (coming soon).
// Confirmed value is 0 until the self + AI stages are done (admin pending).
final class ReviewStore {

    struct Goal: Codable { var id: String; var text: String }

    struct DayReview: Codable {
        var selfScore: Int? = nil               // 0-100, user's honest value estimate
        var contributions: [String: Int] = [:]  // goalID -> % contributed today
        var submittedSelf: Bool = false
        var aiScore: Int? = nil                  // 0-100 abuse-filter confidence
        var aiNote: String = ""
        var adminScore: Int? = nil               // coming soon (always nil for now)
    }

    private let dir: URL
    private let goalsURL: URL
    private let dayFmt: DateFormatter
    private(set) var goals: [Goal] = []

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConditionManager/review", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
        goalsURL = base.appendingPathComponent("goals.json")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        dayFmt = f

        loadGoals()
    }

    var todayKey: String { dayFmt.string(from: Date()) }

    // MARK: Goals

    private func loadGoals() {
        guard let data = try? Data(contentsOf: goalsURL),
              let g = try? JSONDecoder().decode([Goal].self, from: data) else { return }
        goals = g
    }
    private func saveGoals() {
        if let data = try? JSONEncoder().encode(goals) { try? data.write(to: goalsURL, options: .atomic) }
    }
    func addGoal(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        goals.append(Goal(id: UUID().uuidString, text: t))
        saveGoals()
    }
    func removeGoal(id: String) {
        goals.removeAll { $0.id == id }
        saveGoals()
    }

    // MARK: Per-day review

    private func reviewURL(_ day: String) -> URL { dir.appendingPathComponent("review-\(day).json") }

    func review(_ day: String) -> DayReview {
        guard let data = try? Data(contentsOf: reviewURL(day)),
              let r = try? JSONDecoder().decode(DayReview.self, from: data) else { return DayReview() }
        return r
    }
    func saveReview(_ r: DayReview, day: String) {
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: reviewURL(day), options: .atomic) }
    }
}
