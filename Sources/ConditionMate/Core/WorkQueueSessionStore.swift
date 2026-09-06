import Foundation

// 카드 하나를 실제로 수행한 **세션**을 찾아, 그 세션 안에 나온 것을 그대로 끌어온다.
//
// 왜 있는가. 2026-09-06 에 라이언이 이슈 상세를 보고 말한 것이 이것이다 —
//   "내가 최초로 말을 했던 것을 수정해서 한 것 그리고 문제 정의 … 그다음에 어떻게 일 할 건지
//    정의하고 그다음에 뭔가 결과물이 나오는 것까지 한 세션에서 전부 다 나올 거야.
//    그 내용을 따로 파일을 만들 필요는 없고 그걸 갖고 와서 여기에 보여주는 걸로 하자."
//
// 그때 화면은 `작업지시서 없음` / `결과물 없음` 이라고 쓰고 있었다. 카드에 안 적힌 것은 맞으니
// 화면이 거짓말을 한 것은 아니다. 그런데 그 일은 실제로 됐다. 실측 —
// 카드 `2026-09-05-2024-linkedin-version-scope` 는 `issue:` 도 `output:` 도 비어 있는데, 그 카드를
// 받은 세션(`7b59cb18-…`)이 `issue/2026-09-05-linkedin-version-scope-directive.md` 와
// `channels/linkedin/20260905-directive-is-deliverable.md` 를 실제로 썼고 둘 다 디스크에 있다.
// 카드와 세션 사이에 끈이 없어서 화면만 모르고 있었다. 이 파일이 그 끈이다.
//
// ── 끈을 어떻게 잡는가 ────────────────────────────────────────────────────────
// Claude Code 는 세션마다 `~/.claude/projects/<cwd 를 대시로 바꾼 이름>/<sessionId>.jsonl` 에
// 대화 전체를 남긴다. 그리고 디렉터가 띄운 세션의 **첫 지시문**에는 카드 id 와 카드 파일 경로가
// 그대로 들어 있다(실측 첫 줄: "이것은 라우팅으로 넘어온 일이다 … 카드 id: 2026-09-05-2024-…").
// 그래서 판정은 하나다 — **첫 사용자 메시지에 이 카드 id 나 카드 파일 경로가 든 세션.**
//
// 본문 어딘가에 id 가 나오는 것으로는 안 잡는다. 큐를 훑은 세션, 카드를 읽기만 한 세션, 이 화면을
// 만들고 있는 세션이 전부 걸린다. 실측으로 한 카드 id 가 24 개 기록에 나오는데 첫 지시문에
// 담은 것은 1 개였다. 첫 지시문은 그 세션이 무엇을 하러 떴는지이므로 그 자리에서만 본다.
//
// ★ 같은 판정 규칙이 `Core/CardLaterRequests.swift` 에도 있다(SPEC DASH-11). 그쪽은 검색
//   코퍼스에 실을 **나중 사람 발화**를 모으고 이쪽은 상세에 세울 **지시문·산출물·보고**를 뽑아서
//   하는 일이 다르지만, "첫 사람 턴에 카드 id 가 든 트랜스크립트" 라는 열쇠는 한 벌이다.
//   한쪽을 고치면 다른 쪽도 본다. 합치지 않은 이유는 그쪽이 target 폴더 안의 여러 파일을 전부
//   모으고 이쪽은 하나를 골라야 하며, 이쪽에만 target 이 빈 카드를 위한 색인 갈래가 있어서다.
//
// ── 무엇을 끌어오는가 ────────────────────────────────────────────────────────
// ASSUMPTION (L1, 갈래를 스스로 골랐다). 라이언이 댄 다섯 — 최초 원문 · 수정된 최초의 리퀘스트 ·
// 문제 정의 · 어떻게 일할 건지 · 결과물 — 중 앞의 둘은 상세 화면에 이미 자기 절이 있다(2·3 번).
// 남은 셋을 이렇게 가른다.
//
//   작업지시서 칸  ← (a) 세션의 **첫 지시문 전문**. 문제 정의와 어떻게 일할 건지가 여기 들어 있다 —
//                      실측 지시문에 `## 라이언 원문` `## 이 폴더를 고른 근거` `## 완성`
//                      `## 이번에 하지 않는 것` `## 레벨` 이 다 있었다.
//                  (b) 그 세션이 실제로 쓴 파일 중 `issue/` 아래의 것.
//   결과물 칸      ← (c) 그 세션이 실제로 쓴 나머지 파일 전부(디스크 존재 확인해서).
//                  (d) 그 세션의 **마지막 보고**(마지막 어시스턴트 텍스트).
//
// 파일을 새로 만들지 않는다. 카드에도 한 글자 안 쓴다. 읽기만 한다 — 이 항목의 금지가 그것이다.
//
// ASSUMPTION: 세션이 만든 파일은 `Write`/`Edit`/`MultiEdit`/`NotebookEdit` 툴 호출의 경로로만
// 센다. `Bash` 안의 heredoc 으로 만든 파일은 못 잡는다. 셸 문자열을 파싱해 추측하는 것보다
// 못 잡는 것을 못 잡았다고 두는 쪽이 낫다 — 이 화면의 규칙이 "없으면 없다고 쓴다" 이다.
//
// ASSUMPTION: 목록의 `stage`(요청만/작업지시서까지/결과물까지)는 **안 바꾼다.** 그것은 카드 109 개를
// 한 번에 그리는 값이라, 카드마다 세션 기록(가장 큰 것이 15MB)을 훑으면 목록 새로고침이 멈춘다.
// 세션에서 온 것은 상세를 열었을 때만 붙고, 붙었다는 사실을 헤더의 `세션에서 옴` 배지로 말한다.
// 배지가 `요청만` 인데 아래에 지시서가 서 있는 상태는 화면의 버그가 아니라 진짜 상태다 —
// 일은 됐고 카드에 아직 안 적혔다는 뜻이고, 그것을 적는 것은 큐 PM 의 일이다.
enum WorkQueueSessionStore {

    // MARK: - Finder 열기 허용 목록

    // 세션에서 파낸 경로는 카드에 안 적혀 있으므로 `WorkQueueStore.knownRevealPaths()` 가 모른다.
    // 상세를 계산할 때 여기 담고, 그쪽이 합집합으로 쓴다. 상세를 연 뒤에야 열 수 있다는 뜻이고
    // 그것이 실제 조작 순서다 — 행을 눌러 상세를 열고 나서 [파일 열기] 를 누른다.
    private static let lock = NSLock()
    private static var allow = Set<String>()

