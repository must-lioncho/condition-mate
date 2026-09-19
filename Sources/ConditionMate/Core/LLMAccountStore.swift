import Foundation

// MARK: - Multi-LLM Account Store
// Manages accounts across Claude Code, Codex, Antigravity (Gemini), Hermes, etc.
// Maps technical account identifiers (UUIDs, emails, local IDs) to human-readable
// labels like "클로드 계정 1", "클로드 계정 2", "코덱스 계정 1", "안티그라비티 (iris)".
// Persisted in ~/.condition-mate/llm_accounts.json.
final class LLMAccountStore {
    static let shared = LLMAccountStore()

    struct Account: Codable, Equatable {
        var id: String          // e.g. "claude:3189e304-df68-4fff-9f28-70e708b6b1a1"
        var provider: String    // "claude" | "codex" | "antigravity" | "gemini" | "hermes"
        var label: String       // "클로드 계정 1 (mustcompanylevel8)"
        var email: String       // "mustcompanylevel8@gmail.com"
        var org: String         // "mustcompanylevel8@gmail.com's Organization"
        var color: String       // Hex color for badges and chart slices
    }

    struct StoreData: Codable {
        var accounts: [String: Account] = [:]
    }

    private var data = StoreData()
    private let fileURL: URL
    private let lock = NSLock()

    // Default badge colors per provider/index
    private let providerColors: [String: [String]] = [
        "claude": ["#7c3aed", "#2563eb", "#0284c7", "#0d9488"], // purple, blue, sky, teal
        "codex": ["#059669", "#16a34a", "#65a30d"],              // green variants
        "antigravity": ["#ea580c", "#d97706", "#f59e0b"],        // amber/orange
        "gemini": ["#4f46e5", "#6366f1"],
        "hermes": ["#e11d48", "#f43f5e"],
        "glm": ["#fb923c", "#f97316", "#c2410c"]                 // orange — 토큰 뷰의 glm 색과 같다
    ]

    private init() {
        fileURL = AppPaths.base.appendingPathComponent("llm_accounts.json")
        load()
        bootstrapKnownAccounts()
    }

