import Foundation
import Integrations

// 지라 번역 엔진 — 크롬 익스텐션이 보낸 텍스트 묶음을 한국어로 옮긴다.
//
// 왜 익스텐션이 Gemini를 직접 부르지 않는가: API 키가 브라우저 안(chrome.storage)에
// 평문으로 남으면 그 프로필을 읽을 수 있는 무엇이든 키를 가져간다. 키는 이미 키체인
// (cm-gemini-api-key)에 있고 슬랙 번역이 같은 키를 쓰므로, 익스텐션은 키를 모른 채
// 로컬 브리지에만 요청하고 실제 호출은 이 파일이 한다. 익스텐션이 유출돼도 새어나가는
// 것은 "로컬 앱에 번역을 시킬 수 있는 권한"뿐이다.
//
// 한 요청에 여러 조각(제목·설명·댓글 N개)을 함께 보내 Gemini 호출 1회로 끝낸다 —
// 조각마다 호출하면 이슈 하나 여는 데 열 번 넘게 왕복한다.
public enum JiraTranslate {

    // 슬랙 번역과 같은 모델 계열. `-latest` 별칭을 쓰는 이유는 고정 버전명이 키마다
    // 404가 나기 때문(슬랙 데몬 주석과 동일한 사정).
    static let models: [String: String] = [
        "gemini-flash-lite": "gemini-flash-lite-latest",
        "gemini-flash": "gemini-flash-latest",
    ]
    static let defaultModel = "gemini-flash-lite"

    // 입력 상한 — 익스텐션이 실수로 페이지 전체를 밀어넣어도 요금과 지연이 터지지 않게.
    static let maxSegments = 60
    static let maxCharsPerSegment = 8_000
    static let maxCharsTotal = 60_000

    public struct Result {
        public let outputs: [String]     // 입력과 같은 길이. 실패한 조각은 원문 그대로.
        public let model: String
        public let ms: Int
        public let cached: Int
        public let error: String?        // nil = 전부 성공
    }

    // MARK: - 캐시

    // 같은 티켓을 다시 열거나 지라가 리렌더할 때마다 재호출하지 않는다. 프로세스
    // 메모리에만 두는 이유: 번역문은 회사 이슈 내용이라 디스크에 사본을 늘리지 않는다.
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 800

    private static func cacheKey(_ lang: String, _ text: String) -> String {
        "\(lang)\u{0}\(text)"
    }

    private static func cached(_ key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func store(_ key: String, _ value: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    public static func clearCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeAll(); cacheOrder.removeAll()
    }

    // MARK: - 번역

    public static func translate(_ texts: [String], lang: String = "ko", model requested: String? = nil) -> Result {
        let t0 = Date()
        let langName = langLabel(lang)
        var outputs = texts
        var pending: [Int] = []          // 캐시에 없어서 실제로 물어봐야 하는 조각들
        var hits = 0

        for (i, t) in texts.enumerated() {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let hit = cached(cacheKey(lang, trimmed)) { outputs[i] = hit; hits += 1; continue }
            pending.append(i)
        }
        guard !pending.isEmpty else {
            return Result(outputs: outputs, model: "cache", ms: ms(t0), cached: hits, error: nil)
        }

        guard let key = CMKeychain.value(service: "cm-gemini-api-key"), !key.isEmpty else {
            return Result(outputs: outputs, model: "none", ms: ms(t0), cached: hits,
                          error: "Gemini API 키가 연동돼 있지 않습니다 (연동 관리에서 등록하세요)")
        }

        let choice = models[requested ?? ""] != nil ? requested! : defaultModel
        let apiModel = models[choice]!
        let payload = pending.map { texts[$0].trimmingCharacters(in: .whitespacesAndNewlines) }

        do {
            let translated = try callGemini(apiModel: apiModel, key: key,
                                            texts: payload, langName: langName)
            // 개수가 어긋나면(모델이 조각을 합치거나 빠뜨린 경우) 받은 만큼만 반영하고
            // 나머지는 원문을 남긴다 — 엉뚱한 줄에 붙는 것보다 낫다.
            for (n, idx) in pending.enumerated() where n < translated.count {
                let out = translated[n].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else { continue }
                outputs[idx] = out
                store(cacheKey(lang, payload[n]), out)
            }
            let short = translated.count < pending.count
            return Result(outputs: outputs, model: choice, ms: ms(t0), cached: hits,
                          error: short ? "일부 조각을 번역하지 못했습니다 (\(translated.count)/\(pending.count))" : nil)
        } catch {
            return Result(outputs: outputs, model: choice, ms: ms(t0), cached: hits,
                          error: (error as? TranslateError)?.message ?? "\(error)")
        }
    }

    struct TranslateError: Error { let message: String }

    private static func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }

