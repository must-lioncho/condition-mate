import Foundation

// MCP 호스트 — 같은 연동이 붙어야 하는 곳이 하나가 아니라는 사실을 담는 자리.
//
// 왜 생겼나: 이 앱은 오랫동안 "등록됨"을 ~/.claude.json 하나로 판정했다. 그런데
// 실제로 쓰는 도구는 하나가 아니다 — 노션을 Claude Code에 붙여 놓고 코덱스로
// 넘어가면 거기엔 없다. 화면은 초록불인데 코덱스 세션에는 도구가 없으니, 사용자는
// "연결했는데 왜 안 보이지"에서 멈춘다. 붙은 곳과 안 붙은 곳을 한 줄에 나란히
// 보여주지 않으면 이 질문에 답할 자리가 화면에 없다.
//
// 여기 있는 것은 "어디를 봐야 하는가"와 "거기엔 무엇이 있는가"뿐이다. 읽기 전용이다 —
// 등록·해제는 MCPRegistrar 가 한다.
public enum MCPHosts {

    // 이 맥에서 MCP 서버가 앉을 수 있는 곳 하나.
    public struct Host {
        public let id: String        // 안정 키 — 화면·JSON이 이 id로 서로를 가리킨다
        public let name: String      // 사람이 부르는 이름 ("Claude Code")
        public let configPath: String
        // 설정 파일이 있는가. 없으면 "등록 안 됨"이 아니라 "이 맥에 없음"이다 —
        // 둘을 같은 회색으로 그리면, 안 쓰는 도구가 늘 빨간불로 남는다.
        public let present: Bool
        // 앱이 여기에 등록·해제할 수 있는가. false면 화면은 상태만 보여주고
        // 스위치를 그리지 않는다 (여기서 못 고치는 것을 고칠 수 있는 것처럼
        // 그리면, 눌러 보고 아무 일도 안 일어나는 자리가 된다).
        public let managed: Bool
        // 이 홈이 로그인 계정 하나에 매여 있는가. 매여 있으면 연동도 그 계정의
        // 것이고, 계정을 여럿이 나눠 쓰면 연동과 흔적이 함께 공유된다.
        public let accountScoped: Bool
        // 그 사실이 뜻하는 바 한 줄. 문장을 여기 두는 이유는 화면이 조건을 보고
        // 문장을 조립하기 시작하면, 같은 사실이 화면마다 다르게 적히기 때문이다.
        public let caution: String

        public init(id: String, name: String, configPath: String, present: Bool,
                    managed: Bool, accountScoped: Bool = false, caution: String = "") {
            self.id = id
            self.name = name
            self.configPath = configPath
            self.present = present
            self.managed = managed
            self.accountScoped = accountScoped
            self.caution = caution
        }
    }

    // 설정에서 읽어 낸 서버 한 줄.
    public struct Server {
        public let name: String      // 그 설정에 적힌 이름
        public let scope: String     // "사용자" / "프로젝트" — 클로드만 나뉜다
        public let target: String    // 실제로 붙는 곳 (url 또는 명령줄)
    }

    // MARK: 주의사항

    // 이 기능 전체가 사람에게 처음 알려야 하는 사실 한 줄. "연결"이라는 말이 한 번으로
    // 끝나는 일처럼 들리는 것이 문제의 출발점이다 — 실제로는 클라이언트마다 따로다.
    // 인스턴스 줄의 회색 칩만으로는 그 이유를 알 수 없어서, 목록 위에 한 번 적어 둔다.
    public static let perClientNote =
        "MCP 연동은 클라이언트마다 따로 붙습니다. 여기서 켜는 것은 Claude Code 하나뿐이고, "
        + "Codex 같은 다른 도구에서 같은 도구를 쓰려면 그 도구에서 한 번 더 연결해야 합니다."

    // MARK: 호스트 목록

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static let claudeCodeId = "claude-code"
    public static let codexId = "codex"
    public static let claudeDesktopId = "claude-desktop"

    private static func path(_ rel: String) -> String {
        home.appendingPathComponent(rel).path
    }

