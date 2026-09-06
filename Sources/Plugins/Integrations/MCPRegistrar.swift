import Foundation

// MCP 서버 등록 — 앱이 받아 둔 토큰을 Claude 세션이 도구로 쓰게 만드는 다리.
//
// 핵심 결정: 등록한 설정 파일(~/.claude.json)에 비밀값을 넣지 않는다.
//
// 보통의 MCP 클라이언트는 토큰을 설정 JSON에 그대로 적는다 (env·headers). 이 앱은
// 그렇게 하지 않는다 — 이미 모든 비밀값이 키체인 한곳에 있고, 같은 토큰을 평문
// JSON으로 한 벌 더 복사해 두면 (1) 키를 바꿀 때 두 곳을 고쳐야 하고 (2) 사용자가
// 앱에서 삭제해도 옛 토큰이 파일에 남는다. 그래서 설정에는 '이 키체인 항목을 읽어
// 서버를 띄우라'는 런처만 적고, 실제 값은 서버가 뜨는 순간 키체인에서 읽는다.
//
// argv에도 남기지 않는다: 원격 서버(github·jira)는 mcp-remote 를 거치는데, 헤더 값에
// ${AUTH_HEADER} 를 그대로 넘기면 mcp-remote 가 자기 환경변수에서 치환한다. 토큰이
// 명령줄에 실리지 않으므로 `ps` 에 보이지 않는다.
//
// 등록 자체는 claude CLI(`claude mcp add-json/remove --scope user`)로 한다.
// ~/.claude.json 은 Claude Code 가 소유한 파일이고 여러 세션이 동시에 고쳐 쓴다 —
// 앱이 직접 써 넣으면 남의 쓰기를 덮어쓸 수 있다. 읽기(등록 상태 확인)만 파일에서 한다.
public enum MCPRegistrar {

    public struct Result {
        public let ok: Bool
        public let error: String
        public let name: String
    }

    // MARK: 경로

