import Foundation

// 연동 카탈로그 — 이 앱이 기대는 모든 외부 연동(자격증명·제공자·기능 요구)의
// 단일 원본.
//
// 왜 한곳인가: 예전에는 같은 사실이 네 군데에 손으로 적혀 있었다 — 슬랙 페이지의
// 연동 모달 목록(INT_SECTIONS), SlackIntegrations의 검사 대상, SlackTranslateStore의
// hasKey 호출, 그리고 재발급 안내 문구. 키를 하나 추가하거나 서비스 이름을 고치면
// 네 곳이 조용히 어긋났다. 이제 화면·검사·게이팅이 전부 이 파일을 읽는다.
//
// 여기 있는 것은 "무엇이 필요한가"뿐이다. 실제 값은 키체인(CMKeychain)에,
// 살아있는지 여부는 IntegrationChecks에 있다.

// 연동 방식. 키를 받는 것만 연동이 아니다 — 로그인 세션을 빌려 쓰는 것도 연동이고,
// 그 사실을 화면이 구분해서 보여줘야 "왜 이건 키 칸이 없지?"가 안 생긴다.
public enum AuthKind: String {
    case apiKey       // 키체인에 저장하는 API 키·토큰 (화면에서 입력)
    case cliSession   // 로컬 CLI 로그인 세션 — 키 불필요 (claude 구독)
    case webSession   // 브라우저 로그인 세션 — 키 불필요 (ChatGPT 웹)
    case endpoint     // 로컬 엔드포인트 URL (Ollama 등)
}

// 비밀이 아닌 부가 입력 칸. 지라는 토큰만으로 아무것도 못 한다 — 어느 사이트의
// 누구인지가 있어야 호출이 성립한다. 이런 값은 비밀이 아니므로 키체인이 아니라
// 인스턴스 레지스트리(integrations.json)에 산다.
public struct CredField {
    public let key: String         // 저장 키 ("site", "email")
    public let label: String       // 화면 이름
    public let placeholder: String
    public let required: Bool

    public init(key: String, label: String, placeholder: String, required: Bool = true) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.required = required
    }
}

// 이 자격증명으로 등록할 MCP 서버. 토큰을 받는 것과 "그 토큰으로 Claude 세션에
// 도구를 붙이는 것"은 다른 일이라, 후자를 별도로 적어 둔다 — 없으면 nil.
public struct MCPSpec {
    public let kind: String        // 런처 스크립트가 아는 종류 ("notion"/"github"/"jira")
    public let namePrefix: String  // MCP 서버 이름 접두어 (cm-github-must)
    public let summary: String     // 카드가 보여줄 한 줄 — 무엇이 등록되는가

    public init(kind: String, namePrefix: String, summary: String) {
        self.kind = kind
        self.namePrefix = namePrefix
        self.summary = summary
    }
}

// 같은 서비스에 붙는 서로 다른 인증 경로. 노션은 두 가지가 있고 둘은 다른 물건이다:
// 내부 통합 시크릿(ntn_)은 워크스페이스에 붙는 토큰이라 페이지마다 '연결 추가'를
// 해야 보이고, 브라우저 승인(OAuth)은 로그인한 사람의 권한을 그대로 빌린다.
//
// 이걸 왜 나눴나: 예전에는 토큰 칸 하나뿐이라 "나는 OAuth로 붙이고 싶은데 왜 키를
// 내놓으라고 하지"가 됐다. 방식이 인스턴스의 속성이 되면, 같은 노션 카드 안에
// 토큰 워크스페이스 하나와 OAuth 계정 하나가 나란히 살 수 있다.
public struct AuthOption {
    public let id: String          // 인스턴스에 저장되는 값 ("token"/"oauth")
    public let name: String        // 세그먼트 버튼에 쓰는 이름
    public let desc: String        // 고르기 전에 읽는 한 줄
    public let needsToken: Bool    // 키체인 항목이 필요한가 (false면 토큰 칸을 안 그린다)
    public let mcpKind: String     // 런처 스크립트가 아는 종류
    public let mcpSummary: String  // 무엇이 등록되는가
    public let hint: String        // 방식별 안내 (발급 경로 또는 승인 시점)

    public init(id: String, name: String, desc: String, needsToken: Bool,
                mcpKind: String, mcpSummary: String, hint: String) {
        self.id = id
        self.name = name
        self.desc = desc
        self.needsToken = needsToken
        self.mcpKind = mcpKind
        self.mcpSummary = mcpSummary
        self.hint = hint
    }
}

