import Foundation

// 이슈 상세의 [Orca 로 열기] — 결과물이 마음에 안 들 때 그 자리에서 그 일의 폴더로 넘어가
// 버전을 올리기 위한 것이다. 화면에서 "이건 아닌데" 를 알고 나서 창을 찾아 헤매는 동안
// 그 판단이 식는다. 그 사이를 없애는 것이 이 파일의 유일한 목적이다.
//
// 보안 규칙은 `AppDelegate.revealWorkQueuePath` 와 같은 자리에서 온다 — **호출자가 주는 것은
// 카드 키 하나뿐이다.** 작업 폴더도 터미널 제목도 서버가 카드와 `WorkQueueStore.lionWorkRoot`
// 에서 스스로 만든다. 웹뷰가 준 문자열이 셸로 들어가는 길은 이 파일에 없다.
//
// 이 파일은 AppDelegate 를 부르지 않는다. Core 가 AppDelegate 에 의존하면 방향이 거꾸로다
// (WorkQueueStore.swift 맨 아래에 같은 이유로 jsonStr 이 따로 있다). 그래서 shellQuote 도
// 여기에 자기 것을 둔다.
enum IssueOrcaLauncher {

    // 창을 띄운다. 돌려주는 것은 화면이 버튼 얼굴에 그대로 쓸 수 있는 JSON 한 덩어리다 —
    // 실패를 조용히 삼키면 라이언이 아무 일도 안 일어난 줄 알고 다른 창을 연다.
    static func launch(key: String) -> String {
        guard let card = find(key: key) else {
            return "{\"ok\":false,\"error\":\"unknown-card\"}"
        }

        // 작업 폴더는 카드가 아니라 워크스페이스 루트다. 카드의 `target:` 은 30 개가 비어 있고
        // 리스트인 것도 있어서 폴더로 못 쓴다. 루트에서 열면 아래가 다 보인다.
        let cwd = WorkQueueStore.lionWorkRoot.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return "{\"ok\":false,\"error\":\"missing-root\"}"
        }

        guard let orca = orcaBinary() else {
            return "{\"ok\":false,\"error\":\"no-orca\"}"
        }

        let base = card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? card.id : card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(("이슈 · " + base).prefix(60))

        // 2026-09-06. 예전에는 `--command "claude"` 였다 — 창은 떴지만 빈 세션이라 라이언이
        // 그 안에서 카드 경로를 다시 타이핑해야 했다. 이 버튼의 값은 창이 열리는 것이 아니라
        // **일이 시작되는** 것이다. 그래서 카드 파일을 읽고 그대로 실행하라는 지시를 첫 질의로
        // 같이 실어 보낸다. `claude '<프롬프트>'` 는 그 질의를 이미 제출한 채로 대화 세션을
        // 연다 — 핸들을 되받아 `terminal send` 로 밀어 넣는 것과 달리 부팅 타이밍과 경주하지
        // 않고 프로세스도 하나뿐이다.
        //
        // ASSUMPTION (L1, 갈래를 스스로 골랐다): 이 주입을 `launch()` 안에 두어 **모든** 호출자가
        // 같은 동작을 받게 했다. 화면의 `orcaBtn()` 은 한 벌뿐이고 서버로 오는 것은 카드 키
        // 하나라, 결과물 절의 버튼과 새로 붙는 카드 파일 절의 버튼이 이 한 줄로 같이 고쳐진다.
        // 모드 인자를 만들어 갈래를 나누지 않았다 — 두 자리가 다르게 동작할 이유가 없다.
        //
        // ASSUMPTION (L1, 갈래를 스스로 골랐다): 카드 파일이 비었거나 디스크에 없으면 새 에러
        // 코드를 만들지 않고 예전의 맨 `claude` 로 조용히 내려간다. 창이라도 뜨는 것이 깨진
        // 프롬프트를 물고 뜨는 것보다 낫다.
        //
        // 경로는 웹뷰가 아니라 서버가 카드에서 꺼낸 것이다 — 파일 맨 위의 보안 규칙 그대로,
        // 웹뷰가 준 문자열이 셸로 들어가는 길은 여기에도 없다.
        let cardPath = card.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeCmd: String
        if !cardPath.isEmpty, FileManager.default.fileExists(atPath: cardPath) {
            let prompt = "이 카드 파일을 읽고 그 안에 적힌 일을 지금 실행해라: " + cardPath
            // 두 겹 인용이다. 안쪽은 orca 가 터미널 셸에 넘길 때 한 인자로 묶기 위한 것이고,
            // 바깥쪽은 이 문자열이 `/bin/bash -lc` 로 갈 때 `--command` 값 하나로 묶기 위한 것이다.
            claudeCmd = shellQuote("claude " + shellQuote(prompt))
        } else {
            claudeCmd = "claude"
        }

