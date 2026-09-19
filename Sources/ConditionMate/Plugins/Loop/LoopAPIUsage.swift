import Foundation

// Direct API usage has no Claude transcript. Never infer an unmarked Claude call's
// transport: the same model is used by both the CLI and the API.
enum LoopAPIUsage {
    struct Event {
        var id: String
        var at: Double
        var day: String
        var model: String
        var tokens: Int
        var cost: Double?
    }
    struct Snapshot {
        var events: [Event] = []
        var ambiguousDays: [String: Int] = [:]
        var unreadable = false
    }
    static func parse(_ text: String, timeZone: TimeZone) -> Snapshot {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone; fmt.dateFormat = "yyyy-MM-dd"
        var result = Snapshot()
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  r["action"] as? String == "model.usage",
                  let at = r["at"] as? Double, at > 0 else { continue }
            let day = fmt.string(from: Date(timeIntervalSince1970: at))
            let model = r["model"] as? String ?? ""
            let transport = r["transport"] as? String
            if transport == "cli" { continue }
            guard transport == "api" || (transport == nil && model.hasPrefix("gemini-")) else {
                result.ambiguousDays[day, default: 0] += 1
                continue
            }
            let tokens = r["total_tokens"] as? Int ?? 0
            result.events.append(Event(id: "api-\(index)", at: at, day: day, model: model,
                                       tokens: tokens, cost: r["cost_usd"] as? Double))
        }
        return result
    }
    private static let lock = NSLock()
    private static var cached: (String, Snapshot)?
    static func read(_ url: URL, timeZone: TimeZone) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return Snapshot(unreadable: true)
        }
        let stamp = "\(url.path)|\(attrs[.size] ?? 0)|\(attrs[.modificationDate] ?? "")|\(timeZone.identifier)"
        if let cached, cached.0 == stamp { return cached.1 }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Snapshot(unreadable: true) }
        let value = parse(text, timeZone: timeZone)
        cached = (stamp, value)
        return value
    }
}
