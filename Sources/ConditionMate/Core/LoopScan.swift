import Foundation

// 루프 재구성 — "이 맥에서 실제로 돈 위임 라우트는 무엇인가"를 디스크에서만 세운다.
//
// 루프는 목표에서 결과까지의 이름 붙은 반복 가능한 경로다. 이 맥에서 그 경로는 다섯
// 종류의 부품으로만 만들어지고, 다섯 다 디스크에 흔적을 남긴다:
//   1) 메인 세션 → 서브에이전트 위임   ~/.claude/projects/<slug>/*.jsonl 의 Agent 도구 호출
//      (도구 이름은 Agent 다. Task 가 아니다 — 코퍼스 전량에서 "name":"Task" 는 0건이다. 자세한
//      근거는 아래 parse(_:) 의 주석 참고.)
//   2) 그 위임을 받는 에이전트 정의     전역 / 스킬 하네스 / 프로젝트 (AgentInventory 가 진실)
//   3) 에이전트를 결정적으로 돌리는 하네스  ~/.claude/skills/<skill>/ledger/*.jsonl
//   4) 팀 — 하나의 작업 목록을 나눠 갖는 여러 팀원  ~/.claude/teams/session-*/config.json + ~/.claude/tasks
//   5) 사람 없이 라우트를 시작하는 예약 워커   launchd plist (원본은 소유 저장소에 커밋)
//
// 이 파일은 1번(위임 기록)만 담당한다. 나머지는 각자 자기 자리에서 읽어
// AppDelegate.loopEngineeringJSON() 이 합친다 — OrchestrationFeed 라는 타입은 디스크에 없었다.
//
// 2026-08-23 스캔 범위 확장. 그 전까지 이 스캐너는 세션 폴더를 한 겹만 훑고
// `pathExtension == "jsonl"` 로 걸렀다. 그래서 `<slug>/<sessionId>/subagents/` 아래를 한 번도
// 내려가지 않았고, 문서와 화면은 "서브에이전트의 내부 턴은 한 줄도 남지 않는다"고 적고 있었다.
// 그것은 증거의 부재가 아니라 스캔 범위의 문제였다. 그 폴더에는 위임 한 건마다
//   agent-<id>.jsonl        받은 쪽의 내부 트랜스크립트 (개당 300~450KB)
//   agent-<id>.meta.json    {agentType, description, toolUseId, spawnDepth}
// 두 짝이 들어 있고, `meta.toolUseId` 가 부모 쪽 `Hop.uid`(tool_use 아이디)와 같은 열쇠다.
// 이 조인이 두 가지를 되살린다:
//   (a) 백그라운드(async) 위임의 소요시간. 부모의 결과 줄은 "띄웠다"는 영수증일 뿐이지만,
//       자식 트랜스크립트의 첫 줄과 마지막 줄이 실제 시작과 끝이다.
//   (b) 중첩 위임. 에이전트가 다시 에이전트를 부른 홉은 부모 트랜스크립트에 없고 자식
//       트랜스크립트 안에만 있다. 최상위만 세면 위임 총계가 실제보다 작다.
//
// 왜 grep 하듯 읽는가: 트랜스크립트는 전부 합쳐 수백 MB다. 줄마다 JSON 을 파싱하면 페이지 한 번
// 여는 데 수십 초가 든다. 그래서 (a) 줄에 표식 문자열이 없으면 파싱조차 하지 않고, (b) 파일별
// 결과를 경로+수정시각+크기로 캐시해 두 번째 호출부터는 바뀐 파일만 다시 읽는다.
// 서브에이전트 트랜스크립트도 같은 규율을 그대로 따른다 — 내부 집계(턴 수·도구 호출 수·
// 첫끝 시각)는 JSON 파싱이 아니라 바이트 수준 부분문자열 세기로 뽑는다.
enum LoopScan {

