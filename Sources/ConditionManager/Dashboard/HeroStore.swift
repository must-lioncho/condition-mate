import Foundation
import SQLite3

// Read-only bridge to the team's praise record, merged from TWO sources and
// served as GET /api/hero/list:
//
//   1. heroes.db (SQLite) — owned by the `/hero` skill. Entries recorded from
//      Claude Code. The app never opens it for writing.
//   2. <data>/hero/slack.jsonl — owned by slack-eyes-daemon.mjs (append-only).
//      Every message in the Slack #hero channel, backfilled once and then kept
//      live, with the praise structured by the daemon's regex → AI parser
//      (line.parsed / line.parsedBy). Lines the parser could not read keep
//      parsed == nil and surface as raw text only.
//
// Both stay single-writer; merging happens here at read time. Dedup key is the
// Slack ts for Slack rows and the DB id for skill rows, so the same praise
// recorded in both places shows once (Slack wins — it carries the permalink).
enum HeroStore {
    // The skill owns the DB location; override with CM_HERO_DB if the workspace moves.
    static var dbPath: String {
        if let env = ProcessInfo.processInfo.environment["CM_HERO_DB"], !env.isEmpty {
            return NSString(string: env).expandingTildeInPath
        }
        return NSString(string: "~/Work/departtment_service/projects/agent-mustcompany/storage/hero/heroes.db")
            .expandingTildeInPath
    }

    // Daemon-owned Slack feed. Injected by the app at startup (AppPaths.sub);
    // the default mirrors the daemon's own CM_DATA_DIR fallback.
    static var slackFile: URL = {
        let base = ProcessInfo.processInfo.environment["CM_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".condition-manager")
        return base.appendingPathComponent("hero/slack.jsonl")
    }()

    /// Merged feed for the dashboard Hero tab. `error` is only set when BOTH
    /// sources are unavailable — one missing source is normal (praise recorded
    /// only in Slack, or the daemon not yet backfilled) and must not blank the
    /// tab.
    static func listJSON() -> String {
        let dbRows = databaseEntries()
        let slackRows = slackEntries()
        if dbRows == nil && slackRows.isEmpty {
            return encode(["entries": [], "db": dbPath, "slack": slackFile.path, "error": "no-source"])
        }
        // Slack first so its permalink-bearing row wins the dedup.
        var byKey: [String: [String: Any]] = [:]
        var order: [String] = []
        for row in slackRows + (dbRows ?? []) {
            guard let key = row["key"] as? String else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key] = byKey[key] ?? row
        }
        let entries = order.compactMap { byKey[$0] }
            .sorted { ($0["at"] as? Int ?? 0) > ($1["at"] as? Int ?? 0) }
        return encode([
            "entries": entries,
            "db": dbPath,
            "slack": slackFile.path,
            "slackCount": slackRows.count,
            "dbCount": dbRows?.count ?? 0,
        ])
    }

    // ---------------------------------------------------------------- sources

    /// One line per Slack #hero message. `parsed` present = the daemon could
    /// structure it; otherwise the raw text is all we show.
    private static func slackEntries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: slackFile, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ts = o["ts"] as? String else { continue }
            let p = o["parsed"] as? [String: Any]
            let at = o["at"] as? Int ?? Int(Double(ts) ?? 0)
            out.append([
                "key": "slack:\(ts)",
                "no": ((p?["entryNo"] as? Int) ?? 0),
                "at": at,
                "created_at": stamp(at),
                "nominator": o["nominator"] as? String ?? "",
                "nominee": p?["nominee"] as? String ?? "",
                "nominee_korean": p?["nominee_korean"] as? String ?? "",
                "skill": p?["skill"] as? String ?? "",
                "level": p?["level"] as? Int ?? 0,
                "reason": p?["reason"] as? String ?? "",
                "next_todo": p?["next_todo"] as? String ?? "",
                "next_level_goal": p?["next_level_goal"] as? String ?? "",
                "parsed": p != nil,
                "parsedBy": o["parsedBy"] as? String ?? "",
                "text": o["text"] as? String ?? "",
                "permalink": o["permalink"] as? String ?? "",
                "source": "slack",
            ])
        }
        return out
    }

    /// nil = the skill's DB is absent or unreadable (distinct from "empty").
    private static func databaseEntries() -> [[String: Any]]? {
        let path = dbPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, created_at, nominator, nominee, nominee_korean, skill, level,
               reason, next_todo, next_level_goal
        FROM heroes ORDER BY id DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let created = text(1)
            rows.append([
                "key": "db:\(id)",
                "no": id,
                "at": epoch(created),
                "created_at": created,
                "nominator": text(2),
                "nominee": text(3),
                "nominee_korean": text(4),
                "skill": text(5),
                "level": Int(sqlite3_column_int64(stmt, 6)),
                "reason": text(7),
                "next_todo": text(8),
                "next_level_goal": text(9),
                "parsed": true,
                "parsedBy": "skill",
                "text": "",
                "permalink": "",
                "source": "db",
            ])
        }
        return rows
    }

    // ---------------------------------------------------------------- time

    // The skill writes "YYYY-MM-DD HH:mm" in local time. Parsed to an epoch only
    // for sorting and the leaderboard's period filter — the display string stays
    // whatever the source recorded.
    private static let dbFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func epoch(_ s: String) -> Int {
        if let d = dbFormatter.date(from: s) { return Int(d.timeIntervalSince1970) }
        return 0
    }

    private static func stamp(_ at: Int) -> String {
        guard at > 0 else { return "" }
        return dbFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{\"entries\":[]}" }
        return s
    }
}
