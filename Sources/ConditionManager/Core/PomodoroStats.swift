import Foundation

/// Durable pomodoro completion history — the single source of truth behind the rail's
/// "오늘 N/2" tracker.
///
/// Completions are recorded exclusively by the server (the heartbeat's wall-clock check in
/// AppDelegate), never by a webview: the old design kept the daily count in the rail's
/// localStorage and only bumped it on a manual 🍅 tap, so a page reload — or the rail simply
/// not being open at 25:00 — silently lost the pomodoro. Persisting completions here makes
/// the count survive reloads and app restarts, and keeps it auditable against actions.jsonl
/// (every recordCompletion pairs with a pomodoro.complete event).
final class PomodoroStats {
    struct Completion: Codable {
        var t: Int            // completion moment (UTC epoch seconds)
        var mode: String      // session mode at completion ("pomodoro")
        var activeSecs: Int   // activity-gated seconds accrued inside the wall-clock interval
    }

    private struct FileV1: Codable {
        var version: Int
        var completions: [Completion]
    }

    private(set) var completions: [Completion] = []
    private let fileURL: URL

    init() {
        fileURL = AppPaths.base.appendingPathComponent("pomodoro-stats.json")
        load()
    }

    func recordCompletion(mode: String, activeSecs: Int, at date: Date = Date()) {
        completions.append(Completion(t: Int(date.timeIntervalSince1970),
                                      mode: mode, activeSecs: activeSecs))
        save()
    }

    /// Completions on the display-timezone "today". Storage stays UTC epoch; only the
    /// day-bucket boundary follows cm.timeZone, the same rule every 표시 surface uses.
    func todayCount(now: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Settings.shared.displayTimeZone
        return completions.reduce(0) { n, c in
            cal.isDate(Date(timeIntervalSince1970: TimeInterval(c.t)), inSameDayAs: now) ? n + 1 : n
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(FileV1.self, from: data) else { return }
        completions = file.completions
    }

    private func save() {
        let file = FileV1(version: 1, completions: completions)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
