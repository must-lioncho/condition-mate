import Foundation

// MCP 서버 실검사 — "등록했다"와 "실제로 붙는다"는 다르다.
//
// 왜 필요한가: 등록은 ~/.claude.json 에 줄 하나를 넣는 일이라 언제나 성공한다.
// 그 줄이 가리키는 서버가 뜨는지, 승인이 끝났는지, 도구가 몇 개 붙는지는 아무도
// 확인하지 않았다 — 사용자는 스위치를 켜 놓고 다음 Claude 세션에서야 안 붙는다는
// 걸 알게 됐다. 특히 브라우저 승인 방식은 '승인 창이 언제 뜨는지'조차 화면에
// 안 나와서, 아무 반응이 없는 스위치를 여러 번 누르게 됐다.
//
// 그래서 앱이 직접 서버를 한 번 띄워 본다. 런처 스크립트를 그대로 실행하고
// (Claude가 띄우는 것과 같은 경로) MCP 핸드셰이크를 말한 뒤 tools/list 까지 받아
// 도구 개수를 센다. 여기까지 오면 '붙는다'가 사실로 확인된 것이다.
//
// 오래 걸린다: npx 콜드 스타트 몇 초, 승인이 안 돼 있으면 사람이 브라우저에서
// 로그인하는 시간까지. 그래서 요청을 붙잡지 않고 백그라운드에서 돌리며 단계를
// 상태로 남기고, 화면이 그걸 폴링해 스피너와 문구를 갱신한다.
//
// 도구 개수만으로는 부족하다: "도구 28개"는 앱만 아는 사실이라, 사용자는 정말 내
// 워크스페이스에 닿은 건지 확인할 방법이 없었다. 그래서 마지막에 도구를 하나 실제로
// 호출해 사람이 눈으로 볼 수 있는 흔적을 남긴다 — 노션이면 테스트 페이지 하나를
// 만들고 그 URL을 화면에 링크로 띄운다. 열어 보면 끝난다.
public enum MCPProbe {

    // 진행 단계. 화면은 이 문자열로 스피너를 켜고 끈다.
    //   starting  — 프로세스를 띄우는 중 (npx 다운로드 포함)
    //   auth      — 승인 대기: 브라우저 창이 열렸고 사람이 로그인해야 한다
    //   handshake — 서버와 말이 통했다, 도구 목록을 받는 중
    //   verify    — 도구를 실제로 한 번 호출하는 중 (테스트 페이지 생성)
    //   ok / error— 끝
    public struct State {
        public var phase: String
        public var detail: String
        public var tools: Int
        public var error: String
        // 실행 증거 — 사람이 열어 볼 수 있는 주소. 없으면 빈 문자열.
        public var url: String
        public var at: Date
    }

    // 확인 행동 — "붙었다"를 사람이 확인할 수 있는 흔적으로 바꾸는 도구 호출 한 번.
    // 서버 종류마다 다르고, 정의가 없는 종류는 예전처럼 도구 개수까지만 확인한다.
    private struct Verify {
        let tool: String            // tools/list 에 이 이름이 있어야 호출한다
        let args: [String: Any]
        let progress: String        // 진행 중 문구
        let label: String           // 결과 링크 문구
    }

