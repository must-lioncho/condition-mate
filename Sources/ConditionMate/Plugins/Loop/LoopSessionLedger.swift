import Foundation

// 세션 원장 — "이 Claude 세션은 어떤 루프를 돌리려고 열린 것인가"를 디스크에 한 번만 판정해
// 남긴다.
//
// 왜 필요한가. 루프 상세의 토큰 칸은 지금까지 "계측 설치 완료 · 새 모델 호출 대기 중"만 적고
// 있었다. 루프가 남긴 원장(actions-daemon.jsonl 등)에는 비용이나 호출 결과만 있고 입력·출력
// 토큰이 없기 때문이다. 그런데 그 토큰은 이미 다른 곳에 전부 있다 — 루프를 돌리려고 열렸던
// Claude 세션의 트랜스크립트(~/.claude/projects/<slug>/*.jsonl)다. 없는 것은 계측이 아니라
// "이 세션이 어느 루프의 것인가"라는 연결 하나뿐이었다. 이 파일이 그 연결만 만든다.
//
// 판정 근거는 세션의 첫 사람 프롬프트다. 코퍼스를 전수로 보면 이 축이 실제로 갈린다:
//   "Run exactly ONE SB-PO cycle now, following AGENT_PO.md…"  82개 세션이 글자까지 같다
//   "Base directory for this skill: …/skills/nss-report-daily"  44개
//   "=== POST TO REVIEW === author_id: …"                        9개
// 사람이 연 세션은 이런 모양이 아니다 — 매번 다른 한국어 구술이다. 그래서 LLM 없이도 갈린다.
// 모델 호출로 판정하지 않는 이유는 정확도가 아니라 되돌릴 수 있음이다: 규칙은 언제든 고쳐서
// 1.1GB를 다시 읽지 않고 다시 판정할 수 있지만, 모델 판정은 다시 사려면 다시 돈을 내야 한다.
//
// 그래서 이 파일은 두 층으로 갈라져 있다:
//   (1) 추출 — 트랜스크립트를 실제로 읽어 cwd·첫 프롬프트·일자별 토큰·비용을 뽑는다. 비싸다.
//       그래서 세션마다 딱 한 번만 하고 (mtime, size) 지문과 함께 디스크에 남긴다. 지문이
//       같으면 다시 읽지 않는다. 진행 중인 세션만 파일이 자라므로 다시 읽힌다.
//   (2) 판정 — 추출된 첫 프롬프트를 규칙에 넣어 그룹을 만든다. 메모리 안에서 도는 값싼 일이라
//       매 조회마다 새로 한다. 규칙을 고쳐도 (1)을 다시 하지 않는다.
//
// 등록되지 않은 루프도 숨기지 않는다. 같은 첫 프롬프트로 세션이 세 번 이상 열렸으면 사람이
// 매번 그렇게 칠 리 없으므로 기계가 연 것이다 — loops/index.md 에 등록되지 않았을 뿐 루프다.
// 그것을 "미등록 루프 후보"로 따로 세워 루프 엔지니어링 화면이 등록을 권할 수 있게 한다.
enum LoopSessionLedger {

    // MARK: - 저장 형태

    struct DaySpend: Codable {
        var t: Int = 0        // 그날 이 세션이 쓴 토큰 (신규 입력 + 출력 + 캐시 생성)
        var c: Double = 0     // 그날의 $ (캐시 읽기까지 포함한 실제 과금 산식)
    }

    // 추출 결과 한 벌 = 세션 하나. 판정 결과는 여기에 넣지 않는다 — 규칙이 바뀌면 틀린 값이
    // 디스크에 남아 다음 판정을 오염시키기 때문이다. 여기에는 관측한 것만 남는다.
    struct Row: Codable {
        var sid: String = ""
        var path: String = ""
        var proj: String = ""      // 세션 폴더 이름 꼬리 — 사람이 프로젝트를 알아보는 이름
        var cwd: String = ""
        var prompt: String = ""    // 첫 사람 프롬프트 (줄바꿈 접어 400자)
        var title: String = ""
        var firstDay: String = ""
        var lastDay: String = ""
        var mtime: Double = 0      // 지문 — 이 값이 그대로면 다시 읽지 않는다
        var size: Int = 0
        var tokens: Int = 0
        var costUSD: Double = 0
        var days: [String: DaySpend] = [:]
        var startTS: Double = 0    // 세션 목록을 시간순으로 세우는 축
        var endTS: Double = 0
        var turns: Int = 0
        var tools: Int = 0
        var analyzedAt: Double = 0
        var v: Int = 1             // 추출기 판(版). 올리면 전량 재추출된다.
    }