public struct Credential {
    public let id: String          // 안정 키 — 검사 응답·게이팅이 이 id로 서로를 가리킨다
    public let name: String        // 화면 이름
    public let provider: String    // Provider.id
    public let kind: AuthKind
    public let service: String     // 키체인 service ("" = 키 없는 연동). multi면 접두어.
    public let account: String     // 키체인 account 기본값
    public let role: String        // 이게 없으면 무엇이 죽는지 — 한 줄
    public let placeholder: String // 입력 칸 힌트
    public let valuePrefixes: [String] // 값 형식 검증 접두어 (빈 배열 = 검사 안 함)
    public let issueURL: String    // 발급 페이지
    public let issueHint: String   // 발급 경로 (앱 밖에서 하는 일이라 경로를 적어둔다)
    // 여러 개를 이름 붙여 등록할 수 있는가 — 깃허브 개인/조직별 토큰, 노션 워크스페이스,
    // 지라 사이트. false면 예전과 똑같이 항목 하나뿐이고 키체인 service도 그대로다.
    public let multi: Bool
    public let fields: [CredField] // 비밀이 아닌 추가 입력 칸
    public let mcp: MCPSpec?       // 이 자격증명으로 등록할 MCP 서버 (없으면 nil)
    // 인증 경로가 둘 이상이면 여기 적는다. 비우면 예전과 똑같다 — 토큰 한 갈래.
    public let authOptions: [AuthOption]

    public init(id: String, name: String, provider: String, kind: AuthKind,
                service: String, account: String, role: String, placeholder: String,
                valuePrefixes: [String] = [], issueURL: String, issueHint: String,
                multi: Bool = false, fields: [CredField] = [], mcp: MCPSpec? = nil,
                authOptions: [AuthOption] = []) {
        self.id = id
        self.name = name
        self.provider = provider
        self.kind = kind
        self.service = service
        self.account = account
        self.role = role
        self.placeholder = placeholder
        self.valuePrefixes = valuePrefixes
        self.issueURL = issueURL
        self.issueHint = issueHint
        self.multi = multi
        self.fields = fields
        self.mcp = mcp
        self.authOptions = authOptions
    }

    // 인스턴스가 들고 있는 방식 문자열 → 실제 옵션. 방식을 안 쓰는 자격증명(그리고
    // 이 기능 이전에 만들어진 인스턴스)은 여기서 토큰 옵션으로 합성된다 — 호출부가
    // "옵션이 있으면/없으면"을 매번 나누지 않게 하려는 것.
    public func authOption(_ mode: String) -> AuthOption {
        if let hit = authOptions.first(where: { $0.id == mode }) { return hit }
        if let first = authOptions.first, mode.isEmpty { return first }
        return AuthOption(id: "token", name: "토큰", desc: "",
                          needsToken: true,
                          mcpKind: mcp?.kind ?? "",
                          mcpSummary: mcp?.summary ?? "",
                          hint: issueHint)
    }
}

// 제공자 = 화면의 한 카드. 어느 섹션에 그릴지는 section이 정한다:
//   "llm"    — LLM 연동 (모델 키)
//   "mcp"    — MCP 연동 (Claude 세션이 도구로 쓰는 외부 서비스)
//   "plugin" — 플러그인 카드 안에서만 그린다 (슬랙 토큰)
public struct Provider {
    public let id: String
    public let name: String
    public let desc: String
    public let section: String
    public var isLLM: Bool { section == "llm" }

    public init(id: String, name: String, desc: String, section: String) {
        self.id = id
        self.name = name
        self.desc = desc
        self.section = section
    }
}

// 기능 요구 — "이 기능은 어떤 연동이 살아 있어야 도는가".
//
// 이게 카탈로그에 있는 이유: 슬랙 번역은 Gemini가 기본이고 Claude가 백업인데,
// 그 사실이 데몬 코드 안에만 있으면 화면은 "번역이 안 늘어난다"까지만 보여주고
// 사용자는 무엇을 연동해야 하는지 모른다. 여기 적어두면 플러그인 카드가
// "기본도 백업도 없습니다 — LLM 연동을 해주세요"까지 스스로 말할 수 있다.
public struct Capability {
    public let id: String
    public let name: String
    public let owner: String        // 이 기능을 쓰는 플러그인 id
    public let primary: [String]    // 우선 쓰는 자격증명 id (앞에서부터)
    public let backup: [String]     // 전부 없을 때의 폴백
    public let emptyHint: String    // 기본·백업이 모두 없을 때 사용자에게 할 말
}

