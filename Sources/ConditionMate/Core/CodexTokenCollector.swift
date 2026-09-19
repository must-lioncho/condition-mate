import Foundation
import SQLite3

// MARK: - Codex Token Collector
// Extracts token usage and session history from ~/.codex/state_5.sqlite.
// Reads the `threads` table: id, title, model, tokens_used, cwd, created_at_ms.
struct CodexSessionRecord {
    let id: String
    let title: String
    let model: String
    let tokensUsed: Int
    let cwd: String
    let createdAt: Date
    let day: String
    let reasoningEffort: String
}

final class CodexTokenCollector {
    static let shared = CodexTokenCollector()

    private var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    }

    func fetchSessions(since cutoff: Date) -> [CodexSessionRecord] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        let query = "SELECT id, title, model, tokens_used, cwd, created_at_ms, reasoning_effort FROM threads WHERE created_at_ms >= ? AND tokens_used > 0 ORDER BY created_at_ms DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, cutoffMs)

        var records: [CodexSessionRecord] = []
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone
        dayFmt.dateFormat = "yyyy-MM-dd"

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "o1"
            let tokens = Int(sqlite3_column_int64(stmt, 3))
            let cwd = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let ms = sqlite3_column_int64(stmt, 5)
            let effort = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            let day = dayFmt.string(from: date)

            records.append(CodexSessionRecord(
                id: id,
                title: title.isEmpty ? "Codex Task (\(id.prefix(8)))" : title,
                model: model,
                tokensUsed: tokens,
                cwd: cwd,
                createdAt: date,
                day: day,
                reasoningEffort: effort
            ))
        }
        return records
    }
}
