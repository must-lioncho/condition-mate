import Foundation

// Central registry of the app's background "workers" — the repeating timers and
// the sub-cadences driven off the 1 Hz heartbeat. Each worker registers once
// (name, what it does, how often), then calls recordRun() every time it fires.
//
// Nothing here schedules work; it only observes it. The dashboard reads a
// snapshot to answer the three questions a human keeps asking: what workers
// exist, are they actually running, and when do they fire next.
//
// Thread-safety: timers fire on the main thread while the dashboard server reads
// snapshots from its network queue, so every access is guarded by a lock.
final class WorkerRegistry {

    static let shared = WorkerRegistry()

    struct Worker {
        let id: String
        let name: String       // short Korean label for the dashboard
        let detail: String     // one-line description of what it does
        let interval: Double   // seconds between runs (the schedule)
        let owner: String      // "core" (always on) or a plugin id (e.g. "claude-desktop")
        var lastRun: Date?     // when it last fired (nil = never yet)
        var runCount: Int      // total fires since launch
        var lastError: String? // last quality-check failure (nil = healthy)
        var lastErrorAt: Date? // when the last error was recorded
        var enabled: Bool      // user on/off (false = 꺼짐); only toggleable workers use it
    }

    private var workers: [String: Worker] = [:]
    private var order: [String] = []          // preserves registration order for display
    private let lock = NSLock()

    private init() {}

    // Declare a worker. Idempotent: re-registering keeps the existing run stats so
    // a worker that re-registers (e.g. after restart paths) doesn't lose its count.
    // `owner` is "core" for always-on workers, or a plugin id for ones gated by a
    // plugin connection (registered on connect, unregistered on disconnect).
    func register(id: String, name: String, detail: String, interval: Double,
                  owner: String = "core", enabled: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        if workers[id] != nil { return }   // keep existing run stats on re-register
        workers[id] = Worker(id: id, name: name, detail: detail, interval: interval,
                             owner: owner, lastRun: nil, runCount: 0,
                             lastError: nil, lastErrorAt: nil, enabled: enabled)
        order.append(id)
    }

    // Flip a worker's user on/off state (drives the 꺼짐 badge). The runner script reads
    // its own flag file for the authoritative gate; this just mirrors it for display.
    func setEnabled(_ id: String, _ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var w = workers[id] else { return }
        w.enabled = enabled
        workers[id] = w
    }

    // Remove a worker (e.g. its owning plugin was disconnected). The row vanishes
    // from the dashboard and its run stats are dropped; re-registering starts fresh.
    func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        workers.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    // Is this worker currently registered? Lets the heartbeat skip gated work cheaply.
    func isRegistered(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return workers[id] != nil
    }

    // Stamp a worker as having just fired. Cheap (date + counter) so even the
    // 1 Hz heartbeat can call it every tick.
    func recordRun(_ id: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var w = workers[id] else { return }
        w.lastRun = date
        w.runCount += 1
        workers[id] = w
    }

    // Record a fire AND write a detail log line (why it ran, what it changed).
    // Use this where one fire maps to one meaningful log entry; use the plain
    // recordRun for high-frequency counters that log separately (the heartbeat).
    func recordRun(_ id: String, why: String, effect: String, at date: Date = Date()) {
        recordRun(id, at: date)
        WorkerLog.shared.append(id, why: why, effect: effect, at: date)
    }

    // Record a quality-check FAILURE: stamp the run, flag the worker with an error
    // (surfaced as a red 상태 badge), and write an error-level log line. The worker
    // stays registered — the error clears on the next healthy run (recordRun).
    func recordError(_ id: String, why: String, detail: String, at date: Date = Date()) {
        lock.lock()
        if var w = workers[id] {
            w.lastRun = date
            w.runCount += 1
            w.lastError = detail
            w.lastErrorAt = date
            workers[id] = w
        }
        lock.unlock()
        WorkerLog.shared.append(id, why: why, effect: detail, level: "error", at: date)
    }

