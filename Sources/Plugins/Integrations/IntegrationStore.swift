import Foundation

// 연동 상태의 단일 창구. 화면(플러그인 페이지의 연동 목록, 슬랙
// 페이지의 연동 모달)과 게이팅(무엇이 없어서 이 기능이 못 도는가)이 전부 여기를
// 통해 같은 사실을 본다.
//
// 두 단계로 나뉜다:
//   등록 여부(present) — 키체인에 항목이 있는가. 싸다(30초 캐시).
//   실제 연결(state)   — 진짜 API가 받아주는가. 비싸다(사용자가 검사를 누를 때만).
// 화면은 열자마자 등록 여부를 그리고, 검사 결과가 오면 그 위에 덮어쓴다.
public enum IntegrationStore {

    // MARK: 캐시

    private static let lock = NSLock()
    private static var presenceCache: [String: (present: Bool, masked: String, at: Date)] = [:]
    private static var checkCache: [String: (result: CheckResult, at: Date)] = [:]

    private static let presenceTTL: TimeInterval = 30
    private static let checkTTL: TimeInterval = 300   // 화면 재방문 시 재검사 없이 보여줄 창

    // 키체인 항목 존재 + 마스킹 표시. security 프로세스를 띄우므로 캐시한다
    // (플러그인 페이지가 열릴 때마다 6번씩 띄우면 체감이 느려진다).
    // key가 있으면 그 인스턴스의 항목을 본다 (깃허브 조직별 토큰 등).
    private static func presence(_ c: Credential, _ key: String = "") -> (present: Bool, masked: String) {
        let id = key.isEmpty ? c.id : "\(c.id):\(key)"
        // 키가 없는 연동(CLI 세션·웹 세션)은 "등록"이라는 개념이 없다 — 검사 결과로만 판단.
        guard !c.service.isEmpty else {
            let st = cachedCheck(id)?.state
            return (st == .ok || st == .manual, "")
        }
        lock.lock()
        if let hit = presenceCache[id], Date().timeIntervalSince(hit.at) < presenceTTL {
            lock.unlock()
            return (hit.present, hit.masked)
        }
        lock.unlock()
        let masked = CMKeychain.masked(service: CredInstance.service(base: c.service, key: key))
        let present = !masked.isEmpty
        lock.lock(); presenceCache[id] = (present, masked, Date()); lock.unlock()
        return (present, masked)
    }

    // 인스턴스 하나의 '등록됨'. 토큰 방식은 키체인에 항목이 있느냐지만, 브라우저
    // 승인 방식은 앱이 보관하는 값이 아예 없다 — 그쪽의 등록됨은 'MCP 서버로 올라가
    // 있느냐'다. 이 구분을 안 하면 OAuth로 붙인 노션이 영원히 '연동 안 됨'으로 남는다.
    private static func instPresence(_ c: Credential, _ inst: CredInstance,
                                     _ registeredMCP: Set<String>) -> (present: Bool, masked: String) {
        guard c.authOption(inst.mode).needsToken else {
            let name = MCPRegistrar.serverName(c, inst)
            return (!name.isEmpty && registeredMCP.contains(name), "")
        }
        if !inst.keychainService.isEmpty, !inst.keychainAccount.isEmpty {
            return (CMKeychain.exists(service: inst.keychainService, account: inst.keychainAccount), "")
        }
        if c.id == "notion-token" {
            return (CMKeychain.exists(service: CredInstance.service(base: c.service, key: inst.key)), "")
        }
        return presence(c, inst.key)
    }

    // 지금 실제로 등록된 MCP 서버 이름 — ~/.claude.json 을 읽으므로 짧게 캐시한다
    // (페이지가 5초마다 상태를 다시 그린다).
    private static var mcpNamesCache: (names: Set<String>, at: Date)?
    private static func mcpNames() -> Set<String> {
        lock.lock()
        if let hit = mcpNamesCache, Date().timeIntervalSince(hit.at) < 10 {
            lock.unlock(); return hit.names
        }
        lock.unlock()
        let names = MCPRegistrar.registeredNames()
        lock.lock(); mcpNamesCache = (names, Date()); lock.unlock()
        return names
    }

    // 앱이 만들지 않았지만 같은 곳에 붙는 서버. 클라이언트마다 따로 나온다 —
    // 같은 노션이라도 Claude엔 붙어 있고 코덱스엔 없을 수 있고, 사용자가 알고 싶은
    // 것이 정확히 그 차이다. 목록이 5초마다 다시 그려지므로 파일 읽기를 그때마다
    // 하지 않도록 mcpNames 와 같은 창으로 캐시한다.
    private static var externalCache: [String: (hits: [MCPRegistrar.ExternalServer], at: Date)] = [:]
    static func externalServers(_ c: Credential) -> [MCPRegistrar.ExternalServer] {
        guard let host = c.mcp?.externalHost, !host.isEmpty else { return [] }
        lock.lock()
        if let cached = externalCache[host], Date().timeIntervalSince(cached.at) < 10 {
            lock.unlock(); return cached.hits
        }
        lock.unlock()
        let hits = MCPRegistrar.externalServers(host: host)
        lock.lock(); externalCache[host] = (hits, Date()); lock.unlock()
        return hits
    }

    static func externalServer(_ c: Credential) -> MCPRegistrar.ExternalServer? {
        externalServers(c).first
    }

    // 호스트별로 등록된 서버 이름. 인스턴스 한 줄이 "어디에 붙어 있나"를 말하려면
    // 클라이언트 수만큼 설정 파일을 읽어야 하는데, 그것을 인스턴스마다 하면 페이지
    // 한 번 그리는 데 파일을 수십 번 연다 — 한 번 읽어 창을 공유한다.
    private static var hostNamesCache: (map: [String: Set<String>], at: Date)?
    private static func hostNames() -> [String: Set<String>] {
        lock.lock()
        if let hit = hostNamesCache, Date().timeIntervalSince(hit.at) < 10 {
            lock.unlock(); return hit.map
        }
        lock.unlock()
        var map: [String: Set<String>] = [:]
        for h in MCPHosts.hosts() { map[h.id] = MCPRegistrar.registeredNames(hostId: h.id) }
        lock.lock(); hostNamesCache = (map, Date()); lock.unlock()
        return map
    }

