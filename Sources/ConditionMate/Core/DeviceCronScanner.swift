import Foundation

// Discovers the periodic jobs registered on THIS Mac — the ones the app does not
// own and never registered with WorkerRegistry: launchd LaunchAgents and the
// classic crontab. Nothing is hard-coded; the list is whatever the machine
// actually has, so a job added outside the app shows up on the next poll.
//
// Why this exists: WorkerRegistry only knows about workers the app itself starts.
// A launchd agent that was never loaded, or one whose last run exited non-zero,
// is invisible there — and that is exactly the "등록은 해뒀는데 죽어 있는" case a
// human needs to see. Here the truth comes from launchctl, not from our own bookkeeping.
//
// Cost: one `launchctl print` per label (~30ms each). The snapshot is cached for
// `ttl` seconds and computed on whatever queue asks for it — never the main thread,
// so a slow launchctl can't stall the UI heartbeat.
final class DeviceCronScanner {

    static let shared = DeviceCronScanner()

    // One discovered job. `source` distinguishes the two registries so the page can
    // label them; everything else is best-effort and may be absent for a given source.
    struct Job {
        var id: String            // stable key (launchd label, or "crontab:<n>")
        var source: String        // "launchd" | "crontab"
        var name: String          // human-readable name (what a person calls this job)
        var label: String         // the machine identity (reverse-DNS label / crontab line)
        var project: String       // which project this job belongs to, for loop engineering
        var detail: String        // program path + args, or the raw cron command
        var schedule: String      // human-readable Korean cadence
        var loaded: Bool          // registered with launchd right now (crontab: always true)
        var disabled: Bool        // launchctl print-disabled says the label is off
        var pid: Int              // -1 when not running
        var runs: Int             // -1 when unknown
        var lastExit: Int         // -1 when unknown / never exited
        var lastRunEpoch: Double  // mtime of the job's log file, 0 when unknown
        var path: String          // plist path, or the crontab line's origin
        var outLog: String        // StandardOutPath, "" when the job logs nowhere
        var errLog: String        // StandardErrorPath, "" when the job logs nowhere
    }

    private let lock = NSLock()
    private var cached: String = ""
    private var cachedJobs: [Job] = []
    private var cachedAt: Date = .distantPast
    private let ttl: TimeInterval = 30

    private init() {}

    // JSON for /device-cron.json. Serves the cached snapshot while it is fresh so a
    // 5s page poll doesn't shell out 15 times a tick.
    func snapshotJSON(now: Date = Date()) -> String {
        lock.lock()
        if now.timeIntervalSince(cachedAt) < ttl, !cached.isEmpty {
            let hit = cached
            lock.unlock()
            return hit
        }
        lock.unlock()

        let jobs = scan()
        let body = "{\"jobs\":[" + jobs.map(Self.encode).joined(separator: ",") + "],"
            + "\"scannedAt\":\(Int(now.timeIntervalSince1970))}"

        lock.lock()
        cached = body
        cachedJobs = jobs
        cachedAt = now
        lock.unlock()
        return body
    }

    // Every job in the current snapshot. The 루프 엔지니어링 page asks whether a plist a
    // repository committed is actually registered with launchd — a scheduled worker is the
    // only part that starts a route without a human, so an unregistered one means the route
    // has no entry point. It reuses this scan rather than shelling out to launchctl again.
    func jobsSnapshot(now: Date = Date()) -> [Job] {
        lock.lock()
        let fresh = now.timeIntervalSince(cachedAt) < ttl && !cachedJobs.isEmpty
        let jobs = cachedJobs
        lock.unlock()
        if fresh { return jobs }
        _ = snapshotJSON(now: now)
        lock.lock(); defer { lock.unlock() }
        return cachedJobs
    }

    // One job by id, for the detail page. Reuses the cached scan when it is fresh so
    // opening a row does not re-shell out to launchctl for every label.
    func job(id: String, now: Date = Date()) -> Job? {
        lock.lock()
        let fresh = now.timeIntervalSince(cachedAt) < ttl && !cachedJobs.isEmpty
        let jobs = cachedJobs
        lock.unlock()
        if fresh { return jobs.first { $0.id == id } }
        _ = snapshotJSON(now: now)
        lock.lock(); defer { lock.unlock() }
        return cachedJobs.first { $0.id == id }
    }

