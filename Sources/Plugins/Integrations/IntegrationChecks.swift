import Foundation

// 라이브 연결 검사 — 자격증명 하나가 "등록돼 있다"와 "실제로 통한다"는 다르다.
// 키가 만료·회수됐거나 스코프가 빠졌을 때 화면은 그냥 "조용히 안 된다"로 보이므로,
// 여기서 진짜 API를 한 번 호출해 어디가 끊겼는지 즉답한다.
//
// 호출은 전부 요금이 붙지 않는 조회 계열(models 목록, auth.test)만 쓴다.
public enum CredentialState: String {
    case ok        // 실제 호출 성공
    case fail      // 등록돼 있는데 거부됨 (만료·오타·권한)
    case missing   // 등록 자체가 없음
    case manual    // 검증할 키가 없는 연동 (브라우저 세션 등) — 사람이 확인
}

public struct CheckResult {
    public var state: CredentialState
    public var account: String
    public var detail: String       // 성공했을 때 무엇이 확인됐는지
    public var error: String        // 실패 원인 (사람 말로)
    public var missingScopes: [String]

    public init(state: CredentialState, account: String = "", detail: String = "",
                error: String = "", missingScopes: [String] = []) {
        self.state = state
        self.account = account
        self.detail = detail
        self.error = error
        self.missingScopes = missingScopes
    }
}

public enum IntegrationChecks {

    // 자격증명 하나를 라이브로 검사한다. id는 합성 id를 받는다 —
    // 인스턴스가 없으면 "slack-user", 있으면 "github-token:must".
    public static func check(_ id: String) -> CheckResult {
        let (credId, key) = CredInstance.split(id)
        guard let c = IntegrationCatalog.credential(credId) else {
            return CheckResult(state: .fail, error: "알 수 없는 연동 항목")
        }
        // 실제로 읽을 키체인 항목. 인스턴스가 있으면 service에 접미어가 붙는다.
        let svc = CredInstance.service(base: c.service, key: key)
        let inst = key.isEmpty ? nil : IntegrationInstances.find(credId: credId, key: key)
        // 브라우저 승인으로 붙는 인스턴스는 앱이 들고 있는 자격증명이 없다 — 여기서
        // API를 부를 수단 자체가 없으므로, 확인했다고 말하지 않고 지금 아는 사실만
        // 그대로 돌려준다 (승인은 Claude 세션이 서버를 처음 쓸 때 일어난다).
        if let inst, !c.authOption(inst.mode).needsToken {
            return checkOAuth(c, inst)
        }
        switch credId {
        case "slack-user":      return checkSlackUser(c, svc)
        case "slack-app":       return checkSlackApp(c, svc)
        case "gemini-api":      return checkGemini(c, svc)
        case "anthropic-api":   return checkAnthropic(c, svc)
        case "openai-api":      return checkOpenAI(c, svc)
        case "claude-cli":      return checkClaudeCli()
        case "chatgpt-web":     return CheckResult(state: .manual,
                                                   detail: "브라우저 로그인 세션 — 스피킹을 누르면 chatgpt.com이 열립니다")
        case "ollama-endpoint": return checkOllama(c, svc)
        case "notion-token":    return checkNotion(c, svc)
        case "github-token":    return checkGitHub(c, svc)
        case "jira-token":      return checkJira(c, svc, inst)
        default:                return CheckResult(state: .fail, error: "검사 방법이 정의되지 않았습니다")
        }
    }