    // 한 번의 위임 = 라우트의 홉 하나.
    struct Hop {
        var uid: String          // tool_use 아이디 — 같은 위임을 두 번 세지 않기 위한 열쇠
        var agent: String        // 위임 대상 에이전트 타입 (subagent_type)
        var desc: String         // 위임 설명 한 줄
        var cwd: String          // 그 위임이 일어난 작업 폴더 — 프로젝트 귀속의 근거
        var branch: String
        var session: String
        var ts: String           // 위임을 건 시각 (ISO8601)
        var kind: String         // done | async | dead | open
        // 홉이 붙든 시간. 확장 전에는 kind == done 일 때만 값이 있었다. 이제 async/open 홉도
        // 자식 트랜스크립트가 조인되면 그쪽 벽시계 시간이 들어온다. 값이 없으면 -1.
        var seconds: Double
        var promptBytes: Int     // 보낸 지시문 길이 — 핸드오프에 실어 보낸 맥락의 무게
        var outBytes: Int        // 돌려받은 결과 길이
        var missing: String      // kind == dead 일 때 "없다"고 응답에 적힌 에이전트 이름
        // --- 여기부터는 서브에이전트 트랜스크립트를 조인해서 채운다 ---
        var depth: Int = 1       // 1 = 최상위 위임, 2 이상 = 에이전트가 다시 부른 중첩 위임
        var joined: Bool = false // 받은 쪽 트랜스크립트를 찾았는가
        var innerTurns: Int = 0  // 받은 쪽 내부 어시스턴트 턴 수
        var innerTools: Int = 0  // 받은 쪽 내부 도구 호출 수
        var innerSeconds: Double = -1   // 받은 쪽 트랜스크립트의 첫 줄 ~ 마지막 줄
        // 시간의 출처. 화면이 "이 숫자를 어디서 얻었는가"를 말할 수 있어야 한다.
        //   parent = 부모의 위임/결과 시각 차이, child = 자식 트랜스크립트의 벽시계, none = 없음
        var timeSource: String = "none"
    }

    // 서브에이전트 트랜스크립트 한 벌 = 위임을 받은 쪽의 기록.
    struct AgentRun {
        var toolUseId: String    // 부모 홉의 uid 와 같은 열쇠
        var agentType: String
        var desc: String
        var spawnDepth: Int
        var seconds: Double      // 첫 줄 ~ 마지막 줄 벽시계
        var turns: Int           // 내부 어시스턴트 턴
        var tools: Int           // 내부 도구 호출
        var sideLines: Int       // isSidechain:true 줄 수
        var path: String
        var startTs: String      // 첫 줄의 시각 — 병목 지수의 창을 자르는 열쇠
    }

    // 내부 기록 전체의 합. 화면 상단이 "에이전트가 실제로 얼마나 돌았나"를 말하는 근거다.
    struct Inner {
        var files = 0
        var sideLines = 0
        var turns = 0
        var tools = 0
        var seconds = 0.0
        var nested = 0           // spawnDepth >= 2 인 위임 수
        var joined = 0           // 부모 홉과 이어붙은 위임 수
    }

    // 사람 병목 지수의 재료.
    //
    // 이 지수는 L1..L9 를 잰 값이 아니다. 단계 이벤트 원장이 없어서 잴 수가 없다. 재는 것은
    // 세션 트랜스크립트 코퍼스이고, 사람 대기는 "대화에서 사람이 다음 말을 하기까지의 공백",
    // 에이전트 가동은 "서브에이전트가 돈 벽시계 시간"이다. 즉 대용치(proxy)다.
    // 정의의 소유자는 docs/loop-definition.md 이고, 아래 세 결정은 그 문서가 정한 것이다.
    //
    //   1) 파일 선택자 = 세션 시작 시각. 파일 수정 시각이 아니다. 수정 시각으로 창을 자르면
    //      8월 이전에 시작된 세션이 8월에 한 번 건드려지기만 해도 창 안으로 들어오고, 7월의
    //      공백이 8월 창의 분자에 실린다. 그렇게 계산된 옛 값(97.0퍼센트)은 폐기됐다.
    //   2) 사람 프롬프트 = type 이 user 이면서 tool_result 를 담지 않고 isMeta 가 아닌 줄.
    //   3) 공백당 4시간 상한. 관측 사실이 아니라 사용자가 정한 정책이다. 잠자는 8시간을 그대로
    //      대기로 세면 지수가 사람의 응답성이 아니라 밤의 길이를 재게 되기 때문이다.
    //      상한 없음과 1시간 상한도 같이 들고 나가 화면이 민감도를 보일 수 있게 한다.
    struct Bottleneck {
        var windowStart = ""     // 코퍼스 창의 시작 (ISO8601)
        var files = 0            // 세션 시작 시각이 창 안인 최상위 트랜스크립트 수
        var turns = 0            // 잰 사람 공백의 수
        var waitCapped = 0.0     // 4시간 상한 합계 (초)
        var waitUncapped = 0.0
        var waitHour = 0.0       // 1시간 상한 합계 (초)
        var agentFiles = 0       // 창 안에서 시작된 서브에이전트 트랜스크립트 수
        var agentSeconds = 0.0   // 그 트랜스크립트들의 벽시계 시간 합계
    }