    // Last `limit` lines of a job's log file. This is the only run history launchd
    // keeps — it reports a last exit code but never a per-run trail — so a job that
    // logs nothing genuinely has no history to show, and we say so rather than invent one.
    static func logTail(_ path: String, limit: Int = 300) -> [String] {
        guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return [] }
        // Read only the tail: these logs are append-only and can grow without bound.
        let slice = data.count > 256_000 ? data.suffix(256_000) : data
        let lines = String(decoding: slice, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return Array(lines.suffix(limit)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Scan

    // Two passes: collect the project names that real paths prove exist, then let
    // label-only jobs (a daemon whose program lives in /Applications, say) resolve
    // their org token against that set instead of inventing a second spelling.
    private func scan() -> [Job] {
        var jobs = scanLaunchAgents()
        jobs.append(contentsOf: scanCrontab())
        let known = Set(jobs.map(\.project).filter { $0 != Self.unknownProject })
        for i in jobs.indices where jobs[i].project == Self.unknownProject {
            jobs[i].project = Self.resolveProject(label: jobs[i].label, detail: jobs[i].detail,
                                                  known: known)
        }
        return jobs
    }

    // Both directories load into the per-user gui domain, so a single
    // `launchctl print gui/<uid>/<label>` answers for either one.
    private var agentDirs: [String] {
        [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents"]
    }

    private func scanLaunchAgents() -> [Job] {
        let fm = FileManager.default
        let uid = getuid()
        let disabledLabels = self.disabledLabels(uid: uid)

        var out: [Job] = []
        for dir in agentDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = dir + "/" + name
                guard let plist = NSDictionary(contentsOfFile: path) else { continue }
                let label = (plist["Label"] as? String) ?? String(name.dropLast(6))
                let detail = Self.programDescription(plist)

                var job = Job(id: label, source: "launchd",
                              name: Self.humanName(label: label),
                              label: label,
                              project: Self.projectFromPath(detail) ?? Self.unknownProject,
                              detail: detail,
                              schedule: Self.launchdSchedule(plist),
                              loaded: false, disabled: disabledLabels.contains(label),
                              pid: -1, runs: -1, lastExit: -1,
                              lastRunEpoch: Self.logMTime(plist), path: path,
                              outLog: (plist["StandardOutPath"] as? String) ?? "",
                              errLog: (plist["StandardErrorPath"] as? String) ?? "")

                // `launchctl print` is the only place that knows whether the job is actually
                // loaded and how its last run ended. A non-zero exit here means "not loaded".
                let printed = Self.shell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
                if !printed.isEmpty {
                    job.loaded = true
                    job.pid = Self.intField(printed, "pid")
                    job.runs = Self.intField(printed, "runs")
                    job.lastExit = Self.intField(printed, "last exit code")
                    if printed.contains("state = running") && job.pid < 0 { job.pid = 0 }
                }
                // A plist-level Disabled key counts even when launchctl has no opinion.
                if (plist["Disabled"] as? Bool) == true { job.disabled = true }
                out.append(job)
            }
        }
        return out
    }

    // Labels launchd has been told to keep off. One call covers every label, so this
    // never scales with the number of agents.
    private func disabledLabels(uid: uid_t) -> Set<String> {
        let text = Self.shell("/bin/launchctl", ["print-disabled", "gui/\(uid)"])
        var set = Set<String>()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix("=> true"), let arrow = line.range(of: "=>") else { continue }
            let label = line[..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !label.isEmpty { set.insert(label) }
        }
        return set
    }

    // The classic unix crontab. Comment lines and `VAR=value` assignments are skipped;
    // everything else is "5 cron fields, then the command".
    private func scanCrontab() -> [Job] {
        let text = Self.shell("/usr/bin/crontab", ["-l"])
        guard !text.isEmpty else { return [] }

        var out: [Job] = []
        var index = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 5 else { continue }
            // A `NAME=value` line has no cron expression — skip it rather than mis-parsing.
            if fields[0].contains("=") { continue }

            let expr = fields[0..<5].joined(separator: " ")
            let command = fields[5...].joined(separator: " ")
            index += 1
            // A crontab line names its own log with `>> file`; that is the only run
            // history it has, so pick it up the way we read a launchd StandardOutPath.
            let logPath = Self.redirectTarget(command)
            out.append(Job(id: "crontab:\(index)", source: "crontab",
                           name: Self.commandName(command), label: line,
                           project: Self.projectFromPath(command) ?? Self.unknownProject,
                           detail: command,
                           schedule: Self.cronSchedule(expr),
                           loaded: true, disabled: false, pid: -1, runs: -1, lastExit: -1,
                           lastRunEpoch: Self.mtime(logPath),
                           path: "crontab -l (line \(index))",
                           outLog: logPath, errLog: ""))
        }
        return out
    }

