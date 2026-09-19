import Foundation
import Integrations

// 위임 카드 AI 검색 — "내가 그때 무슨 일 했더라" 에 답한다.
//
// 2026-09-06 라이언: "검색 기능이 하나 넣어줘 … 링크링 관련된 업무를 했었는데 못 찾겠거든 …
// 기터브 매니저 관련해서 작업을 하던 거를 좀 찾아보고 싶어 … 찾기 기능에다가 하면은 AI가 그
// 내용을 찾아주는 그걸 좀 기대를 하거든."
//
// 그래서 이것은 제목 문자열 매칭이 아니다. 라이언이 말한 두 예가 그대로 그 이유다 —
// 음성 전사에서 `링크링`(링크 정합성)과 `기터브 매니저`(GitHub 매니저)로 나왔고, 카드에는
// 그 글자가 없다. 글자를 맞추면 둘 다 0 건이 나온다. 그래서 카드 **내용**을 모델이 읽는다.
//
//   ★ 이 검색은 비동기다. 대시보드 서버는 직렬 큐(cm.dashboard) 하나로 돈다. ★
//
// 이것이 이 파일의 모양을 통째로 정한다. 모델 호출은 5~20 초가 걸리는데 그것을 요청 핸들러
// 안에서 기다리면 그 시간 동안 대시보드의 **모든 페이지**가 멈춘다. 그래서 POST 는 일감을
// 만들어 즉시 돌아오고, 실제 호출은 이 파일의 자기 큐에서 돈다. 화면은 GET 으로 물어본다.
//
//   ★ 키가 없으면 AI 인 척하지 않는다. ★
//
// 키가 없거나 모델 호출이 실패하면 글자 맞추기로 떨어지되, 결과에 `mode:"local"` 과 왜
// 떨어졌는지를 실어 화면이 그것을 그대로 말하게 한다. 조용히 나쁜 결과를 내는 것이 이
// 기능이 만들 수 있는 가장 비싼 고장이다 — 라이언이 "없다" 를 사실로 믿게 되기 때문이다.
//
// 큐 폴더에는 한 바이트도 쓰지 않는다. 읽기만 한다.
enum IssueSearch {

    // MARK: - 일감

    struct Hit {
        var key: String        // `<레인>/<슬러그>` — 목록 행의 키와 같은 모양이다
        var why: String        // 왜 이것인지 한 줄
    }

    struct Job {
        var q: String
        var state: String      // running | done | error
        var mode: String       // ai | local
        var model: String
        var note: String       // 어떻게 찾았는지 / 왜 AI 가 아니었는지
        var error: String
        var hits: [Hit]
        var scanned: Int
        var startedAt: Date
    }

    private static let lock = NSLock()
    private static var jobs: [String: Job] = [:]
    // 자기 큐에서 돈다. 서버의 직렬 큐를 물지 않기 위한 것이고 이 파일이 존재하는 방식이다.
    private static let worker = DispatchQueue(label: "cm.issue-search", qos: .userInitiated)

    // MARK: - 시작

    // POST /api/issues/search {q}. 일감 id 를 즉시 돌려준다.
    static func start(query raw: String) -> String {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "{\"ok\":false,\"error\":\"empty-query\"}" }
        // 너무 긴 질의는 자른다. 프롬프트 주입이 아니라 실수로 붙여 넣은 문서를 막는 것이다.
        let qq = String(q.prefix(500))

        let id = UUID().uuidString
        lock.lock()
        // 오래된 일감은 버린다. 이 원장은 화면 하나가 방금 물어본 것을 되찾는 자리이지 기록이 아니다.
        let cutoff = Date().addingTimeInterval(-600)
        jobs = jobs.filter { $0.value.startedAt > cutoff }
        jobs[id] = Job(q: qq, state: "running", mode: "", model: "", note: "", error: "",
                       hits: [], scanned: 0, startedAt: Date())
        lock.unlock()

