import AppKit
import Foundation

// Slack 👀 번역 plugin engine — data stores + Slack Web API calls for the
// /slack-translate feature. Deliberately app-agnostic (GUI/Draw 전례): no
// ConditionManager types. The app injects its data dir and settings hooks at
// startup (SlackTranslateStore.dir / .debugButtons, SlackTranslateContent
// .headExtraHTML); the defaults mirror the daemon's own CM_DATA_DIR fallback so
// this target can also be developed and exercised standalone.
//
// The other half of the plugin is an EXTERNAL long-running daemon
// (Daemon/slack-eyes-daemon.mjs, launchd KeepAlive) holding the Slack Socket
// Mode WebSocket. It owns items.jsonl (append-only); everything here is the
// app-owned side.
//
// Ownership split (no cross-process file contention):
//   <data>/slack-translate/items.jsonl — daemon-owned, APPEND-ONLY. One JSON
//     object per line: {id, channel, channelName, ts, author, textEn, textKo,
//     decision, permalink, reactedAt, translatedAt}. decision = 의사결정 선택지
//     (1: 추천+이유 / 2: 대안) generated in the same LLM call as the translation.
//     later:true = 📌 Later 버킷 항목 — 🔖/📌 리액션 트리거(주 경로) 또는
//     레거시 star 저장(source:'later'). 데몬이 관리, 페이지가 📌 Later 섹션으로
//     그룹핑한다. (Slack 네이티브 Later 버튼은 API 관측 불가라 리액션이 트리거.)
//     triggeredAt = 트리거가 마지막으로 발생한 시각 — 이미 수집된 메시지에
//     리액션을 다시 달면(재트리거) 데몬이 이 값을 갱신하고 처리완료를 해제한다.
//     페이지 정렬 기준(없으면 reactedAt)이라 재트리거된 항목이 맨 위로 온다.
//   <data>/slack-translate/done.json — app-owned. {"<id>": true} map written
//     atomically by POST /api/slack/done; the GET feed merges it client-side.
//     The daemon also POSTs here (sync:false) when the user removes the trigger
//     emoji directly in Slack — 자동 처리완료, no reaction mirror-back.
//   <data>/slack-translate/actions.jsonl — app-owned, APPEND-ONLY 액션 로그.
//     이 기능의 모든 액션(완료 토글, 리액션 동기화, 답장 전송/수정/삭제, 개별
//     Slack API 호출)을 소요시간(ms)·성공여부·에러와 함께 기록한다. 디버그
//     모드의 액션 로그 패널이 GET /api/slack/actions 로 읽는다 (SlackActionLog).
//   <data>/slack-translate/sync-status.json — app-owned. 리액션 동기화가 실패한
//     항목만 남는 맵 {"<id>": {error, action, at}} — 성공하면 항목이 지워진다.
//     처리완료를 눌렀는데 슬랙 👀가 안 지워지는 문제(예: 토큰에 reactions:write
//     스코프 없음)를 조용히 삼키지 않고 피드에 실어 UI에 경고로 띄우기 위함.
//
// Feed: GET /api/slack/items → {"items":[…], "done":{…}, "syncErr":{…}} (items
// are the raw JSONL lines joined — already JSON objects, ActionLog pattern).
public enum SlackTranslateStore {

    // ----- app wiring (injected at startup) -----

