import Foundation

// Persists cumulative play-time. Writes are debounced (dirty flag + periodic flush)
// to avoid hammering disk; the JSON is tiny so memory cost is negligible.
final class TimeStore {

    struct Data: Codable {
        var totalSeconds: Double = 0
        var perApp: [String: Double] = [:]
        var perDay: [String: Double] = [:] // key: yyyy-MM-dd
    }

    private(set) var data = Data()
    private var dirty = false

    private let fileURL: URL
    private let dayFormatter: DateFormatter

    init() {
        fileURL = AppPaths.base.appendingPathComponent("stats.json")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        dayFormatter = df

        load()
    }

    private func load() {
        guard let raw = try? Foundation.Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Data.self, from: raw) else { return }
        data = decoded
    }

    func add(seconds: Double, app: String) {
        let day = dayFormatter.string(from: Date())
        data.totalSeconds += seconds
        data.perApp[app, default: 0] += seconds
        data.perDay[day, default: 0] += seconds
        dirty = true
    }

    var todaySeconds: Double {
        data.perDay[dayFormatter.string(from: Date())] ?? 0
    }

    // Top apps by accumulated time, for display.
    func topApps(limit: Int = 5) -> [(bundleID: String, seconds: Double)] {
        data.perApp
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    func saveIfNeeded() {
        guard dirty else { return }
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
            dirty = false
        }
    }
}
