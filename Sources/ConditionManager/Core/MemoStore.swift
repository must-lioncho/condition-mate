import Foundation

// The 메모장 — ONE global scratch pad, shared by every surface that mounts MemoPad
// (Dashboard/MemoPad.swift). Backed by its own JSON file under AppPaths.base
// (~/.condition-manager/memo.json) so the text survives a page reload, a port change,
// an app restart, and a dev rebuild.
//
// WHY a separate file instead of a Settings key: the memo is free text that grows to
// kilobytes and is saved on a 400ms debounce while the user types. Routing it through
// Settings would rewrite the WHOLE settings.json on every keystroke burst, putting every
// unrelated preference in the blast radius of a mid-write kill. A dedicated file keeps
// the frequent writes isolated (and still atomic).
//
// Global scope is deliberate (approved 2026-07-30): the same one memo appears wherever
// the pad is mounted, so a thought jotted on the 대화 page is there on any other surface.
// Per-goal/per-screen scoping is intentionally NOT modeled — if it is ever needed, add a
// key parameter here rather than a second store.
//
// ── 저장 신뢰 (2026-08-06) ──────────────────────────────────────────────────
// The global scope has one big hazard: the pad is mounted in SEVERAL long-lived webviews
// (dashboard + /goal-add), and a pad that loaded hours ago can POST its whole stale text
// over lines written on another surface since — silently wiping them. Two defenses:
//
//   rev (판번호)  — a monotonic revision, bumped on every accepted change. Clients send
//                   the rev they last saw as `base`; a mismatched base is a STALE writer,
//                   so the write is refused and the current state returned. The client
//                   merges and retries — no version ever silently buries another.
//   history       — every text that leaves `memo.json` (replaced on accept, or refused on
//                   conflict) is appended to memo-history.jsonl first. The journal is a
//                   recovery net, not a product: capped, best-effort, never user-facing.
//                   If a merge ever goes wrong, the buried text is still on disk.
final class MemoStore {
    static let shared = MemoStore()

    // Hard cap so a runaway paste (or a pathological client) can't grow the file without
    // bound. 256K characters is far past any hand-written note; excess is truncated.
    private static let maxChars = 256 * 1024

    // History journal cap. When the file outgrows the byte cap it is trimmed to the most
    // recent entries — old versions age out, recent mistakes stay recoverable.
    // 2026-08-06: raised (768K/100 → 4M/400) when the journal became user-facing — the pad's
    // 히스토리 menu reads it, so "yesterday's long draft" must survive a day of debounced saves.
    private static let historyMaxBytes = 4 * 1024 * 1024
    private static let historyKeepLines = 400

    private let fileURL: URL
    private let historyURL: URL
    private let lock = NSLock()
    private let histLock = NSLock()
    private var text: String = ""
    private var updatedAt: Double = 0      // epoch seconds of the last save (0 = never)
    private var rev: Int = 0               // monotonic revision (0 = never saved)

    private init() {
        fileURL = AppPaths.base.appendingPathComponent("memo.json", isDirectory: false)
        historyURL = AppPaths.base.appendingPathComponent("memo-history.jsonl", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            text = (obj["text"] as? String) ?? ""
            updatedAt = (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            // Files from before rev existed: a saved text means at least one revision.
            rev = (obj["rev"] as? NSNumber)?.intValue ?? (updatedAt > 0 ? 1 : 0)
        }
    }

    // MARK: Read

    var current: (text: String, updatedAt: Double, rev: Int) {
        lock.lock(); defer { lock.unlock() }
        return (text, updatedAt, rev)
    }

    // MARK: Write

    // `base` is the revision the client last saw (nil = legacy caller, always accepted).
    // A mismatched base means another surface saved in between — the write is refused
    // (conflict=true, current state returned) and the REFUSED text is journaled, so even
    // a client that dies before retrying leaves its words on disk.
    // Returns the state as stored (text may be truncated at maxChars).
    @discardableResult
    func save(_ raw: String, base: Int? = nil) -> (text: String, updatedAt: Double, rev: Int, conflict: Bool) {
        let clipped = raw.count > MemoStore.maxChars
            ? String(raw.prefix(MemoStore.maxChars)) : raw
        lock.lock()
        // No-op writes (a debounce firing on unchanged text) must not touch the disk or
        // bump updatedAt/rev — a spurious revision would make every other pad re-merge.
        if clipped == text {
            let now = (text, updatedAt, rev, false)
            lock.unlock()
            return now
        }
        if let b = base, b != rev {
            let now = (text, updatedAt, rev, true)
            lock.unlock()
            appendHistory(kind: "refused", rev: b, text: clipped)
            return now
        }
        let buried = text
        text = clipped
        rev += 1
        updatedAt = Date().timeIntervalSince1970
        let snapshot: [String: Any] = ["text": text, "updatedAt": updatedAt, "rev": rev]
        let result = (text, updatedAt, rev, false)
        lock.unlock()
        if !buried.isEmpty { appendHistory(kind: "replaced", rev: result.2 - 1, text: buried) }
        // Atomic so a kill mid-write can never leave a half-written memo behind.
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: []) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return result
    }

    // MARK: Loop harvest (릴리즈 컷)