    // 여러 개를 병렬로. 개별 8초(URLRequest timeout), 전체 15초 상한 —
    // handlePost가 동기라 오래 붙잡으면 대시보드 전체가 멈춘다.
    public static func checkAll(_ ids: [String]) -> [String: CheckResult] {
        var out: [String: CheckResult] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = check(id)
                lock.lock(); out[id] = r; lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 15)
        lock.lock()
        // 시간 초과로 비어 있는 칸은 실패로 채운다 — 빈 칸은 화면이 해석할 수 없다.
        for id in ids where out[id] == nil {
            out[id] = CheckResult(state: .fail, error: "검사 시간 초과")
        }
        let snapshot = out
        lock.unlock()
        return snapshot
    }

    // MARK: 개별 검사

    // 브라우저 승인 인스턴스. mcp-remote 는 승인 결과를 ~/.mcp-auth 아래 파일로
    // 갖고 있지만, 그 파일이 어느 서버 것인지는 밖에서 확신할 수 없다 — 그래서
    // "승인 기록이 있다"까지만 말하고 "이 서버가 연결됐다"고는 말하지 않는다.
    // 확인할 수 없는 것을 확인한 척하면, 안 붙는 서버를 붙었다고 그리게 된다.
    private static func checkOAuth(_ c: Credential, _ inst: CredInstance) -> CheckResult {
        let opt = c.authOption(inst.mode)
        let name = MCPRegistrar.serverName(c, inst)
        let registered = !name.isEmpty && MCPRegistrar.registeredNames().contains(name)
        let authDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcp-auth", isDirectory: true)
        let everAuthed = FileManager.default.fileExists(atPath: authDir.path)
        // 살아있는 상태는 아래 테스트 줄이 말한다 — 여기서 같은 말을 반복하면
        // 한 줄에 두 개의 상태가 생기고, 그 둘이 어긋나는 순간 화면을 못 믿게 된다.
        var detail = registered ? "등록됨" : "아직 등록되지 않았습니다"
        if !registered && everAuthed { detail += " · 이 기기에 노션 승인 기록이 있습니다" }
        return CheckResult(state: .manual, account: opt.name, detail: detail)
    }

    private static func checkSlackUser(_ c: Credential, _ svc: String) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        let (code, obj, headers) = http("https://slack.com/api/auth.test", method: "POST",
                                        headers: ["Authorization": "Bearer \(token)"])
        guard code > 0 else { r.error = "네트워크"; return r }
        guard obj?["ok"] as? Bool == true else {
            r.error = (obj?["error"] as? String) ?? "http \(code)"
            return r
        }
        let team = (obj?["team"] as? String) ?? ""
        let user = (obj?["user"] as? String) ?? ""
        r.state = .ok
        r.detail = [team, user].filter { !$0.isEmpty }.joined(separator: " · ")
        // 스코프 대조 — auth.test 응답 헤더 x-oauth-scopes가 이 토큰의 전체 스코프.
        if let hdr = headers["x-oauth-scopes"] {
            let have = Set(hdr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            r.missingScopes = IntegrationCatalog.slackUserScopes.filter { !have.contains($0) }
        }
        return r
    }

    private static func checkSlackApp(_ c: Credential, _ svc: String) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        let (code, obj, _) = http("https://slack.com/api/apps.connections.open", method: "POST",
                                  headers: ["Authorization": "Bearer \(token)"])
        guard code > 0 else { r.error = "네트워크"; return r }
        if obj?["ok"] as? Bool == true {
            r.state = .ok
            r.detail = "Socket Mode 연결 가능"
        } else {
            r.error = (obj?["error"] as? String) ?? "http \(code)"
        }
        return r
    }

    private static func checkGemini(_ c: Credential, _ svc: String) -> CheckResult {
        guard let key = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        // 키를 URL 쿼리 대신 헤더로 보낸다 (로그·프록시에 키가 남지 않게).
        let (code, obj, _) = http("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1",
                                  headers: ["x-goog-api-key": key])
        return apiResult(c, svc, code: code, obj: obj, errPath: ["error", "message"])
    }

    private static func checkAnthropic(_ c: Credential, _ svc: String) -> CheckResult {
        guard let key = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        let (code, obj, _) = http("https://api.anthropic.com/v1/models?limit=1",
                                  headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
        return apiResult(c, svc, code: code, obj: obj, errPath: ["error", "message"])
    }

    private static func checkOpenAI(_ c: Credential, _ svc: String) -> CheckResult {
        guard let key = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        let (code, obj, _) = http("https://api.openai.com/v1/models",
                                  headers: ["Authorization": "Bearer \(key)"])
        return apiResult(c, svc, code: code, obj: obj, errPath: ["error", "message"])
    }

    // 로컬 서버라 키가 없다 — 주소가 비어 있으면 기본 포트를 본다.
    private static func checkOllama(_ c: Credential, _ svc: String) -> CheckResult {
        let base = (CMKeychain.value(service: svc) ?? "").trimmingCharacters(in: .whitespaces)
        let url = (base.isEmpty ? "http://127.0.0.1:11434" : base)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var r = CheckResult(state: .fail, account: url)
        let (code, obj, _) = http("\(url)/api/tags")
        guard code > 0 else {
            r.state = .missing
            r.error = "응답이 없습니다 — ollama serve가 실행 중인지 확인하세요"
            return r
        }
        guard code == 200 else { r.error = "http \(code)"; return r }
        let models = (obj?["models"] as? [[String: Any]])?.count ?? 0
        r.state = .ok
        r.detail = "모델 \(models)개"
        return r
    }

    // 노션 통합 토큰. 토큰이 유효해도 통합이 어느 페이지에도 연결돼 있지 않으면
    // "연결은 됐는데 아무것도 안 보인다"가 되므로, 접근 가능한 페이지 수까지 확인해
    // 그 상태를 detail로 말해 준다 (사용자가 노션에서 해야 할 일이 남았다는 뜻).
    private static func checkNotion(_ c: Credential, _ svc: String) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        let hdrs = ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"]
        let (code, obj, _) = http("https://api.notion.com/v1/users/me", headers: hdrs)
        guard code > 0 else { r.error = "네트워크"; return r }
        guard code == 200 else {
            r.error = (obj?["message"] as? String).map { String($0.prefix(120)) } ?? "http \(code)"
            return r
        }
        let botName = (obj?["name"] as? String) ?? "통합"
        let ws = ((obj?["bot"] as? [String: Any])?["workspace_name"] as? String) ?? ""
        r.state = .ok
        r.detail = [botName, ws].filter { !$0.isEmpty }.joined(separator: " · ")
        // 공유된 페이지가 하나도 없으면 도구는 붙지만 아무것도 못 읽는다.
        let (sCode, sObj, _) = http("https://api.notion.com/v1/search", method: "POST",
                                    headers: hdrs, body: "{\"page_size\":1}")
        if sCode == 200, let results = sObj?["results"] as? [[String: Any]], results.isEmpty {
            r.error = "토큰은 유효하지만 이 통합에 공유된 페이지가 없습니다 — 노션에서 대상 페이지의 '연결'에 통합을 추가하세요"
        }
        return r
    }

    // 깃허브 토큰. 개인/조직 어느 쪽 토큰인지가 화면에서 구분돼야 해서 로그인 계정을
    // detail로 싣는다 — 인스턴스를 여러 개 등록했을 때 어느 칸이 어느 계정인지
    // 라벨만으로는 확신할 수 없다(사용자가 붙인 이름은 틀릴 수 있다).
    private static func checkGitHub(_ c: Credential, _ svc: String) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        let (code, obj, headers) = http("https://api.github.com/user",
                                        headers: ["Authorization": "Bearer \(token)",
                                                  "Accept": "application/vnd.github+json",
                                                  "X-GitHub-Api-Version": "2022-11-28"])
        guard code > 0 else { r.error = "네트워크"; return r }
        guard code == 200 else {
            r.error = (obj?["message"] as? String).map { String($0.prefix(120)) } ?? "http \(code)"
            return r
        }
        let login = (obj?["login"] as? String) ?? ""
        r.state = .ok
        // classic 토큰만 스코프 헤더를 준다. fine-grained PAT은 빈 값이라 종류를 대신 말한다.
        let scopes = (headers["x-oauth-scopes"] ?? "").trimmingCharacters(in: .whitespaces)
        let kindLabel = scopes.isEmpty ? "fine-grained" : "classic · \(scopes)"
        r.detail = [login, kindLabel].filter { !$0.isEmpty }.joined(separator: " · ")
        return r
    }

    // 지라는 토큰만으로 검사할 수 없다 — 어느 사이트의 누구인지가 인스턴스에 있다.
    private static func checkJira(_ c: Credential, _ svc: String, _ inst: CredInstance?) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        let site = (inst?.fields["site"] ?? "").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let email = (inst?.fields["email"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty, !email.isEmpty else {
            r.error = "사이트 주소와 계정 이메일을 함께 입력해야 검사할 수 있습니다"
            return r
        }
        guard let basic = "\(email):\(token)".data(using: .utf8)?.base64EncodedString() else {
            r.error = "인증 문자열을 만들지 못했습니다"
            return r
        }
        let (code, obj, _) = http("\(site)/rest/api/3/myself",
                                  headers: ["Authorization": "Basic \(basic)",
                                            "Accept": "application/json"])
        guard code > 0 else { r.error = "네트워크 — 사이트 주소를 확인하세요"; return r }
        guard code == 200 else {
            // 지라는 실패 사유를 errorMessages 배열로 준다 (401은 본문이 비어 있기도 하다).
            let msg = (obj?["errorMessages"] as? [String])?.first
                ?? (obj?["message"] as? String) ?? ""
            // 404는 토큰 문제가 아니라 사이트 주소가 틀린 경우가 대부분이다 —
            // "http 404"만 보여주면 사용자는 토큰을 다시 발급하러 간다.
            var fallback = "http \(code)"
            if code == 401 { fallback = "인증 거부 — 이메일·토큰을 확인하세요" }
            if code == 404 { fallback = "사이트를 찾지 못했습니다 — 주소를 확인하세요" }
            if code == 403 { fallback = "권한이 없습니다 — 계정 권한 또는 API 토큰 인증 허용 여부를 확인하세요" }
            r.error = msg.isEmpty ? fallback : String(msg.prefix(120))
            return r
        }
        let name = (obj?["displayName"] as? String) ?? email
        r.state = .ok
        r.detail = [name, URL(string: site)?.host ?? site].filter { !$0.isEmpty }.joined(separator: " · ")
        return r
    }

    // 번역 폴백 — 빠른 키가 없거나 실패할 때 claude CLI(구독 로그인)로 돈다.
    // 키체인 항목이 아니라 바이너리 존재만 본다.
    private static func checkClaudeCli() -> CheckResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return CheckResult(state: .ok, detail: found)
        }
        // GUI 앱 PATH는 좁다 — 로그인 셸에 물어 마지막으로 한 번 더 찾는다.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !path.isEmpty { return CheckResult(state: .ok, detail: path) }
        }
        return CheckResult(state: .missing, error: "claude CLI를 찾지 못했습니다")
    }

    // MARK: 공통

    private static func apiResult(_ c: Credential, _ svc: String, code: Int, obj: [String: Any]?,
                                  errPath: [String]) -> CheckResult {
        var r = CheckResult(state: .fail, account: CMKeychain.account(service: svc, fallback: c.account))
        guard code > 0 else { r.error = "네트워크"; return r }
        if code == 200 {
            r.state = .ok
            r.detail = "키 유효"
            return r
        }
        var node: Any? = obj
        for key in errPath { node = (node as? [String: Any])?[key] }
        let msg = (node as? String) ?? ""
        r.error = msg.isEmpty ? "http \(code)" : String(msg.prefix(120))
        return r
    }

    // 동기 HTTP — handlePost 컨텍스트에서 부르므로 세마포어로 기다린다.
    private static func http(_ url: String, method: String = "GET",
                             headers: [String: String] = [:], body: String = "{}")
        -> (code: Int, body: [String: Any]?, headers: [String: String]) {
        guard let u = URL(string: url) else { return (0, nil, [:]) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 8
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if method == "POST" {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        }
        var code = 0
        var body: [String: Any]?
        var respHeaders: [String: String] = [:]
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                code = http.statusCode
                for (k, v) in http.allHeaderFields {
                    if let key = k as? String, let value = v as? String {
                        respHeaders[key.lowercased()] = value
                    }
                }
            }
            if let data = data { body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return (code, body, respHeaders)
    }
}
