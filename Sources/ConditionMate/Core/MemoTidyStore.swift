import Foundation
import AppKit

// 메모장 'AI로 정리해서 복사' 의 백그라운드 잡 (2026-08-12).
//
// WHY: 메모는 생각나는 대로 적은 초안이라 오타·줄 구조가 들쭉날쭉하다. 남에게 넘길 때
// (거의 언제나 슬랙에 붙여넣을 때)만 그걸 다듬는데, 그 다듬기를 사람이 매번 손으로 하고
// 있었다. 그 일은 클로드 코드가 훨씬 잘한다 — 다만 한 번 부르는 데 1~5분이 걸린다.
//
// 그래서 '기다리는 버튼' 이 아니라 '맡겨 두는 일' 로 모델링한다:
//   1. 패드 우클릭 → AI로 정리해서 복사 → POST /api/memo/tidy 는 즉시 돌아온다.
//   2. 잡은 왼쪽 레일의 'AI 정리' 줄로 올라가 경과 시간이 오른다(멈춘 화면이 없다).
//   3. 끝나면 결과가 곧바로 클립보드에 들어간다 — 사용자가 슬랙 창에 있으면 ⌘V 뿐이다.
//   4. 그 사이 딴 일을 했더라도 레일 줄을 눌러 언제든 다시 복사한다(결과는 남는다).
//
// 실패는 조용하다(앱 규칙 — 실패 배너 없음). 레일 줄이 '실패' 로 남고 로그에만 사유가 간다.
//
// 저장: <data>/memo-tidy.json 에 최근 잡 20건. 앱을 재시작해도 어제 정리한 결과를 다시
// 복사할 수 있어야 하고, 파일이 하나뿐이라 메모 본문(memo.json)과 블라스트 반경이 겹치지
// 않는다. 원문(src)은 싣지 않는다 — 결과만 있으면 다시 복사에는 충분하고, 메모 본문이
// 두 벌로 디스크에 남을 이유가 없다.
final class MemoTidyStore {
    static let shared = MemoTidyStore()

    struct Job {
        var id: String
        var title: String          // 레일 줄에 적히는 짧은 이름 (원문 첫 줄)
        var startedAt: Double
        var endedAt: Double        // 0 = 아직 진행 중
        var status: String         // running | done | failed
        var chars: Int             // 원문 글자 수
        var result: String         // 정리된 본문 (done 일 때만)
        var error: String          // 실패 사유 (failed 일 때만)
    }

    private static let keepJobs = 20
    private static let maxChars = 64 * 1024      // 한 번에 넘길 수 있는 초안 상한
    private static let timeoutSec = 600.0        // 10분 — 1~5분이 보통, 그 밖은 죽은 것으로 본다

    private let fileURL: URL
    private let lock = NSLock()
    private var jobs: [Job] = []                 // 최신이 먼저

    private init() {
        fileURL = AppPaths.base.appendingPathComponent("memo-tidy.json", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["jobs"] as? [[String: Any]] {
            jobs = arr.map {
                Job(id: ($0["id"] as? String) ?? "",
                    title: ($0["title"] as? String) ?? "",
                    startedAt: ($0["startedAt"] as? NSNumber)?.doubleValue ?? 0,
                    endedAt: ($0["endedAt"] as? NSNumber)?.doubleValue ?? 0,
                    status: ($0["status"] as? String) ?? "failed",
                    chars: ($0["chars"] as? NSNumber)?.intValue ?? 0,
                    result: ($0["result"] as? String) ?? "",
                    error: ($0["error"] as? String) ?? "")
            }
            // 진행 중이던 잡은 앱이 죽으며 함께 죽었다 — 되살아난 척하지 않는다.
            for i in jobs.indices where jobs[i].status == "running" {
                jobs[i].status = "failed"
                jobs[i].error = "앱이 종료되어 중단됨"
                jobs[i].endedAt = Date().timeIntervalSince1970
            }
        }
    }

    // MARK: 시작

    // 초안을 받아 잡을 세우고 백그라운드에서 claude 를 돌린다. 즉시 돌아온다.
    // 반환은 세워진 잡의 id (세우지 못했으면 nil — 빈 글, CLI 없음).
    @discardableResult
    func start(text: String) -> String? {
        let src = String(text.prefix(Self.maxChars))
        guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let claude = AppDelegate.resolveClaude() else {
            AppLog.log("memo-tidy: claude CLI 를 찾지 못했습니다")
            return nil
        }
        let id = "t\(Int(Date().timeIntervalSince1970 * 1000))"
        let job = Job(id: id, title: Self.titleOf(src), startedAt: Date().timeIntervalSince1970,
                      endedAt: 0, status: "running", chars: src.count, result: "", error: "")
        lock.lock(); jobs.insert(job, at: 0); trimLocked(); let snap = jobs; lock.unlock()
        persist(snap)
        AppLog.log("memo-tidy: 시작 \(id) — \(src.count)자")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.run(id: id, claude: claude, src: src)
        }
        return id
    }

