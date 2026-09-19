import Foundation

// 위임 카드의 보관 원장 — 라이언이 끝난 결과물을 하나씩 확인하고 나서 목록에서 치우기 위한 것이다.
//
//   ★ 아카이브는 여섯째 버킷이 아니라 **다른 축**이다. ★
//
// 이것이 이 파일의 설계를 통째로 정한다. `bucket` 은 그대로 카드의 `status:` 에서 나온다
// (WorkQueueStore.bucket(for:)). 보관은 그 위에 따로 서는 깃발이고, 그래서 보관을 풀면
// "무엇으로 돌아갔는지" 를 말할 수 있다 — 완료였으면 완료로, 막힘이었으면 막힘으로.
// 상태값 하나로 만들었으면 보관하는 순간 원래 상태가 지워져서 되돌리기가 불가능해진다.
//
//   ★ 저장 위치는 `AppPaths.sub("work-queue")/archive.json` 이다. ★
//
// 두 가지를 피하려고 여기다. 하나, **큐 폴더에는 쓰지 않는다** — 큐는 읽기 전용이고
// `## 원문` 훼손으로 카드 하나가 폐기된 기록이 QUEUE.md 2026-09-05 14:31 에 있다.
// 둘, `versions.json` 과 같은 폴더에 두되 **파일은 따로** 둔다. 버전 원장은 매 스캔마다
// 다른 코드가 통째로 덮어쓰므로 거기에 보관 기록을 얹으면 스캔 한 번에 날아간다.
enum IssueArchiveStore {

    static var fileURL: URL {
        AppPaths.sub("work-queue").appendingPathComponent("archive.json")
    }

    // 보관 당시의 상태를 통째로 찍어 둔다. 되돌릴 때 "무엇으로 돌아갔다" 를 말할 수 있는
    // 유일한 근거이고, 그 사이에 카드 파일이 또 바뀌었어도 이 값은 안 흔들린다.
    struct Record {
        var key: String
        var archivedAt: String
        var prevBucket: String
        var prevStatus: String
        var prevFolder: String
        var title: String

        var dict: [String: Any] {
            ["key": key, "archivedAt": archivedAt, "prevBucket": prevBucket,
             "prevStatus": prevStatus, "prevFolder": prevFolder, "title": title]
        }
    }

    // MARK: - 키

    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 원장의 키는 `<레인>/<슬러그>` 도 `id:` 도 아니라
    // **파일 이름에서 `.md` 를 뗀 것**이다.
    //
    // `id:` 가 아닌 이유는 버전 원장과 같다(WorkQueueStore.swift 의 versionPairs 주석) — 같은
    // `id:` 를 가진 카드가 두 레인에 하나씩 남은 쌍이 4 쌍 실재해서 id 로는 어느 쪽인지 안
    // 정해진다. 레인을 붙이지 않는 이유는 그 반대다. 카드는 일이 끝나면 `inbox/` 에서 `done/`
    // 으로 옮겨 가는데, 레인을 키에 넣으면 그 순간 보관 깃발이 조용히 떨어진다. 라이언이
    // 치운 것이 다음 새로고침에 목록으로 되돌아오는 것이 이 화면에서 가장 나쁜 실패다.
    // 그래서 들어오는 키가 무슨 모양이든 마지막 경로 조각만 취하고 `.md` 를 벗겨 정규화한다.
    static func normalize(_ raw: String) -> String {
        var k = raw.trimmingCharacters(in: .whitespaces)
        if let slash = k.lastIndex(of: "/") { k = String(k[k.index(after: slash)...]) }
        if k.hasSuffix(".md") { k = String(k.dropLast(3)) }
        return k
    }

    // MARK: - 읽고 쓰기

    private static let lock = NSLock()

