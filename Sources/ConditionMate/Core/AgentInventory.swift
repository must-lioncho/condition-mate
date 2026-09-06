import Foundation

// 에이전트 인벤토리 — "이 맥에 에이전트가 어디에 몇 개 있는가"의 단일 진실.
//
// 에이전트 정의(.md)는 한 곳에 모여 있지 않다. 세 종류의 자리에 흩어진다:
//   1) 전역        ~/.claude/agents/*.md              — 모든 프로젝트에서 쓰는 에이전트
//   2) 스킬 하네스  ~/.claude/skills/<skill>/.claude/agents/*.md — 그 스킬이 headless 로 부르는 전용 에이전트
//   3) 프로젝트     <project>/.claude/agents/*.md      — 그 저장소 안에서만 뜨는 에이전트
//
// 루프를 관리하려면 셋을 같이 봐야 한다 — 전역만 보면 "에이전트가 없습니다"가 뜨는데
// 정작 일은 프로젝트 에이전트가 하고 있는 상황이 그대로 생긴다(2026-08 실제 상태).
//
// 프로젝트를 찾는 방법: "사용자가 실제로 일하는 폴더"를 씨앗으로 모으고, 그 씨앗의 상위 폴더
// (워크스페이스)를 얕게 훑어 형제 프로젝트까지 전부 건진다. 씨앗은 세 갈래를 합집합한다.
//   (1) ~/.claude/projects 의 세션 트랜스크립트에 적힌 cwd — Claude Code 를 돌린 적 있는 폴더
//   (2) 앱이 아는 goal 들의 작업 폴더(cwd) — 호출부가 extraRoots 로 넘겨준다
//   (3) 개발 빌드의 저장소 루트(AppPaths.projectRoot; 설치본에서는 nil)
// 씨앗만으로는 부족하다. 사용자가 한 번도 열지 않은 형제 프로젝트의 에이전트도 "내 에이전트"이기
// 때문이다. 그래서 각 씨앗의 상위 3단계를 워크스페이스 후보로 삼아 깊이 3까지 훑는다 — 씨앗이
// <ws>/projects/org-x/proj 하나만 있어도 <ws> 아래 모든 프로젝트가 잡힌다.
//
// (3) 에만 기대면 안 된다는 것이 2026-08-23 에 드러났다: 설치본은 projectRoot 가 nil 이라 순회가
// 통째로 건너뛰어져 프로젝트가 2곳만 잡혔다(개발 빌드는 10곳). 실행 위치는 발견 범위를 바꾸면 안 된다.
// 홈 전체를 쓸지 않는 이유는 TCC 다 — ~/Documents·Desktop·Downloads 를 훑으면 권한 팝업이 뜬다.
enum AgentInventory {

    // MARK: - Public

    // 스코프 목록(전역 → 스킬 → 프로젝트 순). 각 스코프는 자기 agents 배열을 갖는다.
    // 실행 성적(runs/okRate/functions)은 원장을 아는 AppDelegate 가 이름으로 덧입힌다.
    // extraRoots: 앱만 아는 작업 폴더(goal 의 cwd 등). 씨앗으로 함께 쓴다.
    static func scopes(globalRoot: URL, extraRoots: [String] = []) -> [[String: Any]] {
        var out: [[String: Any]] = []
        // 같은 agents 폴더가 두 번 실리지 않게 한다. 스킬 폴더는 그 자체로 Claude Code 를 돌린
        // cwd 이기도 해서, 막지 않으면 '스킬 하네스'와 '프로젝트'로 각각 한 번씩 잡힌다 —
        // 그러면 목록이 두 배로 보이고 "교체 필요 1건"이 2건으로 세어진다.
        var emitted = Set<String>()
        func push(_ sc: [String: Any], allowEmpty: Bool) {
            let dir = (sc["dir"] as? String) ?? ""
            guard !emitted.contains(dir) else { return }
            if !allowEmpty, ((sc["agents"] as? [[String: Any]])?.isEmpty ?? true) { return }
            emitted.insert(dir)
            out.append(sc)
        }

        // 1) 전역 — 비어 있어도 싣는다. "전역에 무엇이 있나"는 이 화면의 첫 질문이고,
        //    "비어 있다"도 답이다(지금이 실제로 그 상태다).
        let gdir = globalRoot.appendingPathComponent("agents", isDirectory: true)
        push(scope(kind: "global", name: "전역", owner: globalRoot, dir: gdir), allowEmpty: true)

        // 2) 스킬 하네스 — 스킬 폴더 안에 자기 전용 에이전트를 들고 있는 것만.
        let skillsDir = globalRoot.appendingPathComponent("skills", isDirectory: true)
        let skillDirs = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for s in skillDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? s.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let d = s.appendingPathComponent(".claude/agents", isDirectory: true)
            push(scope(kind: "skill", name: s.lastPathComponent, owner: s, dir: d), allowEmpty: false)
        }