    // MARK: 조회 · 다시 복사

    func jsonPayload() -> String {
        lock.lock(); let snap = jobs; lock.unlock()
        let rows = snap.map { j -> [String: Any] in
            // 목록에는 결과 전문을 싣지 않는다(레일이 3초마다 읽는 길이다) — 미리보기만.
            ["id": j.id, "title": j.title, "startedAt": Int(j.startedAt), "endedAt": Int(j.endedAt),
             "status": j.status, "chars": j.chars, "outChars": j.result.count,
             "preview": String(j.result.prefix(180)), "error": j.error]
        }
        let obj: [String: Any] = ["jobs": rows]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{\"jobs\":[]}" }
        return s
    }

    // 한 잡의 결과 전문 (레일 팝업이 열릴 때 한 번 읽는다).
    func result(id: String) -> String? {
        lock.lock(); let hit = jobs.first { $0.id == id }; lock.unlock()
        guard let j = hit, j.status == "done", !j.result.isEmpty else { return nil }
        return j.result
    }

    // 결과 전문을 JSON 으로 (GET /api/memo/tidy?id=…).
    func resultJSON(id: String) -> String {
        let text = result(id: id) ?? ""
        let obj: [String: Any] = ["ok": !text.isEmpty, "text": text]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{\"ok\":false,\"text\":\"\"}" }
        return s
    }

    // 끝난 잡의 결과를 다시 클립보드에 넣는다 (레일 줄의 '복사').
    func copyToPasteboard(id: String) -> Bool {
        guard let text = result(id: id) else { return false }
        Self.writeClipboard(text)
        return true
    }

    // MARK: 실행

