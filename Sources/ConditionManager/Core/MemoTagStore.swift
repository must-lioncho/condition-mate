import Foundation

// 메모장 칸(담당·팀·프로젝트)의 태그 사전 — 같은 사람/팀/프로젝트가 철자만 다르게 여러 벌
// 쌓이는 것을 막는 유일한 장치다. 슬랙에서 사람을 부를 때처럼, 몇 글자 치면 이미 쓰던 이름이
// 떠오르고 그걸 고른다. 없을 때만 "만들기" 로 새 이름이 사전에 들어간다.
//
// WHY 별도 파일: 메모 본문(memo.json)은 타이핑 중 400ms 마다 통째로 덮어써진다. 사전을 거기에
// 얹으면 매 키 입력이 사전의 blast radius 가 된다. 그리고 사전은 본문보다 오래 살아야 한다 —
// 메모 줄을 지워도 "그 사람은 존재한다" 는 사실은 남는 게 맞다.
//
// 저장 포맷 (~/.condition-manager/memo-tags.json):
//     { "담당": [ {"name":"ismail","count":3,"createdAt":…,"usedAt":…}, … ], "팀": […], … }
// count/usedAt 은 정렬용 — 자주·최근 쓴 이름이 먼저 뜬다. 날짜(목표일)는 사전을 두지 않는다.
final class MemoTagStore {
    static let shared = MemoTagStore()

    // 사전을 두는 칸. 메모장의 FIELDS(MemoPad.swift)와 이름이 같아야 한다 — 클라이언트가
    // 칸 이름을 그대로 k 로 보낸다. 자유 입력 kind 를 받지 않는 이유: 오타 하나가 새 사전을
    // 만들어 버리면 사전이 사전 구실을 못 한다.
    static let kinds = ["담당", "팀", "프로젝트"]

    private static let maxPerKind = 2000       // 폭주 방지 (사람이 손으로 만드는 이름의 상한 훨씬 위)
    private static let maxNameChars = 80

    struct Tag {
        var name: String
        var count: Int
        var createdAt: Double
        var usedAt: Double
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var tags: [String: [Tag]] = [:]

    private init() {
        fileURL = AppPaths.base.appendingPathComponent("memo-tags.json", isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for kind in MemoTagStore.kinds {
            guard let list = obj[kind] as? [[String: Any]] else { continue }
            tags[kind] = list.compactMap { row in
                guard let name = (row["name"] as? String), !name.isEmpty else { return nil }
                return Tag(name: name,
                           count: (row["count"] as? NSNumber)?.intValue ?? 1,
                           createdAt: (row["createdAt"] as? NSNumber)?.doubleValue ?? 0,
                           usedAt: (row["usedAt"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
    }

    // MARK: Read

    static func isKind(_ k: String) -> Bool { return kinds.contains(k) }

    // 검색. 빈 질의는 "자주 쓰는 것부터" 목록으로 — 아무것도 안 치고 칸에 들어왔을 때
    // 이미 있는 이름을 먼저 보여 주는 게 중복을 막는 가장 값싼 방법이다.
    //
    // 매칭은 세 단계로 점수를 매긴다(작을수록 먼저):
    //   0 앞글자 일치 · 1 단어 앞글자 일치 · 2 아무데나 포함
    // 같은 단계 안에서는 많이 쓴 것 → 최근 쓴 것 → 이름순.
    func search(kind: String, query: String, limit: Int = 8) -> [Tag] {
        lock.lock(); defer { lock.unlock() }
        let list = tags[kind] ?? []
        let q = MemoTagStore.fold(query)
        if q.isEmpty {
            return Array(list.sorted(by: MemoTagStore.byUse).prefix(limit))
        }
        let scored: [(Int, Tag)] = list.compactMap { t in
            let n = MemoTagStore.fold(t.name)
            if n.hasPrefix(q) { return (0, t) }
            // 단어 경계(공백·-·_·.) 뒤에서 시작하면 "홍 길동" 의 "길" 도 잡힌다.
            if n.split(whereSeparator: { " -_./".contains($0) }).contains(where: { $0.hasPrefix(q) }) {
                return (1, t)
            }
            if n.contains(q) { return (2, t) }
            return nil
        }
        return scored.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            return MemoTagStore.byUse(a.1, b.1)
        }.prefix(limit).map { $0.1 }
    }

    // 질의와 글자까지 똑같은 태그가 이미 있는가 — 있으면 "만들기" 를 내밀지 않는다.
    func exists(kind: String, name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let n = MemoTagStore.fold(name)
        return (tags[kind] ?? []).contains { MemoTagStore.fold($0.name) == n }
    }

    // MARK: Write

    // 만들기 / 사용 기록. 이미 있으면 새로 만들지 않고 사용 횟수만 올린다(대소문자·여백만
    // 다른 입력이 두 벌로 갈라지지 않도록). 저장된 이름을 돌려준다 — 클라이언트는 자기가
    // 친 글자가 아니라 사전에 있는 표기를 칸에 넣어야 한다.
    @discardableResult
    func touch(kind: String, name raw: String) -> String? {
        guard MemoTagStore.isKind(kind) else { return nil }
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                             .prefix(MemoTagStore.maxNameChars))
        guard !name.isEmpty else { return nil }
        lock.lock()
        var list = tags[kind] ?? []
        let now = Date().timeIntervalSince1970
        let key = MemoTagStore.fold(name)
        var stored = name
        if let i = list.firstIndex(where: { MemoTagStore.fold($0.name) == key }) {
            list[i].count += 1
            list[i].usedAt = now
            stored = list[i].name
        } else {
            guard list.count < MemoTagStore.maxPerKind else { lock.unlock(); return nil }
            list.append(Tag(name: name, count: 1, createdAt: now, usedAt: now))
        }
        tags[kind] = list
        let snapshot = serialized()
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: []) {
            try? data.write(to: fileURL, options: .atomic)   // atomic — 중간에 죽어도 반쪽 사전이 남지 않는다
        }
        return stored
    }

    // MARK: Helpers

    // 비교용 정규화 — 대소문자·앞뒤 여백·연속 공백만 지운다. 그 이상(자모 분해 등)은 하지
    // 않는다: 다르게 보이는 두 이름을 같은 것으로 뭉치면 사람이 되돌릴 방법이 없다.
    private static func fold(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
    }

    private static func byUse(_ a: Tag, _ b: Tag) -> Bool {
        if a.count != b.count { return a.count > b.count }
        if a.usedAt != b.usedAt { return a.usedAt > b.usedAt }
        return a.name < b.name
    }

    // lock 을 이미 쥔 상태에서만 부른다.
    private func serialized() -> [String: Any] {
        var out: [String: Any] = [:]
        for (kind, list) in tags {
            out[kind] = list.map { t -> [String: Any] in
                ["name": t.name, "count": t.count,
                 "createdAt": Int(t.createdAt), "usedAt": Int(t.usedAt)]
            }
        }
        return out
    }
}