    private static var dataDir: URL {
        ProcessInfo.processInfo.environment["CM_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".condition-mate", isDirectory: true)
    }

    public static var launcherPath: String {
        dataDir.appendingPathComponent("mcp/cm-mcp-launch.sh").path
    }

    // MCP 서버 이름 — 인스턴스와 1:1. 접두어 cm- 이 붙어 있어 사용자가 직접 등록한
    // 서버와 섞이지 않는다 (앱이 지울 때 남의 서버를 지우지 않기 위한 안전선이기도 하다).
    public static func serverName(_ cred: Credential, _ inst: CredInstance) -> String {
        guard let spec = cred.mcp else { return "" }
        return "\(spec.namePrefix)-\(inst.key)"
    }

    // MARK: 런처

    // 런처 스크립트. 매 등록마다 최신 내용으로 다시 쓴다 — 앱을 업데이트했는데 예전
    // 스크립트가 남아 조용히 다른 서버를 띄우는 상황을 없앤다.
    private static let launcherBody = """
    #!/bin/sh
    # ConditionMate MCP 런처 — 앱이 자동 생성합니다 (직접 고치지 마세요).
    #
    # 사용: cm-mcp-launch.sh <kind> <keychain-service> <keychain-account> [extra...]
    # 비밀값은 인자로 받지 않는다. 여기서 키체인을 읽어 환경변수로만 넘긴다.
    set -e
    # GUI에서 뜬 Claude 프로세스는 PATH가 좁다 — node/npx가 사는 곳을 앞에 붙인다.
    PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    export PATH

    kind="$1"
    svc="$2"
    acct="$3"
    shift 3 || exit 64

    # OAuth 종류는 키체인을 쓰지 않는다 — 승인 토큰은 mcp-remote 가 ~/.mcp-auth 에
    # 들고 있고, 없으면 자기가 브라우저를 열어 받아 온다. 여기서 키를 요구하면
    # 붙을 수 있는 서버가 exit 69 로 죽는다.
    case "$kind" in
      *-oauth)
        token=""
        ;;
      *)
        if [ "$acct" = "-" ]; then
          token=$(/usr/bin/security find-generic-password -w -s "$svc" 2>/dev/null || true)
        else
          token=$(/usr/bin/security find-generic-password -w -s "$svc" -a "$acct" 2>/dev/null || true)
        fi
        if [ -z "$token" ]; then
          echo "cm-mcp-launch: 키체인 항목 $svc 를 읽지 못했습니다 (앱의 플러그인 > 연동에서 토큰을 다시 저장하세요)" >&2
          exit 69
        fi
        ;;
    esac

    case "$kind" in
      notion)
        NOTION_TOKEN="$token"
        export NOTION_TOKEN
        exec npx -y @notionhq/notion-mcp-server
        ;;
      notion-oauth)
        # 노션이 직접 띄우는 원격 서버. 첫 실행 때 mcp-remote 가 브라우저 승인 창을
        # 열고, 그 뒤로는 저장된 승인을 재사용한다.
        exec npx -y mcp-remote https://mcp.notion.com/mcp
        ;;
      github)
        # 헤더 값은 mcp-remote 가 자기 환경에서 치환한다 — argv에 토큰이 남지 않게.
        AUTH_HEADER="Bearer $token"
        export AUTH_HEADER
        exec npx -y mcp-remote https://api.githubcopilot.com/mcp/ --header 'Authorization:${AUTH_HEADER}'
        ;;
      github-oauth)
        # GitHub은 mcp-remote 가 즉석으로 자기 자신을 등록(dynamic client
        # registration)하는 걸 허용하지 않는다 — 그래서 직접 만든 OAuth App의
        # client_id/secret을 미리 쥐어 줘야 승인 화면까지 갈 수 있다. 그 값은
        # 'cm-github-oauth-app' 자격증명 키체인 항목에 "id:secret" 한 줄로 있다
        # (서비스 이름은 $1로 넘어온다 — svc 칸은 이 kind에서 안 쓴다).
        app_svc="$1"
        if [ -z "$app_svc" ]; then
          echo "cm-mcp-launch: GitHub OAuth App 정보가 없습니다 (연동 페이지 > GitHub OAuth App 에 Client ID:Secret을 먼저 저장하세요)" >&2
          exit 64
        fi
        app_info=$(/usr/bin/security find-generic-password -w -s "$app_svc" 2>/dev/null || true)
        if [ -z "$app_info" ]; then
          echo "cm-mcp-launch: 키체인 항목 $app_svc 를 읽지 못했습니다 (GitHub OAuth App 연동에서 값을 다시 저장하세요)" >&2
          exit 69
        fi
        case "$app_info" in
          *:*) ;;
          *)
            echo "cm-mcp-launch: GitHub OAuth App 값 형식이 잘못됐습니다 — 'Client ID:Client Secret' 형태로 다시 저장하세요" >&2
            exit 69
            ;;
        esac
        client_id="${app_info%%:*}"
        client_secret="${app_info#*:}"
        # JSON을 argv에 남기지 않으려고(ps에 secret이 안 보이게) 임시 파일로 넘긴다.
        # set -e 아래서 npx가 비정상 종료하면(인증 실패·중단 등) 뒷정리 코드가 통째로
        # 건너뛰어지므로, 실행 후 지우려 하지 않는다 — 0600 권한으로 $TMPDIR에 두고
        # exec로 넘긴다(다른 kind들과 같은 패턴). macOS가 주기적으로 비운다.
        info_file="$(mktemp "${TMPDIR:-/tmp}/cm-gh-oauth.XXXXXX")"
        chmod 600 "$info_file"
        printf '{"client_id":"%s","client_secret":"%s"}' "$client_id" "$client_secret" > "$info_file"
        # 포트는 고정이어야 한다 — GitHub OAuth App의 Authorization callback URL이
        # 이 포트로 정확히 등록돼 있어야 승인 리다이렉트가 돌아온다.
        exec npx -y mcp-remote https://api.githubcopilot.com/mcp/ 33417 --static-oauth-client-info "@$info_file"
        ;;
      jira)
        email="$1"
        if [ -z "$email" ]; then
          echo "cm-mcp-launch: 지라는 계정 이메일이 필요합니다" >&2
          exit 64
        fi
        AUTH_HEADER="Basic $(printf '%s:%s' "$email" "$token" | base64 | tr -d '\\n')"
        export AUTH_HEADER
        exec npx -y mcp-remote https://mcp.atlassian.com/v1/mcp --header 'Authorization:${AUTH_HEADER}'
        ;;
      *)
        echo "cm-mcp-launch: 알 수 없는 종류 $kind" >&2
        exit 64
        ;;
    esac
    """

    @discardableResult
    public static func writeLauncher() -> Bool {
        let url = URL(fileURLWithPath: launcherPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? launcherBody.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        // 0700 — 이 스크립트는 키체인을 읽는다. 다른 사용자가 실행할 수 있으면 안 된다.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return true
    }

    // MARK: 등록·해제

    // 인스턴스 하나를 MCP 서버로 등록한다. 이미 같은 이름이 있으면 지우고 다시 넣는다
    // (add-json 은 중복 이름을 거부하고, 그 실패가 사용자에겐 '왜 안 켜지지'로만 보인다).
    public static func register(cred: Credential, inst: CredInstance) -> Result {
        guard let spec = cred.mcp else {
            return Result(ok: false, error: "이 연동은 MCP 서버가 없습니다", name: "")
        }
        let name = serverName(cred, inst)
        guard !name.isEmpty else { return Result(ok: false, error: "서버 이름을 만들 수 없습니다", name: "") }
        guard let claude = claudePath() else {
            return Result(ok: false, error: "claude CLI를 찾지 못했습니다 — 터미널에서 claude 로그인 후 다시 시도하세요", name: name)
        }
        guard writeLauncher() else {
            return Result(ok: false, error: "런처 스크립트를 만들지 못했습니다", name: name)
        }
        // 어느 인증 경로로 만든 인스턴스냐에 따라 런처가 띄우는 서버가 다르다
        // (노션 토큰 → 로컬 npx 서버, 노션 OAuth → 원격 mcp.notion.com).
        let opt = cred.authOption(inst.mode)
        let kind = opt.mcpKind.isEmpty ? spec.kind : opt.mcpKind
        // 키체인을 안 읽는 경로에는 service 이름을 넘기지 않는다 — 존재하지도 않는
        // 항목 이름이 설정 파일에 남으면 나중에 읽는 사람이 그게 쓰인다고 오해한다.
        let service = inst.keychainService.isEmpty
            ? CredInstance.service(base: cred.service, key: inst.key) : inst.keychainService
        let account = inst.keychainAccount.isEmpty ? cred.account : inst.keychainAccount
        var args: [String] = [kind, opt.needsToken ? service : "-", opt.needsToken ? account : "-"]
        if kind == "jira" {
            let email = (inst.fields["email"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else {
                return Result(ok: false, error: "계정 이메일을 먼저 입력하세요", name: name)
            }
            args.append(email)
        }
        if kind == "github-oauth" {
            // 이 인스턴스 자신은 토큰이 없다(needsToken: false) — mcp-remote 가
            // GitHub에 자기 자신을 등록할 때 쓰는 앱 자격증명은 별도의
            // github-oauth-app 자격증명 키체인 항목에 있다. 여기선 그 서비스
            // 이름만 넘긴다 — 값은 런처가 뜨는 순간 키체인에서 읽는다.
            guard let appCred = IntegrationCatalog.credential("github-oauth-app") else {
                return Result(ok: false, error: "github-oauth-app 자격증명이 카탈로그에 없습니다", name: name)
            }
            args.append(appCred.service)
        }
        let payload: [String: Any] = [
            "type": "stdio",
            "command": launcherPath,
            "args": args,
            "env": [String: String](),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return Result(ok: false, error: "설정 JSON을 만들지 못했습니다", name: name)
        }
        _ = run(claude, ["mcp", "remove", name, "--scope", "user"])   // 있으면 치우고
        let (code, out) = run(claude, ["mcp", "add-json", name, json, "--scope", "user"])
        guard code == 0 else {
            return Result(ok: false, error: shortError(out, fallback: "claude mcp add-json 실패 (\(code))"), name: name)
        }
        return Result(ok: true, error: "", name: name)
    }

    public static func unregister(cred: Credential, inst: CredInstance) -> Result {
        let name = serverName(cred, inst)
        guard !name.isEmpty else { return Result(ok: false, error: "서버 이름을 만들 수 없습니다", name: "") }
        guard let claude = claudePath() else {
            // CLI가 없으면 지울 방법도 없다 — 다만 사용자가 원한 최종 상태(끄기)는
            // 이미 등록돼 있지 않을 때와 같으므로, 등록 목록에 없으면 성공으로 본다.
            return registeredNames().contains(name)
                ? Result(ok: false, error: "claude CLI를 찾지 못했습니다", name: name)
                : Result(ok: true, error: "", name: name)
        }
        let (code, out) = run(claude, ["mcp", "remove", name, "--scope", "user"])
        if code == 0 || !registeredNames().contains(name) {
            return Result(ok: true, error: "", name: name)
        }
        return Result(ok: false, error: shortError(out, fallback: "claude mcp remove 실패 (\(code))"), name: name)
    }

    // MARK: 등록 상태 (읽기 전용)

    // 지금 실제로 등록돼 있는 서버 이름들 — 앱이 등록하는 곳(Claude Code 사용자
    // 스코프)만 센다. 앱은 --scope user 로만 등록하므로, 여기서 프로젝트 스코프까지
    // 세면 남이 만든 동명의 서버를 앱이 만든 것으로 착각하게 된다.
    // 어디를 어떻게 읽는지는 MCPHosts 가 안다 — claude mcp list 는 서버마다 연결을
    // 시도해서 느리므로(헬스체크), 화면 갱신용으로는 설정 파일을 그대로 읽는다.
    public static func registeredNames() -> Set<String> {
        registeredNames(hostId: MCPHosts.claudeCodeId)
    }

    // 호스트 하나에 등록된, 앱이 만든 서버 이름들. 화면이 "Claude엔 붙었고 코덱스엔
    // 안 붙었다"를 한 줄로 말할 수 있게 하는 값이다.
    public static func registeredNames(hostId: String) -> Set<String> {
        let servers = MCPHosts.servers(hostId: hostId)
        guard hostId == MCPHosts.claudeCodeId else { return Set(servers.map { $0.name }) }
        return Set(servers.filter { $0.scope == "사용자" }.map { $0.name })
    }

    // 앱이 만들지 않은, 같은 곳에 붙는 서버. 사람은 claude mcp add / codex mcp add 로
    // 서버를 직접 등록하고, 그렇게 등록한 것은 대개 지금 쓰는 프로젝트에 매여 있다 —
    // 그래서 사용자 스코프만 읽으면 '있는데 없다'가 된다. MCPHosts 가 두 스코프를 다
    // 훑어 주고, 여기서는 앱이 만든 서버(cm- 접두어)만 뺀다: 이 함수가 답하는 질문은
    // "앱 밖에서 이미 붙어 있는가"이고, 앱이 만든 것은 이름으로 이미 셀 수 있다.
    public struct ExternalServer {
        public let name: String    // 사용자가 붙인 서버 이름 ("atlassian")
        public let scope: String   // "사용자" / "프로젝트"
        public let target: String  // 실제로 붙는 곳 (url 또는 명령줄)
        public let hostId: String  // 어느 클라이언트의 설정에서 나왔는가
        public let hostName: String

        public init(name: String, scope: String, target: String,
                    hostId: String = MCPHosts.claudeCodeId, hostName: String = "Claude Code") {
            self.name = name
            self.scope = scope
            self.target = target
            self.hostId = hostId
            self.hostName = hostName
        }
    }

    // 호스트별로 하나씩. 같은 노션이라도 Claude엔 있고 코덱스엔 없을 수 있고,
    // 사용자가 알고 싶은 것이 정확히 그 차이다.
    public static func externalServers(host: String) -> [ExternalServer] {
        guard !host.isEmpty else { return [] }
        return MCPHosts.hosts().compactMap { h -> ExternalServer? in
            guard let hit = MCPHosts.servers(hostId: h.id).first(where: { s in
                !s.name.hasPrefix("cm-") && s.target.contains(host)
            }) else { return nil }
            return ExternalServer(name: hit.name, scope: hit.scope, target: hit.target,
                                  hostId: h.id, hostName: h.name)
        }
    }

    // 예전 호출부가 쓰던 '하나만' 형태 — 앱이 등록하는 곳을 먼저 본다.
    public static func externalServer(host: String) -> ExternalServer? {
        externalServers(host: host).first
    }

    // MARK: 내부

    // claude 실행 파일 — GUI 앱의 PATH는 좁아서 후보 경로를 먼저 본다
    // (IntegrationChecks.checkClaudeCli 와 같은 사다리).
    private static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let (code, out) = run("/bin/zsh", ["-lc", "command -v claude"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (code == 0 && !path.isEmpty) ? path : nil
    }

    private static func shortError(_ out: String, fallback: String) -> String {
        let line = out.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? fallback : String(line.prefix(160))
    }

    private static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Claude CLI 는 홈의 설정을 고치므로 cwd 는 홈이면 충분하다.
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard (try? p.run()) != nil else { return (-1, "실행 실패: \(exe)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
