import Foundation
import Integrations

// 슬랙 페이지의 '연동' 모달이 부르는 라이브 점검 — 이제 얇은 어댑터다.
//
// 카탈로그(무엇이 필요한가), 키체인 접근, 실제 API 검사는 전부 Integrations
// 레지스트리로 옮겼다. 슬랙 페이지·플러그인 페이지의 연동 목록이 같은 원본을
// 보게 하려는 것이 목적이다 — 예전에는 같은 키 목록이 네 군데에 손으로 적혀 있어
// 하나를 고치면 나머지가 조용히 어긋났다.
//
// 이 파일이 남아 있는 이유는 응답 키 이름 때문이다: 슬랙 페이지는 checks.slackUser
// 같은 이름을 기대하고, 레지스트리는 slack-user 라는 id를 쓴다. 여기서 옛 이름으로
// 되짚어 주면 페이지를 건드리지 않고도 원본을 한곳으로 모을 수 있다.
public enum SlackIntegrations {

    // 옛 응답 키 → 레지스트리 자격증명 id. 순서는 화면에 보이는 순서 그대로.
    static let legacyKeys: [(legacy: String, id: String)] = [
        ("slackUser", "slack-user"),
        ("slackApp", "slack-app"),
        ("gemini", "gemini-api"),
        ("anthropic", "anthropic-api"),
        ("claudeCli", "claude-cli"),
    ]

    // 슬랙 데몬·앱이 실제로 쓰는 사용자 토큰 스코프 (원본은 IntegrationCatalog).
    public static var requiredUserScopes: [String] { IntegrationCatalog.slackUserScopes }

    public static func checkJSON() -> String {
        let t0 = DispatchTime.now()
        let ids = legacyKeys.map { $0.id }
        let results = IntegrationChecks.checkAll(ids)
        // 레지스트리 캐시에도 남겨 둔다 — 플러그인 페이지가 다시 검사하지 않고도
        // 같은 판단(연결됨/끊김)을 그릴 수 있어야 "한곳의 데이터"가 성립한다.
        IntegrationStore.record(results)

        let ms = SlackTranslateStore.ms(since: t0)
        let summary = legacyKeys.map { pair -> String in
            let st = results[pair.id]?.state.rawValue ?? "?"
            return "\(pair.legacy)=\(st == "ok" ? "✓" : st)"
        }.joined(separator: " ")
        let allOk = legacyKeys.allSatisfy { results[$0.id]?.state == .ok }
        SlackActionLog.log("integrations.check", ok: allOk, ms: ms, detail: summary)

        var out = "{\"ok\":true,\"at\":\(Int(Date().timeIntervalSince1970)),\"ms\":\(ms)"
        out += ",\"checks\":{"
        out += legacyKeys.map { pair -> String in
            let r = results[pair.id] ?? CheckResult(state: .fail, error: "검사 결과 없음")
            var s = "\"\(pair.legacy)\":{\"state\":\"\(r.state.rawValue)\""
            s += ",\"account\":\(esc(r.account)),\"detail\":\(esc(r.detail)),\"error\":\(esc(r.error))"
            s += ",\"missingScopes\":[\(r.missingScopes.map(esc).joined(separator: ","))]}"
            return s
        }.joined(separator: ",")
        out += "}"
        // 키 갱신을 반영하려면 데몬 재시작이 필요하다 (데몬은 번역 키를 프로세스당
        // 1회만 읽는다).
        out += ",\"daemonNote\":\"키를 갱신했다면 '다시 연결'로 데몬을 재시작해야 반영됩니다.\""
        // 재발급 가이드가 "슬랙 앱에서 체크할 스코프 목록"을 이 배열 그대로 그린다 —
        // 페이지에 목록을 또 적어두면 카탈로그와 조용히 어긋난다.
        out += ",\"userScopes\":[\(requiredUserScopes.map(esc).joined(separator: ","))]"
        out += "}"
        return out
    }

    private static func esc(_ s: String) -> String {
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
        return out + "\""
    }
}
