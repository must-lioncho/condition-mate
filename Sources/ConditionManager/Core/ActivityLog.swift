import Foundation

// Per-minute activity timeline. One compact JSON line per minute, in a daily
// file. 1440 lines/day max => a few dozen KB; old files pruned after a week.
final class ActivityLog {

    private let dir: URL
    private let dayFormatter: DateFormatter
    private let retentionDays = 7

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConditionManager/activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        dayFormatter = df

        pruneOld()
    }

    private func fileURL(for date: Date) -> URL {
        dir.appendingPathComponent("activity-\(dayFormatter.string(from: date)).jsonl")
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

    // Today's samples parsed as dictionaries (for the abuse filter).
    func todaySamplesParsed() -> [[String: Any]] {
        let json = todaySamplesJSON()
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