    // 한 트랜스크립트에서 뽑은 사람 공백. 파일 단위 캐시의 값이다.
    struct FileGaps {
        var startTs = ""
        var inWindow = false
        var turns = 0
        var uncapped = 0.0
        var capped4h = 0.0
        var capped1h = 0.0
    }

    // 코퍼스 창의 시작. docs/loop-definition.md 5-5절이 이 날짜로 권위 있는 값을 기록했다.
    // 여기를 옮기면 그 문서의 숫자와 화면이 갈라진다 — 둘은 반드시 함께 움직여야 한다.
    static let windowStartISO = "2026-08-01T00:00:00Z"
    private static let capFourHours = 14400.0
    private static let capOneHour = 3600.0

    // MARK: - Public

    // 모든 세션 트랜스크립트에서 위임 홉을 뽑는다. 60초 TTL + 파일 단위 캐시.
    static func hops() -> [Hop] { return scan().hops }

    // 서브에이전트 내부 기록의 합. hops() 와 같은 한 번의 훑기에서 나온다.
    static func inner() -> Inner { return scan().inner }

    // 사람 병목 지수의 재료. 역시 같은 한 번의 훑기에서 나온다.
    static func bottleneck() -> Bottleneck { return scan().bottleneck }

    // 홉·내부 집계·병목 재료를 한 번에. 따로 계산하면 같은 파일을 세 번 훑게 된다.
    static func scan() -> (hops: [Hop], inner: Inner, bottleneck: Bottleneck) {
        lock.lock(); defer { lock.unlock() }
        if let c = feedCache, Date().timeIntervalSince(c.at) < feedTTL { return (c.hops, c.inner, c.bottleneck) }

        var out: [Hop] = []
        var runs: [String: AgentRun] = [:]
        var inner = Inner()
        var bn = Bottleneck(windowStart: windowStartISO)
        let fm = FileManager.default

        for dir in AgentInventory.sessionDirs() {
            let entries = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            for e in entries {
                if e.pathExtension == "jsonl" {
                    out.append(contentsOf: cachedHops(of: e))
                    let g = cachedGaps(of: e)
                    if g.inWindow {
                        bn.files += 1
                        bn.turns += g.turns
                        bn.waitCapped += g.capped4h
                        bn.waitUncapped += g.uncapped
                        bn.waitHour += g.capped1h
                    }
                    continue
                }
                // <slug>/<sessionId>/subagents/ — 한 겹 더 내려가는 유일한 자리다. 세션 폴더
                // 아래에 다른 하위 폴더가 생기더라도 subagents 이름만 본다.
                guard (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let sub = e.appendingPathComponent("subagents", isDirectory: true)
                guard fm.fileExists(atPath: sub.path) else { continue }
                let subFiles = (try? fm.contentsOfDirectory(
                    at: sub, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])) ?? []
                for f in subFiles where f.pathExtension == "jsonl" {
                    // 받은 쪽 트랜스크립트도 위임을 걸 수 있다 — 중첩 위임은 여기에만 남는다.
                    var nested = cachedHops(of: f)
                    for i in nested.indices { nested[i].depth = 2 }
                    out.append(contentsOf: nested)
                    if let r = cachedRun(of: f) {
                        runs[r.toolUseId] = r
                        inner.files += 1
                        inner.sideLines += r.sideLines
                        inner.turns += r.turns
                        inner.tools += r.tools
                        if r.seconds > 0 { inner.seconds += r.seconds }
                        if r.spawnDepth >= 2 { inner.nested += 1 }
                        // 분모의 에이전트 가동 몫. 분자(사람 대기)와 같은 창으로 잘라야 한다 —
                        // 창이 다르면 비율이 아니라 두 다른 기간의 비교가 된다.
                        if !r.startTs.isEmpty, r.startTs >= windowStartISO, r.seconds > 0 {
                            bn.agentFiles += 1
                            bn.agentSeconds += r.seconds
                        }
                    }
                }
            }
        }

        // 같은 위임이 여러 파일에 실린다 — 세션을 이어서 열면(resume) 앞선 대화가 새 파일로 복사되기
        // 때문이다. 실측 88건 중 12건이 그 복사본이었다. tool_use 아이디로 한 번만 센다.
        // 복사본 쪽에는 결과 줄이 안 실렸을 수 있으니, 결과를 받은 판본을 우선한다.
        var best: [String: Hop] = [:]
        for h in out {
            if let prev = best[h.uid], prev.kind != "open" || h.kind == "open" { continue }
            best[h.uid] = h
        }

        // 조인. 열쇠는 meta.toolUseId == Hop.uid 다.
        for (uid, run) in runs {
            guard var h = best[uid] else { continue }
            h.joined = true
            h.innerTurns = run.turns
            h.innerTools = run.tools
            h.innerSeconds = run.seconds
            if run.spawnDepth >= 2 { h.depth = max(h.depth, run.spawnDepth) }
            // 부모가 잰 시간이 있으면 그것이 진실이다 — 부모가 실제로 기다린 시간이기 때문이다.
            // 없을 때(백그라운드로 띄웠거나 결과 줄이 안 남았을 때)만 자식의 벽시계로 메운다.
            if h.seconds >= 0 { h.timeSource = "parent" }
            else if run.seconds > 0 { h.seconds = run.seconds; h.timeSource = "child" }
            best[uid] = h
            inner.joined += 1
        }

        var uniq = Array(best.values)
        uniq.sort { $0.ts > $1.ts }
        feedCache = (Date(), uniq, inner, bn)
        return (uniq, inner, bn)
    }