    private func run(id: String, claude: String, src: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 도구도 프로젝트 컨텍스트도 필요 없는 순수 텍스트 작업이다 — 한 번의 왕복이면 끝난다.
        //
        // `exec` 가 중요하다: 이게 없으면 bash 가 claude 를 자식으로 포크하고, 아래 타임아웃의
        // terminate() 는 bash 만 죽인다. 살아남은 claude 가 stdout 파이프를 계속 쥐고 있어
        // readDataToEndOfFile 이 영원히 돌아오지 않고, 잡은 '진행 중' 에 붙박인다(실측 —
        // 게이트웨이가 닿지 않는 동안 SYN_SENT 로 멈춘 채 10분 타임아웃도 소용이 없었다).
        // exec 로 bash 가 스스로를 claude 로 갈아입으면 우리가 아는 pid 가 곧 claude 다.
        p.arguments = ["-lc", "exec \(AppDelegate.shellQuote(claude)) -p --output-format json 2>/dev/null"]
        p.environment = AppDelegate.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch {
            finish(id: id, result: "", error: "claude 실행 실패")
            return
        }
        // 타임아웃으로 끊었는지는 종료 코드로 알 수 없다 — claude 는 SIGTERM 을 받아도
        // 스스로 정리하고 '오류 JSON' 을 뱉으며 정상 종료로 끝난다(실측). 그래서 우리가
        // 끊었다는 사실만은 우리가 기억한다. 그래야 실패 사유가 '시간 초과' 로 남는다.
        let cut = Flag()
        let killer = DispatchWorkItem { cut.set(); if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSec, execute: killer)
        inPipe.fileHandleForWriting.write(Data(Self.prompt(src).utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        if cut.isSet || p.terminationReason == .uncaughtSignal {
            finish(id: id, result: "", error: "시간이 너무 오래 걸려 중단됨(10분)")
            return
        }
        let raw = String(decoding: outData, as: UTF8.self)
        var reply = ""
        if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any] {
            // 실패한 왕복도 200줄짜리 JSON 한 덩이로 돌아온다. 그 덩이를 '정리된 글' 로
            // 착각하면 인증 오류 JSON 이 통째로 클립보드에 실려 슬랙으로 나간다(실측 —
            // 게이트웨이가 닿지 않던 동안 실제로 그렇게 됐다). 그래서 성공 여부를 먼저 본다.
            let text = (parsed["result"] as? String) ?? ""
            let isErr = ((parsed["is_error"] as? NSNumber)?.boolValue ?? false)
                        || (parsed["type"] as? String) == "error"
            if isErr {
                let why = text.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(id: id, result: "", error: why.isEmpty ? "claude 오류" : String(why.prefix(160)))
                return
            }
            reply = text
        } else {
            // JSON 이 아니면 평문 출력으로 본다(포맷이 바뀐 CLI 에서도 글은 건진다).
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        reply = Self.unfence(reply)
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish(id: id, result: "", error: "응답이 비어 있음")
            return
        }
        finish(id: id, result: reply, error: "")
    }

    private func finish(id: String, result: String, error: String) {
        lock.lock()
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        jobs[i].endedAt = Date().timeIntervalSince1970
        jobs[i].status = error.isEmpty ? "done" : "failed"
        jobs[i].result = result
        jobs[i].error = error
        let took = Int(jobs[i].endedAt - jobs[i].startedAt)
        let snap = jobs
        lock.unlock()
        persist(snap)
        if error.isEmpty {
            // 성공의 보상은 곧바로 클립보드다 — 사용자가 이미 슬랙 창에 있다면 ⌘V 뿐이다.
            Self.writeClipboard(result)
            AppLog.log("memo-tidy: 완료 \(id) — \(result.count)자 · \(took)초 · 클립보드")
        } else {
            AppLog.log("memo-tidy: 실패 \(id) — \(error) · \(took)초")
        }
    }

    // MARK: 조각

    private func trimLocked() {
        if jobs.count > Self.keepJobs { jobs = Array(jobs.prefix(Self.keepJobs)) }
    }

    private func persist(_ snap: [Job]) {
        let rows = snap.map { j -> [String: Any] in
            ["id": j.id, "title": j.title, "startedAt": j.startedAt, "endedAt": j.endedAt,
             "status": j.status, "chars": j.chars, "result": j.result, "error": j.error]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["jobs": rows]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func writeClipboard(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // 레일 줄에 적힐 이름 — 원문의 첫 알맹이 줄. 상태 토큰·들여쓴 칸 줄은 건너뛴다.
    private static func titleOf(_ src: String) -> String {
        for line in src.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            for token in ["- [ ] ", "- [x] ", "- [!] "] where t.hasPrefix(token) {
                t = String(t.dropFirst(token.count))
            }
            if t.hasPrefix("@") { continue }
            if t.isEmpty { continue }
            return t.count > 28 ? String(t.prefix(28)) + "…" : t
        }
        return "메모 정리"
    }

    // 모델이 습관적으로 감싸는 ```…``` 울타리를 벗긴다 — 슬랙에 붙일 평문이 목적이다.
    private static func unfence(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
              let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```",
              lines.count > 2 else { return lines.joined(separator: "\n") }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    // 타임아웃 타이머(다른 큐)와 실행 스레드가 함께 보는 한 칸짜리 깃발.
    private final class Flag {
        private let l = NSLock()
        private var v = false
        func set() { l.lock(); v = true; l.unlock() }
        var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    }

    private static func prompt(_ src: String) -> String {
        return """
        아래는 사용자가 메모장에 빠르게 적어 둔 초안입니다. 슬랙에 그대로 붙여넣을 수 있도록 다듬어 주세요.

        규칙:
        - 오타, 띄어쓰기, 문법을 고칩니다.
        - 원문의 의미와 정보는 바꾸지 않습니다. 없는 내용을 채워 넣거나 요약해 줄이지 마세요.
        - 원문의 언어를 그대로 둡니다(영어로 적힌 줄은 영어로, 한국어 줄은 한국어로).
        - 줄 순서는 원문 그대로. 들여쓰기·번호·목록만 읽기 좋게 정리합니다.
        - 링크는 원문 그대로 둡니다.
        - 코드블록(```)이나 마크다운 표는 쓰지 마세요. 슬랙에 붙일 평문입니다.
        - 설명·머리말·맺음말 없이 정리된 본문만 출력하세요.

        [초안]
        \(src)
        """
    }
}