    // MARK: - Identity: what a person calls this job, and which project owns it

    static let unknownProject = ""
    static let systemProject = "시스템"

    // Reverse-DNS labels carry the org in the middle and the actual job name at the end.
    // `com.globalmpc.support-agents` reads as "support-agents" to a human; the full label
    // is the developer's name for it and belongs on the detail page, not in the list.
    private static func humanName(label: String) -> String {
        var parts = label.split(separator: ".").map(String.init)
        // Drop the reverse-DNS head (com/ai/io/net/org) and the org token after it.
        if let first = parts.first, ["com", "ai", "io", "net", "org", "co"].contains(first) {
            parts.removeFirst()
            if parts.count > 1 { parts.removeFirst() }
        }
        let name = parts.joined(separator: " ")
        return name.isEmpty ? label : name
    }

    // The repo layout is projects/<org-x>/<project>/… — one directory level below the
    // org is the project a job belongs to. This is what makes the list answer
    // "which crons run for THIS project", which is the whole point of grouping.
    private static func projectFromPath(_ text: String) -> String? {
        guard let r = text.range(of: "/projects/") else {
            // The shared workspace scripts live one level up, outside any single project.
            if text.contains("/departtment_service/scripts/") { return "departtment_service" }
            return nil
        }
        let rest = text[r.upperBound...].split(separator: "/").map(String.init)
        guard rest.count >= 2 else { return nil }
        return rest[1]
    }

    // For a job whose program path proves nothing (a daemon inside an .app bundle, a
    // vendor updater, an empty stub plist), fall back to the label's org token — but
    // resolve it against the projects real paths already proved exist, so `condition-mate`
    // lands on `lion-condition-mate` instead of becoming a second, near-identical bucket.
    private static func resolveProject(label: String, detail: String, known: Set<String>) -> String {
        var parts = label.split(separator: ".").map(String.init)
        if let first = parts.first, ["com", "ai", "io", "net", "org", "co"].contains(first) {
            parts.removeFirst()
        }
        guard let token = parts.first, !token.isEmpty else { return systemProject }
        if known.contains(token) { return token }
        if let match = known.first(where: { $0.hasSuffix("-" + token) }) { return match }
        // Nothing of ours: a vendor updater or an OS agent. One bucket, easy to filter out.
        let home = NSHomeDirectory()
        let mine = detail.contains(home + "/Work/") || detail.contains(home + "/.claude/")
        return mine ? token : systemProject
    }

    // `… >> /path/to.log 2>&1` — the file a crontab line appends its output to.
    private static func redirectTarget(_ command: String) -> String {
        let tokens = command.split(separator: " ").map(String.init)
        guard let i = tokens.lastIndex(where: { $0 == ">>" || $0 == ">" }),
              i + 1 < tokens.count else { return "" }
        let target = tokens[i + 1]
        return target.hasPrefix("/") ? target : ""
    }

    // MARK: - plist reading