    static func revealAllowlist() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return allow
    }

    private static func remember(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for p in paths where p.hasPrefix("/") { allow.insert(p) }
    }

    // MARK: - 캐시

    // 캐시가 두 층인 이유는 비싼 것이 둘이고 무효가 되는 조건이 다르기 때문이다.
    //
    //   1) **찾기**(어느 기록 파일인가). `target:` 이 없는 카드는 2.0GB 기록 전체를 훑어야 해서
    //      실측 17 초가 걸렸다. 그런데 카드 하나가 어느 세션에서 돌았는지는 한 번 정해지면
    //      안 바뀐다. 그래서 프로세스가 사는 동안 들고 있는다.
    //   2) **읽기**(그 기록에서 무엇이 나왔나). 세션이 아직 돌고 있으면 기록이 자란다.
    //      그래서 크기+수정시각을 키에 넣어 자동으로 무효가 되게 한다.
    //
    // 앞선 판은 (2) 만 두고 (1) 을 안 둬서, 두 번째로 같은 카드를 열어도 17 초가 그대로 들었다.
    // 캐시가 비싼 자리 뒤에 있으면 캐시가 아니다.
    private struct Hit {
        var path: String; var opened: String; var launch: String
        var how: String; var searched: Int; var projectDir: String
    }
    private static var resolved: [String: Hit] = [:]
    private static var missed: [String: (at: Date, value: [String: Any])] = [:]
    private struct Entry { var stamp: String; var value: [String: Any] }
    private static var cache: [String: Entry] = [:]
    // 못 찾은 카드를 다시 물어볼 때까지의 시간. 짧게 두는 이유는 방금 던진 카드가 곧 세션을
    // 갖게 되기 때문이다 — 영구히 캐시하면 앱을 다시 띄울 때까지 `없음` 으로 굳는다.
    private static let missTTL: TimeInterval = 180

    private static let projectsDir =
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)

    // cwd → 기록 폴더 이름. Claude Code 는 `/` 와 `_` 와 `.` 을 전부 `-` 로 바꾼다.
    // 실측: `/Users/lioncho/Work/lion_work/organization/lion/lion-contents`
    //   →  `-Users-lioncho-Work-lion-work-organization-lion-lion-contents`
    static func projectDirName(for cwd: String) -> String {
        var out = ""
        for ch in cwd { out.append(ch == "/" || ch == "_" || ch == "." ? "-" : ch) }
        return out
    }

    // MARK: - 본체

    /// 카드 하나에 붙는 세션 블록. 못 찾아도 `found:false` 와 **왜 못 찾았는지**를 돌려준다.
    /// 빈 값을 돌려주면 화면이 고장 난 것과 구별되지 않는다.
    ///
    /// - Parameters:
    ///   - cardID: 카드의 `id:`
    ///   - cardPath: 카드 파일 절대경로
    ///   - cwds: 이 카드가 돌았을 법한 작업 폴더들. `target:` 이 첫째이고, Orca 가 알려준
    ///           worktree 경로가 있으면 그것도 같이 온다.
    static func session(cardID: String, cardPath: String, cwds: [String]) -> [String: Any] {
        lock.lock()
        var hit = resolved[cardID]
        let miss = missed[cardID]
        lock.unlock()

        if let h = hit, !FileManager.default.fileExists(atPath: h.path) { hit = nil }
        if hit == nil {
            if let m = miss, Date().timeIntervalSince(m.at) < missTTL { return m.value }
            switch find(cardID: cardID, cardPath: cardPath, cwds: cwds) {
            case .hit(let h):
                hit = h
                lock.lock(); resolved[cardID] = h; missed[cardID] = nil; lock.unlock()
            case .miss(let why):
                lock.lock(); missed[cardID] = (Date(), why); lock.unlock()
                return why
            }
        }
        guard let h = hit else { return ["found": false, "why": "세션을 못 찾았다.", "searched": 0] }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: h.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)/\(Int(mtime))"
        lock.lock(); let cached = cache[h.path]; lock.unlock()
        if let c = cached, c.stamp == stamp {
            remember(pathsIn(c.value))
            return c.value
        }

        var out = scan(URL(fileURLWithPath: h.path), launch: h.launch, opened: h.opened)
        out["projectDir"] = h.projectDir
        out["searched"] = h.searched
        out["why"] = "이 카드 id 로 뜬 세션이다 — 첫 지시문에 `\(cardID)` 가 적혀 있다. (\(h.how))"

        lock.lock()
        cache[h.path] = Entry(stamp: stamp, value: out)
        if cache.count > 160 { cache.removeAll() }
        lock.unlock()
        remember(pathsIn(out))
        return out
    }

    // MARK: - 찾기

    private enum Result { case hit(Hit); case miss([String: Any]) }

    private static func find(cardID: String, cardPath: String, cwds: [String]) -> Result {
        let fm = FileManager.default
        let bases = cwds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }

        // 1 순위 — `target:` 폴더의 기록. 가장 싸고 가장 정확하다.
        var dirs: [URL] = []
        var seenDir = Set<String>()
        for b in bases {
            let d = projectsDir.appendingPathComponent(projectDirName(for: b), isDirectory: true)
            if seenDir.insert(d.path).inserted { dirs.append(d) }
        }
        var files: [URL] = []
        for d in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted()
            where name.hasSuffix(".jsonl") {
                files.append(d.appendingPathComponent(name))
            }
        }
        var how = "target 폴더"
        var searched = files.count
        var hits = match(files, cardID: cardID, cardPath: cardPath)

        // 2 순위 — 라우팅 지시문 색인 전체.
        //
        // 왜 이 갈래가 필요한가. 실측 2026-09-06: 카드 109 개 중 `target:` 이 빈 것이 86 개이고
        // 그중 37 개가 `status: done` 이다. 일은 끝났는데 좌표가 카드에 없다. 1 순위만 두면 그
        // 37 개는 영원히 `없음` 으로 남는다 — 이 기능이 가장 필요한 자리에서 안 도는 셈이다.
        if hits.isEmpty {
            let idx = launchIndex()
            searched = idx.count
            let h2 = idx.filter {
                $0.launch.contains(cardID) || (!cardPath.isEmpty && $0.launch.contains(cardPath))
            }.map { (url: URL(fileURLWithPath: $0.path), opened: $0.opened, launch: $0.launch) }
            if !h2.isEmpty { how = "지시문 색인"; hits = h2 }
        }

        guard let best = hits.sorted(by: { $0.opened < $1.opened }).last else {
            return .miss(["found": false,
                          "why": "라우팅 지시문 \(searched) 개를 봤는데 이 카드 id 를 담은 것이 없다. "
                               + (bases.isEmpty ? "카드에 target: 도 없다. 아직 안 띄운 카드이거나, "
                                                : "")
                               + "카드 id 없이 말로 넘긴 세션이다.",
                          "projectDir": dirs.first?.path ?? "", "searched": searched])
        }
        var howText = how
        if hits.count > 1 { howText += " · 같은 조건의 세션이 \(hits.count) 개라 가장 나중 것을 골랐다" }
        searched = max(searched, hits.count)
        return .hit(Hit(path: best.url.path, opened: best.opened, launch: best.launch,
                        how: howText, searched: searched,
                        projectDir: best.url.deletingLastPathComponent().path))
    }

    // 후보 파일들에서 **첫 지시문**이 이 카드를 가리키는 것만 남긴다. 이 판정이 이 파일의 축이다.
    private static func match(_ files: [URL], cardID: String, cardPath: String)
        -> [(url: URL, opened: String, launch: String)] {
        var out: [(url: URL, opened: String, launch: String)] = []
        for f in files {
            guard let (launch, opened) = firstUserPrompt(f) else { continue }
            guard launch.contains(cardID) || (!cardPath.isEmpty && launch.contains(cardPath)) else { continue }
            out.append((f, opened, launch))
        }
        return out
    }

    // MARK: - 라우팅 지시문 색인

    // `~/.claude/projects/<폴더>/<sessionId>.jsonl` 전부의 **첫 지시문**을 한 번 읽어 들고 있는다.
    // 그중 큐 카드를 가리키는 것(경로에 `lion-work-queue` 가 있거나 `카드 id` 를 적은 것)만 남긴다.
    //
    // 앞선 판은 여기서 `grep -rl` 로 기록 2.0GB 를 카드마다 훑었다. **그것이 실측 16 초였고**
    // 카드를 하나 누를 때마다 16 초를 물었다. 색인은 전체가 1 초이고 그 뒤로는 문자열 비교다.
    // 새로 생긴 기록만 더 읽으므로 두 번째부터는 거의 공짜다.
    //
    // 실측 2026-09-06: 최상위 기록 2087 개 중 라우팅 지시문으로 걸리는 것이 89 개다.
    private struct Launch { var path: String; var opened: String; var launch: String }
    private static var index: [Launch] = []
    private static var indexed = Set<String>()
    private static var indexAt: Date?
    private static var building = false
    private static let indexTTL: TimeInterval = 60

    /// 색인을 미리 만들어 둔다. 목록(`GET /api/issues`)이 그려질 때 뒤에서 부른다 —
    /// 처음 만드는 데 실측 10 초가 걸리고, 그것을 라이언이 카드를 누른 뒤에 물리면 화면이
    /// 10 초 멈춘다. 목록은 카드를 누르기 한참 전에 뜨므로 그 사이에 끝난다.
    static func warm() { _ = launchIndex() }

    private static func launchIndex() -> [Launch] {
        lock.lock()
        let fresh = indexAt.map { Date().timeIntervalSince($0) < indexTTL } ?? false
        // 이미 누가 만들고 있으면 지금 있는 것을 쓴다. 둘이 같이 만들면 같은 파일을 두 번 담는다.
        if fresh || building { defer { lock.unlock() }; return index }
        building = true
        var known = indexed
        lock.unlock()

        let fm = FileManager.default
        var add: [Launch] = []
        for dir in ((try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? []).sorted() {
            let d = projectsDir.appendingPathComponent(dir, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []) where name.hasSuffix(".jsonl") {
                let f = d.appendingPathComponent(name)
                guard known.insert(f.path).inserted else { continue }
                guard let (launch, opened) = firstUserPrompt(f) else { continue }
                // 라우팅으로 넘어온 지시문만 남긴다. 그 밖의 세션은 카드와 무관하고, 다 담으면
                // 2087 개의 지시문을 메모리에 들고 있게 된다.
                guard launch.contains("lion-work-queue") || launch.contains("카드 id")
                        || launch.contains("[id]") else { continue }
                add.append(Launch(path: f.path, opened: opened, launch: launch))
            }
        }

        lock.lock(); defer { lock.unlock() }
        index.append(contentsOf: add)
        indexed = known
        indexAt = Date()
        building = false
        return index
    }

    // 이 세션에서 열어도 되는 경로 전부. `remember()` 를 부르는 자리가 여기 하나이므로,
    // 여기에 담기지 않은 것은 `/api/issues/reveal` 도 `/api/issues/transcript` 도 거절한다.
    //
    // `file`(기록 .jsonl 자신)과 `cwd`(그 세션이 일한 작업 폴더)를 2026-09-06 에 더했다.
    // 세션 줄의 `[파일 열기]`/`[폴더 열기]` 와 기록 팝업이 그 둘을 넘기는데, 앞선 판은
    // `directiveFiles`/`outputFiles` 만 담아서 그 셋이 전부 `unknown-path` 로 거절됐다.
    private static func pathsIn(_ d: [String: Any]) -> [String] {
        var out: [String] = []
        for k in ["directiveFiles", "outputFiles"] {
            for row in (d[k] as? [[String: Any]]) ?? [] {
                if let p = row["path"] as? String, !p.isEmpty { out.append(p) }
            }
        }
        let fm = FileManager.default
        // 기록 파일. 존재하는 것만 담는다 — 목록은 "열 수 있는 것" 의 목록이다.
        if let f = d["file"] as? String, f.hasPrefix("/"), !f.contains(".."),
           fm.fileExists(atPath: f) { out.append(f) }
        // 작업 폴더. 폴더라서 파일 존재 확인 대신 **폴더인지**만 본다.
        if let c = d["cwd"] as? String, c.hasPrefix("/"), !c.contains("..") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue { out.append(c) }
        }
        return out
    }

    // MARK: - 기록 읽기

    // 첫 사용자 메시지 = 그 세션이 무엇을 하러 떴는가. 툴 결과와 하네스가 밀어 넣은 것은 뺀다.
    //
    // 앞에서부터 조금씩 읽고 찾는 즉시 멈춘다. 후보가 60 개까지 오는데 파일 하나가 15MB 까지
    // 가므로, 앞을 통째로 읽으면 찾기 한 번이 십 초 단위가 된다 — 실측 17 초의 원인이 이것이었다.
    // 첫 지시문은 거의 언제나 앞 64KB 안에 있다.
    private static func firstUserPrompt(_ url: URL) -> (text: String, at: String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        var buf = Data()
        while buf.count < 1024 * 1024 {         // 여기까지 봐도 사람 말이 없으면 그런 세션이다
            guard let d = try? h.read(upToCount: chunk), !d.isEmpty else { break }
            let atEOF = d.count < chunk
            buf.append(d)
            guard let s = String(data: buf, encoding: .utf8) else { if atEOF { break } else { continue } }
            var lines = s.components(separatedBy: "\n")
            if !atEOF { lines.removeLast() }    // 마지막 줄은 아직 안 끝났을 수 있다
            for line in lines {
                // JSON 파싱은 비싸다. 문자열로 먼저 거른다.
                guard line.contains("\"type\":\"user\""), let o = jsonObject(line),
                      (o["type"] as? String) == "user", (o["isMeta"] as? Bool) != true else { continue }
                let t = userText(o)
                guard !t.isEmpty, !isSystemInjected(t) else { continue }
                return (t, (o["timestamp"] as? String) ?? "")
            }
            if atEOF { break }
        }
        return nil
    }

    // 한 세션 전체를 훑어 쓴 파일과 마지막 보고를 뽑는다.
    //
    // 하위 대화(`<sessionId>/subagents/*.jsonl`)도 같이 센다. 디렉터가 띄운 세션은 일을 워커에게
    // 넘기는 일이 잦아서, 본체만 보면 파일을 하나도 안 쓴 것으로 보인다 — 실제로 쓴 것은 워커다.
    // 다만 **마지막 보고는 본체에서만** 가져온다. 워커의 보고는 그 세션이 라이언에게 낸 답이 아니다.
    private static func scan(_ url: URL, launch: String, opened: String) -> [String: Any] {
        var writes: [String] = []
        var seen = Set<String>()
        var report = ""
        var lastAt = opened
        var userTurns = 0
        // 그 세션이 **일한 작업 폴더**. 기록 폴더 이름(`-Users-lioncho-…`)에서 되돌리는 것은
        // 불가능하다 — `projectDirName` 이 `/` 와 `_` 와 `.` 을 전부 `-` 로 바꾸므로 역변환이
        // 한 값으로 안 정해진다. 그래서 기록 안의 `cwd` 를 그대로 읽는다.
        // 처음 나온 것 하나만 쓴다. 실측(97cc3cc2 세션 124 줄)에서 값은 하나뿐이었고,
        // 여럿이면 그 세션이 시작한 자리가 맞다.
        var cwd = ""

        func walk(_ f: URL, isMain: Bool) {
            guard let data = try? Data(contentsOf: f, options: [.mappedIfSafe]) else { return }
            let capped = data.count > 64 * 1024 * 1024 ? data.prefix(64 * 1024 * 1024) : data
            guard let text = String(data: capped, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\n") {
                guard line.count > 20 else { continue }
                let isUser = line.contains("\"type\":\"user\"")
                let isAsst = line.contains("\"type\":\"assistant\"")
                guard isUser || isAsst, let o = jsonObject(line) else { continue }
                let type = o["type"] as? String ?? ""
                if isMain, let ts = o["timestamp"] as? String, !ts.isEmpty, ts > lastAt { lastAt = ts }
                if isMain, cwd.isEmpty, let c = o["cwd"] as? String, c.hasPrefix("/") { cwd = c }
                if type == "user" {
                    guard isMain, (o["isMeta"] as? Bool) != true else { continue }
                    let t = userText(o)
                    if !t.isEmpty, !isSystemInjected(t) { userTurns += 1 }
                    continue
                }
                guard type == "assistant",
                      let msg = o["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                for b in blocks {
                    switch b["type"] as? String ?? "" {
                    case "text":
                        guard isMain else { continue }
                        let t = (b["text"] as? String ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { report = t }
                    case "tool_use":
                        let name = b["name"] as? String ?? ""
                        guard ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name),
                              let input = b["input"] as? [String: Any] else { continue }
                        let p = (input["file_path"] as? String)
                            ?? (input["notebook_path"] as? String) ?? ""
                        guard p.hasPrefix("/"), !p.contains(".."), isKeepable(p),
                              seen.insert(p).inserted else { continue }
                        writes.append(p)
                    default: continue
                    }
                }
            }
        }

        walk(url, isMain: true)
        let subs = url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: subs.path)) ?? []).sorted()
        where name.hasSuffix(".jsonl") {
            walk(subs.appendingPathComponent(name), isMain: false)
        }

        // 지시서로 읽히는 것과 그 밖의 것. 축은 **폴더 하나**다 — 이 워크스페이스의 규약이
        // 작업지시서를 `issue/` 아래에 두는 것이고(work-directive-spec), 실측으로 맞는다.
        //
        // 파일 **이름**에 `directive` 가 들었는지는 안 본다. 처음에 그것도 축으로 넣었더니
        // `channels/linkedin/20260905-directive-is-deliverable.md` 가 걸렸다 — 그것은 지시서가
        // 아니라 "작업지시서가 곧 산출물"을 주제로 쓴 **링크드인 글**, 곧 결과물이다. 이름의
        // 한 조각으로 종류를 정하면 소재가 지시서인 글이 전부 지시서로 잘못 선다.
        func isDirectiveFile(_ p: String) -> Bool {
            p.contains("/issue/") || p.contains("/issues/")
                || (p as NSString).lastPathComponent.contains("지시서")
        }
        let ds = writes.filter(isDirectiveFile).map { row(key: "세션이 쓴 지시서", path: $0) }
        let os = writes.filter { !isDirectiveFile($0) }.map { row(key: "세션이 쓴 파일", path: $0) }

        return [
            "found": true,
            "file": url.path,
            // 그 세션이 일한 작업 폴더. 못 읽었으면 빈 문자열이고, 화면은 그때만 기록 폴더로
            // 떨어지며 버튼 title 에 무엇을 여는지 그대로 적는다.
            "cwd": cwd,
            "sessionId": String(url.lastPathComponent.dropLast(6)),   // ".jsonl"
            "startedAt": opened,
            "lastAt": lastAt,
            "userTurns": userTurns,
            "writeCount": writes.count,
            // 첫 지시문 전문. 문제 정의와 어떻게 일할 건지가 이 안에 있다.
            "directive": String(launch.prefix(20000)),
            // 마지막 보고. 하우스 룰상 여기 `한 줄 정리` 가 붙어 있다.
            "report": String(report.prefix(8000)),
            "directiveFiles": ds,
            "outputFiles": os,
        ]
    }

    // 스크래치패드는 결과물이 아니다. 세션마다 임시 폴더에 스크립트를 쓰는데(실측
    // `/private/tmp/claude-501/…/scratchpad/census.py`), 그것을 결과물 칸에 세우면 진짜 산출물이
    // 잡동사니에 묻힌다. 그리고 그 경로들은 곧 지워져서 전부 `경로 없음` 으로 뜬다.
    private static func isKeepable(_ p: String) -> Bool {
        for bad in ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/",
                    "/.git/", "/node_modules/"] where p.contains(bad) {
            return false
        }
        return true
    }

    // 화면의 artRow 가 그대로 받는 모양. `WorkQueueStore.Pointer.dict` 와 키가 같다.
    private static func row(key: String, path: String) -> [String: Any] {
        var isDir: ObjCBool = false
        let ex = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return ["key": key, "raw": path, "kind": "절대경로", "path": path,
                "exists": ex, "isDir": isDir.boolValue, "openable": ex]
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{"), let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func userText(_ o: [String: Any]) -> String {
        guard let msg = o["message"] as? [String: Any] else { return "" }
        if let s = msg["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = msg["content"] as? [[String: Any]] else { return "" }
        var out: [String] = []
        for b in blocks where (b["type"] as? String) == "text" {
            let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        return out.joined(separator: "\n")
    }

    // NOTE: 이 절은 `transcriptJSON` **앞**에 선다. `.e2e/issues.test.js` 가 이 파일을
    // `transcriptJSON(` 선언 줄부터 파일 끝까지 잘라서 그 조각에 `jsonl` 이라는 낱말이
    // 없는지를 본다 — 그 함수가 원본 JSONL 을 그대로 붓지 않는다는 판정이다. 아래에 두면
    // 이 절의 `subagents/*.jsonl` 이 그 조각에 들어가 그 판정이 거짓으로 진다.
    //
    // 그리고 그 선언 줄을 여기서 글자 그대로 다시 적지 않는다. 시험이 `indexOf` 로 **첫 번째**
    // 등장을 찾기 때문에, 이 파일 안에서 그 선언 문자열을 글자 그대로 다시 쓰면 슬라이스가
    // 진짜 함수가 아니라 여기서 시작해 뒤쪽 판정이 통째로 어긋난다.
    // MARK: - 이 카드를 **쓴** 실행 (SPEC DASH-14)

    // 위 `session(cardID:…)` 이 찾는 것은 카드를 **받은** 세션이다. 여기서 찾는 것은 그 카드
    // 파일을 **만든** 실행이고 둘은 다른 기록이다. 실측 —
    //   카드를 쓴 실행: `.../11b66f83-…/subagents/agent-a76a3488df2463e20.jsonl`
    //                   (codex exec / gpt-6-astra), 2026-09-05T23:14Z
    //   카드를 받은 세션: `bc96ab37-…` (lion-condition-mate 폴더), 2026-09-06T08:45Z
    // 섹션 2 `수정된 최초의 리퀘스트` 의 값은 카드의 `## 1초 요약` 의 `요구` 줄이므로, 라이언이
    // 물은 "그 수정을 어떤 모델이 얼마에 했나" 는 앞의 것을 가리킨다. 뒤엣것을 재사용하면
    // **틀린 세션**의 숫자가 화면에 선다.
    //
    // 새 로그 파일을 만들지 않는다 — 라이언의 제약이 "따로 파일을 만들 필요 없을 것 같은데"
    // 이고, 실제로 세 값이 전부 이미 디스크에 있다. codex 는 Bash tool_result 본문에 그대로
    // 찍힌 배너에서, Claude 는 `message.model` / `message.usage` 에서 읽는다.
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다). 라이언의 구술 낱말 `앱폭트` 를 `effort` 로
    // 확정했다. 근거 둘 — 배너에 `reasoning effort:` 라는 필드가 그 이름 그대로 있고, 이 카드를
    // 쓴 Codex 실행 자신이 그 낱말을 `에포트` 로 옮겨 적었다. 다만 라이언의 문장은 "얼마나 …
    // **써서**" 로 쓴 **양**을 묻고 `reasoning effort` 는 양이 아니라 설정값이므로, 양에 해당하는
    // `tokens` 를 같이 돌려준다. 어느 필드에서 왔는지는 `tokensFrom` 에 적어서 이 해석이 틀렸을
    // 때 라이언이 화면만 보고 반려할 수 있게 한다.
    //
    // ASSUMPTION: codex 실행에는 `message.usage` 가 없으므로 토큰은 배너 꼬리의 `tokens used`
    // 줄에서만 읽는다. 그 줄이 없으면 `tokens` 는 0 이고 `tokensFrom` 이 비어서, 화면이 그
    // 조각을 통째로 뺀다. 0 을 "0 토큰 썼다" 로 그리지 않는다.

    private static var revisionHit: [String: [String: Any]] = [:]
    private static var revisionMiss: [String: (at: Date, value: [String: Any])] = [:]
    // 후보 상한. 넘기면 최신 것부터 이만큼만 본다. 실측 후보가 147 개이므로 여유가 크다.
    private static let revisionCandidateCap = 400

    /// 카드 하나를 **만든 실행**의 모델 · effort · 토큰 · 걸린 초. 못 찾으면 빈칸이 아니라
    /// `found:false` 와 **왜 못 찾았는지**를 돌려준다.
    ///
    /// - Parameters:
    ///   - cardID: 카드의 `id:` — 캐시 키로만 쓴다. 찾는 열쇠는 카드 **파일 이름**이다.
    ///             실측으로 codex 출력에 적힌 것이 상대경로(`organization/…/inbox/<이름>.md`)라
    ///             절대경로로만 찾으면 하나도 안 걸린다.
    ///   - cardPath: 카드 파일 절대경로
    ///   - captured: 카드 프론트매터의 `captured:`. 후보를 좁히는 유일한 열쇠다.
    static func revision(cardID: String, cardPath: String, captured: String) -> [String: Any] {
        lock.lock()
        let hit = revisionHit[cardID]
        let miss = revisionMiss[cardID]
        lock.unlock()
        if let h = hit { remember([(h["file"] as? String) ?? ""]); return h }
        if let m = miss, Date().timeIntervalSince(m.at) < missTTL { return m.value }

        let out = findRevision(cardPath: cardPath, captured: captured)
        lock.lock()
        if (out["found"] as? Bool) == true {
            revisionHit[cardID] = out
            revisionMiss[cardID] = nil
            if revisionHit.count > 240 { revisionHit.removeAll() }
        } else {
            // 방금 만들어진 카드는 곧 찾아진다. 영구히 캐시하면 앱을 다시 띄울 때까지
            // `없음` 으로 굳는다 — `missed` 와 같은 이유로 짧게 둔다.
            revisionMiss[cardID] = (Date(), out)
        }
        lock.unlock()
        if let f = out["file"] as? String, !f.isEmpty { remember([f]) }
        return out
    }

    private struct RevHit {
        var runner: String
        var model: String
        var effort: String
        var tokens: Int
        var tokensFrom: String
        var startedAt: String
        var endedAt: String
        var file: String
        var sessionId: String
    }

    private static func findRevision(cardPath: String, captured: String) -> [String: Any] {
        let cardName = (cardPath as NSString).lastPathComponent
        guard !cardName.isEmpty else {
            return ["found": false, "why": "카드 파일 경로가 비어 있어 무엇을 찾을지 정할 수 없다."]
        }

        // 1. `captured` 를 **로컬 시각**으로 읽는다. 실측 — `captured: 2026-09-06-0445` 는 카드를
        //    쓴 python 이 `date +%Y-%m-%d-%H%M` 로 찍은 값이고 이 맥은 UTC+5:30 이라
        //    `2026-09-05T23:15:53Z + 5:30 = 04:45` 로 정확히 맞는다.
        //    카드 파일의 `birthtime` 은 쓰지 않는다 — 나중에 `target_handle` 을 적은 Edit 가
        //    파일을 새로 써서 실제 생성보다 9 시간 30 분 뒤로 갱신돼 있었다.
        let capAt = capturedDate(captured)
        // 파싱 실패면 이 필터를 건너뛰고 전체를 후보로 둔다. 느리지만 틀리지는 않는다.
        let cutoff = capAt.map { $0.addingTimeInterval(-120) }

        // 2. 후보 모으기. **하위 대화(`<sessionId>/subagents/*.jsonl`)를 반드시 포함한다** —
        //    실측으로 카드를 쓴 것이 바로 그 자리다. `launchIndex()` 는 최상위 `.jsonl` 만
        //    담으므로 여기에 쓸 수 없다.
        let fm = FileManager.default
        var all = 0
        var cands: [(url: URL, mtime: Date)] = []
        if let it = fm.enumerator(at: projectsDir,
                                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in it {
                guard u.pathExtension == "jsonl" else { continue }
                all += 1
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey])
                let m = v?.contentModificationDate ?? Date.distantPast
                if let c = cutoff, m < c { continue }
                cands.append((u, m))
            }
        }
        var capped = false
        if cands.count > revisionCandidateCap {
            cands.sort { $0.mtime > $1.mtime }
            cands = Array(cands.prefix(revisionCandidateCap))
            capped = true
        }

        // 3~5. 후보를 훑어 codex 갈래와 claude 갈래를 각각 모으고, codex 가 이긴다.
        //      같은 갈래에서 여럿이면 **가장 이른 것**을 고른다. 카드를 처음 만든 것이 codex 이고
        //      Claude 쪽은 나중에 `status`·`target_handle` 을 적은 Edit 라, 라이언이 물은 것은
        //      수정을 **만든** 실행이지 나중에 좌표를 적은 실행이 아니다.
        var codexHits: [RevHit] = []
        var claudeHits: [RevHit] = []
        var scanned = 0
        let needle = Data(cardName.utf8)
        for (u, _) in cands {
            guard let data = try? Data(contentsOf: u, options: [.mappedIfSafe]) else { continue }
            let sliced = data.count > 64 * 1024 * 1024 ? data.prefix(64 * 1024 * 1024) : data[...]
            // 문자열로 먼저 거르고 그다음에 JSON 파싱한다(`scan()` 과 같은 방식). 바이트
            // 비교라 String 변환 비용을 후보 27 개에만 물린다 — 실측 147 개 훑기가 0.1 초다.
            guard sliced.range(of: needle) != nil else { continue }
            scanned += 1
            // 인덱스를 0 부터로 맞춘 사본을 넘긴다. `prefix` 로 자른 조각은 시작 인덱스가
            // 0 이 아니라, 아래의 바이트 오프셋 계산이 어긋난다.
            harvest(Data(sliced), url: u, cardName: cardName, cardPath: cardPath,
                    codex: &codexHits, claude: &claudeHits)
        }

        let pick = codexHits.sorted { $0.endedAt < $1.endedAt }.first
            ?? claudeHits.sorted { $0.endedAt < $1.endedAt }.first
        guard let h = pick else {
            var why = "기록 \(cands.count) 개(전체 \(all) 개 중 `captured` 이후에 수정된 것)를 봤는데 "
                + "이 카드 파일(`\(cardName)`)을 만든 실행이 없다. "
            if capAt == nil && !captured.isEmpty {
                why += "카드의 `captured: \(captured)` 를 시각으로 못 읽어 전체를 후보로 뒀는데도 없다. "
            } else if capAt == nil {
                why += "카드에 `captured:` 가 없어 전체를 후보로 뒀는데도 없다. "
            }
            if capped { why += "후보가 상한 \(revisionCandidateCap) 개를 넘어 최신 것부터 그만큼만 봤다. " }
            why += "카드 이름을 담은 기록은 \(scanned) 개였다 — 카드를 읽기만 한 세션이고, "
                + "쓴 실행은 기록이 지워졌거나 Claude Code 밖(셸 heredoc 등)에서 돌았다."
            return ["found": false, "why": why]
        }

        let secs = elapsed(from: h.startedAt, to: h.endedAt)
        var out: [String: Any] = [
            "found": true,
            "runner": h.runner,
            "model": h.model,
            "effort": h.effort,
            "tokens": h.tokens,
            "tokensFrom": h.tokensFrom,
            "startedAt": h.startedAt,
            "endedAt": h.endedAt,
            "file": h.file,
            "sessionId": h.sessionId,
        ]
        if let s = secs { out["seconds"] = (s * 10).rounded() / 10 }
        out["why"] = h.runner == "codex"
            ? "이 카드 파일을 만든 실행이다 — codex exec 출력에 카드 경로와 `1초 요약` 이 있다."
            : "이 카드 파일을 만든 실행이다 — `\(h.model)` 이 이 경로로 Write/Edit 를 했다."
        return out
    }

    // 기록 한 벌에서 이 카드를 만든 후보를 뽑는다.
    //
    // **줄을 String 으로 쪼개지 않는다.** 후보 27 개가 2,400 만 글자라, 앞선 판처럼
    // `components(separatedBy:)` 로 쪼개고 줄마다 `String.contains` 를 물으면 그 한 가지가
    // 첫 호출의 2~4 초였다(전체 0.5 초는 파일 읽기와 걸러내기뿐이었다). 여기서는 줄 경계를
    // 바이트로 뜨고, 카드 이름이 실제로 나온 자리(보통 한 파일에 서너 개)만 String 으로 바꿔
    // JSON 으로 판다. 되짚기도 바이트 비교로 한다.
    private static func harvest(_ d: Data, url: URL, cardName: String, cardPath: String,
                                codex: inout [RevHit], claude: inout [RevHit]) {
        let sessionFromPath = String(url.lastPathComponent.dropLast(6))   // ".jsonl"

        var bounds: [Range<Int>] = []
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var s = 0
            var i = 0
            let n = p.count
            while i < n {
                if p[i] == 0x0A {
                    if i > s { bounds.append(s..<i) }
                    s = i + 1
                }
                i += 1
            }
            if s < n { bounds.append(s..<n) }
        }
        guard !bounds.isEmpty else { return }

        func lineIndex(containing off: Int) -> Int? {
            var lo = 0, hi = bounds.count - 1
            while lo <= hi {
                let m = (lo + hi) / 2
                if off < bounds[m].lowerBound { hi = m - 1 }
                else if off >= bounds[m].upperBound { lo = m + 1 }
                else { return m }
            }
            return nil
        }
        func has(_ i: Int, _ needle: Data) -> Bool {
            d.range(of: needle, options: [], in: bounds[i]) != nil
        }
        func obj(_ i: Int) -> [String: Any]? {
            guard bounds[i].count > 20 else { return nil }
            guard let s = String(data: d.subdata(in: bounds[i]), encoding: .utf8) else { return nil }
            return jsonObject(s)
        }

        let nameBytes = Data(cardName.utf8)
        let asstBytes = Data("\"type\":\"assistant\"".utf8)
        let userBytes = Data("\"type\":\"user\"".utf8)

        // codex 갈래의 **시작 시각**은 그 tool_result 가 아니라 같은 `tool_use_id` 를 낸 앞쪽
        // assistant 레코드에 있다. 그 줄만 되짚어 찾는다.
        func assistantAt(toolUseID tid: String, before i: Int) -> String {
            guard !tid.isEmpty else { return "" }
            let t = Data(tid.utf8)
            var j = i - 1
            while j >= 0 {
                if has(j, t), has(j, asstBytes), let o = obj(j),
                   (o["type"] as? String) == "assistant" {
                    return (o["timestamp"] as? String) ?? ""
                }
                j -= 1
            }
            return ""
        }

        // claude 갈래의 시작 시각은 **바로 앞 사람 턴**이다. 툴 결과와 하네스가 밀어 넣은 것은
        // 사람 턴이 아니므로 `scan()` 과 같은 판정(`isMeta` · `isSystemInjected`)으로 거른다.
        func humanAt(before i: Int) -> String {
            var j = i - 1
            while j >= 0 {
                if has(j, userBytes), let o = obj(j), (o["type"] as? String) == "user",
                   (o["isMeta"] as? Bool) != true {
                    let t = userText(o)
                    if !t.isEmpty, !isSystemInjected(t) { return (o["timestamp"] as? String) ?? "" }
                }
                j -= 1
            }
            return ""
        }

        // 카드 이름이 실제로 나온 줄만 고른다. 이것이 이 함수의 성능 축이다.
        var targets: [Int] = []
        var from = 0
        while from < d.count,
              let r = d.range(of: nameBytes, options: [], in: from..<d.count) {
            if let li = lineIndex(containing: r.lowerBound), targets.last != li { targets.append(li) }
            from = max(r.upperBound, from + 1)
        }

        for i in targets {
            let isAsst = has(i, asstBytes)
            let isUser = has(i, userBytes)
            guard isAsst || isUser, let o = obj(i) else { continue }
            let at = (o["timestamp"] as? String) ?? ""
            guard let msg = o["message"] as? [String: Any] else { continue }

            // claude 갈래 — `Write`/`Edit`/`MultiEdit` 의 `file_path` 가 카드를 가리킨다.
            if isAsst, (o["type"] as? String) == "assistant",
               let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    let name = b["name"] as? String ?? ""
                    guard ["Write", "Edit", "MultiEdit"].contains(name),
                          let input = b["input"] as? [String: Any],
                          let p = input["file_path"] as? String,
                          p == cardPath || (p as NSString).lastPathComponent == cardName else { continue }
                    let u = msg["usage"] as? [String: Any] ?? [:]
                    func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                    let tk = n("input_tokens") + n("cache_creation_input_tokens")
                        + n("cache_read_input_tokens") + n("output_tokens")
                    let began = humanAt(before: i)
                    claude.append(RevHit(
                        runner: "claude",
                        model: (msg["model"] as? String) ?? "",
                        // Claude 실행에는 `reasoning effort` 필드가 없다. 빈칸으로 두고
                        // 화면이 그 조각을 통째로 뺀다 — `effort ` 만 남기지 않는다.
                        effort: "",
                        tokens: tk,
                        tokensFrom: tk > 0 ? "claude `message.usage` 합계" : "",
                        startedAt: began.isEmpty ? at : began,
                        endedAt: at,
                        file: url.path,
                        sessionId: sessionFromPath))
                }
                continue
            }

            // codex 갈래 — Bash `tool_result` 본문에 Codex 배너와 카드 경로가 같이 있다.
            guard isUser, (o["type"] as? String) == "user",
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks where (b["type"] as? String) == "tool_result" {
                let body: String
                if let s = b["content"] as? String {
                    body = s
                } else if let parts = b["content"] as? [[String: Any]] {
                    body = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else { continue }
                guard body.contains("OpenAI Codex"),
                      body.contains(cardName) || (!cardPath.isEmpty && body.contains(cardPath))
                else { continue }
                let banner = codexBanner(body)
                let tid = (b["tool_use_id"] as? String) ?? ""
                let tk = codexTokens(body)
                let began = assistantAt(toolUseID: tid, before: i)
                codex.append(RevHit(
                    runner: "codex",
                    model: banner["model"] ?? "",
                    effort: banner["reasoning effort"] ?? "",
                    tokens: tk,
                    tokensFrom: tk > 0 ? "codex `tokens used`" : "",
                    startedAt: began.isEmpty ? at : began,
                    endedAt: at,
                    file: url.path,
                    sessionId: banner["session id"] ?? sessionFromPath))
            }
        }
    }

    // Codex 배너의 `키: 값` 표. 배너는 `OpenAI Codex v…` 다음 `--------` 로 열고 닫힌다.
    private static func codexBanner(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("OpenAI Codex") }) else { return out }
        var seenRule = 0
        var i = start + 1
        while i < lines.count, i < start + 40 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("----") { seenRule += 1; if seenRule >= 2 { break }; i += 1; continue }
            if let r = t.range(of: ": ") {
                out[String(t[t.startIndex..<r.lowerBound])] = String(t[r.upperBound...])
            }
            i += 1
        }
        return out
    }

    // 꼬리의 `tokens used` 다음 줄. 콤마를 뗀다. 여럿이면 마지막 것이 그 실행의 총계다.
    private static func codexTokens(_ body: String) -> Int {
        let lines = body.components(separatedBy: "\n")
        var found = 0
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "tokens used" {
                var j = i + 1
                while j < lines.count, j < i + 4 {
                    let t = lines[j].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
                    if let n = Int(t), n > 0 { found = n; break }
                    if !t.isEmpty { break }
                    j += 1
                }
            }
            i += 1
        }
        return found
    }

    // `YYYY-MM-DD-HHMM` 과 ISO8601 둘을 받는다. 앞의 것은 **로컬 시각**으로 읽는다.
    private static func capturedDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd-HHmm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: t) { return d }
        }
        return isoDate(t)
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func elapsed(from: String, to: String) -> Double? {
        guard let a = isoDate(from), let b = isoDate(to) else { return nil }
        let d = b.timeIntervalSince(a)
        return d >= 0 ? d : nil
    }
    // MARK: - 기록 팝업이 읽는 자리 (SPEC DASH-13)

    // 기록 한 벌을 **사람이 읽는 턴 배열**로 돌려준다. 원본 JSONL 을 그대로 화면에 붓지 않는다 —
    // 124 줄짜리 파일이 796KB 이고 그중 사람이 읽을 것은 극히 일부다.
    //
    // 판정 규칙(`isMeta` · `isSystemInjected` · Write/Edit/MultiEdit/NotebookEdit)은 위 `scan()`
    // 과 **같은 한 벌**을 쓴다. 두 벌을 두면 한쪽만 고쳐지고, 그때 화면과 목록이 서로 다른
    // 세션을 말한다.
    //
    // 경로 검증은 여기서 하지 않는다. `AppDelegate.workQueueTranscriptPath` 가 다섯 조건을
    // 다 통과시킨 경로만 이 함수에 온다 — 검증을 두 자리에 두면 한쪽이 느슨해진다.
    static func transcriptJSON(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        // 파일이 2MB 를 넘어도 읽는다. md 리더처럼 통째로 거절하면 15MB 짜리 세션에서 이 기능이
        // 통째로 안 도는데, 그런 세션이야말로 라이언이 보고 싶어 하는 것이다. `scan()` 과 같은
        // 64MB 상한을 쓰고 매핑으로 연다.
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return "{\"ok\":false,\"error\":\"unreadable\"}"
        }
        let capped = data.count > 64 * 1024 * 1024 ? data.prefix(64 * 1024 * 1024) : data
        guard let text = String(data: capped, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"unreadable\"}"
        }

        var cwd = ""
        var turns: [[String: Any]] = []
        for line in text.components(separatedBy: "\n") {
            guard line.count > 20 else { continue }
            let isUser = line.contains("\"type\":\"user\"")
            let isAsst = line.contains("\"type\":\"assistant\"")
            guard isUser || isAsst, let o = jsonObject(line) else { continue }
            let type = o["type"] as? String ?? ""
            if cwd.isEmpty, let c = o["cwd"] as? String, c.hasPrefix("/") { cwd = c }
            let at = (o["timestamp"] as? String) ?? ""
            if type == "user" {
                guard (o["isMeta"] as? Bool) != true else { continue }
                let t = userText(o)
                guard !t.isEmpty, !isSystemInjected(t) else { continue }
                turns.append(["role": "user", "at": at, "text": String(t.prefix(4000)), "files": [String]()])
                continue
            }
            guard type == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            var parts: [String] = []
            var files: [String] = []
            for b in blocks {
                switch b["type"] as? String ?? "" {
                case "text":
                    let t = (b["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { parts.append(t) }
                case "tool_use":
                    // 쓴 파일만 담는다. 읽기·검색·셸 호출은 담지 않는다 — 라이언이 보고 싶은
                    // 것은 그 턴이 **무엇을 만들었나**이고, 나머지는 소음이다.
                    let name = b["name"] as? String ?? ""
                    guard ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name),
                          let input = b["input"] as? [String: Any] else { continue }
                    let p = (input["file_path"] as? String)
                        ?? (input["notebook_path"] as? String) ?? ""
                    if p.hasPrefix("/"), !files.contains(p) { files.append(p) }
                default: continue
                }
            }
            let t = parts.joined(separator: "\n")
            guard !t.isEmpty || !files.isEmpty else { continue }
            turns.append(["role": "assistant", "at": at, "text": String(t.prefix(4000)), "files": files])
        }

        let total = turns.count
        // 뒤에서부터 400 개. 오래된 것을 자른다 — 라이언이 보고 싶은 것은 그 세션이 무엇을
        // 했나이고 그것은 뒤에 있다.
        if turns.count > 400 { turns.removeFirst(turns.count - 400) }
        // 전체 2MB 상한도 **뒤에서부터** 채운다. 같은 이유다.
        var budget = 2_000_000
        var kept: [[String: Any]] = []
        for t in turns.reversed() {
            let cost = ((t["text"] as? String)?.utf8.count ?? 0)
                + ((t["files"] as? [String]) ?? []).reduce(0) { $0 + $1.utf8.count } + 120
            if !kept.isEmpty && cost > budget { break }
            budget -= cost
            kept.append(t)
        }
        kept.reverse()

        let payload: [String: Any] = [
            "ok": true,
            "path": path,
            "sessionId": String(url.lastPathComponent.dropLast(6)),   // ".jsonl"
            "cwd": cwd,
            "turns": kept,
            "total": total,
            "shown": kept.count,
            // 자른 것이 있으면 그렇게 말한다. 조용히 자르지 않는 것이 이 화면의 규칙이다.
            "truncated": kept.count < total,
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let s = String(data: out, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"unreadable\"}"
        }
        return s
    }

    // 사람이 친 것이 아니라 하네스가 밀어 넣은 것. 이것을 지시문으로 잡으면 엉뚱한 세션이 걸린다.
    private static func isSystemInjected(_ t: String) -> Bool {
        for p in ["<task-notification>", "<local-command", "<command-name>",
                  "<system-reminder>", "Caveat: The messages below"] where t.hasPrefix(p) {
            return true
        }
        return false
    }

}
