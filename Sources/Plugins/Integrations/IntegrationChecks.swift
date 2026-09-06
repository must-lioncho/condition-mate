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
    // 검사가 알아낸 상세(깃허브 CLI: 계정·조직·레포·서명) — 이미 JSON 문자열.
    // 인스턴스는 자기 파일에 scan을 두지만, 인스턴스 없는 자격증명은 이 결과가
    // 상세를 실어 나를 유일한 자리다. 빈 값이면 상세 없음.
    public var scan: String

    public init(state: CredentialState, account: String = "", detail: String = "",
                error: String = "", missingScopes: [String] = [], scan: String = "") {
        self.state = state
        self.account = account
        self.detail = detail
        self.error = error
        self.missingScopes = missingScopes
        self.scan = scan
    }
}

public enum IntegrationChecks {

    // 자격증명 하나를 라이브로 검사한다. id는 합성 id를 받는다 —
    // 인스턴스가 없으면 "slack-user", 있으면 "github-token:must".
    //
    // deep: 사람이 '연결 확인'을 눌렀는가. 대부분의 검사는 둘을 구분하지 않지만,
    // 확인 비용이 화면을 그리는 경로에 앉으면 안 되는 것이 하나 있다 — 지라 골은
    // 확인하려면 파이썬을 띄우고 토큰을 갱신(회전)해야 해서, 목록이 5초마다 다시
    // 그려질 때마다 그걸 하면 안 된다. 그래서 평소엔 자격증명이 서 있는지까지만
    // 보고, 실제 호출은 사람이 눌렀을 때만 한다.
    public static func check(_ id: String, deep: Bool = false) -> CheckResult {
        let (credId, key) = CredInstance.split(id)
        guard let c = IntegrationCatalog.credential(credId) else {
            return CheckResult(state: .fail, error: "알 수 없는 연동 항목")
        }
        // 실제로 읽을 키체인 항목. 인스턴스가 있으면 service에 접미어가 붙는다.
        let inst = key.isEmpty ? nil : IntegrationInstances.find(credId: credId, key: key)
        let svc = inst?.keychainService.isEmpty == false
            ? inst!.keychainService : CredInstance.service(base: c.service, key: key)
        let account = inst?.keychainAccount.isEmpty == false ? inst!.keychainAccount : nil
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
        case "notion-token":    return checkNotion(c, svc, account)
        case "github-token":    return checkGitHub(c, svc, inst)
        case "github-cli":      return checkGitHubCli(c)
        case "github-oauth-app": return checkGitHubOAuthApp(svc)
        case "genspark-cli":    return checkGensparkCli()
        case "jira-token":      return checkJira(c, svc, inst)
        case "jira-goals":      return checkJiraGoals(deep: deep)
        case "jira-cli":        return checkAtlassianCli()
        default:                return CheckResult(state: .fail, error: "검사 방법이 정의되지 않았습니다")
        }
    }

    // 여러 개를 병렬로. 개별 8초(URLRequest timeout), 전체 15초 상한 —
    // handlePost가 동기라 오래 붙잡으면 대시보드 전체가 멈춘다.
    public static func checkAll(_ ids: [String], deep: Bool = false) -> [String: CheckResult] {
        var out: [String: CheckResult] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = check(id, deep: deep)
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
        if !registered && everAuthed { detail += " · 이 기기에 승인 기록이 있습니다" }
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
    private static func checkNotion(_ c: Credential, _ svc: String, _ selectedAccount: String?) -> CheckResult {
        guard let token = selectedAccount.map({ CMKeychain.value(service: svc, account: $0) }) ?? CMKeychain.value(service: svc) else {
            return CheckResult(state: .missing, account: c.account)
        }
        var r = CheckResult(state: .fail, account: selectedAccount ?? CMKeychain.account(service: svc, fallback: c.account))
        let hdrs = ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"]
        let (code, obj, _) = http("https://api.notion.com/v1/users/me", headers: hdrs)
        guard code > 0 else { r.error = "네트워크"; return r }
        guard code == 200 else {
            if code == 401 || code == 403 {
                r.error = "토큰이 거부됐습니다 — 만료·회수됐거나 값이 잘못됐습니다"
            } else {
                r.error = (obj?["message"] as? String).map { sanitizeError($0) } ?? "http \(code)"
            }
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

    private static func sanitizeError(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(120))
    }

    // 깃허브 토큰. 개인/조직 어느 쪽 토큰인지가 화면에서 구분돼야 해서 로그인 계정을
    // detail로 싣는다 — 인스턴스를 여러 개 등록했을 때 어느 칸이 어느 계정인지
    // 라벨만으로는 확신할 수 없다(사용자가 붙인 이름은 틀릴 수 있다).
    //
    // 그리고 여기서 한 걸음 더 간다: "붙는다"만으로는 조직이 여럿인 사람에게
    // 아무 정보가 없다. MUST 토큰과 Global MPC 토큰은 둘 다 200을 주지만 닿는
    // 레포가 전혀 다르고, 사용자가 알고 싶은 것은 정확히 그 차이다. 그래서 이
    // 검사는 승인 형태(PAT 종류·만료·스코프)·조직·접근 레포·커밋 서명까지 훑어
    // 인스턴스에 적어 둔다(IntegrationInstances.setScan — 비밀값은 들어가지 않는다).
    private static func checkGitHub(_ c: Credential, _ svc: String, _ inst: CredInstance?) -> CheckResult {
        guard let token = CMKeychain.value(service: svc) else {
            if let inst { IntegrationInstances.setScan(credId: c.id, key: inst.key, json: "") }
            return CheckResult(state: .missing, account: c.account)
        }
        var r = githubTokenResult(token: token, cred: c, inst: inst)
        r.account = CMKeychain.account(service: svc, fallback: c.account)
        // 거부된 토큰의 지난 스캔은 이제 거짓이다 — 남겨 두면 죽은 토큰 아래에
        // 레포 목록이 그대로 붙어 있어서 아직 닿는 것처럼 읽힌다. 네트워크가 없어
        // 판단을 못 한 경우는 예외 — 그건 토큰에 대한 새 사실이 아니다.
        if let inst, r.state == .ok || r.error != "네트워크" {
            IntegrationInstances.setScan(credId: c.id, key: inst.key, json: r.scan)
        }
        return r
    }

    // 토큰 하나를 /user 로 확인하고, 통하면 훑어서(githubScan) 요약 한 줄과 상세
    // JSON을 만든다. PAT 인스턴스와 gh CLI 로그인이 같은 길을 쓴다 — 토큰의 출처만
    // 다르지 "이 토큰이 무엇에 닿는가"라는 질문은 같다.
    private static func githubTokenResult(token: String, cred c: Credential,
                                          inst: CredInstance?) -> CheckResult {
        var r = CheckResult(state: .fail)
        let hdrs = ["Authorization": "Bearer \(token)",
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28"]
        let (code, obj, headers) = http("https://api.github.com/user", headers: hdrs)
        guard code > 0 else { r.error = "네트워크"; return r }
        guard code == 200 else {
            r.error = (obj?["message"] as? String).map { String($0.prefix(120)) } ?? "http \(code)"
            if code == 401 { r.error = "토큰이 거부됐습니다 — 만료·회수됐거나 값이 잘못됐습니다" }
            return r
        }
        let login = (obj?["login"] as? String) ?? ""
        let scan = githubScan(token: token, hdrs: hdrs, user: obj ?? [:],
                              userHeaders: headers, cred: c, inst: inst)
        if let data = try? JSONSerialization.data(withJSONObject: scan, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            r.scan = json
        }
        r.state = .ok
        r.account = login
        let auth = (scan["auth"] as? [String: Any]) ?? [:]
        let repos = (scan["repos"] as? [String: Any]) ?? [:]
        let orgs = (scan["orgs"] as? [[String: Any]]) ?? []
        var bits = [login, (auth["kind"] as? String) ?? ""]
        let n = (repos["count"] as? Int) ?? 0
        if n > 0 { bits.append("레포 \(n)\(((repos["more"] as? Bool) ?? false) ? "+" : "")") }
        if !orgs.isEmpty { bits.append("조직 \(orgs.count)") }
        r.detail = bits.filter { !$0.isEmpty }.joined(separator: " · ")
        // 통했지만 사용자가 손봐야 하는 것 — 조직 미승인·만료 임박·보이는 레포 없음.
        r.error = (scan["warning"] as? String) ?? ""
        return r
    }

    // gh CLI 로그인. 토큰은 gh가 자기 키링에 들고 있다 — 앱은 저장하지 않고 그 자리에서
    // 빌려 훑기만 한다. `gh auth token`이 실패하면 로그인이 없는 것이고, 통하면
    // PAT 인스턴스와 같은 상세(계정·조직·레포·서명)를 만들어 돌려준다.
    private static func checkGitHubCli(_ c: Credential) -> CheckResult {
        guard let gh = findCli("gh") else {
            return CheckResult(state: .missing, error: "gh CLI를 찾지 못했습니다 — brew install gh 후 gh auth login")
        }
        let (tcode, tout, terr) = runCli(gh, ["auth", "token"])
        let token = tout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tcode == 0, !token.isEmpty else {
            let why = terr.trimmingCharacters(in: .whitespacesAndNewlines)
            return CheckResult(state: .missing,
                               error: why.isEmpty ? "gh에 로그인돼 있지 않습니다 — 터미널에서 gh auth login"
                                                  : String(why.prefix(160)))
        }
        var r = githubTokenResult(token: token, cred: c, inst: nil)
        // gh 자신이 말하는 로그인 계정 — API가 준 login과 다르면 그 사실이 보여야
        // 한다(다른 계정 토큰이 환경변수로 끼어든 경우).
        let (_, sout, serr) = runCli(gh, ["auth", "status", "--hostname", "github.com"])
        let status = (sout + "\n" + serr)
        if let acct = status.split(separator: "\n")
            .first(where: { $0.contains("Logged in to github.com account") })
            .map({ $0.replacingOccurrences(of: "✓", with: "") .trimmingCharacters(in: .whitespaces) }) {
            let ghLogin = acct.components(separatedBy: "account ").last?
                .components(separatedBy: " ").first ?? ""
            if !ghLogin.isEmpty, !r.account.isEmpty, ghLogin != r.account {
                r.error = (r.error.isEmpty ? "" : r.error + " · ")
                    + "gh 상태는 \(ghLogin) 계정인데 토큰은 \(r.account) 로 응답합니다 (GH_TOKEN 환경변수 확인)"
            }
        }
        if r.state == .ok { r.detail = "gh " + gh + " · " + r.detail }
        return r
    }

    // GitHub은 OAuth App의 client_id/secret이 맞는지 확인할 조회 API를 안 내놓는다
    // (그 자체가 로그인 수단이라 "맞는지 확인"이 곧 로그인 시도다) — 그래서 형식만
    // 본다. 실제로 맞는지는 위 GitHub 연동의 '브라우저 승인(OAuth)'을 처음 켤 때
    // mcp-remote가 띄우는 승인 화면에서 드러난다.
    private static func checkGitHubOAuthApp(_ svc: String) -> CheckResult {
        guard let raw = CMKeychain.value(service: svc), !raw.isEmpty else {
            return CheckResult(state: .missing)
        }
        guard let sep = raw.firstIndex(of: ":"), sep != raw.startIndex,
              raw.index(after: sep) != raw.endIndex else {
            return CheckResult(state: .fail, error: "형식이 'Client ID:Client Secret'이 아닙니다")
        }
        return CheckResult(state: .manual,
                           detail: "저장됨 — 실제로 맞는지는 GitHub 연동의 '브라우저 승인(OAuth)'을 "
                               + "처음 켤 때 뜨는 GitHub 승인 화면에서 확인됩니다")
    }

    // GUI 앱의 PATH는 좁다 — 흔한 자리를 먼저 보고, 없으면 로그인 셸에 한 번 묻는다.
    private static func findCli(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let (code, out, _) = runCli("/bin/zsh", ["-lc", "command -v \(name)"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (code == 0 && !path.isEmpty) ? path : nil
    }

    private static func runCli(_ path: String, _ args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "", "실행 실패") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    // 토큰 하나가 실제로 무엇에 닿는지 훑는다. 실패하는 호출은 조용히 건너뛴다 —
    // 스코프가 좁은 토큰이면 일부는 403이 정상이고, 그걸 실패로 올리면 잘 붙는
    // 토큰이 빨갛게 보인다. 대신 "확인할 수 없었다"를 그 자리에 적는다.
    private static func githubScan(token: String, hdrs: [String: String],
                                   user: [String: Any], userHeaders: [String: String],
                                   cred: Credential, inst: CredInstance?) -> [String: Any] {
        var out: [String: Any] = [:]
        var warnings: [String] = []

        // ----- 승인 형태 -----
        // 접두어가 종류를 말한다. 화면에서 "OAuth인가 PAT인가"에 답하는 자리다.
        var kind = "알 수 없는 형식"
        if token.hasPrefix("github_pat_")  { kind = "fine-grained PAT" }
        else if token.hasPrefix("ghp_")    { kind = "classic PAT" }
        else if token.hasPrefix("gho_")    { kind = "OAuth 앱 토큰" }
        else if token.hasPrefix("ghu_")    { kind = "GitHub App 사용자 토큰" }
        else if token.hasPrefix("ghs_")    { kind = "GitHub App 설치 토큰" }
        // classic 토큰만 스코프 헤더를 준다. fine-grained는 빈 값이고, 그건 스코프가
        // 없다는 뜻이 아니라 "권한이 레포별로 잘게 붙어 있어 헤더로 안 온다"는 뜻이다.
        let scopeRaw = (userHeaders["x-oauth-scopes"] ?? "").trimmingCharacters(in: .whitespaces)
        let scopes = scopeRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let expRaw = (userHeaders["github-authentication-token-expiration"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        var auth: [String: Any] = ["kind": kind, "scopes": scopes, "expires": expRaw]
        auth["scopeNote"] = scopes.isEmpty
            ? "fine-grained·앱 토큰은 스코프를 헤더로 주지 않습니다 — 권한은 레포별로 붙습니다"
            : ""
        if let days = daysUntil(expRaw) {
            auth["expiresInDays"] = days
            if days <= 0 { warnings.append("토큰이 만료됐습니다") }
            else if days <= 30 { warnings.append("토큰이 \(days)일 뒤 만료됩니다") }
        } else if expRaw.isEmpty {
            auth["expiresNote"] = "만료 없음"
        }
        out["auth"] = auth
        out["account"] = ["login": (user["login"] as? String) ?? "",
                          "name": (user["name"] as? String) ?? "",
                          "type": (user["type"] as? String) ?? "",
                          "url": (user["html_url"] as? String) ?? ""]
        if let remain = Int(userHeaders["x-ratelimit-remaining"] ?? ""),
           let limit = Int(userHeaders["x-ratelimit-limit"] ?? "") {
            out["rate"] = ["remaining": remain, "limit": limit]
        }

        // ----- 조직 -----
        var orgLogins: [String] = []
        let (oCode, oAny, _) = httpAny("https://api.github.com/user/orgs?per_page=100", headers: hdrs)
        if oCode == 200, let rows = oAny as? [[String: Any]] {
            orgLogins = rows.compactMap { $0["login"] as? String }
            out["orgs"] = orgLogins.map { ["login": $0] }
        } else {
            out["orgs"] = [[String: Any]]()
            out["orgsNote"] = oCode == 403
                ? "조직 목록을 읽을 권한이 없습니다 (classic 토큰은 read:org 스코프가 필요합니다)"
                : "조직 목록을 확인하지 못했습니다"
        }

        // ----- 접근 가능한 레포 -----
        // fine-grained PAT은 여기 나오는 것이 곧 '이 토큰에 물린 레포'다.
        // classic은 계정이 볼 수 있는 전체라서 수가 크고, 그 차이를 화면이 말한다.
        let (rCode, rAny, rHeaders) = httpAny(
            "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
            headers: hdrs)
        var ownerRows: [[String: Any]] = []
        var repoCount = 0
        if rCode == 200, let rows = rAny as? [[String: Any]] {
            repoCount = rows.count
            var byOwner: [String: [[String: Any]]] = [:]
            for row in rows {
                let owner = ((row["owner"] as? [String: Any])?["login"] as? String) ?? "?"
                byOwner[owner, default: []].append(row)
            }
            ownerRows = byOwner.map { owner, rows -> [String: Any] in
                let perms = rows.map { ($0["permissions"] as? [String: Any]) ?? [:] }
                return [
                    "login": owner,
                    "count": rows.count,
                    "private": rows.filter { ($0["private"] as? Bool) ?? false }.count,
                    "push": perms.filter { ($0["push"] as? Bool) ?? false }.count,
                    "admin": perms.filter { ($0["admin"] as? Bool) ?? false }.count,
                    // 이름은 앞의 몇 개만 — 100개를 그대로 실으면 화면이 목록이 된다.
                    "names": rows.prefix(8).compactMap { $0["name"] as? String },
                ]
            }.sorted { (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0) }
        }
        let more = (rHeaders["link"] ?? "").contains("rel=\"next\"")
        out["repos"] = ["count": repoCount, "more": more, "owners": ownerRows,
                        "note": rCode == 200 ? "" : "레포 목록을 확인하지 못했습니다 (http \(rCode))"]
        if rCode == 200 && repoCount == 0 {
            warnings.append("토큰은 유효하지만 접근 가능한 레포가 없습니다 — fine-grained 토큰이면 레포를 선택했는지, 조직 토큰이면 resource owner를 확인하세요")
        }

        // ----- 선언한 조직에 실제로 닿는가 -----
        // 이름을 적어 둔 인스턴스만 확인한다. 여기가 "MUST 토큰인데 MUST가 안 보인다"를
        // 잡는 자리다 — SAML SSO 미승인이면 200과 403 사이에서 조용히 갈린다.
        let wantOrg = (inst?.fields["org"] ?? "").trimmingCharacters(in: .whitespaces)
        if !wantOrg.isEmpty {
            let lower = wantOrg.lowercased()
            var status = ""
            var note = ""
            if orgLogins.contains(where: { $0.lowercased() == lower }) {
                status = "member"
                note = "조직 멤버십이 확인됩니다"
            } else if ownerRows.contains(where: { (($0["login"] as? String) ?? "").lowercased() == lower }) {
                status = "repos"
                note = "이 조직의 레포에 닿습니다 (조직 자체를 읽을 권한은 없습니다)"
            } else {
                // 마지막으로 조직 레포를 직접 찔러 본다 — SSO 미승인은 여기서만 드러난다.
                let (pCode, _, pHeaders) = httpAny(
                    "https://api.github.com/orgs/\(wantOrg)/repos?per_page=1", headers: hdrs)
                let sso = pHeaders["x-github-sso"] ?? ""
                if !sso.isEmpty {
                    status = "sso"
                    note = "SAML SSO 승인이 필요합니다 — 토큰 설정 페이지에서 이 조직에 'Authorize' 하세요"
                } else if pCode == 200 {
                    status = "public"
                    note = "공개 레포만 보입니다 — 이 조직의 비공개 레포에는 닿지 않습니다"
                } else if pCode == 404 {
                    status = "none"
                    note = "이 토큰으로는 조직이 보이지 않습니다 — 조직 이름 또는 resource owner를 확인하세요"
                } else {
                    status = "none"
                    note = "조직 접근을 확인하지 못했습니다 (http \(pCode))"
                }
                warnings.append("\(wantOrg): \(note)")
            }
            out["org"] = ["login": wantOrg, "status": status, "note": note]
        }

        // ----- 커밋 서명 -----
        out["signing"] = githubSigning(hdrs: hdrs)

        out["warning"] = warnings.joined(separator: " · ")
        return out
    }

    // 커밋 서명 — "서명까지 되는가"에 답하려면 두 쪽을 다 봐야 한다. 계정에 서명 키가
    // 등록돼 있어야 깃허브가 Verified 를 붙이고, 이 맥의 git 이 실제로 서명을 켜 두고
    // 있어야 서명된 커밋이 나간다. 둘 중 하나만 보면 늘 반쪽 답이 된다.
    private static func githubSigning(hdrs: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        var gpgIds: [String] = []
        var sshKeys: [String] = []
        var notes: [String] = []

        let (gCode, gAny, _) = httpAny("https://api.github.com/user/gpg_keys?per_page=100", headers: hdrs)
        if gCode == 200, let rows = gAny as? [[String: Any]] {
            gpgIds = rows.compactMap { $0["key_id"] as? String }
            // 서브키로 서명하는 설정이 흔하다 — 부모 키만 보면 일치를 놓친다.
            for row in rows {
                for sub in (row["subkeys"] as? [[String: Any]]) ?? [] {
                    if let id = sub["key_id"] as? String { gpgIds.append(id) }
                }
            }
        } else if gCode == 403 || gCode == 404 {
            notes.append("GPG 키 목록을 읽을 권한이 없습니다 (classic은 read:gpg_key · fine-grained는 계정 권한 'GPG keys' 읽기)")
        }
        let (sCode, sAny, _) = httpAny("https://api.github.com/user/ssh_signing_keys?per_page=100", headers: hdrs)
        if sCode == 200, let rows = sAny as? [[String: Any]] {
            sshKeys = rows.compactMap { $0["key"] as? String }
        } else if sCode == 403 || sCode == 404 {
            notes.append("SSH 서명 키 목록을 읽을 권한이 없습니다 (classic은 read:ssh_signing_key · fine-grained는 계정 권한 'SSH signing keys' 읽기)")
        }
        out["gpgCount"] = gpgIds.isEmpty ? 0 : Set(gpgIds).count
        out["sshCount"] = sshKeys.count
        out["keysReadable"] = (gCode == 200 || sCode == 200)

        // 이 맥의 전역 git 설정. 레포마다 로컬로 덮어쓸 수 있으므로 화면은 그 사실을
        // 함께 말한다 — 여기서 "모든 레포가 서명된다"고 단정하면 틀린다.
        let cfg = gitGlobalConfig()
        let format = (cfg["gpg.format"] ?? "openpgp").lowercased()
        let signOn = ["true", "1", "yes"].contains((cfg["commit.gpgsign"] ?? "").lowercased())
        let signingKey = cfg["user.signingkey"] ?? ""
        out["local"] = ["format": format, "sign": signOn, "key": maskKey(signingKey),
                        "email": cfg["user.email"] ?? "", "name": cfg["user.name"] ?? ""]

        // 로컬 키가 계정에 등록된 키와 같은가 — 이게 맞아야 Verified 가 붙는다.
        var matched: Bool? = nil
        if !signingKey.isEmpty {
            if format == "ssh" {
                let body = sshKeyBody(signingKey)
                if !body.isEmpty, sCode == 200 {
                    matched = sshKeys.contains { sshKeyBody($0) == body }
                }
            } else if gCode == 200 {
                let want = signingKey.uppercased()
                    .replacingOccurrences(of: "0X", with: "")
                matched = gpgIds.contains { want.hasSuffix($0.uppercased()) || $0.uppercased().hasSuffix(want) }
            }
        }
        if let matched { out["matched"] = matched }

        var verdict: String
        if !signOn {
            verdict = "이 맥의 git 은 커밋 서명이 꺼져 있습니다 (commit.gpgsign 미설정)"
        } else if signingKey.isEmpty {
            verdict = "서명은 켜져 있지만 user.signingkey 가 없습니다 — 커밋이 실패할 수 있습니다"
        } else if matched == true {
            verdict = "커밋 서명 켜짐 · 이 계정에 등록된 키와 일치합니다 — Verified 로 표시됩니다"
        } else if matched == false {
            verdict = "커밋 서명은 켜져 있지만 이 계정에 등록된 키와 일치하지 않습니다 — Unverified 로 표시됩니다"
        } else {
            verdict = "커밋 서명 켜짐 — 계정 등록 여부는 토큰 권한이 없어 확인하지 못했습니다"
        }
        out["verdict"] = verdict
        out["note"] = notes.joined(separator: " · ")
        return out
    }

    // 전역 git 설정 한 번만 읽는다 (git config --global --list).
    private static func gitGlobalConfig() -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["config", "--global", "--list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<eq]).lowercased()] = String(line[line.index(after: eq)...])
        }
        return out
    }

    // user.signingkey 는 경로일 수도(ssh), 키 본문일 수도 있다. 파일이면 읽어서
    // 본문을 꺼낸다 — 경로만 비교하면 같은 키를 다른 경로로 쓰는 경우를 놓친다.
    private static func sshKeyBody(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("~") {
            text = FileManager.default.homeDirectoryForCurrentUser.path + String(text.dropFirst())
        }
        if text.hasPrefix("/"), let file = try? String(contentsOfFile: text, encoding: .utf8) {
            text = file.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "ssh-ed25519 AAAA… comment" → 가운데 본문만 비교한다 (주석은 기기마다 다르다).
        let parts = text.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    // 화면에 나가는 값이라 경로는 그대로, 키 본문은 앞뒤만 남긴다.
    private static func maskKey(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(" "), text.count > 24 else { return text }
        return String(text.prefix(16)) + "…" + String(text.suffix(6))
    }

    // 만료 헤더는 "2026-12-31 00:00:00 UTC" 또는 ISO 로 온다.
    private static func daysUntil(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let fmts = ["yyyy-MM-dd HH:mm:ss ZZZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd"]
        for f in fmts {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: text) {
                return Int(d.timeIntervalSinceNow / 86400)
            }
        }
        return nil
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

    // 지라 골 — 이슈와 같은 사이트인데 자격증명도 부르는 길도 다르다. Goals는
    // REST에 없어서 OAuth 2.0 (3LO) 앱으로 GraphQL을 부르고, 그 자격증명 세 개는
    // jira-goals 스킬이 키체인에 들고 있다. 앱은 그 값을 쓰지도 보관하지도 않는다.
    //
    // 그래서 이 검사는 두 겹이다. 평소엔 "설 수 있는 상태인가"까지만 본다 —
    // 스킬이 제자리에 있고 자격증명 세 개가 다 있는가, 마지막으로 토큰을 받은 게
    // 언제인가. 사람이 '연결 확인'을 누르면 그때 스킬을 실제로 돌려 토큰이 지금도
    // 통하는지 본다(만료됐으면 그 자리에서 갱신되고, 회전된 새 토큰은 스킬이 저장한다).
    private static let jiraGoalsService = "condition-mate-jira-goals"
    private static let jiraGoalsAccounts = ["client_id", "client_secret", "refresh_token"]

    private static func checkJiraGoals(deep: Bool) -> CheckResult {
        let fm = FileManager.default
        let skill = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/jira-goals", isDirectory: true)
        let script = skill.appendingPathComponent("scripts/goals_client.py")
        let site = jiraGoalsSite(skill)
        var r = CheckResult(state: .missing, account: site)

        guard fm.fileExists(atPath: script.path) else {
            r.error = "jira-goals 스킬을 찾지 못했습니다 — \(script.path) 가 없습니다"
            return r
        }
        let missing = jiraGoalsAccounts.filter {
            !CMKeychain.exists(service: jiraGoalsService, account: $0)
        }
        guard missing.isEmpty else {
            r.error = "키체인(\(jiraGoalsService))에 \(missing.joined(separator: ", "))가 없습니다 — 스킬의 reference/setup.md 절차로 등록하세요"
            return r
        }

        // 스킬이 마지막으로 받아 둔 액세스 토큰의 시각. 파일 안의 토큰은 읽지 않는다 —
        // 언제 발급됐는지만 알면 되고, 그건 파일 시각이 말해 준다.
        var issued = ""
        let cache = skill.appendingPathComponent(".cache/access_token.json")
        if let at = (try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "M월 d일 HH:mm"
            issued = "마지막 토큰 발급 \(f.string(from: at))"
        }

        if !deep {
            r.state = .ok
            r.detail = [site, "자격증명 3종 등록됨", issued]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return r
        }

        guard let py = findCli("python3") else {
            r.state = .fail
            r.error = "python3을 찾지 못했습니다 — 스킬을 실행할 수 없습니다"
            return r
        }
        // scopes: 토큰 안에 실제로 실려 있는 권한을 토큰 자신에게서 읽는다.
        // 캐시된 토큰이 살아 있으면 네트워크를 타지 않고, 만료됐으면 갱신 한 번이 돈다.
        let (code, out, err) = runCli(py, [script.path, "scopes"])
        guard code == 0, let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scopes = obj["scopes"] as? [String], !scopes.isEmpty else {
            r.state = .fail
            let why = (err.isEmpty ? out : err)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            r.error = why.isEmpty ? "골 API 호출이 실패했습니다 (종료 코드 \(code))" : String(why.prefix(160))
            return r
        }
        r.state = .ok
        // 쓰기 스코프가 빠진 토큰은 조회는 되고 업데이트만 조용히 실패한다 —
        // 그 상태를 '연결됨'으로만 두면 나중에 왜 안 써지는지를 여기서 알 수 없다.
        if !scopes.contains("write:goal:goals") { r.missingScopes = ["write:goal:goals"] }
        r.detail = [site, "토큰 유효 · 스코프 \(scopes.count)개", issued]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return r
    }

    // 터미널의 acli. 앱은 자격증명을 들고 있지 않으므로 물어볼 것은 둘뿐이다 —
    // 깔려 있는가, 그리고 로그인돼 있는가. 둘은 다른 상태이고 할 일도 다르다
    // (하나는 설치, 하나는 브라우저 승인). 그래서 한 덩어리로 뭉치지 않는다.
    private static func checkAtlassianCli() -> CheckResult {
        guard let acli = findCli("acli") else {
            return CheckResult(state: .missing,
                               error: "acli를 찾지 못했습니다 — developer.atlassian.com/cloud/acli 의 서명된 바이너리를 ~/.local/bin 에 두세요")
        }
        let (code, out, err) = runCli(acli, ["jira", "auth", "status"])
        let text = (out + "\n" + err)
        // 로그인하지 않은 상태에서 acli는 0이 아닌 코드와 unauthorized를 낸다.
        guard code == 0, !text.lowercased().contains("unauthorized") else {
            return CheckResult(state: .missing, account: acli,
                               error: "acli는 깔려 있지만 로그인돼 있지 않습니다 — 터미널에서 acli jira auth login --web")
        }
        // 출력 형식은 acli 버전에 따라 달라진다 — 파싱해서 뜻을 만들지 않고,
        // 사람이 읽을 수 있는 줄을 그대로 옮긴다. 여기서 형식을 가정하면
        // acli가 한 줄을 바꾸는 날 화면이 조용히 빈칸이 된다.
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t✓✔•-")) }
            .filter { !$0.isEmpty }
        var r = CheckResult(state: .ok, account: acli)
        r.detail = lines.prefix(2).joined(separator: " · ")
        if r.detail.isEmpty { r.detail = "로그인됨" }
        return r
    }

    // 어느 사이트의 골인지는 스킬이 자기 메타데이터에 적어 둔다. 앱 소스에 사이트
    // 주소를 다시 적으면 스킬을 옮겨 붙일 때 두 값이 조용히 어긋난다.
    private static func jiraGoalsSite(_ skill: URL) -> String {
        let md = skill.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: md, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(60) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("site:") else { continue }
            return t.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return ""
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

    // Genspark CLI 로그인 — 바이너리 존재만 보는 claude-cli와 달리, login-info를
    // 실제로 불러 로그인 계정까지 확인한다. 앱은 키를 들고 있지 않다 — gsk 자신의
    // ~/.genspark-tool-cli/config.json 세션을 그 자리에서 빌려 볼 뿐이다.
    private static func checkGensparkCli() -> CheckResult {
        guard let gsk = findCli("gsk") else {
            return CheckResult(state: .missing,
                               error: "gsk CLI를 찾지 못했습니다 — npm i -g @genspark/cli 후 gsk login")
        }
        let (code, out, err) = runCli(gsk, ["login-info"])
        guard code == 0, let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["status"] as? String) == "ok",
              let info = obj["data"] as? [String: Any] else {
            let why = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return CheckResult(state: .missing,
                               error: why.isEmpty ? "gsk에 로그인돼 있지 않습니다 — 터미널에서 gsk login"
                                                  : String(why.prefix(160)))
        }
        let email = (info["email"] as? String) ?? ""
        let plan = (info["plan"] as? String) ?? ""
        var detail = [email, plan].filter { !$0.isEmpty }.joined(separator: " · ")
        if let credit = info["credit_balance"] as? Double {
            detail += (detail.isEmpty ? "" : " · ") + "크레딧 \(Int(credit))"
        }
        return CheckResult(state: .ok, account: email, detail: detail)
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
        let (code, json, hdrs) = httpAny(url, method: method, headers: headers, body: body)
        return (code, json as? [String: Any], hdrs)
    }

    // 같은 호출인데 최상위가 배열인 응답용 (깃허브의 목록 API는 전부 배열이다).
    private static func httpAny(_ url: String, method: String = "GET",
                                headers: [String: String] = [:], body: String = "{}")
        -> (code: Int, json: Any?, headers: [String: String]) {
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
        var body: Any?
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
            if let data = data { body = try? JSONSerialization.jsonObject(with: data) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return (code, body, respHeaders)
    }
}
