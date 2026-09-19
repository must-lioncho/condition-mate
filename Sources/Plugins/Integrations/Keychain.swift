import Foundation
import Security

public struct CMKeychainCandidate: Equatable {
    public let service: String
    public let account: String
}

public enum CMKeychainCandidateResult {
    case found([CMKeychainCandidate])
    case unavailable(String)
}

// macOS 키체인 접근 — 이 앱의 모든 외부 연동 비밀값(슬랙 토큰, LLM API 키)이
// 드나드는 유일한 문이다.
//
// 왜 Security 프레임워크(SecItemAdd)가 아니라 /usr/bin/security 인가:
// 이 키들은 앱만 쓰는 게 아니다. 슬랙 Socket Mode 데몬(node, 앱 밖 프로세스)이
// 같은 항목을 `security find-generic-password -w` 로 읽는다. SecItemAdd로 만든
// 항목은 ACL이 생성한 앱에만 묶여서 데몬이 읽을 때 키체인 승인 창이 뜬다.
// /usr/bin/security 로 쓰면 ACL 주인이 security 바이너리라, 앱도 데몬도 프롬프트
// 없이 읽는다 — 사용자가 예전부터 터미널로 등록해 온 항목과 정확히 같은 모양이다.
//
// 왜 쓰기를 argv가 아니라 stdin(`security -i`)으로 보내는가: `security
// add-generic-password … -w <값>` 은 그 짧은 순간 비밀값이 `ps` 출력에 그대로
// 보인다. 대화형 모드는 명령줄을 stdin으로 받으므로 argv에 아무것도 남지 않는다.
public enum CMKeychain {

    // MARK: 읽기

    // 값 자체. 화면으로 절대 내려보내지 않는다 — 라이브 검사(실 API 호출)와
    // 마스킹 표시에만 쓴다.
    public static func value(service: String) -> String? {
        guard !service.isEmpty else { return nil }
        let (code, out) = run(["find-generic-password", "-w", "-s", service])
        guard code == 0 else { return nil }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public static func value(service: String, account: String) -> String? {
        guard isSafeName(service), isSafeName(account) else { return nil }
        let (code, out) = run(["find-generic-password", "-w", "-s", service, "-a", account])
        guard code == 0 else { return nil }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // 값은 요청하지 않는다. 현재 프로세스가 볼 수 있는 generic-password 속성 중
    // service/account에 notion이 들어간 항목만 결정적으로 추천한다. macOS는 이
    // 질의의 완전성을 보장하지 않으므로 실패와 빈 결과를 호출자가 서로 구분한다.
    public static func notionCandidates() -> CMKeychainCandidateResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: false
        ]
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        if status == errSecItemNotFound { return .found([]) }
        guard status == errSecSuccess else {
            return .unavailable("Keychain 항목 이름을 읽을 수 없습니다 (\(status))")
        }
        let rows: [[CFString: Any]]
        if let many = raw as? [[CFString: Any]] { rows = many }
        else if let one = raw as? [CFString: Any] { rows = [one] }
        else { return .found([]) }
        let candidates = rows.compactMap { row -> CMKeychainCandidate? in
            guard let service = row[kSecAttrService] as? String,
                  let account = row[kSecAttrAccount] as? String else { return nil }
            return CMKeychainCandidate(service: service, account: account)
        }
        return .found(filterNotionCandidates(candidates))
    }

    public static func filterNotionCandidates(_ rows: [CMKeychainCandidate]) -> [CMKeychainCandidate] {
        var seen = Set<String>()
        return rows.filter {
            $0.service.range(of: "notion", options: .caseInsensitive) != nil ||
            $0.account.range(of: "notion", options: .caseInsensitive) != nil
        }.filter {
            isSafeName($0.service) && isSafeName($0.account) &&
            seen.insert($0.service + "\u{0}" + $0.account).inserted
        }.sorted {
            let lhs = $0.service.localizedStandardCompare($1.service)
            return lhs == .orderedSame
                ? $0.account.localizedStandardCompare($1.account) == .orderedAscending
                : lhs == .orderedAscending
        }
    }

    public static func exists(service: String) -> Bool { value(service: service) != nil }

    // 같은 service 아래 항목이 여럿일 때(지라 골의 client_id·client_secret·refresh_token)
    // "그 중 어느 것이 있는가"를 묻는 자리. 값을 읽지 않고 항목의 존재만 본다 —
    // -w 없이 부르면 속성만 나오므로 잠긴 키체인의 승인 창을 부르지 않는다.
    public static func exists(service: String, account: String) -> Bool {
        guard !service.isEmpty, !account.isEmpty else { return false }
        guard isSafeName(service), isSafeName(account) else { return false }
        let (code, _) = run(["find-generic-password", "-s", service, "-a", account])
        return code == 0
    }

