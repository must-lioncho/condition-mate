import Foundation

// 연동 인스턴스 — "같은 종류의 연동을 여러 개 갖는다"를 담는 자리.
//
// 왜 필요했나: 슬랙·LLM 키는 하나면 끝이라 자격증명 하나 = 키체인 항목 하나로
// 충분했다. 깃허브는 그렇지 않다 — 개인 계정 토큰과 조직 A·B·C 토큰이 따로 있고,
// 어느 조직 일을 하느냐에 따라 쓰는 토큰이 다르다. 노션(워크스페이스)·지라(사이트)도
// 같은 모양이다. 그래서 자격증명은 '틀'이 되고, 실제 값은 이름 붙은 인스턴스가 된다.
//
// 무엇이 어디에 사는가:
//   비밀값(토큰)      → 키체인. service = "<base>-<key>" (예: cm-github-token-must)
//   비밀 아닌 필드     → 이 파일. 지라 사이트 주소·계정 이메일은 비밀이 아니고,
//                       키체인 값 하나에 JSON으로 우겨넣으면 마스킹·검증이 무너진다.
//   MCP 등록 여부      → 이 파일. 실제 등록 상태는 claude CLI가 진실이지만, 사용자가
//                       무엇을 켜뒀는지는 앱이 기억해야 재등록·정리를 할 수 있다.
//
// 파일은 <data>/integrations.json 하나. 비밀값이 절대 들어가지 않는다는 것이
// 이 파일의 유일한 불변식이다 — 필드를 늘릴 때 secret: true 인 것은 여기 오면 안 된다.
public struct CredInstance {
    public var credId: String                 // 자격증명 id (예: "github-token")
    public var key: String                    // 슬러그 — 키체인 접미어·MCP 서버 이름에 쓰인다
    public var label: String                  // 사람이 읽는 이름 ("MUST 조직")
    public var fields: [String: String]       // 비밀 아닌 필드 (site·email 등)
    public var mcp: Bool                      // MCP 서버로 등록해 두었는가
    // 인증 경로 (Credential.authOptions의 id). 만들 때 정해지고 이후 바뀌지 않는다 —
    // 방식이 바뀌면 키체인 항목의 유무부터 달라져서, 사실상 다른 인스턴스다.
    // 이 필드 이전에 만들어진 줄은 비어 있고, 그건 토큰 방식으로 읽힌다.
    public var mode: String
    // 마지막 실검사 — 등록은 언제나 성공하므로, '붙는다'는 사실은 따로 남겨야 한다.
    // 0이면 한 번도 확인한 적 없음(화면은 그걸 주황으로 말한다).
    public var testedAt: Double
    public var testOk: Bool
    public var testNote: String               // 도구 개수 또는 실패 사유 (비밀 아님)
    // 검사가 남긴 흔적의 주소 — 노션이면 그때 만든 테스트 페이지. 도구 개수는 앱만
    // 아는 숫자라 사용자가 확인할 방법이 없었다. 이 링크가 그 확인이다.
    public var testUrl: String

    public init(credId: String, key: String, label: String,
                fields: [String: String] = [:], mcp: Bool = false, mode: String = "token",
                testedAt: Double = 0, testOk: Bool = false, testNote: String = "",
                testUrl: String = "") {
        self.credId = credId
        self.key = key
        self.label = label
        self.fields = fields
        self.mcp = mcp
        self.mode = mode
        self.testedAt = testedAt
        self.testOk = testOk
        self.testNote = testNote
        self.testUrl = testUrl
    }

    // 이 인스턴스의 키체인 service. 단일 인스턴스 자격증명(슬랙·LLM)은 예전 그대로
    // base를 쓴다 — 접미어를 붙이는 순간 이미 등록된 키가 전부 사라진 것처럼 보인다.
    public static func service(base: String, key: String) -> String {
        key.isEmpty ? base : "\(base)-\(key)"
    }

    // 합성 id — 화면·검사·API가 인스턴스 하나를 가리키는 단일 문자열.
    // "github-token:must" 처럼 쓰고, 인스턴스가 없는 자격증명은 그냥 "slack-user".
    public var compositeId: String { key.isEmpty ? credId : "\(credId):\(key)" }

    public static func split(_ composite: String) -> (credId: String, key: String) {
        guard let i = composite.firstIndex(of: ":") else { return (composite, "") }
        return (String(composite[composite.startIndex..<i]),
                String(composite[composite.index(after: i)...]))
    }
}

public enum IntegrationInstances {

    private static let lock = NSLock()
    private static var cache: [CredInstance]?

    // 데이터 폴더는 슬랙 데몬·지라 브리지와 같은 규칙 — CM_DATA_DIR, 없으면 ~/.condition-mate.
    // (앱 타입에 의존하지 않으려고 여기서 다시 구한다. Integrations 타깃은 앱을 모른다.)
    private static var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["CM_DATA_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".condition-mate", isDirectory: true)
        return base.appendingPathComponent("integrations.json")
    }

    // MARK: 읽기

    public static func all() -> [CredInstance] {
        lock.lock()
        if let hit = cache { lock.unlock(); return hit }
        lock.unlock()
        let loaded = load()
        lock.lock(); cache = loaded; lock.unlock()
        return loaded
    }

    public static func all(credId: String) -> [CredInstance] {
        all().filter { $0.credId == credId }
    }

    public static func find(credId: String, key: String) -> CredInstance? {
        all().first { $0.credId == credId && $0.key == key }
    }