    // 추출기가 바뀌어 예전 행을 믿을 수 없을 때만 올린다.
    // 2 — 세션 시작·종료 시각과 턴·도구 수를 추가하면서 올렸다(전량 1회 재추출).
    private static let extractorVersion = 2

    // MARK: - 바깥에서 꽂아 주는 것

    // 트랜스크립트 한 개를 읽어 필요한 값을 돌려주는 함수. 앱이 이미 토큰 뷰를 위해 같은
    // 파서를 갖고 있으므로 파서를 여기서 또 쓰지 않고 그것을 그대로 꽂아 쓴다 — 같은 파일을
    // 두 벌의 규칙으로 세면 화면 두 곳의 숫자가 서로 어긋난다.
    struct Extract {
        var days: [String: DaySpend]
        var title: String
        var cwd: String
        var prompt: String
        var firstDay: String
        var lastDay: String
        var startTS: Double = 0     // 세션이 열린 시각 (epoch)
        var endTS: Double = 0
        var turns: Int = 0
        var tools: Int = 0
    }
    static var extractor: ((URL, Date, Int) -> Extract)?
    static var storeDir: URL?
    static var log: ((String) -> Void)?

    // MARK: - 상태

    private static let queue = DispatchQueue(label: "cm.loop-session-ledger", qos: .utility)
    private static let lock = NSLock()
    private static var rows: [String: Row] = [:]        // sid -> 행
    private static var loaded = false
    private static var running = false
    private static var lastPassAt: Date?
    private static var passStartedAt: Date?
    private static var totalFiles = 0
    private static var staleFiles = 0                   // 이번 패스에서 읽어야 할 파일 수
    private static var doneThisPass = 0
    private static var currentPath = ""
    // 매 패스에서 전체 파일 지문을 확인한다. 앱 미실행 중 생긴 오래된 파일도
    // 놓치지 않되, 내용 파싱은 지문이 달라진 파일에만 수행한다.
    private static var fullScanRunning = false
    private static var fullScanQueued = false
    private static var fullScanScheduled = false
    // 판정 결과 메모. 판정 자체는 값싸지만 토큰 뷰는 세션 한 줄마다 배지를 물어보므로
    // (하루 50줄 × 전량 판정) 그대로 두면 화면 한 번에 수만 번 다시 판정하게 된다.
    // 행이 바뀔 때만 무효화한다.
    private static var rowsStamp = 0
    private static var verdictCache: (rowsStamp: Int, definitionsStamp: String, map: [String: Verdict])?

