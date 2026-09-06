import Foundation

// 중앙은 라우터만 소유한다. registry의 각 경로를 매 조회마다 직접 읽기 때문에 프로젝트 정의를
// Condition Mate로 복사하지 않으며, definition mtime과 조회 시각으로 연결/동기화 상태를 말한다.
enum LoopDefinitionStore {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Loop
            .deletingLastPathComponent() // Plugins
            .deletingLastPathComponent() // ConditionMate
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repository
    }

    private static var registryURL: URL {
        repositoryRoot.appendingPathComponent("Sources/ConditionMate/Plugins/Loop/loops/index.md")
    }

    // 등록표에 적힌 경로들. 라우팅 표는 이 한 곳에서만 읽는다.
    static func routes() -> [String] {
        let registry = (try? String(contentsOf: registryURL, encoding: .utf8)) ?? ""
        return registry.split(separator: "\n").compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- /") else { return nil }
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
    }

    // 선언 본문만. 세션 원장(LoopSessionLedger)이 "이 세션은 어느 루프 것인가"를 판정할 때
    // 각 루프의 sessionSignatures / sessionSkills 를 읽어 가는 자리다. 화면용 상태(트리거
    // 등록 여부, 원장 건수)는 붙이지 않는다 — 판정에 필요 없고 launchd 조회가 비싸다.
    static func definitions() -> [[String: Any]] {
        routes().compactMap { route in
            guard let text = try? String(contentsOfFile: route, encoding: .utf8),
                  let data = definitionData(in: text),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return obj
        }
    }

    static func json() -> String {
        let fm = FileManager.default
        let routes = routes()
        let jobs = DeviceCronScanner.shared.jobsSnapshot()
        let scannedAt = Date()
        var loops: [[String: Any]] = []

        for route in routes {
            guard let text = try? String(contentsOfFile: route, encoding: .utf8),
                  let data = definitionData(in: text),
                  var item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                loops.append(["id": URL(fileURLWithPath: route).deletingLastPathComponent().lastPathComponent,
                              "name": URL(fileURLWithPath: route).deletingLastPathComponent().lastPathComponent,
                              "definitionPath": route, "connected": false, "status": "broken",
                              "workspace": URL(fileURLWithPath: route).deletingLastPathComponent().deletingLastPathComponent().path,
                              "runCount": 0])
                continue
            }
            item["definitionPath"] = route
            item["connected"] = true
            item["syncedAt"] = ISO8601DateFormatter().string(from: scannedAt)
            if let attrs = try? fm.attributesOfItem(atPath: route), let m = attrs[.modificationDate] as? Date {
                item["definitionUpdatedAt"] = ISO8601DateFormatter().string(from: m)
            }
            let workspace = (item["workspace"] as? String) ?? ""
            item["workspaceExists"] = fm.fileExists(atPath: workspace)

            var triggers = (item["triggers"] as? [[String: Any]]) ?? []
            for i in triggers.indices {
                guard let label = triggers[i]["label"] as? String,
                      let job = jobs.first(where: { $0.label == label }) else {
                    triggers[i]["registered"] = triggers[i]["kind"] as? String == "event"
                    continue
                }
                triggers[i]["registered"] = job.loaded && !job.disabled
                triggers[i]["running"] = job.pid > 0
                triggers[i]["lastExit"] = job.lastExit
                triggers[i]["lastRunEpoch"] = job.lastRunEpoch
                triggers[i]["schedule"] = job.schedule.isEmpty ? triggers[i]["cadence"] : job.schedule
            }
            item["triggers"] = triggers

            let ledger = (item["ledgerPath"] as? String) ?? (workspace + "/ledger/runs.jsonl")
            if let body = try? String(contentsOfFile: ledger, encoding: .utf8) {
                let lines = body.split(separator: "\n")
                // 원장 건수는 "이 루프가 몇 번 일했나"로 읽힌다. 그런데 공용 데몬은 Slack
                // 폴링(api.auth.test, api.conversations.history …)까지 같은 파일에 적는다 —
                // 실측으로 8118행 중 4994행이 폴링이었고, 그래서 화면의 "원장 8118건"은
                // 실제 동작의 2.6배로 부풀어 있었다. 여기서 폴링을 빼고 센다.
                // JSON 파싱 대신 문자열 일치를 쓰는 이유: act()가 키 순서를 고정해 쓰므로
                // 결과가 같고, 원장이 커져도 스캔 비용이 선형에 머문다.
                let pollMarker = "\"action\":\"api."
                let work = lines.filter { !$0.contains(pollMarker) }
                item["runCount"] = work.count
                item["runCountRaw"] = lines.count
                item["runCountPolls"] = lines.count - work.count
                // 원장이 언제부터 있는지 — 토큰 기록 구간과 비교해야 "기록이 없는 구간"이
                // 보인다. 앞뒤 한 행씩만 읽는다.
                func epoch(_ line: Substring) -> Double? {
                    guard let d = String(line).data(using: .utf8),
                          let row = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                    else { return nil }
                    if let at = row["at"] as? Double { return at }
                    if let at = row["at"] as? Int { return Double(at) }
                    if let ts = row["ts"] as? String { return ISO8601DateFormatter().date(from: ts)?.timeIntervalSince1970 }
                    return nil
                }
                if let first = lines.first, let e = epoch(first) {
                    item["ledgerFrom"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: e))
                }
                if let last = lines.last, let e = epoch(last) {
                    item["ledgerTo"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: e))
                }
                if let last = lines.last, let d = String(last).data(using: .utf8),
                   var row = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    // 공용 데몬 원장은 epoch `at`/`action`/`ok`, 프로젝트 루프는
                    // ISO `ts`/`stage`/`outcome`을 쓴다. 화면 계약만 여기서 한 모양으로 맞춘다.
                    if row["ts"] == nil, let epoch = row["at"] as? Double {
                        row["ts"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
                    } else if row["ts"] == nil, let epoch = row["at"] as? Int {
                        row["ts"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(epoch)))
                    }
                    if row["stage"] == nil { row["stage"] = row["action"] ?? "" }
                    if row["outcome"] == nil, let ok = row["ok"] as? Bool { row["outcome"] = ok ? "ok" : "failed" }
                    item["lastRun"] = row
                }
            } else { item["runCount"] = 0; item["runCountRaw"] = 0; item["runCountPolls"] = 0 }
            let usagePaths = (item["usagePaths"] as? [String]) ?? []
            let usage = usageEvents(paths: usagePaths, workspace: workspace, now: scannedAt)
            item["usageEvents"] = usage.recent
            item["usageTotals"] = usage.totals
            loops.append(item)
        }

        let payload: [String: Any] = ["loops": loops, "count": loops.count,
            "directory": registryURL.deletingLastPathComponent().path, "registry": registryURL.path,
            "scannedAt": ISO8601DateFormatter().string(from: scannedAt)]
        let out = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: out, as: UTF8.self)
    }

    private static func definitionData(in markdown: String) -> Data? {
        guard let start = markdown.range(of: "```json") else { return nil }
        let tail = markdown[start.upperBound...]
        guard let end = tail.range(of: "```") else { return nil }
        return String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
    }

    // 최근 30일의 실제 모델 usage만 전달한다. 호출 횟수나 문자열 길이로 토큰을 추정하지 않는다.
    // Claude CLI와 Gemini/Anthropic API의 서로 다른 usage 키를 이 경계에서 한 모양으로 맞춘다.
    //
    // 차트용 이벤트(recent)와 별개로 누적 합계(totals)를 같이 낸다. 31일 창만 주면 화면이
    // "최근 24시간" 같은 짧은 창밖에 못 그리는데, 토큰 기록이 20분치뿐인 루프에서는 그
    // 숫자가 루프 전체를 대표하는 것처럼 읽힌다. firstAt 을 같이 줘서 "언제부터 기록된
    // 숫자인가"를 화면이 항상 밝힐 수 있게 한다.
    private static func usageEvents(paths: [String], workspace: String, now: Date)
        -> (recent: [[String: Any]], totals: [String: Any]) {
        let cutoff = now.addingTimeInterval(-31 * 86_400)
        let iso = ISO8601DateFormatter()
        var out: [[String: Any]] = []
        var allInput = 0, allOutput = 0, allTotal = 0, allCalls = 0, pricedCalls = 0
        var allCost = 0.0
        var firstAt: Date?, lastAt: Date?
        for raw in paths {
            let expanded = NSString(string: raw).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: workspace).appendingPathComponent(expanded).path
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let tail = data.count > 12_000_000 ? data.suffix(12_000_000) : data[...]
            for line in String(decoding: tail, as: UTF8.self).split(separator: "\n") {
                guard let d = String(line).data(using: .utf8),
                      let row = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                let date: Date?
                if let ts = row["ts"] as? String { date = iso.date(from: ts) }
                else if let at = row["at"] as? Double { date = Date(timeIntervalSince1970: at) }
                else if let at = row["at"] as? Int { date = Date(timeIntervalSince1970: Double(at)) }
                else { date = nil }
                guard let date else { continue }
                let usage = (row["usage"] as? [String: Any]) ?? row
                func number(_ key: String) -> Int {
                    if let n = usage[key] as? Int { return n }
                    if let n = usage[key] as? Double { return Int(n) }
                    return 0
                }
                let directInput = number("input_tokens")
                let cacheCreate = number("cache_creation_input_tokens")
                let cacheRead = number("cache_read_input_tokens")
                let input = directInput + cacheCreate + cacheRead
                let output = number("output_tokens")
                let declared = number("total_tokens")
                let total = declared > 0 ? declared : input + output
                guard total > 0 else { continue }
                let cost: Double
                if let n = row["cost_usd"] as? Double { cost = n }
                else if let n = row["cost_usd"] as? Int { cost = Double(n) }
                else if let s = row["cost_usd"] as? String { cost = Double(s) ?? 0 }
                else { cost = 0 }
                // 누적은 창을 자르기 전에 센다 — 이게 "이 루프가 지금까지 쓴 총량"이다.
                allInput += input; allOutput += output; allTotal += total
                allCost += cost; allCalls += 1
                if row["cost_usd"] != nil { pricedCalls += 1 }
                if firstAt == nil || date < firstAt! { firstAt = date }
                if lastAt == nil || date > lastAt! { lastAt = date }

                guard date >= cutoff else { continue }
                out.append(["ts": iso.string(from: date), "input": input, "output": output,
                            "total": total, "costUSD": cost,
                            "model": row["model"] ?? row["detail"] ?? "",
                            "stage": row["stage"] ?? row["action"] ?? "model"])
            }
        }
        var totals: [String: Any] = ["input": allInput, "output": allOutput, "total": allTotal,
                                     "costUSD": allCost, "calls": allCalls,
                                     // 단가를 아는 호출 수. calls 와 다르면 비용이 과소 집계다.
                                     "pricedCalls": pricedCalls]
        if let f = firstAt { totals["firstAt"] = iso.string(from: f) }
        if let l = lastAt { totals["lastAt"] = iso.string(from: l) }
        return (out.sorted { (($0["ts"] as? String) ?? "") < (($1["ts"] as? String) ?? "") }, totals)
    }
}
