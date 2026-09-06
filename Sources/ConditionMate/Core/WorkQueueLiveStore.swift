import Foundation

// 위임 카드의 **살아 있는 상태** — 카드가 말하지 못하는 것을 Orca 창에서 직접 본다.
//
// 왜 필요한가. 카드는 항목당 두 번만 쓰인다 — 큐 PM 이 좌표를 적을 때와 닫을 때다. 그 사이
// 목적지 세션이 몇 시간을 일해도 카드는 안 바뀌고, 창이 죽어도 카드는 `던짐` 인 채로 남는다.
// 그래서 화면의 `도는 중` 은 도는 것의 수가 아니라 **아무도 안 닫은 카드의 수**였다.
// 2026-09-06 00:52 에 라이언이 본 것이 그것이고, 그날 12 개 중 진짜로 도는 것은 4 개 이하였다.
//
// 이 파일이 하는 일은 하나다. `도는 중` 종이 버킷 하나를 다섯 상태로 가른다.
//
//   도는 중   창이 있고, 임계 시간 안에 화면이 바뀌었다      ← 라이언이 읽는 숫자
//   멈춰 있음  창은 있는데 화면이 임계 시간 넘게 그대로다
//   창 없음    target_handle 이 살아 있는 목록에 없다
//   좌표 없음  status 는 던짐인데 target_handle 이 비었다
//   확인 중    관측 기록이 하나뿐이라 아직 대조할 것이 없다
//
// `확인 중` 을 값으로 만든 것은 일부러다. 빈칸이나 낙관적 기본값(`도는 중`)으로 두면 이번에
// 고치는 거짓말을 작게 다시 만드는 것이다. 없는 판정은 없다고 쓴다.
//
// 원장은 `AppPaths.sub("work-queue")/terminals.json` 이다 — `WorkQueueVersionLedger` 와 같은
// 폴더, 같은 규칙이다. 깨져 있으면 지우고 새로 시작한다. 편의 데이터이지 정본이 아니고,
// 정본은 언제나 Orca 와 큐 폴더의 카드다. **큐 폴더에는 한 바이트도 쓰지 않는다.**
enum WorkQueueLiveStore {

    // MARK: - 상태 어휘

    // `도는 중` 이라는 이름을 그대로 쓰는 것이 이 설계의 핵심 결정이다. `IssuesContent.swift` 가
    // `bb['도는 중']` 을 하드코딩해 카드를 그리므로(IssuesContent.swift:233), 이름을 바꾸면 그
    // 칸이 0 이 된다. 이름을 유지하면 그 파일을 한 줄도 안 고치고 그 숫자의 **뜻**만 바뀐다.
    static let stateRunning = "도는 중"
    static let stateStalled = "멈춰 있음"
    static let stateNoWindow = "창 없음"
    static let stateNoHandle = "좌표 없음"
    static let stateChecking = "확인 중"

    // 종이 버킷 `도는 중` 이 갈려 나갈 수 있는 이름 전부. `WorkQueueStore.bucketOrder` 가 이것을
    // 그대로 이어 붙여 화면의 필터 칩을 만든다.
    static let liveStates = [stateRunning, stateStalled, stateNoWindow, stateNoHandle, stateChecking]

    // MARK: - 임계 시간

