import Foundation

// Extensible plugin registry. Each plugin is an external integration the dashboard
// can connect to a local folder. Today the only built-in is Claude Desktop, but the
// list is designed to grow: add a definition to `builtins` and the dashboard renders
// it automatically.
//
// "Connecting" a plugin means picking a folder AND passing a content-parse check —
// pointing at an arbitrary folder is rejected as 잘못된 연결 (invalid). Connection
// state (the chosen folder per plugin) persists in Settings.
final class PluginStore {

    // Verification outcome for a folder.
    enum Status: String {
        case disconnected   // no folder chosen yet
        case valid          // folder chosen and content check passed
        case invalid        // folder chosen but content check failed (e.g. random folder)
    }

    // How a plugin connects. `folder` plugins attach to a verified project folder
    // (Claude Desktop). `toggle` plugins have no folder — installing them IS the whole
    // connection, and their working files live under AppPaths automatically (컨디션 메이트).
    enum Kind: String { case folder, toggle }

    struct Plugin {
        let id: String          // stable key, e.g. "claude-desktop"
        let name: String        // display name
        let desc: String        // one-line description for the card
        let hint: String        // what a valid folder should contain (folder kind)
        let kind: Kind          // folder vs toggle connection model
        var folderPath: String  // connected folder ("" = not connected; unused for toggle)
        var status: Status
        var detail: String      // human-readable verification result
        var verifiedAt: Date?   // last time verify()/install ran
    }

    // Per-project activity, scanned from the connected Claude root. `level` is a 1..5
    // intensity by recency of the project's newest transcript (5 = touched ≤5min,
    // 1 = within a week); 0 = dormant (>7일). inUse = currently active (level 5).
    struct ProjectActivity {
        let name: String        // friendly project name (from transcript cwd, else folder)
        let path: String        // project folder path
        let lastActiveSec: Int  // seconds since the newest transcript was modified
        let level: Int          // 0..5 intensity
        let inUse: Bool         // level == 5 (touched within 5 minutes)
    }

    // Built-in plugin definitions. folderPath/status/detail are filled at runtime.
    private static let builtins: [Plugin] = [
        Plugin(id: "claude-desktop",
               name: "Claude Desktop",
               desc: "Claude Code 세션 transcript를 읽어 목표·세션을 연동합니다.",
               hint: "Claude 루트 폴더 ~/.claude (또는 ~/.claude/projects) — 모든 프로젝트 세션을 한 번에 연동합니다.",
               kind: .folder, folderPath: "", status: .disconnected, detail: "미연결", verifiedAt: nil),
        // 컨디션 메이트 (see .doc/condition-mate.md): 함께 견디며 등을 맡기는 전우 같은 BGM 기반
        // 컨디션 관리. 설치하면 BGM 디렉터가 켜지는 것이 기본 기능이고, Discord 채널 연결은 그
        // 위에 얹는 강화다. 폴더가 아니라 설치(토글) 모델 — 자원은 앱 데이터 폴더에 자동 보관.
        // 기본 설치됨(첫 실행부터 BGM 동작); 제거하면 BGM도 꺼진다.
        Plugin(id: "condition-mate",
               name: "컨디션 메이트",
               desc: "상황을 함께 읽고 BGM으로 컨디션을 끌어올리는 메이트. 설치 시 BGM 동작 · Discord 연결로 강화.",
               hint: "설치형 — 켜면 BGM 디렉터가 함께 동작합니다. 자원은 앱 데이터 폴더에 자동 보관.",
               kind: .toggle, folderPath: "", status: .disconnected, detail: "미설치", verifiedAt: nil)
    ]

    // Toggle plugins that should be installed out of the box (so the feature works on a
    // fresh launch). 컨디션 메이트 owns BGM, which the app has always played by default.
    private static let defaultInstalled: Set<String> = ["condition-mate"]

