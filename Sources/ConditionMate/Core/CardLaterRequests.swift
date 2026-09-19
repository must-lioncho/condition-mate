import Foundation

// 카드가 던져진 뒤에 라이언이 목적지 창에서 **더 말한 것**을 되찾는다.
//
// 2026-09-06 에 라이언: "두번째 파일을 보면은 이제 내가 좀 더 디테일한 내용을 작성한 거야
// 그래서 요 내용이 나와야 되는데 요 내용이있지 않아 그래서 지금 내가 원하던 결과가 아니거든."
//
// 그날 조사해서 확정한 원인이 이 파일이 존재하는 이유다. **아무 데서도 잘리지 않았다.**
// 트랙 카드는 최상위 창에 처음 들어온 발화 한 번의 스냅샷이고, 그 뒤에 라이언이 목적지
// 창에서 말한 것을 카드로 되돌리는 경로가 시스템 어디에도 없다.
//
// 실측이 그대로 그것이다. `2026-09-05-2024-linkedin-version-scope` 카드는 `14:54Z` 에
// 쓰였고 그 안의 `## 원문` 은 41 자다. 그런데 그 카드가 띄운 목적지 세션
// (`lion-contents` 의 `7b59cb18-…`) 에는 `17:28:31Z` 에 757 자, `17:30:28Z` 에 1123 자짜리
// 사람 발화가 더 들어와 있다 — 타이틀 훅, 400명, AX 0~6레벨, 자율에이전트 6단계까지.
// 카드가 쓰인 지 2 시간 34 분 뒤다. 라이언이 화면에서 "내가 원했던 내용과 다르다" 고 한 것은
// 카드가 달라진 것이 아니라 **요구가 다른 창에서 자랐고 그 자란 부분이 여기 도착하지 않은 것**이다.
//
//   ★ 카드 파일에는 한 바이트도 쓰지 않는다. ★
//
// 큐 폴더를 읽기 전용으로 다루는 것은 AppDelegate 의 `/api/issues` 주석에 적힌 불변식이다.
// 그래서 이 파일은 되쓰기를 하지 않고 **읽는 시점에 파생**한다. 재료는 이미 디스크에 있다 —
// 목적지 세션의 트랜스크립트가 `~/.claude/projects/<슬러그>/<세션>.jsonl` 에 남는다.
//
// 어느 트랜스크립트가 그 카드의 것인지는 **첫 사람 턴에 카드 id 가 들어 있는가**로 가른다.
// 디렉터가 넘기는 지시문의 머리에 `카드 id: <id>` 가 그대로 들어가기 때문이고, 그 한 줄이
// 카드와 세션을 잇는 유일한 열쇠다. 창 손잡이(`target_handle`)로 잇지 않는 이유는 손잡이가
// 터미널의 것이지 세션의 것이 아니라서, 그 창에서 `/clear` 를 하거나 창을 재사용하면 같은
// 손잡이가 다른 트랜스크립트를 가리키기 때문이다.
//
// ★ 같은 판정 규칙을 `Core/WorkQueueSessionStore.swift` 도 쓴다(SPEC DASH-12). 그쪽은 상세
//   화면의 `작업지시서`·`결과물` 칸을 세션에서 채우고, `target:` 이 빈 카드를 위해 지시문 색인
//   갈래를 하나 더 갖고 있다. 열쇠("첫 사람 턴에 카드 id")를 고치면 두 곳을 같이 고쳐야 한다.
enum CardLaterRequests {

    // 한 카드에 붙는 나중 발화 전체. 검색 코퍼스에 실을 만큼만 모은다.
    private static let totalLimit = 2000
    // 트랜스크립트 한 개를 읽는 상한. 세션 파일은 15MB 까지 자란다. 사람 턴은 그 안에서
    // 극소수이므로 통째로 문자열로 올리지 않고 줄 단위로 흘린다.
    private static let maxFileBytes = 24 * 1024 * 1024

    // MARK: - 캐시
    //
    // LoopScan 과 같은 규율이다. 경로+수정시각+크기가 그대로면 다시 읽지 않는다. 이슈 목록은
    // 새로고침마다 카드 109 장을 도는데 그때마다 트랜스크립트를 다시 파싱하면 페이지가 선다.

    private struct Entry { var stamp: String; var text: String }
    private static let lock = NSLock()
    private static var cache: [String: Entry] = [:]

    // MARK: - 바깥에서 부르는 자리