        // `--focus` 는 일부러 넣는다. 라이언이 이 버튼을 누르는 이유가 그 창에 **있으려는**
        // 것이라, 띄우기만 하고 안 옮겨 주면 창을 찾는 일이 그대로 남는다.
        let cmd = [shellQuote(orca), "terminal", "create",
                   "--worktree", shellQuote("path:" + cwd),
                   "--title", shellQuote(title),
                   "--command", claudeCmd,
                   "--focus", "--json"].joined(separator: " ")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 로그인 셸로 띄운다 — PATH 가 라이언의 터미널과 같게 풀려야 orca 가 쓰는 것들이
        // 같은 자리에서 잡힌다 (AppDelegate 의 claude 호출과 같은 패턴이다).
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            return "{\"ok\":false,\"error\":\"orca-failed\",\"detail\":\(jsonStr(error.localizedDescription))}"
        }
        // 감시견. 멈춘 프로세스가 연결 스레드를 물고 있으면 대시보드 전체가 선다.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0 else {
            let detail = String(String(decoding: data, as: UTF8.self).prefix(200))
            return "{\"ok\":false,\"error\":\"orca-failed\",\"detail\":\(jsonStr(detail))}"
        }
        return "{\"ok\":true,\"title\":\(jsonStr(title)),\"cwd\":\(jsonStr(cwd))}"
    }

    // MARK: - 카드 찾기

    // `WorkQueueStore.detailJSON(id:)` 과 **같은 규칙**이다. 레인+파일명이 먼저이고, 그것으로
    // 안 잡히면 id/파일명으로 찾되 `done/` 을 고른다(나중 상태). 같은 `id:` 를 가진 카드가
    // 두 레인에 하나씩 남은 쌍이 4 쌍 있어서 규칙이 갈리면 다른 카드가 열린다.
    private static func find(key rawKey: String) -> WorkQueueStore.Card? {
        let id = rawKey.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let list = WorkQueueStore.cards()
        let lane = id.components(separatedBy: "/")
        if lane.count == 2,
           let hit = list.first(where: { $0.folder == lane[0] && $0.fileName == lane[1] + ".md" }) {
            return hit
        }
        let byID = list.filter { $0.id == id || $0.fileName == id + ".md" }
        return byID.first(where: { $0.folder == "done" }) ?? byID.first
    }

    // MARK: - orca 찾기

    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 고정 경로 둘을 먼저 보고 그 다음에 로그인 셸의
    // `command -v` 로 떨어진다. 이 맥에서는 `/usr/local/bin/orca` 가 Orca.app 안의 실체를
    // 가리키는 링크라 첫 줄에서 끝난다. 셸을 먼저 부르면 버튼 한 번마다 로그인 셸이 한 번
    // 더 뜨고, 그 값이 눌릴 때마다 붙는다.
    private static func orcaBinary() -> String? {
        let fm = FileManager.default
        for p in ["/usr/local/bin/orca", "/opt/homebrew/bin/orca"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v orca"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = nil
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let found = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }

    // MARK: - 인용

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsonStr(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        t.removeFirst(); t.removeLast()
        return t
    }
}