    private static func programDescription(_ plist: NSDictionary) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            return args.joined(separator: " ")
        }
        if let program = plist["Program"] as? String { return program }
        return "(실행 경로 미지정)"
    }

    // launchd expresses "when" four different ways. Report whichever the plist uses;
    // a job with none of them only runs when something else pokes it.
    private static func launchdSchedule(_ plist: NSDictionary) -> String {
        if let interval = plist["StartInterval"] as? Int, interval > 0 {
            return "\(humanInterval(interval))마다"
        }
        if let cal = plist["StartCalendarInterval"] as? [String: Any] {
            return calendarDescription(cal)
        }
        if let cals = plist["StartCalendarInterval"] as? [[String: Any]], !cals.isEmpty {
            return cals.map(calendarDescription).joined(separator: ", ")
        }
        if let paths = plist["WatchPaths"] as? [String], !paths.isEmpty {
            return "파일 변경 시 (\(paths.count)곳 감시)"
        }
        if (plist["KeepAlive"] as? Bool) == true || plist["KeepAlive"] is [String: Any] {
            return "상주 (죽으면 재시작)"
        }
        if (plist["RunAtLoad"] as? Bool) == true { return "로그인 시 1회" }
        return "수동 (외부 트리거)"
    }

    private static func calendarDescription(_ cal: [String: Any]) -> String {
        let hour = cal["Hour"] as? Int
        let minute = cal["Minute"] as? Int
        let weekday = cal["Weekday"] as? Int
        let day = cal["Day"] as? Int

        let time: String
        if let h = hour, let m = minute { time = String(format: "%02d:%02d", h, m) }
        else if let h = hour { time = String(format: "%02d시", h) }
        else if let m = minute { time = String(format: "매시 %02d분", m) }
        else { time = "시각 미지정" }

        if let w = weekday { return "\(weekdayName(w))요일 \(time)" }
        if let d = day { return "매월 \(d)일 \(time)" }
        if hour == nil, minute != nil { return time }
        return "매일 \(time)"
    }

    private static func weekdayName(_ w: Int) -> String {
        let names = ["일", "월", "화", "수", "목", "금", "토"]
        return names.indices.contains(w % 7) ? names[w % 7] : "\(w)"
    }

    // The job's own log file is the closest thing launchd offers to "last run at";
    // launchctl itself never reports one.
    private static func logMTime(_ plist: NSDictionary) -> Double {
        let candidates = [plist["StandardOutPath"] as? String,
                          plist["StandardErrorPath"] as? String].compactMap { $0 }
        return candidates.map(mtime).max() ?? 0
    }

    private static func mtime(_ path: String) -> Double {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSince1970
    }

    // MARK: - cron expression

    private static func cronSchedule(_ expr: String) -> String {
        let f = expr.split(separator: " ").map(String.init)
        guard f.count == 5 else { return expr }
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])

        // Only the common shapes get prose; anything exotic keeps its raw expression,
        // which is more honest than a wrong translation.
        if minute.hasPrefix("*/"), hour == "*", dom == "*", month == "*", dow == "*" {
            return "\(minute.dropFirst(2))분마다"
        }
        if hour.hasPrefix("*/"), dom == "*", month == "*", dow == "*" {
            return "\(hour.dropFirst(2))시간마다"
        }
        if minute == "*", hour == "*" { return "1분마다" }
        guard let m = Int(minute), let h = Int(hour) else { return expr }
        let time = String(format: "%02d:%02d", h, m)
        if dom == "*", month == "*", dow == "*" { return "매일 \(time)" }
        if dow != "*" { return "\(dow) 요일 \(time)" }
        if dom != "*" { return "매월 \(dom)일 \(time)" }
        return expr
    }

    private static func humanInterval(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return "\(seconds / 86400)일" }
        if seconds >= 3600 && seconds % 3600 == 0 { return "\(seconds / 3600)시간" }
        if seconds >= 60 && seconds % 60 == 0 { return "\(seconds / 60)분" }
        return "\(seconds)초"
    }

    // A crontab line's display name: the basename of the script being run, so the row
    // reads "cost_daily.py" rather than the full pipeline with its redirects.
    private static func commandName(_ command: String) -> String {
        for token in command.split(separator: " ") {
            let t = String(token)
            guard t.contains("/"), !t.hasPrefix(">"), !t.hasPrefix("2>") else { continue }
            if let last = t.split(separator: "/").last, last.contains(".") { return String(last) }
        }
        return String(command.prefix(40))
    }

    // MARK: - Helpers

    // Fixed-command shell out (no user input reaches argv). Returns "" on any failure —
    // an unloaded launchd label exits non-zero, and that empty string IS the signal.
    private static func shell(_ launch: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // Pull `<field> = <int>` out of launchctl's indented block output. Values like
    // "(never exited)" or a missing field both yield -1 (unknown).
    private static func intField(_ text: String, _ field: String) -> Int {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(field + " =") else { continue }
            let value = line.dropFirst(field.count + 2).trimmingCharacters(in: .whitespaces)
            return Int(value) ?? -1
        }
        return -1
    }

    private static func encode(_ j: Job) -> String {
        "{\"id\":\(s(j.id)),\"source\":\(s(j.source)),\"name\":\(s(j.name)),"
            + "\"label\":\(s(j.label)),\"project\":\(s(j.project)),"
            + "\"detail\":\(s(j.detail)),\"schedule\":\(s(j.schedule)),"
            + "\"loaded\":\(j.loaded),\"disabled\":\(j.disabled),\"pid\":\(j.pid),"
            + "\"runs\":\(j.runs),\"lastExit\":\(j.lastExit),"
            + "\"lastRunEpoch\":\(Int(j.lastRunEpoch)),\"path\":\(s(j.path)),"
            + "\"hasLog\":\(!j.outLog.isEmpty || !j.errLog.isEmpty)}"
    }

    // Minimal JSON string encoder. Paths and commands come from disk, so escape
    // defensively — one stray quote must not break the whole feed.
    private static func s(_ str: String) -> String {
        var out = "\""
        for scalar in str.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
