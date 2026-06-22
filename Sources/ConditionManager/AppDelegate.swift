import AppKit

// Central coordinator. Owns every subsystem and runs a single 1 Hz heartbeat
// that drives time accumulation, session gating, and the status-bar label.
// One status item, one heartbeat timer — intentionally minimal.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let store = TimeStore()
    let activity = ActivityMonitor()
    let library = BPMLibrary()
    let audio = AudioEngine()
    let activityLog = ActivityLog()
    let reviewStore = ReviewStore()
    private(set) var director: ConditionDirector!

    // Local dashboard web server (loopback only, started on demand).
    private lazy var dashboard = DashboardServer(
        html: { DashboardContent.html() },
        data: { [weak self] in self?.dashboardData() ?? "{}" },
        post: { [weak self] path, body in self?.handlePost(path, body) ?? "{}" }
    )
    private var minuteInput = 0   // input-present seconds while working (any app), this minute
    private var minuteAppSeconds: [String: Int] = [:] // frontmost seconds per app this minute
    private var minuteSiteSeconds: [String: Int] = [:] // browser-domain seconds this minute
    private var chromeDomain = ""              // cached active-tab domain (refreshed periodically)
    private var siteRefreshing = false

    private var statusItem: NSStatusItem!
    private var menuController: MenuController!
    private var heartbeat: Timer?
    private var tick: Int = 0

    // Manual master switch (Hubstaff-style Start/Stop Working).
    // Tracking + music only run while this is on; defaults off each launch.
    private(set) var isWorking = false
    private(set) var sessionSeconds: Double = 0   // active seconds this session
    private(set) var liveStatus = "정지"

    // Per-app BGM strategy: an app's profile takes over once it has been the
    // frontmost window for at least `dwellThreshold` seconds. (CM_DWELL for tests.)
    private let dwellThreshold = Int(ProcessInfo.processInfo.environment["CM_DWELL"] ?? "") ?? 60
    private var lastFrontBundle: String?
    private var frontStableSeconds = 0
    private var committedProfileKey = ""
    private(set) var activeAppLabel = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        director = ConditionDirector(activity: activity, library: library, audio: audio)
        audio.targetVolume = Float(Settings.shared.volume)

        activity.start()
        reloadLibrary()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "metronome", accessibilityDescription: "Condition Manager")
            button.imagePosition = .imageLeading
        }
        menuController = MenuController(delegate: self)
        statusItem.menu = menuController.menu

        updateStatusTitle()

        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.onHeartbeat()
        }

        // Seed one sample so the dashboard isn't empty on first open.
        activityLog.append(ActivityLog.Sample())

        // Test hooks (smoke tests): auto-start a session; start dashboard server
        // without opening a browser and print its URL.
        let env = ProcessInfo.processInfo.environment
        if let fake = env["CM_FAKE_FRONT"] { Settings.shared.addTrackedApp(fake) }
        if env["CM_AUTOSTART"] != nil { startWorking() }
        if env["CM_DASHBOARD"] != nil {
            dashboard.start { port in
                FileHandle.standardError.write("[dashboard] http://127.0.0.1:\(port)/\n".data(using: .utf8)!)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveIfNeeded()
        director.stop()
        activity.stop()
        heartbeat?.invalidate()
    }

    // MARK: - Heartbeat (1 Hz)

    private func onHeartbeat() {
        tick += 1
        let s = Settings.shared
        // CM_FAKE_FRONT overrides the frontmost app (tests).
        let frontBundle = ProcessInfo.processInfo.environment["CM_FAKE_FRONT"]
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // App filter: if the user designated tracked apps, only those count;
        // otherwise (none configured) any foreground app counts.
        let trackedConfigured = !s.trackedApps.isEmpty
        let isTracked = frontBundle.map { s.trackedApps.contains($0) } ?? false
        let appOK = !trackedConfigured || isTracked
        let isIdle = activity.idleSeconds >= s.idleSeconds

        // The manual switch is the master gate.
        let inSession = isWorking && appOK && !isIdle

        if inSession, let bundle = frontBundle {
            store.add(seconds: 1, app: bundle)
            sessionSeconds += 1
        }
        // Presence input: any input second while in a working session (regardless
        // of the tracked-app filter) — basis for total/desk/focus time.
        if isWorking && !isIdle { minuteInput += 1 }
        // Track the dominant frontmost app within this minute (for the dashboard).
        if let bundle = frontBundle { minuteAppSeconds[bundle, default: 0] += 1 }

        // For browsers, refresh the active-tab domain (throttled) and tally it.
        if let bundle = frontBundle, ValueTier.isBrowser(bundle) {
            if tick % 5 == 0 { refreshBrowserDomain(bundle) }
            if !chromeDomain.isEmpty { minuteSiteSeconds[chromeDomain, default: 0] += 1 }
        } else {
            chromeDomain = ""
        }

        // Human-readable live status for the menu.
        if !isWorking {
            liveStatus = "정지"
        } else if isIdle {
            liveStatus = "자리 비움 · 일시정지"
        } else if !appOK {
            liveStatus = "대기 · 추적 앱이 활성 아님"
        } else {
            liveStatus = "작업 중"
        }

        // --- Per-app BGM strategy: switch profile after >= dwell threshold ---
        if frontBundle == lastFrontBundle {
            frontStableSeconds += 1
        } else {
            lastFrontBundle = frontBundle
            frontStableSeconds = 0
        }
        if isWorking, let bundle = frontBundle, isTracked,
           frontStableSeconds >= dwellThreshold {
            let key = s.profileKey(for: bundle)
            if key != committedProfileKey {
                committedProfileKey = key
                director.applyProfile(BGMProfile.by(key: key))
                activeAppLabel = appDisplayName(bundle)
            }
        }

        // Gate music to the active session.
        if s.musicEnabled && !library.tracks.isEmpty {
            if inSession {
                if !director.isRunning { director.start() }
                else if !director.isActive { director.resumeSession() }
            } else if director.isActive {
                director.pauseSession()
            }
        } else if director.isRunning {
            director.stop()
        }

        // Per-minute activity sample for the dashboard timeline. (CM_SAMPLE_SEC for tests.)
        let sampleInterval = Int(ProcessInfo.processInfo.environment["CM_SAMPLE_SEC"] ?? "") ?? 60
        if tick % sampleInterval == 0 {
            // Dominant app + site this minute, with the strategy/track + value tier.
            let domBundle = minuteAppSeconds.max { $0.value < $1.value }?.key
            let domSite = minuteSiteSeconds.max { $0.value < $1.value }?.key ?? "-"
            let tier = domBundle.map { ValueTier.classify(bundleID: $0, site: domSite) } ?? .passive
            let meeting = domBundle.map { ValueTier.isMeeting(bundleID: $0, site: domSite) } ?? false
            var sample = ActivityLog.Sample()
            sample.rate = Int(activity.activityRate)
            sample.key = Int(activity.keyRate)
            sample.mouse = Int(activity.mouseRate)
            sample.active = minuteInput
            sample.bpm = director.isActive ? Int(director.targetBPM) : 0
            sample.phase = director.isActive ? director.phase.rawValue : "-"
            sample.working = isWorking
            sample.meeting = meeting
            sample.app = domBundle.map { appDisplayName($0) } ?? "-"
            sample.profile = director.isActive ? director.activeProfileLabel : "-"
            sample.track = director.isActive ? (audio.currentTitle ?? "-") : "-"
            sample.site = domSite.isEmpty ? "-" : domSite
            sample.tier = tier.label
            sample.mult = tier.multiplier
            activityLog.append(sample)
            minuteInput = 0
            minuteAppSeconds.removeAll()
            minuteSiteSeconds.removeAll()
        }

        // Live status label every second while working; save every 30s.
        updateStatusTitle()
        if tick % 30 == 0 { store.saveIfNeeded() }

        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil, tick % 2 == 0 {
            let dir = director.isActive
                ? " | 전략=\(director.activeProfileLabel) [\(Int(director.activeMinBPM))-\(Int(director.activeMaxBPM))] BGM \(Int(director.targetBPM))BPM \(director.phase.rawValue)"
                : ""
            FileHandle.standardError.write(
                "[hb t=\(tick)] front=\(frontBundle ?? "-") dwell=\(frontStableSeconds) committed=\(committedProfileKey)\(dir)\n"
                    .data(using: .utf8)!)
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        if isWorking {
            // Ticking session clock, like a stopwatch.
            button.title = " " + Formatting.clock(sessionSeconds)
        } else {
            button.title = " " + Formatting.compactHours(store.data.totalSeconds)
        }
    }

    // MARK: - Manual Start/Stop Working

    func startWorking() {
        guard !isWorking else { return }
        isWorking = true
        sessionSeconds = 0
        committedProfileKey = ""
        frontStableSeconds = 0
        activeAppLabel = ""
        updateStatusTitle()
    }

    func stopWorking() {
        guard isWorking else { return }
        isWorking = false
        committedProfileKey = ""
        activeAppLabel = ""
        director.pauseSession()
        store.saveIfNeeded()
        updateStatusTitle()
    }

    // Refresh the cached browser domain off the main thread (osascript can block
    // and the first call may show a permission prompt).
    private func refreshBrowserDomain(_ bundleID: String) {
        guard !siteRefreshing else { return }
        siteRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let domain = BrowserInspector.activeDomain(bundleID: bundleID)
            DispatchQueue.main.async {
                self?.chromeDomain = domain
                self?.siteRefreshing = false
            }
        }
    }

    // Display name for a bundle id (falls back to the id).
    func appDisplayName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    func toggleWorking() {
        isWorking ? stopWorking() : startWorking()
    }

    // MARK: - Actions invoked by the menu

    func reloadLibrary() {
        // CM_SCAN_DIR env overrides the saved folder (handy for testing).
        let path = ProcessInfo.processInfo.environment["CM_SCAN_DIR"] ?? Settings.shared.musicFolderPath
        guard let path else { return }
        library.load(folderPath: path)
        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil {
            let range = library.bpmRange.map { " range \(Int($0.min))-\(Int($0.max))" } ?? ""
            FileHandle.standardError.write(
                "[ConditionManager] loaded \(library.tracks.count) tracks (skipped \(library.skippedCount))\(range)\n"
                    .data(using: .utf8)!
            )
            for t in library.tracks {
                FileHandle.standardError.write("  \(Int(t.bpm)) BPM  \(t.title)\n".data(using: .utf8)!)
            }
        }
    }

    func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "BPM이 파일명에 포함된 음원 폴더를 선택하세요"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.musicFolderPath = url.path
            reloadLibrary()
            // Restart cleanly so the new library takes effect.
            if director.isRunning { director.stop() }
        }
    }

    func addCurrentFrontmostApp() {
        // Frontmost app excluding ourselves; resolve a moment after activation.
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }), let id = app.bundleIdentifier {
            Settings.shared.addTrackedApp(id)
        }
    }

    func toggleMusic() {
        Settings.shared.musicEnabled.toggle()
        if !Settings.shared.musicEnabled { director.stop() }
    }

    func setAppProfile(_ key: String, for bundleID: String) {
        Settings.shared.setProfile(key, for: bundleID)
        // Force re-evaluation so a change to the current app applies right away.
        committedProfileKey = ""
    }

    func setReleaseMinutes(_ m: Double) { Settings.shared.releaseMinutes = m }
    func setBPMRange(min: Double, max: Double) {
        Settings.shared.minBPM = min
        Settings.shared.maxBPM = max
    }

    func requestAccessibility() {
        activity.requestAccessibilityPrompt()
    }

    func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    // MARK: - Dashboard

    func openDashboard() {
        dashboard.start { port in
            DispatchQueue.main.async {
                if let url = URL(string: "http://127.0.0.1:\(port)/") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // Minimal JSON string encoder (quotes + escapes).
    private func jsonString(_ s: String) -> String {
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

    // JSON payload for the dashboard (today's timeline + live summary).
    func dashboardData() -> String {
        let samples = activityLog.todaySamplesJSON()
        let todayLabel = Formatting.hoursLabel(store.todaySeconds)
        let totalLabel = Formatting.hoursLabel(store.data.totalSeconds)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd (EEE)"
        let date = df.string(from: Date())
        let nowApp = activeAppLabel.isEmpty ? "-" : activeAppLabel
        let nowProfile = director.isActive ? director.activeProfileLabel : "-"
        let nowTrack = director.isActive ? (audio.currentTitle ?? "-") : "-"
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let nowSite = chromeDomain.isEmpty ? "-" : chromeDomain
        let nowTier = ValueTier.classify(bundleID: frontBundle, site: chromeDomain)
        return """
        {"date":"\(date)",\
        "today":{"seconds":\(Int(store.todaySeconds)),"label":"\(todayLabel)"},\
        "total":{"seconds":\(Int(store.data.totalSeconds)),"label":"\(totalLabel)"},\
        "now":{"working":\(isWorking),"status":"\(liveStatus)",\
        "app":\(jsonString(nowApp)),"profile":\(jsonString(nowProfile)),"track":\(jsonString(nowTrack)),\
        "site":\(jsonString(nowSite)),"key":\(Int(activity.keyRate)),"mouse":\(Int(activity.mouseRate)),\
        "tier":\(jsonString(nowTier.label)),"mult":\(nowTier.multiplier)},\
        "review":\(reviewJSON()),\
        "samples":\(samples)}
        """
    }

    // Goals + today's review pipeline state.
    private func reviewJSON() -> String {
        let day = reviewStore.todayKey
        let r = reviewStore.review(day)
        let goals = reviewStore.goals
            .map { g -> String in
                // startedAt as epoch seconds (0 = not running); trackedSeconds is the
                // banked total, so the client can tick the live session locally.
                let started = g.startedAt.map { String($0.timeIntervalSince1970) } ?? "0"
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),\"parent\":\(jsonString(g.parent)),"
                    + "\"status\":\(jsonString(g.status)),\"trackedSeconds\":\(g.trackedSeconds),\"startedAt\":\(started)}"
            }
            .joined(separator: ",")
        let contribs = r.contributions
            .map { "\(jsonString($0.key)):\($0.value)" }
            .joined(separator: ",")
        let notes = r.notes
            .map { "\(jsonString($0.key)):\(jsonString($0.value))" }
            .joined(separator: ",")
        func optInt(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return "{\"goals\":[\(goals)],"
            + "\"selfScore\":\(optInt(r.selfScore)),\"submittedSelf\":\(r.submittedSelf),"
            + "\"contributions\":{\(contribs)},\"notes\":{\(notes)},"
            + "\"aiScore\":\(optInt(r.aiScore)),\"aiNote\":\(jsonString(r.aiNote)),"
            + "\"adminScore\":\(optInt(r.adminScore))}"
    }

    // POST router (runs on the server queue; mutations hop to main for safety).
    func handlePost(_ path: String, _ body: String) -> String {
        let obj = (body.data(using: .utf8)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        return DispatchQueue.main.sync {
            let day = reviewStore.todayKey
            switch path {
            case "/api/goal/add":
                if let text = obj["text"] as? String {
                    reviewStore.addGoal(text: text, parent: (obj["parent"] as? String) ?? "")
                }
            case "/api/goal/remove":
                if let id = obj["id"] as? String {
                    // Clean up notes/contributions for the goal and its children.
                    let removed = Set([id] + reviewStore.goals.filter { $0.parent == id }.map { $0.id })
                    var r = reviewStore.review(day)
                    removed.forEach { r.notes.removeValue(forKey: $0); r.contributions.removeValue(forKey: $0) }
                    reviewStore.saveReview(r, day: day)
                    reviewStore.removeGoal(id: id)
                }
            case "/api/goal/note":
                if let id = obj["id"] as? String {
                    var r = reviewStore.review(day)
                    r.notes[id] = (obj["note"] as? String) ?? ""
                    reviewStore.saveReview(r, day: day)
                }
            case "/api/goal/parent":
                if let id = obj["id"] as? String {
                    reviewStore.setParent(id: id, parent: (obj["parent"] as? String) ?? "")
                }
            case "/api/goal/reorder":
                if let order = obj["order"] as? [String] {
                    reviewStore.reorderGoals(order: order)
                }
            case "/api/goal/status":
                if let id = obj["id"] as? String, let status = obj["status"] as? String {
                    reviewStore.setStatus(id: id, status: status)
                }
            case "/api/review":
                var r = reviewStore.review(day)
                if let s = (obj["selfScore"] as? NSNumber)?.intValue { r.selfScore = s }
                if let c = obj["contributions"] as? [String: Any] {
                    r.contributions = c.compactMapValues { ($0 as? NSNumber)?.intValue }
                }
                r.submittedSelf = true
                reviewStore.saveReview(r, day: day)
            case "/api/aifilter":
                var r = reviewStore.review(day)
                let result = AbuseFilter.evaluate(activityLog.todaySamplesParsed())
                r.aiScore = result.score
                r.aiNote = result.note
                reviewStore.saveReview(r, day: day)
            default:
                break
            }
            return "{\"ok\":true}"
        }
    }

    func quit() {
        dashboard.stop()
        NSApp.terminate(nil)
    }
}