public enum IntegrationCatalog {

    // MARK: 제공자

    public static let providers: [Provider] = [
        Provider(id: "anthropic", name: "Claude (Anthropic)",
                 desc: "번역·요약·에이전트 실행. API 키 직통과 CLI 구독 세션 두 가지로 연동합니다.",
                 section: "llm"),
        Provider(id: "gemini", name: "Gemini (Google)",
                 desc: "Flash-Lite·Flash — 슬랙 번역 기본 모델.",
                 section: "llm"),
        Provider(id: "openai", name: "OpenAI · ChatGPT",
                 desc: "API 키 직통, 그리고 스피킹이 쓰는 브라우저 로그인 세션.",
                 section: "llm"),
        Provider(id: "ollama", name: "Ollama (로컬)",
                 desc: "로컬에서 도는 모델 — 키 없이 엔드포인트만 있으면 됩니다.",
                 section: "llm"),
        Provider(id: "slack", name: "Slack",
                 desc: "메시지 수집·답장·리액션 동기화에 쓰는 워크스페이스 토큰.",
                 section: "plugin"),
        // MCP 연동 — 아래 셋은 앱이 직접 부르는 API가 아니라 Claude 세션이 도구로
        // 쓰는 서버다. 토큰은 여기서 받고, 등록은 각 인스턴스의 'MCP 등록' 스위치가 한다.
        Provider(id: "notion", name: "Notion",
                 desc: "페이지·데이터베이스 읽기/쓰기. 워크스페이스마다 통합 토큰을 따로 등록합니다.",
                 section: "mcp"),
        Provider(id: "atlassian", name: "Jira (Atlassian)",
                 desc: "이슈 조회·생성·코멘트. 사이트 주소·계정 이메일과 함께 API 토큰을 등록합니다.",
                 section: "mcp"),
        Provider(id: "github", name: "GitHub",
                 desc: "레포·이슈·PR. 개인 계정과 조직마다 토큰이 다르므로 이름을 붙여 여러 개 등록합니다.",
                 section: "mcp"),
    ]

    public static func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    // MARK: 자격증명