    // MARK: - Cache

    private static let lock = NSLock()
    private static let feedTTL: TimeInterval = 60
    private static var feedCache: (at: Date, hops: [Hop], inner: Inner, bottleneck: Bottleneck)?
    private static var fileCache: [String: (stamp: String, hops: [Hop])] = [:]
    private static var runCache: [String: (stamp: String, run: AgentRun?)] = [:]
    private static var gapCache: [String: (stamp: String, gaps: FileGaps)] = [:]

    private static func cachedHops(of url: URL) -> [Hop] {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(rv?.fileSize ?? 0)"
        if let c = fileCache[url.path], c.stamp == stamp { return c.hops }
        let parsed = parse(url)
        fileCache[url.path] = (stamp, parsed)
        return parsed
    }

    private static func cachedRun(of url: URL) -> AgentRun? {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(rv?.fileSize ?? 0)"
        if let c = runCache[url.path], c.stamp == stamp { return c.run }
        let parsed = parseRun(url)
        runCache[url.path] = (stamp, parsed)
        return parsed
    }

    // MARK: - 받은 쪽 트랜스크립트 (subagents/agent-<id>.jsonl)

    // 서브에이전트 트랜스크립트 한 벌을 집계한다. 여기서 JSON 을 파싱하는 것은 짝이 되는
    // agent-<id>.meta.json(150바이트 남짓) 하나뿐이다. 트랜스크립트 본문은 개당 300~450KB라
    // 줄마다 파싱하면 조회 한 번에 수 초가 든다. 필요한 넷 — 첫끝 시각, 내부 어시스턴트 턴 수,
    // 내부 도구 호출 수, isSidechain 줄 수 — 은 전부 바이트 수준 부분문자열 세기로 나온다.
    // 실측으로 이 셈은 전량 JSON 파싱과 정확히 같은 값을 낸다(턴 5,877 · 도구 3,286 · 18.1시간).
    private static func parseRun(_ url: URL) -> AgentRun? {
        // 짝이 되는 meta 가 없으면 부모 홉과 이을 열쇠(toolUseId)가 없다. 세지 않는다 —
        // 열쇠 없는 기록을 합계에 넣으면 어느 위임의 시간인지 말할 수 없게 된다.
        let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
        guard let mdata = try? Data(contentsOf: meta),
              let mobj = (try? JSONSerialization.jsonObject(with: mdata)) as? [String: Any],
              let toolUseId = mobj["toolUseId"] as? String, !toolUseId.isEmpty else { return nil }

        var turns = 0, tools = 0, side = 0
        var firstTs = "", lastTs = ""
        forEachRawLine(url) { start, len in
            if contains(start, len, markerAssistant) { turns += 1 }
            tools += count(start, len, markerToolUse)
            if contains(start, len, markerSidechain) { side += 1 }
            // 줄마다 timestamp 는 하나다. 문자열 그대로 최소/최대를 잡고 Date 파싱은 파일당
            // 두 번만 한다 — ISO8601 UTC 는 사전순이 곧 시간순이다.
            if let ts = firstStringValue(start, len, markerTimestamp) {
                if firstTs.isEmpty || ts < firstTs { firstTs = ts }
                if ts > lastTs { lastTs = ts }
            }
        }
        let secs = (firstTs.isEmpty || lastTs.isEmpty) ? -1 : elapsed(from: firstTs, to: lastTs)
        return AgentRun(toolUseId: toolUseId,
                        agentType: (mobj["agentType"] as? String) ?? "",
                        desc: String(((mobj["description"] as? String) ?? "").prefix(140)),
                        spawnDepth: (mobj["spawnDepth"] as? Int) ?? 1,
                        seconds: secs, turns: turns, tools: tools, sideLines: side,
                        path: url.path, startTs: firstTs)
    }

