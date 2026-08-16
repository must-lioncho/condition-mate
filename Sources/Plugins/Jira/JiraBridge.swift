import Foundation
import Network
import Security

// 지라 번역 브리지 — 로컬 크롬 익스텐션 하나만을 위한 최소 HTTP 서버.
//
// 왜 대시보드 서버(DashboardServer)를 쓰지 않는가:
//  1) 대시보드 포트는 매 실행마다 달라질 수 있다(마지막 포트를 선호하지만 보장은 아니다).
//     익스텐션은 manifest의 host_permissions에 주소를 박아야 하므로 고정 포트가 필요하다.
//  2) 공격 표면을 분리한다. 이 서버가 아는 것은 "텍스트를 번역한다" 하나뿐이라, 브라우저
//     쪽에서 들어오는 요청이 대시보드의 목표·세션·파일 엔드포인트에 닿을 길이 없다.
//
// 방어선(로컬 전용이라도 브라우저는 남의 웹페이지를 실행하는 곳이다):
//  - 127.0.0.1 에만 바인딩 — LAN에서 보이지 않는다.
//  - 공유 토큰 x-cm-jira-token 필수. 토큰은 <data>/jira-bridge/token (0600)에 있고
//    설치 스크립트가 익스텐션 폴더에 심는다. 아무 웹사이트나 127.0.0.1을 두드려도
//    토큰을 모르므로 401이다.
//  - Origin 헤더가 있으면 chrome-extension:// 로 시작해야 한다. 일반 웹페이지의
//    fetch는 항상 자기 Origin(https://…)을 붙이므로 여기서 걸린다.
//  - CORS 허용 헤더는 chrome-extension 출처에만 되돌려준다. `*` 는 절대 쓰지 않는다.
//  - 요청 본문 상한, 조각 수 상한, 분당 호출 상한.
public final class JiraBridge {

    public static let shared = JiraBridge()
    private init() {}

    // 익스텐션 manifest와 반드시 같은 값. 바꾸면 양쪽을 함께 고쳐야 한다.
    public static let fixedPort: UInt16 = 17321

    // 앱이 주입한다 (<data>/jira-bridge). 토큰·설정이 여기 산다.
    public static var dataDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cm-jira-bridge", isDirectory: true)
    public static var log: (String) -> Void = { _ in }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cm.jira.bridge", qos: .utility)
    private static let maxRequestBytes = 512 * 1024
    private static let headerSep = Data("\r\n\r\n".utf8)

    public var isRunning: Bool { listener != nil }