        // 3) 프로젝트 — 정의를 실제로 들고 있는 폴더만 싣는다(빈 스코프로 목록을 채우지 않는다).
        for root in projectRoots(extraRoots: extraRoots) {
            let d = root.appendingPathComponent(".claude/agents", isDirectory: true)
            push(scope(kind: "project", name: displayName(root), owner: root, dir: d), allowEmpty: false)
        }
        return out
    }

    // 루프 엔지니어링 화면이 쓰는 프로젝트 목록. 발견 규칙은 위 scopes() 와 같은 것 하나여야 한다 —
    // 두 화면이 서로 다른 프로젝트 집합을 말하면 "이 프로젝트에는 라우트가 없다"가 발견 누락인지
    // 사실인지 구분할 수 없게 된다. 그래서 새로 훑지 않고 같은 캐시를 그대로 빌려 준다.
    static func discoveredProjects(extraRoots: [String] = []) -> [URL] {
        return projectRoots(extraRoots: extraRoots)
    }

    // 프로젝트 표시 이름 — 루프 엔지니어링 화면도 목록과 같은 이름을 써야 한다.
    static func label(for url: URL) -> String { return displayName(url) }

    // 세션 트랜스크립트 폴더 하나하나. 루프 재구성(LoopScan)은 이 폴더들과 그 아래 subagents/ 를 읽는다.
    static func sessionDirs() -> [URL] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // 프로젝트 이름. 보통은 폴더 이름 하나면 충분하지만 `workspace`, `app`, `src` 처럼 어느
    // 저장소에나 있는 이름은 그것만으로 무엇인지 알 수 없다 — 그럴 때만 부모 폴더를 앞에 붙인다.
    private static let genericNames: Set<String> = [
        "workspace", "app", "src", "repo", "main", "root", "project", "projects", "packages", "server", "client",
    ]
    private static func displayName(_ url: URL) -> String {
        let last = url.lastPathComponent
        guard genericNames.contains(last.lowercased()) else { return last }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? last : parent + "/" + last
    }

    // MARK: - One scope

    private static func scope(kind: String, name: String, owner: URL, dir: URL) -> [String: Any] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let iso = ISO8601DateFormatter()
        var agents: [[String: Any]] = []
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = AppDelegate.parseFrontmatter(text)
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let rawDesc = front["description"] ?? ""
            let desc: String = rawDesc.count > 600 ? String(rawDesc.prefix(600)) + "…" : rawDesc
            let agentName: String = front["name"] ?? url.deletingPathExtension().lastPathComponent
            let mtime: String = iso.string(from: rv?.contentModificationDate ?? Date())
            var row: [String: Any] = [:]
            row["name"] = agentName
            row["file"] = url.lastPathComponent
            row["path"] = url.path
            row["desc"] = desc
            row["model"] = front["model"] ?? "inherit"
            row["tools"] = front["tools"] ?? ""
            row["harness"] = front["harness"] ?? ""
            row["mtime"] = mtime
            row["bytes"] = rv?.fileSize ?? 0
            row["scopeKind"] = kind
            row["scopeName"] = name
            agents.append(row)
        }
        let hasGit = fm.fileExists(atPath: owner.appendingPathComponent(".git").path)
        var out: [String: Any] = [:]
        out["kind"] = kind
        out["name"] = name
        out["path"] = owner.path
        out["dir"] = dir.path
        out["git"] = hasGit
        out["count"] = agents.count
        out["agents"] = agents
        return out
    }

    // MARK: - Project discovery (cached)

    private static let lock = NSLock()
    private static var cache: (at: Date, key: String, roots: [URL])?
    private static let cacheTTL: TimeInterval = 60

    // 프로젝트 후보 폴더. 스캔 비용이 페이지 폴링마다 나가지 않도록 60초 캐시한다.
    // 캐시 키에 extraRoots 를 넣어, goal 폴더가 늘면 다음 호출에서 바로 반영되게 한다.
    private static func projectRoots(extraRoots: [String]) -> [URL] {
        let key = extraRoots.sorted().joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.key == key, Date().timeIntervalSince(c.at) < cacheTTL { return c.roots }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path

        // 1) 씨앗 — 사용자가 실제로 일한 폴더.
        var seeds: [String] = claudeSessionCwds()
        seeds += extraRoots
        if let proj = AppPaths.projectRoot { seeds.append(proj.path) }

        // 2) 워크스페이스 후보 — 각 씨앗의 상위 3단계. 홈과 그 위는 제외한다(TCC 보호 폴더를
        //    훑지 않기 위해서이자, 홈 전체 순회는 느리기 때문).
        var walkRoots = Set<String>()
        for seed in seeds {
            var u = URL(fileURLWithPath: seed, isDirectory: true).standardizedFileURL
            guard fm.fileExists(atPath: u.path) else { continue }
            walkRoots.insert(u.path)
            for _ in 0..<3 {
                u = u.deletingLastPathComponent()
                let p = u.standardizedFileURL.path
                if p.count <= home.count || !p.hasPrefix(home + "/") { break }
                walkRoots.insert(p)
            }
        }
        // 3) 훑기 — 후보를 상위로 축약하지 않고 전부 각각 훑는다. 축약하면 루트가 너무 위로
        //    올라가 깊이가 모자란다: <홈>/Work 하나로 합쳐 버리면 깊이 3이 Work → 워크스페이스 →
        //    projects → org-x 까지만 닿아 정작 저장소 폴더를 못 본다. 실제로 세션 기록이 없는
        //    오래된 프로젝트(lion-careerpath) 하나가 그렇게 빠졌다. 대신 이미 같은 깊이 이상으로
        //    훑은 폴더는 다시 훑지 않는 예산(budget)으로 중복 비용을 막는다.
        var seen = Set<String>()
        var out: [URL] = []
        var budget: [String: Int] = [:]
        func consider(_ u: URL) {
            let p = u.standardizedFileURL.path
            guard !seen.contains(p) else { return }
            seen.insert(p)
            var isDir: ObjCBool = false
            let d = u.appendingPathComponent(".claude/agents", isDirectory: true).path
            if fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue {
                out.append(URL(fileURLWithPath: p, isDirectory: true))
            }
        }
        func sweep(_ root: URL, remaining: Int) {
            let p = root.standardizedFileURL.path
            if let prev = budget[p], prev >= remaining { return }
            budget[p] = remaining
            guard remaining > 0 else { return }
            // ~/.claude/projects 는 세션 트랜스크립트 창고다 — 폴더 수는 수십~수백인데 에이전트는
            // 절대 없다. 이름만으로 거르면 <ws>/projects 까지 같이 막히므로 전체 경로로 판단한다.
            if p.hasSuffix("/.claude/projects") { return }
            let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for sub in subs.prefix(300) {
                guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !skipDirs.contains(sub.lastPathComponent) else { continue }
                consider(sub)
                sweep(sub, remaining: remaining - 1)
            }
        }
        for root in walkRoots.sorted() {
            let u = URL(fileURLWithPath: root, isDirectory: true)
            consider(u)
            sweep(u, remaining: 3)
        }
        // 씨앗 자신도 확인한다 — 홈 바로 아래라 후보에서 잘려 나간 경우까지 건진다.
        for seed in seeds { consider(URL(fileURLWithPath: seed, isDirectory: true)) }

        out.sort { $0.path < $1.path }
        cache = (Date(), key, out)
        return out
    }

    // 순회에서 들어가지 않는 폴더 — 빌드 산출물/의존성/미디어. 수만 개를 세지 않기 위해서다.
    private static let skipDirs: Set<String> = [
        "node_modules", ".build", ".git", "Pods", "vendor", "dist", "build",
        "DerivedData", "venv", ".venv", "target", "__pycache__", ".next",
        "Library", "Applications", "Music", "Movies", "Pictures", "Downloads",
    ]

    // ~/.claude/projects/<encoded>/<session>.jsonl 의 첫 줄에 실린 cwd 를 모은다. 폴더 이름은
    // 경로를 '-' 로 뭉갠 것이라 되돌릴 수 없다(이 저장소 이름부터 하이픈을 쓴다) — 그래서
    // 이름을 파싱하지 않고 트랜스크립트가 스스로 적어 둔 cwd 를 읽는다. 폴더당 최신 파일 하나,
    // 앞 16KB 만 읽는다.
    private static func claudeSessionCwds() -> [String] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [String] = []
        for dir in dirs.prefix(300) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            // 최신 파일 하나만 보면 그 세션이 요약(summary) 줄로 시작하거나 첫 메시지가 아주 길어
            // cwd 를 못 찾는 일이 잦다(실측: 66곳 중 42곳 실패). 최신 3개까지 물어본다.
            let jsonl = files.filter { $0.pathExtension == "jsonl" }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            for f in jsonl.prefix(3) {
                if let cwd = firstCwd(of: f), !cwd.isEmpty { out.append(cwd); break }
            }
        }
        return out
    }

    private static func firstCwd(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // 넉넉히 읽고(256KB) 손실 허용 디코드를 쓴다 — 고정 바이트로 자르면 한글 문자 중간에서
        // 끊겨 UTF-8 디코드가 통째로 실패하고, 그러면 그 프로젝트가 목록에서 사라진다(실제로 그랬다).
        // 마지막 줄은 잘렸을 수 있으니 버리고, 앞쪽 80줄까지 cwd 를 찾는다.
        let data: Data = ((try? fh.read(upToCount: 262_144)) ?? nil) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in all.dropLast().prefix(80) {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let cwd = o["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }
}

// 에이전트 판정 원장 — "이 에이전트가 원하는 결과를 냈는가"에 대한 사람의 결론.
// 실행 성적(원장에서 계산되는 성공률)은 에이전트가 스스로 남긴 기록이고, 이쪽은 사용자가
// 내린 판정이다. 둘은 다르다: 매번 ok 로 끝났는데도 결과물이 쓸모없을 수 있다.
// 키는 에이전트 정의 파일의 절대 경로 — 같은 이름의 에이전트가 여러 프로젝트에 있어도 안 섞인다.
// 저장 위치는 앱 데이터 디렉터리(읽기 전용으로 취급하는 ~/.claude 트리는 건드리지 않는다).
enum AgentVerdicts {
    private static let lock = NSLock()
    private static var url: URL { AppPaths.base.appendingPathComponent("agent-verdicts.json") }

    static func load() -> [String: [String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return [:] }
        return obj
    }

    // state: "ok"(목적 달성) | "replace"(교체 필요) | ""(판정 해제). seq 가 0보다 크면
    // 그 판정에서 시작된 교체 위임 goal 번호를 함께 남긴다.
    @discardableResult
    static func set(path: String, state: String, reason: String, seq: Int = 0) -> [String: [String: Any]] {
        var all = load()
        let key = path.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return all }
        if state.isEmpty {
            all.removeValue(forKey: key)
        } else {
            var row: [String: Any] = [
                "state": state == "replace" ? "replace" : "ok",
                "reason": String(reason.prefix(400)),
                "ts": ISO8601DateFormatter().string(from: Date()),
            ]
            // 이전 교체 위임 번호는 새 판정에도 남겨 둔다 — 어디서 고치고 있는지의 링크다.
            if seq > 0 { row["seq"] = seq }
            else if let prev = all[key]?["seq"] as? Int { row["seq"] = prev }
            all[key] = row
        }
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONSerialization.data(withJSONObject: all) { try? data.write(to: url) }
        return all
    }
}
