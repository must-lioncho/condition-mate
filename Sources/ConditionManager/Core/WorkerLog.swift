import Foundation

// Per-worker run log, persisted as JSONL (one file per worker under worker-logs/).
// Each line records WHEN a worker fired, WHY it fired (the trigger / condition),
// and WHAT EFFECT the run had — the three questions the dashboard "자세히" page
// answers.
//
// The log is the high-volume sibling of WorkerRegistry: a busy worker can emit a
// line every few seconds, so each file is size-capped and trimmed to its most
// recent lines. Files are independent, so a chatty worker (activity-sample) never
// crowds out a quiet one (timeline-sample).
//
// All file access runs on one serial queue: writes from the timer threads are
// async (never block the heartbeat), reads from the dashboard server are sync
// (so the page sees a consistent file).
final class WorkerLog {

    static let shared = WorkerLog()

    // Trim trigger and target. When a file grows past maxBytes we rewrite it
    // keeping only the last keepLines lines — bounding each worker to a few
    // hundred KB and the whole directory to a few MB.
    private let maxBytes = 256 * 1024
    private let keepLines = 500

    private let queue = DispatchQueue(label: "worker-log")
    private let fm = FileManager.default

    private init() {}

    private var dir: URL { AppPaths.sub("worker-logs") }
    private func fileURL(_ id: String) -> URL {
        dir.appendingPathComponent(sanitize(id) + ".jsonl")
    }

    // Append one run record. Cheap to call from any worker; the actual IO is
    // dispatched off the caller's thread.
    func append(_ id: String, why: String, effect: String, level: String = "info", at date: Date = Date()) {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        // Only stamp a level when it's noteworthy (error), so healthy lines stay compact.
        let lvl = level == "info" ? "" : ",\"lvl\":\(Self.j(level))"
        let line = "{\"t\":\(ms),\"why\":\(Self.j(why)),\"effect\":\(Self.j(effect))\(lvl)}\n"
        queue.async { [weak self] in
            guard let self = self else { return }
            let url = self.fileURL(id)
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    h.seekToEndOfFile()
                    h.write(data)
                } else {
                    // First write for this worker (or file missing): create it.
                    try? data.write(to: url)
                }
            }
            self.trimIfNeeded(url)
        }
    }

    // Read the most recent records for a worker, newest first. Runs synchronously
    // on the log queue so it can't race a concurrent append/trim.
    func recent(_ id: String, limit: Int = 500) -> [(t: Int, why: String, effect: String, level: String)] {
        queue.sync {
            let url = fileURL(id)
            guard let data = try? Data(contentsOf: url) else { return [] }
            var out: [(Int, String, String, String)] = []
            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
                let t = (obj["t"] as? Int) ?? 0
                let why = (obj["why"] as? String) ?? ""
                let effect = (obj["effect"] as? String) ?? ""
                let level = (obj["lvl"] as? String) ?? "info"
                out.append((t, why, effect, level))
            }
            if out.count > limit { out = Array(out.suffix(limit)) }
            return out.reversed().map { (t: $0.0, why: $0.1, effect: $0.2, level: $0.3) }
        }
    }

    // Rewrite a file down to its last keepLines lines once it grows past the cap.
    // Called on the log queue after every append; the stat is cheap and the
    // read+rewrite only fires when actually over the limit.
    private func trimIfNeeded(_ url: URL) {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var lines: [Substring] = []
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            .forEach { lines.append($0) }
        guard lines.count > keepLines else { return }
        let kept = lines.suffix(keepLines).joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // Keep filenames to a safe, predictable charset (worker ids are static slugs).
    private func sanitize(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // Minimal JSON string encoder (quotes + escapes).
    private static func j(_ s: String) -> String {
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
}