    // MARK: - 사람 공백 (최상위 트랜스크립트)

    private static func cachedGaps(of url: URL) -> FileGaps {
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(rv?.fileSize ?? 0)"
        if let c = gapCache[url.path], c.stamp == stamp { return c.gaps }
        let parsed = parseGaps(url)
        gapCache[url.path] = (stamp, parsed)
        return parsed
    }

    // 한 세션 안의 "어시스턴트 마지막 출력 → 다음 사람 프롬프트" 간격을 전부 잰다.
    //
    // 창 밖의 파일은 첫 줄만 읽고 되돌아간다. 813개 중 창 안은 절반 남짓이라, 이 한 줄짜리
    // 판정이 전체 훑기 비용의 절반을 걷어낸다. 판정 기준이 세션 시작 시각인 것 자체가
    // 정의(docs/loop-definition.md 5-5)이고, 이 최적화는 그 정의를 그대로 따른 결과다.
    private static func parseGaps(_ url: URL) -> FileGaps {
        var g = FileGaps()
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return g }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            var offset = 0
            var lastAssist: Date?
            var started = false

            while offset < total {
                let remaining = total - offset
                let start = base + offset
                let nlPtr = memchr(start, 0x0A, remaining)
                let lineLen = nlPtr.map { UnsafeRawPointer($0) - start } ?? remaining
                defer { offset += lineLen + 1 }
                guard lineLen > 0 else { continue }

                if !started {
                    // 첫 시각 = 세션 시작. 창 밖이면 이 파일은 여기서 끝이다. 813개 중 절반
                    // 남짓이 여기서 걸러지고, 그만큼이 통째로 안 읽힌다.
                    guard let ts0 = firstStringValue(start, lineLen, markerTimestamp) else { continue }
                    started = true
                    g.startTs = ts0
                    g.inWindow = ts0 >= windowStartISO
                    if !g.inWindow { return }
                }

                // 시각 추출을 타입 판정 뒤로 미룬다. 대부분의 줄은 어시스턴트도 사람 프롬프트도
                // 아니고(도구 결과·첨부·메타), 그런 줄에서 문자열을 만들면 코퍼스 전체에 걸쳐
                // 수십만 번의 불필요한 할당이 된다. 실측으로 이 한 가지가 첫 조회를 40초에서
                // 한 자리 초로 줄인 가장 큰 몫이다.
                let isAssistant = contains(start, lineLen, markerAssistant)
                if !isAssistant {
                    // 사람 프롬프트만 공백을 닫는다. 도구 결과를 물고 들어오는 user 줄은 에이전트가
                    // 자기 도구에 답한 것이고, isMeta 는 시스템이 끼워 넣은 줄이다. 둘 다 사람이 아니다.
                    guard contains(start, lineLen, markerUserType),
                          !contains(start, lineLen, markerToolResult),
                          !contains(start, lineLen, markerIsMeta) else { continue }
                }
                guard let ts = firstStringValue(start, lineLen, markerTimestamp),
                      let now = date(ts) else { continue }

                if isAssistant { lastAssist = now; continue }
                guard let prev = lastAssist else { continue }
                let gap = now.timeIntervalSince(prev)
                lastAssist = nil
                guard gap >= 0 else { continue }
                g.turns += 1
                g.uncapped += gap
                g.capped4h += min(gap, capFourHours)
                g.capped1h += min(gap, capOneHour)
            }
        }
        return g
    }

    // MARK: - One transcript

    // 트랜스크립트 한 파일에서 위임 도구 호출과 그 결과를 짝지어 홉으로 만든다.
    //
    // 위임 도구의 이름은 `Agent` 다. `Task` 가 아니다 — 이 맥의 코퍼스 전량에서 `"name":"Task"`
    // 는 0건이고 `"name":"Agent"` 는 129건이다. 여러 문서가 "Task 도구 호출을 grep 하라"고
    // 적어 두었고, 그 grep 은 아무것도 돌려주지 않는다. 아무것도 안 나오는 것은 "위임이 한 번도
    // 없었다"와 똑같이 읽힌다. `Task` 분기는 옛 판본 트랜스크립트를 위해 남겨 둔다.
    //
    // 표식이 `"subagent_type"` 이 아니라 도구 이름인 이유: 위임 10건이 `subagent_type` 없이
    // 걸려 있다(런타임이 general-purpose 로 기본값을 잡는 호출이다). 표식을 `subagent_type` 에
    // 걸면 그 10건은 줄 단위에서 아예 걸러져 위임 자체가 없던 것이 된다. 실측으로 이 표식 하나가
    // 최상위 위임 92건을 102건으로, 받은 쪽 트랜스크립트 조인율을 91퍼센트에서 100퍼센트로 바꾼다.
    // 세 표식을 훑는다: 위임을 거는 줄의 도구 이름 둘, 결과 줄의 "tool_use_id".
    private static func parse(_ url: URL) -> [Hop] {
        var uses: [String: Hop] = [:]          // tool_use id → 아직 결과를 못 받은 홉
        var order: [String] = []
        var results: [String: (ts: String, err: Bool, text: String)] = [:]

        forEachLine(url) { line in
            // 여기 도달한 줄은 이미 표식("name":"Agent" / "name":"Task" / tool_use_id)이 걸린
            // 줄이다 — 전체의 극히 일부라, JSON 파싱 비용을 그 몇천 줄에서만 치른다.
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            let ts = (obj["timestamp"] as? String) ?? ""
            for block in content {
                let type = (block["type"] as? String) ?? ""
                if type == "tool_use", let id = block["id"] as? String {
                    let name = (block["name"] as? String) ?? ""
                    guard name == "Agent" || name == "Task",
                          let input = block["input"] as? [String: Any] else { continue }
                    // subagent_type 이 없는 위임은 런타임이 general-purpose 로 잡는다. 이 10건을
                    // 버리면 "이름 없는 파트로 위임했다"가 아니라 "위임이 없었다"가 되어, 받은 쪽
                    // 트랜스크립트가 디스크에 멀쩡히 있는데도 주인 없는 기록으로 남는다.
                    let declared = ((input["subagent_type"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let agent = declared.isEmpty ? "general-purpose" : declared
                    let prompt = (input["prompt"] as? String) ?? ""
                    uses[id] = Hop(uid: id, agent: agent,
                                   desc: String(((input["description"] as? String) ?? "").prefix(140)),
                                   cwd: (obj["cwd"] as? String) ?? "",
                                   branch: (obj["gitBranch"] as? String) ?? "",
                                   session: (obj["sessionId"] as? String) ?? "",
                                   ts: ts, kind: "open", seconds: -1,
                                   promptBytes: prompt.utf8.count, outBytes: 0, missing: "")
                    order.append(id)
                } else if type == "tool_result", let id = block["tool_use_id"] as? String {
                    guard uses[id] != nil else { continue }
                    var text = ""
                    if let s = block["content"] as? String { text = s }
                    else if let arr = block["content"] as? [[String: Any]] {
                        text = arr.compactMap { $0["text"] as? String }.joined()
                    }
                    results[id] = (ts, (block["is_error"] as? Bool) ?? false, text)
                }
            }
        }

        var out: [Hop] = []
        for id in order {
            guard var h = uses[id] else { continue }
            if let r = results[id] {
                h.outBytes = r.text.utf8.count
                if r.err && r.text.contains("not found. Available agents:") {
                    // 존재하지 않는 파트로의 위임 — 런타임 레지스트리가 그 이름을 모른다.
                    // 즉시(1~2초) 실패하고 아무 일도 일어나지 않는다. '이름 있는 파트만' 규칙 위반.
                    h.kind = "dead"
                    h.missing = h.agent
                } else if r.text.hasPrefix("Async agent launched successfully") {
                    // 백그라운드로 띄운 위임 — 결과 줄은 "띄웠다"는 영수증일 뿐 일이 끝난 시각이
                    // 아니다. 이 쌍의 시간차를 홉 소요시간으로 쓰면 몇 분짜리 일이 2초로 둔갑한다.
                    h.kind = "async"
                } else {
                    h.kind = "done"
                    h.seconds = elapsed(from: h.ts, to: r.ts)
                }
            }
            out.append(h)
        }
        return out
    }

    // 위임을 거는 줄의 표식은 도구 이름이다. `"subagent_type"` 이 아니다 — 위 parse() 주석 참조.
    private static let markerAgentTool = Array("\"name\":\"Agent\"".utf8)
    private static let markerTaskTool = Array("\"name\":\"Task\"".utf8)
    private static let markerResult = Array("\"tool_use_id\"".utf8)
    private static let markerAssistant = Array("\"type\":\"assistant\"".utf8)
    private static let markerToolUse = Array("\"type\":\"tool_use\"".utf8)
    private static let markerSidechain = Array("\"isSidechain\":true".utf8)
    private static let markerTimestamp = Array("\"timestamp\":\"".utf8)
    private static let markerUserType = Array("\"type\":\"user\"".utf8)
    private static let markerToolResult = Array("\"tool_result\"".utf8)
    private static let markerIsMeta = Array("\"isMeta\":true".utf8)

    // MARK: - 바이트 수준 보조자
    //
    // 받은 쪽 트랜스크립트 집계 전용. 이 넷은 전부 "줄 안에 이 문자열이 있는가 / 몇 번 있는가"라
    // JSON 파싱 없이 memmem 으로 끝난다. forEachLine 과 달리 표식이 걸린 줄만이 아니라 모든 줄에
    // 콜백이 오지만, 콜백 안에서 하는 일이 memmem 몇 번뿐이라 Data 를 만들지 않는다.

    private static func contains(_ start: UnsafeRawPointer, _ len: Int, _ needle: [UInt8]) -> Bool {
        return needle.withUnsafeBufferPointer { memmem(start, len, $0.baseAddress, $0.count) != nil }
    }

    private static func count(_ start: UnsafeRawPointer, _ len: Int, _ needle: [UInt8]) -> Int {
        return needle.withUnsafeBufferPointer { m -> Int in
            guard let nb = m.baseAddress, m.count > 0 else { return 0 }
            var n = 0, off = 0
            while off < len, let hit = memmem(start + off, len - off, nb, m.count) {
                n += 1
                off = (UnsafeRawPointer(hit) - start) + m.count
            }
            return n
        }
    }

    // `"key":"` 바로 뒤부터 다음 따옴표까지를 문자열로 돌려준다. 없으면 nil.
    private static func firstStringValue(_ start: UnsafeRawPointer, _ len: Int, _ key: [UInt8]) -> String? {
        return key.withUnsafeBufferPointer { m -> String? in
            guard let nb = m.baseAddress,
                  let hit = memmem(start, len, nb, m.count) else { return nil }
            let vStart = (UnsafeRawPointer(hit) - start) + m.count
            guard vStart < len else { return nil }
            guard let endPtr = memchr(start + vStart, 0x22, len - vStart) else { return nil }
            let vLen = UnsafeRawPointer(endPtr) - (start + vStart)
            guard vLen > 0 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: start + vStart, count: vLen), as: UTF8.self)
        }
    }

    // 모든 줄을 (시작 포인터, 길이)로 넘긴다. Data 를 만들지 않는다.
    private static func forEachRawLine(_ url: URL, _ body: (UnsafeRawPointer, Int) -> Void) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let remaining = total - offset
                let start = base + offset
                let nlPtr = memchr(start, 0x0A, remaining)
                let lineLen = nlPtr.map { UnsafeRawPointer($0) - start } ?? remaining
                if lineLen > 0 { body(start, lineLen) }
                offset += lineLen + 1
            }
        }
    }

    // 트랜스크립트 한 파일을 줄 단위로 넘긴다. 가장 큰 파일이 23MB 라 통째로 매핑해도 안전하고,
    // 매핑하면 복사가 한 번도 일어나지 않는다. 줄 찾기와 표식 검사는 memchr/memmem 으로 바이트에서
    // 끝내고, Data 를 만드는 것은 표식이 걸린 줄에서만 한다 — 실측 683MB 를 33초에서 2초 남짓으로
    // 줄인 것이 이 구분이다(Swift String/Data 슬라이스로 훑으면 그 자체가 비용이다).
    private static func forEachLine(_ url: URL, _ body: (Data) -> Void) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let remaining = total - offset
                let start = base + offset
                let nlPtr = memchr(start, 0x0A, remaining)
                let lineLen = nlPtr.map { UnsafeRawPointer($0) - start } ?? remaining
                if lineLen > 0 {
                    let hit = contains(start, lineLen, markerAgentTool)
                        || contains(start, lineLen, markerResult)
                        || contains(start, lineLen, markerTaskTool)
                    if hit { body(Data(bytes: start, count: lineLen)) }
                }
                offset += lineLen + 1
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let fast = fastUTCDate(s) { return fast }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    // `2026-08-23T14:29:32.696Z` 한 가지 모양만 직접 읽는다. 트랜스크립트의 시각은 전부 이 모양이고,
    // 사람 공백을 재려면 이 파서가 코퍼스의 모든 어시스턴트/사람 줄마다 한 번씩 돈다.
    // ISO8601DateFormatter 는 호출당 마이크로초 단위가 들고, 그 자리에서는 그것이 곧 수십 초다.
    // 모양이 조금이라도 다르면 nil 을 돌려주고 위의 정식 파서로 넘긴다 — 빠른 길은 지름길이지
    // 대체가 아니다.
    private static func fastUTCDate(_ s: String) -> Date? {
        let u = Array(s.utf8)
        // 최소 "YYYY-MM-DDTHH:MM:SSZ" = 20바이트, 끝은 Z.
        guard u.count >= 20, u.count <= 30, u.last == 0x5A else { return nil }
        guard u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54,
              u[13] == 0x3A, u[16] == 0x3A else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b {
                let c = Int(u[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19) else { return nil }
        var frac = 0.0
        if u.count > 20 {
            guard u[19] == 0x2E else { return nil }          // 소수점이 아니면 모르는 모양이다
            guard let f = num(20, u.count - 1) else { return nil }
            frac = Double(f) / pow(10.0, Double(u.count - 21))
        } else {
            guard u[19] == 0x5A else { return nil }
        }
        // 그레고리력 → 1970 기준 일수. 시간대는 항상 UTC(Z)라 보정이 없다.
        let days = daysFromCivil(y: y, m: mo, d: d)
        let secs = Double(days) * 86400 + Double(h * 3600 + mi * 60 + se) + frac
        return Date(timeIntervalSince1970: secs)
    }

    // Howard Hinnant 의 days_from_civil. 윤년 규칙을 분기 없이 처리한다.
    private static func daysFromCivil(y: Int, m: Int, d: Int) -> Int {
        let yy = y - (m <= 2 ? 1 : 0)
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400                                  // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146097 + doe - 719468
    }

    private static func elapsed(from: String, to: String) -> Double {
        guard let a = date(from), let b = date(to) else { return -1 }
        let d = b.timeIntervalSince(a)
        return d >= 0 ? d : -1
    }
}