    // 항목의 실제 account 이름. 갱신(add -U)이 기존 항목을 덮어쓰려면 service와
    // account가 둘 다 같아야 한다 — 다르면 같은 service에 항목이 둘 생기고
    // find-generic-password가 어느 쪽을 돌려줄지 알 수 없게 된다.
    public static func account(service: String, fallback: String) -> String {
        guard !service.isEmpty else { return fallback }
        let (code, out) = run(["find-generic-password", "-s", service])
        guard code == 0 else { return fallback }
        // "acct"<blob>="slack" 형태의 줄에서 계정명을 뽑는다.
        for line in out.split(separator: "\n") where line.contains("\"acct\"") {
            guard let eq = line.range(of: "=\""), line.hasSuffix("\"") else { continue }
            let v = line[eq.upperBound..<line.index(before: line.endIndex)]
            if !v.isEmpty { return String(v) }
        }
        return fallback
    }

    // 화면에 보여줄 수 있는 형태 — 뒤 4자리만. 값이 짧으면 자릿수도 숨긴다.
    public static func masked(service: String) -> String {
        guard let v = value(service: service) else { return "" }
        guard v.count > 8 else { return "••••" }
        return "••••" + String(v.suffix(4))
    }

    // MARK: 쓰기

    public enum WriteResult { case saved, rejected(String), failed(String) }

    // 대시보드에서 받은 값을 저장한다. 값은 stdin으로만 흐른다.
    //
    // 문자 제한이 있는 이유: 대화형 모드는 명령줄을 셸처럼 토큰화하므로 따옴표·
    // 역슬래시·개행이 들어오면 파서가 값을 잘라먹거나 다른 인자로 오해한다.
    // 조용히 잘린 키를 저장하면 "저장은 됐는데 연결만 안 되는" 최악의 상태가 되니,
    // 애초에 거부하고 터미널 명령을 안내한다. 실제 API 키·토큰은 전부 이 범위 안이다.
    public static func set(service: String, account: String, value raw: String) -> WriteResult {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty, !account.isEmpty else { return .rejected("서비스 이름이 없습니다") }
        guard !v.isEmpty else { return .rejected("빈 값입니다") }
        guard v.count <= 4096 else { return .rejected("값이 너무 깁니다") }
        guard v.allSatisfy({ isSafe($0) }) else {
            return .rejected("키에 공백·따옴표·역슬래시 같은 문자가 있습니다 — 복사 범위를 확인하거나 터미널 명령으로 등록하세요")
        }
        guard isSafeName(service), isSafeName(account) else { return .rejected("서비스·계정 이름이 올바르지 않습니다") }
        // -U: 같은 service+account 항목이 있으면 만들지 말고 갱신.
        let cmd = "add-generic-password -U -s \(service) -a \(account) -w \"\(v)\"\n"
        let (code, out) = run(["-i"], stdin: cmd)
        if code == 0 { return .saved }
        let msg = out.split(separator: "\n").last.map(String.init) ?? "security 실패 (\(code))"
        return .failed(String(msg.prefix(160)))
    }

    // 연동 해제. 항목이 원래 없었어도 성공으로 본다 (사용자가 원한 최종 상태는 같다).
    @discardableResult
    public static func clear(service: String) -> Bool {
        guard isSafeName(service) else { return false }
        let (code, _) = run(["delete-generic-password", "-s", service])
        return code == 0 || !exists(service: service)
    }

    // MARK: 내부

    // 값에 허용하는 문자: 공백/따옴표/역슬래시/제어문자를 뺀 출력 가능한 ASCII.
    private static func isSafe(_ c: Character) -> Bool {
        guard let a = c.asciiValue, a > 0x20, a < 0x7F else { return false }
        return c != "\"" && c != "\\" && c != "'" && c != "`" && c != "$"
    }

    public static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { c in
            c.isLetter && c.isASCII || c.isNumber || c == "-" || c == "_" || c == "." || c == "@"
        }
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        // security는 find-generic-password의 속성 덤프를 stderr로 낸다 — 같이 읽는다.
        p.standardError = outPipe
        var inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            p.standardInput = pipe
            inPipe = pipe
        }
        guard (try? p.run()) != nil else { return (-1, "security 실행 실패") }
        if let inPipe = inPipe, let s = stdin {
            inPipe.fileHandleForWriting.write(Data(s.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
