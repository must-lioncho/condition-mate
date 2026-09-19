import Foundation

@main struct LoopAPIUsageCheck {
    static func main() throws {
        let rows: [[String: Any]] = [
            ["at": 1789750000, "action": "model.usage", "model": "gemini-flash-lite-latest", "total_tokens": 100, "cost_usd": 0.01],
            ["at": 1789750000, "action": "model.usage", "model": "claude-haiku", "transport": "cli", "total_tokens": 200],
            ["at": 1789750000, "action": "model.usage", "model": "claude-haiku", "transport": "api", "total_tokens": 300],
            ["at": 1789750000, "action": "model.usage", "model": "claude-haiku", "total_tokens": 400],
            ["at": 1789750000, "action": "translate", "total_tokens": 500]
        ]
        let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n{partial"
        let value = LoopAPIUsage.parse(text, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        precondition(value.events.count == 2)
        precondition(value.events.reduce(0) { $0 + $1.tokens } == 400)
        precondition(value.events.last?.cost == nil)
        precondition(value.ambiguousDays.values.reduce(0, +) == 1)
        let utc = LoopAPIUsage.parse(text, timeZone: TimeZone(secondsFromGMT: 0)!)
        precondition(utc.events.count == 2)
        precondition(LoopAPIUsage.read(URL(fileURLWithPath: "/nonexistent/usage.jsonl"), timeZone: .current).unreadable)
        if CommandLine.arguments.count > 1 {
            let live = LoopAPIUsage.read(URL(fileURLWithPath: CommandLine.arguments[1]), timeZone: TimeZone(identifier: "Asia/Kolkata")!)
            let yesterday = live.events.filter { $0.day == "2026-09-18" }
            print("2026-09-18 IST: \(yesterday.count) API calls, \(yesterday.reduce(0) { $0 + $1.tokens }) tokens")
            precondition(yesterday.count >= 197)
        }
        print("LoopAPIUsage checks passed")
    }
}
