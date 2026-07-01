import Foundation

// Append-only log of BGM preference signals (dislike now; volume changes later)
// with a rich context snapshot per event. The aggregated TrackPreferenceStore
// drives live selection; this log keeps the raw history so the motivation
// algorithm can later learn context-conditional preferences — e.g. a track that
// is only disliked late at night vs. genuinely disliked. See .issue/goal-11.md.
final class TrackEventLog {

    // Everything known about the moment a signal fired.
    struct Context {
        var signal = "dislike"          // dislike | volumeDown | volumeUp
        var trackKey = "-"              // file name (preference identity)
        var title = "-"
        var trackBPM = 0
        var targetBPM = 0
        var phase = "-"
        var profile = "-"
        var app = "-"
        var site = "-"
        var norm = 0.0                  // activity / personal peak (0...1)
        var rate = 0
        var sessionSeconds = 0
        var todaySeconds = 0
        var totalSeconds = 0
        var hour = 0                    // local hour 0...23 (time-of-day bucket source)
        var weekday = 0                 // Calendar weekday 1...7
        var meeting = false
    }

    private let fileURL: URL

    init() {
        fileURL = AppPaths.sub("events").appendingPathComponent("track-events.jsonl")
    }

    func append(_ c: Context) {
        let t = Int(Date().timeIntervalSince1970)
        let line = "{\"t\":\(t),\"signal\":\(jsonString(c.signal)),"
            + "\"trackKey\":\(jsonString(c.trackKey)),\"title\":\(jsonString(c.title)),"
            + "\"trackBPM\":\(c.trackBPM),\"targetBPM\":\(c.targetBPM),"
            + "\"phase\":\(jsonString(c.phase)),\"profile\":\(jsonString(c.profile)),"
            + "\"app\":\(jsonString(c.app)),\"site\":\(jsonString(c.site)),"
            + "\"norm\":\(String(format: "%.3f", c.norm)),\"rate\":\(c.rate),"
            + "\"sessionSeconds\":\(c.sessionSeconds),\"todaySeconds\":\(c.todaySeconds),"
            + "\"totalSeconds\":\(c.totalSeconds),\"hour\":\(c.hour),\"weekday\":\(c.weekday),"
            + "\"meeting\":\(c.meeting)}\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    }

    // Minimal JSON string encoder (quotes + escapes). Korean passes through UTF-8.
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
}