    // 순서가 곧 화면 순서다. 앱이 등록할 수 있는 곳(Claude Code)을 먼저 둔다 —
    // 사용자가 스위치를 누를 자리가 첫 칸이어야 무엇을 하면 되는지가 보인다.
    public static func hosts() -> [Host] {
        let fm = FileManager.default
        let claude = path(".claude.json")
        let desktop = path("Library/Application Support/Claude/claude_desktop_config.json")
        var out = [
            Host(id: claudeCodeId, name: "Claude Code", configPath: claude,
                 present: fm.fileExists(atPath: claude), managed: true),
        ]
        out += codexHosts()
        out.append(Host(id: claudeDesktopId, name: "Claude 앱", configPath: desktop,
                        present: fm.fileExists(atPath: desktop), managed: false))
        return out
    }

    // 코덱스가 사는 곳은 하나가 아니다 — 여기서 틀리면 화면이 조용히 거짓말을 한다.
    //
    // 처음엔 ~/.codex/config.toml 하나만 봤는데, 이 맥의 코덱스는 거기에 쓰지 않는다.
    // 계정마다 홈이 따로 있고(codex-accounts/<계정>/home), MCP 자격증명도 그 계정에
    // 매여 있다. 그래서 ~/.codex 만 읽으면 "코덱스 0개"라고 말하게 되는데, 실제로는
    // 계정 홈에 서버가 붙어 있다. 계정을 나눠서 보여주는 것 자체가 여기서 필요한
    // 정보이기도 하다: 계정 하나를 여럿이 나눠 쓰면 한 사람이 붙인 연동이 나머지
    // 전원에게 그대로 보이고, 남는 흔적도 그 계정 이름이 된다.
    //
    // 이름표는 계정 UUID 앞자리다. 이메일은 auth.json 의 토큰 안에 있고, 그것을
    // 뜯어 읽는 것은 화면에 이름 하나 띄우자고 할 일이 아니다.
    // 계정에 매인 홈이 뜻하는 것. 이 맥에서 코덱스의 MCP 서버와 그 자격증명은
    // ~/.codex 가 아니라 계정 홈에 앉는다 — 즉 연동은 사람이 아니라 계정의 것이다.
    // 계정 하나를 여럿이 나눠 쓰는 것은 흔한 일이고, 그때 이 사실이 사고가 된다:
    // 한 사람이 붙이면 나머지 전원 세션에 그대로 뜨고, 그 연동이 밖에 남기는
    // 흔적(코멘트·편집)도 전부 그 계정 이름이라 누가 한 일인지 구분되지 않는다.
    private static let accountCaution =
        "이 연동은 사람이 아니라 Codex 계정에 붙습니다 — 계정을 여럿이 나눠 쓰면 한 사람이 "
        + "연결한 것이 전원 세션에 그대로 뜨고, 노션 같은 곳에 남는 코멘트·편집도 그 계정 "
        + "이름으로 남아 누가 한 일인지 구분되지 않습니다."

    private static func codexHosts() -> [Host] {
        let fm = FileManager.default
        var out: [Host] = []
        var seen = Set<String>()

        // 이름표와 id는 언제나 경로에서 뽑는다. 같은 홈이 환경변수로 들어올 때와
        // 탐색으로 찾을 때 서로 다른 id를 갖게 되면, 화면이 같은 것을 두 물건으로
        // 부르게 된다.
        func label(_ dir: String) -> (id: String, name: String, acct: Bool, caution: String) {
            let parts = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
            if let i = parts.firstIndex(of: "codex-accounts"), i + 1 < parts.count {
                let short = String(parts[i + 1].prefix(8))
                return ("\(codexId)-acct-\(short)", "Codex · 계정 \(short)", true, accountCaution)
            }
            if parts.contains("codex-runtime-home") {
                return ("\(codexId)-runtime", "Codex · 공용 런타임", true, accountCaution)
            }
            return (codexId, "Codex CLI", false, "")
        }

        func add(_ dir: String) {
            let cfg = URL(fileURLWithPath: dir).appendingPathComponent("config.toml").path
            let real = URL(fileURLWithPath: cfg).resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: cfg), seen.insert(real).inserted else { return }
            let l = label(dir)
            out.append(Host(id: l.id, name: l.name, configPath: cfg, present: true,
                            managed: false, accountScoped: l.acct, caution: l.caution))
        }