    // 라이언이 본 공백은 100 분이었다. 클로드 세션은 서브에이전트를 기다리는 동안에도 스피너와
    // 토큰 카운터가 계속 다시 그려져 화면이 바뀌므로(2026-09-06 실측: 활동 중인 창은 45 초 안에
    // 화면 해시가 바뀌었다), 10 분 내내 한 픽셀도 안 바뀌었다면 생각 중이 아니라 서 있는 것이다.
    //
    // 권한 프롬프트 앞에 서 있는 창도 화면이 정지하므로 `멈춰 있음` 으로 잡힌다. 그것은 오탐이
    // 아니라 **라이언이 가야 할 창**이라 정확히 맞는 판정이다.
    static var quietThreshold: TimeInterval {
        let env = (ProcessInfo.processInfo.environment["CM_ORCA_QUIET_MINUTES"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        if let m = Double(env), m > 0 { return m * 60 }
        return 10 * 60
    }

    // 스냅샷을 몇 초 동안 재활용하는가. 화면 새로고침마다 프로세스를 1+N 개 띄우지 않기 위한 것이다.
    static var cacheTTL: TimeInterval {
        let env = (ProcessInfo.processInfo.environment["CM_ORCA_CACHE_SECONDS"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        if let s = Double(env), s > 0 { return s }
        return 30
    }

    // 한 번의 갱신에 쓰는 전체 예산. 넘기면 있는 것만 쓴다 — 대시보드 요청이 매달리는 것이
    // 고치려던 것보다 나쁜 고장이다.
    private static let refreshBudget: TimeInterval = 8
    // 동시에 몇 개의 `read` 를 돌리는가. 하나가 0.2 초라 4 면 오늘 밤 7 개가 0.6 초에 끝난다.
    private static let readConcurrency = 4

    // MARK: - 원장

    struct Observation {
        var firstSeen: String       // 이 핸들을 처음 본 시각
        var lastSeenAt: String      // 마지막으로 관측을 시도한 시각
        var screenHash: String      // 마지막으로 읽은 화면의 해시. 화면 자체는 저장하지 않는다.
        // 화면이 바뀐 것을 **앱이 실제로 본** 시각. 기준선을 심기만 한 것은 여기 적지 않는다 —
        // 심은 것을 움직인 것으로 세면 멈춘 창이 임계 시간 동안 `도는 중` 으로 나온다.
        var lastMovedAt: String
        // 지금 들고 있는 `screenHash` 를 처음 기록한 시각. 움직임을 한 번도 못 본 창의 조용한
        // 시간을 여기서부터 센다.
        var baselineAt: String
        var goneSince: String       // 목록에서 처음 사라진 시각. 살아 있으면 빈 문자열.
        var title: String

        var dict: [String: Any] {
            ["firstSeen": firstSeen, "lastSeenAt": lastSeenAt, "screenHash": screenHash,
             "lastMovedAt": lastMovedAt, "baselineAt": baselineAt,
             "goneSince": goneSince, "title": title]
        }
    }

    static var fileURL: URL {
        AppPaths.sub("work-queue").appendingPathComponent("terminals.json")
    }

    private static let ledgerLock = NSLock()

    static func loadLedger() -> [String: Observation] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Observation] = [:]
        for (h, v) in obj {
            guard let r = v as? [String: Any] else { continue }
            out[h] = Observation(
                firstSeen: (r["firstSeen"] as? String) ?? "",
                lastSeenAt: (r["lastSeenAt"] as? String) ?? "",
                screenHash: (r["screenHash"] as? String) ?? "",
                lastMovedAt: (r["lastMovedAt"] as? String) ?? "",
                baselineAt: (r["baselineAt"] as? String) ?? "",
                goneSince: (r["goneSince"] as? String) ?? "",
                title: (r["title"] as? String) ?? "")
        }
        return out
    }

    private static func saveLedger(_ l: [String: Observation]) {
        // 오래된 핸들은 턴다. 위임이 이어지는 한 핸들은 계속 새로 생기므로 안 털면 무한정 큰다.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var obj: [String: Any] = [:]
        for (h, o) in l {
            if let seen = parse(o.lastSeenAt), seen < cutoff { continue }
            obj[h] = o.dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 시각

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // 저장은 UTC 로 한다 (2026-09-06). 앞서는 formatter 의 기본 타임존(= 맥의 로컬)이라
        // 이 맥이 IST 일 때 `+0530`, 한국이면 `+0900` 이 섞여 파일에 남았다. 앞으로 생성되는
        // 것만 UTC 이고 이미 적힌 값은 손대지 않는다 — 포맷에 `Z` 가 있어서 파싱은 적힌
        // 오프셋을 그대로 존중하므로 옛 값도 계속 정확히 읽힌다(마이그레이션 불필요).
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static func stamp(_ d: Date = Date()) -> String { fmt.string(from: d) }
    private static func parse(_ s: String) -> Date? { s.isEmpty ? nil : fmt.date(from: s) }

    // MARK: - 판정 결과

    struct Live {
        var handle: String
        var state: String
        var reason: String          // 왜 그렇게 판정했는지. 화면이 근거를 그대로 보일 수 있게 낸다.
        var lastActivityAt: String  // 앱이 본 마지막 움직임(또는 Orca 가 기록한 마지막 출력)
        var quietSeconds: Int       // 그 시각으로부터 지난 시간. 모르면 -1.
        var title: String
        var worktreePath: String
        var source: String          // "화면 해시" | "Orca lastOutputAt" | "목록" | "카드"

        var dict: [String: Any] {
            ["handle": handle, "state": state, "reason": reason,
             "lastActivityAt": lastActivityAt, "quietSeconds": quietSeconds,
             "title": title, "worktreePath": worktreePath, "source": source]
        }
    }

    struct Snapshot {
        var observedAt: Date
        var orcaAvailable: Bool
        var error: String
        var terminalCount: Int
        var probed: [String: Live]      // 이번에 판정한 핸들들

        var isEmpty: Bool { observedAt == Date(timeIntervalSince1970: 0) }

        var dict: [String: Any] {
            ["observedAt": WorkQueueLiveStore.stamp(observedAt), "orcaAvailable": orcaAvailable,
             "error": error, "terminalCount": terminalCount, "probed": probed.count,
             "ageSeconds": Int(Date().timeIntervalSince(observedAt))]
        }
    }

    private static let cacheLock = NSLock()
    private static var cached = Snapshot(observedAt: Date(timeIntervalSince1970: 0),
                                         orcaAvailable: false, error: "", terminalCount: 0, probed: [:])
    private static var refreshing = false
    private static let refreshQ = DispatchQueue(label: "cm.workqueue.live", qos: .utility)

    // MARK: - 스냅샷

    // 요청한 핸들들에 대한 판정. 캐시가 신선하면 그대로 쓰고, 차가우면(앱 뜬 뒤 첫 호출) 막고
    // 갱신하고, 오래됐으면 있는 것을 즉시 돌려주고 갱신은 뒤에서 돈다.
    //
    // 차가울 때 막는 이유는 하나다. 라이언이 화면을 처음 열었을 때 전부 `확인 중` 이면 이 기능이
    // 없는 것과 같기 때문이다. `IssuesContent` 에는 자동 새로고침이 없어서(실측: setInterval 0 건)
    // 다음 갱신이 언제 올지 앱이 정할 수 없다.
    static func snapshot(handles: [String]) -> Snapshot {
        let wanted = Set(handles.filter { OrcaTerminals.isValidHandle($0) })

        cacheLock.lock()
        let snap = cached
        let busy = refreshing
        cacheLock.unlock()

        let age = Date().timeIntervalSince(snap.observedAt)
        let coversAll = wanted.isSubset(of: Set(snap.probed.keys))
        if !snap.isEmpty && age < cacheTTL && coversAll { return snap }

        if snap.isEmpty {
            // 차갑다. 막고 갱신한다.
            return refresh(handles: wanted)
        }
        // 따뜻하지만 낡았다. 지금 것을 주고 뒤에서 갱신한다.
        if !busy {
            cacheLock.lock(); refreshing = true; cacheLock.unlock()
            refreshQ.async {
                _ = refresh(handles: wanted)
                cacheLock.lock(); refreshing = false; cacheLock.unlock()
            }
        }
        return snap
    }

    // 실제 갱신. `list` 한 번으로 살아 있는 핸들 집합을 얻고, 그 안에 있는 핸들만 `read` 로
    // 화면을 읽는다. 목록에 없는 핸들은 read 를 부르지 않는다 — 죽은 창에 프로세스를 띄우는
    // 것은 값이 없고, 죽음은 이미 목록의 부재로 확정됐다.
    @discardableResult
    static func refresh(handles: Set<String>) -> Snapshot {
        let started = Date()
        let listed = OrcaTerminals.list()
        let now = Date()
        let nowS = stamp(now)

        guard listed.ok else {
            // orca 를 못 부르면 판정을 포기한다. 조용히 전부 `도는 중` 으로 두지 않는다 —
            // 그것이 이번에 고치는 거짓말이다. 사유를 실어 화면이 그대로 말하게 한다.
            let s = Snapshot(observedAt: now, orcaAvailable: OrcaTerminals.available,
                             error: listed.error, terminalCount: 0, probed: [:])
            cacheLock.lock(); cached = s; cacheLock.unlock()
            return s
        }

        let live = listed.byHandle
        ledgerLock.lock()
        var ledger = loadLedger()
        ledgerLock.unlock()

        var probed: [String: Live] = [:]

        // 1. 목록에 없는 핸들 — 창이 사라졌다. 프로세스를 안 띄우고 여기서 끝난다.
        var toRead: [String] = []
        for h in handles.sorted() {
            if let t = live[h] {
                var o = ledger[h] ?? Observation(firstSeen: nowS, lastSeenAt: "", screenHash: "",
                                                 lastMovedAt: "", baselineAt: "",
                                                 goneSince: "", title: t.title)
                o.goneSince = ""
                o.title = t.title.isEmpty ? o.title : t.title
                ledger[h] = o
                toRead.append(h)
            } else {
                var o = ledger[h] ?? Observation(firstSeen: nowS, lastSeenAt: nowS, screenHash: "",
                                                 lastMovedAt: "", baselineAt: "",
                                                 goneSince: nowS, title: "")
                if o.goneSince.isEmpty { o.goneSince = nowS }
                o.lastSeenAt = nowS
                ledger[h] = o
                let goneFor = parse(o.goneSince).map { Int(now.timeIntervalSince($0)) } ?? 0
                probed[h] = Live(handle: h, state: stateNoWindow,
                                 reason: "살아 있는 터미널 \(listed.terminals.count) 개 목록에 이 핸들이 없다",
                                 lastActivityAt: o.lastMovedAt, quietSeconds: goneFor,
                                 title: o.title, worktreePath: "", source: "목록")
            }
        }

        // 2. 살아 있는 핸들만 화면을 읽는다. 동시 4, 전체 예산 안에서.
        var screens: [String: OrcaTerminals.ScreenState] = [:]
        if !toRead.isEmpty {
            let sem = DispatchSemaphore(value: readConcurrency)
            let group = DispatchGroup()
            let lock = NSLock()
            for h in toRead {
                if Date().timeIntervalSince(started) > refreshBudget { break }
                sem.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let r = OrcaTerminals.screenHash(handle: h)
                    lock.lock(); screens[h] = r; lock.unlock()
                    sem.signal(); group.leave()
                }
            }
            _ = group.wait(timeout: .now() + refreshBudget)
        }

        // 3. 판정.
        for h in toRead {
            let t = live[h]
            var o = ledger[h] ?? Observation(firstSeen: nowS, lastSeenAt: "", screenHash: "",
                                             lastMovedAt: "", baselineAt: "",
                                             goneSince: "", title: t?.title ?? "")
            let orcaLast: Date? = t?.lastOutputAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            let prevSeen = parse(o.lastSeenAt)
            // 관측이 임계 시간 넘게 끊겨 있었으면(앱이 꺼져 있었다) 이번 차이를 움직임으로 세지
            // 않는다. 그 사이 언제 움직였는지 알 수 없으므로 다시 심는 것이 정직하다.
            let observationGapped = prevSeen == nil || now.timeIntervalSince(prevSeen!) > quietThreshold

            var state = stateChecking
            var reason = ""
            var source = "화면 해시"

            switch screens[h] {
            case .some(.read(let hash)):
                if o.screenHash.isEmpty || observationGapped {
                    // 첫 관측이거나 관측이 임계 시간 넘게 끊겼다 다시 붙은 것. 대조할 기준이 없다.
                    // **여기서 `lastMovedAt` 을 지금으로 찍지 않는다.** 기준선을 심은 것은 움직임을
                    // 본 것이 아니고, 심은 것을 움직임으로 세면 멈춘 창이 임계 시간 동안
                    // `도는 중` 으로 나온다 — 이번에 고치는 거짓말을 작게 다시 만드는 길이다.
                    o.screenHash = hash
                    o.baselineAt = nowS
                    if let ol = orcaLast {
                        let quiet = now.timeIntervalSince(ol)
                        state = quiet < quietThreshold ? stateRunning : stateStalled
                        reason = "화면 기준선을 새로 심었다. Orca 가 기록한 마지막 출력이 \(mins(quiet)) 전이다"
                        source = "Orca lastOutputAt"
                        o.lastMovedAt = stamp(ol)
                    } else {
                        state = stateChecking
                        reason = "화면 기준선을 방금 심었다. 다음 갱신에서 움직임을 대조한다"
                    }
                } else if hash != o.screenHash {
                    o.screenHash = hash
                    o.baselineAt = nowS
                    o.lastMovedAt = nowS
                    state = stateRunning
                    reason = "지난 관측 이후 화면이 바뀌었다"
                } else {
                    // 화면이 그대로다. Orca 가 더 최근 출력을 기록해 뒀으면 그쪽을 믿는다.
                    var last = parse(o.lastMovedAt)
                    if let ol = orcaLast, last == nil || ol > last! { last = ol; source = "Orca lastOutputAt" }
                    if let l = last {
                        let quiet = now.timeIntervalSince(l)
                        state = quiet < quietThreshold ? stateRunning : stateStalled
                        reason = quiet < quietThreshold
                            ? "화면은 그대로지만 마지막 움직임이 \(mins(quiet)) 전이다"
                            : "화면이 \(mins(quiet)) 넘게 그대로다"
                    } else if let base = parse(o.baselineAt) {
                        // 움직임을 한 번도 못 봤고 Orca 도 기록이 없는 창. 기준선을 심은 뒤로
                        // 얼마나 조용했는지는 셀 수 있으므로 그것으로 판정한다. 임계 시간을
                        // 넘기기 전에는 `도는 중` 이라고 하지 않는다 — 근거가 아직 없다.
                        let quiet = now.timeIntervalSince(base)
                        state = quiet < quietThreshold ? stateChecking : stateStalled
                        reason = quiet < quietThreshold
                            ? "기준선을 심은 뒤 \(mins(quiet)) 동안 화면이 그대로다. 아직 판정하지 않는다"
                            : "관측을 시작한 뒤 \(mins(quiet)) 동안 화면이 한 번도 안 바뀌었다"
                        source = "화면 해시"
                    } else {
                        state = stateChecking
                        reason = "화면은 그대로인데 마지막 움직임 시각을 아직 모른다"
                    }
                }
            case .some(.stale):
                // 목록에는 있었는데 read 가 죽었다고 답했다. 방금 닫힌 것이다.
                o.goneSince = o.goneSince.isEmpty ? nowS : o.goneSince
                state = stateNoWindow
                reason = "목록에는 있었지만 read 가 terminal_handle_stale 로 답했다"
                source = "목록"
            case .some(.failed(let e)):
                state = stateChecking
                reason = "화면을 읽지 못했다: \(e)"
            case .none:
                state = stateChecking
                reason = "이번 갱신의 시간 예산 안에 화면을 못 읽었다"
            }

            o.lastSeenAt = nowS
            if o.firstSeen.isEmpty { o.firstSeen = nowS }
            ledger[h] = o

            let lastAct = parse(o.lastMovedAt)
            probed[h] = Live(handle: h, state: state, reason: reason,
                             lastActivityAt: o.lastMovedAt,
                             quietSeconds: lastAct.map { Int(now.timeIntervalSince($0)) } ?? -1,
                             title: t?.title ?? o.title, worktreePath: t?.worktreePath ?? "",
                             source: source)
        }

        ledgerLock.lock()
        saveLedger(ledger)
        ledgerLock.unlock()

        let s = Snapshot(observedAt: now, orcaAvailable: true, error: "",
                         terminalCount: listed.terminals.count, probed: probed)
        cacheLock.lock(); cached = s; cacheLock.unlock()
        return s
    }

    // MARK: - 사람이 읽는 시간

    private static func mins(_ sec: TimeInterval) -> String {
        let m = Int(sec / 60)
        if m < 1 { return "1분 이내" }
        if m < 60 { return "\(m)분" }
        return "\(m / 60)시간 \(m % 60)분"
    }
}
