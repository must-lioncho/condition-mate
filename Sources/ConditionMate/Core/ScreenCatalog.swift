import Foundation

// 화면 카탈로그: the app's every DISTINCT screen state, auto-captured and managed for UX/UI
// review. The app renders far more states than anyone can enumerate from memory (zen start,
// countdown, running dial, 수확 오브, goal detail, queue review, equipment, each condition
// tab, modals, …) — this catalog SEES them all as they actually occur, keeps ONE screenshot
// per state under a stable ID (SCR-0001, …), and counts how often each is entered.
//
// How a state is identified: AppWindowController probes the visible webview every ~2s
// (screenCatalogTick) for a state key = mode | path?querykeys | in-page view | UI flags
// (zen/reward/run/modal/…). Query VALUES are dropped (goal #12 and #34 are the same SCREEN),
// so the catalog stays a bounded set of layouts, not an unbounded set of documents. A state
// must be observed on two consecutive ticks (settled, readyState=complete) before its
// screenshot is taken; an existing state is re-shot when its screenshot is older than
// refreshAfter, so each entry always shows the CURRENT look of that screen.
//
// Storage: <data>/screens/catalog.json (index) + <data>/screens/SCR-XXXX.png (one per state,
// overwritten on refresh). Management fields (note, status) are edited from the 화면 카탈로그
// tab on the condition page (시스템관리) via POST /api/debug/screens/note; screenshots are
// served inline via GET /api/debug/screens/img?id=… (id-whitelisted — never a path lookup).
// All mutation funnels through one serial queue: observations arrive from the main-thread
// timer while list/note/img come from the HTTP server thread.
final class ScreenCatalog {

    static let shared = ScreenCatalog()

    struct Entry: Codable {
        var id: String          // stable screenshot id ("SCR-0001")
        var key: String         // full state key (dedup identity)
        var mode: String        // app-window mode: dashboard | bgm
        var page: String        // path + sorted query KEYS ("/goal?n")
        var view: String        // in-page view/tab (dashboard _view, condition page mode)
        var flags: String       // comma flags: zen,reward,run,counting,done,modal,railoff
        var w: Int              // viewport at last observation
        var h: Int
        var firstSeen: Int64    // ms epoch
        var lastSeen: Int64
        var count: Int          // how many times this state was ENTERED (transitions, not ticks)
        var shotAt: Int64       // ms epoch of the stored screenshot (0 = none yet)
        var file: String        // png filename under screens/ ("" until first capture)
        var note: String        // UX/UI review memo (user-edited)
        var status: String      // management state: "" | review | fix | done | ignore
    }

    private let dir: URL
    private let catalogURL: URL
    private let queue = DispatchQueue(label: "cm.screencatalog", qos: .utility)
    private var entries: [Entry] = []
    private var byKey: [String: Int] = [:]   // key -> index into entries
    private var nextSeq = 1
    private var saveScheduled = false
    private var capWarned = false

    // Re-shoot a state's screenshot when the stored one is older than this — the catalog
    // shows each screen's CURRENT look, not its first-ever look.
    private static let refreshAfter: TimeInterval = 24 * 3600
    // Hard cap on distinct states — a runaway key (e.g. a flag that embeds a timestamp by
    // mistake) must not fill the disk with screenshots. Real state space is well under this.
    private static let maxEntries = 600

    private init() {
        dir = AppPaths.sub("screens")
        catalogURL = dir.appendingPathComponent("catalog.json")
        load()
    }

    // MARK: - Observation (main-thread timer via AppWindowController)

