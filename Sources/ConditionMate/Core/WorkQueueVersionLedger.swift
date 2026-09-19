import Foundation
import CryptoKit

// 위임 카드의 버전 원장 — "이게 마지막 버전이구나" 를 화면에서 읽게 하는 자리.
//
// 왜 원장인가. 라이언의 요구는 "내가 계속 이야기하면서 버전 업이 되고 마지막 버전이 이제
// 나와야 되겠지" 였다. 그런데 그 버전의 원천이 디스크에 **없다**. 세 후보를 다 확인했다
// (2026-09-05 실측):
//
//   1. 프론트매터 버전 필드 — 없다. 85 개 카드 어디에도 `version` 계열 키가 없다.
//   2. git 히스토리 — 큐 저장소는 커밋 3 개이고 85 중 20 개는 추적조차 안 된다. 카드별
//      리비전은 82 개가 1, 1 개가 2. 이것을 원천으로 쓰면 화면이 82 개 `v1`, 20 개
//      `버전 없음` 이 되어 쓸모가 없다.
//   3. 계보 필드(`preceding:` 등) — 실재하지만 4 개 카드뿐이다. 있는 것만 곁들여 그린다.
//
// 그래서 **앱이 오늘부터 스스로 센다.** 카드 본문을 해시해서 원장에 남기고, 해시가 이전과
// 다르면 새 버전이다. 오늘 화면은 "전부 v1, 오늘 첫 관측" 이라고 사실대로 말한다.
//
// 대안이었던 "카드 슬러그 유사도로 과거 계보를 추측한다" 는 버렸다. 근거 없는 추측을 화면에
// 사실처럼 올리면 이 화면의 유일한 목적 — 라이언이 믿고 다른 창을 안 여는 것 — 이 깨진다.
//
//   ★ 저장 위치는 `AppPaths.sub("work-queue")/versions.json` 이다. ★
//
// `AppPaths.sub("issue")` 가 아니다. 그 경로는 `IssuePaths.root` 이고 goal-NN 폴더 155 개와
// 첨부와 goal 별 chat 이 사는 **goal 저장소**다. 거기에 큐 원장을 떨어뜨리면 남의 저장소를
// 오염시킨다. 그리고 큐 폴더에도 쓰지 않는다 — 큐는 읽기 전용이다.
enum WorkQueueVersionLedger {

    struct Observation {
        var hash: String
        var firstSeen: String        // ISO8601, 그 해시를 처음 본 시각

        var dict: [String: Any] { ["hash": hash, "firstSeen": firstSeen] }
    }

    static var fileURL: URL {
        AppPaths.sub("work-queue").appendingPathComponent("versions.json")
    }

    // 카드 본문의 내용 해시. 파일 전체(프론트매터 포함)를 센다 — `status:` 가 던짐에서 done 으로
    // 바뀐 것도 라이언이 "계속 이야기하면서" 일어난 변화이므로 버전이다.
    static func hash(_ text: String) -> String {
        let d = SHA256.hash(data: Data(text.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    private static let lock = NSLock()

    // 원장을 읽는다. 깨져 있으면 빈 것으로 시작한다 — 이 원장은 편의 데이터이지 정본이 아니라
    // 복구하려고 애쓸 값이 없다. 정본은 언제나 큐 폴더의 카드다.
    static func load() -> [String: [Observation]] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: [Observation]] = [:]
        for (id, v) in obj {
            guard let rows = v as? [[String: Any]] else { continue }
            let obs = rows.compactMap { r -> Observation? in
                guard let h = r["hash"] as? String, !h.isEmpty else { return nil }
                return Observation(hash: h, firstSeen: (r["firstSeen"] as? String) ?? "")
            }
            if !obs.isEmpty { out[id] = obs }
        }
        return out
    }

    private static func save(_ ledger: [String: [Observation]]) {
        var obj: [String: Any] = [:]
        for (id, obs) in ledger { obj[id] = obs.map { $0.dict } }
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

    // 이번 스캔의 (id, 해시) 전부를 받아 원장을 갱신하고 갱신된 원장을 돌려준다.
    // 해시가 마지막 것과 같으면 아무것도 하지 않는다 — 그래서 앱을 두 번 띄워도 `v1` 이다.
    // 파일 쓰기는 실제로 바뀐 것이 하나라도 있을 때만 한다.
    @discardableResult
    static func observe(_ pairs: [(id: String, hash: String)]) -> [String: [Observation]] {
        lock.lock()
        defer { lock.unlock() }
        var ledger = load()
        var changed = false
        let now = stamp()
        for p in pairs {
            guard !p.id.isEmpty, !p.hash.isEmpty else { continue }
            if ledger[p.id]?.last?.hash == p.hash { continue }
            ledger[p.id, default: []].append(Observation(hash: p.hash, firstSeen: now))
            changed = true
        }
        if changed { save(ledger) }
        return ledger
    }

    // 화면이 쓰는 모양. `v1 · 2026-09-05 첫 관측` 의 재료다.
    // 첫 관측이라는 말을 붙이는 이유는 없는 역사를 있는 척하지 않기 위한 것이다 — 이 원장은
    // 오늘 처음 켜졌고, `v1` 은 "한 번 바뀌었다" 가 아니라 "처음 봤다" 는 뜻이다.
    static func versionsDict(_ obs: [Observation]) -> [[String: Any]] {
        obs.enumerated().map { i, o in
            ["v": i + 1, "hash": String(o.hash.prefix(12)), "firstSeen": o.firstSeen,
             "isLast": i == obs.count - 1, "isFirstObservation": i == 0]
        }
    }
}