    // <data>/slack-translate. Default matches the daemon's CM_DATA_DIR fallback.
    public static var dir: URL = {
        let base = ProcessInfo.processInfo.environment["CM_DATA_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".condition-manager")
        return base.appendingPathComponent("slack-translate")
    }()
    // 디버그 버튼 노출 여부 (호스트 앱 전역 설정) — feed에 실려 페이지가 반영한다.
    public static var debugButtons: () -> Bool = { false }

    static var itemsFile: URL { dir.appendingPathComponent("items.jsonl") }
    static var doneFile: URL { dir.appendingPathComponent("done.json") }
    // App-owned ledger of replies I sent from the dashboard, keyed by item id:
    // {"<itemId>": [{"ts":"…","text":"…","at":<epoch>,"editedAt":<epoch>?}, …]}.
    // ts is the Slack ts of MY reply message — the handle chat.update edits by.
    static var repliesFile: URL { dir.appendingPathComponent("replies.json") }
    static var configFile: URL { dir.appendingPathComponent("config.json") }
    // GUI세션 연결 대장 — 이 메시지로 연 AI 세션(목표)이 무엇이었는지 남긴다.
    // {"<itemId>": {"seq": <목표번호>, "at": <epoch>}}
    // 이게 있어야 버튼이 "세션열기"에서 "세션 이어가기"로 바뀌고, 그때 쓴
    // 프롬프트/컨텍스트가 실린 원래 세션으로 되돌아갈 수 있다.
    static var guiFile: URL { dir.appendingPathComponent("gui-sessions.json") }
    // 리액션 동기화 실패 맵 — 실패만 남고 성공하면 지워진다 (헤더 주석 참고).
    static var syncStatusFile: URL { dir.appendingPathComponent("sync-status.json") }

    // 액션 소요시간(ms) — 벽시계가 아니라 단조 시계 기준.
    public static func ms(since t0: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
    }

    // Translation model choice — written here, read by the daemon PER translate
    // call (no restart needed). Valid: auto | gemini-flash-lite | gemini-flash | haiku.
    public static func setModel(_ model: String) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = obj
        }
        cfg["model"] = model
        if let data = try? JSONSerialization.data(withJSONObject: cfg) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    // 번역 목표 언어 — config.json {"lang": "ko"|"en"|"vi"|"ja"|"zh"}, 데몬이
    // 번역 호출마다 읽는다 (모델 선택과 동일 패턴, 재시작 불필요). 이미 그
    // 언어인 메시지는 데몬이 번역하지 않고 원문 그대로 저장한다.
    public static func setLang(_ lang: String) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = obj
        }
        cfg["lang"] = lang
        if let data = try? JSONSerialization.data(withJSONObject: cfg) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    // 수집 기준 체크박스 — config.json {"sources":{"eyes":…,"mention":…,"team":…,
    // "dm":…,"broadcast":…,"later":…}}. 데몬이 이벤트마다 읽으므로 재시작 없이 즉시
    // 적용. 부분 업데이트(한 키만)도 기존 값과 병합한다. 해제 = 앞으로 수집 안 함
    // (기존 항목은 유지).
    public static func setSources(_ sources: [String: Bool]) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = obj
        }
        var cur = (cfg["sources"] as? [String: Bool]) ?? [:]
        let allowed = ["eyes", "mention", "team", "dm", "broadcast", "later"]
        for (k, v) in sources where allowed.contains(k) { cur[k] = v }
        cfg["sources"] = cur
        // 구버전 mentions 플래그는 sources.mention으로 대체됐다 — 남아 있으면
        // 데몬이 off로 해석할 수 있으니 제거한다.
        cfg.removeValue(forKey: "mentions")
        if let data = try? JSONSerialization.data(withJSONObject: cfg) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    // Model-key presence (keychain) for the model picker's warning hints.
    // security-spawn is ~10ms; cached 60s since the feed polls at 5s.
    private static var keyCache: [String: (has: Bool, at: Date)] = [:]
    static func hasKey(_ service: String) -> Bool {
        if let c = keyCache[service], Date().timeIntervalSince(c.at) < 60 { return c.has }
        let sec = Process()
        sec.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        sec.arguments = ["find-generic-password", "-s", service]
        sec.standardOutput = FileHandle.nullDevice
        sec.standardError = FileHandle.nullDevice
        var has = false
        if (try? sec.run()) != nil {
            sec.waitUntilExit()
            has = sec.terminationStatus == 0
        }
        keyCache[service] = (has, Date())
        return has
    }

    // Raw JSONL lines are already JSON objects — join them, no re-encode.
    public static func itemsJSON() -> String {
        var items = "[]"
        if let text = try? String(contentsOf: itemsFile, encoding: .utf8) {
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") }
            items = "[\(lines.joined(separator: ","))]"
        }
        let done = (try? String(contentsOf: doneFile, encoding: .utf8)) ?? "{}"
        let replies = (try? String(contentsOf: repliesFile, encoding: .utf8)) ?? "{}"
        let syncErr = (try? String(contentsOf: syncStatusFile, encoding: .utf8)) ?? "{}"
        let gui = (try? String(contentsOf: guiFile, encoding: .utf8)) ?? "{}"
        // 해결된 실패는 저절로 사라지도록 — 60초에 한 번 백그라운드 재검증.
        revalidateSyncErrors()
        var model = "gemini-flash-lite" // default = 1초 번역 (user request 2026-07-23)
        var lang = "ko" // 번역 목표 언어 (기본 한국어)
        var sources = "{}" // 기본 전부 on — 페이지가 (!== false)로 해석
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["model"] as? String { model = m }
            if let l = obj["lang"] as? String { lang = l }
            if let s = obj["sources"],
               let d = try? JSONSerialization.data(withJSONObject: s) {
                sources = String(decoding: d, as: UTF8.self)
            }
        }
        // 한 식으로 이어붙이면 타입체커가 터진다 — 조각으로 분해해 합친다.
        var out = "{\"items\":\(items)"
        out += ",\"done\":\(done.hasPrefix("{") ? done : "{}")"
        out += ",\"replies\":\(replies.hasPrefix("{") ? replies : "{}")"
        out += ",\"syncErr\":\(syncErr.hasPrefix("{") ? syncErr : "{}")"
        out += ",\"gui\":\(gui.hasPrefix("{") ? gui : "{}")"
        out += ",\"model\":\"\(model)\""
        out += ",\"lang\":\"\(lang)\""
        out += ",\"sources\":\(sources)"
        out += ",\"geminiKey\":\(hasKey("cm-gemini-api-key"))"
        out += ",\"anthropicKey\":\(hasKey("cm-anthropic-api-key"))"
        // 데몬 건강 상태 — 페이지가 5초마다 이 피드를 폴링하므로 별도 엔드포인트
        // 없이 같이 실어 보낸다 (SlackHealth.statusJSON은 프로세스를 띄우지 않는다).
        out += ",\"health\":\(SlackHealth.statusJSON())"
        out += ",\"debugButtons\":\(debugButtons())}"
        return out
    }

    // Look up an item's channel / own ts / thread root / trigger emoji / source by id.
    // source == "mention"/"team"/"dm"/"broadcast" → 알림 자동 수집 항목
    // (트리거 이모지가 없으므로 처리완료해도 슬랙에 리액션을 되돌려 쓰지 않는다).
    private static func lookup(id: String) -> (channel: String, ts: String, threadTs: String, emoji: String, source: String, authorId: String)? {
        guard let lines = try? String(contentsOf: itemsFile, encoding: .utf8) else { return nil }
        for line in lines.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["id"] as? String == id,
                  let channel = obj["channel"] as? String,
                  let ts = obj["ts"] as? String else { continue }
            return (channel, ts, (obj["threadTs"] as? String) ?? ts,
                    (obj["emoji"] as? String) ?? "",
                    (obj["source"] as? String) ?? "",
                    (obj["authorId"] as? String) ?? "")
        }
        return nil
    }

    // User token (xoxp) via /usr/bin/security — same read path the daemon uses, so
    // the keychain item's ACL already allows it (no extra prompt).
    private static func userToken() -> String? {
        let sec = Process()
        sec.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        sec.arguments = ["find-generic-password", "-w", "-s", "cm-slack-user-token"]
        let pipe = Pipe()
        sec.standardOutput = pipe
        sec.standardError = FileHandle.nullDevice
        guard (try? sec.run()) != nil else { return nil }
        sec.waitUntilExit()
        let token = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (sec.terminationStatus == 0 && token.hasPrefix("xox")) ? token : nil
    }

    // Synchronous Slack Web API call (semaphore — handlePost is synchronous and
    // Slack answers in <1s). Returns the parsed response, nil on network failure.
    // Every call lands in the 액션 로그: api.<method>, 소요 ms, ok/error.
    private static func slackRaw(_ method: String, _ args: [String: String], token: String) -> [String: Any]? {
        let t0 = DispatchTime.now()
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: args)
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        let ok = (result?["ok"] as? Bool) == true
        let err = ok ? "" : (result == nil ? "network" : (result?["error"] as? String ?? "unknown"))
        // 메시지 본문은 로그에 남기지 않는다 — 채널/ts 좌표만.
        let target = [args["channel"], args["timestamp"] ?? args["ts"] ?? args["thread_ts"]]
            .compactMap { $0 }.joined(separator: ":")
        SlackActionLog.log("api.\(method)", ok: ok, ms: ms(since: t0), error: err, detail: target)
        return result
    }

    // Same call, folded to the {"ok":…} JSON the dashboard client consumes.
    private static func slackCall(_ method: String, _ args: [String: String], token: String) -> String {
        guard let obj = slackRaw(method, args, token: token) else {
            return "{\"ok\":false,\"error\":\"network\"}"
        }
        if obj["ok"] as? Bool == true { return "{\"ok\":true}" }
        let err = (obj["error"] as? String ?? "unknown").replacingOccurrences(of: "\"", with: "")
        return "{\"ok\":false,\"error\":\"\(err)\"}"
    }

    // 상위 액션(답장 전송/수정/삭제)의 최종 결과를 액션 로그에 남긴다 — 내부의
    // 개별 api.* 호출 로그와 별개로, 사용자가 누른 액션 1건 = 1줄 + 총 소요시간.
    private static func logOutcome(_ action: String, id: String, result: String,
                                   t0: DispatchTime, detail: String = "") {
        let ok = result.hasPrefix("{\"ok\":true")
        var err = ""
        if !ok, let data = result.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            err = obj["error"] as? String ?? "unknown"
        }
        SlackActionLog.log(action, id: id, ok: ok, ms: ms(since: t0), error: err, detail: detail)
    }

    // ----- my-replies ledger (app-owned replies.json) -----

    // POST /api/slack/gui/link {id, seq} — 이 메시지의 GUI세션이 어느 목표로 열렸는지
    // 기록한다. goal-add 가 GUI시작으로 목표를 만든 직후(seq 확정) 한 번 호출한다.
    // 이미 연결이 있으면 최신 것으로 덮어쓴다 (마지막으로 연 세션이 이어갈 대상).
    public static func linkGui(id: String, seq: Int) -> String {
        guard !id.isEmpty, seq > 0 else { return "{\"ok\":false,\"error\":\"bad request\"}" }
        var map = loadGui()
        map[id] = ["seq": seq, "at": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: map) {
            try? data.write(to: guiFile, options: .atomic)
        }
        SlackActionLog.log("gui.link", id: id, ok: true, ms: 0, detail: "goal-\(seq) 세션 연결")
        return "{\"ok\":true,\"seq\":\(seq)}"
    }

    private static func loadGui() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: guiFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return obj
    }

    private static func loadReplies() -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: repliesFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
        else { return [:] }
        return obj
    }

    private static func saveReplies(_ map: [String: [[String: Any]]]) {
        if let data = try? JSONSerialization.data(withJSONObject: map) {
            try? data.write(to: repliesFile, options: .atomic)
        }
    }

    // POST /api/slack/reply {id, text, mention} — thread-reply to the reacted message
    // AS THE USER (needs the chat:write user scope). Text is sent verbatim (no
    // translation — user's choice 2026-07-21). mention=true prepends <@authorId> so
    // the original author gets a notification (thread-following alone은 보장이 안 됨
    // — user request 2026-07-24). The sent message's ts is recorded in replies.json
    // so the dashboard can show "내 답장" and edit it later via chat.update.
    public static func reply(id: String, text: String, mention: Bool = false) -> String {
        let t0 = DispatchTime.now()
        let result = replyInner(id: id, text: text, mention: mention)
        logOutcome("reply", id: id, result: result, t0: t0,
                   detail: "\(text.count)자\(mention ? " +멘션" : "")")
        return result
    }

    private static func replyInner(id: String, text: String, mention: Bool) -> String {
        guard let item = lookup(id: id) else { return "{\"ok\":false,\"error\":\"item not found\"}" }
        guard let token = userToken() else { return "{\"ok\":false,\"error\":\"keychain token missing\"}" }
        var outText = text
        if mention, !text.contains("<@") {
            // authorId 없는 구버전 항목은 전송 시점에 원 메시지에서 user id를 조회.
            var uid = item.authorId
            if uid.isEmpty,
               let res = slackRaw("conversations.replies",
                                  ["channel": item.channel, "ts": item.ts, "limit": "50"],
                                  token: token),
               let msgs = res["messages"] as? [[String: Any]],
               let msg = msgs.first(where: { ($0["ts"] as? String) == item.ts }) {
                uid = (msg["user"] as? String) ?? ""
            }
            // 봇 메시지 등 user id가 없으면 멘션 없이 그대로 전송 (전송 실패보다 낫다).
            if !uid.isEmpty { outText = "<@\(uid)> " + text }
        }
        guard let res = slackRaw("chat.postMessage",
                                 ["channel": item.channel, "text": outText, "thread_ts": item.threadTs],
                                 token: token) else { return "{\"ok\":false,\"error\":\"network\"}" }
        guard res["ok"] as? Bool == true else {
            let err = (res["error"] as? String ?? "unknown").replacingOccurrences(of: "\"", with: "")
            return "{\"ok\":false,\"error\":\"\(err)\"}"
        }
        if let ts = res["ts"] as? String {
            var map = loadReplies()
            // Ledger keeps the ACTUAL sent text (mention markup included) — edits
            // via chat.update must start from what Slack has, not the typed draft.
            map[id, default: []].append(["ts": ts, "text": outText,
                                         "at": Int(Date().timeIntervalSince1970)])
            saveReplies(map)
        }
        return "{\"ok\":true}"
    }

    // POST /api/slack/reply/edit {id, ts, text} — edit MY earlier reply in place
    // (chat.update, covered by the same chat:write user scope) and mirror the new
    // text into the ledger with an editedAt stamp.
    public static func editReply(id: String, ts: String, text: String) -> String {
        let t0 = DispatchTime.now()
        let result = editReplyInner(id: id, ts: ts, text: text)
        logOutcome("reply.edit", id: id, result: result, t0: t0, detail: "\(text.count)자")
        return result
    }

    private static func editReplyInner(id: String, ts: String, text: String) -> String {
        guard let item = lookup(id: id) else { return "{\"ok\":false,\"error\":\"item not found\"}" }
        guard let token = userToken() else { return "{\"ok\":false,\"error\":\"keychain token missing\"}" }
        let result = slackCall("chat.update",
                               ["channel": item.channel, "ts": ts, "text": text], token: token)
        if result == "{\"ok\":true}" {
            var map = loadReplies()
            map[id] = (map[id] ?? []).map { r in
                guard r["ts"] as? String == ts else { return r }
                var r2 = r
                r2["text"] = text
                r2["editedAt"] = Int(Date().timeIntervalSince1970)
                return r2
            }
            saveReplies(map)
        }
        return result
    }

    // POST /api/slack/reply/delete {id, ts} — delete MY earlier reply from Slack
    // (chat.delete — you can always delete your own message with the chat:write user
    // scope) and drop it from the ledger. Also the target when an edit clears all
    // text (Slack UX parity: emptying a message deletes it). "message_not_found"
    // means Slack already lost it, so we still prune the ledger rather than dangle.
    public static func deleteReply(id: String, ts: String) -> String {
        let t0 = DispatchTime.now()
        let result = deleteReplyInner(id: id, ts: ts)
        logOutcome("reply.delete", id: id, result: result, t0: t0)
        return result
    }

    private static func deleteReplyInner(id: String, ts: String) -> String {
        guard let item = lookup(id: id) else { return "{\"ok\":false,\"error\":\"item not found\"}" }
        guard let token = userToken() else { return "{\"ok\":false,\"error\":\"keychain token missing\"}" }
        let result = slackCall("chat.delete", ["channel": item.channel, "ts": ts], token: token)
        if result == "{\"ok\":true}" || result.contains("message_not_found") {
            var map = loadReplies()
            map[id] = (map[id] ?? []).filter { ($0["ts"] as? String) != ts }
            if map[id]?.isEmpty == true { map.removeValue(forKey: id) }
            saveReplies(map)
            return "{\"ok\":true}"
        }
        return result
    }

    // 처리완료 ↔ Slack 👀 sync (needs the reactions:write user scope): checking done
    // removes the :eyes: reaction from the original message, unchecking re-adds it.
    // Best-effort — "no_reaction"/"already_reacted" mean the state already matches.
    // The daemon ignores reaction_removed, and re-adding fires reaction_added on an
    // id it has already seen, so neither direction loops back into the pipeline.
    // 결과는 삼키지 않는다: 액션 로그(ms 포함) + 실패 시 sync-status.json에 기록해
    // 피드가 항목에 경고를 띄운다 (2026-07-23: missing_scope 실패가 조용히 묻혀
    // "처리완료 눌렀는데 👀가 안 지워짐"의 원인을 알 수 없었던 문제).
    public static func syncReaction(id: String, done: Bool) {
        let t0 = DispatchTime.now()
        let action = done ? "reaction.remove" : "reaction.add"
        func fail(_ error: String) {
            SlackActionLog.log(action, id: id, ok: false, ms: ms(since: t0), error: error)
            setSyncStatus(id: id, ok: false, error: error, action: action)
        }
        guard let item = lookup(id: id) else { return fail("item not found") }
        // 동기화할 이모지 결정: emoji 필드가 있으면 그것(멘션으로 수집된 뒤 👀를
        // 직접 단 항목 포함), 없고 source도 없으면 emoji 필드가 생기기 전의 옛 👀
        // 항목이므로 eyes.
        let emoji = item.emoji.isEmpty ? (item.source.isEmpty ? "eyes" : "") : item.emoji
        // 이모지 트리거가 없는 멘션류 항목엔 동기화할 것도 없고, add를 돌리면 원
        // 메시지에 👀가 새로 달려 버리므로 통째로 건너뛴다.
        if emoji.isEmpty {
            SlackActionLog.log(action, id: id, ok: true, ms: ms(since: t0),
                               detail: "@멘션 항목 — 리액션 동기화 생략")
            setSyncStatus(id: id, ok: true, error: "", action: action)
            return
        }
        guard let token = userToken() else { return fail("keychain token missing") }
        let res = slackRaw(done ? "reactions.remove" : "reactions.add",
                           ["channel": item.channel, "timestamp": item.ts, "name": emoji],
                           token: token)
        let rawErr = res == nil ? "network"
            : ((res?["ok"] as? Bool) == true ? "" : (res?["error"] as? String ?? "unknown"))
        // 상태가 이미 원하는 쪽이면(no_reaction/already_reacted) 성공으로 취급.
        let ok = rawErr.isEmpty || rawErr == "no_reaction" || rawErr == "already_reacted"
        SlackActionLog.log(action, id: id, ok: ok, ms: ms(since: t0),
                           error: ok ? "" : rawErr,
                           detail: ":\(emoji): \(done ? "제거" : "복원")")
        setSyncStatus(id: id, ok: ok, error: rawErr, action: action)
    }

    // 실패만 남는 맵 — 성공(또는 이후 재시도 성공)하면 해당 항목을 지운다.
    private static func setSyncStatus(id: String, ok: Bool, error: String, action: String) {
        var map: [String: Any] = [:]
        if let data = try? Data(contentsOf: syncStatusFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            map = obj
        }
        if ok {
            if map[id] == nil { return } // 지울 것도 없으면 파일 쓰기 생략
            map.removeValue(forKey: id)
        } else {
            map[id] = ["error": error, "action": action,
                       "at": Int(Date().timeIntervalSince1970)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: map) {
            try? data.write(to: syncStatusFile, options: .atomic)
        }
    }

    // ----- 실패 항목 자가 검증 (no-user-facing-failure) -----
    //
    // 실패 맵은 "다시 시도할 때"만 지워졌다 — 원인이 밖에서 해결돼도(스코프 부여,
    // 네트워크 복구, 항목 삭제) 경고가 영원히 남았다. 피드를 읽을 때마다 최대
    // 60초에 한 번, 백그라운드에서 실패 항목을 조용히 다시 동기화한다. 성공하면
    // setSyncStatus가 항목을 지우고 경고는 저절로 사라진다. 사용자에게는 아무것도
    // 묻지 않는다 — 조용히 재시도하고, 여전히 실패할 때만 경고가 남는다.
    private static let revalLock = NSLock()
    private static var lastReval = Date.distantPast
    private static var revalidating = false

    static func revalidateSyncErrors() {
        revalLock.lock()
        let due = !revalidating && Date().timeIntervalSince(lastReval) >= 60
        if due { revalidating = true; lastReval = Date() }
        revalLock.unlock()
        guard due else { return }

        DispatchQueue.global(qos: .utility).async {
            defer { revalLock.lock(); revalidating = false; revalLock.unlock() }
            guard let data = try? Data(contentsOf: syncStatusFile),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !map.isEmpty else { return }
            var doneMap: [String: Bool] = [:]
            if let d = try? Data(contentsOf: doneFile),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Bool] {
                doneMap = obj
            }
            for id in map.keys {
                // 항목 자체가 사라졌으면 되돌릴 대상이 없다 — 경고만 지운다.
                guard lookup(id: id) != nil else {
                    setSyncStatus(id: id, ok: true, error: "", action: "reval")
                    continue
                }
                syncReaction(id: id, done: doneMap[id] ?? false)
            }
        }
    }

    // POST /api/slack/speak — 스피킹 시작. Builds the briefing prompt from recent
    // Slack threads, copies it to the clipboard (paste fallback), and opens ChatGPT
    // web with ?q= so the context auto-submits; the user then taps the voice icon.
    // Returns the {"ok":…,"mode":…} JSON the page consumes.
    public static func speakBriefing() -> String {
        let t0 = DispatchTime.now()
        let brief = briefing()
        SlackActionLog.log("speak", ok: true, ms: ms(since: t0),
                           detail: "브리핑 \(brief.count)자")
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brief, forType: .string)
            var comps = URLComponents(string: "https://chatgpt.com/")!
            comps.queryItems = [URLQueryItem(name: "q", value: brief)]
            if let url = comps.url, url.absoluteString.count < 7000 {
                NSWorkspace.shared.open(url)
            } else {
                // Prompt too long for a URL — open plain ChatGPT; the briefing
                // is on the clipboard, the page shows a ⌘V hint.
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
            }
        }
        let mode = brief.count < 5500 ? "url" : "clipboard"
        return "{\"ok\":true,\"mode\":\"\(mode)\"}"
    }

    // 스피킹 브리핑 — a self-contained English-coach prompt built from recent Slack
    // threads (un-done items first). Deterministic template, no LLM: ChatGPT itself
    // extracts expressions and runs the roleplay, so the button is instant and the
    // data is always fresh. Kept compact so it fits chatgpt.com/?q= URL injection.
    static func briefing() -> String {
        var items: [[String: Any]] = []
        if let text = try? String(contentsOf: itemsFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    items.append(obj)
                }
            }
        }
        var doneMap: [String: Bool] = [:]
        if let data = try? Data(contentsOf: doneFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            doneMap = obj
        }
        // Most recent trigger first; open (un-done) threads before processed ones.
        func trigAt(_ o: [String: Any]) -> Double {
            (o["triggeredAt"] as? Double) ?? (o["reactedAt"] as? Double) ?? 0
        }
        items.sort { trigAt($0) > trigAt($1) }
        let open = items.filter { !(doneMap[$0["id"] as? String ?? ""] ?? false) }
        let closed = items.filter { doneMap[$0["id"] as? String ?? ""] ?? false }
        var lines: [String] = []
        var budget = 3500 // chars of thread material — keeps the ?q= URL well under limits
        for it in open + closed {
            guard lines.count < 15, budget > 0 else { break }
            let ch = it["channelName"] as? String ?? ""
            let au = it["author"] as? String ?? ""
            var tx = (it["textEn"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            if tx.count > 220 { tx = String(tx.prefix(220)) + "…" }
            let row = "[\(ch)] \(au): \(tx)"
            lines.append(row)
            budget -= row.count
        }
        return """
        You are my English speaking coach and roleplay partner. I am Lion cho (조중현), \
        working at MUST Company. Below are real threads from my work Slack that I need \
        to handle in English.

        RECENT WORK THREADS (most recent first):
        \(lines.joined(separator: "\n"))

        SESSION RULES — this is a VOICE conversation:
        1. English only. Keep every reply short and conversational (2-4 sentences).
        2. Roleplay as my actual colleagues continuing these real threads, or ask me \
        "How would you reply to this message?" using the threads above.
        3. After each of my turns, give ONE quick correction of my most unnatural \
        phrase, then continue the conversation naturally.
        4. Teach me the business expressions these situations actually need.
        Start now: list the 2-3 most interesting threads above in one line each, and \
        ask me which one to practice.
        """
    }

    public static func setDone(id: String, done: Bool) {
        var map: [String: Bool] = [:]
        if let data = try? Data(contentsOf: doneFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            map = obj
        }
        if done { map[id] = true } else { map.removeValue(forKey: id) }
        if let data = try? JSONSerialization.data(withJSONObject: map) {
            try? data.write(to: doneFile, options: .atomic)
        }
    }
}