    public static let credentials: [Credential] = [
        // ----- Slack -----
        Credential(id: "slack-user", name: "슬랙 사용자 토큰", provider: "slack", kind: .apiKey,
                   service: "cm-slack-user-token", account: "slack",
                   role: "메시지 수집 · 스레드 답장 · 리액션 동기화 (xoxp-)",
                   placeholder: "xoxp-…", valuePrefixes: ["xoxp-"],
                   issueURL: "https://api.slack.com/apps",
                   issueHint: "api.slack.com/apps > 앱 선택 > OAuth & Permissions > User OAuth Token"),
        Credential(id: "slack-app", name: "슬랙 앱 토큰", provider: "slack", kind: .apiKey,
                   service: "cm-slack-app-token", account: "slack",
                   role: "실시간 수신 Socket Mode 연결 (xapp-)",
                   placeholder: "xapp-…", valuePrefixes: ["xapp-"],
                   issueURL: "https://api.slack.com/apps",
                   issueHint: "api.slack.com/apps > 앱 선택 > Basic Information > App-Level Tokens (connections:write)"),

        // ----- LLM -----
        Credential(id: "gemini-api", name: "Gemini API 키", provider: "gemini", kind: .apiKey,
                   service: "cm-gemini-api-key", account: "gemini",
                   role: "Gemini Flash-Lite · Flash 번역 (슬랙 번역 기본 모델)",
                   placeholder: "AIza…",
                   issueURL: "https://aistudio.google.com/apikey",
                   issueHint: "Google AI Studio > Get API key"),
        Credential(id: "anthropic-api", name: "Claude API 키", provider: "anthropic", kind: .apiKey,
                   service: "cm-anthropic-api-key", account: "anthropic",
                   role: "Claude Haiku API 직통 번역 · API 기반 호출",
                   placeholder: "sk-ant-…", valuePrefixes: ["sk-ant-"],
                   issueURL: "https://console.anthropic.com/settings/keys",
                   issueHint: "Anthropic Console > Settings > API keys"),
        Credential(id: "claude-cli", name: "Claude CLI 구독", provider: "anthropic", kind: .cliSession,
                   service: "", account: "",
                   role: "키 없이 구독 로그인 세션으로 실행 — 번역·에이전트 폴백",
                   placeholder: "",
                   issueURL: "",
                   issueHint: "터미널에서 claude 로그인 (claude 명령이 PATH에 있으면 연동됨)"),
        Credential(id: "openai-api", name: "OpenAI API 키", provider: "openai", kind: .apiKey,
                   service: "cm-openai-api-key", account: "openai",
                   role: "GPT 모델 API 직통 호출",
                   placeholder: "sk-…", valuePrefixes: ["sk-"],
                   issueURL: "https://platform.openai.com/api-keys",
                   issueHint: "OpenAI Platform > API keys"),
        Credential(id: "chatgpt-web", name: "ChatGPT 웹 세션", provider: "openai", kind: .webSession,
                   service: "", account: "",
                   role: "스피킹 — 브라우저 로그인 세션으로 chatgpt.com에 브리핑 주입 (토큰 불필요)",
                   placeholder: "",
                   issueURL: "https://chatgpt.com",
                   issueHint: "브라우저에서 chatgpt.com에 로그인해 두면 됩니다"),
        Credential(id: "ollama-endpoint", name: "Ollama 엔드포인트", provider: "ollama", kind: .endpoint,
                   service: "cm-ollama-endpoint", account: "ollama",
                   role: "로컬 모델 서버 주소 — 비워두면 http://127.0.0.1:11434",
                   placeholder: "http://127.0.0.1:11434", valuePrefixes: ["http"],
                   issueURL: "https://ollama.com",
                   issueHint: "ollama serve 가 도는 주소 (기본 포트 11434)"),

        // ----- MCP 연동 -----
        // 셋 다 multi: 하나로 끝나지 않는다. 깃허브는 개인 계정과 조직마다 토큰이
        // 다르고, 노션은 워크스페이스마다 통합이 따로 있고, 지라는 사이트마다 다르다.
        // 인스턴스 하나 = 키체인 항목 하나 = MCP 서버 하나로 1:1 대응시킨다.
        Credential(id: "notion-token", name: "Notion 통합 토큰", provider: "notion", kind: .apiKey,
                   service: "cm-notion-token", account: "notion",
                   role: "워크스페이스의 페이지·DB 접근 — 통합을 페이지에 연결해야 보입니다",
                   placeholder: "ntn_… 또는 secret_…",
                   valuePrefixes: ["ntn_", "secret_"],
                   issueURL: "https://www.notion.so/profile/integrations",
                   issueHint: "notion.so > 설정 > 통합(Integrations) > 새 내부 통합 > Internal Integration Secret · 그리고 대상 페이지에서 '연결 추가'로 통합을 붙여야 합니다",
                   multi: true,
                   mcp: MCPSpec(kind: "notion", namePrefix: "cm-notion",
                                summary: "@notionhq/notion-mcp-server (npx · stdio)"),
                   // 노션은 붙는 길이 둘이다. 내부 통합 시크릿(=흔히 말하는 PAT)은
                   // 워크스페이스에 매인 토큰이라 페이지마다 통합을 붙여야 보이고,
                   // 브라우저 승인은 노션이 직접 띄우는 원격 서버에 로그인해 붙는다.
                   authOptions: [
                       AuthOption(id: "token", name: "토큰 직접 입력",
                                  desc: "내부 통합 시크릿(ntn_) — 워크스페이스 단위, 만료 없음. 대상 페이지마다 통합을 '연결 추가'해야 보입니다.",
                                  needsToken: true,
                                  mcpKind: "notion",
                                  mcpSummary: "@notionhq/notion-mcp-server (npx · stdio)",
                                  hint: "notion.so > 설정 > 통합(Integrations) > 새 내부 통합 > Internal Integration Secret · 그리고 대상 페이지에서 '연결 추가'로 통합을 붙여야 합니다"),
                       AuthOption(id: "oauth", name: "브라우저 로그인 (OAuth)",
                                  desc: "노션 호스티드 서버에 계정으로 승인 — 키를 붙여넣지 않고, 내 노션 권한을 그대로 씁니다.",
                                  needsToken: false,
                                  mcpKind: "notion-oauth",
                                  mcpSummary: "mcp.notion.com/mcp (OAuth · mcp-remote 경유)",
                                  hint: "붙여넣을 키가 없습니다 — MCP 등록을 켜면 앱이 그 자리에서 서버에 붙어 보고, 승인이 필요하면 브라우저에 노션 로그인 창이 뜹니다"),
                   ]),
        Credential(id: "jira-token", name: "Jira API 토큰", provider: "atlassian", kind: .apiKey,
                   service: "cm-jira-token", account: "atlassian",
                   role: "이슈 조회·생성·코멘트 — 사이트 주소와 계정 이메일이 함께 필요합니다",
                   placeholder: "ATATT… (API 토큰)",
                   issueURL: "https://id.atlassian.com/manage-profile/security/api-tokens",
                   issueHint: "id.atlassian.com > 보안 > API 토큰 만들기 (조직 관리자가 API 토큰 인증을 허용해 둬야 합니다)",
                   multi: true,
                   fields: [
                       CredField(key: "site", label: "사이트 주소", placeholder: "https://회사이름.atlassian.net"),
                       CredField(key: "email", label: "계정 이메일", placeholder: "you@company.com"),
                   ],
                   mcp: MCPSpec(kind: "jira", namePrefix: "cm-jira",
                                summary: "mcp.atlassian.com/v1/mcp (Basic 인증 · mcp-remote 경유)")),
        Credential(id: "github-token", name: "GitHub 토큰", provider: "github", kind: .apiKey,
                   service: "cm-github-token", account: "github",
                   role: "레포·이슈·PR 접근 — 개인 계정과 조직별로 토큰을 따로 등록합니다",
                   placeholder: "github_pat_… 또는 ghp_…",
                   valuePrefixes: ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_"],
                   issueURL: "https://github.com/settings/personal-access-tokens",
                   issueHint: "github.com > Settings > Developer settings > Personal access tokens · 조직 토큰은 그 조직을 resource owner로 골라야 하고 조직 승인이 필요할 수 있습니다",
                   multi: true,
                   mcp: MCPSpec(kind: "github", namePrefix: "cm-github",
                                summary: "api.githubcopilot.com/mcp (Bearer 인증 · mcp-remote 경유)")),
    ]