    // Clear a worker's error flag (a quality check passed). Cheap; safe to call every run.
    func clearError(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard var w = workers[id], w.lastError != nil else { return }
        w.lastError = nil
        w.lastErrorAt = nil
        workers[id] = w
    }

    // Static metadata for one worker (name/detail/interval), for the log page.
    func info(_ id: String) -> (name: String, detail: String, interval: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let w = workers[id] else { return nil }
        return (w.name, w.detail, w.interval)
    }

    // All workers in registration order (id + name), for the combined log timeline.
    func allWorkers() -> [(id: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { workers[$0] }.map { (id: $0.id, name: $0.name) }
    }

    // Workers that fired within the last `window` seconds — the 워커(cron) usage
    // signal for the equipment pomodoro EXP attribution (EquipmentStore).
    func runsWithin(_ window: TimeInterval, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return workers.values.filter { w in
            guard let last = w.lastRun else { return false }
            return now.timeIntervalSince(last) <= window
        }.count
    }

    // A worker is "active" when it fired recently relative to its schedule. We
    // allow two intervals plus a few seconds of slack before calling it idle, so a
    // single slow tick doesn't flip the badge. Conditional workers (e.g. the BGM
    // director) naturally read as idle once they stop firing.
    private func isActive(_ w: Worker, now: Date) -> Bool {
        guard let last = w.lastRun else { return false }
        let slack = max(3.0, w.interval * 2)
        return now.timeIntervalSince(last) <= slack
    }

    // JSON array for the dashboard, in registration order. Each entry carries the
    // schedule plus server-computed "seconds since" / "seconds until" so the client
    // can render a live countdown without worrying about clock skew.
    func snapshotJSON(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let entries = order.compactMap { workers[$0] }.map { w -> String in
            let active = isActive(w, now: now)
            let agoSec: Int
            if let last = w.lastRun {
                agoSec = max(0, Int(now.timeIntervalSince(last).rounded()))
            } else {
                agoSec = -1   // never run
            }
            // Seconds until next fire (only meaningful while active).
            let nextSec: Int
            if active, let last = w.lastRun {
                let due = last.addingTimeInterval(w.interval)
                nextSec = max(0, Int(due.timeIntervalSince(now).rounded()))
            } else {
                nextSec = -1
            }
            let errJSON = w.lastError.map { Self.j($0) } ?? "null"
            // The QA automation workers are user-toggleable; core/plugin workers aren't.
            // "즉시 실행" only applies to the periodic inspection worker — the fix worker
            // is event-driven (fired when a goal is filed), so it's toggleable but not runnable.
            let toggleable = (w.owner == "qa")
            let runnable = (w.id == "qa-agent")
            // bug-hunt is launched BY HAND at end of day (Scripts/bug-hunt.sh), not by a
            // scheduler. Its `interval` is the per-round cadence inside one multi-hour run,
            // not a fire schedule — flag it so the dashboard labels it 수동, not 자동화.
            let manual = (w.id == "bug-hunt")
            return "{\"id\":\(Self.j(w.id)),\"name\":\(Self.j(w.name)),\"detail\":\(Self.j(w.detail)),"
                + "\"owner\":\(Self.j(w.owner)),\"interval\":\(Int(w.interval.rounded())),\"active\":\(active),"
                + "\"agoSec\":\(agoSec),\"nextSec\":\(nextSec),\"runs\":\(w.runCount),"
                + "\"error\":\(w.lastError != nil),\"errorMsg\":\(errJSON),"
                + "\"enabled\":\(w.enabled),\"toggleable\":\(toggleable),\"runnable\":\(runnable),\"manual\":\(manual)}"
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    // Minimal JSON string encoder (quotes + escapes). Worker labels are static
    // Korean text, but escape defensively so a stray quote never breaks the feed.
    private static func j(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