    static func records() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: Record] = [:]
        for (k, v) in obj {
            guard let r = v as? [String: Any] else { continue }
            out[k] = Record(key: k,
                            archivedAt: (r["archivedAt"] as? String) ?? "",
                            prevBucket: (r["prevBucket"] as? String) ?? "",
                            prevStatus: (r["prevStatus"] as? String) ?? "",
                            prevFolder: (r["prevFolder"] as? String) ?? "",
                            title: (r["title"] as? String) ?? "")
        }
        return out
    }

    static func isArchived(_ key: String) -> Bool {
        records()[normalize(key)] != nil
    }

    private static func save(_ all: [String: Record]) {
        var obj: [String: Any] = [:]
        for (k, r) in all { obj[k] = r.dict }
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // 저장은 UTC 로 한다 (2026-09-06). 앞서는 formatter 의 기본 타임존(= 맥의 로컬)이라
        // 이 맥이 IST 일 때 `+0530`, 한국이면 `+0900` 이 섞여 파일에 남았다. 앞으로 생성되는
        // 것만 UTC 이고 이미 적힌 값은 손대지 않는다 — 포맷에 `Z` 가 있어서 파싱은 적힌
        // 오프셋을 그대로 존중하므로 옛 값도 계속 정확히 읽힌다(마이그레이션 불필요).
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f.string(from: Date())
    }

    // MARK: - 보관 · 보관 해제

    // 찍어 두는 값은 **서버가 카드에서 직접 읽은 것**이다. 화면이 보낸 값을 그대로 믿으면
    // 되돌아가는 자리를 호출자가 마음대로 정할 수 있게 되고, 그러면 되돌리기가 기록이
    // 아니라 주장이 된다.
    static func archive(key rawKey: String) -> String {
        guard let card = find(key: rawKey) else {
            return "{\"ok\":false,\"error\":\"unknown-card\"}"
        }
        let k = normalize(card.fileName)
        lock.lock()
        var all = records()
        all[k] = Record(key: k, archivedAt: stamp(), prevBucket: card.bucket,
                        prevStatus: card.status, prevFolder: card.folder, title: card.title)
        save(all)
        lock.unlock()
        return "{\"ok\":true,\"prevBucket\":\(jsonStr(card.bucket))}"
    }

    // 일괄 보관. 2026-09-06 라이언: "일괄 워크하이브 버튼도 있으면 좋을 것 같아요 / 일괄 한
    // 번에 다 어카이브 하는 거야."
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다): "다" 의 범위는 **화면에 지금 보이는 것**이다. 큐
    // 전체가 아니다. 화면은 상태·트랙·대상 필터를 물고 있으므로 라이언이 `미분류` 를 골라 놓고
    // 누르면 그 1 개만 치우고, `전체` 로 두고 누르면 전부 치운다. 서버가 "전부" 를 스스로
    // 정하면 라이언이 방금 좁혀 놓은 것을 무시하게 되고, 그것이 되돌리기가 있어도 나쁜 실패다.
    // 그래서 무엇을 치울지는 화면이 키 목록으로 보내고 서버는 받은 것만 치운다.
    //
    // 이미 보관된 키는 **건너뛴다**. 덮어쓰면 `prevBucket` 이 지금 값으로 갈려서, 보관 당시가
    // 무엇이었는지를 말하는 유일한 근거가 조용히 지워진다.
    static func archiveMany(keys raw: [String]) -> String {
        let list = WorkQueueStore.cards()
        let now = stamp()
        lock.lock()
        var all = records()
        var archived = 0, skipped = 0, unknown = 0
        for rk in raw {
            guard let card = find(key: rk, in: list) else { unknown += 1; continue }
            let k = normalize(card.fileName)
            if all[k] != nil { skipped += 1; continue }
            all[k] = Record(key: k, archivedAt: now, prevBucket: card.bucket,
                            prevStatus: card.status, prevFolder: card.folder, title: card.title)
            archived += 1
        }
        if archived > 0 { save(all) }
        lock.unlock()
        return "{\"ok\":true,\"archived\":\(archived),\"skipped\":\(skipped),\"unknown\":\(unknown)}"
    }

    // 되돌린 자리를 **원장에서** 읽어 돌려준다. 지금 카드의 값이 아니다 — 보관해 둔 사이에
    // 카드 파일이 또 바뀌었을 수 있고, 라이언이 알고 싶은 것은 "내가 치웠을 때 무엇이었나" 다.
    static func unarchive(key rawKey: String) -> String {
        let k = normalize(rawKey)
        lock.lock()
        var all = records()
        guard let rec = all[k] else {
            lock.unlock()
            return "{\"ok\":false,\"error\":\"not-archived\"}"
        }
        all.removeValue(forKey: k)
        save(all)
        lock.unlock()
        return "{\"ok\":true,\"restored\":{\"bucket\":\(jsonStr(rec.prevBucket)),"
            + "\"status\":\(jsonStr(rec.prevStatus))}}"
    }

    // MARK: - 목록 가르기

    // `WorkQueueStore.json()` 이 만든 문자열을 받아 보관 깃발로 가르고, **남은 것만으로 파생
    // 숫자를 전부 다시 센다.**
    //
    // 자바스크립트에서 다시 세지 않는 이유는 WorkQueueStore.json() 이 카운트를 실어 보내는
    // 이유와 같다 — 두 곳에서 세면 두 곳이 갈린다. 그래서 뷰마다 세는 자리는 정확히 하나다.
    //
    // 파싱이 깨지면 받은 것을 그대로 돌려준다. 보관 파일 하나가 깨졌다고 화면이 백지가 되면
    // 라이언이 큐를 못 읽게 되고, 그것이 이 기능이 만들 수 있는 가장 비싼 고장이다.
    static func filter(listJSON: String, archivedOnly: Bool) -> String {
        guard let data = listJSON.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cards = payload["cards"] as? [[String: Any]] else {
            return listJSON
        }
        let recs = records()
        func keyOf(_ c: [String: Any]) -> String { normalize((c["file"] as? String) ?? "") }

        var kept: [[String: Any]] = []
        var archivedTotal = 0
        for c in cards {
            let rec = recs[keyOf(c)]
            if rec != nil { archivedTotal += 1 }
            guard (rec != nil) == archivedOnly else { continue }
            var d = c
            if let r = rec {
                // 보관 당시의 값을 행에 같이 싣는다. 지금 버킷과 다르면 화면이 둘 다 보인다 —
                // 보관해 둔 사이에 카드가 바뀐 것을 감추면 그것이 화면의 거짓말이다.
                d["archivedAt"] = r.archivedAt
                d["prevBucket"] = r.prevBucket
                d["prevStatus"] = r.prevStatus
            }
            kept.append(d)
        }

        var byBucket: [String: Int] = [:]
        for b in WorkQueueStore.bucketOrder { byBucket[b] = 0 }
        var tracks: [String: Int] = [:]
        var targets: [String: Int] = [:]
        var withArtifacts = 0, withDirective = 0
        var dupeKeys = Set<String>()
        for c in kept {
            byBucket[(c["bucket"] as? String) ?? WorkQueueStore.bucketUnknown, default: 0] += 1
            tracks[(c["track"] as? String) ?? "없음", default: 0] += 1
            let t = (c["target"] as? String) ?? ""
            targets[t.isEmpty ? "없음" : t, default: 0] += 1
            if ((c["artifactCount"] as? Int) ?? 0) > 0 { withArtifacts += 1 }
            if (c["hasDirective"] as? Bool) ?? false { withDirective += 1 }
            // 원본은 "같은 파일 이름이 두 레인에 다 있는 **쌍**" 의 수를 센다. 여기서도 쌍으로
            // 세야 같은 뜻이 된다 — 행 수로 세면 같은 숫자가 두 배로 보인다.
            if (c["laneDuplicate"] as? Bool) ?? false { dupeKeys.insert(keyOf(c)) }
        }
        let done = byBucket[WorkQueueStore.bucketDone] ?? 0

        payload["cards"] = kept
        payload["counts"] = ["total": kept.count, "done": done,
                             "notDone": kept.count - done, "byBucket": byBucket]
        payload["tracks"] = tracks
        payload["targets"] = targets
        payload["withArtifacts"] = withArtifacts
        payload["withDirective"] = withDirective
        payload["laneDuplicates"] = dupeKeys.count
        payload["archivedCount"] = archivedTotal
        payload["view"] = archivedOnly ? "archive" : "live"

        guard let out = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: out, encoding: .utf8) else {
            return listJSON
        }
        return text
    }

    // MARK: - 카드 찾기

    // `WorkQueueStore.detailJSON(id:)` 과 같은 규칙이다. 레인+파일명이 먼저이고, 그것으로 안
    // 잡히면 id/파일명으로 찾되 `done/` 을 고른다(나중 상태).
    private static func find(key rawKey: String) -> WorkQueueStore.Card? {
        find(key: rawKey, in: WorkQueueStore.cards())
    }

    // 같은 규칙인데 카드 목록을 밖에서 받는다. 일괄 보관이 키마다 `WorkQueueStore.cards()` 를
    // 부르면 카드 90 여 장을 키 개수만큼 다시 읽는다 — 전체 보관 한 번에 파일 읽기가 8000 번이
    // 되고, 그 사이에 큐 폴더가 바뀌면 앞뒤 키가 서로 다른 스냅샷을 보게 된다.
    private static func find(key rawKey: String, in list: [WorkQueueStore.Card]) -> WorkQueueStore.Card? {
        let id = rawKey.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let lane = id.components(separatedBy: "/")
        if lane.count == 2,
           let hit = list.first(where: { $0.folder == lane[0] && $0.fileName == lane[1] + ".md" }) {
            return hit
        }
        let byID = list.filter { $0.id == id || $0.fileName == id + ".md" }
        return byID.first(where: { $0.folder == "done" }) ?? byID.first
    }

    private static func jsonStr(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        var t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        t.removeFirst(); t.removeLast()
        return t
    }
}
