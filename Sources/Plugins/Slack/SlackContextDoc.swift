import Foundation

// 컨텍스트 공유하기 — 번역함 카드 한 장이 아니라, 그 메시지가 놓인 "원 대화 전체"를
// 슬랙에서 다시 긁어 마크다운 문서 하나로 만든다.
//
// 왜: 카드에는 대상 메시지 본문만 있어서, 그 앞에서 오간 결정("문제부터 정의하라"
// 같은)이 세션에 전달되지 않았다. 그래서 세션이 대화를 이어받아도 앞 맥락을 모른 채
// 답을 지어냈다 (user request 2026-08-22). 이제 세션은 이 문서를 Read 해서 대화
// 전체를 본다.
//
// 수집 범위 (2026-08-22 사용자 선택): 대상이 속한 스레드는 답글 전부, 채널/DM
// 타임라인은 대상 앞 40개 + 대상 이후 최근 10개. API 호출은 conversations.history
// 2번 + conversations.replies 1번 + 처음 보는 사람 수만큼 users.info — 이름은
// users.json 에 캐시되므로 두 번째 추출부터는 사실상 3번이다.
//
// 호출은 동기다(대시보드 POST 핸들러 위에서 돈다). 그래서 사람 이름 조회에 상한을
// 두어 최악의 경우에도 대시보드가 오래 멈추지 않게 한다 — 못 찾은 사람은 원래 id로
// 남고, 캐시가 채워지는 다음 추출에서 이름이 붙는다.
//
// 이 타깃은 앱 타입을 모른다 (Package.swift 참고) — 문서를 어디에 저장할지는
// 호출자(앱)가 정하고, 여기서는 마크다운 문자열까지만 만든다.
public struct SlackContextDoc {
    public let ok: Bool
    public let markdown: String
    public let messages: Int      // 문서에 담긴 메시지 수
    public let threadReplies: Int // 그중 스레드 답글 수
    public let error: String
}

extension SlackTranslateStore {

    // 채널 타임라인에서 대상 앞뒤로 긁어올 개수. 스레드는 개수 제한 없이 전부.
    static let contextBefore = 40
    static let contextAfter = 10
    // 한 메시지 본문 상한 / 문서 전체 상한 — 세션 첫 턴이 통째로 읽으므로 폭주를 막는다.
    private static let msgCap = 2000
    private static let docCap = 200_000

    // 사람 이름 캐시 {"U123": "홍길동"} — users.info 왕복을 한 번만 하게 한다.
    static var usersFile: URL { dir.appendingPathComponent("users.json") }

