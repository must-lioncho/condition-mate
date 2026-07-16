import Foundation
import WebCLI

// Owns the live PTY-backed claude sessions for this standalone server. Reuses
// WebCLI.PtySession verbatim — the same engine the in-app dashboard uses. This
// standalone build keeps at most one live session per working directory and hands
// its token back on reconnect, so a browser refresh resumes the same terminal
// (the PTY's buffer tail replays) instead of spawning a second claude.
final class CLIRegistry {
    private let lock = NSLock()
    private var sessions: [String: PtySession] = [:]   // token -> session
    private var dirs: [String: String] = [:]           // token -> cwd
    private let command: String

    init(command: String) {
        self.command = command
    }

    // POST /api/cli/start — reconnect to a live session for `cwd` if one exists,
    // otherwise spawn a fresh PTY. Mirrors the app's cliStart JSON contract that
    // CMWebCLI expects: {ok, token} / {ok:false, error}.
    func start(cwd: String, cols: UInt16, rows: UInt16) -> String {
        let dir = (cwd as NSString).expandingTildeInPath
        let c = max(cols, 20), r = max(rows, 4)

        lock.lock()
        // Drop any dead sessions first so the live-lookup below is accurate.
        for (k, v) in sessions where !v.alive { v.terminate(); sessions[k] = nil; dirs[k] = nil }
        if let existing = sessions.first(where: { dirs[$0.key] == dir && $0.value.alive }) {
            existing.value.resize(cols: c, rows: r)
            let tok = existing.key
            lock.unlock()
            return "{\"ok\":true,\"token\":\(jsonString(tok)),\"reused\":true}"
        }
        lock.unlock()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "{\"ok\":false,\"error\":\"no-such-dir\"}"
        }
        guard let s = PtySession(command: command, cwd: dir, cols: c, rows: r) else {
            return "{\"ok\":false,\"error\":\"pty-failed\"}"
        }
        lock.lock()
        sessions[s.token] = s
        dirs[s.token] = dir
        lock.unlock()
        return "{\"ok\":true,\"token\":\(jsonString(s.token))}"
    }

    // POST /api/cli/io — write any keystrokes, return new output since `since`.
    func io(token: String, inputB64: String, since: Int) -> String {
        lock.lock(); let s = sessions[token]; lock.unlock()
        guard let s else { return "{\"ok\":false,\"error\":\"no-session\"}" }
        if !inputB64.isEmpty, let d = Data(base64Encoded: inputB64) { s.write(d) }
        let (data, offset) = s.read(since: since)
        return "{\"ok\":true,\"data\":\(jsonString(data.base64EncodedString())),"
            + "\"offset\":\(offset),\"alive\":\(s.alive ? "true" : "false")}"
    }

    // POST /api/cli/resize — mirror the browser terminal size onto the PTY.
    func resize(token: String, cols: UInt16, rows: UInt16) {
        lock.lock(); let s = sessions[token]; lock.unlock()
        s?.resize(cols: max(cols, 20), rows: max(rows, 4))
    }

    // Reap sessions idle for longer than maxIdle so a long-lived server never
    // accumulates dead PTYs. Called on a timer from main.
    func reapIdle(maxIdle: TimeInterval = 30 * 60) {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        for (k, v) in sessions where !v.alive || now.timeIntervalSince(v.lastTouched) > maxIdle {
            v.terminate(); sessions[k] = nil; dirs[k] = nil
        }
    }

    func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, v) in sessions { v.terminate() }
        sessions.removeAll(); dirs.removeAll()
    }
}

// Minimal RFC 8259 string escaper — enough for tokens and base64 (both ASCII-safe),
// but complete so any PTY-derived text is quoted correctly.
func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}