    private static func invalidateMCP() {
        lock.lock(); mcpNamesCache = nil; externalCache.removeAll(); hostNamesCache = nil; lock.unlock()
    }

    private static func cachedCheck(_ id: String) -> CheckResult? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = checkCache[id], Date().timeIntervalSince(hit.at) < checkTTL else { return nil }
        return hit.result
    }

    private static func store(_ id: String, _ r: CheckResult) {
        lock.lock(); checkCache[id] = (r, Date()); lock.unlock()
    }

    // 키를 바꾸면 이전 판단은 전부 거짓이 된다 — 캐시를 즉시 버린다.
    private static func invalidate(_ id: String) {
        lock.lock()
        presenceCache.removeValue(forKey: id)
        checkCache.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: 상태 조회 (싸다)

    // 화면이 처음 그릴 때 쓰는 전체 payload. 라이브 호출은 하지 않는다.
    // primaryOverrides: 기능의 '기본' 경로가 사용자 설정에 따라 달라질 때
    // (슬랙 번역 모델 선택) 호출자가 좁혀 준다.
    public static func statusJSON(primaryOverrides: [String: [String]] = [:]) -> String {
        ensureLegacyNotionReference()
        var out = "{\"ok\":true"
        out += ",\"providers\":\(providersJSON())"
        out += ",\"credentials\":\(credentialsJSON())"
        out += ",\"capabilities\":\(capabilitiesJSON(primaryOverrides: primaryOverrides))"
        out += ",\"mcpHosts\":\(mcpHostsJSON())"
        out += ",\"mcpHostNote\":\(esc(MCPHosts.perClientNote))"
        out += ",\"slackUserScopes\":[\(IntegrationCatalog.slackUserScopes.map(esc).joined(separator: ","))]"
        out += "}"
        return out
    }

    private static func ensureLegacyNotionReference() {
        guard IntegrationInstances.all(credId: "notion-token").isEmpty,
              CMKeychain.exists(service: "cm-notion-token") else { return }
        let account = CMKeychain.account(service: "cm-notion-token", fallback: "notion")
        _ = IntegrationInstances.upsert(CredInstance(
            credId: "notion-token", key: "legacy", label: "기존 Notion 연결", mode: "token",
            keychainService: "cm-notion-token", keychainAccount: account))
    }

    // 이 맥에서 MCP 서버가 앉을 수 있는 곳들. 화면 위쪽에 한 줄로 놓여서, 카드를
    // 펼치기 전에 "어디까지 붙일 수 있는 판인가"를 먼저 말한다. 설정 파일이 없는
    // 클라이언트는 '등록 안 됨'이 아니라 '이 맥에 없음'이다 — 둘을 같은 회색으로
    // 그리면 안 쓰는 도구가 늘 빨간불로 남는다.
    private static func mcpHostsJSON() -> String {
        let names = hostNames()
        let items = MCPHosts.hosts().map { h -> String in
            var s = "{\"id\":\(esc(h.id)),\"name\":\(esc(h.name))"
            s += ",\"present\":\(h.present),\"managed\":\(h.managed)"
            s += ",\"accountScoped\":\(h.accountScoped),\"caution\":\(esc(h.caution))"
            s += ",\"configPath\":\(esc(h.configPath))"
            s += ",\"serverCount\":\((names[h.id] ?? []).count)}"
            return s
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private static func providersJSON() -> String {
        let registeredMCP = mcpNames()
        let items = IntegrationCatalog.providers.map { p -> String in
            let creds = IntegrationCatalog.credentials(provider: p.id)
            // 목록에 보일지를 가르는 '연결됨'은 게이팅보다 엄격하다: 사용자가 실제로
            // 등록했거나(키) 검사를 통과한 것만 센다. 브라우저 세션처럼 검증할 수
            // 없는 항목까지 세면, 아무것도 안 한 제공자가 늘 연결된 것처럼 보인다.
            // 다중 인스턴스 자격증명은 인스턴스가 하나라도 등록돼 있으면 연결로 본다.
            // 앱이 등록한 인스턴스가 없어도, 사람이 직접 등록해 둔 같은 서버가 이미
            // 붙어 있으면 그것도 연결이다 — 도구는 이미 세션에 있는데 화면만 '연동
            // 안 됨'이라고 하면, 사용자는 같은 서버를 하나 더 만들게 된다.
            let live = creds.filter { c in
                c.multi ? (IntegrationInstances.all(credId: c.id)
                            .contains { instPresence(c, $0, registeredMCP).present }
                           || externalServer(c) != nil)
                        : registered(c)
            }
            let instCount = creds.reduce(0) { $0 + ($1.multi ? IntegrationInstances.all(credId: $1.id).count : 0) }
            let mcpCount = creds.reduce(0) { acc, c in
                acc + IntegrationInstances.all(credId: c.id)
                    .filter { registeredMCP.contains(MCPRegistrar.serverName(c, $0)) }.count
            }
            var s = "{\"id\":\(esc(p.id)),\"name\":\(esc(p.name)),\"desc\":\(esc(p.desc))"
            s += ",\"isLLM\":\(p.isLLM),\"section\":\(esc(p.section))"
            s += ",\"instanceCount\":\(instCount),\"mcpCount\":\(mcpCount)"
            s += ",\"connected\":\(!live.isEmpty)"
            // 하나만 서 있어도 되는 제공자와, 전부 서야 하는 제공자(지라)를 가른다.
            // full이 false면 붙긴 붙었는데 절반이다 — 그 상태를 '연결됨'이라고
            // 부르면 나머지 절반이 왜 안 되는지 화면 어디서도 알 수 없게 된다.
            s += ",\"liveCount\":\(live.count),\"credCount\":\(creds.count)"
            s += ",\"full\":\(p.requireAll ? live.count == creds.count : !live.isEmpty)"
            // 어떤 방식으로 연결돼 있는지 — "API 키" / "CLI 구독" 같은 한 줄 (중복 제거).
            var seen = Set<String>()
            let vias = live.map { kindLabel($0.kind) }.filter { seen.insert($0).inserted }
            s += ",\"via\":\(esc(vias.joined(separator: " · ")))"
            s += ",\"credentials\":[\(creds.map { esc($0.id) }.joined(separator: ","))]}"
            return s
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private static func credentialsJSON() -> String {
        let registeredMCP = mcpNames()
        let items = IntegrationCatalog.credentials.map { c -> String in
            // 다중 인스턴스 자격증명은 '자기 자신'이 등록될 자리가 없다 — 값은 전부
            // 인스턴스에 있고, 위 칸은 틀(이름·발급 경로)만 설명한다.
            let p = c.multi ? (present: false, masked: "") : presence(c)
            let chk = c.multi ? nil : cachedCheck(c.id)
            var s = "{\"id\":\(esc(c.id)),\"name\":\(esc(c.name)),\"provider\":\(esc(c.provider))"
            s += ",\"kind\":\(esc(c.kind.rawValue)),\"kindLabel\":\(esc(kindLabel(c.kind)))"
            s += ",\"service\":\(esc(c.service)),\"account\":\(esc(c.account))"
            s += ",\"role\":\(esc(c.role)),\"placeholder\":\(esc(c.placeholder))"
            s += ",\"issueURL\":\(esc(c.issueURL)),\"issueHint\":\(esc(c.issueHint))"
            s += ",\"multi\":\(c.multi),\"singleInstance\":\(c.singleInstance)"
            s += ",\"fields\":[\(fieldsJSON(c))]"
            if let m = c.mcp {
                s += ",\"mcp\":{\"kind\":\(esc(m.kind)),\"summary\":\(esc(m.summary))}"
            } else {
                s += ",\"mcp\":null"
            }
            let exts = externalServers(c)
            if let ext = exts.first {
                s += ",\"external\":{\"name\":\(esc(ext.name)),\"scope\":\(esc(ext.scope))"
                s += ",\"target\":\(esc(ext.target)),\"hostId\":\(esc(ext.hostId))"
                s += ",\"hostName\":\(esc(ext.hostName))}"
            } else {
                s += ",\"external\":null"
            }
            // 클라이언트별 전부. 하나만 실으면 "Claude엔 직접 등록해 뒀고 코덱스엔
            // 없다"가 화면에서 사라진다 — 그 차이가 사용자가 여기서 찾는 답이다.
            s += ",\"externals\":[\(exts.map(externalJSON).joined(separator: ","))]"
            s += ",\"authOptions\":[\(authOptionsJSON(c))]"
            s += ",\"instances\":[\(instancesJSON(c, registeredMCP))]"
            s += ",\"present\":\(p.present),\"masked\":\(esc(p.masked))"
            s += ",\"state\":\(esc(chk?.state.rawValue ?? "unknown"))"
            s += ",\"detail\":\(esc(chk?.detail ?? "")),\"error\":\(esc(chk?.error ?? ""))"
            s += ",\"missingScopes\":[\((chk?.missingScopes ?? []).map(esc).joined(separator: ","))]"
            // 인스턴스 없는 자격증명의 상세(gh CLI 로그인의 계정·조직·레포). 이미 JSON.
            let scan = chk?.scan ?? ""
            s += ",\"scan\":\(scan.isEmpty ? "null" : scan)}"
            return s
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private static func externalJSON(_ e: MCPRegistrar.ExternalServer) -> String {
        var s = "{\"name\":\(esc(e.name)),\"scope\":\(esc(e.scope))"
        s += ",\"target\":\(esc(e.target)),\"hostId\":\(esc(e.hostId))"
        s += ",\"hostName\":\(esc(e.hostName))}"
        return s
    }

    // 인증 경로 목록. 하나뿐인 자격증명은 빈 배열로 나가고, 화면은 그때 세그먼트를
    // 그리지 않는다 — 고를 게 없는데 선택지를 보여주면 뭔가 빠진 것처럼 읽힌다.
    private static func authOptionsJSON(_ c: Credential) -> String {
        guard c.authOptions.count > 1 else { return "" }
        return c.authOptions.map { o -> String in
            var s = "{\"id\":\(esc(o.id)),\"name\":\(esc(o.name)),\"desc\":\(esc(o.desc))"
            s += ",\"needsToken\":\(o.needsToken),\"summary\":\(esc(o.mcpSummary))"
            s += ",\"hint\":\(esc(o.hint)),\"caution\":\(esc(o.caution))}"
            return s
        }.joined(separator: ",")
    }

    private static func fieldsJSON(_ c: Credential) -> String {
        c.fields.map { f -> String in
            var s = "{\"key\":\(esc(f.key)),\"label\":\(esc(f.label))"
            s += ",\"placeholder\":\(esc(f.placeholder)),\"required\":\(f.required)"
            s += ",\"tokenOnly\":\(f.tokenOnly)}"
            return s
        }.joined(separator: ",")
    }

    // 서버 이름 하나가 어느 클라이언트에 앉아 있는가. 이름이 비면(=MCP가 없는
    // 자격증명) 빈 배열이고, 화면은 그때 호스트 줄을 통째로 안 그린다.
    private static func hostStatusJSON(_ name: String) -> [String] {
        guard !name.isEmpty else { return [] }
        let names = hostNames()
        return MCPHosts.hosts().map { h in
            var s = "{\"id\":\(esc(h.id)),\"name\":\(esc(h.name))"
            s += ",\"present\":\(h.present),\"managed\":\(h.managed)"
            s += ",\"accountScoped\":\(h.accountScoped),\"caution\":\(esc(h.caution))"
            s += ",\"registered\":\((names[h.id] ?? []).contains(name))}"
            return s
        }
    }

    // 인스턴스 목록 — 화면이 한 줄씩 그릴 수 있는 형태. 앱이 기억하는 '등록해 뒀다'와
    // 실제 claude 설정에 있는지(mcpRegistered)를 따로 싣는다: 사용자가 터미널에서
    // 직접 지웠을 수도 있고, 그럴 때 화면이 '등록됨'이라고 우기면 안 된다.
    private static func instancesJSON(_ c: Credential, _ registeredMCP: Set<String>) -> String {
        IntegrationInstances.all(credId: c.id).map { inst -> String in
            let p = instPresence(c, inst, registeredMCP)
            let chk = cachedCheck(inst.compositeId)
            let name = MCPRegistrar.serverName(c, inst)
            let opt = c.authOption(inst.mode)
            var s = "{\"key\":\(esc(inst.key)),\"label\":\(esc(inst.label))"
            s += ",\"id\":\(esc(inst.compositeId))"
            s += ",\"mode\":\(esc(inst.mode)),\"modeName\":\(esc(opt.name))"
            s += ",\"needsToken\":\(opt.needsToken),\"modeHint\":\(esc(opt.hint))"
            // 붙이는 법(hint)과 붙이고 나면 무엇이 남는가(caution)는 다른 사실이다 —
            // 같은 줄에 섞으면 경고가 안내문에 묻힌다.
            s += ",\"modeCaution\":\(esc(opt.caution))"
            s += ",\"mcpSummary\":\(esc(opt.mcpSummary))"
            s += ",\"fields\":{\(inst.fields.map { "\(esc($0.key)):\(esc($0.value))" }.sorted().joined(separator: ","))}"
            s += ",\"keychainService\":\(esc(inst.keychainService.isEmpty ? CredInstance.service(base: c.service, key: inst.key) : inst.keychainService))"
            s += ",\"keychainAccount\":\(esc(inst.keychainAccount.isEmpty ? c.account : inst.keychainAccount))"
            s += ",\"mcpWanted\":\(inst.mcp),\"mcpName\":\(esc(name))"
            s += ",\"mcpRegistered\":\(!name.isEmpty && registeredMCP.contains(name))"
            // 클라이언트마다 따로. 한 번 연결하면 끝인 것처럼 보이던 자리를 여기서
            // 가른다 — 같은 이름의 서버가 Claude엔 있고 코덱스엔 없으면, 코덱스
            // 세션에는 이 도구가 없다는 뜻이고 화면이 그렇게 말해야 한다.
            s += ",\"hosts\":[\(hostStatusJSON(name).joined(separator: ","))]"
            // 실검사 상태 — 등록됨과 별개다. 지금 돌고 있는 검사가 있으면 그 단계가
            // 마지막 결과를 덮는다 (화면은 그 사이 스피너를 돌린다).
            s += ",\"testedAt\":\(Int(inst.testedAt)),\"testOk\":\(inst.testOk)"
            s += ",\"testNote\":\(esc(inst.testNote)),\"testUrl\":\(esc(inst.testUrl))"
            // 마지막 검사가 알아낸 상세(깃허브: 승인 형태·조직·레포·서명). 이미 JSON
            // 문자열이라 그대로 실는다 — 다시 감싸면 화면에서 두 번 파싱해야 한다.
            s += ",\"scan\":\(inst.scan.isEmpty ? "null" : inst.scan)"
            s += ",\"scannedAt\":\(Int(inst.scannedAt))"
            if let st = MCPProbe.state(inst.compositeId) {
                s += ",\"probe\":{\"phase\":\(esc(st.phase)),\"detail\":\(esc(st.detail))"
                s += ",\"tools\":\(st.tools),\"error\":\(esc(st.error)),\"url\":\(esc(st.url))}"
            } else {
                s += ",\"probe\":null"
            }
            s += ",\"present\":\(p.present),\"masked\":\(esc(p.masked))"
            s += ",\"state\":\(esc(chk?.state.rawValue ?? "unknown"))"
            s += ",\"detail\":\(esc(chk?.detail ?? "")),\"error\":\(esc(chk?.error ?? ""))}"
            return s
        }.joined(separator: ",")
    }

    // 다른 곳(슬랙 페이지의 연동 모달)이 이미 돌린 검사 결과를 레지스트리에 흡수한다.
    // 같은 사실을 두 번 확인하지 않게 하려는 것 — 한쪽에서 검사하면 다른 화면도
    // 그 판단을 그대로 쓴다.
    public static func record(_ results: [String: CheckResult]) {
        for (id, r) in results { store(id, r) }
    }

    // "사용자가 이 연동을 실제로 붙였는가" — 키를 등록했거나 검사를 통과한 것.
    // available()과 달리 '검증할 수 없어서 통과로 치는' 항목(웹 세션)은 세지 않는다.
    private static func registered(_ c: Credential) -> Bool {
        if !c.service.isEmpty { return presence(c).present }
        // 키 없는 연동은 검사가 곧 존재 확인이다 — 로컬 확인이라 싸고, 결과는 캐시된다.
        if let chk = cachedCheck(c.id) { return chk.state == .ok }
        let r = IntegrationChecks.check(c.id)
        store(c.id, r)
        return r.state == .ok
    }

    // 키체인 항목 존재만 (라이브 호출 없음). 5초 폴링이 도는 피드에서 쓴다.
    public static func isPresent(_ credentialId: String) -> Bool {
        guard let c = IntegrationCatalog.credential(credentialId) else { return false }
        return presence(c).present
    }

    // MARK: 기능 게이팅

    // "지금 이 자격증명으로 일을 시킬 수 있는가". 라이브 검사 결과가 있으면 그걸
    // 믿고, 없으면 등록 여부로 판단한다 — 등록돼 있는데 실패한 키를 '있다'로
    // 세면 화면이 "연동은 됐는데 왜 안 돌지"를 만든다.
    public static func available(_ credentialId: String) -> Bool {
        guard let c = IntegrationCatalog.credential(credentialId) else { return false }
        if let chk = cachedCheck(credentialId) {
            return chk.state == .ok || chk.state == .manual
        }
        // 키 없는 연동은 검사가 곧 존재 확인이다 — 싸므로 즉석에서 한 번 돈다.
        if c.service.isEmpty {
            let r = IntegrationChecks.check(credentialId)
            store(credentialId, r)
            return r.state == .ok || r.state == .manual
        }
        return presence(c).present
    }

    // 한 기능이 지금 도는지 + 안 돌면 사용자에게 할 말.
    public static func capabilityJSON(_ cap: Capability, primaryOverrides: [String: [String]] = [:]) -> String {
        let primary = primaryOverrides[cap.id] ?? cap.primary
        let livePrimary = primary.filter { available($0) }
        let liveBackup = cap.backup.filter { available($0) }
        let ok = !livePrimary.isEmpty || !liveBackup.isEmpty
        // 메시지는 셋으로 갈린다: 정상 / 기본은 없고 백업으로 버티는 중 / 아무것도 없음.
        var message = ""
        var level = "ok"
        if livePrimary.isEmpty && liveBackup.isEmpty {
            level = "none"
            message = cap.emptyHint
        } else if livePrimary.isEmpty {
            // 조사(을/를·으로/로)가 이름에 따라 달라지므로 괄호로 감싸 붙인다 —
            // 문자열을 이어 붙이는 순간 "구독로" 같은 문장이 화면에 남는다.
            level = "backup"
            let names = liveBackup.compactMap { IntegrationCatalog.credential($0)?.name }
            message = "기본 연동이 없어 백업(\(names.joined(separator: " · ")))으로 대신 돌고 있습니다 — 느리거나 품질이 다를 수 있습니다."
        } else if liveBackup.isEmpty && !cap.backup.isEmpty {
            // 지금은 돌지만 기본이 끊기면 즉시 멈춘다 — 사용자가 원한 그 경고.
            level = "nobackup"
            let names = cap.backup.compactMap { IntegrationCatalog.credential($0)?.name }
            message = "백업용도 없습니다 — 기본 연동이 끊기면 바로 멈춥니다. 백업 후보: \(names.joined(separator: " · ")) — 함께 연동해 두세요."
        }
        var s = "{\"id\":\(esc(cap.id)),\"name\":\(esc(cap.name)),\"owner\":\(esc(cap.owner))"
        s += ",\"ok\":\(ok),\"level\":\(esc(level)),\"message\":\(esc(message))"
        s += ",\"primary\":[\(primary.map(esc).joined(separator: ","))]"
        s += ",\"backup\":[\(cap.backup.map(esc).joined(separator: ","))]"
        s += ",\"usingPrimary\":[\(livePrimary.map(esc).joined(separator: ","))]"
        s += ",\"usingBackup\":[\(liveBackup.map(esc).joined(separator: ","))]}"
        return s
    }

    public static func capabilitiesJSON(primaryOverrides: [String: [String]] = [:]) -> String {
        let items = IntegrationCatalog.capabilities
            .map { capabilityJSON($0, primaryOverrides: primaryOverrides) }
            .joined(separator: ",")
        return "[\(items)]"
    }

    // MARK: 라이브 검사

    // ids가 비면 전부. 결과는 캐시에 남아 다음 화면 그리기에 그대로 쓰인다.
    public static func checkJSON(ids: [String] = []) -> String {
        let targets = ids.isEmpty ? IntegrationCatalog.credentials.map { $0.id }
                                  : ids.filter { IntegrationCatalog.credential($0) != nil }
        guard !targets.isEmpty else { return "{\"ok\":false,\"error\":\"검사할 항목이 없습니다\"}" }
        let t0 = Date()
        // 사람이 '연결 확인'을 누른 경로 — 여기서만 깊게 본다. 목록을 그리는 쪽은
        // 같은 검사를 얕게 부른다 (지라 골은 깊은 검사가 파이썬 실행이라 비싸다).
        let results = IntegrationChecks.checkAll(targets, deep: true)
        for (id, r) in results { store(id, r) }
        var out = "{\"ok\":true,\"at\":\(Int(Date().timeIntervalSince1970))"
        out += ",\"ms\":\(Int(Date().timeIntervalSince(t0) * 1000))"
        out += ",\"checks\":{"
        out += results.map { id, r -> String in
            var s = "\(esc(id)):{\"state\":\(esc(r.state.rawValue))"
            s += ",\"account\":\(esc(r.account)),\"detail\":\(esc(r.detail)),\"error\":\(esc(r.error))"
            s += ",\"missingScopes\":[\(r.missingScopes.map(esc).joined(separator: ","))]}"
            return s
        }.joined(separator: ",")
        out += "}}"
        return out
    }

    // MARK: 키 등록·해제

    // 대시보드에서 받은 값을 키체인에 저장하고 곧바로 라이브 검사까지 한다 —
    // "저장했습니다"만 말하고 실제로 통하는지 모르면 반쪽이다.
    public static func setKeyJSON(id: String, value: String) -> String {
        let (credId, key) = CredInstance.split(id)
        guard let c = IntegrationCatalog.credential(credId) else {
            return "{\"ok\":false,\"error\":\"알 수 없는 연동 항목\"}"
        }
        guard !c.service.isEmpty else {
            return "{\"ok\":false,\"error\":\"이 연동은 키를 저장하지 않습니다\"}"
        }
        // 다중 인스턴스는 반드시 어느 인스턴스인지가 있어야 한다 — 없으면 접두어 없는
        // 키체인 항목이 하나 생기고, 그건 어느 화면에도 보이지 않는 유령이 된다.
        if c.multi && key.isEmpty {
            return "{\"ok\":false,\"error\":\"인스턴스를 먼저 만들어 주세요\"}"
        }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 형식 접두어 대조 — 슬랙 사용자 토큰 칸에 앱 토큰을 넣는 실수가 가장 흔하고,
        // 그 결과가 "연결은 되는데 이상하게 실패"라 원인을 찾기 어렵다.
        if !c.valuePrefixes.isEmpty, !c.valuePrefixes.contains(where: { v.hasPrefix($0) }) {
            // 조사를 붙이지 않는다 — 이름이 무엇이든 문장이 성립해야 한다
            // ("GitHub 토큰는"처럼 어색해지는 것을 피하려고 이름 뒤에서 문장을 끊는다).
            let list = c.valuePrefixes.joined(separator: " · ")
            return "{\"ok\":false,\"error\":\(esc("\(c.name) — 값이 \(list) 로 시작해야 합니다. 붙여넣은 값을 확인하세요"))}"
        }
        let svc = CredInstance.service(base: c.service, key: key)
        // 기존 항목이 있으면 그 account를 그대로 쓴다 (다르면 항목이 둘 생긴다).
        let account = CMKeychain.account(service: svc, fallback: c.account)
        switch CMKeychain.set(service: svc, account: account, value: v) {
        case .rejected(let why):
            return "{\"ok\":false,\"error\":\(esc(why))}"
        case .failed(let why):
            return "{\"ok\":false,\"error\":\(esc("키체인 저장 실패 — \(why)"))}"
        case .saved:
            invalidate(id)
            let r = IntegrationChecks.check(id)
            store(id, r)
            var out = "{\"ok\":true,\"saved\":true,\"id\":\(esc(id))"
            out += ",\"state\":\(esc(r.state.rawValue)),\"detail\":\(esc(r.detail)),\"error\":\(esc(r.error))"
            out += ",\"missingScopes\":[\(r.missingScopes.map(esc).joined(separator: ","))]"
            out += ",\"masked\":\(esc(CMKeychain.masked(service: svc)))}"
            return out
        }
    }

    public static func clearKeyJSON(id: String) -> String {
        let (credId, key) = CredInstance.split(id)
        guard let c = IntegrationCatalog.credential(credId), !c.service.isEmpty else {
            return "{\"ok\":false,\"error\":\"알 수 없는 연동 항목\"}"
        }
        let ok = CMKeychain.clear(service: CredInstance.service(base: c.service, key: key))
        invalidate(id)
        return ok ? "{\"ok\":true,\"cleared\":true}" : "{\"ok\":false,\"error\":\"키체인 삭제 실패\"}"
    }

    // MARK: Notion Keychain 연결

    public static func notionCandidatesJSON() -> String {
        switch CMKeychain.notionCandidates() {
        case .unavailable(let why):
            return "{\"ok\":false,\"code\":\"keychain_unavailable\",\"error\":\(esc(why))}"
        case .found(let rows):
            let items = rows.map { "{\"service\":\(esc($0.service)),\"account\":\(esc($0.account))}" }
                .joined(separator: ",")
            return "{\"ok\":true,\"candidates\":[\(items)],\"empty\":\(rows.isEmpty)}"
        }
    }

    public static func connectNotionCandidateJSON(service: String, account: String,
                                                   label rawLabel: String = "") -> String {
        guard CMKeychain.isSafeName(service), CMKeychain.isSafeName(account),
              service.range(of: "notion", options: .caseInsensitive) != nil ||
              account.range(of: "notion", options: .caseInsensitive) != nil else {
            return "{\"ok\":false,\"error\":\"Notion Keychain 후보가 아닙니다\"}"
        }
        let isTerminalOwned = service == "cm-notion-token-registered" && account == "notion"
        let isDiscovered: Bool
        if case .found(let rows) = CMKeychain.notionCandidates() {
            isDiscovered = rows.contains { $0.service == service && $0.account == account }
        } else {
            isDiscovered = false
        }
        guard isDiscovered || isTerminalOwned else {
            return "{\"ok\":false,\"error\":\"현재 추천 목록에 없는 Keychain 항목입니다\"}"
        }
        guard CMKeychain.exists(service: service, account: account) else {
            return "{\"ok\":false,\"error\":\"Keychain 항목을 찾지 못했거나 접근이 거절됐습니다\"}"
        }
        let c = IntegrationCatalog.credential("notion-token")!
        let baseLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = baseLabel.isEmpty ? "Notion · \(service)" : baseLabel
        let existing = IntegrationInstances.all(credId: c.id).first {
            $0.keychainService == service && $0.keychainAccount == account
        }
        let key = existing?.key ?? IntegrationInstances.uniqueSlug(
            credId: c.id, desired: IntegrationInstances.slug(service + "-" + account, fallback: "keychain"))
        let inst = CredInstance(credId: c.id, key: key, label: label, mode: "token",
                                keychainService: service, keychainAccount: account)
        guard IntegrationInstances.upsert(inst) else {
            return "{\"ok\":false,\"error\":\"연결 설정을 저장하지 못했습니다\"}"
        }
        let id = inst.compositeId
        invalidate(id)
        let result = IntegrationChecks.check(id, deep: true)
        store(id, result)
        _ = IntegrationInstances.setTest(credId: c.id, key: key, ok: result.state == .ok,
                                         note: result.state == .ok ? result.detail : result.error)
        return "{\"ok\":true,\"id\":\(esc(id)),\"state\":\(esc(result.state.rawValue))," +
            "\"detail\":\(esc(result.detail)),\"error\":\(esc(result.error))}"
    }

    // MARK: 인스턴스 (다중 연동)

    // 인스턴스 생성·수정. 토큰 값이 함께 오면 키체인에도 저장하고 곧바로 검사한다 —
    // 사용자 입장에서 '추가'는 한 번의 동작이지, 만들고 다시 키를 넣는 두 단계가 아니다.
    public static func setInstanceJSON(credId: String, key rawKey: String, label rawLabel: String,
                                       slugHint: String = "", mode rawMode: String = "",
                                       fields: [String: String], value: String) -> String {
        guard let c = IntegrationCatalog.credential(credId), c.multi else {
            return "{\"ok\":false,\"error\":\"여러 개를 등록할 수 있는 연동이 아닙니다\"}"
        }
        // 단일 슬롯 연동(지금은 깃허브)은 이름·키를 사용자에게 묻지 않는다 — 고정
        // 키("token")와 자격증명 이름을 그대로 써서 늘 같은 인스턴스 하나로 upsert된다.
        // 그래서 '추가'가 곧 '저장'이고, 화면에 '인스턴스'라는 개념이 아예 안 보인다.
        let rawKey = c.singleInstance ? "token" : rawKey
        let label = c.singleInstance ? c.name : rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "{\"ok\":false,\"error\":\"이름을 입력하세요\"}" }
        // 방식은 새로 만들 때만 정한다. 기존 인스턴스면 저장된 값이 이기고(upsert가
        // 보존한다), 화면이 보낸 값은 무시된다.
        let existing = rawKey.isEmpty ? nil : IntegrationInstances.find(credId: credId, key: rawKey)
        let mode = existing?.mode ?? (rawMode.isEmpty ? (c.authOptions.first?.id ?? "token") : rawMode)
        if !c.authOptions.isEmpty, !c.authOptions.contains(where: { $0.id == mode }) {
            return "{\"ok\":false,\"error\":\"알 수 없는 인증 방식입니다\"}"
        }
        let opt = c.authOption(mode)
        // 브라우저 승인 방식에 토큰이 함께 오면 저장하지 않고 되돌린다 — 조용히
        // 버리면 사용자는 키를 넣었다고 믿고, 저장하면 아무도 안 읽는 키가 남는다.
        if !opt.needsToken, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "{\"ok\":false,\"error\":\(esc("\(opt.name) 방식은 토큰을 저장하지 않습니다 — 토큰 칸을 비우거나 방식을 바꾸세요"))}"
        }
        // 필수 필드 확인 — 지라는 사이트·이메일이 없으면 검사도 등록도 못 한다.
        var clean: [String: String] = [:]
        for f in c.fields {
            let v = (fields[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if f.required && v.isEmpty {
                return "{\"ok\":false,\"error\":\(esc("\(f.label) 칸을 채워 주세요"))}"
            }
            // 사이트 주소는 끝의 / 를 떼어 둔다 (그대로 두면 //rest/... 로 호출된다).
            clean[f.key] = f.key == "site" ? v.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : v
        }
        // 기존 인스턴스 수정이면 key가 오고, 새로 만들면 라벨에서 슬러그를 만든다.
        // 단일 슬롯 연동은 key가 고정("token")이라 처음 저장하는 순간에도 이미
        // "존재하는" 키로 온다 — 그게 최초 생성인지 수정인지는 upsert가 알아서 가른다.
        let key: String
        if !rawKey.isEmpty {
            guard existing != nil || c.singleInstance else {
                return "{\"ok\":false,\"error\":\"없는 인스턴스입니다\"}"
            }
            key = rawKey
        } else {
            // 슬러그는 키체인 service와 MCP 서버 이름이 된다 — 한글 라벨만 있으면
            // 아무것도 남지 않으므로(전부 걸러진다) 사용자가 영문 이름을 따로 줄 수
            // 있게 했다. 비우면 라벨에서 뽑고, 그것도 비면 inst.
            let hint = slugHint.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = hint.isEmpty ? IntegrationInstances.slug(label, fallback: "inst")
                                    : IntegrationInstances.slug(hint, fallback: "inst")
            key = IntegrationInstances.uniqueSlug(credId: credId, desired: base)
        }
        // 지금 막 만든 것인지(=값이 거부되면 빈 껍데기를 치워야 하는지) — rawKey가
        // 아니라 이걸로 가른다. 단일 슬롯 연동은 key가 늘 고정값("token")이라
        // rawKey.isEmpty가 더는 '새로 만듦'의 신호가 아니다.
        let wasNew = existing == nil
        guard IntegrationInstances.upsert(CredInstance(credId: credId, key: key,
                                                       label: label, fields: clean,
                                                       mode: mode)) else {
            return "{\"ok\":false,\"error\":\"인스턴스를 저장하지 못했습니다\"}"
        }
        let composite = "\(credId):\(key)"
        // 브라우저 승인 방식은 여기서 더 할 일이 없다 — 저장할 키도, 지금 부를 수
        // 있는 API도 없다. 다음 단계(MCP 등록)를 화면이 안내한다.
        guard opt.needsToken else {
            invalidate(composite)
            let r = IntegrationChecks.check(composite)
            store(composite, r)
            return "{\"ok\":true,\"id\":\(esc(composite)),\"key\":\(esc(key)),\"mode\":\(esc(mode))" +
                   ",\"state\":\(esc(r.state.rawValue)),\"detail\":\(esc(r.detail)),\"error\":\"\"}"
        }
        // 토큰을 함께 보냈으면 저장(+검사)까지 끝낸다. 비어 있으면 라벨·필드만 고친 것.
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty {
            let saved = setKeyJSON(id: composite, value: v)
            if !saved.contains("\"saved\":true") {
                // 키가 거부되면 방금 만든 빈 인스턴스는 치운다 — 값 없는 껍데기가
                // 목록에 남으면 사용자는 '추가에 성공했다'고 오해한다.
                if wasNew { IntegrationInstances.remove(credId: credId, key: key) }
                return saved
            }
        } else if !presence(c, key).present {
            // 값 없이 만든 인스턴스는 그대로 두되, 아직 토큰이 없다고 말해 준다.
            return "{\"ok\":true,\"id\":\(esc(composite)),\"key\":\(esc(key)),\"needsToken\":true}"
        }
        // 필드가 바뀌면 이전 검사 결과는 다른 사이트의 결과다 — 다시 확인한다.
        invalidate(composite)
        let r = IntegrationChecks.check(composite)
        store(composite, r)
        // 이미 MCP로 등록된 인스턴스는 필드(이메일)가 바뀌면 등록 내용도 갱신해야 한다.
        if let inst = IntegrationInstances.find(credId: credId, key: key), inst.mcp {
            _ = MCPRegistrar.register(cred: c, inst: inst)
            invalidateMCP()
        }
        return "{\"ok\":true,\"id\":\(esc(composite)),\"key\":\(esc(key))" +
               ",\"state\":\(esc(r.state.rawValue)),\"detail\":\(esc(r.detail)),\"error\":\(esc(r.error))}"
    }

    // 인스턴스 삭제 — 키체인 항목과 MCP 등록까지 함께 걷어낸다. 셋 중 하나만 지우면
    // 사용자가 볼 수 없는 잔재가 남는다 (화면에서 사라진 토큰이 계속 살아 있는 상태).
    public static func removeInstanceJSON(credId: String, key: String) -> String {
        guard let c = IntegrationCatalog.credential(credId), c.multi else {
            return "{\"ok\":false,\"error\":\"알 수 없는 연동 항목\"}"
        }
        guard let inst = IntegrationInstances.find(credId: credId, key: key) else {
            return "{\"ok\":false,\"error\":\"없는 인스턴스입니다\"}"
        }
        if c.mcp != nil { _ = MCPRegistrar.unregister(cred: c, inst: inst) }
        // 외부 Keychain 후보를 연결한 Notion 인스턴스는 참조만 지운다. 사용자가
        // 앱 밖에서 만든 원본 비밀을 앱의 '연결 해제'가 삭제하면 안 된다.
        if inst.keychainService.isEmpty {
            _ = CMKeychain.clear(service: CredInstance.service(base: c.service, key: key))
        }
        let ok = IntegrationInstances.remove(credId: credId, key: key)
        invalidate("\(credId):\(key)")
        invalidateMCP()
        return ok ? "{\"ok\":true,\"removed\":true}" : "{\"ok\":false,\"error\":\"인스턴스 삭제 실패\"}"
    }

    // MCP 등록 스위치. 등록은 토큰이 실제로 통할 때만 허용한다 — 죽은 토큰으로
    // 등록해 두면 Claude 세션이 매번 붙지 않는 서버를 물고 늘어진다.
    public static func setMCPJSON(credId: String, key: String, on: Bool) -> String {
        guard let c = IntegrationCatalog.credential(credId), c.mcp != nil else {
            return "{\"ok\":false,\"error\":\"MCP 서버가 없는 연동입니다\"}"
        }
        guard let inst = IntegrationInstances.find(credId: credId, key: key) else {
            return "{\"ok\":false,\"error\":\"없는 인스턴스입니다\"}"
        }
        if on {
            // 브라우저 승인 방식은 등록이 곧 첫 단추다 — 여기서 토큰을 요구하면
            // 켤 수 있는 스위치가 영영 안 켜진다.
            if c.authOption(inst.mode).needsToken, !presence(c, key).present {
                return "{\"ok\":false,\"error\":\"토큰을 먼저 저장하세요\"}"
            }
            let r = MCPRegistrar.register(cred: c, inst: inst)
            guard r.ok else { return "{\"ok\":false,\"error\":\(esc(r.error))}" }
            IntegrationInstances.setMCP(credId: credId, key: key, on: true)
            invalidateMCP()
            // 브라우저 승인 인스턴스는 '등록됨'이 곧 상태다 — 이전 판단(아직 등록 전)이
            // 캐시에 남아 있으면 방금 켠 스위치가 화면에 반영되지 않는다.
            invalidate("\(credId):\(key)")
            // 켠 김에 실제로 붙는지까지 확인한다. 승인이 필요한 방식이면 여기서
            // 브라우저 창이 열리고, 화면은 그 사실을 스피너로 말한다 — 예전에는
            // 아무 일도 안 일어난 것처럼 보여서 스위치를 여러 번 누르게 됐다.
            _ = probeJSON(credId: credId, key: key)
            return "{\"ok\":true,\"mcp\":true,\"name\":\(esc(r.name)),\"probing\":true}"
        }
        let r = MCPRegistrar.unregister(cred: c, inst: inst)
        IntegrationInstances.setMCP(credId: credId, key: key, on: false)
        invalidateMCP()
        invalidate("\(credId):\(key)")
        return r.ok ? "{\"ok\":true,\"mcp\":false,\"name\":\(esc(r.name))}"
                    : "{\"ok\":false,\"error\":\(esc(r.error))}"
    }

    // MARK: 실검사 (프로브)

    // 서버를 실제로 한 번 띄워 본다. 요청을 붙잡지 않고 바로 돌아온다 — 승인이
    // 안 돼 있으면 사람이 브라우저에서 로그인하는 시간만큼 걸리고, 그동안 대시보드
    // 전체가 멈추면 안 된다. 화면은 probeStateJSON 을 폴링해 단계를 따라온다.
    public static func probeJSON(credId: String, key: String) -> String {
        guard let c = IntegrationCatalog.credential(credId), c.mcp != nil else {
            return "{\"ok\":false,\"error\":\"MCP 서버가 없는 연동입니다\"}"
        }
        guard let inst = IntegrationInstances.find(credId: credId, key: key) else {
            return "{\"ok\":false,\"error\":\"없는 인스턴스입니다\"}"
        }
        let composite = inst.compositeId
        // 등록되지 않은 인스턴스도 검사할 수 있다 — 등록 전에 '붙는지'부터 확인하는
        // 편이 순서상 자연스럽고, 등록 실패와 연결 실패를 따로 볼 수 있다.
        let started = MCPProbe.start(cred: c, inst: inst) { ok, tools, url, err in
            // 성공한 검사의 note 는 '무엇을 확인했는가'다. 확인 페이지까지 만들었으면
            // 그 사실을, 만들지 못했으면 그 사유를 남긴다 (err 가 그 사유로 온다).
            var note = "도구 \(tools)개"
            if ok, !url.isEmpty { note += " · 테스트 페이지 생성됨" }
            else if ok, !err.isEmpty { note += " · 확인 페이지 실패" }
            IntegrationInstances.setTest(credId: credId, key: key, ok: ok,
                                         note: ok ? note : err, url: url)
            invalidate(composite)
        }
        return started ? "{\"ok\":true,\"running\":true,\"id\":\(esc(composite))}"
                       : "{\"ok\":true,\"running\":true,\"already\":true,\"id\":\(esc(composite))}"
    }

    public static func probeStateJSON(credId: String, key: String) -> String {
        let composite = key.isEmpty ? credId : "\(credId):\(key)"
        guard let st = MCPProbe.state(composite) else {
            return "{\"ok\":true,\"phase\":\"idle\"}"
        }
        var s = "{\"ok\":true,\"phase\":\(esc(st.phase)),\"detail\":\(esc(st.detail))"
        s += ",\"tools\":\(st.tools),\"error\":\(esc(st.error)),\"url\":\(esc(st.url))"
        s += ",\"running\":\(MCPProbe.isRunning(composite))}"
        return s
    }

    // MARK: 표시 문구

    public static func kindLabel(_ k: AuthKind) -> String {
        switch k {
        case .apiKey:     return "API 키"
        case .cliSession: return "CLI 로그인"
        case .webSession: return "웹 세션"
        case .endpoint:   return "엔드포인트"
        // 브라우저 동의로 만들어진 자격증명 한 벌 — 앱이 받아 저장하는 키가 아니다.
        case .oauthApp:   return "OAuth 앱"
        }
    }

    // 최소 JSON 문자열 이스케이퍼 (타깃이 앱 타입에 의존하지 않도록 자체 보유).
    static func esc(_ s: String) -> String {
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