    // 번역함 항목 원본 JSON (lookup 은 좌표만 준다 — 문서 머리말에 채널명·링크·
    // 번역·의미 분석이 필요해 객체 전체를 읽는다).
    static func rawItem(id: String) -> [String: Any]? {
        guard let lines = try? String(contentsOf: itemsFile, encoding: .utf8) else { return nil }
        for line in lines.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["id"] as? String == id else { continue }
            return obj
        }
        return nil
    }

    // 한 메시지가 문서에 실릴 때의 모습. ts 는 정렬 키이자 중복 제거 키다.
    private struct Row {
        let ts: String
        let user: String
        let text: String
        let replyCount: Int
        let files: Int
        let isThreadReply: Bool
    }

    private static func row(_ m: [String: Any], threadReply: Bool) -> Row? {
        guard let ts = m["ts"] as? String else { return nil }
        let text = (m["text"] as? String) ?? ""
        let files = (m["files"] as? [[String: Any]])?.count ?? 0
        // 본문도 첨부도 없는 줄(채널 입장 이벤트 등)은 문서에서 뺀다.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, files == 0 { return nil }
        let user = (m["user"] as? String) ?? (m["username"] as? String) ?? (m["bot_id"] as? String) ?? ""
        return Row(ts: ts, user: user, text: text,
                   replyCount: (m["reply_count"] as? Int) ?? 0, files: files,
                   isThreadReply: threadReply)
    }

    // 슬랙 ts("1755852120.000200") → 표시용 현지 시각 "08-22 09:42".
    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    private static func stamp(_ ts: String) -> String {
        guard let sec = Double(ts.split(separator: ".").first.map(String.init) ?? ts) else { return ts }
        return stampFmt.string(from: Date(timeIntervalSince1970: sec))
    }

    // 슬랙 마크업 → 사람이 읽는 글 (데몬의 cleanText 와 같은 규칙).
    static func cleanSlackText(_ raw: String, names: [String: String]) -> String {
        var t = raw
        for id in mentionIds(raw) {
            t = t.replacingOccurrences(of: "<@\(id)>", with: "@" + (names[id] ?? id))
        }
        t = sub(t, "<!subteam\\^[A-Z0-9]+\\|@?([^>]+)>", "@$1")
        t = sub(t, "<!(here|channel|everyone)>", "@$1")
        t = sub(t, "<#[A-Z0-9]+\\|([^>]+)>", "#$1")
        t = sub(t, "<(https?://[^|>]+)\\|([^>]+)>", "$2 ($1)")
        t = sub(t, "<(https?://[^|>]+)>", "$1")
        t = t.replacingOccurrences(of: "&lt;", with: "<")
        t = t.replacingOccurrences(of: "&gt;", with: ">")
        t = t.replacingOccurrences(of: "&amp;", with: "&")
        return t
    }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    // 본문에 박힌 <@U123> 멘션의 사용자 id — 이름 조회 대상에 함께 넣는다.
    private static func mentionIds(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<@([A-Z0-9]+)>") else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    // 처음 보는 사람만 users.info 로 조회하고 users.json 에 적어 둔다. 한 번 추출에
    // 조회 상한 30명 — 캐시가 비어 있어도 왕복이 무한정 늘어나지 않게 한다.
    private static func resolveNames(_ ids: Set<String>, token: String) -> [String: String] {
        var cache: [String: String] = [:]
        if let data = try? Data(contentsOf: usersFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            cache = obj
        }
        var fetched = 0
        for id in ids.sorted() where cache[id] == nil {
            guard id.hasPrefix("U") || id.hasPrefix("W") else { continue }  // 봇/username 은 그대로 쓴다
            if fetched >= 30 { break }
            fetched += 1
            guard let res = slackRaw("users.info", ["user": id], token: token),
                  let user = res["user"] as? [String: Any] else { continue }
            let profile = user["profile"] as? [String: Any]
            let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (user["real_name"] as? String)
                ?? (user["name"] as? String)
                ?? id
            cache[id] = name
        }
        if fetched > 0, let data = try? JSONSerialization.data(withJSONObject: cache) {
            try? data.write(to: usersFile, options: .atomic)
        }
        return cache
    }

    // 원 대화를 긁어 마크다운 문서를 만든다. 실패해도 세션 시작 자체는 막지 않는다 —
    // 호출자가 ok=false 를 보고 "메시지 컨텍스트만" 으로 진행한다.
    public static func contextDoc(id: String) -> SlackContextDoc {
        let t0 = DispatchTime.now()
        func fail(_ e: String) -> SlackContextDoc {
            SlackActionLog.log("context.doc", id: id, ok: false, ms: ms(since: t0), error: e)
            return SlackContextDoc(ok: false, markdown: "", messages: 0, threadReplies: 0, error: e)
        }
        guard let item = rawItem(id: id) else { return fail("item not found") }
        guard let token = userToken() else { return fail("keychain token missing") }
        let channel = (item["channel"] as? String) ?? ""
        let ts = (item["ts"] as? String) ?? ""
        guard !channel.isEmpty, !ts.isEmpty else { return fail("item incomplete") }
        let threadTs = (item["threadTs"] as? String) ?? ts

        // 채널/DM 타임라인 — 대상 포함 앞 40개(latest 기준 과거 방향) + 그 이후 10개.
        // conversations.history 는 창(oldest~latest) 안에서 "최신부터" 돌려준다. 그래서
        // 뒤쪽 10개는 대상 바로 다음 10개가 아니라 대상 이후의 "가장 최근" 10개다 —
        // 지금 대화가 어디까지 왔는지 보여주므로 그대로 쓰되, 사이가 비면(has_more)
        // 문서에 끊김 표시를 넣는다 (붙어 있는 것처럼 읽히면 안 된다).
        var rows: [String: Row] = [:]
        var apiError = ""
        func take(_ res: [String: Any]?) {
            guard let res else { apiError = apiError.isEmpty ? "network" : apiError; return }
            if res["ok"] as? Bool != true {
                let e = (res["error"] as? String) ?? "unknown"
                if apiError.isEmpty { apiError = e }
                return
            }
            for m in (res["messages"] as? [[String: Any]]) ?? [] {
                if let r = row(m, threadReply: false) { rows[r.ts] = r }
            }
        }
        let before = slackRaw("conversations.history",
                              ["channel": channel, "latest": ts, "inclusive": "true",
                               "limit": String(contextBefore + 1)], token: token)
        let after = slackRaw("conversations.history",
                             ["channel": channel, "oldest": ts, "inclusive": "false",
                              "limit": String(contextAfter)], token: token)
        take(before)
        take(after)
        let afterGap = (after?["has_more"] as? Bool) == true
        // 스레드 답글 — 대상이 스레드 안이면 채널 history 에는 아예 안 나온다
        // (broadcast 답글 제외). ts 파라미터는 스레드의 아무 메시지나 받는다.
        var threadCount = 0
        let thread = slackRaw("conversations.replies",
                              ["channel": channel, "ts": threadTs, "limit": "200"], token: token)
        let threadMsgs = (thread?["messages"] as? [[String: Any]]) ?? []
        for m in threadMsgs {
            guard let r = row(m, threadReply: (m["ts"] as? String) != threadTs) else { continue }
            if rows[r.ts] == nil, r.isThreadReply { threadCount += 1 }
            rows[r.ts] = r
        }
        // 어느 호출에서도 대상 메시지를 못 찾으면(삭제·권한) 저장해 둔 원문으로 대신한다.
        if rows[ts] == nil {
            let saved = (item["textEn"] as? String) ?? (item["textKo"] as? String) ?? ""
            rows[ts] = Row(ts: ts, user: (item["authorId"] as? String) ?? "", text: saved,
                           replyCount: 0, files: 0, isThreadReply: threadTs != ts)
        }
        // 대상 한 줄(폴백)만 남았고 슬랙이 이유를 줬다면 그 이유로 실패한다 — 권한이
        // 없어서(missing_scope·not_in_channel) 빈 문서가 나가는 걸 막는다.
        guard rows.count > 1 || apiError.isEmpty else { return fail(apiError) }

        let ordered = rows.values.sorted { (Double($0.ts) ?? 0) < (Double($1.ts) ?? 0) }
        var ids = Set(ordered.map(\.user).filter { !$0.isEmpty })
        for r in ordered { ids.formUnion(mentionIds(r.text)) }
        if let author = item["authorId"] as? String, !author.isEmpty { ids.insert(author) }
        let names = resolveNames(ids, token: token)

        let md = render(item: item, id: id, target: ts, rows: ordered, names: names,
                        threadCount: threadCount, afterGap: afterGap)
        SlackActionLog.log("context.doc", id: id, ok: true, ms: ms(since: t0),
                           detail: "\(ordered.count)msg/\(threadCount)thread")
        return SlackContextDoc(ok: true, markdown: md, messages: ordered.count,
                               threadReplies: threadCount, error: "")
    }

    // ----- 문서 조립 -----
    // 세션이 처음부터 끝까지 한 번에 읽는 문서다: 머리말(어디의 무슨 대화인지) →
    // 대화 전문(오래된 것부터, 대상 메시지에 표식) → 번역함이 이미 뽑아 둔 분석.
    private static func render(item: [String: Any], id: String, target: String,
                               rows: [Row], names: [String: String], threadCount: Int,
                               afterGap: Bool) -> String {
        func name(_ uid: String) -> String {
            uid.isEmpty ? "(알 수 없음)" : (names[uid] ?? uid)
        }
        let channelName = (item["channelName"] as? String) ?? (item["channel"] as? String) ?? ""
        var head: [String] = []
        head.append("# 슬랙 원 대화 — \(channelName)")
        head.append("")
        head.append("- 대상 메시지: \((item["author"] as? String) ?? name((item["authorId"] as? String) ?? "")) · \(stamp(target))")
        if let link = item["permalink"] as? String, !link.isEmpty {
            head.append("- 슬랙 링크: \(link)")
        }
        head.append("- 수집 범위: 스레드 답글 \(threadCount)개 + 채널 타임라인 앞 \(contextBefore)개 · 이후 최근 \(contextAfter)개")
        head.append("- 수집 시각: \(stamp(String(Date().timeIntervalSince1970)))")
        head.append("- 번역함 항목 id: \(id)")
        head.append("")
        head.append("## 대화 전문 (오래된 것 → 최신)")
        head.append("")

        var body: [String] = []
        var gapDone = !afterGap
        for r in rows {
            // 대상 이후 구간이 잘렸다면, 채널 타임라인이 다시 시작하는 자리에 끊김을 남긴다.
            if !gapDone, !r.isThreadReply, (Double(r.ts) ?? 0) > (Double(target) ?? 0) {
                body.append("_(이 사이에 가져오지 못한 메시지가 더 있습니다 — 아래는 이후의 가장 최근 대화입니다)_")
                body.append("")
                gapDone = true
            }
            var tags: [String] = []
            if r.isThreadReply { tags.append("스레드 답글") }
            if r.ts == target { tags.append("⟵ 번역함이 잡은 대상 메시지") }
            if r.replyCount > 0 { tags.append("스레드 답글 \(r.replyCount)개") }
            if r.files > 0 { tags.append("첨부 \(r.files)개") }
            let tag = tags.isEmpty ? "" : "  _(\(tags.joined(separator: " · ")))_"
            body.append("**[\(stamp(r.ts))] \(name(r.user))**\(tag)")
            var text = cleanSlackText(r.text, names: names)
            if text.count > msgCap { text = String(text.prefix(msgCap)) + "…(생략)" }
            body.append(text.isEmpty ? "_(본문 없음)_" : text)
            body.append("")
        }

        var tail: [String] = []
        tail.append("## 번역함이 저장해 둔 대상 메시지 분석")
        tail.append("")
        if let ko = item["textKo"] as? String, !ko.isEmpty {
            tail.append("### 번역")
            tail.append(ko)
            tail.append("")
        }
        if let meaning = item["meaning"] as? String, !meaning.isEmpty {
            tail.append("### 의미 분석")
            tail.append(meaning)
            tail.append("")
        }
        if let decision = item["decision"] as? String, !decision.isEmpty {
            tail.append("### 의사결정 선택지")
            tail.append(decision)
            tail.append("")
        }

        // 문서 상한: 머리말(어디의 무슨 대화인지)과 꼬리(분석)는 지키고 대화 앞부분만
        // 잘라 낸다. 머리말째 날리면 세션이 무슨 채널의 대화인지도 모르게 된다.
        let fixed = (head + tail).reduce(0) { $0 + $1.count + 1 }
        var bodyLen = body.reduce(0) { $0 + $1.count + 1 }
        var trimmed = false
        while fixed + bodyLen > docCap, body.count > 3 {
            bodyLen -= body.removeFirst().count + 1
            trimmed = true
        }
        if trimmed {
            body.insert(contentsOf: ["_(대화 앞부분이 길어 잘렸습니다 — 이후 대화만 남깁니다)_", ""], at: 0)
        }
        return (head + body + tail).joined(separator: "\n")
    }
}
