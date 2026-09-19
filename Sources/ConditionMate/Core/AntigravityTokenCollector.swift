import Foundation

// MARK: - Antigravity Token Collector
// Extracts token usage and session history from ~/.gemini/antigravity-cli/brain.
// Reads each conversation directory's .system_generated/logs/transcript.jsonl.
struct AntigravitySessionRecord {
    let id: String
    let title: String
    let model: String
    let tokensUsed: Int
    let inTok: Int
    let outTok: Int
    let cwd: String
    let createdAt: Date
    let day: String
    let effort: String
}

final class AntigravityTokenCollector {
    static let shared = AntigravityTokenCollector()

    private var brainURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
    }

    func fetchSessions(since cutoff: Date) -> [AntigravitySessionRecord] {
        let fm = FileManager.default
        guard let convDirs = try? fm.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var records: [AntigravitySessionRecord] = []
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone
        dayFmt.dateFormat = "yyyy-MM-dd"

        for dir in convDirs {
            let tpath = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard fm.fileExists(atPath: tpath.path) else { continue }
            guard let rv = try? tpath.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = rv.contentModificationDate, mtime >= cutoff else { continue }

            guard let data = try? Foundation.Data(contentsOf: tpath) else { continue }
            let convId = dir.lastPathComponent

            var firstPrompt = ""
            var firstDate: Date?
            var inChars = 0
            var outChars = 0
            var thinkChars = 0
            var cwd = ""

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let type = obj["type"] as? String else { return }

                if let c = obj["created_at"] as? String, let ts = isoFmt.date(from: c) ?? ISO8601DateFormatter().date(from: c) {
                    if firstDate == nil { firstDate = ts }
                }

                if type == "USER_INPUT" {
                    if let content = obj["content"] as? String {
                        inChars += content.count
                        if firstPrompt.isEmpty {
                            let l1 = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                            firstPrompt = String(l1.trimmingCharacters(in: .whitespaces).prefix(80))
                        }
                    }
                } else if type == "PLANNER_RESPONSE" {
                    if let content = obj["content"] as? String { outChars += content.count }
                    if let thinking = obj["thinking"] as? String {
                        outChars += thinking.count
                        thinkChars += thinking.count
                    }
                    if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            if let args = tc["args"] as? [String: Any] {
                                if cwd.isEmpty, let c = args["Cwd"] as? String { cwd = c }
                                if let s = try? JSONSerialization.data(withJSONObject: args) {
                                    outChars += s.count
                                }
                            }
                        }
                    }
                }
            }

            guard let sessionDate = firstDate ?? rv.contentModificationDate else { continue }
            let inTokens = Int(Double(inChars) / 2.8)
            let outTokens = Int(Double(outChars) / 3.2)
            let totalTokens = inTokens + outTokens
            guard totalTokens > 0 else { continue }

            let title = firstPrompt.isEmpty ? "Antigravity Session (\(convId.prefix(8)))" : firstPrompt
            let effort = thinkChars > 0 ? "thinking" : "default"
            records.append(AntigravitySessionRecord(
                id: convId,
                title: title,
                model: "Gemini Pro/Flash",
                tokensUsed: totalTokens,
                inTok: inTokens,
                outTok: outTokens,
                cwd: cwd,
                createdAt: sessionDate,
                day: dayFmt.string(from: sessionDate),
                effort: effort
            ))
        }

        return records
    }
}
