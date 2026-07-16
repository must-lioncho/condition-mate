import Foundation

// 0.5-second-resolution trace of WHAT THE USER IS LOOKING AT, plus the native
// window/webview lifecycle around it. One JSONL line per sample under
// events/view-trace.jsonl. Two sources feed it:
//
//   src:"js"     — a heartbeat injected into every app-window webview
//                  (AppWindowScripts.viewTraceHeartbeat) samples every 500ms:
//                  page path, active view/tab (_view on the dashboard, mode on
//                  the condition page), readyState, painted, hidden, focus,
//                  viewport — and posts batches to POST /api/debug/view-trace.
//                  Lifecycle moments (boot/firstPaint/domReady/load/jsError)
//                  are sent immediately (k:"ev"), ticks in 5s batches (k:"tick").
//                  The heartbeat also exposes window.cmVT.ev(note) so pages can
//                  stamp in-page user moments the sampler can't see (chat panel
//                  open, composer image attach, in-page CLI open, GUI↔CLI
//                  switches) — same k:"ev" channel, no extra endpoint.
//   src:"native" — AppKit-side moments the page can't see: app launch, window
//                  open/close, mode switch, zen narrow/expand, navigation
//                  start/commit/finish/fail, occlusion changes.
//
// Purpose: reconstruct exactly what was on screen at any moment WITHOUT a
// screenshot — e.g. the "3초 흰 화면" report becomes measurable as the gap
// between native loadStart/didCommit and the page's boot/firstPaint events.
// Read it back via GET /api/debug/view-trace/list?limit=N (newest window) or
// the file directly. The file self-trims (keeps the newest ~8MB once it grows
// past ~24MB) so a permanently-open window can't grow it unbounded.
final class ViewTrace {

    static let shared = ViewTrace()

    private let fileURL: URL
    // All file access funnels through one serial queue: JS batches arrive on the
    // HTTP server thread while native events come from the main thread.
    private let queue = DispatchQueue(label: "cm.viewtrace", qos: .utility)
    private var appendsSinceTrimCheck = 0

    private static let trimThresholdBytes: UInt64 = 24 * 1024 * 1024
    private static let trimKeepBytes = 8 * 1024 * 1024

    private init() {
        fileURL = AppPaths.sub("events").appendingPathComponent("view-trace.jsonl")
    }

    // One AppKit-side lifecycle moment. `event` is the machine-readable name
    // ("appLaunch", "windowOpen", "loadStart", "didCommit", …), `page` the URL
    // path involved (when there is one), `detail` a short human note.
    func native(_ event: String, page: String = "", detail: String = "") {
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        var line = "{\"t\":\(t),\"src\":\"native\",\"k\":\"ev\",\"note\":\(js(event))"
        if !page.isEmpty { line += ",\"page\":\(js(String(page.prefix(200))))" }
        if !detail.isEmpty { line += ",\"detail\":\(js(String(detail.prefix(300))))" }
        line += "}\n"
        write(line)
    }

    // POST /api/debug/view-trace body: {"events":[{…}, …]} from the injected JS
    // heartbeat. Every value is re-encoded through a key whitelist with length
    // clamps — nothing from the webview is written to disk verbatim. Returns the
    // number of accepted events.
    func appendBatch(_ body: String) -> Int {
        guard let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return 0 }
        var out = ""
        var n = 0
        for e in events.prefix(200) {
            // Client timestamp (ms). A clock too far off just falls back to server time.
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var t = (e["t"] as? NSNumber)?.int64Value ?? now
            if t < now - 3_600_000 || t > now + 60_000 { t = now }
            let k = (e["k"] as? String) == "ev" ? "ev" : "tick"
            var line = "{\"t\":\(t),\"src\":\"js\",\"k\":\"\(k)\""
            for key in ["page", "view", "ready", "note"] {
                if let v = e[key] as? String, !v.isEmpty {
                    line += ",\"\(key)\":\(js(String(v.prefix(300))))"
                }
            }
            for key in ["painted", "hidden", "focus"] {
                if let v = e[key] as? Bool { line += ",\"\(key)\":\(v)" }
            }
            for key in ["w", "h"] {
                if let v = (e[key] as? NSNumber)?.intValue { line += ",\"\(key)\":\(max(0, min(v, 100_000)))" }
            }
            line += "}\n"
            out += line
            n += 1
        }
        if n > 0 { write(out) }
        return n
    }

    // GET /api/debug/view-trace/list feed: the last `limit` samples, oldest first.
    // Reads at most the file's last ~4MB so the endpoint stays fast against a
    // long-lived trace.
    func recentJSON(limit: Int = 2000) -> String {
        let capped = max(1, min(limit, 20000))
        return queue.sync { [fileURL] in
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return "{\"events\":[]}"
            }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            let window: UInt64 = 4 * 1_048_576
            let start = size > window ? size - window : 0
            handle.seek(toFileOffset: start)
            let data = handle.readDataToEndOfFile()
            guard var text = String(data: data, encoding: .utf8) else { return "{\"events\":[]}" }
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") }
            let tail = lines.suffix(capped)
            return "{\"events\":[\(tail.joined(separator: ","))]}"
        }
    }

    private func write(_ chunk: String) {
        queue.async { [fileURL] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                if let data = chunk.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            }
            self.appendsSinceTrimCheck += 1
            if self.appendsSinceTrimCheck >= 500 {
                self.appendsSinceTrimCheck = 0
                self.trimIfNeeded()
            }
        }
    }

    // Keep the newest trimKeepBytes once the file crosses trimThresholdBytes —
    // at ~4 tick lines/sec (two webviews) the trace grows ~50MB/day, and only
    // the recent window is ever needed to reconstruct a report. Runs on `queue`.
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > Self.trimThresholdBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        handle.seek(toFileOffset: size - UInt64(Self.trimKeepBytes))
        let tail = handle.readDataToEndOfFile()
        try? handle.close()
        // A mid-file cut lands inside a line: drop the partial head before rewriting.
        var kept = tail
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            kept = tail.subdata(in: tail.index(after: nl)..<tail.endIndex)
        }
        try? kept.write(to: fileURL, options: .atomic)
    }

    // Minimal JSON string encoder (quotes + escapes). Korean passes through UTF-8.
    private func js(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}