    private(set) var plugins: [Plugin]
    // Latest per-project activity scan (claude-desktop). Refreshed by the sync-check
    // worker every 30s; the dashboard reads it from the plugin payload.
    private(set) var claudeProjects: [ProjectActivity] = []

    init() {
        let saved = Settings.shared.pluginFolders
        // Hydrate each built-in with its persisted folder, then re-verify so the
        // dashboard reflects reality on launch (folder may have moved/changed).
        plugins = PluginStore.builtins.map { def in
            var p = def
            switch def.kind {
            case .folder:
                // Hydrate the persisted folder and re-verify so the dashboard reflects
                // reality on launch (folder may have moved/changed).
                if let path = saved[def.id], !path.isEmpty {
                    let r = PluginStore.verifyFolder(pluginId: def.id, folderPath: path)
                    p.folderPath = path
                    p.status = r.status
                    p.detail = r.detail
                    p.verifiedAt = Date()
                }
            case .toggle:
                // Installed (valid) iff the stored flag — or the built-in default — says so.
                let installed = Settings.shared.isPluginInstalled(
                    def.id, default: PluginStore.defaultInstalled.contains(def.id))
                p.status = installed ? .valid : .disconnected
                p.detail = installed ? "설치됨" : "미설치"
                p.verifiedAt = installed ? Date() : nil
            }
            return p
        }
    }

    // Install a toggle plugin (its whole "connection"). No-op for folder plugins.
    func install(pluginId: String) {
        guard let i = index(of: pluginId), plugins[i].kind == .toggle else { return }
        plugins[i].status = .valid
        plugins[i].detail = "설치됨"
        plugins[i].verifiedAt = Date()
        Settings.shared.setPluginInstalled(true, for: pluginId)
    }

    // Uninstall a toggle plugin. No-op for folder plugins.
    func uninstall(pluginId: String) {
        guard let i = index(of: pluginId), plugins[i].kind == .toggle else { return }
        plugins[i].status = .disconnected
        plugins[i].detail = "미설치"
        plugins[i].verifiedAt = nil
        Settings.shared.setPluginInstalled(false, for: pluginId)
    }

    private func index(of id: String) -> Int? { plugins.firstIndex { $0.id == id } }

    func plugin(_ id: String) -> Plugin? { index(of: id).map { plugins[$0] } }

    // A plugin counts as connected only when its folder passed verification (valid).
    // An invalid/잘못된 연결 does NOT activate the plugin's workers.
    func isConnected(_ id: String) -> Bool { plugin(id)?.status == .valid }

    // The verified folder for a connected plugin ("" if not connected/invalid).
    func connectedFolder(_ id: String) -> String {
        guard let p = plugin(id), p.status == .valid else { return "" }
        return p.folderPath
    }

    // Attach a folder to a plugin: verify content, store the result, and persist the
    // folder (even when invalid, so the card shows what the user picked). Returns the
    // verification result for the caller.
    @discardableResult
    func connect(pluginId: String, folderPath: String) -> (status: Status, detail: String) {
        let r = PluginStore.verifyFolder(pluginId: pluginId, folderPath: folderPath)
        guard let i = index(of: pluginId) else { return r }
        plugins[i].folderPath = folderPath
        plugins[i].status = r.status
        plugins[i].detail = r.detail
        plugins[i].verifiedAt = Date()
        Settings.shared.setPluginFolder(folderPath, for: pluginId)
        return r
    }

    // Clear a plugin's connection.
    func disconnect(pluginId: String) {
        guard let i = index(of: pluginId) else { return }
        plugins[i].folderPath = ""
        plugins[i].status = .disconnected
        plugins[i].detail = "미연결"
        plugins[i].verifiedAt = nil
        Settings.shared.setPluginFolder(nil, for: pluginId)
    }

