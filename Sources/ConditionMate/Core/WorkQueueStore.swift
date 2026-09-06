import Foundation
import CryptoKit

// 위임 카드 저장소 — lion-work-queue 의 트랙 카드를 읽어 "무엇을 위임했고 무엇이 끝났나"를 답한다.
//
// 이 파일이 있는 이유는 화면이 아니라 신뢰다. 라이언이 /issues 를 켠 뒤에 "이거 진짜 끝났나"를
// 확인하려고 다른 창을 여는 순간 이 화면의 값은 0 이 된다. 그래서 여기서 가장 중요한 규칙은
// 하나뿐이다.
//
//   ★ 완료 판정은 `status:` 값으로 한다. 카드가 어느 폴더에 있는지로 하지 않는다. ★
//
// 근거(2026-09-05 실측): `done/` 안에 `status: classified` 카드가 16 개 있다. 분류만 끝나고 일은
// 시작도 안 된 카드들이다. 폴더로 세면 화면이 16 건을 완료라고 거짓말한다. 폴더는 큐 PM 이
// 레인을 정리하는 자리이지 완료의 정의가 아니다.
//
// 두 번째 규칙: 모르는 상태값은 절대 완료로 흘리지 않는다. 큐의 상태 어휘는 지금도 늘고 있다
// (2026-09-05 에 `창 사라짐 — 결과 미확인` 이 새로 생겼다). 새 값이 조용히 완료로 세어지는 것이
// 이 화면이 망가지는 가장 빠른 길이므로, 표에 없는 값은 `미분류` 라는 다섯째 버킷에 세워 둔다.
// 화면이 "미분류 N" 을 보여 주면 그것이 곧 이 표를 갱신하라는 신호다.
//
// 이 저장소는 읽기 전용이다. 큐 폴더에 한 바이트도 쓰지 않는다 — `## 원문` 훼손으로 카드 하나가
// 폐기된 기록이 QUEUE.md 2026-09-05 14:31 에 있다.
enum WorkQueueStore {

    // MARK: - 어디를 읽는가

    // 큐 폴더의 기본 경로. `IssueFolder` 가 답해 주지 않는 값이라 여기에 자기 상수로 둔다 —
    // IssueFolder 는 "앞으로 이슈 문서가 떨어질 자리"이고 이쪽은 "이미 위임된 카드가 쌓인 자리"라
    // 서로 다른 물건이다. (IssuePaths 는 또 다른 것 — 그쪽은 goal-NN 폴더 155 개의 목표 저장소이고
    // 이 기능과 아무 상관이 없다. 건드리지 않는다.)
    static let defaultRootPath =
        "/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue"

