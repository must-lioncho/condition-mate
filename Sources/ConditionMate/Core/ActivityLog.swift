import Foundation

// Per-minute activity timeline. One compact JSON line per minute, in a daily
// file. 1440 lines/day max => a few dozen KB. Files are kept effectively
// forever (the 히스토리 tab reads them back); the very high retention cap only
// bounds truly ancient files so the directory can't grow without any limit.
final class ActivityLog {

    private let dir: URL
    private let dayFormatter: DateFormatter
    private let retentionDays = 3650   // ~10 years => practically unlimited history

    init() {
        dir = AppPaths.sub("activity")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        dayFormatter = df

        pruneOld()
    }

    // NAMING RULE — DO NOT CHANGE. `dayFormatter` above deliberately carries no timeZone,
    // so it slices on the machine's local day. That is a STORAGE SHARD name, NOT a date
    // boundary: it only decides which file a minute's line lands in. The date boundary is
    // decided by the READERS, each of which converts a sample's `t` (epoch seconds) under
    // Settings.shared.displayTimeZone — see activeSecondsByDay(days:) and historyJSON(days:).
    //
    // Changing the naming rule would strand every file already on disk under a different
    // rule with no migration, so the boundary was moved to the read side instead
    // (2026-09-05, issue/2026-09-05-token-view-timezone-directive.md). Consequence to know:
    // opening activity-2026-09-05.jsonl by hand shows a SYSTEM-LOCAL day, not a KST day.
    private func fileURL(for date: Date) -> URL {
        dir.appendingPathComponent("activity-\(dayFormatter.string(from: date)).jsonl")
    }