// slack-translate 전용 액션 로그 — 모든 액션을 소요시간과 함께 남긴다.
// {at, action, id, ok, ms, error, detail} 1건 = 1줄, <data>/slack-translate/
// actions.jsonl (append-only). action 이름: done.set/done.unset(완료 토글),
// reaction.remove/reaction.add(👀 동기화), reply/reply.edit/reply.delete(답장),
// config.model(모델 변경), speak(브리핑), api.<method>(개별 Slack API 호출).
// 파일 접근은 전용 직렬 큐 — append는 server/utility 스레드에서, read는 server
// 스레드에서 온다 (ActionLog 패턴).
public enum SlackActionLog {

    private static let queue = DispatchQueue(label: "cm.slack.actionlog")
    static var file: URL { SlackTranslateStore.dir.appendingPathComponent("actions.jsonl") }

    public static func log(_ action: String, id: String = "", ok: Bool, ms: Int,
                           error: String = "", detail: String = "") {
        let line = "{\"at\":\(Int(Date().timeIntervalSince1970)),\"action\":\(js(action)),"
            + "\"id\":\(js(id)),\"ok\":\(ok),\"ms\":\(ms),\"error\":\(js(error)),"
            + "\"detail\":\(js(detail))}\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: SlackTranslateStore.dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    // GET /api/slack/actions — last `limit` entries, oldest first (클라이언트가
    // 뒤집어 최신부터 표시). Tail-window read so a long-lived log stays fast.
    public static func recentJSON(limit: Int) -> String {
        let capped = max(1, min(limit, 1000))
        return queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                return "{\"actions\":[]}"
            }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            let window: UInt64 = 524_288
            let start = size > window ? size - window : 0
            handle.seek(toFileOffset: start)
            guard var text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
                return "{\"actions\":[]}"
            }
            if start > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") }
            return "{\"actions\":[\(lines.suffix(capped).joined(separator: ","))]}"
        }
    }

    // Minimal JSON string encoder (ActionLog.js와 동일 로직).
    private static func js(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}