    private static func load() -> [CredInstance] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["instances"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let credId = row["credId"] as? String, !credId.isEmpty,
                  let key = row["key"] as? String, !key.isEmpty else { return nil }
            let fields = (row["fields"] as? [String: String]) ?? [:]
            return CredInstance(credId: credId, key: key,
                                label: (row["label"] as? String) ?? key,
                                fields: fields,
                                mcp: (row["mcp"] as? Bool) ?? false,
                                mode: (row["mode"] as? String) ?? "token",
                                testedAt: (row["testedAt"] as? Double) ?? 0,
                                testOk: (row["testOk"] as? Bool) ?? false,
                                testNote: (row["testNote"] as? String) ?? "",
                                testUrl: (row["testUrl"] as? String) ?? "")
        }
    }

    // MARK: 쓰기

    // 인스턴스 생성·수정. 같은 (credId, key)가 있으면 라벨·필드만 갱신한다 —
    // key가 키체인 service의 일부라서, key를 바꾸는 것은 '다른 인스턴스'다.
    @discardableResult
    public static func upsert(_ inst: CredInstance) -> Bool {
        var rows = all()
        if let i = rows.firstIndex(where: { $0.credId == inst.credId && $0.key == inst.key }) {
            // mcp 플래그는 등록 토글이 소유한다 — 저장 요청이 실수로 끄지 않게 보존.
            // 방식(mode)도 마찬가지로 만들 때 정해진 값을 지킨다: 라벨을 고치는 요청이
            // 방식을 바꿔 버리면, 키체인에 값이 있는데 안 읽는 인스턴스가 생긴다.
            var merged = inst
            merged.mcp = rows[i].mcp
            merged.mode = rows[i].mode
            // 검사 기록도 저장 요청이 지우지 않는다 — 이름만 고쳤는데 '테스트 안 됨'
            // 으로 되돌아가면, 사용자는 방금 확인한 것을 다시 확인하게 된다.
            merged.testedAt = rows[i].testedAt
            merged.testOk = rows[i].testOk
            merged.testNote = rows[i].testNote
            merged.testUrl = rows[i].testUrl
            rows[i] = merged
        } else {
            rows.append(inst)
        }
        return save(rows)
    }

    @discardableResult
    public static func setMCP(credId: String, key: String, on: Bool) -> Bool {
        var rows = all()
        guard let i = rows.firstIndex(where: { $0.credId == credId && $0.key == key }) else { return false }
        rows[i].mcp = on
        return save(rows)
    }

    // 실검사 결과 기록. 프로브가 끝날 때만 호출된다 — 여기 값이 곧 "마지막으로
    // 붙는 것을 확인한 시각"이고, 화면의 테스트 상태는 전부 이 세 칸에서 나온다.
    @discardableResult
    public static func setTest(credId: String, key: String, ok: Bool, note: String,
                               url: String = "") -> Bool {
        var rows = all()
        guard let i = rows.firstIndex(where: { $0.credId == credId && $0.key == key }) else { return false }
        rows[i].testedAt = Date().timeIntervalSince1970
        rows[i].testOk = ok
        rows[i].testNote = note
        // 이번 검사의 흔적만 남긴다 — 지난번 테스트 페이지 링크가 남아 있으면
        // 방금 확인한 것처럼 보인다.
        rows[i].testUrl = url
        return save(rows)
    }

    @discardableResult
    public static func remove(credId: String, key: String) -> Bool {
        let rows = all().filter { !($0.credId == credId && $0.key == key) }
        return save(rows)
    }

    private static func save(_ rows: [CredInstance]) -> Bool {
        let items: [[String: Any]] = rows.map {
            ["credId": $0.credId, "key": $0.key, "label": $0.label,
             "fields": $0.fields, "mcp": $0.mcp, "mode": $0.mode,
             "testedAt": $0.testedAt, "testOk": $0.testOk, "testNote": $0.testNote,
             "testUrl": $0.testUrl]
        }
        let payload: [String: Any] = ["version": 1, "instances": items]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // 원자적 교체 — 쓰다 죽으면 인스턴스 목록이 통째로 날아가고, 그러면 키체인에는
        // 값이 남았는데 화면에는 아무것도 없는 상태가 된다(사용자가 복구할 방법이 없다).
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        lock.lock(); cache = rows; lock.unlock()
        return true
    }

    // MARK: 슬러그

    // 사용자가 입력한 이름 → 키체인 service·MCP 서버 이름에 쓸 수 있는 슬러그.
    // 키체인은 영문/숫자/-/_/./@ 만 받고(CMKeychain.isSafeName), MCP 서버 이름도
    // 같은 범위가 안전하다. 한글 라벨은 label에 그대로 남고, 슬러그만 여기서 만든다.
    public static func slug(_ raw: String, fallback: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " || ch == "." || ch == "/" { out.append("-") }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 { out = String(out.prefix(40)) }
        return out.isEmpty ? fallback : out
    }

    // 이미 쓰는 슬러그면 -2, -3 … 을 붙인다. 같은 조직 이름을 두 번 넣었을 때
    // 조용히 덮어쓰면 앞의 토큰이 사라진다.
    public static func uniqueSlug(credId: String, desired: String) -> String {
        let used = Set(all(credId: credId).map { $0.key })
        if !used.contains(desired) { return desired }
        var n = 2
        while used.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }
}