        worker.async { run(id: id, query: qq) }
        return "{\"ok\":true,\"id\":\(jsonStr(id)),\"state\":\"running\"}"
    }

    // GET /api/issues/search?id=... — 아직 도는 중이면 그렇다고 답한다.
    static func poll(id: String) -> String {
        lock.lock()
        let job = jobs[id.trimmingCharacters(in: .whitespaces)]
        lock.unlock()
        guard let j = job else {
            // 앱을 다시 띄웠거나 10 분이 지났다. 화면이 다시 검색하면 되므로 실패로 쓴다.
            return "{\"ok\":false,\"state\":\"gone\",\"error\":\"unknown-job\"}"
        }
        var hits: [[String: Any]] = []
        for h in j.hits { hits.append(["key": h.key, "why": h.why]) }
        let payload: [String: Any] = [
            "ok": j.state != "error", "state": j.state, "q": j.q, "mode": j.mode,
            "model": j.model, "note": j.note, "error": j.error,
            "scanned": j.scanned, "hits": hits,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let t = String(data: d, encoding: .utf8) else {
            return "{\"ok\":false,\"state\":\"error\",\"error\":\"encode\"}"
        }
        return t
    }

    // MARK: - 본체

    private static func finish(_ id: String, _ mutate: (inout Job) -> Void) {
        lock.lock()
        if var j = jobs[id] { mutate(&j); jobs[id] = j }
        lock.unlock()
    }

    private static func run(id: String, query: String) {
        let corpus = docs()
        guard !corpus.isEmpty else {
            finish(id) { j in
                j.state = "done"; j.mode = "local"; j.scanned = 0
                j.note = "큐 폴더에서 읽은 카드가 0 개다. 찾을 것이 아니라 읽을 것이 없다."
            }
            return
        }

        // 키를 고른다. 실측(2026-09-06)으로 이 맥에는 `cm-gemini-api-key` 만 있고
        // `cm-anthropic-api-key` 는 없다. 순서는 앱의 다른 자리와 같게 둔다 —
        // IntegrationCatalog 의 capability 가 `primary: ["gemini-api", "anthropic-api"]` 다.
        var diag: [String] = []
        if let gkey = CMKeychain.value(service: "cm-gemini-api-key"), !gkey.isEmpty {
            let (hitsOpt, why) = askGemini(key: gkey, query: query, corpus: corpus)
            if let hits = hitsOpt {
                // 어느 모델이 실제로 답했는지를 화면에 그대로 쓴다. 혼잡해서 라이트로
                // 내려간 것을 감추면, 결과가 얕을 때 라이언이 그 이유를 알 수 없다.
                let used = why.isEmpty && lastGeminiModel.isEmpty ? geminiModel : lastGeminiModel
                let w = withTimeWindow(query: query, corpus: corpus, hits: hits)
                finish(id) { j in
                    j.state = "done"; j.mode = "ai"; j.model = used.isEmpty ? geminiModel : used
                    j.hits = w.hits; j.scanned = corpus.count
                    j.note = "AI 가 카드 \(corpus.count) 개의 내용을 읽고 골랐다." + w.note
                }
                return
            }
            diag.append("gemini: " + why)
        }
        if let akey = CMKeychain.value(service: "cm-anthropic-api-key"), !akey.isEmpty {
            let (hitsOpt, why) = askAnthropic(key: akey, query: query, corpus: corpus)
            if let hits = hitsOpt {
                let w = withTimeWindow(query: query, corpus: corpus, hits: hits)
                finish(id) { j in
                    j.state = "done"; j.mode = "ai"; j.model = anthropicModel
                    j.hits = w.hits; j.scanned = corpus.count
                    j.note = "AI 가 카드 \(corpus.count) 개의 내용을 읽고 골랐다." + w.note
                }
                return
            }
            diag.append("anthropic: " + why)
        }

        // 떨어진 이유를 화면에 말한다. AI 인 척하지 않는 것이 이 갈래의 전부다.
        let hasKey = (CMKeychain.value(service: "cm-gemini-api-key")?.isEmpty == false)
            || (CMKeychain.value(service: "cm-anthropic-api-key")?.isEmpty == false)
        // 글자 맞추기는 시각을 모른다. 그래서 시각 창을 여기에도 똑같이 씌운다 — AI 가 죽어
        // 있을 때야말로 "4시간 전 것" 이 안 나오면 안 되는 자리다.
        let w = withTimeWindow(query: query, corpus: corpus,
                               hits: localSearch(query: query, corpus: corpus))
        let hits = w.hits
        finish(id) { j in
            j.state = "done"; j.mode = "local"; j.hits = hits; j.scanned = corpus.count
            // 왜 AI 가 아니었는지를 화면이 그대로 말할 수 있게 원인을 붙인다. "AI 가 안 됐다"
            // 만 쓰면 라이언이 키를 봐야 하는지 네트워크를 봐야 하는지 알 수 없다.
            j.error = diag.joined(separator: " · ")
            j.note = (hasKey
                ? "AI 호출이 실패해서 글자 맞추기로 찾았다 (" + j.error + "). 뜻이 같아도 글자가 다르면 안 잡힌다."
                : "AI 키가 없어서 글자 맞추기로 찾았다 (키체인 cm-gemini-api-key). "
                  + "뜻이 같아도 글자가 다르면 안 잡힌다.") + w.note
        }
    }

    // MARK: - 코퍼스

    private struct Doc {
        var key: String
        var when: String
        var title: String
        var bucket: String
        var track: String
        var target: String
        var status: String
        var text: String
        // 카드가 찍힌 시각. `when` 은 모델에게 보여 줄 문자열이고 이것은 우리가 직접 재는 값이다.
        // 둘을 갈라 두는 이유는 "4시간 전" 같은 조건을 모델의 산수에 맡기지 않기 위해서다 —
        // 아래 `timeWindow(...)` 가 이 값으로 직접 창을 자른다.
        var stamp: Date?
    }

    // 카드 한 장이 모델에게 보이는 모습. 발췌를 700 자로 자르는 이유는 비용이 아니라 신호다 —
    // 카드의 앞부분(원문과 1초 요약)에 "무슨 일이었나" 가 들어 있고, 뒤로 갈수록 절차 문구라
    // 카드끼리 서로 닮아진다. 닮은 꼬리를 다 넣으면 관련도가 오히려 흐려진다.
    private static let excerptLimit = 700

    // `## 원문` 이 이보다 짧으면 본문 전체로 떨어진다. 2026-09-06 에 40 에서 올렸다.
    //
    // 40 이었을 때 실제로 벌어진 일이 이 숫자를 정한다. 라이언이 못 찾은 그 카드
    // (`2026-09-05-2024-linkedin-version-scope`)의 `## 원문` 이 **정확히 41 자**였다. 한 글자
    // 차이로 폴백이 안 걸려서, 모델은 그 카드의 트랙 판정도 미결정 갈래도 1초 요약도 못 보고
    // `디렉터 에전트에게 위임해 [1] 자 이제는 링크드인 용으로 하나 만들어줘` 한 줄만 봤다.
    // 카드 109 장 중 가장 얇은 발췌였고, 그래서 주제 추측에서 가장 먼저 밀렸다.
    //
    // 임계값이 낮으면 얇은 카드가 조용히 얇은 채로 남는다. 원문이 두세 줄인 카드는 그 자체로는
    // 신호가 거의 없고, 신호는 그 아래 `1초 요약` 에 들어 있다. 그러니 짧을수록 본문을 붙여야 한다.
    private static let thinOriginLimit = 200

    // 나중 발화의 몫. 본문과 따로 잡아 둔다 — 위 `docs()` 의 별표 주석이 그 이유다.
    private static let laterLimit = 600

    private static func docs() -> [Doc] {
        var out: [Doc] = []
        for c in WorkQueueStore.cards() {
            let raw = (try? String(contentsOf: URL(fileURLWithPath: c.filePath), encoding: .utf8)) ?? ""
            let body = stripFrontMatter(raw)
            // `## 원문` 이 라이언이 실제로 말한 것이라 가장 잘 찾힌다. 없는 옛 카드는 본문 전체를 쓴다.
            var t = WorkQueueStore.section(body, "원문")
            if t.count < thinOriginLimit { t = body }
            // 카드가 던져진 뒤 목적지 창에서 라이언이 **더 말한 것**. 카드 파일에는 없고
            // 그 세션의 트랜스크립트에만 있다. 이것을 안 붙이면 요구가 자란 카드를 자란
            // 뒤의 말로는 영영 못 찾는다 — 그것이 2026-09-06 에 라이언이 못 찾은 이유다.
            //
            //   ★ 카드 본문과 **따로** 줄인다. 이어 붙인 뒤에 한 번 줄이면 안 된다. ★
            //
            // 처음에 그렇게 썼다가 실측에서 걸렸다. 본문이 이미 700 자를 넘는 카드에서는
            // 이어 붙인 나중 발화가 통째로 잘려 나가 하나도 안 들어갔고, 그래서 그 말로
            // 찾으면 0 건이 나왔다. 두 개는 서로 다른 시점의 요구이므로 각자 자리를 갖는다.
            var excerpt = squeeze(t, limit: excerptLimit)
            let later = CardLaterRequests.text(cardID: c.id, target: c.target)
            if !later.isEmpty {
                excerpt += " / 이후 추가 요청: " + squeeze(later, limit: laterLimit)
            }
            let key = c.folder + "/" + (c.fileName.hasSuffix(".md")
                                        ? String(c.fileName.dropLast(3)) : c.fileName)
            out.append(Doc(key: key,
                           // 앞 8 자만 남기면 `20260905` 가 되어 시:분이 통째로 사라진다. 그러면
                           // "4시간 전에 작성한" 은 모델이 원리적으로 만족시킬 수 없는 조건이 된다.
                           // 2026-09-06 에 라이언의 질의가 실제로 그렇게 빗나갔다.
                           when: readableStamp(c.capturedKey),
                           title: c.title,
                           bucket: c.bucket,
                           track: c.track,
                           target: c.target,
                           status: c.status,
                           text: excerpt,
                           stamp: date(fromKey: c.capturedKey)))
        }
        return out
    }

    // `yyyyMMddHHmmss` → `YYYY-MM-DD HH:MM`. WorkQueueStore.sortKey() 가 만드는 14 자가 입력이다.
    private static func readableStamp(_ key: String) -> String {
        let k = key.filter { $0.isNumber }
        guard k.count >= 12 else { return String(k.prefix(8)) }
        let c = Array(k)
        return "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8])) "
             + "\(String(c[8..<10])):\(String(c[10..<12]))"
    }

    private static func date(fromKey key: String) -> Date? {
        let k = key.filter { $0.isNumber }
        guard k.count >= 14 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone.current
        return f.date(from: String(k.prefix(14)))
    }

    // 프론트매터를 떼어 낸다. WorkQueueStore 의 파서는 private 이고, 여기서 필요한 것은 키·값이
    // 아니라 "본문이 어디서 시작하나" 하나뿐이라 그 파서를 열지 않고 여기서 두 줄로 끝낸다.
    private static func stripFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        var i = 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                return lines[(i + 1)...].joined(separator: "\n")
            }
            i += 1
        }
        return text
    }

    private static func squeeze(_ s: String, limit: Int) -> String {
        var out = ""
        var lastSpace = false
        for ch in s {
            if ch == "\n" || ch == "\r" || ch == "\t" || ch == " " {
                if !lastSpace { out.append(" "); lastSpace = true }
            } else {
                out.append(ch); lastSpace = false
            }
            if out.count >= limit { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 프롬프트

    private static let maxHits = 12

    private static func prompt(query: String, corpus: [Doc]) -> String {
        var lines: [String] = []
        for d in corpus {
            lines.append("key=\(d.key) | \(d.when) | \(d.bucket)/\(d.status) | \(d.track) | "
                         + "대상=\(d.target.isEmpty ? "없음" : d.target) | 제목=\(d.title) | 내용=\(d.text)")
        }
        // 지금 시각을 싣는다. 이것이 없으면 "4시간 전", "어제", "아까" 같은 조건은 기준점이
        // 없어서 모델이 만족시킬 수 없다. 2026-09-06 에 라이언의 질의
        // `링크드인 컨텐츠를 4시간 전에 작성한 게 있거든 찾아줄래요?` 가 정확히 그렇게 빗나갔다 —
        // 모델은 그 구절을 버리고 남은 낱말로 주제 추측을 했고 9 건 안에 그 카드가 없었다.
        let nf = DateFormatter()
        nf.dateFormat = "yyyy-MM-dd HH:mm"
        nf.timeZone = TimeZone.current
        let now = nf.string(from: Date())

        return """
        너는 라이언의 위임 카드 목록에서 "내가 그때 무슨 일을 했더라" 를 찾아 주는 검색기다.

        지금 시각: \(now)

        아래는 카드 \(corpus.count) 개다. 한 줄이 카드 하나이고 `key=... | 날짜 | 버킷/status | 트랙 | 대상 | 제목 | 내용` 이다.
        `날짜` 는 그 카드가 찍힌 시각이고 `YYYY-MM-DD HH:MM` 이다.

        ── 카드 ──
        \(lines.joined(separator: "\n"))
        ── 끝 ──

        질문: \(query)

        규칙:
        - 제목의 글자가 겹치는지가 아니라 **내용이 그 일인지**로 골라라.
        - 표기가 달라도 같은 것이면 고른다. 질문은 음성 받아쓰기라 오타가 많다
          (예: 기터브=GitHub, 링크링=링크 정합성, 어카이브=아카이브, 위사결정=의사결정).
        - **시각 표현은 위의 `지금 시각` 을 기준으로 풀어라.** `4시간 전`, `어제`, `아까`,
          `오늘 새벽` 같은 말은 카드의 `날짜` 와 맞춰 본다. 날짜가 맞는 카드는 주제가 조금 덜
          비슷해도 올린다 — 라이언은 언제 한 일인지를 기억하고 찾는 경우가 많다.
        - `내용` 에 `이후 추가 요청:` 이 있으면 그것은 카드가 만들어진 **뒤에** 라이언이 그 일의
          창에서 더 말한 것이다. 처음 요청보다 이쪽이 지금의 요구에 가까울 때가 많으니 같이 읽어라.
        - 관련도가 높은 순으로 최대 \(maxHits) 개.
        - 관련 있는 것이 하나도 없으면 빈 배열을 낸다. 억지로 채우지 마라.
        - key 는 위 목록에 있는 문자열을 **한 글자도 바꾸지 말고** 그대로 적어라.

        JSON 하나만 출력한다. 설명도 코드펜스도 붙이지 마라.
        {"hits":[{"key":"<key 그대로>","why":"<왜 이것인지 한국어 한 줄, 30자 이내>"}]}
        """
    }

    // 모델이 준 문자열에서 hits 를 꺼낸다. 코드펜스를 붙여 오는 경우가 있어 첫 `{` 부터
    // 마지막 `}` 까지만 잘라 파싱한다. 목록에 없는 key 는 버린다 — 모델이 지어낸 카드를
    // 화면에 세우면 그 순간 이 화면이 답하기로 한 질문(무엇이 실제로 있었나)을 배신한다.
    private static func parseHits(_ text: String, corpus: [Doc]) -> [Hit]? {
        guard let lo = text.firstIndex(of: "{"), let hi = text.lastIndex(of: "}"), lo < hi else { return nil }
        let slice = String(text[lo...hi])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["hits"] as? [[String: Any]] else { return nil }
        let known = Set(corpus.map { $0.key })
        var out: [Hit] = []
        var seen = Set<String>()
        for h in arr {
            let k = ((h["key"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard known.contains(k), !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(Hit(key: k, why: squeeze((h["why"] as? String) ?? "", limit: 120)))
            if out.count >= maxHits { break }
        }
        return out
    }

    // MARK: - 모델 호출

    // `-latest` 별칭을 쓴다. 고정 버전 이름은 구글이 키별로 모델을 돌리면서 404 가 되는 일이
    // 있고, 그 사실이 이미 slack-eyes-daemon.mjs:1333 에 실측으로 적혀 있다.
    private static let geminiModel = "gemini-flash-latest"
    // 혼잡할 때 내려가는 자리. 실측(2026-09-06)으로 `gemini-flash-latest` 가 같은 분에 세 번
    // 연속 503 "high demand" 를 냈다. 라이트는 슬랙 번역이 매일 쓰는 모델이라 여유가 다르고,
    // 이 일(카드 발췌를 읽고 관련된 것을 고르기)에는 라이트로도 충분하다.
    private static let geminiFallbackModel = "gemini-flash-lite-latest"
    private static let anthropicModel = "claude-haiku-4-5"

    // 큰 모델이 혼잡하면 라이트로 한 번 더. 여기서 안 내려가면 그 순간의 혼잡이 그대로
    // "AI 가 안 된다" 로 보이고, 라이언은 글자 맞추기 결과를 사실로 읽게 된다.
    private static func askGemini(key: String, query: String, corpus: [Doc]) -> ([Hit]?, String) {
        let (hits, why) = askGeminiOnce(model: geminiModel, key: key, query: query, corpus: corpus)
        if hits != nil { return (hits, why) }
        guard why.hasPrefix("HTTP 429") || why.hasPrefix("HTTP 503") else { return (nil, why) }
        let (h2, w2) = askGeminiOnce(model: geminiFallbackModel, key: key, query: query, corpus: corpus)
        if h2 != nil { return (h2, "") }
        return (nil, why + " → " + geminiFallbackModel + ": " + w2)
    }

    private static func askGeminiOnce(model: String, key: String, query: String, corpus: [Doc])
        -> ([Hit]?, String) {
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt(query: query, corpus: corpus)]]]],
            // temperature 0 — 같은 질문에 같은 답이 나와야 한다. 검색 결과가 부를 때마다
            // 달라지면 라이언이 "아까는 나왔는데" 를 확인하러 창을 연다.
            "generationConfig": ["temperature": 0, "responseMimeType": "application/json"],
        ]
        guard let (code, obj) = postJSON(
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent",
                headers: ["x-goog-api-key": key], body: body) else { return (nil, "응답 없음(시간 초과·네트워크)") }
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? ""
            return (nil, "HTTP \(code)" + (msg.isEmpty ? "" : " " + String(msg.prefix(120))))
        }
        guard let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let fin = (obj["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
            return (nil, "본문 없음" + (fin.map { " (finishReason \($0))" } ?? ""))
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard let hits = parseHits(text, corpus: corpus) else { return (nil, "JSON 파싱 실패") }
        lastGeminiModel = model
        return (hits, "")
    }

    // 마지막으로 실제로 답한 제미나이 모델. 화면이 "무엇이 답했나" 를 말하기 위한 것뿐이다.
    private static var lastGeminiModel = ""

    private static func askAnthropic(key: String, query: String, corpus: [Doc]) -> ([Hit]?, String) {
        let body: [String: Any] = [
            "model": anthropicModel,
            "max_tokens": 1200,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt(query: query, corpus: corpus)]],
        ]
        guard let (code, obj) = postJSON("https://api.anthropic.com/v1/messages",
                                         headers: ["x-api-key": key,
                                                   "anthropic-version": "2023-06-01"],
                                         body: body) else { return (nil, "응답 없음(시간 초과·네트워크)") }
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? ""
            return (nil, "HTTP \(code)" + (msg.isEmpty ? "" : " " + String(msg.prefix(120))))
        }
        guard let content = obj["content"] as? [[String: Any]] else { return (nil, "본문 없음") }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard let hits = parseHits(text, corpus: corpus) else { return (nil, "JSON 파싱 실패") }
        return (hits, "")
    }

    // 동기 POST. 이 파일의 자기 큐에서만 불리므로 서버의 직렬 큐를 물지 않는다.
    // 45 초에서 끊는다 — 카드 90 여 장을 읽는 호출이라 8 초(IntegrationChecks 의 값)로는 모자란다.
    //
    // 429·503 은 한 번 다시 건다. 실측(2026-09-06)으로 같은 질의가 처음엔 503 "high demand" 로
    // 떨어지고 몇 초 뒤엔 그대로 됐다. 여기서 안 다시 걸면 그 순간의 혼잡이 곧바로 "AI 가 안
    // 된다" 로 라이언에게 보이고, 라이언은 글자 맞추기 결과를 사실로 읽게 된다. 두 번까지다 —
    // 그 이상 붙잡으면 화면이 답을 못 받는 시간만 길어진다.
    private static func postJSON(_ urlText: String, headers: [String: String], body: [String: Any])
        -> (Int, [String: Any])? {
        let first = postOnce(urlText, headers: headers, body: body)
        guard let f = first, f.0 == 429 || f.0 == 503 else { return first }
        Thread.sleep(forTimeInterval: 3)
        return postOnce(urlText, headers: headers, body: body) ?? first
    }

    private static func postOnce(_ urlText: String, headers: [String: String], body: [String: Any])
        -> (Int, [String: Any])? {
        guard let u = URL(string: urlText),
              let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = payload

        var code = 0
        var obj: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse { code = http.statusCode }
            if let data { obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 50)
        guard let o = obj else { return nil }
        return (code, o)
    }

    // MARK: - 시각 조건은 모델에게 안 맡긴다

    // 라이언이 `[2]` 에서 못박은 것이 이것이다. "내가 원하는 결과는 4시간 저거 했을 때 여기 나와야 해."
    //
    // 프롬프트에 지금 시각을 실었으니 모델도 이제 풀 수 있다. 그런데 그것만으로는 이 요구가
    // 지켜지지 않는다. 모델은 순위를 매기는 것이지 조건을 만족시키겠다고 약속한 것이 아니고,
    // 무엇보다 **모델이 없을 때가 있다.** 2026-09-06 이 그날이었다 — gemini 키가 쿼터 초과
    // (`HTTP 429`) 라 이 검색은 통째로 글자 맞추기로 떨어져 있었고, 글자 맞추기는 시각을 아예 모른다.
    //
    // 그래서 시각 조건만은 우리가 직접 잰다. 질의에서 시각 표현을 읽어 창을 자르고, 그 창에
    // 들어오는 카드는 모델이 뭐라 했든 결과에 세운다. 모델이 살아 있으면 순위를 보태고,
    // 죽어 있으면 이것만으로도 라이언이 찾던 것이 나온다.
    private static let pinLimit = 5

    private struct Window { var lo: Date; var hi: Date; var center: Date; var label: String }

    private static func timeWindow(_ query: String) -> Window? {
        let q = query.replacingOccurrences(of: " ", with: "")
        let cal = Calendar.current
        let now = Date()

        // `N시간 전`. 구술이라 "4시간전에", "네시간 전" 처럼 들어온다. 숫자만 받는다 —
        // 한글 수사까지 받으려다 오탐을 만드느니 안 잡히는 편이 낫다.
        if let n = number(before: "시간", in: q) {
            let center = now.addingTimeInterval(-Double(n) * 3600)
            // ±2 시간. 사람이 "4시간 전" 이라고 할 때 그것은 4.0 이 아니라 "그 무렵" 이다.
            return Window(lo: center.addingTimeInterval(-7200),
                          hi: center.addingTimeInterval(7200),
                          center: center, label: "\(n)시간 전 무렵")
        }
        if let n = number(before: "분", in: q) {
            let center = now.addingTimeInterval(-Double(n) * 60)
            return Window(lo: center.addingTimeInterval(-1800),
                          hi: center.addingTimeInterval(1800),
                          center: center, label: "\(n)분 전 무렵")
        }
        if let n = number(before: "일", in: q), n >= 1, n <= 60 {
            guard let d = cal.date(byAdding: .day, value: -n, to: now) else { return nil }
            let lo = cal.startOfDay(for: d)
            return Window(lo: lo, hi: lo.addingTimeInterval(86400),
                          center: lo.addingTimeInterval(43200), label: "\(n)일 전")
        }
        if q.contains("어제") {
            guard let d = cal.date(byAdding: .day, value: -1, to: now) else { return nil }
            let lo = cal.startOfDay(for: d)
            return Window(lo: lo, hi: lo.addingTimeInterval(86400),
                          center: lo.addingTimeInterval(43200), label: "어제")
        }
        if q.contains("오늘") || q.contains("새벽") {
            let lo = cal.startOfDay(for: now)
            return Window(lo: lo, hi: now,
                          center: lo.addingTimeInterval(now.timeIntervalSince(lo) / 2), label: "오늘")
        }
        if q.contains("아까") || q.contains("조금전") || q.contains("방금") {
            let lo = now.addingTimeInterval(-6 * 3600)
            return Window(lo: lo, hi: now, center: now.addingTimeInterval(-3 * 3600), label: "아까")
        }
        return nil
    }

    // `…4시간…` 에서 `시간` 바로 앞에 붙은 숫자를 읽는다. 없으면 nil.
    private static func number(before unit: String, in q: String) -> Int? {
        guard let r = q.range(of: unit) else { return nil }
        var digits = ""
        var i = r.lowerBound
        while i > q.startIndex {
            i = q.index(before: i)
            guard q[i].isNumber else { break }
            digits.insert(q[i], at: digits.startIndex)
        }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        return n
    }

    // 창에 들어오는 카드를 결과의 **앞으로** 올린다. 이미 목록에 있던 것도 올린다.
    //
    // 처음에는 "없는 것만 꽂는다" 로 썼다가 실측에서 틀린 것이 드러나 고쳤다. 라이언이 찾던
    // 카드는 글자 맞추기로 이미 9 위에 들어와 있었고, 그래서 "없는 것" 이 아니라는 이유로
    // 안 올라가고 9 위에 그대로 남았다. 시각으로 물었는데 시각이 맞는 것이 아래에 있으면
    // 그 질문에 답한 것이 아니다.
    //
    // 창 안에서의 순서는 최신순이 아니다. 최신순으로 하면 창 안 카드가 다섯을 넘을 때
    // 가장 최근 것만 살아남고 라이언이 찾던 것이 잘려 나간다 — 이것도 실측에서 나왔다.
    // 그래서 **질의의 낱말이 얼마나 겹치는가**를 먼저 보고, 같으면 창 중심에 가까운 순이다.
    private static func withTimeWindow(query: String, corpus: [Doc],
                                       hits: [Hit]) -> (hits: [Hit], note: String) {
        guard let w = timeWindow(query) else { return (hits, "") }
        let inWindow = corpus.filter { d in
            guard let s = d.stamp else { return false }
            return s >= w.lo && s <= w.hi
        }
        guard !inWindow.isEmpty else { return (hits, "") }

        // 한 줄로 이어 붙이면 타입 검사기가 시간 안에 못 푼다(실측). 단계를 갈라 둔다.
        let toks = tokens(query)
        var scored: [(doc: Doc, score: Int, gap: TimeInterval)] = []
        for d in inWindow {
            let gap = abs((d.stamp ?? Date.distantPast).timeIntervalSince(w.center))
            scored.append((doc: d, score: overlap(d, toks), gap: gap))
        }
        scored.sort { a, b in a.score == b.score ? a.gap < b.gap : a.score > b.score }
        let ranked = scored.prefix(pinLimit)

        // 원래 순위에 있던 카드는 그 사유를 지우지 않고 시각 사유를 덧붙인다. 왜 위로 올라왔는지
        // 화면에서 읽혀야 하고, 앞의 사유를 지우면 그 카드가 주제로도 맞았다는 사실이 사라진다.
        let byKey = Dictionary(hits.map { ($0.key, $0.why) }, uniquingKeysWith: { a, _ in a })
        var out: [Hit] = []
        var seen = Set<String>()
        for r in ranked {
            let d = r.doc
            seen.insert(d.key)
            let stamped = "시각 일치: " + w.label + " · " + d.when
            out.append(Hit(key: d.key,
                           why: byKey[d.key].map { $0 + " · " + stamped } ?? stamped))
        }
        for h in hits where !seen.contains(h.key) { out.append(h) }
        return (Array(out.prefix(maxHits)),
                " · 「\(w.label)」로 읽어 그 시각의 카드 \(seen.count) 개를 앞에 세웠다.")
    }

    // 질의를 2 글자 이상 토큰으로. 글자 맞추기와 시각 창이 같은 자를 쓰게 한 벌만 둔다.
    private static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(
                CharacterSet(charactersIn: "가-힣")))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
    }

    private static func overlap(_ d: Doc, _ toks: [String]) -> Int {
        guard !toks.isEmpty else { return 0 }
        let hay = (d.title + " " + d.text + " " + d.target + " " + d.key).lowercased()
        var score = 0
        for t in toks where hay.contains(t) {
            score += d.title.lowercased().contains(t) ? 3 : 1
        }
        return score
    }

    // MARK: - 글자 맞추기 (AI 가 없을 때만)

    // 일부러 단순하다. 이것은 AI 검색의 대체품이 아니라 **AI 가 없을 때 화면이 빈손으로
    // 돌아오지 않게 하는 것**이고, 화면은 이 결과를 AI 결과와 다른 문구로 말한다.
    private static func localSearch(query: String, corpus: [Doc]) -> [Hit] {
        let toks = tokens(query)
        guard !toks.isEmpty else { return [] }

        var scored: [(Doc, Int, [String])] = []
        for d in corpus {
            let hay = (d.title + " " + d.text + " " + d.target + " " + d.key).lowercased()
            var score = 0
            var matched: [String] = []
            for t in toks where hay.contains(t) {
                // 제목에 있으면 더 센다 — 제목은 카드 한 장을 한 줄로 줄인 것이다.
                score += d.title.lowercased().contains(t) ? 3 : 1
                matched.append(t)
            }
            if score > 0 { scored.append((d, score, matched)) }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.when > $1.0.when : $0.1 > $1.1 }
            .prefix(maxHits)
            .map { Hit(key: $0.0.key, why: "글자 일치: " + $0.2.joined(separator: ", ")) }
    }

    private static func jsonStr(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        t.removeFirst(); t.removeLast()
        return t
    }
}
