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
        var lastRun: Date?     // when it last fired (nil = never yet)
        var runCount: Int      // total fires since launch
    }

    private var workers: [String: Worker] = [:]
    private var order: [String] = []          // preserves registration order for display
    private let lock = NSLock()

    private init() {}

    // Declare a worker. Idempotent: re-registering keeps the existing run stats so
    // a worker that re-registers (e.g. after restart paths) doesn't lose its count.
    func register(id: String, name: String, detail: String, interval: Double) {
        lock.lock(); defer { lock.unlock() }
        if workers[id] != nil { return }   // keep existing run stats on re-register
        workers[id] = Worker(id: id, name: name, detail: detail, interval: interval,
                             lastRun: nil, runCount: 0)
        order.append(id)
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

    // A worker is "active" when it fired recently relative to its schedule. We
    // allow two intervals plus a few seconds of slack before calling it idle, so a
    // single slow tick doesn't flip the badge. Conditional workers (the BGM
    // director, the menu-bar bard) naturally read as idle once they stop firing.
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
            return "{\"id\":\(Self.j(w.id)),\"name\":\(Self.j(w.name)),\"detail\":\(Self.j(w.detail)),"
                + "\"interval\":\(Int(w.interval.rounded())),\"active\":\(active),"
                + "\"agoSec\":\(agoSec),\"nextSec\":\(nextSec),\"runs\":\(w.runCount)}"
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