    // 루프(스프린트) 컷은 보드 목표만이 아니라 메모장의 완료 줄도 거둔다 (2026-08-07 —
    // "메모장에서 한 것도 완료된 루프 로그에 같이 들어가게"). ReviewStore.releaseSprint 가
    // 릴리즈를 만들 때 부른다. 두 종류를 거둔다:
    //   - 스탬프 없는 완료 줄(- [x])      → 지금 '@루프: <releaseCode>' 들여쓴 줄을 찍는다
    //   - 이미 sprintCode 로 스탬프된 완료 줄 → 패드의 '루프 종료' 버튼이 먼저 묻어 둔 줄.
    //     includeStamped(=이 릴리즈가 스프린트 기본 코드의 첫 커밋)일 때만 함께 거둔다 —
    //     같은 스프린트의 늦은 부분 커밋(26-38.2)이 앞 릴리즈가 이미 기록한 줄을 다시
    //     세지 않도록.
    // 반환은 거둔 줄의 제목(문서 순서). 스탬프 문법은 MemoPad 의 '@골' 과 같은 4칸 들여쓴
    // 줄이라 파싱→재직렬화 항등이 유지되고, 패드는 다음 로드/새로고침에서 병합으로 받는다.
    // 릴리즈 복원(restoreRelease)은 메모를 되돌리지 않는다 — 릴리즈 기록의 notes 는 그
    // 순간의 스냅숏이고, 묻힌 줄은 '이전 루프 포함' 보기로 언제든 볼 수 있다.
    func harvestLoop(sprintCode: String, releaseCode: String, includeStamped: Bool) -> [String] {
        guard !releaseCode.isEmpty else { return [] }
        // 판 충돌(그 사이 패드가 저장)이면 새 판을 다시 읽어 다시 찍는다 — 최대 3회.
        for _ in 0..<3 {
            let (out, ok) = harvestOnce(sprintCode: sprintCode, releaseCode: releaseCode,
                                        includeStamped: includeStamped)
            if ok { return out }
        }
        return []
    }

    private func harvestOnce(sprintCode: String, releaseCode: String,
                             includeStamped: Bool) -> ([String], Bool) {
        let snapshot = current
        guard !snapshot.text.isEmpty else { return ([], true) }
        let lines = snapshot.text.components(separatedBy: "\n")
        // 각 체크리스트 줄의 들여쓴 블록에서 '@루프: ' 값을 찾는다(없으면 nil).
        func stampOf(block: ArraySlice<String>) -> String? {
            for l in block {
                guard l.hasPrefix("    ") || l.hasPrefix("\t") else { break }
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("@루프:") {
                    return String(t.dropFirst("@루프:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        var out: [String] = []
        var rewritten: [String] = []
        var changed = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            rewritten.append(line)
            let isDone = line.hasPrefix("- [x]")
            if isDone {
                let title = String(line.dropFirst("- [x]".count)).trimmingCharacters(in: .whitespaces)
                let stamp = stampOf(block: lines[(i + 1)...])
                if stamp == nil, !title.isEmpty {
                    // 제목 바로 다음에 찍는다 — 파서는 블록 안 순서를 가리지 않는다.
                    rewritten.append("    @루프: \(releaseCode)")
                    changed = true
                    out.append(title)
                } else if includeStamped, let s = stamp, !sprintCode.isEmpty, s == sprintCode, !title.isEmpty {
                    out.append(title)
                }
            }
            i += 1
        }
        if changed {
            // 서버 내부 쓰기 — 지금 판(rev)을 base 로 쓰므로 다른 창의 새 글을 덮지 않는다.
            let r = save(rewritten.joined(separator: "\n"), base: snapshot.rev)
            if r.conflict { return ([], false) }
        }
        return (out, true)
    }

    // MARK: History read

    // The pad's 히스토리 menu (GET /api/memo/history). Newest first. Entries whose text
    // matches the CURRENT memo are skipped — the list is "what you can go back to", and
    // showing the present as a past version only confuses. Empty texts are skipped too
    // (nothing to restore). `limit` bounds the response, not the journal.
    func history(limit: Int = 100) -> [(t: Double, rev: Int, kind: String, text: String)] {
        let nowText = current.text
        histLock.lock()
        let raw = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? ""
        histLock.unlock()
        var out: [(t: Double, rev: Int, kind: String, text: String)] = []
        for line in raw.split(separator: "\n").reversed() {
            if out.count >= limit { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty, text != nowText
            else { continue }
            out.append((t: (obj["t"] as? NSNumber)?.doubleValue ?? 0,
                        rev: (obj["rev"] as? NSNumber)?.intValue ?? 0,
                        kind: (obj["kind"] as? String) ?? "",
                        text: text))
        }
        return out
    }

    // MARK: History journal

    // Best-effort by design: a failed append must never block or fail a save.
    private func appendHistory(kind: String, rev: Int, text: String) {
        let entry: [String: Any] = ["t": Date().timeIntervalSince1970,
                                    "rev": rev, "kind": kind, "text": text]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: []) else { return }
        data.append(0x0A)
        histLock.lock(); defer { histLock.unlock() }
        if let h = try? FileHandle(forWritingTo: historyURL) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: historyURL)
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: historyURL.path))?[.size] as? Int,
           size > MemoStore.historyMaxBytes,
           let whole = try? String(contentsOf: historyURL, encoding: .utf8) {
            let kept = whole.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(MemoStore.historyKeepLines).joined(separator: "\n") + "\n"
            try? kept.data(using: .utf8)?.write(to: historyURL, options: .atomic)
        }
    }
}