    // Record one observation of the currently visible state. `entered` is true when the key
    // DIFFERS from the previous tick's key (a state transition — that is what count counts).
    // Returns true when this state wants a screenshot (new, never captured, or stale).
    func observe(key: String, mode: String, page: String, view: String, flags: String,
                 w: Int, h: Int, entered: Bool) -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return queue.sync {
            if let i = byKey[key] {
                entries[i].lastSeen = now
                entries[i].w = w
                entries[i].h = h
                if entered { entries[i].count += 1 }
                scheduleSave()
                let stale = Double(now - entries[i].shotAt) / 1000 > Self.refreshAfter
                return entries[i].shotAt == 0 || stale
            }
            guard entries.count < Self.maxEntries else {
                if !capWarned {
                    capWarned = true
                    AppLog.log("screen-catalog cap reached (\(Self.maxEntries)) — new states are no longer recorded")
                }
                return false
            }
            let id = String(format: "SCR-%04d", nextSeq)
            nextSeq += 1
            entries.append(Entry(id: id, key: key, mode: mode, page: page, view: view,
                                 flags: flags, w: w, h: h, firstSeen: now, lastSeen: now,
                                 count: 1, shotAt: 0, file: "", note: "", status: ""))
            byKey[key] = entries.count - 1
            AppLog.log("screen-catalog new state \(id) key=\(key)")
            scheduleSave()
            return true
        }
    }

    // Store the captured screenshot for a state. PNG is written first, then the index —
    // an entry never points at a file that does not exist.
    func record(key: String, png: Data) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        queue.async {
            guard let i = self.byKey[key] else { return }
            let name = self.entries[i].id + ".png"
            let fm = FileManager.default
            if !fm.fileExists(atPath: self.dir.path) {
                try? fm.createDirectory(at: self.dir, withIntermediateDirectories: true)
            }
            do {
                try png.write(to: self.dir.appendingPathComponent(name), options: .atomic)
            } catch {
                AppLog.log("screen-catalog write failed \(name): \(error.localizedDescription)")
                return
            }
            self.entries[i].file = name
            self.entries[i].shotAt = now
            self.scheduleSave()
        }
    }

    // MARK: - API feeds (server thread)

    // GET /api/debug/screens/list — the whole catalog, newest-seen first.
    func listJSON() -> String {
        queue.sync {
            let sorted = entries.sorted { $0.lastSeen > $1.lastSeen }
            let enc = JSONEncoder()
            guard let data = try? enc.encode(sorted), let arr = String(data: data, encoding: .utf8) else {
                return "{\"screens\":[]}"
            }
            return "{\"screens\":\(arr)}"
        }
    }

    // GET /api/debug/screens/img?id=SCR-0001 — the stored PNG. Lookup is BY ID through the
    // in-memory index (id -> its own recorded filename), never by a caller-supplied path.
    func imageData(id: String) -> Data? {
        queue.sync {
            guard let e = entries.first(where: { $0.id == id }), !e.file.isEmpty else { return nil }
            return try? Data(contentsOf: dir.appendingPathComponent(e.file))
        }
    }

    // GET /api/debug/screens/sitemap — the UXUI sitemap (pages -> subpages -> states),
    // derived from the SOURCE by Scripts/uxui-sitemap.py and installed here by the
    // UXUI 관리 worker (Scripts/uxui-sitemap.sh) whenever main moves. Served raw; the
    // 화면 카탈로그 tab joins it with the catalog client-side (match by state-key parts).
    func sitemapJSON() -> String {
        queue.sync {
            let url = dir.appendingPathComponent("sitemap.json")
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8), !s.isEmpty else {
                return "{\"pages\":[]}"
            }
            return s
        }
    }

    // POST /api/debug/screens/note {id, note?, status?} — management fields from the UI.
    func setNote(id: String, note: String?, status: String?) -> Bool {
        queue.sync {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
            if let note { entries[i].note = String(note.prefix(500)) }
            if let status, ["", "review", "fix", "done", "ignore"].contains(status) {
                entries[i].status = status
            }
            scheduleSave()
            return true
        }
    }

    // MARK: - Persistence (on `queue`)

    private func load() {
        guard let data = try? Data(contentsOf: catalogURL),
              let arr = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = arr
        for (i, e) in entries.enumerated() {
            byKey[e.key] = i
            // Recover the counter from the highest stored id, so restarts never reuse an id.
            if e.id.hasPrefix("SCR-"), let n = Int(e.id.dropFirst(4)), n >= nextSeq { nextSeq = n + 1 }
        }
    }

    // Observations land every ~2s while the window is open — debounce the index write so the
    // steady state costs one small file write every few seconds at most.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    private func save() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(entries) {
            try? data.write(to: catalogURL, options: .atomic)
        }
    }
}