    static let langs: [String: String] = [
        "ko": "한국어", "en": "영어(English)", "ja": "일본어(日本語)",
        "zh": "중국어(简体中文)", "vi": "베트남어(Tiếng Việt)",
    ]

    static func langLabel(_ code: String) -> String { langs[code] ?? langs["ko"]! }

    // 지라 텍스트에 맞춘 지시. 이슈 키·코드·URL을 번역해버리면 검색과 링크가 깨지므로
    // 보존 대상을 먼저 못박는다.
    static func systemPrompt(_ langName: String) -> String {
        """
        너는 Jira 이슈 화면의 텍스트를 \(langName)로 옮기는 번역기다.

        입력은 문자열 배열(JSON)이고, 각 원소는 화면의 한 조각(이슈 제목, 설명, 댓글 등)이다.
        같은 길이의 문자열 배열(JSON)로만 답하라. 원소 순서는 입력과 정확히 같아야 한다.

        규칙:
        - 이미 \(langName)로 쓰인 조각은 번역하지 말고 원문 그대로 그 자리에 둔다.
        - 이슈 키(ME-13986 같은 대문자-숫자 조합), 브랜치·커밋 해시, 파일 경로, URL,
          @멘션, 코드·명령어, 제품명·회사명·티커·사람 이름은 번역하지 말고 그대로 유지한다.
        - 상태 라벨(BACKLOG, In Progress, Done 등)은 옮기되 원문을 괄호로 덧붙이지 않는다.
        - 줄바꿈·목록 기호·들여쓰기 같은 문서 구조는 입력 그대로 유지한다.
        - 업무 문맥에 맞는 자연스러운 \(langName) 문장으로 옮긴다. 직역투를 피한다.
        - 번역문 외에 설명·머리말·따옴표·마크다운 헤더를 덧붙이지 않는다.
        """
    }

    private static func callGemini(apiModel: String, key: String,
                                   texts: [String], langName: String) throws -> [String] {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(apiModel):generateContent")
        else { throw TranslateError(message: "잘못된 모델 이름") }

        let inputJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: texts)) ?? Data("[]".utf8),
                               as: UTF8.self)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt(langName)]]],
            "contents": [["parts": [["text": inputJSON]]]],
            // responseSchema로 배열을 강제한다 — 구분자 파싱보다 어긋날 여지가 적다.
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json",
                "responseSchema": ["type": "ARRAY", "items": ["type": "STRING"]],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var code = 0
        var data: Data?
        var netErr: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, err in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            data = d
            if let err = err { netErr = err.localizedDescription }
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 30) == .success else {
            throw TranslateError(message: "번역 시간 초과")
        }
        if let netErr = netErr { throw TranslateError(message: "네트워크: \(netErr)") }
        guard code == 200, let data = data else {
            throw TranslateError(message: "Gemini HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]], let first = cands.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw TranslateError(message: "Gemini 응답을 해석할 수 없습니다")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard let arr = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] else {
            throw TranslateError(message: "Gemini가 배열이 아닌 응답을 돌려줬습니다")
        }
        return arr
    }
}