    // 환경변수로 덮어쓸 수 있게 한다. 격리 인스턴스에서 시험할 때 실제 큐를 건드리지 않기 위한 것이다.
    static var root: URL {
        let env = (ProcessInfo.processInfo.environment["CM_WORK_QUEUE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let p = env.isEmpty ? defaultRootPath : (env as NSString).expandingTildeInPath
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    // `organization/...` 로 시작하는 산출물 값이 기준으로 삼는 워크스페이스 루트.
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 상수로 못박지 않고 큐 폴더 경로에서 되짚는다.
    // 큐는 `<lion_work>/organization/lion/lion-work-queue` 에 살므로 `/organization/` 앞이 곧
    // 루트다. 상수로 두면 CM_WORK_QUEUE_DIR 로 격리해 시험할 때 산출물만 실제 디스크를 가리켜
    // 두 원천이 갈린다. `/organization/` 이 없는 경로(임의 격리 폴더)면 그 폴더 자신을 루트로
    // 본다 — 그래야 픽스처 안에서 상대경로가 픽스처 안으로 풀린다.
    static var lionWorkRoot: URL {
        let env = (ProcessInfo.processInfo.environment["CM_LION_WORK_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let p = root.path
        if let r = p.range(of: "/organization/") {
            return URL(fileURLWithPath: String(p[..<r.lowerBound]), isDirectory: true)
        }
        return root
    }

    // MARK: - 버킷

    static let bucketDone = "완료"
    static let bucketRunning = "도는 중"
    static let bucketWaiting = "대기"
    static let bucketBlocked = "막힘"
    static let bucketUnknown = "미분류"

    // 화면에 나오는 순서. 라이언이 가장 먼저 봐야 하는 것이 `막힘` 이라서 `안 됨` 안에서 맨 뒤가
    // 아니라 따로 세어 보인다 — 아무도 안 건드리는데 아무도 모르는 상태이기 때문이다.
    //
    // 2026-09-06 에 `도는 중` 하나가 다섯으로 갈렸다. 카드가 항목당 두 번만 쓰이므로 `도는 중` 은
    // 도는 것의 수가 아니라 아무도 안 닫은 카드의 수였고(그날 12 중 진짜는 4 이하), 그것을
    // 실제 Orca 창의 상태로 가른다. 갈리는 규칙은 `WorkQueueLiveStore` 에 있다.
    //
    // **`도는 중` 이라는 이름은 그대로 둔다.** `IssuesContent.swift:233` 이 `bb['도는 중']` 을
    // 하드코딩해 카드를 그리므로 이름을 바꾸면 그 칸이 0 이 된다. 이름을 유지하면 그 파일을
    // 한 줄도 안 고치고 그 숫자의 뜻만 바뀐다. 늘어나는 네 이름은 필터 칩 줄이
    // `D.bucketOrder` 를 그대로 훑어 그리므로(IssuesContent.swift:267-269) 자동으로 실린다.
    static let bucketOrder = [bucketDone, bucketRunning]
        + WorkQueueLiveStore.liveStates.filter { $0 != WorkQueueLiveStore.stateRunning }
        + [bucketWaiting, bucketBlocked, bucketUnknown]

    // 12 종(실측)의 `status:` 값을 4 개 버킷으로 정규화한다. 표에 없는 값은 미분류다.
    //
    // 표에 없지만 넣어 둔 값들(`completed`, `closed`, `dispatched`, `in-progress`, `cancelled`)은
    // 미래 방어가 아니라 어휘의 사투리 방어다 — 같은 뜻의 영어 단어가 카드마다 갈려 쓰인 전례가
    // 이미 `던짐`/`"던짐"` 과 `cleanup`/`cleanup_level`/`cleanup_floor` 로 두 번 있었다.
    static func bucket(for rawStatus: String) -> String {
        let s = rawStatus.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return bucketUnknown }
        switch s {
        case "done", "닫힘", "folded", "completed", "complete", "closed":
            return bucketDone
        // `launched` 는 2026-09-06 실측에서 미분류로 떨어져 있던 값이다
        // (`2026-09-06-0119-mpc-uxui-seat-cost`). 카드 1 개뿐이고 그 카드를 쓴 자리에 물어보지
        // 않았다 — 단어 뜻으로 던짐 계열이라고 골랐다.
        case "던짐", "running", "submitted", "dispatched", "in-progress", "in progress", "launched":
            return bucketRunning
        // `waiting` 도 같은 실측에서 미분류였다(`2026-09-06-0013-cost-report-ceo-outdated`).
        // 이미 표에 `대기` 와 `pending` 이 있으므로 같은 뜻의 영어 사투리로 본다.
        case "queued", "classified", "split", "pending", "대기", "waiting":
            return bucketWaiting
        case "blocked", "incomplete", "cancelled", "canceled", "막힘":
            return bucketBlocked
        default:
            // ASSUMPTION (L1, 갈래를 스스로 골랐다): `창 사라짐 — 결과 미확인` 은 값 전체를 문자열로
            // 못박지 않고 접두사 `창 사라짐` 으로 잡는다. 그 값은 사람이 그때그때 손으로 적은
            // 문장이라 뒤쪽 설명("결과 미확인")이 카드마다 달라질 것이 거의 확실하고, 전체 일치로
            // 잡으면 다음 변종이 조용히 미분류로 떨어진다. 앞의 `창 사라짐` 은 "세션 창이 없어졌다"
            // 는 사건 자체라 뜻이 바뀌지 않는다. 사람이 봐야 하는 상태이므로 `막힘` 이다.
            if s.hasPrefix("창 사라짐") { return bucketBlocked }
            return bucketUnknown
        }
    }

    // MARK: - 왜 이 버킷인가

    // 2026-09-06 라이언: "막힘 요거는 왜 있는 건지 설명이 들어가면 좋을 것 같은데 … 마우스 오버를
    // 하면은 왜 막힘로 여기는 어떤 걸로 분류가 되는건지".
    //
    // 화면은 이미 `status:` 원문을 배지 옆에 찍고 있다. 모자란 것은 **그 값이 왜 이 버킷인가** 다.
    // 그래서 정규화 표의 근거를 문장으로 같이 낸다 — 표는 여기 하나뿐이므로 설명도 여기서 만든다.
    // 화면에서 만들면 표가 늘 때마다 두 곳이 갈리고, 갈린 설명은 없는 것보다 나쁘다.
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 설명은 두 문장이다 — 이 카드의 값이 무슨 뜻인지,
    // 그리고 같은 버킷에 어떤 값들이 같이 들어오는지. 앞 문장만 두면 "다른 것도 막힘이 되나" 를
    // 못 답하고, 뒤 문장만 두면 이 카드가 왜 여기 있는지를 못 답한다.
    static func bucketWhy(for rawStatus: String) -> String {
        let raw = rawStatus.trimmingCharacters(in: .whitespaces)
        let s = raw.lowercased()
        let b = bucket(for: raw)
        let shown = raw.isEmpty ? "(없음)" : raw

        var lead: String
        switch s {
        case "": lead = "카드에 status: 줄이 아예 없다."
        case "done", "닫힘", "folded", "completed", "complete", "closed":
            lead = "status: \(shown) — 일이 끝났다고 카드에 적혀 있다."
        case "던짐", "running", "submitted", "dispatched", "in-progress", "in progress", "launched":
            lead = "status: \(shown) — 세션에 넘겼고 아직 닫히지 않았다."
        case "queued", "classified", "split", "pending", "대기", "waiting":
            lead = "status: \(shown) — 큐에 올라가 있고 아직 아무도 안 집었다."
        case "blocked", "막힘":
            lead = "status: \(shown) — 진행이 막혔다고 카드에 적혀 있다."
        case "incomplete":
            lead = "status: \(shown) — 시작은 했는데 끝나지 않은 채로 서 있다."
        case "cancelled", "canceled":
            lead = "status: \(shown) — 취소됐다. 되살릴지 버릴지를 사람이 정해야 한다."
        default:
            lead = s.hasPrefix("창 사라짐")
                ? "status: \(shown) — 세션 창이 없어져서 결과를 아무도 확인하지 못했다."
                : "status: \(shown) — 이 값이 정규화 표에 없다."
        }

        var rule: String
        switch b {
        case bucketDone:
            rule = "done · 닫힘 · folded · completed · closed 가 완료다."
        case bucketBlocked:
            rule = "blocked · incomplete · cancelled · 막힘 과 `창 사라짐…` 으로 시작하는 값이 막힘이다. "
                 + "저절로 안 풀리므로 사람이 봐야 움직인다."
        case bucketWaiting:
            rule = "queued · classified · split · pending · waiting · 대기 가 대기다."
        case bucketUnknown:
            rule = "표에 없는 값은 완료로 흘리지 않고 미분류로 세워 둔다 — "
                 + "WorkQueueStore.bucket(for:) 의 표에 이 값을 더해야 사라진다."
        default:
            rule = "던짐 · running · submitted · dispatched · in-progress · launched 가 도는 중이다."
        }
        // `\(b) 로` 로 쓰면 `막힘 로` 가 되어 조사가 틀린다. 앞에 세워서 조사를 피한다.
        return "이 카드가 `\(b)` 인 이유 — \(lead) \(rule)"
    }

    // 버킷 하나의 규칙만. 필터 칩과 요약 카드처럼 카드 한 장이 아니라 무리를 가리키는 자리에 쓴다.
    static func bucketRule(_ b: String) -> String {
        switch b {
        case bucketDone:
            return "완료 — 카드의 status 가 done · 닫힘 · folded · completed · closed 인 것."
        case bucketBlocked:
            return "막힘 — 카드의 status 가 blocked · incomplete · cancelled · 막힘 이거나 "
                 + "`창 사라짐…` 으로 시작하는 것. 저절로 안 풀리므로 사람이 봐야 움직인다."
        case bucketWaiting:
            return "대기 — 카드의 status 가 queued · classified · split · pending · waiting · 대기 인 것."
        case bucketUnknown:
            return "미분류 — 정규화 표에 없는 status 값. 완료로 흘리지 않고 여기 세워 둔다."
        default:
            // 2026-09-06 에 `도는 중` 이 실제 Orca 창의 상태로 다섯으로 갈렸다. 그 어휘는
            // WorkQueueLiveStore 가 소유하므로 여기서 뜻을 다시 정의하지 않고, 어디를 봐야
            // 하는지만 말한다 — 두 곳에 적으면 두 곳이 갈린다.
            if b != bucketRunning && WorkQueueLiveStore.liveStates.contains(b) {
                return "\(b) — status 는 던짐 계열인데, 실제 Orca 창을 보고 `도는 중` 을 다시 가른 값이다. "
                     + "가르는 규칙은 WorkQueueLiveStore 에 있다."
            }
            return "\(b) — 카드의 status 가 던짐 · running · submitted · dispatched · launched 계열인 것."
        }
    }

    // 화면이 마우스 오버 문구로 쓸 규칙 표. 버킷 이름 → 그 버킷의 규칙 한 줄.
    static var bucketRules: [String: String] {
        var out: [String: String] = [:]
        for b in bucketOrder { out[b] = bucketRule(b) }
        return out
    }

    // MARK: - 카드

    struct Card {
        var id: String
        var captured: String          // 원문 그대로
        var capturedKey: String       // 정렬용 YYYYMMDDHHMMSS
        var track: String             // 없으면 "없음" — 16 개 옛 카드가 그렇다. 버리지 않는다.
        var status: String            // 원문 그대로 보존한다. 정규화가 틀렸을 때 라이언이 옆에서 바로 안다.
        var bucket: String
        var target: String
        var cleanup: String           // cleanup / cleanup_level / cleanup_floor 를 하나로 합친 것
        var folder: String            // "inbox" | "done" — 완료 판정에 쓰지 않는다. 표시만 한다.
        var fileName: String
        var filePath: String
        var title: String
        var parsed: Bool              // 프론트매터를 읽었는가. 못 읽어도 카드는 버리지 않는다.
        // 아래 셋은 항목 3 에서 늘었다. 목록 행이 "어디까지 갔나"를 상세를 열지 않고 말하기
        // 위한 것이다. 디스크 확인은 여기서 하지 않는다 — 목록은 85 개를 한 번에 그리므로
        // 카드마다 FileManager 를 때리면 새로고침이 눈에 띄게 느려진다. 존재 확인은 상세에서.
        var artifactCount: Int        // 여섯 키에서 모은 산출물 포인터 개수 (경로가 아닌 값 포함)
        var hasDirective: Bool        // `issue:` 가 있는가
        var stage: String             // 요청만 / 작업지시서까지 / 결과물까지
        var contentHash: String       // 버전 원장이 세는 값. 파일 전체의 SHA-256.
        // `target:` 이 리스트인 카드가 실측 1 개 있다(대상 폴더 둘). 목록 칸에 보이는 `target`
        // 은 항목 1 이 만든 그대로 두고(그쪽은 필터의 키다), 상대경로를 푸는 기준만 따로 낸다 —
        // 이어 붙인 "a b" 를 폴더 이름으로 쓰면 있지도 않은 경로가 만들어진다.
        var targetBase: String
        // 디렉터가 세션을 띄우고 큐 PM 이 적어 넣는 Orca 터미널 핸들. 이것이 카드와 살아 있는
        // 창을 잇는 유일한 끈이다. 실측(2026-09-06): 92 개 중 키가 있는 것 76 개, 값이 실제
        // 핸들 모양인 것 46 개, 그 밖은 빈 값이거나 `직접 고침` 같은 사람 말이다.
        var targetHandle: String

        // 버전 원장의 키. 아래 `versionPairs` 주석에 왜 `id` 가 아닌지 근거가 있다.
        var versionKey: String { fileName }
        // 살아 있는 판정을 붙일 때의 키. 같은 파일 이름이 두 레인에 다 있는 쌍이 4 쌍 있어서
        // 파일 이름만으로는 어느 쪽인지 안 정해진다.
        var laneKey: String { folder + "/" + fileName }

        var dict: [String: Any] {
            ["id": id, "captured": captured, "capturedKey": capturedKey, "capturedUTC": WorkQueueTimestamp.utc(captured) ?? "", "track": track,
             "status": status, "bucket": bucket, "target": target, "cleanup": cleanup,
             "folder": folder, "file": fileName, "path": filePath, "title": title,
             "parsed": parsed, "artifactCount": artifactCount, "hasDirective": hasDirective,
             "stage": stage, "targetBase": targetBase, "targetHandle": targetHandle,
             // `bucket` 은 살아 있는 판정으로 덮어씌워질 수 있다. 카드에 적힌 `status:` 만으로
             // 정해지는 원래 버킷을 같이 실어, 화면이 둘을 대조할 수 있게 한다.
             "paperBucket": bucket,
             // 왜 이 버킷인가. 마우스를 올렸을 때 나오는 문장이고, 표가 여기 하나뿐이라
             // 설명도 여기서 만든다 — 화면에서 만들면 표가 늘 때마다 두 곳이 갈린다.
             "bucketWhy": bucketWhy(for: status)]
        }
    }

    // MARK: - 버전 원장의 키

    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 원장의 키는 `id:` 가 아니라 **파일 이름**이다.
    //
    // 이유는 실측이다. `id:` 가 같은 카드가 두 개씩 있는 쌍이 4 쌍 있다 —
    // `2026-09-04-token-view-timezone-issue` 등이 `inbox/` 와 `done/` 에 같은 이름으로 둘 다
    // 남아 있고 (inbox 쪽은 `status: 던짐`, done 쪽은 `status: done` + 산출물 절) 내용이 다르다.
    // `id:` 로 키를 잡으면 한 번 스캔할 때마다 그 키의 해시가 두 값 사이를 오가며 버전이
    // 끝없이 올라간다. 두 번 띄우면 v1 이어야 하는데 v5 가 되는 것이 그 길이다.
    //
    // 그래서 (1) 키는 파일 이름이고 (2) 같은 이름이 두 레인에 있으면 `done/` 쪽 하나만 관측한다
    // — `done/` 이 나중 상태다. (3) 그리고 그 사실을 숨기지 않고 `laneDuplicate` 로 화면에
    // 올린다. 같은 카드가 두 레인에 남아 있는 것은 큐 PM 이 정리해야 할 진짜 상태이지 화면이
    // 평균 내서 지울 것이 아니다.
    static func versionPairs(_ list: [Card]) -> [(id: String, hash: String)] {
        var chosen: [String: Card] = [:]
        for c in list {
            if let prev = chosen[c.versionKey], prev.folder == "done" { continue }
            chosen[c.versionKey] = c
        }
        return chosen.map { (id: $0.key, hash: $0.value.contentHash) }
            .sorted { $0.id < $1.id }
    }

    // 세 단계. 라이언의 말이 "결과물 없이 작업지서만 나오는 경우도 있겠지" 이므로 없음이
    // 예외가 아니라 단계다. 실측(2026-09-05)으로 85 중 26 만 결과물이 있고 57 은 없다.
    static let stageRequest = "요청만"
    static let stageDirective = "작업지시서까지"
    static let stageArtifact = "결과물까지"

    // MARK: - 읽기

    // 정렬 기본값: captured 내림차순(최신 위). 같으면 파일명으로 안정화한다.
    static func cards() -> [Card] {
        let fm = FileManager.default
        var out: [Card] = []
        for folder in ["inbox", "done"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted() {
                // .md 만 센다. inbox 에 증거 스크린샷 .png 가 섞여 있다.
                guard name.hasSuffix(".md") else { continue }
                let url = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append(card(text: text, url: url, folder: folder))
            }
        }
        return out.sorted {
            $0.capturedKey == $1.capturedKey ? $0.fileName > $1.fileName : $0.capturedKey > $1.capturedKey
        }
    }

    private static func card(text: String, url: URL, folder: String) -> Card {
        let name = url.lastPathComponent
        let slug = String(name.dropLast(3))          // ".md"
        let (front, lists, body, ok) = frontMatter(text)

        let id = pick(front, "id").isEmpty ? slug : pick(front, "id")
        let capturedRaw = pick(front, "captured")
        let status = pick(front, "status")
        // track 이 없는 카드가 16 개(8/25~8/27 의 옛 카드)다. 필터에서 `없음` 을 버리면 그 16 개가
        // 화면에서 사라지므로 값을 만들어 싣는다.
        let track = pick(front, "track").isEmpty ? "없음" : pick(front, "track")
        var cleanup = pick(front, "cleanup")
        if cleanup.isEmpty { cleanup = pick(front, "cleanup_level") }
        if cleanup.isEmpty { cleanup = pick(front, "cleanup_floor") }

        let pointers = artifactPointers(front: front, lists: lists)
        let directives = directivePointers(front: front, lists: lists)
        let stage = !pointers.isEmpty ? stageArtifact
            : (directives.isEmpty ? stageRequest : stageDirective)
        let targetBase = (lists["target"]?.first).map { unquote($0) } ?? pick(front, "target")

        return Card(
            id: id,
            captured: capturedRaw,
            capturedKey: sortKey(capturedRaw, fallbackURL: url),
            track: track,
            status: status,
            // 프론트매터를 못 읽은 카드는 status 가 빈 문자열이라 자동으로 미분류가 된다.
            bucket: bucket(for: status),
            target: pick(front, "target"),
            cleanup: cleanup,
            folder: folder,
            fileName: name,
            filePath: url.path,
            title: title(body: body, slug: slug),
            parsed: ok,
            artifactCount: pointers.count,
            hasDirective: !directives.isEmpty,
            stage: stage,
            contentHash: WorkQueueVersionLedger.hash(text),
            targetBase: targetBase,
            targetHandle: unquote(pick(front, "target_handle")))
    }

    // `issue:` 도 리스트일 수 있다 — `2026-08-25-1919-developer-vs-gtm-owner-essay` 는 대상 폴더가
    // 둘이라 작업지시서도 둘이다. 단일 문자열로만 읽으면 두 경로가 공백으로 이어진 한 덩어리가
    // 되어 둘 다 `경로 없음` 으로 찍힌다 — 실제로는 둘 다 있는데 화면이 거짓말을 하는 것이다.
    static func directivePointers(front: [String: String], lists: [String: [String]]) -> [String] {
        if let items = lists["issue"], !items.isEmpty {
            return items.map { unquote($0) }.filter { !$0.isEmpty }
        }
        let v = unquote(pick(front, "issue"))
        return v.isEmpty ? [] : splitInline(v)
    }

    // MARK: - 프론트매터

    // 첫 줄이 `---` 이고 다음 `---` 까지. 값은 앞뒤 따옴표와 공백을 벗긴다 —
    // `status: 던짐` 과 `status: "던짐"` 이 같은 상태인데 벗기지 않으면 두 줄로 갈려 나온다.
    // 블록 스칼라(`key: |`)와 리스트(`  - x`)를 읽을 수 있어야 한다. 산출물 키(outputs/artifacts)가
    // 그 모양이고, 못 읽으면 그 다음 키들이 통째로 밀려 사라진다.
    //
    // 항목 3 에서 하나 늘었다: 딸린 줄을 공백으로 이어 붙인 문자열 말고 **항목 배열 그대로**도
    // 같이 돌려준다. 산출물 키가 리스트(`  - a` / `  - b`)와 블록 스칼라(`output: |`) 모양으로
    // 들어오는데, 이어 붙인 문자열만 있으면 항목 경계가 지워져 경로 세 개가 공백으로 이어진
    // 한 덩어리가 된다 — 그러면 존재 확인도 폴더 열기도 전부 실패한다.
    private static func frontMatter(_ text: String) -> ([String: String], [String: [String]], String, Bool) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], [:], text, false)
        }
        var map: [String: String] = [:]
        var listMap: [String: [String]] = [:]
        var end = lines.count
        var lastKey = ""
        var continued: [String] = []
        func flush() {
            if !lastKey.isEmpty, !continued.isEmpty {
                if (map[lastKey] ?? "").isEmpty { map[lastKey] = continued.joined(separator: " ") }
                if listMap[lastKey] == nil { listMap[lastKey] = continued }
            }
            continued = []
        }
        var i = 1
        while i < lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespaces) == "---" { end = i + 1; break }
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") || raw.hasPrefix("-") {
                // 앞선 키에 딸린 리스트 항목이거나 블록 스칼라의 본문 줄.
                let t = raw.trimmingCharacters(in: .whitespaces)
                let item = t.hasPrefix("- ") ? String(t.dropFirst(2)) : t
                if !item.isEmpty { continued.append(unquote(item)) }
                i += 1
                continue
            }
            if let c = raw.firstIndex(of: ":") {
                flush()
                let k = String(raw[raw.startIndex..<c]).trimmingCharacters(in: .whitespaces)
                var v = String(raw[raw.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                if v == "|" || v == ">" || v == "|-" || v == ">-" { v = "" }   // 블록 스칼라 머리
                if !k.isEmpty { map[k] = unquote(v); lastKey = k }
            }
            i += 1
        }
        flush()
        let rest = end < lines.count ? lines[end...].joined(separator: "\n") : ""
        return (map, listMap, rest, !map.isEmpty)
    }

    // 앞뒤 따옴표와 공백을 벗긴다. 짝이 안 맞는 따옴표(`target: "` 같은 것이 실제로 있다)도
    // 지운다 — 한쪽만 남은 따옴표는 값이 아니라 오타이기 때문이다.
    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let f = t.first, f == "\"" || f == "'" { t.removeFirst() }
        while let l = t.last, l == "\"" || l == "'" { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func pick(_ m: [String: String], _ k: String) -> String {
        (m[k] ?? "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 제목

    // `## 1초 요약` 의 `요구` 줄이 제목이다. 그 줄이 없는 옛 카드(실측 25 개)는 id 슬러그를 펴서 쓴다.
    // 빈칸으로 두지 않는 것이 이 화면의 규칙이다 — 비어 있으면 라이언이 확인하러 창을 연다.
    private static func title(body: String, slug: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var inSummary = false
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("##") {
                inSummary = t.contains("1초 요약")
                continue
            }
            guard inSummary, t.hasPrefix("요구") else { continue }
            var rest = String(t.dropFirst("요구".count)).trimmingCharacters(in: .whitespaces)
            while let f = rest.first, f == ":" || f == "—" || f == "-" || f == "–" {
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            if !rest.isEmpty { return rest }
        }
        return unslug(slug)
    }

    // `2026-09-05-2228-condition-mate-delegation-issues` → `condition mate delegation issues`.
    // 날짜·시각 접두사를 떼는 이유는 그것이 `captured` 칸에 이미 있어서다 — 같은 값을 한 줄에
    // 두 번 보이면 읽을 것만 늘고 아는 것은 안 는다.
    private static func unslug(_ slug: String) -> String {
        var parts = slug.components(separatedBy: "-")
        // YYYY-MM-DD-HHMM 접두사(4 조각)를 떼되, 그 모양일 때만 뗀다.
        if parts.count > 4, parts[0].count == 4, Int(parts[0]) != nil,
           parts[1].count == 2, Int(parts[1]) != nil,
           parts[2].count == 2, Int(parts[2]) != nil {
            parts.removeFirst(parts[3].count == 4 && Int(parts[3]) != nil ? 4 : 3)
        }
        let s = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? slug : s
    }

    // MARK: - 정렬 키

    // Compare instants in UTC, independently of the user's display timezone.
    private static func sortKey(_ raw: String, fallbackURL: URL) -> String {
        let date = WorkQueueTimestamp.date(raw)
        if date == nil, let key = parseStamp(raw) { return key }
        let modified = (try? FileManager.default.attributesOfItem(atPath: fallbackURL.path)[.modificationDate]) as? Date
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date ?? modified ?? Date(timeIntervalSince1970: 0))
    }

    private static func parseStamp(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        // 앞머리는 언제나 YYYY-MM-DD 다(실측 85/85).
        guard s.count >= 10 else { return nil }
        let head = String(s.prefix(10))
        let d = head.components(separatedBy: "-")
        guard d.count == 3, d[0].count == 4, Int(d[0]) != nil, Int(d[1]) != nil, Int(d[2]) != nil else { return nil }
        var hh = "00", mm = "00", ss = "00"
        var tail = String(s.dropFirst(10))
        if let f = tail.first, f == "T" || f == " " || f == "-" {
            let sep = f
            tail = String(tail.dropFirst())
            if sep == "-" {
                // `2026-08-25-2040` — 붙여 쓴 HHMM.
                let digits = tail.prefix(while: { $0.isNumber })
                if digits.count == 4 {
                    hh = String(digits.prefix(2)); mm = String(digits.suffix(2))
                }
            } else {
                // `20:40` / `20:40:07` (뒤에 오프셋이 붙어 있어도 여기서 끊는다)
                let parts = tail.components(separatedBy: ":")
                if parts.count >= 2 {
                    let h = parts[0].prefix(2), m = parts[1].prefix(2)
                    if h.count == 2, Int(h) != nil, m.count == 2, Int(m) != nil { hh = String(h); mm = String(m) }
                    if parts.count >= 3 {
                        let sec = parts[2].prefix(2)
                        if sec.count == 2, Int(sec) != nil { ss = String(sec) }
                    }
                }
            }
        }
        return d[0] + pad2(d[1]) + pad2(d[2]) + hh + mm + ss
    }

    private static func pad2(_ s: String) -> String { s.count >= 2 ? String(s.prefix(2)) : "0" + s }

    // MARK: - 산출물 포인터

    // 여섯 이름. 이 목록이 이 기능에서 가장 값비싼 한 줄이다.
    //
    // 실측(2026-09-05, 85 개 카드): `artifact:` 9, `artifacts:` 8, `output:` 4, `outputs:` 4,
    // `output_path:` 1, `supporting_artifacts:` 1 — 하나라도 가진 카드가 26 개다.
    // **`output:` 하나만 읽으면 26 건 중 4 건만 보인다.** 라이언이 "완료폴더가 나와야 돼" 라고
    // 한 이유가 매번 물어봐야 해서인데, 22 건이 여전히 안 보이면 요구가 그대로 남는다.
    static let artifactKeys = ["output", "outputs", "artifact", "artifacts",
                              "output_path", "supporting_artifacts"]

    // 원문 그대로의 포인터 값들. (키, 값) 쌍으로 낸다 — 어느 이름으로 적혔는지가 화면에서
    // 근거가 된다(값이 이상할 때 카드의 어느 줄인지 바로 안다).
    static func artifactPointers(front: [String: String], lists: [String: [String]]) -> [(String, String)] {
        var out: [(String, String)] = []
        for k in artifactKeys {
            if let items = lists[k], !items.isEmpty {
                // 리스트와 블록 스칼라. 항목 경계가 이미 잡혀 있으므로 그대로 쓴다.
                for it in items {
                    let v = unquote(it)
                    if !v.isEmpty { out.append((k, v)) }
                }
                continue
            }
            let v = unquote(pick(front, k))
            guard !v.isEmpty else { continue }
            for piece in splitInline(v) { out.append((k, piece)) }
        }
        return out
    }

    // 한 줄에 쉼표로 여러 경로를 적은 카드가 실제로 있다(`output_path:` 1 건, 경로 5 개).
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 쉼표로 자르되 **잘린 조각이 전부 경로 모양일 때만**
    // 자른다. 무조건 자르면 `artifact: GitHub PR 168 (mustcompany-github-manager, stacks/...)`
    // 이 두 동강 나서 화면에 뜻 없는 조각 둘이 뜬다. 그 값은 애초에 경로가 아니므로 한 덩어리
    // 자유문으로 두는 것이 맞다.
    private static func splitInline(_ v: String) -> [String] {
        guard v.contains(",") else { return [v] }
        let parts = v.components(separatedBy: ",").map { unquote($0) }.filter { !$0.isEmpty }
        guard parts.count > 1, parts.allSatisfy({ looksLikePath($0) }) else { return [v] }
        return parts
    }

    // 값에서 뒤에 달린 괄호 주석을 뗀다. `... .pdf (SHA-256 9b4a…)` 처럼 경로 뒤에 해시를 적어
    // 둔 카드가 있다. 떼지 않으면 공백이 섞여 `경로 아님` 으로 떨어져 버튼을 못 얻는다.
    private static func stripTrailingNote(_ v: String) -> String {
        var t = v.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(")"), let open = t.lastIndex(of: "(") else { return t }
        t = String(t[t.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? v.trimmingCharacters(in: .whitespaces) : t
    }

    // 경로 모양인가. 공백이 없고 `/` 나 확장자를 가진 것만 경로로 본다.
    // `SPEC DASH-10 / EP-19` 같은 값이 실제로 `outputs:` 안에 있다 — 그것은 경로가 아니다.
    private static func looksLikePath(_ v: String) -> Bool {
        let t = stripTrailingNote(v)
        guard !t.isEmpty, !t.contains(" "), !t.contains("\t") else { return false }
        return t.contains("/") || t.contains(".")
    }

    // MARK: - 경로 분류

    static let kindAbsolute = "절대경로"
    static let kindWorkspace = "lion_work 상대"
    static let kindTarget = "대상 상대"
    static let kindURL = "URL"
    static let kindNotPath = "경로 아님"
    static let kindNoTarget = "대상 폴더 없음"

    struct Pointer {
        var key: String          // 카드에 적힌 키 이름 (output / artifacts / …)
        var raw: String          // 카드에 적힌 값, 한 글자도 안 고친 것
        var kind: String
        var path: String         // 해석된 절대경로. 못 풀면 ""
        var exists: Bool
        var isDir: Bool
        var openable: Bool       // Finder 로 열 수 있는가 = 해석됐고 디스크에 있다

        var dict: [String: Any] {
            ["key": key, "raw": raw, "kind": kind, "path": path,
             "exists": exists, "isDir": isDir, "openable": openable]
        }
    }

    // 값 하나를 분류하고 풀고 디스크에서 확인한다.
    //
    // 기록된 경로가 디스크에 없는 카드가 실재한다 —
    // `2026-09-05-1753-mpc-agreement-resolve-client-signing` 은 `status: done` 인데 적힌
    // 산출물 셋이 전부 없다. **그것을 숨기지 않는다.** 죽은 버튼을 눌러 아무 일도 안 일어나는
    // 것이 라이언이 창을 여는 이유가 되고, 창을 안 열게 하는 것이 이 화면의 유일한 목적이다.
    static func resolve(key: String, value: String, target: String) -> Pointer {
        let raw = value.trimmingCharacters(in: .whitespaces)
        func made(_ kind: String, _ path: String) -> Pointer {
            guard !path.isEmpty else {
                return Pointer(key: key, raw: raw, kind: kind, path: "",
                               exists: false, isDir: false, openable: false)
            }
            var isDir: ObjCBool = false
            let ex = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return Pointer(key: key, raw: raw, kind: kind, path: path,
                           exists: ex, isDir: isDir.boolValue, openable: ex)
        }

        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return made(kindURL, "")
        }
        let body = stripTrailingNote(raw)
        if body.hasPrefix("/") || body.hasPrefix("~/") {
            let p = (body as NSString).expandingTildeInPath
            return made(kindAbsolute, p.contains("..") ? "" : p)
        }
        guard looksLikePath(body) else { return made(kindNotPath, "") }
        if body.contains("..") { return made(kindNotPath, "") }
        if body.hasPrefix("organization/") {
            return made(kindWorkspace, lionWorkRoot.appendingPathComponent(body).path)
        }
        // 남은 것은 `target:` 폴더 기준 상대경로다. target 이 빈 카드가 실측 30 개라 풀 수 없는
        // 경우를 값으로 만들어 낸다 — 빈칸으로 두면 화면이 고장 난 것처럼 보인다.
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return made(kindNoTarget, "") }
        let base: URL = t.hasPrefix("/") || t.hasPrefix("~/")
            ? URL(fileURLWithPath: (t as NSString).expandingTildeInPath, isDirectory: true)
            : lionWorkRoot.appendingPathComponent(t, isDirectory: true)
        return made(kindTarget, base.appendingPathComponent(body).path)
    }

    // MARK: - 본문 절

    // `## 원문` 을 있는 그대로 떼어 온다. 한 글자도 고치지 않는다 — 원문 훼손으로 카드 하나가
    // 폐기된 기록이 QUEUE.md 2026-09-05 14:31 에 있고, 그 규칙은 화면에도 그대로 적용된다.
    static func section(_ body: String, _ heading: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var out: [String] = []
        var inside = false
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let name = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if inside { break }
                inside = (name == heading)
                continue
            }
            if inside { out.append(raw) }
        }
        // 앞뒤 빈 줄만 턴다. 안쪽 줄바꿈은 원문의 일부라 건드리지 않는다.
        while let f = out.first, f.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        while let l = out.last, l.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // `## 1초 요약` 의 요구/문제/완성 세 줄. 없으면 빈 문자열이다(실측 18 개 옛 카드).
    static func summaryLine(_ body: String, _ label: String) -> String {
        let sec = section(body, "1초 요약")
        guard !sec.isEmpty else { return "" }
        for raw in sec.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(label) else { continue }
            var rest = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            while let f = rest.first, f == ":" || f == "—" || f == "-" || f == "–" {
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            if !rest.isEmpty { return rest }
        }
        return ""
    }

    // MARK: - 살아 있는 판정 덮어쓰기

    // 종이 버킷 `도는 중` 에만 살아 있는 판정을 덮어씌운다. 완료·대기·막힘·미분류는 건드리지
    // 않는다 — 대기 카드에는 애초에 세션이 없고, 닫힌 카드의 창이 없어진 것은 뉴스가 아니다.
    //
    // orca 를 못 부르면 아무것도 덮어씌우지 않고 종이 버킷 그대로 돌아간다. 조용히 전부
    // `도는 중` 으로 두는 것이 이번에 고치는 거짓말이라, 판정을 못 할 때는 판정을 안 한다.
    struct LiveOverlay {
        var snapshot: WorkQueueLiveStore.Snapshot
        var bucketByCard: [String: String]                       // laneKey -> 화면 버킷
        var liveByCard: [String: WorkQueueLiveStore.Live]        // laneKey -> 근거
        var applied: Bool                                        // 덮어씌웠는가
    }

    // 어느 카드를 창에 붙여 물어보는가. **`status` 문자열을 직접 비교하지 않는다.**
    //
    // 2026-09-06 01:35 실측: 카드 95 장에 서로 다른 `status` 값이 14 종 쓰여 있고 한국어와 영어가
    // 섞여 있다. 던짐 계열만 넷으로 흩어져 있다 — `던짐` 9, `submitted` 2, `running` 1,
    // `launched` 1. **`status == "던짐"` 으로 골랐으면 4 장이 통째로 빠진다.** 그래서 고르기는
    // 언제나 `bucket(for:)` 정규화 표를 통과한 뒤에 한다. 지금 표는 14 종을 다 덮는다(미분류 0).
    //
    // 그래도 어휘는 계속 는다. 표에 없는 새 사투리가 내일 생기면 그 카드는 `미분류` 로 떨어지고
    // 조용히 조회 대상에서 빠진다. 그 구멍을 막는 규칙이 두 번째 줄이다 —
    // **핸들이 적혀 있으면 세션이 실제로 떴다는 뜻이므로, 버킷이 미분류라도 창에 물어본다.**
    // 핸들의 유무는 어휘가 아니라 사실이라 표가 늦어도 안 틀린다. 오늘 밤 그런 카드는 0 장이라
    // 비용은 0 이고, 값은 내일 생긴다.
    //
    // 완료·막힘·대기는 일부러 안 붙인다. 실측 근거가 각각 있다.
    //   완료 42 장 중 37 장에 유효 핸들이 있다. 다 물어보면 새로고침마다 프로세스가 37 개 더 뜨는데,
    //   닫힌 카드의 창이 없어진 것은 라이언이 읽을 뉴스가 아니다.
    //   막힘 4 장은 이미 "사람이 봐야 한다" 는 뜻이고 화면이 빨간 칸으로 따로 센다. 덮어쓰면
    //   라이언이 자기 할 일로 읽는 숫자가 줄어든다.
    //   대기 36 장에는 유효 핸들이 **0 장**이다. 좌표가 적히기 전까지 물어볼 창 자체가 없다.
    static func liveTargets(_ list: [Card]) -> [Card] {
        list.filter {
            $0.bucket == bucketRunning
                || ($0.bucket == bucketUnknown && OrcaTerminals.isValidHandle($0.targetHandle))
        }
    }

    static func liveOverlay(_ list: [Card]) -> LiveOverlay {
        let running = liveTargets(list)
        guard !running.isEmpty else {
            return LiveOverlay(snapshot: WorkQueueLiveStore.snapshot(handles: []),
                               bucketByCard: [:], liveByCard: [:], applied: true)
        }
        let handles = running.map { $0.targetHandle }.filter { OrcaTerminals.isValidHandle($0) }
        let snap = WorkQueueLiveStore.snapshot(handles: handles)
        guard snap.orcaAvailable, snap.error.isEmpty else {
            return LiveOverlay(snapshot: snap, bucketByCard: [:], liveByCard: [:], applied: false)
        }

        var buckets: [String: String] = [:]
        var lives: [String: WorkQueueLiveStore.Live] = [:]
        for c in running {
            let h = c.targetHandle
            if h.isEmpty {
                // 던져 놓고 큐 PM 이 좌표를 아직 안 적은 것. 실측 2026-09-06 에 3 건이었고
                // 전부 그날 밤 방금 던진 것이다. 창이 없어진 것과 다른 사건이라 갈라 센다.
                let l = WorkQueueLiveStore.Live(
                    handle: "", state: WorkQueueLiveStore.stateNoHandle,
                    reason: "카드에 target_handle 이 비어 있다. 큐 PM 이 좌표를 아직 안 적었다",
                    lastActivityAt: "", quietSeconds: -1, title: "", worktreePath: "", source: "카드")
                buckets[c.laneKey] = l.state
                lives[c.laneKey] = l
                continue
            }
            if !OrcaTerminals.isValidHandle(h) {
                // `target_handle: 직접 고침` 처럼 사람이 써 넣은 말이 실제로 있다(실측 1 건).
                let l = WorkQueueLiveStore.Live(
                    handle: h, state: WorkQueueLiveStore.stateNoHandle,
                    reason: "target_handle 값이 터미널 핸들 모양이 아니다",
                    lastActivityAt: "", quietSeconds: -1, title: "", worktreePath: "", source: "카드")
                buckets[c.laneKey] = l.state
                lives[c.laneKey] = l
                continue
            }
            if let l = snap.probed[h] {
                buckets[c.laneKey] = l.state
                lives[c.laneKey] = l
            } else {
                let l = WorkQueueLiveStore.Live(
                    handle: h, state: WorkQueueLiveStore.stateChecking,
                    reason: "이번 스냅샷이 이 핸들을 아직 안 봤다. 다음 갱신에서 판정한다",
                    lastActivityAt: "", quietSeconds: -1, title: "", worktreePath: "", source: "카드")
                buckets[c.laneKey] = l.state
                lives[c.laneKey] = l
            }
        }
        return LiveOverlay(snapshot: snap, bucketByCard: buckets, liveByCard: lives, applied: true)
    }

    // MARK: - 피드

    // GET /api/issues. 카운트를 같이 실어 화면이 다시 세지 않게 한다 — 두 곳에서 세면 두 곳이 갈린다.
    static func json() -> String {
        // 세션 지시문 색인을 뒤에서 미리 만든다. 처음 만드는 데 실측 10 초라, 라이언이 카드를
        // 누른 뒤에 만들면 그 클릭이 10 초 멈춘 것처럼 보인다. 목록은 클릭보다 먼저 뜬다.
        DispatchQueue.global(qos: .utility).async { WorkQueueSessionStore.warm() }

        let dir = root
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue

        let list = exists ? cards() : []
        // 살아 있는 판정. `도는 중` 종이 버킷의 카드들만 Orca 창에 붙여 본다.
        let overlay = exists ? liveOverlay(list)
            : LiveOverlay(snapshot: WorkQueueLiveStore.snapshot(handles: []),
                          bucketByCard: [:], liveByCard: [:], applied: false)
        func shown(_ c: Card) -> String { overlay.bucketByCard[c.laneKey] ?? c.bucket }

        var byBucket: [String: Int] = [:]
        for b in bucketOrder { byBucket[b] = 0 }
        var tracks: [String: Int] = [:]
        var targets: [String: Int] = [:]
        for c in list {
            byBucket[shown(c), default: 0] += 1
            tracks[c.track, default: 0] += 1
            let t = c.target.isEmpty ? "없음" : c.target
            targets[t, default: 0] += 1
        }
        let done = byBucket[bucketDone] ?? 0

        // 이슈 문서 폴더는 위임 카드와 다른 물건이라 카운트에 섞지 않고 따로 싣는다.
        // 설정에서 고른 값이 있을 때만 싣는다. 없을 때의 기본값은 "그 세션의 작업 폴더/issue" 라
        // 앱이 대신 지목할 수 없고, 억지로 지목하면 AppPaths 아래 goal 저장소를 가리키게 된다.
        var issueFolder: [String: Any] = ["set": false, "path": "", "exists": false, "count": 0]
        if let ov = IssueFolder.override {
            var d2: ObjCBool = false
            let ex = FileManager.default.fileExists(atPath: ov.path, isDirectory: &d2) && d2.boolValue
            let n = ex ? ((try? FileManager.default.contentsOfDirectory(atPath: ov.path)) ?? [])
                .filter({ $0.hasSuffix(".md") }).count : 0
            issueFolder = ["set": true, "path": ov.path, "exists": ex, "count": n]
        }

        // 버전 원장을 이 스캔으로 갱신한다. 해시가 그대로면 파일을 쓰지 않는다.
        let ledger = WorkQueueVersionLedger.observe(versionPairs(list))

        // 같은 파일 이름이 두 레인에 다 있는 카드. 큐 PM 이 정리해야 할 진짜 상태라 화면에 올린다.
        var lanes: [String: Set<String>] = [:]
        for c in list { lanes[c.versionKey, default: []].insert(c.folder) }

        var cardDicts: [[String: Any]] = []
        for c in list {
            var d = c.dict
            let obs = ledger[c.versionKey] ?? []
            d["version"] = obs.count
            d["versionFirstSeen"] = obs.last?.firstSeen ?? ""
            d["laneDuplicate"] = (lanes[c.versionKey]?.count ?? 1) > 1
            // 화면 버킷은 살아 있는 판정이 이긴다. `paperBucket` 은 카드에 적힌 그대로 남아 있어
            // 둘이 어긋난 자리를 화면이 그대로 보일 수 있다.
            d["bucket"] = shown(c)
            if let l = overlay.liveByCard[c.laneKey] {
                d["live"] = l.dict
                // `bucketWhy` 는 `status:` 값만 보고 종이 버킷을 설명한다. 살아 있는 판정이
                // 버킷을 덮어썼으면 그 설명이 화면의 배지와 어긋나므로, 무엇을 더 봤는지를
                // 이어 붙인다. 앞 문장(카드에 뭐라 적혔나)은 지우지 않는다 — 둘이 갈린 자리가
                // 곧 큐 PM 이 카드를 안 닫았다는 정보다.
                d["bucketWhy"] = bucketWhy(for: c.status)
                    + " 다만 Orca 창을 직접 확인했다 — " + l.reason + "."
            }
            cardDicts.append(d)
        }
        let laneDupes = lanes.values.filter { $0.count > 1 }.count

        let payload: [String: Any] = [
            "ok": true,
            "root": dir.path,
            "rootExists": exists,
            "envOverride": (ProcessInfo.processInfo.environment["CM_WORK_QUEUE_DIR"] ?? "").isEmpty ? false : true,
            "counts": [
                "total": list.count,
                "done": done,
                "notDone": list.count - done,
                "byBucket": byBucket,
            ],
            "bucketOrder": bucketOrder,
            // 왜 이 버킷인가를 화면이 마우스 오버로 말할 수 있게 규칙 표를 같이 싣는다.
            // 화면에서 문장을 만들면 아래 정규화 표가 늘 때 화면만 옛말을 계속한다.
            "bucketRules": bucketRules,
            "tracks": tracks,
            "targets": targets,
            "issueFolder": issueFolder,
            // 결과물이 있는 카드 수. 실측 26/85 — `output:` 하나만 읽었으면 4 가 된다.
            // 화면이 이 수를 그대로 보여서, 여섯 키 파싱이 무너지면 라이언이 바로 안다.
            "withArtifacts": list.filter({ $0.artifactCount > 0 }).count,
            "withDirective": list.filter({ $0.hasDirective }).count,
            // 같은 파일 이름이 inbox/ 와 done/ 에 둘 다 있는 카드 수. 실측 4.
            "laneDuplicates": laneDupes,
            // 살아 있는 판정의 관측 정보. `applied:false` 면 이 화면의 `도는 중` 은 예전 뜻
            // (아무도 안 닫은 카드의 수)이라는 신호다. 그것을 숨기지 않는다.
            "live": {
                var m = overlay.snapshot.dict
                m["applied"] = overlay.applied
                m["quietMinutes"] = Int(WorkQueueLiveStore.quietThreshold / 60)
                m["states"] = WorkQueueLiveStore.liveStates
                return m
            }(),
            "cards": cardDicts,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encode failed\",\"cards\":[]}"
        }
        return text
    }

    // MARK: - 상세 피드

    // GET /api/issues/<id>. 목록과 갈라 둔 이유는 하나다 — 상세는 `## 원문` 전문을 싣기 때문에
    // 목록에 섞으면 85 개 분량의 원문이 매 새로고침마다 흐른다.
    static func detailJSON(id rawID: String) -> String {
        let id = rawID.trimmingCharacters(in: .whitespaces)
        let list = cards()
        // 세 모양을 다 받는다. `<lane>/<slug>` 이 가장 정확하다 — 같은 파일 이름이 두 레인에
        // 다 있는 쌍이 4 쌍 있어서 `id` 나 슬러그만으로는 어느 쪽인지 정해지지 않는다.
        // 모호하면 `done/` 을 고른다(나중 상태).
        let lane = id.components(separatedBy: "/")
        var found: Card?
        if lane.count == 2 {
            found = list.first { $0.folder == lane[0] && $0.fileName == lane[1] + ".md" }
        }
        if found == nil {
            let byID = list.filter { $0.id == id || $0.fileName == id + ".md" }
            found = byID.first { $0.folder == "done" } ?? byID.first
        }
        guard let card = found else {
            return "{\"ok\":false,\"error\":\"unknown-card\",\"id\":\(jsonStr(id))}"
        }
        guard let text = try? String(contentsOf: URL(fileURLWithPath: card.filePath), encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"unreadable\",\"id\":\(jsonStr(id))}"
        }
        let (front, lists, body, _) = frontMatter(text)

        // ── 수정된 최초의 리퀘스트 ────────────────────────────────────────────
        // `## 원문` 을 고친 값일 수 없다. 원문 훼손으로 카드가 폐기된 전례가 있으므로 이 값은
        // 원문 옆에 따로 서야 한다. 떨어지는 순서가 셋이고 셋째를 빈칸으로 두지 않는다 —
        // "정리 안 됨" 은 라이언이 이 카드를 정리해야 한다는 정보이고, 빈칸은 화면이 고장 났다는
        // 신호다. 둘은 다르다.
        let origin = section(body, "원문")
        var cleaned = section(body, "정리된 요청")          // 실측 0 개. 앞으로 큐 PO 가 쓸 자리를 연다.
        var cleanedSource = "정리된 요청"
        if cleaned.isEmpty {
            cleaned = summaryLine(body, "요구")             // 실측 67 개
            cleanedSource = "1초 요약의 요구"
        }
        var cleanedIsRaw = false
        if cleaned.isEmpty {
            // 실측 18 개(전부 8/25~9/03 의 옛 카드). 원문 앞부분을 그대로 보인다.
            cleaned = String(origin.prefix(400))
            cleanedSource = "(정리 안 됨)"
            cleanedIsRaw = true
        }

        // ── 작업지시서 ────────────────────────────────────────────────────────
        // `issue:` 는 산출물과 같은 해석 규칙을 쓴다. 절대경로와 상대경로가 섞여 있다(실측 15 건).
        let directives = directivePointers(front: front, lists: lists)
            .map { resolve(key: "issue", value: $0, target: card.targetBase) }

        // ── 결과물 ────────────────────────────────────────────────────────────
        let pointers = artifactPointers(front: front, lists: lists)
            .map { resolve(key: $0.0, value: $0.1, target: card.targetBase) }

        // ── 버전 ──────────────────────────────────────────────────────────────
        let ledger = WorkQueueVersionLedger.observe(versionPairs(list))
        let versions = WorkQueueVersionLedger.versionsDict(ledger[card.versionKey] ?? [])

        // ── 계보 ──────────────────────────────────────────────────────────────
        // 실측 4 개 카드에만 있다. 수는 적지만 추측이 아니라 진짜 데이터라 있으면 그린다.
        var lineage: [[String: String]] = []
        for (key, label) in [("preceding", "이전 버전"), ("folded_into", "다음 버전"),
                             ("discovered_from", "여기서 나왔다"), ("folded_date", "접힌 날")] {
            let v = unquote(pick(front, key))
            if !v.isEmpty { lineage.append(["key": key, "label": label, "value": v]) }
        }

        // ── 살아 있는 판정 ────────────────────────────────────────────────────
        // 목록과 같은 스냅샷을 쓴다(30 초 캐시). 상세를 열었다고 프로세스를 다시 띄우지 않는다.
        let overlay = liveOverlay(list)
        let live = overlay.liveByCard[card.laneKey]

        // ── 그 일을 실제로 한 세션 ────────────────────────────────────────────
        // 카드에 `issue:` 도 `output:` 도 안 적혀 있는데 일은 된 경우가 실측으로 다수다.
        // 그때 화면이 `없음` 만 쓰면 라이언은 확인하러 다른 창을 연다 — 이 화면이 없애려는
        // 것이 정확히 그 창이다. 그래서 그 카드를 받은 세션 기록에서 지시문·쓴 파일·마지막
        // 보고를 끌어온다. 파일은 만들지 않고 읽기만 한다. 자세한 근거는
        // Core/WorkQueueSessionStore.swift 머리말에 있다.
        var cwds = [card.targetBase.isEmpty ? card.target : card.targetBase]
        if let w = live?.worktreePath, !w.isEmpty { cwds.append(w) }
        let sessionBlock = WorkQueueSessionStore.session(
            cardID: card.id, cardPath: card.filePath, cwds: cwds)

        // ── 이 카드를 **쓴** 실행 (SPEC DASH-14) ──────────────────────────────
        // 위 `session` 이 찾는 것은 카드를 **받은** 세션이다. 섹션 2 `수정된 최초의 리퀘스트` 의
        // 값은 앱이 만든 것이 아니라 카드의 `## 1초 요약` 의 `요구` 줄이므로, "그 수정을 어떤
        // 모델이 얼마나 써서 몇 초에 했나" 는 카드를 **쓴** 실행을 가리킨다. 둘은 다른 기록이라
        // 섞으면 틀린 숫자가 선다 — 근거는 WorkQueueSessionStore 의 DASH-14 절에 있다.
        // 후보를 좁히는 열쇠는 카드 프론트매터의 `captured:` 하나다.
        let revisionBlock = WorkQueueSessionStore.revision(
            cardID: card.id, cardPath: card.filePath, captured: unquote(pick(front, "captured")))

        var d = card.dict
        d["version"] = versions.count
        d["versionFirstSeen"] = (versions.last?["firstSeen"] as? String) ?? ""
        d["laneDuplicate"] = list.filter({ $0.versionKey == card.versionKey }).count > 1
        d["bucket"] = overlay.bucketByCard[card.laneKey] ?? card.bucket
        if let l = live {
            d["live"] = l.dict
            d["bucketWhy"] = bucketWhy(for: card.status)
                + " 다만 Orca 창을 직접 확인했다 — " + l.reason + "."
        }

        let payload: [String: Any] = [
            "ok": true,
            "card": d,
            "live": live?.dict ?? ["state": "", "reason": "이 카드는 살아 있는 판정 대상이 아니다"],
            "cleaned": ["text": cleaned, "source": cleanedSource, "isRawExcerpt": cleanedIsRaw],
            "origin": origin,
            "summary": ["요구": summaryLine(body, "요구"),
                        "문제": summaryLine(body, "문제"),
                        "완성": summaryLine(body, "완성")],
            "directives": directives.map { $0.dict },
            "artifacts": pointers.map { $0.dict },
            "versions": versions,
            "lineage": lineage,
            "stage": card.stage,
            "session": sessionBlock,
            "revision": revisionBlock,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let out = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encode failed\"}"
        }
        return out
    }

    // MARK: - Finder 열기 허용 목록

    // 이번 스캔에서 **카드로부터 실제로 파싱해 낸** 절대경로 전부. 이것 밖의 경로는 열지 않는다.
    //
    // 본보기는 `AppDelegate.revealAgentPath` 의 `knownAgentPaths().contains(p)` 다. 이 저장소는
    // 임의 경로 열기를 한 번도 허용한 적이 없고 — `/api/settings/reveal` 조차 고정 열거값
    // 셋만 받는다 — 웹뷰에서 온 문자열을 그대로 `activateFileViewerSelecting` 에 넘기면
    // 루프백 대시보드가 임의 파일 열람 통로가 된다.
    static func knownRevealPaths() -> Set<String> {
        // 세션 기록에서 파낸 경로도 연다. 그것은 카드에 안 적혀 있어 아래 스캔이 못 만들지만,
        // 상세를 계산할 때 이미 디스크에서 확인한 것이고 출처가 이 앱 자신의 파싱이다.
        // 카드를 훑을 때 세션까지 훑지는 않는다 — 92 개 × 최대 15MB 는 목록을 세운다.
        var out = WorkQueueSessionStore.revealAllowlist()
        let fm = FileManager.default
        for folder in ["inbox", "done"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                guard name.hasSuffix(".md") else { continue }
                let url = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (front, lists, _, _) = frontMatter(text)
                let target = (lists["target"]?.first).map { unquote($0) } ?? pick(front, "target")
                // 카드 파일 자신도 연다 — "이게 어느 카드였지" 가 라이언이 창을 여는 이유 중 하나다.
                out.insert(url.path)
                var values = artifactPointers(front: front, lists: lists)
                values += directivePointers(front: front, lists: lists).map { ("issue", $0) }
                for (k, v) in values {
                    let p = resolve(key: k, value: v, target: target)
                    if !p.path.isEmpty { out.insert(p.path) }
                }
            }
        }
        return out
    }

    // 문자열 하나를 JSON 리터럴로. 이 파일 안에서만 쓰는 최소 구현이라 AppDelegate 의
    // jsonString 을 끌어오지 않는다(Core 가 AppDelegate 에 의존하면 방향이 거꾸로다).
    private static func jsonStr(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        t.removeFirst(); t.removeLast()
        return t
    }
}