    private static var storeURL: URL? {
        guard let dir = storeDir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private static var projectsBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: - 수명

    // 앱이 뜬 뒤 한 박자 늦게 첫 패스를 건다. 첫 패스는 1GB 넘는 트랜스크립트를 전량 읽으므로
    // 실행 직후의 화면 그리기와 겹치면 사람이 앱이 느리다고 느낀다.
    static func start(delay: TimeInterval = 25) {
        queue.asyncAfter(deadline: .now() + delay) { runPass(fullScan: false) }
    }

    // 조회가 들어왔을 때 너무 오래된 원장이면 조용히 다음 패스를 예약한다. 조회 자체는
    // 기다리지 않는다 — 화면은 "어디까지 분석했는지"를 그리면 되고, 나머지는 다음 조회에 채워진다.
    private static func scheduleIfStale(minInterval: TimeInterval = 30) {
        lock.lock()
        let idle = !running && (lastPassAt.map { Date().timeIntervalSince($0) > minInterval } ?? true)
        lock.unlock()
        if idle { queue.async { runPass(fullScan: false) } }
    }

    // 전체 새로고침도 지문이 같은 행을 억지로 재분석하지는 않는다. 전체 파일을 다시 찾아
    // 누락됐거나 변경된 과거 세션까지 갱신하는 동작이다.
    private static func scheduleFullScan() {
        lock.lock()
        if running {
            fullScanQueued = true
            lock.unlock()
            return
        }
        if fullScanScheduled { lock.unlock(); return }
        fullScanScheduled = true
        lock.unlock()
        queue.async {
            lock.lock(); fullScanScheduled = false; lock.unlock()
            runPass(fullScan: true)
        }
    }

    // MARK: - 추출 패스

    private static func runPass(fullScan: Bool) {
        guard let extractor else { return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true; fullScanRunning = fullScan; passStartedAt = Date(); doneThisPass = 0
        lock.unlock()
        loadIfNeeded()

        let fm = FileManager.default
        var files: [(url: URL, mtime: Date, size: Int)] = []
        if let subs = try? fm.contentsOfDirectory(at: projectsBase,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inner = (try? fm.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for f in inner where f.pathExtension == "jsonl" {
                    let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let mtime = rv?.contentModificationDate ?? .distantPast
                    files.append((f, mtime, rv?.fileSize ?? 0))
                }
            }
        }
        // 새 세션과 아직 자라는 세션이 먼저 — 사람이 지금 궁금해하는 것은 오늘 돈 루프다.
        files.sort { $0.mtime > $1.mtime }

        lock.lock()
        totalFiles = files.count
        let known = rows
        lock.unlock()

        let stale = files.filter { f in
            guard let r = known[f.url.deletingPathExtension().lastPathComponent] else { return true }
            return r.v != extractorVersion || r.size != f.size
                || abs(r.mtime - f.mtime.timeIntervalSince1970) > 1
        }
        lock.lock(); staleFiles = stale.count; lock.unlock()

        var sinceSave = 0
        for f in stale {
            lock.lock(); currentPath = f.url.lastPathComponent; lock.unlock()
            let ex = extractor(f.url, f.mtime, f.size)
            var row = Row()
            row.sid = f.url.deletingPathExtension().lastPathComponent
            row.path = f.url.path
            row.proj = projectName(cwd: ex.cwd, folder: f.url.deletingLastPathComponent().lastPathComponent)
            row.cwd = ex.cwd
            row.prompt = ex.prompt
            row.title = ex.title
            row.firstDay = ex.firstDay
            row.lastDay = ex.lastDay
            row.mtime = f.mtime.timeIntervalSince1970
            row.size = f.size
            row.days = ex.days
            row.startTS = ex.startTS; row.endTS = ex.endTS
            row.turns = ex.turns; row.tools = ex.tools
            row.tokens = ex.days.values.reduce(0) { $0 + $1.t }
            row.costUSD = ex.days.values.reduce(0) { $0 + $1.c }
            row.analyzedAt = Date().timeIntervalSince1970
            row.v = extractorVersion
            lock.lock(); rows[row.sid] = row; rowsStamp += 1; doneThisPass += 1; lock.unlock()
            sinceSave += 1
            if sinceSave >= 25 { save(); sinceSave = 0 }
        }
        if sinceSave > 0 { save() }

        lock.lock()
        running = false; fullScanRunning = false; lastPassAt = Date(); currentPath = ""
        let n = doneThisPass, total = totalFiles, runQueuedFullScan = fullScanQueued
        fullScanQueued = false
        lock.unlock()
        if n > 0 { log?("LOOP-SESSIONS pass — \(n)개 새로 분석 · 검색 \(total)개 · 전체 지문 확인") }
        if runQueuedFullScan { scheduleFullScan() }
    }

    // 세션 폴더 이름은 cwd 를 인코딩한 것이라 길다. 사람이 알아보는 것은 꼬리 한두 칸뿐이다.
    private static func projectName(cwd: String, folder: String) -> String {
        let src = cwd.isEmpty ? folder.replacingOccurrences(of: "-", with: "/") : cwd
        let parts = src.split(separator: "/").map(String.init)
        return parts.last ?? folder
    }

    // MARK: - 디스크

    private static func loadIfNeeded() {
        lock.lock()
        if loaded { lock.unlock(); return }
        loaded = true
        lock.unlock()
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Row].self, from: data) else { return }
        lock.lock()
        for r in list { rows[r.sid] = r }
        rowsStamp += 1
        lock.unlock()
        log?("LOOP-SESSIONS load — \(list.count)개 세션 판정 기록을 원장에서 읽음")
    }

