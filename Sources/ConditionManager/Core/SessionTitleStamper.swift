import Foundation

// Policy 3 (.doc/session-lifecycle-policy.md): stamp a stable [seq] number onto the
// Claude desktop session title so a human can eyeball-match a desktop session to its
// condition-manager goal and manually archive (desktop) / complete (web) it.
//
// Scope (decided): writes ONLY the `title` field of Claude's private per-session
// metadata file:
//   ~/Library/Application Support/Claude/claude-code-sessions/<ws>/<win>/local_*.json
// Every other key is preserved verbatim. Best-effort by nature — the desktop app owns
// this file and regenerates the AI title (observed titleSource == "auto"), so the
// worker RE-STAMPS on each run and silently tolerates any read/write/format failure.
//
// It never touches the transcript .jsonl (which holds no title/archive state) and never
// blocks the UI: all directory scanning and file IO runs off the main thread.
enum SessionTitleStamper {

    // Join key: goal.sessionId == local_*.json `cliSessionId`. Map is cliSessionId -> seq.
    // Do NOT match on the metadata's own `sessionId` field — that's an internal "local_"
    // id, not the Claude Code session id the goal mirrors.
    static func stamp(seqBySession: [String: Int]) {
        if seqBySession.isEmpty { return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for url in localFiles(under: sessionsRoot, fm) {
                stampFile(url, seqBySession: seqBySession, fm: fm)
            }
        }
    }

    // Real Claude store, overridable via CM_CLAUDE_SESSIONS_DIR so tests/dev runs never
    // mutate the user's real desktop session metadata.
    static var sessionsRoot: URL {
        if let env = ProcessInfo.processInfo.environment["CM_CLAUDE_SESSIONS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
    }

    // Recursively collect every local_*.json under the sessions root (workspace/window
    // dir names are opaque hashes, so we walk the tree). Cheap: a handful of small files.
    private static func localFiles(under root: URL, _ fm: FileManager) -> [URL] {
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en
            where u.pathExtension == "json" && u.lastPathComponent.hasPrefix("local_") {
            out.append(u)
        }
        return out
    }

    private static func stampFile(_ url: URL, seqBySession: [String: Int], fm: FileManager) {
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cli = obj["cliSessionId"] as? String,
              let seq = seqBySession[cli] else { return }
        let current = (obj["title"] as? String) ?? ""
        let desired = restamp(current, seq: seq)
        if desired == current { return }   // idempotent: already correct, no write
        obj["title"] = desired
        // Re-serialize compact (matches the app's on-disk format) and write atomically.
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? out.write(to: url, options: .atomic)
    }

    // Idempotent prefix rule: make the title start with exactly "[seq] " (or "[seq]" when
    // there is no body). Never yields "[22] [22] ...":
    //   - no [number] prefix      -> prepend
    //   - prefix already == [seq]  -> unchanged (caller skips the write)
    //   - prefix is a different [N] -> the old [N] is stripped first, then [seq] prepended
    static func restamp(_ title: String, seq: Int) -> String {
        let body = stripBracketPrefix(title)
        return body.isEmpty ? "[\(seq)]" : "[\(seq)] \(body)"
    }

    // Drop a single leading "[<digits>]" plus any surrounding spaces. A bracket whose
    // contents are not all digits (e.g. "[wip]") is left intact — only our own numeric
    // stamp is recognized and replaced.
    private static func stripBracketPrefix(_ s: String) -> String {
        var t = Substring(s)
        while t.first == " " { t = t.dropFirst() }
        guard t.first == "[" else { return String(t) }
        var i = t.index(after: t.startIndex)
        var digits = 0
        while i < t.endIndex, t[i].isNumber {
            i = t.index(after: i); digits += 1
        }
        guard digits > 0, i < t.endIndex, t[i] == "]" else { return String(t) }
        i = t.index(after: i)                 // step past ']'
        var rest = t[i...]
        while rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }
}
