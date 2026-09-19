import Foundation
import CryptoKit

// Orca CLI 얇은 감싸개 — "그 세션 창이 아직 있나, 그리고 지금 움직이고 있나" 두 가지만 답한다.
//
// 이 파일이 있는 이유는 `/issues` 화면의 `도는 중` 이 거짓말이었기 때문이다. 카드는 항목당 두 번만
// 쓰인다(큐 PM 이 좌표를 적을 때와 닫을 때). 그 사이 목적지 세션이 몇 시간을 일해도 카드는 안
// 바뀌고, 창이 죽어도 카드는 `던짐` 인 채로 남는다. 그래서 `도는 중` 은 도는 것의 수가 아니라
// **아무도 안 닫은 카드의 수**였다. 라이언이 2026-09-06 00:52 에 본 것이 그것이다.
//
// 근거를 실제로 돌려서 정했다(2026-09-06 01:0x). 자세한 실측은
// `issue/2026-09-06-realtime-card-tracking-directive.md` 에 있고 요점은 둘이다.
//
//   ★ 1. `list` 의 `orphaned`·`connected`·`writable` 은 66 개 전부 같은 값이라 가르는 힘이 0 이다.
//        창의 죽음은 그 필드가 아니라 **목록에서 빠지는 것**으로 안다.
//   ★ 2. `list` 의 `lastOutputAt` 은 66 개 중 53 개가 null 이다. 그것은 "마지막 활동 시각" 이
//        아니라 "이번 Orca 기동 이후의 마지막 출력" 이라, Orca 가 재시작하면 통째로 비워진다.
//        그래서 움직임 판정은 `read` 가 주는 **렌더된 화면의 해시**로 한다.
//
// `latestCursor` 는 쓸 수 없다. 절대 단조 카운터가 아니라 보존 버퍼 기준 상대값이라 활동 중인
// 창도 30 초 뒤 같은 값(2)이었고 `--limit` 을 주면 값이 통째로 달라진다.
//
// 이 감싸개는 읽기만 한다. `send` 도 `close` 도 부르지 않는다.
enum OrcaTerminals {

    // MARK: - 실행 파일

    // 실측 경로는 `/usr/local/bin/orca` 다. 그것만 못박지 않는 이유는 이 앱이 launchd 로도 뜨고
    // 그때 PATH 가 다르기 때문이다 — `orca` 를 PATH 로 찾지 않고 절대경로 후보를 직접 본다.
    static let candidatePaths = [
        "/usr/local/bin/orca",
        "/opt/homebrew/bin/orca",
        NSString(string: "~/.local/bin/orca").expandingTildeInPath,
        NSString(string: "~/bin/orca").expandingTildeInPath,
    ]