    private func load() {
        guard let raw = try? Foundation.Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoreData.self, from: raw) else { return }
        data = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    // Pre-populate known accounts from ~/.claude.json, ~/.gemini, etc.
    private func bootstrapKnownAccounts() {
        lock.lock()
        defer { lock.unlock() }

        var changed = false
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. Claude: ~/.claude.json oauthAccount
        let claudeJsonURL = home.appendingPathComponent(".claude.json")
        if let d = try? Foundation.Data(contentsOf: claudeJsonURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let oauth = obj["oauthAccount"] as? [String: Any] {
            let uuid = (oauth["accountUuid"] as? String) ?? ""
            let email = (oauth["emailAddress"] as? String) ?? ""
            let org = (oauth["organizationName"] as? String) ?? ""
            if !uuid.isEmpty {
                let id = "claude:" + uuid
                if data.accounts[id] == nil {
                    let shortEmail = email.split(separator: "@").first.map(String.init) ?? email
                    data.accounts[id] = Account(
                        id: id,
                        provider: "claude",
                        label: "클로드 계정 1 (\(shortEmail))",
                        email: email,
                        org: org,
                        color: "#7c3aed"
                    )
                    changed = true
                }
            }
        }

        // 2. Claude: Known secondary account UUID discovered in logs
        let secondaryUUID = "8f4e1744-03d8-4aef-88bc-b12a9841dcc9"
        let secId = "claude:" + secondaryUUID
        if data.accounts[secId] == nil {
            data.accounts[secId] = Account(
                id: secId,
                provider: "claude",
                label: "클로드 계정 2",
                email: "",
                org: "",
                color: "#2563eb"
            )
            changed = true
        }

        // Claude default fallback
        let defClaude = "claude:default"
        if data.accounts[defClaude] == nil {
            data.accounts[defClaude] = Account(
                id: defClaude,
                provider: "claude",
                label: "클로드 기본",
                email: "",
                org: "",
                color: "#6366f1"
            )
            changed = true
        }

        // 3. Codex: default
        let codexId = "codex:local"
        if data.accounts[codexId] == nil {
            data.accounts[codexId] = Account(
                id: codexId,
                provider: "codex",
                label: "코덱스 계정 1",
                email: "",
                org: "",
                color: "#059669"
            )
            changed = true
        }

        // 4. Gemini / Antigravity: ~/.gemini/google_accounts.json
        let geminiAccURL = home.appendingPathComponent(".gemini/google_accounts.json")
        var geminiEmail = "iris@must.company"
        if let gd = try? Foundation.Data(contentsOf: geminiAccURL),
           let gobj = try? JSONSerialization.jsonObject(with: gd) as? [String: Any],
           let act = gobj["active"] as? [String: Any],
           let em = act["email"] as? String, !em.isEmpty {
            geminiEmail = em
        }
        let agyId = "antigravity:" + geminiEmail
        if data.accounts[agyId] == nil {
            data.accounts[agyId] = Account(
                id: agyId,
                provider: "antigravity",
                label: "안티그라비티 (\(geminiEmail.split(separator: "@").first ?? "default"))",
                email: geminiEmail,
                org: "",
                color: "#ea580c"
            )
            changed = true
        }

        // 5. GLM (z.ai): ~/.zai/glm-accounts.json — `zai-key` 가 소유하는 계정 목록.
        // 키는 키체인(service=zai-glm-api)에만 있고 이 파일에는 라벨과 활성 표시만 산다.
        // GLM 창은 glm-claude 가 Claude Code 를 z.ai 엔드포인트로 꺾어 띄운 것이라
        // 트랜스크립트가 ~/.claude/projects 에 섞여 쌓인다. 그래서 계정을 여기서 미리
        // 등록해 두어야 토큰 뷰의 `도구·계정` 줄에 GLM 칩이 뜬다.
        for label in glmLabelsOnDisk() {
            let gid = "glm:" + label
            if data.accounts[gid] == nil {
                let colors = providerColors["glm"] ?? ["#fb923c"]
                let idx = data.accounts.values.filter { $0.provider == "glm" }.count
                data.accounts[gid] = Account(
                    id: gid,
                    provider: "glm",
                    label: "GLM 계정 \(idx + 1) (\(label))",
                    email: "",
                    org: "z.ai",
                    color: colors[idx % colors.count]
                )
                changed = true
            }
        }
        // 목록 파일이 없거나 비어 있어도 GLM 세션은 트랜스크립트에 남을 수 있다.
        let defGLM = "glm:default"
        if data.accounts[defGLM] == nil {
            data.accounts[defGLM] = Account(
                id: defGLM,
                provider: "glm",
                label: "GLM 기본",
                email: "",
                org: "z.ai",
                color: "#c2410c"
            )
            changed = true
        }

        // 6. Hermes: default
        let hermesId = "hermes:nous"
        if data.accounts[hermesId] == nil {
            data.accounts[hermesId] = Account(
                id: hermesId,
                provider: "hermes",
                label: "에르메스 계정 1",
                email: "",
                org: "",
                color: "#e11d48"
            )
            changed = true
        }

        if changed { save() }
    }

    // MARK: - GLM (z.ai)

    // ~/.zai/glm-accounts.json 의 {active, accounts:[{label,added}]} 를 읽는다.
    // 파일이 없으면 빈 결과 — GLM 을 안 쓰는 맥에서도 조용히 지나가야 한다.
    private func glmRegistry() -> (active: String, labels: [String]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zai/glm-accounts.json")
        guard let d = try? Foundation.Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return ("", [])
        }
        let active = (obj["active"] as? String) ?? ""
        let rows = (obj["accounts"] as? [[String: Any]]) ?? []
        let labels = rows.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
        return (active, labels)
    }

    private func glmLabelsOnDisk() -> [String] { glmRegistry().labels }