    // MARK: - 수명

    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        _ = Self.token()   // 첫 실행에 토큰을 만들어 둔다 (설치 스크립트가 바로 읽을 수 있게)
        guard let np = NWEndpoint.Port(rawValue: Self.fixedPort) else { return false }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: np)
        guard let l = try? NWListener(using: params) else {
            Self.log("jira-bridge: 포트 \(Self.fixedPort) 바인딩 실패 (이미 사용 중?)")
            return false
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Self.log("jira-bridge: 127.0.0.1:\(Self.fixedPort) 대기")
            case .failed(let e):
                Self.log("jira-bridge: 실패 \(e) — 중지")
                self?.stop()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
        return true
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 토큰

    private static let tokenLock = NSLock()
    private static var cachedToken: String?

    // <data>/jira-bridge/token — 없으면 만든다. 0600으로 유저 본인만 읽는다.
    public static func token() -> String {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if let t = cachedToken { return t }
        let url = dataDir.appendingPathComponent("token")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let t = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 16 { cachedToken = t; return t }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? Data(t.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cachedToken = t
        return t
    }

    // 길이 정보까지 새지 않도록 상수 시간 비교.
    private static func tokenMatches(_ given: String) -> Bool {
        let expect = Array(token().utf8)
        let got = Array(given.utf8)
        guard expect.count == got.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expect.count { diff |= expect[i] ^ got[i] }
        return diff == 0
    }

    // MARK: - 호출 상한

    private let rateLock = NSLock()
    private var recentCalls: [Date] = []
    private static let maxCallsPerMinute = 40

    private func allowCall() -> Bool {
        rateLock.lock(); defer { rateLock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        recentCalls.removeAll { $0 < cutoff }
        guard recentCalls.count < Self.maxCallsPerMinute else { return false }
        recentCalls.append(Date())
        return true
    }

    // MARK: - 요청 처리

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let chunk { acc.append(chunk) }
            if acc.count > Self.maxRequestBytes { conn.cancel(); return }
            guard let sep = acc.range(of: Self.headerSep) else {
                if isComplete || error != nil { conn.cancel() } else { self.receive(conn, buffer: acc) }
                return
            }
            let headerText = String(decoding: acc[acc.startIndex..<sep.lowerBound], as: UTF8.self)
            let need = Self.contentLength(headerText)
            let have = acc.distance(from: sep.upperBound, to: acc.endIndex)
            if have < need && !isComplete && error == nil { self.receive(conn, buffer: acc); return }
            let body = String(decoding: acc[sep.upperBound...], as: UTF8.self)
            self.respond(conn, headerText: headerText, body: body)
        }
    }

    private func respond(_ conn: NWConnection, headerText: String, body: String) {
        let method = headerText.split(separator: " ").first.map(String.init) ?? ""
        let path = Self.path(headerText)
        let origin = Self.header(headerText, "origin")
        let extensionOrigin = origin.hasPrefix("chrome-extension://") ? origin : nil

        // 브라우저 프리플라이트. 익스텐션 출처가 아니면 허용 헤더를 주지 않는다.
        if method == "OPTIONS" {
            send(conn, status: "204 No Content", json: nil, origin: extensionOrigin)
            return
        }
        // 웹페이지에서 온 요청(자기 Origin을 달고 오는 fetch)은 여기서 끝난다.
        if !origin.isEmpty && extensionOrigin == nil {
            send(conn, status: "403 Forbidden", json: "{\"ok\":false,\"error\":\"origin\"}", origin: nil)
            return
        }
        guard Self.tokenMatches(Self.header(headerText, "x-cm-jira-token")) else {
            send(conn, status: "401 Unauthorized", json: "{\"ok\":false,\"error\":\"token\"}", origin: extensionOrigin)
            return
        }

        switch (method, path) {
        case ("GET", "/ping"):
            let model = Self.configuredModel()
            send(conn, status: "200 OK",
                 json: "{\"ok\":true,\"app\":\"condition-mate\",\"api\":1,\"model\":\"\(model)\"}",
                 origin: extensionOrigin)

        case ("POST", "/translate"):
            guard allowCall() else {
                send(conn, status: "429 Too Many Requests",
                     json: "{\"ok\":false,\"error\":\"분당 호출 한도를 넘었습니다\"}", origin: extensionOrigin)
                return
            }
            send(conn, status: "200 OK", json: translateJSON(body), origin: extensionOrigin)

        case ("POST", "/cache/clear"):
            JiraTranslate.clearCache()
            send(conn, status: "200 OK", json: "{\"ok\":true}", origin: extensionOrigin)

        default:
            send(conn, status: "404 Not Found", json: "{\"ok\":false,\"error\":\"unknown\"}", origin: extensionOrigin)
        }
    }

    // {"texts":[...], "lang":"ko", "model":"gemini-flash-lite"}
    //   -> {"ok":true,"items":["…"],"model":…,"ms":…,"cached":N}
    private func translateJSON(_ body: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let raw = obj["texts"] as? [String] else {
            return "{\"ok\":false,\"error\":\"texts 배열이 필요합니다\"}"
        }
        guard !raw.isEmpty else { return "{\"ok\":true,\"items\":[],\"model\":\"none\",\"ms\":0,\"cached\":0}" }
        guard raw.count <= JiraTranslate.maxSegments else {
            return "{\"ok\":false,\"error\":\"한 번에 \(JiraTranslate.maxSegments)조각까지만 됩니다\"}"
        }
        let texts = raw.map { String($0.prefix(JiraTranslate.maxCharsPerSegment)) }
        guard texts.reduce(0, { $0 + $1.count }) <= JiraTranslate.maxCharsTotal else {
            return "{\"ok\":false,\"error\":\"본문이 너무 깁니다\"}"
        }
        let lang = (obj["lang"] as? String) ?? "ko"
        let r = JiraTranslate.translate(texts, lang: lang, model: obj["model"] as? String ?? Self.configuredModel())
        if let err = r.error, r.cached == 0, r.outputs == texts {
            Self.log("jira-bridge: 번역 실패 — \(err)")
            return "{\"ok\":false,\"error\":\(Self.jsonString(err))}"
        }
        let items = r.outputs.map(Self.jsonString).joined(separator: ",")
        var out = "{\"ok\":true,\"items\":[\(items)],\"model\":\(Self.jsonString(r.model)),\"ms\":\(r.ms),\"cached\":\(r.cached)"
        if let err = r.error { out += ",\"warn\":\(Self.jsonString(err))" }
        return out + "}"
    }

    // <data>/jira-bridge/config.json {"model": "gemini-flash-lite"} — 없으면 기본값.
    static func configuredModel() -> String {
        let url = dataDir.appendingPathComponent("config.json")
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = obj["model"] as? String, JiraTranslate.models[m] != nil else {
            return JiraTranslate.defaultModel
        }
        return m
    }

    // MARK: - HTTP 유틸

    private func send(_ conn: NWConnection, status: String, json: String?, origin: String?) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let origin = origin {
            head += "Access-Control-Allow-Origin: \(Self.sanitizeHeader(origin))\r\n"
            head += "Access-Control-Allow-Headers: content-type, x-cm-jira-token\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Max-Age: 600\r\n"
        }
        head += "Cache-Control: no-store\r\n"
        let payload = Data((json ?? "").utf8)
        if json != nil { head += "Content-Type: application/json; charset=utf-8\r\n" }
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func path(_ headerText: String) -> String {
        let parts = headerText.split(separator: "\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return "" }
        return String(parts[1].split(separator: "?").first ?? "")
    }

    private static func header(_ headerText: String, _ name: String) -> String {
        for line in headerText.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].lowercased() == name else { continue }
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func contentLength(_ headerText: String) -> Int {
        Int(header(headerText, "content-length")) ?? 0
    }

    // 헤더로 되돌려 보내기 전에 개행을 제거한다 (응답 분할 방지).
    private static func sanitizeHeader(_ s: String) -> String {
        String(s.prefix(256)).filter { $0 != "\r" && $0 != "\n" }
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) }
                else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }
}