    static var executablePath: String? {
        let env = (ProcessInfo.processInfo.environment["CM_ORCA_BIN"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.isEmpty {
            let p = (env as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static var available: Bool { executablePath != nil }

    // MARK: - 핸들 검사

    // 핸들은 카드 파일에서 온 문자열이다. 셸을 거치지 않고 `Process.arguments` 로 넘기므로 주입은
    // 원리적으로 안 되지만, 검사도 같이 한다 — 이 저장소는 웹뷰/디스크에서 온 문자열을 그대로
    // 외부에 넘긴 적이 한 번도 없다(`revealWorkQueuePath` 의 허용 목록이 같은 규칙이다).
    static func isValidHandle(_ h: String) -> Bool {
        let t = h.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("term_"), t.count >= 13, t.count <= 96 else { return false }
        let body = t.dropFirst("term_".count)
        guard !body.isEmpty else { return false }
        return body.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    // MARK: - 터미널

    struct Terminal {
        var handle: String
        var title: String
        var worktreePath: String
        var branch: String
        var agentIdentity: String
        // ms epoch. **66 개 중 53 개가 null 이다.** 있으면 곁들여 쓰고 없다고 판정을 포기하지 않는다.
        var lastOutputAt: Double?
    }

    struct ListResult {
        var ok: Bool
        var terminals: [Terminal]
        var error: String        // 비어 있으면 성공

        var byHandle: [String: Terminal] {
            var m: [String: Terminal] = [:]
            for t in terminals { m[t.handle] = t }
            return m
        }
    }

    // 살아 있는 터미널 전량. 프로세스 1 개, 실측 0.2 초.
    static func list(timeout: TimeInterval = 6) -> ListResult {
        guard let exe = executablePath else {
            return ListResult(ok: false, terminals: [], error: "orca 실행 파일을 못 찾았다")
        }
        let r = run(exe: exe, args: ["terminal", "list", "--json"], timeout: timeout)
        guard r.ok else { return ListResult(ok: false, terminals: [], error: r.error) }
        guard let obj = json(r.out) else {
            return ListResult(ok: false, terminals: [], error: "list 응답을 JSON 으로 못 읽었다")
        }
        guard (obj["ok"] as? Bool) == true,
              let result = obj["result"] as? [String: Any],
              let rows = result["terminals"] as? [[String: Any]] else {
            return ListResult(ok: false, terminals: [], error: "list 가 ok:false 로 답했다")
        }
        var out: [Terminal] = []
        for r in rows {
            guard let h = r["handle"] as? String, !h.isEmpty else { continue }
            out.append(Terminal(
                handle: h,
                title: (r["title"] as? String) ?? "",
                worktreePath: (r["worktreePath"] as? String) ?? "",
                branch: (r["branch"] as? String) ?? "",
                agentIdentity: (r["agentIdentity"] as? String) ?? "",
                lastOutputAt: r["lastOutputAt"] as? Double))
        }
        return ListResult(ok: true, terminals: out, error: "")
    }

    // MARK: - 화면 해시

    enum ScreenState {
        case read(hash: String)     // 화면을 읽었다. 해시가 이전과 다르면 그 창은 움직였다.
        case stale                  // 핸들이 죽었다 — `terminal_handle_stale`
        case failed(String)         // 그 밖의 실패. 판정을 포기하는 것이지 죽었다는 뜻이 아니다.
    }

    // 렌더된 화면(`source: screen`)의 해시. 클로드 세션은 일하는 동안 스피너 줄과 토큰 카운터를
    // 계속 다시 그리므로 화면이 끊임없이 바뀌고, 멈춰 서 있으면 프레임이 그대로다. 45 초 간격으로
    // 두 번 읽어 실제로 확인했다(directive 의 `orca terminal read` 절).
    //
    // 화면 내용은 돌려주지 않는다. 해시만 낸다 — 다른 세션의 출력을 이 앱의 데이터 폴더로
    // 복사해 두지 않기 위한 것이고, 원장 파일이 커지는 것도 막는다.
    static func screenHash(handle: String, timeout: TimeInterval = 6) -> ScreenState {
        guard let exe = executablePath else { return .failed("orca 실행 파일을 못 찾았다") }
        guard isValidHandle(handle) else { return .failed("핸들 모양이 아니다") }
        let r = run(exe: exe, args: ["terminal", "read", "--terminal", handle, "--screen", "--json"],
                    timeout: timeout)
        guard let obj = json(r.out) else {
            return .failed(r.error.isEmpty ? "read 응답을 JSON 으로 못 읽었다" : r.error)
        }
        if (obj["ok"] as? Bool) != true {
            let code = ((obj["error"] as? [String: Any])?["code"] as? String) ?? ""
            if code == "terminal_handle_stale" { return .stale }
            return .failed(code.isEmpty ? "read 가 ok:false 로 답했다" : code)
        }
        guard let result = obj["result"] as? [String: Any],
              let term = result["terminal"] as? [String: Any] else {
            return .failed("read 응답에 terminal 이 없다")
        }
        // `draft`(사람이 입력창에 쳐 두고 아직 안 보낸 글)는 `tail` 에 안 들어 있다. 그것을
        // 움직임으로 세면 라이언이 타이핑만 해도 `도는 중` 이 되므로, 여기서도 안 읽는다.
        let tail = (term["tail"] as? [String]) ?? []
        return .read(hash: sha(tail.joined(separator: "\n")))
    }

    static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 프로세스

    private struct Run {
        var ok: Bool
        var out: String
        var error: String
    }

    // 셸을 거치지 않는다. 타임아웃을 넘기면 죽인다 — Orca 가 응답하지 않을 때 대시보드 요청이
    // 통째로 매달리면, 고치려던 것보다 나쁜 고장이 된다.
    private static func run(exe: String, args: [String], timeout: TimeInterval) -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            return Run(ok: false, out: "", error: "orca 를 띄우지 못했다: \(error.localizedDescription)")
        }

        // 파이프를 비우지 않으면 출력이 64KB 를 넘길 때 자식이 write 에서 막혀 영원히 안 끝난다.
        // `terminal list --json` 은 66 개 창에서 이미 30KB 급이라 남 얘기가 아니다.
        let box = NSMutableData()
        let lock = NSLock()
        let readQ = DispatchQueue(label: "cm.orca.read")
        readQ.async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); box.append(d); lock.unlock()
        }

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = sem.wait(timeout: .now() + 1)
            return Run(ok: false, out: "", error: "orca 가 \(Int(timeout))초 안에 안 끝났다")
        }
        // 읽기 스레드가 EOF 를 다 소화할 짧은 여유. 프로세스가 끝났으므로 곧 끝난다.
        readQ.sync {}
        _ = try? errPipe.fileHandleForReading.close()

        lock.lock(); let text = String(decoding: box as Data, as: UTF8.self); lock.unlock()
        let code = p.terminationStatus
        // 종료 코드가 0 이 아니어도 본문은 돌려준다. `read` 는 죽은 핸들에도 JSON 으로 답하고,
        // 그 JSON 의 error.code 가 우리가 원하는 판정이기 때문이다.
        return Run(ok: code == 0, out: text,
                   error: code == 0 ? "" : "orca 가 코드 \(code) 로 끝났다")
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