    // Re-run verification against the currently stored folder.
    @discardableResult
    func reverify(pluginId: String) -> (status: Status, detail: String) {
        guard let i = index(of: pluginId) else { return (.disconnected, "미연결") }
        let path = plugins[i].folderPath
        guard !path.isEmpty else { return (.disconnected, "미연결") }
        let r = PluginStore.verifyFolder(pluginId: pluginId, folderPath: path)
        plugins[i].status = r.status
        plugins[i].detail = r.detail
        plugins[i].verifiedAt = Date()
        return r
    }

    // MARK: Verification

    // Validate that `folderPath` is a real connection for the given plugin. Pure and
    // static so it can run during init() and off the main thread.
    static func verifyFolder(pluginId: String, folderPath: String) -> (status: Status, detail: String) {
        switch pluginId {
        case "claude-desktop":  return verifyClaudeFolder(folderPath)
        default:                return (.invalid, "알 수 없는 플러그인")
        }
    }

    // Resolve the "projects root" — the directory whose CHILD folders are per-project
    // session dirs — from whatever the user picked. Accepts the Claude root (~/.claude,
    // which has a projects/ subdir), the projects dir itself, or a single project folder.
    static func claudeProjectsRoot(_ folderPath: String) -> URL? {
        if folderPath.isEmpty { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { return nil }
        let dir = URL(fileURLWithPath: folderPath, isDirectory: true)
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        if fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue { return projects }
        return dir   // already a projects dir, or a single project folder
    }

    // Every transcript under `root`: each child project folder's .jsonl files, plus any
    // .jsonl directly in root (the single-project-folder case). One level deep — Claude
    // never nests transcripts deeper than projects/<project>/<session>.jsonl.
    private static func transcripts(under root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let entries = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for e in entries {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let inner = (try? fm.contentsOfDirectory(at: e, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                out.append(contentsOf: inner.filter { $0.pathExtension == "jsonl" })
            } else if e.pathExtension == "jsonl" {
                out.append(e)
            }
        }
        return out
    }

    // Claude Desktop check: resolve the projects root, find at least one transcript
    // (searching one level into project folders), and confirm it parses as a Claude
    // transcript (line-delimited JSON with `sessionId` + `type`). A random folder finds
    // no transcript or fails the marker check → 잘못된 연결.
    private static func verifyClaudeFolder(_ folderPath: String) -> (status: Status, detail: String) {
        if folderPath.isEmpty { return (.disconnected, "미연결") }
        guard let root = claudeProjectsRoot(folderPath) else {
            return (.invalid, "폴더를 찾을 수 없습니다")
        }
        let all = transcripts(under: root)
        if all.isEmpty {
            return (.invalid, "세션 .jsonl이 없습니다 — ~/.claude (또는 projects) 폴더가 맞는지 확인하세요")
        }
        let newest = all.max { a, b in
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ma < mb
        } ?? all[0]
        guard isClaudeTranscript(newest) else {
            return (.invalid, "Claude 세션 형식이 아닙니다 (.jsonl 내용 확인 실패)")
        }
        // Count distinct project folders (parents of transcripts) for the detail line.
        let projects = Set(all.map { $0.deletingLastPathComponent().path })
        return (.valid, "유효 — 프로젝트 \(projects.count)개 · transcript \(all.count)개")
    }

    // Recency → 1..5 intensity ladder (0 = dormant). Endpoints per the spec: ≤5분 = 5,
    // 1주일 이내 = 1. Middle steps: 1시간, 24시간, 3일.
    static func intensityLevel(ageSec: Double) -> Int {
        switch ageSec {
        case ..<300:        return 5   // ≤ 5분  — 사용 중
        case ..<3600:       return 4   // ≤ 1시간
        case ..<86_400:     return 3   // ≤ 24시간
        case ..<259_200:    return 2   // ≤ 3일
        case ..<604_800:    return 1   // ≤ 7일
        default:            return 0   // 휴면 (7일+)
        }
    }

    // Scan every project under the connected Claude root and rank by activity. Cheap
    // enough for a 30s worker: a stat per transcript, plus one small read per active
    // project to recover a friendly name. Stores the result in `claudeProjects`.
    func refreshClaudeProjects() {
        guard let root = PluginStore.claudeProjectsRoot(connectedFolder("claude-desktop")) else {
            claudeProjects = []; return
        }
        let fm = FileManager.default
        let now = Date()
        let children = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var dirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        // Single-project-folder case: root itself holds the transcripts.
        if dirs.isEmpty { dirs = [root] }
        var out: [ProjectActivity] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            let jsonls = files.filter { $0.pathExtension == "jsonl" }
            guard !jsonls.isEmpty else { continue }
            let newest = jsonls.max { a, b in
                let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return ma < mb
            }!
            let mtime = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let age = max(0, now.timeIntervalSince(mtime))
            let level = PluginStore.intensityLevel(ageSec: age)
            // Friendly name only for non-dormant projects (avoids reading 40 files).
            let name = level > 0 ? (PluginStore.projectName(transcript: newest) ?? PluginStore.decodeFolderName(dir.lastPathComponent))
                                 : PluginStore.decodeFolderName(dir.lastPathComponent)
            out.append(ProjectActivity(name: name, path: dir.path,
                                       lastActiveSec: Int(age), level: level, inUse: level == 5))
        }
        out.sort { $0.lastActiveSec < $1.lastActiveSec }   // most recent first
        claudeProjects = out
    }

    // Recover a human name from a transcript: the last path component of its `cwd`.
    private static func projectName(transcript url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let chunk = fh.readData(ofLength: 16 * 1024)
        guard !chunk.isEmpty else { return nil }
        for raw in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            guard let data = raw.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return nil
    }

    // Best-effort decode of Claude's folder encoding (cwd with '/' → '-'). The real
    // name is ambiguous (names may contain '-'), so just show the trailing segment.
    private static func decodeFolderName(_ encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return trimmed.split(separator: "-").last.map(String.init) ?? encoded
    }

    // Read a small prefix of the file and confirm at least one non-empty line parses
    // to a JSON object that has both `sessionId` and `type` — the stable fields present
    // on every Claude transcript record. Reading a prefix keeps big transcripts cheap.
    private static func isClaudeTranscript(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let chunk = fh.readData(ofLength: 64 * 1024)
        guard !chunk.isEmpty else { return false }
        let text = String(decoding: chunk, as: UTF8.self)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["sessionId"] is String && obj["type"] != nil { return true }
        }
        return false
    }

