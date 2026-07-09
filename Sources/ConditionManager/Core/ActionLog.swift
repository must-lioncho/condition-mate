import Foundation

// Append-only log of ALL USER ACTIONS — session start/stop, mute, BGM controls,
// AND every dashboard operation (goal add/queue/status, sprint edits, settings,
// pomodoro completion/harvest) — plus the BGM REACTIONS they produce (every
// actual track switch, with the pool that selected it — rain / plan slot / mode
// playlist). One JSONL line per event under events/actions.jsonl.
//
// Purpose: a single filterable behavior stream. `category` is the domain axis
// (pomodoro | goal | bgm | equipment | settings | other) so downstream consumers
// can slice it: grant EXP for pomodoro behavior, correlate "pressed pomodoro →
// focus went up", or let agents read the timeline for better decisions. The
// `pool` field on trackChange events shows exactly which gate picked each track,
// so the /actions page can prove (or disprove) that the music actually followed
// the user's action. See TrackEventLog for the older dislike-only signal log;
// this one is the unified action timeline.
final class ActionLog {

    static let shared = ActionLog()

    struct Event {
        var kind = "user"       // user (직접 조작) | bgm (선곡 반응) | system (자동 전환)
        var action = "-"        // sessionStart | sessionStop | modeChange | mute | unmute
                                // | bgmOn | bgmOff | profileShift | rainStart | rainEnd
                                // | dislike | trackChange | opener | chime
                                // | path-derived names for dashboard POSTs ("goal.add",
                                //   "goal.queue.resolve", "pomodoro.complete", …)
        var category = ""       // domain axis (필터 축): pomodoro | goal | bgm
                                // | equipment | settings | other — empty lets
                                // append() derive it from the action name
        var detail = ""         // human-readable Korean summary
        var mode = "-"          // pomodoro | sprint | unlimited (rail session mode)
        var track = ""          // track title involved (playing or newly selected)
        var trackKey = ""       // file name (preference identity)
        var bpm = 0             // track BPM (0 when not applicable)
        var pool = ""           // WHY this track: 폭우 리셋 | 플랜 · <slot> | 모드 · <mode>
        var phase = "-"         // director phase at the moment
        var profile = "-"       // active per-app BGM profile label
        var app = ""            // frontmost tracked app display name
    }

    private let fileURL: URL
    // All file access funnels through one serial queue: appends come from the main
    // thread (heartbeat/endpoints) while reads come from the HTTP server thread.
    private let queue = DispatchQueue(label: "cm.actionlog")
    // Held-open SSE channels (/api/actions/stream). Guarded by `queue`.
    private var streams: [SSEChannel] = []

    private init() {
        fileURL = AppPaths.sub("events").appendingPathComponent("actions.jsonl")
    }

    // Register a live-feed subscriber: every future append is pushed as one `data:`
    // frame, so the 액션로그 view updates the moment an action happens (no polling lag).
    func subscribe(_ channel: SSEChannel) {
        queue.async { self.streams.append(channel) }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.queue.async { self.streams.removeAll { $0 === channel } }
        }
    }

    // Domain fallback for call sites that predate the category axis: session
    // start/stop are 포모도로 행동, updateRun is settings, everything else in the
    // legacy set (mute / bgm on-off / rain / dislike / track events / chimes)
    // is BGM-domain. New call sites should pass category explicitly.
    static func defaultCategory(for action: String) -> String {
        switch action {
        case "sessionStart", "sessionStop", "modeChange": return "pomodoro"
        case "updateRun": return "settings"
        default: return "bgm"
        }
    }

    func append(_ e: Event) {
        var e = e
        if e.category.isEmpty { e.category = Self.defaultCategory(for: e.action) }
        let t = Int(Date().timeIntervalSince1970)
        let line = "{\"t\":\(t),\"kind\":\(js(e.kind)),\"action\":\(js(e.action)),"
            + "\"cat\":\(js(e.category)),"
            + "\"detail\":\(js(e.detail)),\"mode\":\(js(e.mode)),"
            + "\"track\":\(js(e.track)),\"trackKey\":\(js(e.trackKey)),\"bpm\":\(e.bpm),"
            + "\"pool\":\(js(e.pool)),\"phase\":\(js(e.phase)),"
            + "\"profile\":\(js(e.profile)),\"app\":\(js(e.app))}\n"
        queue.async { [fileURL] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            }
            // Push to live subscribers after the file write, same event JSON (sans newline).
            if !self.streams.isEmpty {
                let payload = String(line.dropLast())
                self.streams.forEach { $0.event(payload) }
            }
        }
    }

    // GET /api/actions feed: the last `limit` events, oldest first (the page
    // reverses for display). Lines are already JSON objects, so the array is a
    // plain join — no re-encode. Reads at most the file's last ~1MB so an old,
    // long-lived log can't make the endpoint slow.
    func recentJSON(limit: Int = 500) -> String {
        let capped = max(1, min(limit, 2000))
        return queue.sync { [fileURL] in
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return "{\"events\":[]}"
            }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            let window: UInt64 = 1_048_576
            let start = size > window ? size - window : 0
            handle.seek(toFileOffset: start)
            let data = handle.readDataToEndOfFile()
            guard var text = String(data: data, encoding: .utf8) else { return "{\"events\":[]}" }
            // A mid-file window start can land inside a line: drop the partial head.
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") }
            let tail = lines.suffix(capped)
            return "{\"events\":[\(tail.joined(separator: ","))]}"
        }
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