    private static func save() {
        guard let url = storeURL else { return }
        lock.lock(); let list = Array(rows.values); lock.unlock()
        guard let data = try? JSONEncoder().encode(list.sorted(by: { $0.lastDay > $1.lastDay })) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 판정 (값싸다 — 매 조회마다 다시 한다)

    struct Verdict {
        var key: String      // 그룹 열쇠. 같은 열쇠 = 같은 루프
        var label: String    // 사람이 읽는 이름
        var kind: String     // loop(등록됨) | candidate(미등록 루프) | human(사람이 연 세션)
        var loopId: String   // 등록된 루프일 때만
    }

    // 서명 — 첫 프롬프트에서 매번 달라지는 부분(숫자·날짜·시각)을 지운 앞머리. 같은 루프의
    // 세션은 여기가 글자까지 같다.
    private static func signature(_ prompt: String) -> String {
        var s = prompt.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression)
        // 60자. 그 뒤는 회차마다 달라지는 지시(“Order: 0. Drain…” / “Order: 1. Read…”)가 붙어
        // 같은 루프가 두 그룹으로 갈렸다. 반대로 더 줄이면 "정기 회차다."로 시작하는 서로 다른
        // 루프 네 개가 한 덩어리가 된다 — 이 코퍼스에서 둘 다 만족하는 자리가 60이다.
        return String(s.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    // "Base directory for this skill: /Users/…/skills/<name>" — 스킬 하네스가 세션을 열 때
    // 언제나 이 줄로 시작한다. 사람이 이렇게 치는 일은 없다.
    private static func skillName(_ prompt: String) -> String? {
        let marker = "Base directory for this skill:"
        guard let r = prompt.range(of: marker) else { return nil }
        let tail = prompt[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let pathPart = tail.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let name = pathPart.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    // 슬래시 커맨드로 열린 세션. Claude Code 는 그것을 <command-name>/nss-report-daily</…> 로
    // 트랜스크립트에 적는다. 사람이 직접 친 "/name …" 도 같은 것으로 본다.
    private static func slashCommand(_ prompt: String) -> String? {
        if let r = prompt.range(of: "<command-name>") {
            let tail = prompt[r.upperBound...]
            guard let end = tail.range(of: "</command-name>") else { return nil }
            let name = tail[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.isEmpty ? nil : name
        }
        guard prompt.hasPrefix("/") else { return nil }
        let rest = prompt.dropFirst()
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        // "/Users/lioncho/…" 로 시작하는 붙여넣은 경로는 커맨드가 아니다.
        if rest.dropFirst(name.count).first == "/" { return nil }
        return name.count >= 2 ? String(name) : nil
    }

    // Claude Code 자체 커맨드. 절차가 아니라 조작이므로 루프로 세지 않는다.
    private static let builtinCommands: Set<String> = [
        "login", "logout", "model", "compact", "clear", "help", "init", "resume", "cost",
        "doctor", "status", "config", "agents", "review", "memory", "vim", "terminal-setup",
    ]

    // 하네스 이름 — 스킬 부팅 머리줄과 슬래시 커맨드는 같은 것(스킬 하나)을 가리키는 두 표기다.
    // 같은 스킬이 표기 때문에 두 그룹으로 갈리면 "이 루프가 얼마 썼나"에 답할 수 없다.
    private static func harnessName(_ prompt: String) -> String? {
        slashCommand(prompt) ?? skillName(prompt)
    }

    // 등록된 루프가 자기 세션을 알아보는 방법: loops/index.md 의 sessionSignatures(첫 프롬프트
    // 앞머리)와 sessionSkills(스킬 이름). 정의가 그것을 적지 않으면 이 루프에는 세션이 붙지
    // 않는다 — 폴더가 같다는 이유로 사람 세션을 루프에 얹지 않기 위해서다.
    private struct LoopSig { var id: String; var name: String; var prefixes: [String]; var skills: [String] }
    private static func registeredLoops() -> [LoopSig] {
        LoopDefinitionStore.definitions().map { obj in
            LoopSig(id: (obj["id"] as? String) ?? "",
                    name: (obj["name"] as? String) ?? (obj["id"] as? String) ?? "",
                    prefixes: (obj["sessionSignatures"] as? [String]) ?? [],
                    skills: (obj["sessionSkills"] as? [String]) ?? [])
        }
    }

    // 루프 선언은 프로젝트 원본을 매 조회마다 직접 읽는다. 세션 행이 그대로여도 선언의
    // sessionSignatures/sessionSkills가 바뀌면 판정은 즉시 달라져야 한다. 이 지문을 캐시 키에
    // 넣지 않으면 앱을 재시작하거나 새 세션 파일이 생길 때까지 과거 세션의 소급 귀속이 안 된다.
    private static func definitionsStamp(_ loops: [LoopSig]) -> String {
        loops.map { loop in
            ([loop.id, loop.name] + loop.prefixes.sorted() + ["|"] + loop.skills.sorted()).joined(separator: "\u{1f}")
        }.sorted().joined(separator: "\u{1e}")
    }

    // 세션 전체를 한 번에 판정한다. 반복 서명 규칙은 코퍼스 전체를 봐야 하므로 세션 하나만
    // 따로 판정할 수 없다 — 그래서 판정은 언제나 전량으로 돈다.
    private static func classifyAll() -> [String: Verdict] {
        loadIfNeeded()
        let loops = registeredLoops()
        let defStamp = definitionsStamp(loops)
        lock.lock()
        let all = rows, stamp = rowsStamp
        if let c = verdictCache, c.rowsStamp == stamp, c.definitionsStamp == defStamp {
            lock.unlock(); return c.map
        }
        lock.unlock()

        // 서명별 세션 수와, 그 서명이 걸친 날짜 수. 세션 수만 보면 사람 세션도 잡힌다 —
        // 한 세션을 이어받거나(resume) 압축하면 새 파일이 생기면서 첫 프롬프트가 그대로
        // 복제되기 때문이다. 그 복제본은 거의 언제나 같은 날에 몰려 있다. 그래서 "세 번 이상,
        // 그리고 이틀 이상에 걸쳐"를 함께 요구한다.
        var sigCount: [String: Int] = [:]
        var sigDays: [String: Set<String>] = [:]
        for r in all.values where !r.prompt.isEmpty {
            let sig = signature(r.prompt)
            sigCount[sig, default: 0] += 1
            if !r.firstDay.isEmpty { sigDays[sig, default: []].insert(r.firstDay) }
        }

        var out: [String: Verdict] = [:]
        for (sid, r) in all {
            let p = r.prompt.trimmingCharacters(in: .whitespaces)
            if p.isEmpty {
                out[sid] = Verdict(key: "empty", label: "프롬프트 없음", kind: "human", loopId: "")
                continue
            }
            let sig = signature(p)
            let harness = harnessName(p)

            // 1. 등록된 루프가 자기 것이라고 선언한 세션
            if let hit = loops.first(where: { l in
                l.prefixes.contains(where: { p.hasPrefix($0) })
                    || (harness.map { l.skills.contains($0) } ?? false)
            }), !hit.id.isEmpty {
                out[sid] = Verdict(key: "loop:" + hit.id, label: hit.name, kind: "loop", loopId: hit.id)
                continue
            }
            // 2. 스킬·슬래시 커맨드 하네스가 연 세션 — 등록되지 않았을 뿐 정해진 절차다
            if let harness, !builtinCommands.contains(harness) {
                out[sid] = Verdict(key: "harness:" + harness, label: "/" + harness, kind: "candidate", loopId: "")
                continue
            }
            // 3. 같은 서명으로 세 번 이상, 이틀 이상에 걸쳐 열린 세션 — 기계가 반복해서 연 것
            if (sigCount[sig] ?? 0) >= 3, (sigDays[sig]?.count ?? 0) >= 2 {
                out[sid] = Verdict(key: "sig:" + String(sig.hashValue, radix: 36),
                                   label: String(p.prefix(60)), kind: "candidate", loopId: "")
                continue
            }
            // 4. 나머지는 사람이 연 세션
            out[sid] = Verdict(key: "human", label: "사람이 연 세션", kind: "human", loopId: "")
        }
        lock.lock(); verdictCache = (stamp, defStamp, out); lock.unlock()
        return out
    }

    // 토큰 뷰의 세션 한 줄이 자기 배지를 물어볼 때. sid 는 8자 접두어일 수 있다.
    static func verdict(sid: String) -> Verdict? {
        let map = classifyAll()
        if let v = map[sid] { return v }
        guard let full = map.keys.first(where: { $0.hasPrefix(sid) }) else { return nil }
        return map[full]
    }

    // MARK: - 세션 하나를 사람이 읽을 수 있게

    // GET /api/loop-engineering/session?sid=XXXXXXXX
    //
    // 트랜스크립트를 그대로 보여 주는 화면이 아니다. 한 회차가 무엇을 시켰고 무엇을 했고
    // 무엇이라 답했는지, 시각과 함께 한 줄씩 읽히게 줄여서 준다. 그래서 남기는 것은 셋뿐이다:
    //   지시  — 이 세션을 연 첫 프롬프트
    //   흐름  — 어시스턴트가 사람에게 한 말과, 눈에 띄는 도구 호출(무엇을 고쳤나·무엇을 돌렸나·
    //           누구에게 위임했나)을 시간순으로 섞은 것. 읽기 자료를 다 적으면 다시 로그가 된다.
    //   결과  — 마지막 응답
    // 나머지(파일 읽기 수백 건, 도구 인자 원문)는 세지만 적지 않는다.
    static func sessionJSON(_ path: String) -> String {
        let q = URLComponents(string: "http://x" + path)?.queryItems
        guard let sid = q?.first(where: { $0.name == "sid" })?.value, sid.count >= 6,
              sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return "{}" }
        loadIfNeeded()
        lock.lock()
        let row = rows[sid] ?? rows.first(where: { $0.key.hasPrefix(sid) })?.value
        lock.unlock()
        guard let row, let data = FileManager.default.contents(atPath: row.path) else { return "{}" }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? iso2.date(from: s) }

        struct Step { var ts: Double; var kind: String; var name: String; var text: String }
        var steps: [Step] = []
        var toolCounts: [String: Int] = [:]
        var files: [String] = []
        var agents: [String] = []
        var lastSay = ""
        var errorHits = 0

        func clip(_ s: String, _ n: Int) -> String {
            let t = s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }
        // 도구 호출 한 건에서 사람이 알아볼 한 조각만 뽑는다. 인자 전체는 로그이지 이야기가 아니다.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func target(_ name: String, _ input: [String: Any]) -> String {
            for key in ["file_path", "command", "path", "pattern", "url", "prompt", "description", "query", "skill"] {
                guard let raw = input[key] as? String, !raw.isEmpty else { continue }
                var v = raw
                if key == "command" {
                    // 명령의 머리에 붙는 `cd <긴 경로> && ` 는 매번 같아서 아무것도 알려 주지 않는데
                    // 90자 창을 통째로 먹는다. 정작 무엇을 돌렸는지가 잘려서 안 보였다.
                    // 여러 줄 명령이면 `cd <경로>` 다음이 &&가 아니라 줄바꿈이다 — 둘 다 걷어낸다.
                    while let r = v.range(of: "^\\s*cd\\s+[^&;|\\n]+(&&|;|\\n)\\s*", options: .regularExpression) {
                        v.removeSubrange(r)
                    }
                } else if key == "file_path" || key == "path" {
                    v = v.split(separator: "/").suffix(2).joined(separator: "/")
                }
                return clip(v.replacingOccurrences(of: home, with: "~"), 90)
            }
            return ""
        }

        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard line.contains("\"assistant\"") || line.contains("tool_use"),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            let sidechain = (obj["isSidechain"] as? Bool) == true
            let ts = (obj["timestamp"] as? String).flatMap(parse)?.timeIntervalSince1970 ?? 0
            for b in content {
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String) ?? ""
                    guard !sidechain, t.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else { continue }
                    lastSay = t
                    steps.append(Step(ts: ts, kind: "say", name: "", text: clip(t, 240)))
                case "tool_use":
                    let name = (b["name"] as? String) ?? ""
                    let input = (b["input"] as? [String: Any]) ?? [:]
                    toolCounts[name, default: 0] += 1
                    let tgt = target(name, input)
                    switch name {
                    case "Edit", "Write", "NotebookEdit":
                        if let f = input["file_path"] as? String, !files.contains(f) { files.append(f) }
                        steps.append(Step(ts: ts, kind: "edit", name: name, text: tgt))
                    case "Agent", "Task":
                        let who = (input["subagent_type"] as? String) ?? (input["description"] as? String) ?? ""
                        if !who.isEmpty, !agents.contains(who) { agents.append(who) }
                        steps.append(Step(ts: ts, kind: "agent", name: who,
                                          text: clip((input["description"] as? String) ?? tgt, 90)))
                    case "Bash", "Skill", "WebFetch", "WebSearch":
                        steps.append(Step(ts: ts, kind: "run", name: name, text: tgt))
                    default: break   // Read/Grep/Glob 등 읽기는 세기만 한다
                    }
                default: break
                }
            }
            if let t = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
               t.lowercased().contains("error") || t.contains("실패") { errorHits += 1 }
        }