        // 지금 이 프로세스에 잡혀 있는 홈이 있으면 그것이 먼저다 (터미널에서 띄운
        // 경우). GUI 앱에는 대개 안 잡혀 있어서, 아래 탐색이 실제 경로가 된다.
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
            add(envHome)
        }

        let acctRoot = path("Library/Application Support/orca/codex-accounts")
        for acct in ((try? fm.contentsOfDirectory(atPath: acctRoot)) ?? []).sorted() {
            add(URL(fileURLWithPath: acctRoot).appendingPathComponent("\(acct)/home").path)
        }
        add(path("Library/Application Support/orca/codex-runtime-home/home"))

        // 맨손 설치본(~/.codex). 계정 홈을 이미 찾았고 여기엔 서버가 하나도 없다면
        // 넣지 않는다 — 늘 0개인 줄이 하나 더 있으면 진짜로 비어 있는 계정이 그 옆에
        // 묻힌다. 서버가 하나라도 있으면 쓰고 있다는 뜻이므로 그때는 보여준다.
        let bare = path(".codex")
        if out.isEmpty || !codexServers(URL(fileURLWithPath: bare).appendingPathComponent("config.toml").path).isEmpty {
            add(bare)
        }
        return out
    }

    public static func host(_ id: String) -> Host? {
        hosts().first { $0.id == id }
    }

    // MARK: 서버 읽기

    // 호스트 하나에 등록된 서버 전부. 순서는 이름순으로 고정한다 — 화면이 5초마다
    // 다시 그리는데 순서가 흔들리면 읽는 사람이 같은 줄을 다시 찾아야 한다.
    public static func servers(hostId: String) -> [Server] {
        switch hostId {
        case claudeCodeId:      return claudeServers(path(".claude.json"))
        case claudeDesktopId:   return jsonServers(path("Library/Application Support/Claude/claude_desktop_config.json"), scope: "사용자")
        default:
            // 코덱스는 홈이 여럿이라 id가 고정이 아니다 — 목록에서 자기 설정 경로를
            // 되찾아 읽는다. 모르는 id면 빈 배열이다 (화면이 없는 것을 있다고 말하는
            // 것보다, 못 읽은 것을 0으로 말하는 편이 덜 위험하다).
            guard let h = host(hostId) else { return [] }
            return codexServers(h.configPath)
        }
    }

    public static func names(hostId: String) -> Set<String> {
        Set(servers(hostId: hostId).map { $0.name })
    }

    // MARK: 클로드 (JSON)

    // Claude Code 는 사용자 스코프와 프로젝트 스코프 둘을 들고 있다. 사람이 직접
    // 등록한 서버는 대개 지금 쓰는 프로젝트에 매여 있어서, 사용자 스코프만 읽으면
    // '있는데 없다'가 된다.
    private static func claudeServers(_ p: String) -> [Server] {
        guard let obj = jsonObject(p) else { return [] }
        var out = scan(obj["mcpServers"], scope: "사용자")
        if let projects = obj["projects"] as? [String: Any] {
            for (_, raw) in projects.sorted(by: { $0.key < $1.key }) {
                guard let proj = raw as? [String: Any] else { continue }
                out += scan(proj["mcpServers"], scope: "프로젝트")
            }
        }
        return dedup(out)
    }

    private static func jsonServers(_ p: String, scope: String) -> [Server] {
        guard let obj = jsonObject(p) else { return [] }
        return dedup(scan(obj["mcpServers"], scope: scope))
    }

    private static func jsonObject(_ p: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func scan(_ raw: Any?, scope: String) -> [Server] {
        guard let map = raw as? [String: Any] else { return [] }
        return map.sorted(by: { $0.key < $1.key }).map { name, cfg in
            Server(name: name, scope: scope, target: targetOf(cfg))
        }
    }

    private static func targetOf(_ raw: Any) -> String {
        guard let cfg = raw as? [String: Any] else { return "" }
        if let url = cfg["url"] as? String, !url.isEmpty { return url }
        let cmd = (cfg["command"] as? String) ?? ""
        let args = (cfg["args"] as? [String]) ?? []
        return ([cmd] + args).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // 같은 이름이 두 스코프에 있으면 먼저 만난 것(사용자)을 남긴다 — 세는 것은
    // '붙어 있는가'이지 '몇 군데 적혀 있는가'가 아니다.
    private static func dedup(_ items: [Server]) -> [Server] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.name).inserted }
    }

    // MARK: 코덱스 (TOML)

    // 코덱스 설정은 TOML이고, 이 앱은 TOML 파서를 들이지 않는다. 여기서 읽어야
    // 하는 것은 [mcp_servers.<이름>] 테이블과 그 안의 command/args/url 뿐이라
    // 줄 단위 스캔으로 충분하다. 모르는 문법을 만나면 그 줄을 버리고 넘어간다 —
    // 설정을 고치는 것이 아니라 읽기만 하므로, 틀리게 읽는 것보다 못 읽는 것이 낫다.
    private static func codexServers(_ p: String) -> [Server] {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) else { return [] }
        var out: [(name: String, target: String, cmd: String, args: [String], url: String)] = []
        var idx: [String: Int] = [:]
        var current: String? = nil     // 지금 읽고 있는 서버 (하위 테이블이면 nil)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                current = nil
                guard let close = line.firstIndex(of: "]") else { continue }
                var header = String(line[line.index(after: line.startIndex)..<close])
                // [[a.b]] 같은 배열 테이블은 여기 쓰이지 않는다 — 남은 대괄호만 턴다.
                header = header.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = tomlKeyParts(header)
                // mcp_servers.<이름> 딱 두 칸일 때만 서버다. 세 칸이면 그 서버의
                // 하위 테이블(env 등)이라 새 서버가 아니고, 여기서 읽을 것도 없다.
                guard parts.count == 2, parts[0] == "mcp_servers" else { continue }
                let name = parts[1]
                if idx[name] == nil {
                    idx[name] = out.count
                    out.append((name, "", "", [], ""))
                }
                current = name
                continue
            }
            guard let name = current, let i = idx[name],
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "command": out[i].cmd = tomlString(val)
            case "url":     out[i].url = tomlString(val)
            case "args":    out[i].args = tomlArray(val)
            default:        break
            }
        }

        return out.sorted { $0.name < $1.name }.map { s in
            let target = !s.url.isEmpty ? s.url
                : ([s.cmd] + s.args).filter { !$0.isEmpty }.joined(separator: " ")
            return Server(name: s.name, scope: "사용자", target: target)
        }
    }

    // TOML 키 경로를 칸으로 나눈다. 따옴표 안의 점은 구분자가 아니다
    // ([mcp_servers."cm-notion.token"] 같은 이름이 통째로 한 칸이어야 한다).
    private static func tomlKeyParts(_ header: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character? = nil
        for ch in header {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "." { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private static func tomlString(_ raw: String) -> String {
        var v = raw
        if let hash = v.firstIndex(of: "#"), !v.hasPrefix("\""), !v.hasPrefix("'") {
            v = String(v[v.startIndex..<hash])
        }
        v = v.trimmingCharacters(in: .whitespaces)
        guard v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" else { return v }
        return String(v.dropFirst().dropLast())
    }

    // 한 줄짜리 배열만 읽는다. 여러 줄로 쓴 args 는 값을 못 읽고 빈 배열이 되는데,
    // 그때 잃는 것은 화면에 보이는 명령줄 한 줄뿐이다 — 서버가 있다는 사실은 남는다.
    private static func tomlArray(_ raw: String) -> [String] {
        guard let open = raw.firstIndex(of: "["), let close = raw.lastIndex(of: "]"), open < close
        else { return [] }
        let inner = String(raw[raw.index(after: open)..<close])
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        for ch in inner {
            if let q = quote {
                if ch == q { out.append(cur); cur = ""; quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; cur = "" }
        }
        return out
    }
}