    // GLM 세션을 어느 계정에 귀속시킬 것인가.
    //
    // 트랜스크립트에는 어느 z.ai 계정으로 돌았는지가 안 적힌다 — glm-claude 는 키를
    // 환경변수로만 넘기고 Claude Code 는 그것을 기록하지 않는다. 그래서 활성 계정으로
    // 귀속한다. 계정이 하나인 동안은 정확하고, 둘 이상이 되면 과거 세션이 지금 활성인
    // 계정으로 몰린다. 정확히 하려면 glm-claude 가 세션에 라벨을 찍어야 한다.
    func activeGLMAccount() -> Account {
        let reg = glmRegistry()
        let label = reg.active.isEmpty ? (reg.labels.first ?? "") : reg.active
        return resolve(provider: "glm", accountId: label.isEmpty ? "default" : label)
    }

    // Resolve or register an account. If a new account UUID is encountered in session
    // transcripts, automatically create a friendly sequential label ("클로드 계정 3" etc).
    func resolve(provider: String, accountId: String, email: String = "", org: String = "") -> Account {
        lock.lock()
        defer { lock.unlock() }

        let cleanId = accountId.isEmpty ? "default" : accountId
        let fullId = "\(provider):\(cleanId)"

        if let existing = data.accounts[fullId] {
            return existing
        }

        // Auto-assign sequential index for this provider
        let providerAccounts = data.accounts.values.filter { $0.provider == provider }
        let nextNum = providerAccounts.count + 1
        let colors = providerColors[provider] ?? ["#64748b"]
        let color = colors[(nextNum - 1) % colors.count]

        let provKorean: String
        switch provider {
        case "claude": provKorean = "클로드"
        case "codex": provKorean = "코덱스"
        case "antigravity": provKorean = "안티그라비티"
        case "gemini": provKorean = "제미나이"
        case "hermes": provKorean = "에르메스"
        case "glm": provKorean = "GLM"
        default: provKorean = provider.capitalized
        }

        // GLM 은 계정 식별자가 UUID 가 아니라 사람이 붙인 라벨(`zai-key add <라벨>`)이라
        // 그 라벨을 그대로 보여 준다 — "GLM 계정 2" 보다 "GLM 계정 2 (lioncho)" 가 낫다.
        if provider == "glm", cleanId != "default" {
            let acc = Account(id: fullId, provider: provider,
                              label: "\(provKorean) 계정 \(nextNum) (\(cleanId))",
                              email: email, org: org.isEmpty ? "z.ai" : org, color: color)
            data.accounts[fullId] = acc
            save()
            return acc
        }

        let labelSuffix = email.isEmpty ? "" : " (\(email.split(separator: "@").first ?? ""))"
        let label = "\(provKorean) 계정 \(nextNum)\(labelSuffix)"

        let newAccount = Account(
            id: fullId,
            provider: provider,
            label: label,
            email: email,
            org: org,
            color: color
        )
        data.accounts[fullId] = newAccount
        save()
        return newAccount
    }

    func setLabel(id: String, label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var acc = data.accounts[id] else { return }
        acc.label = label
        data.accounts[id] = acc
        save()
    }

    func allAccounts() -> [Account] {
        lock.lock()
        defer { lock.unlock() }
        return Array(data.accounts.values).sorted { $0.provider == $1.provider ? $0.label < $1.label : $0.provider < $1.provider }
    }

    func allAccountsJSON() -> String {
        let list = allAccounts()
        let items = list.map { acc -> String in
            "{\"id\":\(jsonString(acc.id)),\"provider\":\(jsonString(acc.provider)),"
            + "\"label\":\(jsonString(acc.label)),\"email\":\(jsonString(acc.email)),"
            + "\"org\":\(jsonString(acc.org)),\"color\":\(jsonString(acc.color))}"
        }
        return "{\"accounts\":[\(items.joined(separator: ","))]}"
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x22: out.append("\\\"")
            case 0x5c: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0c: out.append("\\f")
            case 0x0a: out.append("\\n")
            case 0x0d: out.append("\\r")
            case 0x09: out.append("\\t")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.append(Character(ch))
                }
            }
        }
        out.append("\"")
        return out
    }
}
