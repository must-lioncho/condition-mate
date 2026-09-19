import Foundation

// 루프 지표의 시간축 — `~/.condition-mate/ledger/loop-history.jsonl`.
//
// 왜 필요한가: 지금까지 이 화면에는 `scannedAt` 한 줄뿐이었다. 오늘의 병목 지수가 어제보다
// 나아졌는지 나빠졌는지 알 방법이 없었다. 숫자 하나는 상태이고, 같은 숫자의 연속이 추세다.
// 개선을 말하려면 추세가 있어야 한다.
//
// 이 파일의 두 가지 규칙은 타협하지 않는다.
//
//   1) 절대 덮어쓰지 않는다. append 만 한다. 원장을 다시 쓰기 시작하면 과거가 현재의 해석에
//      맞춰 바뀌고, 그 순간 추세는 증거가 아니라 주장이 된다.
//   2) 조회마다 적지 않는다. 정해진 간격으로만 적는다. 페이지를 열 때마다 한 줄을 남기면
//      원장이 "지표의 역사"가 아니라 "사용자가 화면을 연 횟수"의 기록이 되고, 추세선이
//      사용자의 클릭 습관을 그리게 된다.
enum LoopHistory {

    // 한 줄과 다음 줄 사이의 최소 간격. 6시간이면 하루 최대 네 줄이라, 한 달을 모아도 120줄
    // 남짓이다. 사람이 눈으로 훑을 수 있는 크기를 유지하는 것이 이 값의 목적이다.
    private static let minInterval: TimeInterval = 6 * 3600

    private static let lock = NSLock()

    private static var url: URL {
        let dir = AppPaths.base.appendingPathComponent("ledger", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loop-history.jsonl")
    }

    // 마지막 줄로부터 minInterval 이 지났으면 한 줄 append 한다. 아니면 아무것도 하지 않는다.
    static func appendIfDue(bottleneck: [String: Any], totals: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last = lastEntryDate(), now.timeIntervalSince(last) < minInterval { return }

        var row: [String: Any] = [:]
        row["at"] = ISO8601DateFormatter().string(from: now)
        // 지수 하나만 적으면 나중에 "그때 상한이 몇이었지"를 알 수 없다. 정책과 원값을 같이 적는다.
        row["index"] = bottleneck["index"] ?? 0
        row["indexNoCap"] = bottleneck["indexNoCap"] ?? 0
        row["indexHourCap"] = bottleneck["indexHourCap"] ?? 0
        row["capHours"] = bottleneck["capHours"] ?? 4
        row["humanHours"] = bottleneck["humanHours"] ?? 0
        row["agentHours"] = bottleneck["agentHours"] ?? 0
        row["turns"] = bottleneck["turns"] ?? 0
        row["files"] = bottleneck["files"] ?? 0
        row["windowStart"] = bottleneck["windowStart"] ?? ""
        row["runs"] = totals["runs"] ?? 0
        row["dead"] = totals["dead"] ?? 0
        row["hours"] = totals["hours"] ?? 0
        row["nested"] = totals["nested"] ?? 0

        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        append(line)
    }

    // 최근 n 줄. 1단계 화면은 이것을 그래프가 아니라 텍스트 몇 개로만 쓴다 — 값이 두세 개일 때
    // 꺾은선을 그리면 없는 추세가 있는 것처럼 보인다.
    static func recent(_ n: Int) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(n)
        return lines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    // MARK: - Private

    private static func lastEntryDate() -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let last = text.split(separator: "\n").last,
              let obj = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any],
              let at = obj["at"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: at)
            ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: at)
            }()
    }

    // append 전용 쓰기. 파일 핸들을 끝으로 옮겨 붙인다 — 읽고-고쳐-쓰기를 하지 않는 것이
    // "절대 덮어쓰지 않는다"를 코드에서 보장하는 방법이다.
    private static func append(_ line: String) {
        let u = url
        let fm = FileManager.default
        if !fm.fileExists(atPath: u.path) {
            try? Data(line.utf8).write(to: u)
            return
        }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}