    // 확인용으로 만들 노션 페이지. 워크스페이스 최상위 개인 페이지로 만든다(부모를
    // 지정하지 않으면 그렇게 된다) — 남의 문서 밑에 끼워 넣지 않기 위해서다.
    private static func verifySpec(kind: String) -> Verify? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = f.string(from: Date())
        switch kind {
        case "notion", "notion-oauth":
            let body = """
            Condition Mate 앱의 MCP 연동 테스트가 만든 페이지입니다.

            - 만든 시각: \(stamp)
            - 뜻: 이 페이지가 보인다면 앱이 이 워크스페이스에 실제로 쓰기까지 성공한 것입니다.

            지워도 됩니다.
            """
            return Verify(tool: "notion-create-pages",
                          args: ["pages": [["properties": ["title": "Condition Mate 연결 테스트 — \(stamp)"],
                                            "icon": "✅",
                                            "content": body]]],
                          progress: "노션에 테스트 페이지를 만드는 중…",
                          label: "테스트 페이지 열기")
        default:
            return nil
        }
    }

    private static let lock = NSLock()
    private static var states: [String: State] = [:]
    private static var running: [String: Process] = [:]

    // 전체 상한. 승인은 사람이 브라우저에서 하는 일이라 넉넉해야 하지만, 무한정
    // 켜 두면 사용자가 창을 닫고 잊은 프로세스가 남는다.
    private static let deadline: TimeInterval = 180

    // 사람에게 행동을 요구하는 줄만. 이미 승인된 경로에서도 나오는 일반 로그
    // ("Discovered authorization server", "Connecting to remote server")는 여기 없다.
    private static let authMarkers = [
        "please visit", "opening browser", "open the following", "browser for authorization",
        "waiting for auth", "authorization code", "authenticate in your browser",
    ]

    // 승인 없이 붙는 경우 핸드셰이크는 몇 초면 끝난다. 그보다 오래 끌면 사람이
    // 무언가 해야 하는 상황일 가능성이 크므로, 로그에 단서가 없어도 그렇게 말해 준다
    // — 단, 열렸다고 단정하지 않고 확인해 보라고 한다.
    private static let assumeAuthAfter: TimeInterval = 12

    public static func state(_ id: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        return states[id]
    }

    public static func isRunning(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running[id] != nil
    }

    private static func set(_ id: String, phase: String, detail: String = "",
                            tools: Int = 0, error: String = "", url: String = "") {
        lock.lock()
        // 이미 끝난 검사를 뒤늦은 출력이 되살리지 않게 한다 (프로세스를 죽인 뒤에도
        // 파이프에 남은 줄이 한두 개 더 흘러나온다).
        if let cur = states[id], cur.phase == "ok" || cur.phase == "error",
           phase != "ok", phase != "error" {
            lock.unlock(); return
        }
        states[id] = State(phase: phase, detail: detail, tools: tools, error: error,
                           url: url, at: Date())
        lock.unlock()
    }

    // 검사 시작. 이미 돌고 있으면 그 검사를 그대로 둔다 — 버튼을 두 번 눌렀다고
    // 승인 창이 두 개 뜨면 안 된다 (사용자가 반응 없는 버튼을 연타한 그 상황).
    @discardableResult
    public static func start(cred: Credential, inst: CredInstance,
                             onFinish: @escaping (Bool, Int, String, String) -> Void) -> Bool {
        let id = inst.compositeId
        lock.lock()
        if running[id] != nil { lock.unlock(); return false }
        lock.unlock()
        set(id, phase: "starting", detail: "서버를 띄우는 중…")

        guard let spec = cred.mcp else {
            set(id, phase: "error", error: "MCP 서버가 없는 연동입니다")
            return true
        }
        guard MCPRegistrar.writeLauncher() else {
            set(id, phase: "error", error: "런처 스크립트를 만들지 못했습니다")
            return true
        }
        let opt = cred.authOption(inst.mode)
        let kind = opt.mcpKind.isEmpty ? spec.kind : opt.mcpKind
        var args: [String] = [kind, opt.needsToken
                              ? CredInstance.service(base: cred.service, key: inst.key) : "-"]
        if kind == "jira" {
            let email = (inst.fields["email"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else {
                set(id, phase: "error", error: "계정 이메일을 먼저 입력하세요")
                return true
            }
            args.append(email)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let r = run(id: id, args: args)
            lock.lock(); running.removeValue(forKey: id); lock.unlock()
            if r.ok {
                // 증거가 있으면 그것이 결론이다. 확인 행동을 걸었는데 실패했다면
                // 그 사실도 감추지 않는다 — 연결은 됐지만 쓰지는 못한 상태다.
                var detail = "도구 \(r.tools)개 확인"
                if !r.url.isEmpty {
                    detail += " · 테스트 페이지를 만들었습니다"
                } else if !r.verifyErr.isEmpty {
                    detail += " · 확인 페이지를 만들지 못했습니다: \(r.verifyErr)"
                }
                set(id, phase: "ok", detail: detail, tools: r.tools, url: r.url)
            } else {
                set(id, phase: "error", error: r.err.isEmpty ? "연결하지 못했습니다" : r.err)
            }
            onFinish(r.ok, r.tools, r.url, r.ok ? r.verifyErr : r.err)
        }
        return true
    }

    // MARK: 실제 검사

    private struct Outcome {
        var ok = false
        var tools = 0
        var url = ""
        var verifyErr = ""      // 연결은 됐는데 확인 행동만 실패한 경우의 사유
        var err = ""            // 연결 자체가 실패한 사유
    }

    private static func run(id: String, args: [String]) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: MCPRegistrar.launcherPath)
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        // 확인 행동은 검사 시작 시점에 한 번 정해 둔다 — 페이지 제목의 시각이
        // 응답이 오는 시점이 아니라 사용자가 버튼을 누른 시점이어야 한다.
        let vspec = verifySpec(kind: args.first ?? "")

        // stdout — MCP stdio 전송은 줄바꿈으로 끊는 JSON-RPC다. 한 줄이 쪼개져
        // 도착할 수 있으므로 버퍼에 모았다가 개행 단위로 잘라 읽는다.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            box.lock.lock()
            box.buf.append(data)
            var lines: [String] = []
            while let i = box.buf.firstIndex(of: 0x0A) {
                let line = box.buf[box.buf.startIndex..<i]
                box.buf.removeSubrange(box.buf.startIndex...i)
                lines.append(String(decoding: line, as: UTF8.self))
            }
            box.lock.unlock()
            for line in lines {
                handle(line, id: id, box: box, inPipe: inPipe, sem: sem, verify: vspec)
            }
        }
        // stderr — mcp-remote 는 승인 안내를 여기로 흘린다. 사용자가 지금 무엇을
        // 기다리는지가 이 줄에만 있어서, 화면 문구를 여기서 바꾼다.
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            let text = String(decoding: data, as: UTF8.self)
            box.lock.lock()
            box.err = String((box.err + text).suffix(2000))
            box.lock.unlock()
            // 'authoriz' 같은 넓은 단어로 잡으면 안 된다 — 승인이 이미 끝나 그냥
            // 붙는 경우에도 "Discovered authorization server..." 가 흘러나와서,
            // 열리지도 않은 창을 열렸다고 말하게 된다(실제로 그렇게 틀렸다).
            // 사람에게 무언가 하라고 시키는 줄만 골라 잡는다.
            for line in text.split(separator: "\n") {
                let low = line.lowercased()
                guard authMarkers.contains(where: { low.contains($0) }) else { continue }
                var detail = "브라우저에서 승인을 완료하세요 — 창이 안 보이면 다른 창 뒤에 있을 수 있습니다"
                if let r = line.range(of: "http"), let url = line[r.lowerBound...]
                    .split(separator: " ").first {
                    detail += "\n" + String(url)
                }
                set(id, phase: "auth", detail: detail)
                break
            }
        }

        guard (try? p.run()) != nil else {
            return Outcome(err: "런처를 실행하지 못했습니다")
        }
        lock.lock(); running[id] = p; lock.unlock()

        // 핸드셰이크 시작. 응답이 오면 handle()이 다음 요청을 이어서 보낸다.
        send(inPipe, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "ConditionMate", "version": "1.0"],
        ]])

        // 오래 끌면 승인 대기로 본다 (로그에 단서가 없는 경우의 안전망).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + assumeAuthAfter) { [weak p] in
            box.lock.lock(); let settled = box.done || box.exited; box.lock.unlock()
            guard !settled, p?.isRunning == true else { return }
            lock.lock(); let phase = states[id]?.phase ?? ""; lock.unlock()
            guard phase == "starting" else { return }
            set(id, phase: "auth",
                detail: "응답이 오래 걸립니다 — 브라우저에 승인 창이 떴는지 확인해 주세요")
        }

        // 프로세스가 먼저 죽으면(런처 exit 69 등) 기다릴 이유가 없다.
        let watchdog = DispatchQueue.global(qos: .utility)
        watchdog.async {
            p.waitUntilExit()
            box.lock.lock(); box.exited = true; box.lock.unlock()
            sem.signal()
        }

        let timedOut = sem.wait(timeout: .now() + deadline) == .timedOut
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        box.lock.lock()
        let ok = box.done, tools = box.tools, exited = box.exited
        let url = box.url, verifyErr = box.verifyErr
        let tail = lastLine(box.err)
        box.lock.unlock()

        if ok { return Outcome(ok: true, tools: tools, url: url, verifyErr: verifyErr) }
        if timedOut {
            return Outcome(err: "시간이 초과됐습니다 — 승인 창을 닫았거나 서버가 응답하지 않습니다")
        }
        if exited {
            return Outcome(err: tail.isEmpty ? "서버가 바로 종료됐습니다" : tail)
        }
        return Outcome(err: tail)
    }

    // 응답 한 줄을 읽고 다음 단계로 넘어간다. initialize 응답 → 도구 목록 요청 →
    // (확인 행동이 있으면) 도구 호출 한 번 → 끝. 그 외의 줄(알림·로그)은 무시한다.
    private static func handle(_ line: String, id: String, box: Box, inPipe: Pipe,
                               sem: DispatchSemaphore, verify: Verify?) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rid = (obj["id"] as? NSNumber)?.intValue
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "서버가 오류를 돌려줬습니다"
            box.lock.lock()
            // 확인 행동(3번)의 실패는 연결 실패가 아니다 — 붙기는 붙었는데 그 토큰으로
            // 쓸 수 없는 것이다. 두 사실을 뭉뚱그리면 멀쩡한 연동이 '실패'로 보인다.
            if rid == 3 { box.verifyErr = msg; box.done = true } else { box.err = msg }
            box.lock.unlock()
            sem.signal()
            return
        }
        guard let rid = rid else { return }
        if rid == 1 {
            set(id, phase: "handshake", detail: "연결됨 — 도구 목록을 받는 중…")
            send(inPipe, ["jsonrpc": "2.0", "method": "notifications/initialized"])
            send(inPipe, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
            return
        }
        if rid == 2 {
            let list = ((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let names = Set(list.compactMap { $0["name"] as? String })
            box.lock.lock(); box.tools = list.count; box.lock.unlock()
            // 확인 행동이 정의돼 있고 그 도구가 실제로 붙어 있을 때만 호출한다.
            // 서버 버전이 달라 이름이 없으면 예전처럼 도구 개수까지가 결론이다.
            if let v = verify, names.contains(v.tool) {
                set(id, phase: "verify", detail: v.progress, tools: list.count)
                send(inPipe, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                              "params": ["name": v.tool, "arguments": v.args]])
                return
            }
            box.lock.lock(); box.done = true; box.lock.unlock()
            sem.signal()
            return
        }
        if rid == 3 {
            let result = obj["result"] as? [String: Any]
            let text = resultText(result)
            box.lock.lock()
            if (result?["isError"] as? Bool) == true {
                box.verifyErr = String(text.prefix(160))
            } else if let url = firstURL(text) {
                box.url = url
            } else {
                // 만들었다는데 주소가 없다 — 사용자가 열어 볼 수 없으므로 증거가 아니다.
                box.verifyErr = "만든 페이지의 주소를 찾지 못했습니다"
            }
            box.done = true
            box.lock.unlock()
            sem.signal()
        }
    }

    // tools/call 결과의 텍스트 블록만 이어 붙인다 (이미지·리소스 블록은 버린다).
    private static func resultText(_ result: [String: Any]?) -> String {
        guard let blocks = result?["content"] as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // 결과에서 사람이 열어 볼 첫 주소. 서버마다 응답 모양이 달라 파싱하지 않고
    // 주소만 집어낸다 — 여기서 필요한 건 "이 링크를 누르면 그것이 보인다" 하나뿐이다.
    private static func firstURL(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "https://[^\\s\"'<>)\\]]+") else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        // 문장 끝의 마침표·쉼표까지 주소로 삼으면 링크가 깨진다.
        var url = ns.substring(with: m.range)
        while let last = url.last, ".,;:".contains(last) { url.removeLast() }
        return url.isEmpty ? nil : url
    }

    private static func send(_ pipe: Pipe, _ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        // 서버가 이미 죽었으면 쓰기가 SIGPIPE를 던진다 — 앱이 통째로 죽지 않게 감싼다.
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    private static func lastLine(_ s: String) -> String {
        let line = s.split(separator: "\n").map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    // 핸들러 스레드와 검사 스레드가 함께 만지는 값들.
    private final class Box {
        let lock = NSLock()
        var buf = Data()
        var err = ""
        var tools = 0
        var url = ""
        var verifyErr = ""
        var done = false
        var exited = false
    }
}