    // Every activity-*.jsonl shard name on disk, newest first.
    private func shardDays() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("activity-"), name.hasSuffix(".jsonl") else { continue }
            out.append(String(name.dropFirst("activity-".count).dropLast(".jsonl".count)))
        }
        out.sort(by: >)                                       // newest first
        return out
    }

    // A `yyyy-MM-dd` formatter on the DISPLAY timezone — the actual date boundary.
    // Built per call (not cached) because the header selector can change the display
    // timezone at any moment; a cached formatter would keep serving the old boundary.
    private func displayDayFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = Settings.shared.displayTimeZone
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    // Shards to read in order to cover `days` display-timezone days: the requested window
    // PLUS one extra shard on each end.
    //
    // WHY the padding: the shard name is a SYSTEM-LOCAL day but the bucket key is a
    // DISPLAY-TIMEZONE day, so a sample can land in a day key its own shard is not named
    // after. Concretely, with the 2026-09-05 KST default on an IST (UTC+5.5) machine,
    // KST day D begins at IST 20:30 of D-1 — those first 3h30m of KST day D physically
    // live inside activity-<D-1>.jsonl. Without the older-end pad, the oldest requested
    // day would silently lose them.
    //
    // The newer end needs no arithmetic: the list is newest-first and starts at the newest
    // shard that exists, so every shard that could spill INTO the window is already in.
    private func shardsCovering(days: Int) -> [String] {
        Array(shardDays().prefix(max(1, days) + 1))
    }

    // Parse one shard into (t, line-object) pairs. Bad lines are skipped, as before.
    private func shardObjects(_ day: String) -> [[String: Any]] {
        let url = dir.appendingPathComponent("activity-\(day).jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            out.append(o)
        }
        return out
    }

    // One minute's snapshot.
    struct Sample {
        var rate = 0, active = 0, bpm = 0, key = 0, mouse = 0, mult = 1
        var phase = "-", app = "-", profile = "-", track = "-", site = "-", tier = "소극"
        var working = false
        var meeting = false
    }

    func append(_ s: Sample) {
        let t = Int(Date().timeIntervalSince1970)
        let line = "{\"t\":\(t),\"rate\":\(s.rate),\"active\":\(s.active),"
            + "\"phase\":\"\(s.phase)\",\"bpm\":\(s.bpm),\"working\":\(s.working),"
            + "\"key\":\(s.key),\"mouse\":\(s.mouse),\"mult\":\(s.mult),\"meeting\":\(s.meeting),"
            + "\"app\":\(jsonString(s.app)),\"profile\":\(jsonString(s.profile)),"
            + "\"track\":\(jsonString(s.track)),\"site\":\(jsonString(s.site)),"
            + "\"tier\":\(jsonString(s.tier))}\n"
        let url = fileURL(for: Date())
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    }

    // Today's samples as a JSON array string (built from the raw lines).
    func todaySamplesJSON() -> String {
        let url = fileURL(for: Date())
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "[]" }
        let lines = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return "[" + lines.joined(separator: ",") + "]"
    }

    // Minimal JSON string encoder (quotes + escapes). Korean passes through as UTF-8.
    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    // Compact per-day samples for the 히스토리 tab. Returns a JSON array, newest
    // day first, of {"day":"YYYY-MM-DD","samples":[{t,active,tier,meeting,mult,app}]}.
    // Only the fields the dashboard's carry-forward + timeBuckets + deep-focus
    // logic needs are re-emitted, so many days stay a light payload (the browser
    // runs the very same JS as the "today" view, keeping one source of truth).
    //
    // The "day" a sample belongs to is NOT its file's name — it is its own `t` (epoch)
    // rendered under Settings.shared.displayTimeZone. Shards are read with one file of
    // padding on each end and every sample is re-bucketed, so a sample that spilled across
    // the display-timezone midnight lands on the day the rest of the UI calls it.
    // The wire contract is unchanged: [{"day":"YYYY-MM-DD","samples":[{t,active,mult,
    // meeting,tier,app}]}], newest day first, samples in time order.
    func historyJSON(days: Int) -> String {
        let dayFmt = displayDayFormatter()
        var byDay: [String: [(t: Int, row: String)]] = [:]
        for shard in shardsCovering(days: days) {
            for o in shardObjects(shard) {
                let t = (o["t"] as? Int) ?? 0
                let active = (o["active"] as? Int) ?? 0
                let mult = (o["mult"] as? Int) ?? 1
                let meeting = (o["meeting"] as? Bool) ?? false
                let tier = (o["tier"] as? String) ?? "소극"
                let app = (o["app"] as? String) ?? "-"
                let key = dayFmt.string(from: Date(timeIntervalSince1970: Double(t)))
                let row = "{\"t\":\(t),\"active\":\(active),\"mult\":\(mult),"
                    + "\"meeting\":\(meeting),\"tier\":\(jsonString(tier)),\"app\":\(jsonString(app))}"
                byDay[key, default: []].append((t, row))
            }
        }
        // Emit at most `days` days. The padding shard can only add days OLDER than the
        // window (or fill days already in it), so trimming from the newest end is right.
        let take = byDay.keys.sorted(by: >).prefix(max(1, days))
        let out = take.map { day -> String in
            let rows = (byDay[day] ?? []).sorted { $0.t < $1.t }.map(\.row)
            return "{\"day\":\(jsonString(day)),\"samples\":[\(rows.joined(separator: ","))]}"
        }
        return "[" + out.joined(separator: ",") + "]"
    }

    // Per-DISPLAY-TIMEZONE-day active seconds (sum of each sample's `active` field). Used by
    // the token view's 가치(value) mode to weight token value by the human time actually
    // spent — fewer hours for the same output scores higher (time-efficiency multiplier).
    //
    // The key must be the SAME day string dashboardTokens builds from Settings.displayTimeZone,
    // because AppDelegate joins the two maps on it. Before 2026-09-05 this keyed off the shard
    // FILE NAME (system-local) and the two agreed only by accident, while this Mac's system zone
    // happened to equal the display zone. With the KST display default on an IST machine they
    // diverge by 3h30m every day — nothing breaks visibly, the multiplier just goes quietly
    // wrong — so the bucket is now computed from each sample's own `t`, with one shard of
    // padding on each end (see shardsCovering(days:)).
    func activeSecondsByDay(days: Int) -> [String: Int] {
        let dayFmt = displayDayFormatter()
        var out: [String: Int] = [:]
        for shard in shardsCovering(days: days) {
            for o in shardObjects(shard) {
                let t = (o["t"] as? Int) ?? 0
                let key = dayFmt.string(from: Date(timeIntervalSince1970: Double(t)))
                out[key, default: 0] += (o["active"] as? Int) ?? 0
            }
        }
        return out
    }

    // Today's samples parsed as dictionaries (for the abuse filter).
    func todaySamplesParsed() -> [[String: Any]] {
        samplesParsed(for: Date())
    }

    // Samples of an arbitrary day parsed as dictionaries. The 6h-gap work-start
    // detector reads yesterday+today so an overnight block keeps its true start.
    func samplesParsed(for date: Date) -> [[String: Any]] {
        guard let raw = try? String(contentsOf: fileURL(for: date), encoding: .utf8) else { return [] }
        let json = "[" + raw.split(separator: "\n").filter { !$0.isEmpty }.joined(separator: ",") + "]"
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private func pruneOld() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        for url in files {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