    public static func credential(_ id: String) -> Credential? { credentials.first { $0.id == id } }

    public static func credentials(provider: String) -> [Credential] {
        credentials.filter { $0.provider == provider }
    }

    // 슬랙 데몬·앱이 실제로 쓰는 사용자 토큰 스코프. 여기 없는 스코프가 빠지면
    // "연결은 되는데 일부 동작만 조용히 실패"가 된다 (2026-07-23 reactions:write
    // 누락으로 처리완료 후 👀가 안 지워지던 문제).
    public static let slackUserScopes = [
        "reactions:read", "reactions:write", "chat:write",
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
    ]

    // MARK: 기능 요구

    // 슬랙 번역의 기본 모델은 사용자가 페이지에서 고른다 — 그래서 primary는
    // 고정 배열이 아니라 선택 모델에 따라 달라진다. 기본 카탈로그는 "둘 중
    // 하나라도 있으면 된다"로 두고, 실제 선택 모델은 IntegrationStore가
    // translationCapability(model:)로 좁혀 준다.
    public static let capabilities: [Capability] = [
        Capability(id: "slack-translate", name: "슬랙 번역",
                   owner: "slack-translate",
                   primary: ["gemini-api", "anthropic-api"],
                   backup: ["claude-cli"],
                   emptyHint: "번역할 LLM이 하나도 연동돼 있지 않습니다 — 아래 LLM 연동에서 Gemini 또는 Claude를 연결하세요."),
        // 지라 번역은 슬랙과 달리 폴백이 없다 — 크롬 익스텐션의 번역 버튼은 사용자가
        // 결과를 기다리는 자리라서, CLI 폴백(5~15초)이면 안 쓰느니만 못하다.
        Capability(id: "jira-translate", name: "지라 번역",
                   owner: "jira-translate",
                   primary: ["gemini-api"],
                   backup: [],
                   emptyHint: "Gemini API 키를 연결하면 지라 화면의 번역 버튼이 동작합니다."),
        Capability(id: "slack-speak", name: "슬랙 스피킹",
                   owner: "slack-translate",
                   primary: ["chatgpt-web"],
                   backup: [],
                   emptyHint: "브라우저에서 chatgpt.com에 로그인해 두면 스피킹이 동작합니다."),
    ]

    public static func capabilities(owner: String) -> [Capability] {
        capabilities.filter { $0.owner == owner }
    }
}