    // 카드 하나의 나중 발화를 한 덩어리 문자열로. 없으면 빈 문자열이다.
    // `target` 은 카드 프론트매터의 `target`(목적지 폴더 절대경로)이다.
    static func text(cardID: String, target: String) -> String {
        let id = cardID.trimmingCharacters(in: .whitespaces)
        let folder = target.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !folder.isEmpty else { return "" }
        guard let dir = sessionDir(forTarget: folder) else { return "" }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []

        var out: [String] = []
        for f in files where f.pathExtension == "jsonl" {
            let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = vals?.fileSize ?? 0
            if size > maxFileBytes { continue }
            let stamp = "\(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(size)|\(id)"
            let ck = f.path + "|" + id

            lock.lock(); let hit = cache[ck]; lock.unlock()
            if let h = hit, h.stamp == stamp {
                if !h.text.isEmpty { out.append(h.text) }
                continue
            }
            let t = scan(file: f, cardID: id)
            lock.lock(); cache[ck] = Entry(stamp: stamp, text: t); lock.unlock()
            if !t.isEmpty { out.append(t) }
        }
        return String(out.joined(separator: "\n").prefix(totalLimit))
    }

    // MARK: - 폴더 → 세션 폴더

    // `~/.claude/projects` 아래의 폴더 이름은 작업 폴더 절대경로에서 `/` 와 `_` 와 `.` 를
    // `-` 로 바꾼 것이다. 실측: `/Users/lioncho/Work/lion_work/organization/lion/lion-contents`
    // → `-Users-lioncho-Work-lion-work-organization-lion-lion-contents`.
    //
    // 그 규칙으로 만든 이름을 먼저 찾고, 없으면 실제 폴더 목록에서 대소문자를 무시하고 맞춘다.
    // 규칙을 직접 재현하지 않고 목록과 대조하는 갈래를 남긴 이유는, 이 인코딩이 우리 것이 아니라
    // Claude Code 의 것이라 조용히 바뀔 수 있기 때문이다. 바뀌면 첫 갈래만 빗나가고 둘째가 받는다.
    private static func sessionDir(forTarget folder: String) -> URL? {
        let want = slug(folder)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let direct = base.appendingPathComponent(want, isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        for d in AgentInventory.sessionDirs()
        where d.lastPathComponent.lowercased() == want.lowercased() { return d }
        return nil
    }

    private static func slug(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return String(s.map { ($0 == "/" || $0 == "_" || $0 == ".") ? "-" : $0 })
    }

    // MARK: - 트랜스크립트 한 개

    // 첫 사람 턴에 카드 id 가 있으면 그 세션은 이 카드의 것이다. 그 뒤의 **사람 턴만** 모은다.
    // 첫 턴 자체는 버린다 — 그것은 디렉터가 조립한 지시문이지 라이언이 말한 것이 아니고,
    // 그 안의 `## 라이언 원문` 은 이미 카드에 그대로 들어 있다.
    private static func scan(file: URL, cardID: String) -> String {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        var first = true
        var matched = false
        var out: [String] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            // 줄마다 JSON 을 파싱하면 15MB 짜리에서 페이지가 선다. 표식이 없으면 파싱조차 안 한다.
            guard line.contains("\"type\":\"user\"") else { continue }
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["type"] as? String) == "user" else { continue }
            // 서브에이전트 쪽 줄은 라이언이 말한 것이 아니다.
            if (o["isSidechain"] as? Bool) == true { continue }
            let t = humanText(o)
            if t.isEmpty { continue }

            if first {
                first = false
                // 첫 사람 턴이 이 카드의 지시문인가. 아니면 이 파일은 다른 일의 세션이다.
                if !t.contains(cardID) { return "" }
                matched = true
                continue
            }
            guard matched else { continue }
            out.append(t)
            if out.joined(separator: "\n").count >= totalLimit { break }
        }
        guard matched, !out.isEmpty else { return "" }
        return String(out.joined(separator: "\n").prefix(totalLimit))
    }

    // 사람이 실제로 친/말한 것만 남긴다. 이 자리에서 걸러 내는 것들은 전부 `type:"user"` 로
    // 들어오지만 라이언의 말이 아니다 — 도구 결과, 서브에이전트 완료 알림, 시스템 안내,
    // 붙여 넣은 이미지 자리표시자, 그리고 사용자가 끊었다는 표시다. 이것들을 안 걸러 내면
    // 검색 코퍼스가 요구가 아니라 기계 로그로 채워진다.
    private static func humanText(_ o: [String: Any]) -> String {
        let m = (o["message"] as? [String: Any]) ?? [:]
        var t = ""
        if let s = m["content"] as? String {
            t = s
        } else if let arr = m["content"] as? [Any] {
            var parts: [String] = []
            for b in arr {
                guard let bb = b as? [String: Any], (bb["type"] as? String) == "text",
                      let s = bb["text"] as? String else { continue }
                parts.append(s)
            }
            t = parts.joined(separator: "\n")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        for bad in ["<task-notification", "<system-reminder", "<local-command",
                    "[Request interrupted", "[Image:", "<command-name>", "Caveat:"]
        where t.hasPrefix(bad) { return "" }
        return t
    }
}