    // MARK: Dashboard payload

    // JSON array for /data.json. Mirrors the dashboard's renderPlugins() expectations.
    func pluginsJSON() -> String {
        let items = plugins.map { p -> String in
            let when = p.verifiedAt.map { String($0.timeIntervalSince1970) } ?? "0"
            // claude-desktop carries its per-project activity scan; others get [].
            let projects = (p.id == "claude-desktop") ? claudeProjectsJSON() : "[]"
            return "{\"id\":\(esc(p.id)),\"name\":\(esc(p.name)),\"desc\":\(esc(p.desc)),"
                + "\"hint\":\(esc(p.hint)),\"kind\":\(esc(p.kind.rawValue)),"
                + "\"installed\":\(p.kind == .toggle && p.status == .valid),"
                + "\"folder\":\(esc(p.folderPath)),"
                + "\"status\":\(esc(p.status.rawValue)),\"detail\":\(esc(p.detail)),"
                + "\"verifiedAt\":\(when),\"projects\":\(projects)}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private func claudeProjectsJSON() -> String {
        let items = claudeProjects.map { a -> String in
            "{\"name\":\(esc(a.name)),\"path\":\(esc(a.path)),"
                + "\"lastActiveSec\":\(a.lastActiveSec),\"level\":\(a.level),\"inUse\":\(a.inUse)}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    // Minimal JSON string escaper (kept local so the store has no AppDelegate dep).
    private func esc(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}