        // 너무 길면 가운데를 접는다. 앞은 무엇을 시작했는지, 뒤는 어떻게 끝났는지가 들어 있다.
        steps.sort { $0.ts < $1.ts }
        let cap = 60
        var shown = steps
        var elided = 0
        if steps.count > cap {
            elided = steps.count - cap
            shown = Array(steps.prefix(cap / 2)) + Array(steps.suffix(cap / 2))
        }

        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
                }
            }
            return "\"" + o + "\""
        }
        let stepJSON = shown.map { st in
            "{\"ts\":\(Int(st.ts)),\"kind\":\(esc(st.kind)),\"name\":\(esc(st.name)),\"text\":\(esc(st.text))}"
        }.joined(separator: ",")
        let toolJSON = toolCounts.sorted { $0.value > $1.value }.prefix(8)
            .map { "{\"name\":\(esc($0.key)),\"n\":\($0.value)}" }.joined(separator: ",")
        let fileJSON = files.prefix(20).map { esc($0.split(separator: "/").suffix(2).joined(separator: "/")) }
            .joined(separator: ",")
        let agentJSON = agents.prefix(10).map(esc).joined(separator: ",")
        let verdict = classifyAll()[row.sid]

        return "{\"sid\":\(esc(String(row.sid.prefix(8)))),\"title\":\(esc(row.title)),"
            + "\"proj\":\(esc(row.proj)),\"cwd\":\(esc(row.cwd)),"
            + "\"loop\":\(esc(verdict?.label ?? "")),\"loopKind\":\(esc(verdict?.kind ?? "")),"
            + "\"start\":\(Int(row.startTS)),\"end\":\(Int(row.endTS)),"
            + "\"tokens\":\(row.tokens),\"cost\":\(String(format: "%.4f", row.costUSD)),"
            + "\"turns\":\(row.turns),\"tools\":\(row.tools),\"errors\":\(errorHits),"
            + "\"prompt\":\(esc(row.prompt)),\"result\":\(esc(clip(lastSay, 700))),"
            + "\"steps\":[\(stepJSON)],\"elided\":\(elided),"
            + "\"toolTop\":[\(toolJSON)],\"files\":[\(fileJSON)],\"agents\":[\(agentJSON)]}"
    }

    // MARK: - API

    // GET /api/loop-engineering/sessions
    //   ?loop=<id>    한 루프의 세션만
    //   ?summary=1    진행률과 합계만 (토큰 뷰 머리줄용 — 그룹 목록을 그리지 않는다)
    static func json(_ path: String) -> String {
        let q = URLComponents(string: "http://x" + path)?.queryItems
        let wantLoop = q?.first(where: { $0.name == "loop" })?.value
        let summaryOnly = q?.first(where: { $0.name == "summary" })?.value == "1"
        let wantsFullScan = q?.first(where: { $0.name == "refresh" })?.value == "all"
        if wantsFullScan { scheduleFullScan() } else { scheduleIfStale() }

        loadIfNeeded()
        lock.lock()
        let all = rows
        // 첫 조회가 파일 목록을 세기 전에 들어오면 total 이 0 이라 "0/0 분석 중"으로 보인다.
        // 원장에 이미 들어 있는 세션 수가 알려진 하한이므로 그것을 쓴다.
        let prog: [String: Any] = [
            "total": max(totalFiles, all.count),
            "analyzed": all.count,
            "pending": max(0, staleFiles - doneThisPass),
            "running": running,
            "doneThisPass": doneThisPass,
            "current": currentPath,
            "scope": "all",
            "lastPassAt": lastPassAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "startedAt": passStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        ]
        lock.unlock()

        let verdicts = classifyAll()

        struct Group {
            var key = "", label = "", kind = "", loopId = ""
            var sessions = 0, tokens = 0
            var cost = 0.0
            var days: [String: DaySpend] = [:]
            var projects: Set<String> = []
            var first = "", last = ""
            var rows: [Row] = []
        }
        var groups: [String: Group] = [:]
        let api = LoopAPIUsage.read(AppPaths.sub("slack-translate").appendingPathComponent("actions-daemon.jsonl"),
                                    timeZone: Settings.shared.displayTimeZone)
        let apiLoop = "condition-mate-slack-shared-reply"

        for (sid, r) in all {
            guard let v = verdicts[sid] else { continue }
            if let wantLoop, v.loopId != wantLoop { continue }
            var g = groups[v.key] ?? Group(key: v.key, label: v.label, kind: v.kind, loopId: v.loopId)
            g.sessions += 1; g.tokens += r.tokens; g.cost += r.costUSD
            for (d, s) in r.days {
                var cur = g.days[d] ?? DaySpend()
                cur.t += s.t; cur.c += s.c
                g.days[d] = cur
            }
            if !r.proj.isEmpty { g.projects.insert(r.proj) }
            if !r.firstDay.isEmpty, g.first.isEmpty || r.firstDay < g.first { g.first = r.firstDay }
            if !r.lastDay.isEmpty, r.lastDay > g.last { g.last = r.lastDay }
            g.rows.append(r)
            groups[v.key] = g
        }

        if wantLoop == nil || wantLoop == apiLoop {
            let key = "loop:" + apiLoop
            var g = groups[key] ?? Group(key: key, label: "Slack 공용 수신 · 번역 · 기본 응답", kind: "loop", loopId: apiLoop)
            for e in api.events {
                g.tokens += e.tokens; g.cost += e.cost ?? 0
                var spend = g.days[e.day] ?? DaySpend()
                spend.t += e.tokens; spend.c += e.cost ?? 0; g.days[e.day] = spend
                if g.first.isEmpty || e.day < g.first { g.first = e.day }
                if g.last.isEmpty || e.day > g.last { g.last = e.day }
            }
            if !api.events.isEmpty || !api.ambiguousDays.isEmpty { groups[key] = g }
        }

        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
                }
            }
            return "\"" + o + "\""
        }
        func money(_ v: Double) -> String { String(format: "%.4f", v) }

        let sorted = groups.values.sorted { $0.tokens > $1.tokens }
        var groupJSON: [String] = []
        if !summaryOnly {
            for g in sorted {
                let dayJSON = g.days.keys.sorted(by: >).map { d -> String in
                    let s = g.days[d]!
                    return "\(esc(d)):{\"t\":\(s.t),\"c\":\(money(s.c))}"
                }.joined(separator: ",")
                // 이름이 runs 인 이유: 그룹은 이미 sessions 에 '개수'를 싣고 있어서, 목록에
                // 같은 이름을 쓰면 같은 JSON 안에 키가 두 번 나와 뒤엣것이 앞엣것을 지운다.
                // 실제로 한 번 그렇게 만들어 개수가 사라졌다. 목록은 회차(runs)다.
                // 전체 기간 필터가 실제 전체를 뜻해야 하므로 회차를 자르지 않는다. 사람이 이
                // 목록에서 찾는 것은 "어제 그 회차"라 크기순이 아니라 시간순/날짜축을 유지한다.
                var sessJSON = g.rows.sorted { $0.startTS > $1.startTS }.map { r -> String in
                    let dayData = (try? JSONEncoder().encode(r.days)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return "{\"days\":\(dayData),\"sid\":\(esc(String(r.sid.prefix(8)))),\"title\":\(esc(r.title)),"
                        + "\"proj\":\(esc(r.proj)),\"tokens\":\(r.tokens),\"cost\":\(money(r.costUSD)),"
                        + "\"day\":\(esc(r.lastDay)),\"start\":\(Int(r.startTS)),\"end\":\(Int(r.endTS)),"
                        + "\"turns\":\(r.turns),\"tools\":\(r.tools)}"
                }.joined(separator: ",")
                let events = g.loopId == apiLoop ? api.events : []
                let apiRuns = events.reversed().map { e -> String in
                    "{\"sid\":\(esc(e.id)),\"source\":\"api\",\"title\":\(esc(e.model)),\"day\":\(esc(e.day)),"
                        + "\"start\":\(Int(e.at)),\"end\":\(Int(e.at)),\"tokens\":\(e.tokens),\"cost\":\(e.cost.map(money) ?? "null")}"
                }.joined(separator: ",")
                if !apiRuns.isEmpty { sessJSON += (sessJSON.isEmpty ? "" : ",") + apiRuns }
                let ambiguous = g.loopId == apiLoop ? api.ambiguousDays : [:]
                let ambiguousJSON = (try? JSONSerialization.data(withJSONObject: ambiguous)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                groupJSON.append("{\"key\":\(esc(g.key)),\"label\":\(esc(g.label)),\"kind\":\(esc(g.kind)),"
                    + "\"loopId\":\(esc(g.loopId)),\"apiCalls\":\(events.count),\"ambiguousDays\":\(ambiguousJSON),\"sessions\":\(g.sessions),\"tokens\":\(g.tokens),"
                    + "\"cost\":\(money(g.cost)),\"first\":\(esc(g.first)),\"last\":\(esc(g.last)),"
                    + "\"projects\":[\(g.projects.sorted().prefix(6).map(esc).joined(separator: ","))],"
                    + "\"days\":{\(dayJSON)},\"runs\":[\(sessJSON)]}")
            }
        }

        // 합계 — 이 맥의 토큰이 루프와 사람 사이에 어떻게 갈리는지 한 줄로.
        var loopTok = 0, humanTok = 0, candTok = 0
        var loopSess = 0, humanSess = 0, candSess = 0
        var loopCost = 0.0, humanCost = 0.0, candCost = 0.0
        for g in groups.values {
            switch g.kind {
            case "loop":      loopTok += g.tokens; loopSess += g.sessions; loopCost += g.cost
            case "candidate": candTok += g.tokens; candSess += g.sessions; candCost += g.cost
            default:          humanTok += g.tokens; humanSess += g.sessions; humanCost += g.cost
            }
        }
        let progJSON = (try? JSONSerialization.data(withJSONObject: prog))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "{\"apiLogUnreadable\":\(api.unreadable),\"progress\":\(progJSON),"
            + "\"totals\":{\"loop\":{\"sessions\":\(loopSess),\"tokens\":\(loopTok),\"cost\":\(money(loopCost))},"
            + "\"candidate\":{\"sessions\":\(candSess),\"tokens\":\(candTok),\"cost\":\(money(candCost))},"
            + "\"human\":{\"sessions\":\(humanSess),\"tokens\":\(humanTok),\"cost\":\(money(humanCost))}},"
            + "\"groups\":[\(groupJSON.joined(separator: ","))]}"
    }
}
