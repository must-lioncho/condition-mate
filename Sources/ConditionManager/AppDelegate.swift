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
    let trackPrefs = TrackPreferenceStore()
    let trackEvents = TrackEventLog()
    let trackPlayStats = TrackPlayStatsStore()
    let bgmPlan = BGMPlanMap()
    let pluginStore = PluginStore()
    let equipment = EquipmentStore()
    let chatStore = ChatStore()
    private(set) var director: ConditionDirector!

    // Local dashboard web server (loopback only, started on demand).
    private lazy var dashboard = DashboardServer(
        html: { DashboardContent.html(lastView: Settings.shared.lastView, doneCutoff: Settings.shared.doneCutoff, uiPrefs: Settings.shared.uiPrefs) },
        data: { [weak self] in self?.dashboardData() ?? "{}" },
        live: { [weak self] in self?.liveData() ?? "{}" },
        post: { [weak self] path, body in self?.handlePost(path, body) ?? "{}" },
        file: { [weak self] path in
            if path.hasPrefix("/bgm-audio/") { return self?.serveBGMAudio(path) }
            if path.hasPrefix("/chat-img/") { return self?.serveChatImage(path) }
            if path.hasPrefix("/task-file") { return self?.serveTaskFile(path) }
            if path.hasPrefix("/api/debug/snapshot") { return self?.serveSnapshot(path) }
            return self?.serveEvidence(path)
        },
        page: { [weak self] path in
            if path.hasPrefix("/bgm-timeline-test") { return BGMTimelineTestContent.html() }
            if path.hasPrefix("/session-continue-test") { return SessionContinueTestContent.html() }
            if path.hasPrefix("/lounge-break-test") { return LoungeBreakTestContent.html() }
            if path.hasPrefix("/bgm-player") { return BGMPlayerContent.html() }
            if path.hasPrefix("/bgm-plan") { return BGMPlanContent.html() }
            if path.hasPrefix("/equipment") { return EquipmentContent.html() }
            if path.hasPrefix("/goal") { return self?.goalPage(path) }
            if path.hasPrefix("/worker-log") { return self?.workerLogAllPage(path) }
            if path.hasPrefix("/worker") { return self?.workerLogPage(path) }
            if path.hasPrefix("/cron") { return self?.cronPage() }
            if path.hasPrefix("/breakdown") { return self?.breakdownPage(path) }
            return self?.transcriptPage(path)
        },
        loopFeed: { [weak self] in self?.loopQueueJSON() ?? "{}" },
        chat: { [weak self] in self?.chatJSON() ?? "{}" },
        apiGet: { [weak self] path in
            // All four feeds carry the scope in the query (?seq=NN[&task=…]); an empty/absent
            // task yields a goal scope, so existing seq-only links keep hitting the goal path.
            if path.hasPrefix("/api/goal/chat") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"messages\":[]}" }
                return self?.goalChatJSON(scope)
            }
            if path.hasPrefix("/api/goal/definition") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"text\":\"\"}" }
                let kind = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "kind" })?.value ?? "core"
                return self?.goalDefinitionJSON(scope, kind: kind)
            }
            if path.hasPrefix("/api/goal/sessions") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"sessions\":[]}" }
                return self?.goalSessionsJSON(scope)
            }
            if path.hasPrefix("/api/sessions/recent") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"sessions\":[]}" }
                return self?.recentSessionsJSON(scope)
            }
            if path.hasPrefix("/api/cli/sessions") {
                return self?.cliSessionsJSON()
            }
            if path.hasPrefix("/api/skills/history") {
                return self?.skillHistoryJSON()
            }
            if path.hasPrefix("/api/skills") {
                return self?.skillsJSON()
            }
            if path.hasPrefix("/api/agents") {
                return self?.agentsJSON()
            }
            if path.hasPrefix("/history.json") {
                return self?.dashboardHistory(path)
            }
            if path.hasPrefix("/tokens.json") {
                return self?.dashboardTokens(path)
            }
            if path.hasPrefix("/api/bgm/now") {
                return self?.bgmNowJSON()
            }
            // 전략3 plan map + planner context (current slot, real theme folders).
            if path.hasPrefix("/api/bgm/plan") {
                return self?.bgmPlanJSON()
            }
            // Shared challenge+mute state for any surface that polls it directly (the rail's
            // challenge dial). Includes elapsed active seconds so a page loading mid-session shows
            // the right time.
            if path.hasPrefix("/api/session/state") {
                return self?.sessionStateJSON()
            }
            // 장비+숙련도 state (levels, market inflation, award ledger + plugin list)
            // for the /equipment page and the rail's settings-menu level chip.
            if path.hasPrefix("/api/equipment") {
                return self?.equipmentJSON()
            }
            if path.hasPrefix("/api/bgm/stats") {
                return self?.bgmStatsJSON(path)
            }
            if path.hasPrefix("/api/bgm/list") {
                return self?.bgmListJSON()
            }
            // Lightweight worker snapshot for the standalone 크론(/cron) page — just the
            // workers array, so that page never has to poll the heavy /data.json.
            if path.hasPrefix("/workers.json") {
                return self?.workersJSON()
            }
            return nil
        },
        sse: { [weak self] path, channel in self?.handleChat2Stream(path, channel) }
    )
    private var minuteInput = 0   // input-present seconds while working (any app), this minute
    private var minuteAppSeconds: [String: Int] = [:] // frontmost seconds per app this minute
    private var minuteSiteSeconds: [String: Int] = [:] // browser-domain seconds this minute
    private var chromeDomain = ""              // cached active-tab domain (refreshed periodically)
    private var siteRefreshing = false

    private var statusItem: NSStatusItem!
    private var gauge: LightningGauge!
    private var menuController: MenuController!
    // Single native app window (WKWebView) hosting both the dashboard and the BGM player, switched
    // by an in-window toggle. Replaces the old browser-based dashboard entirely — no web browser.
    private lazy var appWindow = AppWindowController()
    // While the app window is OPEN (in EITHER .dashboard or .bgm mode) it owns audio output: native
    // BGM stays muted the whole time (not just reactively), so the two never overlap ("음악이 두
    // 번"). Released (native unmuted) only when the window closes. See AppWindowController's file
    // header for why: the BGM webview keeps playing regardless of visible mode, so ownership must
    // follow "window open", not "mode == .bgm" — the earlier mode-based rule left native audible
    // in .dashboard mode while the BGM webview kept playing underneath (double audio).
    private var windowOwnsAudio = false
    // App-wide keyboard shortcuts (⌘M mute / ⌘S start·stop challenge). A LOCAL event monitor fires
    // only while the app is active and for ANY of its windows/pages — exactly "앱을 활성화한 뒤 어느
    // 페이지에서든" — without the system-wide Accessibility grant a global monitor would need.
    private var shortcutMonitor: Any?
    private var heartbeat: Timer?
    private var tick: Int = 0
    // Smooth menu-bar APM: the heartbeat only fires at 1 Hz, so reading instantAPM
    // straight into the title makes the number jump in big steps every second. A
    // dedicated ~20 Hz timer glides a displayed value toward the live target so the
    // digit rises and falls smoothly instead of stuttering.
    private var titleTimer: Timer?
    private var displayedAPM: Double = 0
    // Last values written to the worker log, so high-frequency workers log only on
    // change instead of one line per fire (see onHeartbeat).
    private var lastLoggedStatus = ""
    private var lastLoggedDomain = ""

    // Menu-bar gauge mode, mirroring the dashboard toggle. 스포츠 = live APM that
    // bounces every second (focus/fun early on); 타임 = the focus clock (pride in
    // the total once the day is long). Auto-defaults by today's tracked time until
    // the user picks one from the menu (menuBarModeUserSet), then the choice sticks.
    enum MenuBarMode { case sports, time }
    private(set) var menuBarMode: MenuBarMode = .sports
    private var menuBarModeUserSet = false
    // 토탈 시간 (work span), recomputed from samples periodically so the menu-bar clock
    // matches the dashboard "토탈 시간" card. Base = sum of sub-6h gaps between anchors
    // (minute-grained); while working we add the live seconds since the last anchor so
    // the clock ticks every second (HH:MM:SS). Samples are per-minute, hence the split.
    private var totalSpanBaseSec: Double = 0
    private var lastAnchorT: Int = 0
    private var totalSpanCacheAt: Date = .distantPast

    // 토탈 시간 to display now: minute-grained base + live seconds since the last active
    // minute while working (frozen otherwise, and a 6h+ tail is 퇴근, so it stops).
    private func totalSpanDisplaySec() -> Double {
        guard lastAnchorT > 0 else { return totalSpanBaseSec }
        let tail = Date().timeIntervalSince1970 - Double(lastAnchorT)
        let live = (isWorking && tail < 8 * 3600) ? max(0, tail) : 0
        return totalSpanBaseSec + live
    }

    // Master switch (Hubstaff-style Start/Stop Working). Tracking + music only
    // run while this is on. Auto-started on launch (see applicationDidFinishLaunching);
    // the menu button remains available to pause/resume mid-session.
    // Single source of truth for the two live session flags (challenge on/off + music mute),
    // shared by every surface — gauge widget, dropdown menu, dashboard, BGM player. See
    // ChallengeSession. start/stopWorking and the mute path write through this object.
    let session = ChallengeSession()
    // Read-compat shim: many call sites read `isWorking` (is the challenge live?). The value now
    // lives in `session`; this keeps those sites unchanged while there is one owner of the state.
    var isWorking: Bool { session.isRunning }
    private(set) var sessionSeconds: Double = 0   // active seconds this session
    private(set) var liveStatus = "정지"

    // Per-app BGM strategy: an app's profile takes over once it has been the
    // frontmost window for at least `dwellThreshold` seconds. (CM_DWELL for tests.)
    private let dwellThreshold = Int(ProcessInfo.processInfo.environment["CM_DWELL"] ?? "") ?? 60
    private var lastFrontBundle: String?
    private var frontStableSeconds = 0
    private var committedProfileKey = ""
    private(set) var activeAppLabel = ""

    // One-shot guard so the "no music folder" alert appears at most once per
    // playback session (the heartbeat runs at 1 Hz; nagging every tick would
    // freeze the menu bar). Re-armed when the session ends.
    private var musicFolderPromptShown = false

    // --- Waiting (응답 대기) detection (see .doc/waiting-signal-policy.md) ---
    // Safety-net timeout: an in_progress session whose transcript has not grown for
    // this many seconds is treated as parked-waiting, banking its time. Large enough
    // not to mistake a long-running tool for a stall; tunable (CM_WAIT_TIMEOUT, tests).
    private let waitTimeout = Double(ProcessInfo.processInfo.environment["CM_WAIT_TIMEOUT"] ?? "") ?? 120
    // Real-time "is it running?" window (priority 1): a transcript touched within this many
    // seconds means the agent is working right now, so the goal is promoted to in_progress
    // immediately — even when the active hook never fires. Smaller than waitTimeout so the
    // 진행중 → 응답 대기 demotion has hysteresis (no flicker for a session that writes every
    // few seconds). Tunable (CM_ACTIVE_WINDOW).
    private let activeWindow = Double(ProcessInfo.processInfo.environment["CM_ACTIVE_WINDOW"] ?? "") ?? 15
    // Recency window for retroactively reconciling a stranded backlog session goal back to
    // 응답 대기 (slice of design B). Only sessions touched within this window are revived,
    // so an ancient, abandoned session is never resurrected. Tunable (CM_RECONCILE_WINDOW).
    private let reconcileWindow = Double(ProcessInfo.processInfo.environment["CM_RECONCILE_WINDOW"] ?? "") ?? 21600
    // Reap window for an abandoned 응답 대기 goal: a session parked for a human whose
    // transcript stays silent this long is treated as abandoned (the user closed it, or
    // forked it into a new session_id) and retired to 취소(cancelled). Without this, waiting
    // is a one-way trap — priority-1 can't resume a transcript that never changes again and
    // SessionEnd never fires on app-close/fork — so the count grows forever and drifts from
    // Claude Code's live-session view. cancelled (not done) keeps it out of completion metrics
    // and hidden by default. Reap is terminal (recordSession + reconcile both skip cancelled,
    // so it never bounces back), so keep this comfortably longer than a plausible human break;
    // the user can manually reopen if they return to that exact session. Tunable (CM_WAIT_REAP).
    private let waitReap = Double(ProcessInfo.processInfo.environment["CM_WAIT_REAP"] ?? "") ?? 3600
    // Per-session transcript size cache: re-parse the tail only when the file grew,
    // so an idle/waiting session costs a cheap stat, not a full read, each tick.
    private var sessionSeenSize: [String: Int] = [:]
    private var sessionPendingAsk: [String: Bool] = [:]   // last tail had an unanswered AskUserQuestion
    private var sessionTurnEnded: [String: Bool] = [:]     // last tail was a finished assistant turn (awaiting human)
    // Per-transcript token-by-day cache: parsing every ~/.claude/projects/*.jsonl on each
    // poll would be costly, so remember (mtime, size) -> per-day token totals and re-parse a
    // file only when it changes. Keyed by absolute path. Guarded by tokenDayLock.
    private var tokenDayCache: [String: (mtime: Date, size: Int, days: [String: Int])] = [:]
    private let tokenDayLock = NSLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.log("LAUNCH — bundle=\(Bundle.main.bundleIdentifier ?? "nil") argv0=\(CommandLine.arguments.first ?? "?") log=\(AppLog.fileURL.path)")
        // Test hook: CM_QUIT_AFTER=<seconds> triggers the real NSApp.terminate quit path so the
        // full shutdown sequence (applicationShouldTerminate/WillTerminate + window/audio cleanup)
        // can be exercised headlessly and inspected in app.log.
        if let s = ProcessInfo.processInfo.environment["CM_QUIT_AFTER"], let n = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { NSApp.terminate(nil) }
        }
        // Single instance: terminate any older copy already running (a dev auto-reload relaunch
        // or a double-click). Two instances would each start BGM ("음악이 두 번") and one would
        // linger after the other is quit ("앱을 껐는데 위젯이 남음").
        Self.terminateOtherInstances()

        // LSUIElement (menu-bar) apps have no application main menu, so the standard editing
        // key equivalents (Cmd+C/V/X/A, Undo/Redo) are never dispatched to the responder chain.
        // That breaks paste/copy inside the WKWebView's HTML inputs (e.g. the "목표 추가" modal —
        // "붙여넣기가 안 됨"). Install a minimal Edit menu so these shortcuts reach paste:/copy:/… .
        Self.installEditMenu()

        director = ConditionDirector(activity: activity, library: library, audio: audio,
                                     prefStore: trackPrefs, planMap: bgmPlan)
        audio.targetVolume = Float(Settings.shared.volume)
        // Play-time accounting: AudioEngine times each audible segment; the store accrues
        // per-track seconds/plays that feed the BGM 관리 "재생 시간 순위" section.
        audio.onSegmentEnd = { [weak self] key, title, secs in
            self?.trackPlayStats.addSeconds(key: key, title: title, seconds: secs)
        }
        audio.onTrackStart = { [weak self] key, title in
            self?.trackPlayStats.bumpPlay(key: key, title: title)
        }

        activity.start()
        reloadLibrary()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            // Monospaced digits so the APM number and clock keep a constant width —
            // the title never jiggles as the digit count changes (ofSize 0 = default).
            button.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        }
        // Lightning condition gauge: a single bolt that charges bottom-up across
        // five stages and shifts colour with the live condition (활동/개인 최고치
        // 비율). Drives only the button image; the APM/clock text is the button
        // title (updateStatusTitle).
        gauge = LightningGauge { [weak self] image in
            self?.statusItem.button?.image = image
        }
        menuController = MenuController(delegate: self)
        statusItem.menu = menuController.menu

        // In BGM mode the window owns audio: keep native muted the whole time so playback never
        // doubles up, and hand it back on the dashboard / when the window closes.
        appWindow.onOwnAudio = { [weak self] owns in
            guard let self = self else { return }
            self.windowOwnsAudio = owns
            // While the window owns audio, native stays muted regardless of the user's mute intent
            // (no double playback). When it hands audio back on close, native reflects the user's
            // mute intent (session.isMuted) rather than blindly unmuting — so ⌘M made before closing
            // is preserved.
            self.applyNativeMute()
            AppLog.log("app window owns audio=\(owns) -> native muted=\(self.audio.muted)")
        }
        // Closing the app window quits the entire app — the window and the menu-bar app terminate
        // together (the user's goal: "같이 종료"). Dispatched async so we don't tear down while
        // still inside the window's own windowWillClose.
        appWindow.onUserClose = { [weak self] in
            AppLog.log("app window user-closed -> quitting app (같이 종료)")
            DispatchQueue.main.async { self?.quit() }
        }

        // App-wide keyboard shortcuts, active on any page while the app is frontmost:
        //   ⌘M — 음원 뮤트 on/off      ⌘S — 챌린지 시작/중단
        // Returning nil consumes the event so it never reaches the webview (⌘S "save", ⌘M "minimize").
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event) ?? event
        }

        updateStatusTitle()

        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.onHeartbeat()
        }

        // Glide the menu-bar APM digit between the 1 Hz heartbeats so it flows
        // smoothly instead of jumping. Runs in .common mode so it keeps ticking
        // while the menu is open.
        let tt = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(tt, forMode: .common)
        titleTimer = tt

        registerWorkers()

        // Seed one sample so the dashboard isn't empty on first open.
        activityLog.append(ActivityLog.Sample())

        // Auto-start a work session on launch: the master switch comes up ON so
        // tracking + music begin immediately (activity/idle/app gating still apply).
        startWorking()

        // Test hooks (smoke tests): start dashboard server without opening a
        // browser and print its URL.
        let env = ProcessInfo.processInfo.environment
        if let fake = env["CM_FAKE_FRONT"] { Settings.shared.addTrackedApp(fake) }
        if env["CM_DASHBOARD"] != nil {
            dashboard.start { port in
                FileHandle.standardError.write("[dashboard] http://127.0.0.1:\(port)/\n".data(using: .utf8)!)
            }
        }

        // Start the loopback server eagerly (no browser) so its port is published to
        // dashboard.port from launch and the Claude Code session hooks can reach the
        // API even before the user opens the dashboard. Idempotent: openDashboard()
        // later reuses the same listener.
        dashboard.start { _ in }

        // Guaranteed zero-click BGM: auto-open the native BGM window (WKWebView with autoplay
        // enabled) on launch so the activity BGM plays with the space effect immediately. Respect
        // the master switch — if the user turned BGM off (e.g. by closing the window), don't force
        // it back on at launch.
        // Auto-open the app on launch on the DASHBOARD (its face is now the dashboard; the condition
        // surface is reached via the rail's "컨디션 전체 보기"). BGM is still turned on so the BGM
        // webview — created + parked off-view by ensureBuilt — is the live audio engine from launch,
        // playing whenever a challenge runs. (Don't gate on musicEnabled: an earlier off-state would
        // then silently skip opening the window.)
        if Settings.shared.bgmWindowEnabled {
            setBGMEnabled(true)
            dashboard.start { [weak self] port in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Dev (CM_DEV): a dev-watch rebuild relaunches the process on every save, so
                    // auto-popping the window in front here would keep covering the editor. Start
                    // the server (done above) but leave the window closed — open it from the menu
                    // bar when wanted. Opt back in for dashboard-UI sessions with CM_DEV_AUTO_OPEN=1.
                    if AppPaths.isDev && !AppPaths.devAutoOpen {
                        AppLog.log("dev mode (CM_DEV): skip launch auto-open — open the window from the menu bar")
                        return
                    }
                    self.appWindow.autoOpen(port: port, mode: .dashboard)
                }
            }
        }
        AppLog.log("bgm auto-open on launch: bgmWindowEnabled=\(Settings.shared.bgmWindowEnabled)")

        // Resume any AI-queue candidates left pending by a previous run (loadQueue already
        // reverted orphaned "analyzing" items back to pending) so the "bump out" backlog
        // keeps draining across restarts.
        if reviewStore.hasPendingAnalysis { kickAIQueueWorker() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.log("applicationWillTerminate — stopping director + audio, closing BGM window")
        store.saveIfNeeded()
        director.stop()
        audio.stop()
        activity.stop()
        appWindow.closeForQuit()
        gauge?.showIdle()
        if let m = shortcutMonitor { NSEvent.removeMonitor(m); shortcutMonitor = nil }
        heartbeat?.invalidate()
        titleTimer?.invalidate()
        AppLog.log("applicationWillTerminate — done")
    }

    // Log the quit request and let it proceed. If something ever blocked termination this would
    // show us the app got the request but did not die.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.log("applicationShouldTerminate — reply=terminateNow")
        return .terminateNow
    }

    // Force-quit any other running copy of this app (same bundle id) so only one instance ever
    // plays BGM or owns a menu-bar item. A bare SPM binary (no Info.plist / bundle id) is skipped.
    // Build a minimal application main menu whose Edit submenu carries the standard editing
    // actions with their conventional key equivalents. AppKit only routes Cmd+C/V/X/A (and
    // Undo/Redo) to the first responder's copy:/paste:/cut:/selectAll: when a menu item exposes
    // that key equivalent. Without a main menu (the default for LSUIElement apps) those shortcuts
    // are swallowed, so pasting into the WKWebView-hosted dashboard inputs silently fails.
    private static func installEditMenu() {
        let mainMenu = NSMenu()

        // A first (app) menu is conventional but not required for key equivalents; keep it minimal.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            AppLog.log("single-instance: no bundle id (bare binary) — skipping dedup")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        AppLog.log("single-instance: found \(others.count) other instance(s): \(others.map { $0.processIdentifier })")
        for app in others {
            AppLog.log("single-instance: forceTerminate pid \(app.processIdentifier)")
            app.forceTerminate()
        }
    }

    // MARK: - Workers

    // Declare every background worker once so the dashboard can show what exists,
    // whether it's running, and its schedule. Each worker stamps WorkerRegistry as
    // it fires (see onHeartbeat and the subsystem timers). Intervals here mirror the
    // actual cadences below — keep them in sync.
    private func registerWorkers() {
        let r = WorkerRegistry.shared
        let sampleInterval = Double(ProcessInfo.processInfo.environment["CM_SAMPLE_SEC"] ?? "") ?? 60
        r.register(id: "heartbeat", name: "코어 루프",
                   detail: "1초마다 시간 적립·세션 게이팅·상태바 갱신", interval: 1)
        r.register(id: "activity-sample", name: "활동 샘플",
                   detail: "키·마우스 입력률 평활화(APM 산출)", interval: 5)
        r.register(id: "browser-domain", name: "브라우저 도메인",
                   detail: "활성 탭 도메인 갱신(가치 분류용)", interval: 5)
        // The BGM 디렉터 worker is owned by 컨디션 메이트 (registered in syncPluginWorkers),
        // not core — installing that plugin is what brings BGM online.
        r.register(id: "autosave", name: "상태 저장",
                   detail: "누적 시간 디스크 플러시", interval: 30)
        r.register(id: "timeline-sample", name: "타임라인 기록",
                   detail: "분 단위 활동 샘플을 대시보드 타임라인에 적립", interval: sampleInterval)
        // QA agent: an EXTERNAL automation (launchd → claude -p, see Scripts/qa-scan.sh)
        // that screenshots the dashboard, flags UI rendering breakage, and files a goal
        // doc. The app only observes it — each run is reported via POST /api/worker/ping.
        // owner "qa" renders as a distinct 자동화 badge. It reads 유휴 whenever the
        // launchd job isn't pinging (which is the truth). The scan period is user-set in
        // qa-interval-sec (default 600=10분, via Scripts/qa-set-interval.sh); read it so
        // the dashboard 주기 column matches the real cadence (refreshed on next launch).
        r.register(id: "qa-agent", name: "QA 점검",
                   detail: "대시보드 UI 렌더링 깨짐 탐지 · goal 문서 자동 생성",
                   interval: Self.qaIntervalSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.qaDisabledFlag.path))
        // QA fix agent: event-driven. qa-scan.sh fires it (detached) whenever the
        // inspection agent files a goal; it fixes the UI in an isolated git worktree and
        // reports here. Not periodic — interval is display-only; it reads 유휴 between fixes.
        r.register(id: "qa-fix", name: "QA 수정",
                   detail: "goal 생성 시 트리거 · 격리 worktree에서 UI 깨짐 자동 수정·빌드",
                   interval: Self.qaIntervalSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.qaFixDisabledFlag.path))
        // Bug-hunt agent: a LONG-RUNNING (default 4h) hunt for FUNCTIONAL/LOGIC bugs —
        // wrong behavior a user hits (e.g. a 완료 filter that doesn't actually hide 완료
        // items), as opposed to the qa-agent's UI-rendering breakage. Run BY HAND at the
        // end of the day (Scripts/bug-hunt.sh); it reasons over the source for hours, files
        // a goal per confirmed bug, and never fixes. The app only observes it via the same
        // POST /api/worker/ping. Interval here is the round cadence (display-only); the row
        // reads 유휴 outside an active hunt. Toggleable (꺼짐 writes bug-hunt-disabled).
        r.register(id: "bug-hunt", name: "버그 헌트",
                   detail: "퇴근 시 수동 실행 · 최소 4시간 기능·로직 버그 탐색 · goal 문서 자동 생성",
                   interval: Self.bugHuntRoundSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.bugHuntDisabledFlag.path))
        // Claude Desktop's session workers are NOT registered here — they are owned by
        // the plugin and appear/disappear with its connection (see syncPluginWorkers).
        syncPluginWorkers()
    }

    // The QA agent's scan period, read from the same qa-interval-sec file the runner
    // script reads (data dir). Default 600s (10분); floored at 60s. Display-only here —
    // the actual cadence is enforced by qa-scan.sh's interval gate.
    private static func qaIntervalSeconds() -> Double {
        let file = AppPaths.base.appendingPathComponent("qa-interval-sec")
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let v = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 60 else {
            return 600
        }
        return Double(v)
    }

    // The bug-hunt agent's per-round cadence, read from the same bug-hunt-round-sec file
    // the runner reads (data dir). Default 1200s (20분); floored at 300s (5분). Display-only
    // here — the hunt's real pacing is enforced by Scripts/bug-hunt.sh.
    private static func bugHuntRoundSeconds() -> Double {
        let file = AppPaths.base.appendingPathComponent("bug-hunt-round-sec")
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let v = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 300 else {
            return 1200
        }
        return Double(v)
    }

    // Flag files in the data dir that the runner script (qa-scan.sh) shares with the app:
    //   qa-disabled   present  -> the scan is OFF (the 꺼짐 toggle)
    //   qa-force-run  present  -> next base tick runs once now, bypassing the gates
    static var qaDisabledFlag: URL { AppPaths.base.appendingPathComponent("qa-disabled") }
    static var qaFixDisabledFlag: URL { AppPaths.base.appendingPathComponent("qa-fix-disabled") }
    static var qaForceRunFlag: URL { AppPaths.base.appendingPathComponent("qa-force-run") }
    // bug-hunt-disabled present -> the bug-hunt agent is OFF (its 꺼짐 toggle). The runner
    // (Scripts/bug-hunt.sh) refuses to start, and a running hunt stops at the next round.
    static var bugHuntDisabledFlag: URL { AppPaths.base.appendingPathComponent("bug-hunt-disabled") }
    // Latest DOM self-audit pushed by the dashboard ({width, ts, issues:[…]}).
    static var qaAuditFile: URL { AppPaths.base.appendingPathComponent("qa-audit.json") }

    // Best-effort path to the runner script, so "즉시 실행" can spawn it for true
    // immediacy. Derived from the dev data dir (<repo>/.localdata → <repo>/Scripts).
    // Returns nil for an installed app with no sibling repo (run-now falls back to the
    // force-run flag, which the next launchd tick picks up).
    static func qaScriptURL() -> URL? {
        let candidate = AppPaths.base.deletingLastPathComponent()
            .appendingPathComponent("Scripts/qa-scan.sh")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    // Run the QA scan once, immediately, bypassing the interval + change gates. Spawns
    // the script detached (QA_FORCE=1) when reachable; otherwise drops the force-run flag
    // for the next launchd tick. Never blocks — the script reports back via the ping.
    func triggerQARunNow() {
        if let script = Self.qaScriptURL() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            var env = ProcessInfo.processInfo.environment
            env["QA_FORCE"] = "1"
            // qa-scan.sh runs a headless `claude -p` UI-QA worker; suppress its session so it
            // is not mirrored as a dashboard goal (see Scripts/cc-session-hook.sh).
            env["CM_SUPPRESS_SESSION_GOAL"] = "1"
            p.environment = env
            do { try p.run() } catch {
                try? Data().write(to: Self.qaForceRunFlag)   // fall back to the flag
            }
        } else {
            try? Data().write(to: Self.qaForceRunFlag)
        }
    }

    // Worker ids owned by the Claude Desktop plugin (registered on connect, removed on
    // disconnect). Kept in one place so the heartbeat gating and the registry agree.
    private let claudeWorkerIDs = ["session-reconcile", "title-stamp", "claude-sync-check"]

    // Worker ids owned by the 컨디션 메이트 plugin (registered on install, removed on
    // uninstall). The BGM director is the plugin's basic function; mate-tick is the
    // connoisseur layer. mate-discord / mate-suno join in later stages.
    private let mateWorkerIDs = ["director", "mate-tick"]

    // Bring the plugin-owned workers in line with the plugin's connection state. Called
    // at launch and after every plugin connect/disconnect/verify. Connecting Claude
    // Desktop makes its three workers appear in the dashboard and start running;
    // disconnecting removes them (sync pauses, existing goals are left untouched).
    func syncPluginWorkers() {
        let r = WorkerRegistry.shared
        if pluginStore.isConnected("claude-desktop") {
            r.register(id: "session-reconcile", name: "세션 상태 동기화",
                       detail: "트랜스크립트로 세션 진행중·응답 대기 실시간 판정", interval: 1, owner: "claude-desktop")
            r.register(id: "title-stamp", name: "세션 제목 스탬프",
                       detail: "데스크톱 세션 제목에 [seq] 재기입", interval: 30, owner: "claude-desktop")
            r.register(id: "claude-sync-check", name: "프로젝트 활성·싱크 점검",
                       detail: "프로젝트별 활성 강도(5단계) 산출 · 연동 목표 transcript 누락 검사", interval: 30, owner: "claude-desktop")
            pluginStore.refreshClaudeProjects()   // seed the project list before the first 30s tick
        } else {
            claudeWorkerIDs.forEach { r.unregister(id: $0) }
        }

        // 컨디션 메이트: installing the plugin brings BGM online (the director, its basic
        // function) plus the mate decision loop. Uninstalling removes both — BGM goes silent
        // (the heartbeat music gate stops the director when the plugin is not installed).
        if pluginStore.isConnected("condition-mate") {
            r.register(id: "director", name: "BGM 디렉터",
                       detail: "활동률 기반 BGM 템포 결정(세션 활성 시)", interval: 20, owner: "condition-mate")
            r.register(id: "mate-tick", name: "컨디션 메이트",
                       detail: "상황 평가 후 음악 연출(Cue) 산출 — 활성 메이트가 결정", interval: 30, owner: "condition-mate")
        } else {
            mateWorkerIDs.forEach { r.unregister(id: $0) }
        }
    }

    // MARK: - Heartbeat (1 Hz)

    private func onHeartbeat() {
        tick += 1
        WorkerRegistry.shared.recordRun("heartbeat")
        // Reap idle/exited background CLI sessions once a minute.
        if tick % 60 == 0 { cliReapIdle() }
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
            if tick % 5 == 0 { refreshBrowserDomain(bundle); WorkerRegistry.shared.recordRun("browser-domain") }
            if !chromeDomain.isEmpty { minuteSiteSeconds[chromeDomain, default: 0] += 1 }
            // Log only on a real domain change (the 5s poll itself is just a counter).
            if chromeDomain != lastLoggedDomain {
                lastLoggedDomain = chromeDomain
                if !chromeDomain.isEmpty {
                    WorkerLog.shared.append("browser-domain",
                        why: "활성 탭 도메인 변경 감지", effect: "도메인 → \(chromeDomain)")
                }
            }
        } else {
            chromeDomain = ""
        }

        // Human-readable live status for the menu.
        if !isWorking {
            liveStatus = "정지"
        } else if isIdle {
            liveStatus = (Settings.shared.idleAmbientEnabled && appOK)
                ? "자리 비움 · 앰비언트"
                : "자리 비움 · 일시정지"
        } else if !appOK {
            liveStatus = "대기 · 추적 앱이 활성 아님"
        } else {
            liveStatus = "챌린지 중"
        }
        // Log only when the live status actually changes, so the heartbeat log stays
        // readable (one transition line) instead of one row every second.
        if liveStatus != lastLoggedStatus {
            WorkerLog.shared.append("heartbeat",
                why: "세션 평가 (작업=\(isWorking), 추적앱=\(appOK), 유휴=\(isIdle))",
                effect: "'\(lastLoggedStatus.isEmpty ? "시작" : lastLoggedStatus)' → '\(liveStatus)'")
            lastLoggedStatus = liveStatus
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

        // Gate music to the active session — and to the 컨디션 메이트 plugin. BGM is the
        // plugin's basic function, so it only runs while the plugin is installed; uninstalled
        // means no music at all (the director is stopped and stays silent).
        if !pluginStore.isConnected("condition-mate") {
            if director.isRunning { director.stop() }
        } else if s.musicEnabled && inSession && !musicFolderConfigured {
            // Playback would start but no music folder is set: nudge the user
            // (once per session) and offer to jump straight to folder selection.
            promptForMusicFolderIfNeeded()
        } else if s.musicEnabled && !library.tracks.isEmpty {
            // Non-session caused ONLY by idleness (master on, tracked app active):
            // hold slow ambient music instead of silence.
            let idleOnly = isWorking && appOK && isIdle && s.idleAmbientEnabled
            if inSession {
                if !director.isRunning { director.start() }
                else if director.isIdleMode { director.exitIdle() }
                else if !director.isActive { director.resumeSession() }
            } else if idleOnly {
                director.enterIdle()
            } else if director.isPlaying {
                director.pauseSession()
            }
        } else if director.isRunning {
            director.stop()
        }
        // Re-arm the folder prompt once playback is no longer requested, so a
        // later session nudges again.
        if !inSession || !s.musicEnabled { musicFolderPromptShown = false }

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
            sample.bpm = director.isPlaying ? Int(director.targetBPM) : 0
            sample.phase = director.isIdleMode ? "IDLE"
                : (director.isActive ? director.phase.rawValue : "-")
            sample.working = isWorking
            sample.meeting = meeting
            sample.app = domBundle.map { appDisplayName($0) } ?? "-"
            sample.profile = director.isPlaying ? director.activeProfileLabel : "-"
            sample.track = director.isPlaying ? (audio.currentTitle ?? "-") : "-"
            sample.site = domSite.isEmpty ? "-" : domSite
            sample.tier = tier.label
            sample.mult = tier.multiplier
            activityLog.append(sample)
            minuteInput = 0
            minuteAppSeconds.removeAll()
            minuteSiteSeconds.removeAll()
            WorkerRegistry.shared.recordRun("timeline-sample",
                why: "\(sampleInterval)초 주기 분 단위 집계",
                effect: "앱=\(sample.app) · tier=\(sample.tier) · 입력=\(sample.active)초 · BPM=\(sample.bpm)")
        }

        // Claude Desktop integration: session-reconcile, title-stamp, and the sync check
        // only run while the plugin is connected (valid folder). Disconnecting pauses
        // them — existing session goals keep their last status, no transcripts read.
        let claudeOn = pluginStore.isConnected("claude-desktop")
        if claudeOn {
            // Reconcile session goal status from transcripts every heartbeat (cheap stat per
            // goal; full re-parse only on growth) — keeps 진행중 real-time (priority 1).
            reconcileSessionStates(); WorkerRegistry.shared.recordRun("session-reconcile")

            // Policy 3: re-stamp [seq] onto Claude desktop session titles so a human can
            // eyeball-match a desktop session to its goal (file IO, throttled, off-main).
            if tick % 30 == 0 { stampSessionTitles()
                WorkerRegistry.shared.recordRun("title-stamp",
                    why: "30초 주기 세션 제목 동기화", effect: "데스크톱 세션 제목에 [seq] 재기입 점검") }

            // Quality check: every 30s confirm each session-linked goal's transcript is
            // resolvable. Any missing → 데이터 싱크 오류 (red status + error log line).
            if tick % 30 == 0 { runClaudeSyncCheck() }
        }

        // 컨디션 메이트: every 30s, the active mate reads the situation and hands the director
        // its next Cue. Only runs while the plugin is connected; a default cue is a no-op
        // (autonomous control). Aligned to the same 30s cadence as the worker's interval.
        if pluginStore.isConnected("condition-mate") && tick % 30 == 0 {
            runMateTick(isIdle: isIdle)
        }

        // Total span (= 대시보드 토탈 시간) — recompute from samples periodically. The
        // value is minute-grained, so a 10s refresh is plenty and keeps file IO low.
        if tick % 10 == 0 || totalSpanCacheAt == .distantPast { recomputeTotalSpan() }
        // Live status label every second while working; save every 30s.
        // Auto gauge mode (until the user picks one): 8h+ total -> 타임, else 스포츠.
        if !menuBarModeUserSet {
            menuBarMode = totalSpanDisplaySec() >= 8 * 3600 ? .time : .sports
        }
        updateStatusTitle()
        if tick % 30 == 0 { store.saveIfNeeded()
            WorkerRegistry.shared.recordRun("autosave",
                why: "30초 주기 영속화", effect: "누적 시간 변경분 디스크 플러시") }

        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil, tick % 2 == 0 {
            let dirPhase = director.isIdleMode ? "IDLE" : director.phase.rawValue
            let dir = director.isPlaying
                ? " | 전략=\(director.activeProfileLabel) [\(Int(director.activeMinBPM))-\(Int(director.activeMaxBPM))] BGM \(Int(director.targetBPM))BPM \(dirPhase)"
                : ""
            FileHandle.standardError.write(
                "[hb t=\(tick)] front=\(frontBundle ?? "-") dwell=\(frontStableSeconds) committed=\(committedProfileKey)\(dir)\n"
                    .data(using: .utf8)!)
        }
    }

    // Reconcile each session goal's live status from its transcript, real-time first. This
    // is the pull-based truth behind the hooks (push): even if no hook fires, the status
    // tracks real agent activity. Priority ladder (see .doc/waiting-signal-policy.md):
    //   1. transcript touched within activeWindow  -> in_progress  (the real-time "is it
    //      running?" signal; works without the active hook — top priority, surfaced instantly)
    //   2. in_progress but quiet past waitTimeout, or blocked on an AskUserQuestion -> 응답 대기
    //      (the lagging, inferred state — fine if it shows late)
    //   3. a stranded backlog goal (inside the recency window) parked on the human -> 응답 대기
    //   4. done is hook-terminal and is left untouched (not in the guard below)
    // Banking of active time happens in recordSession on each transition.
    // Short, single-line goal label for worker log entries (full titles can be long).
    private func goalLabel(_ goal: ReviewStore.Goal) -> String {
        let t = goal.text.replacingOccurrences(of: "\n", with: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    private func reconcileSessionStates() {
        let now = Date()
        let fm = FileManager.default
        for goal in reviewStore.goals {
            guard !goal.sessionId.isEmpty,
                  goal.status == "in_progress" || goal.status == "waiting" || goal.status == "backlog",
                  let url = resolveTranscript(goal),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let size = (attrs[.size] as? Int) ?? 0
            let stale = now.timeIntervalSince(mtime)

            // PRIORITY 1 — real-time active: a transcript touched within activeWindow means
            // the agent is working right now. Promote immediately, overriding any
            // waiting/backlog inference. Idempotent — recordSession only writes on a real
            // transition, so a session already in_progress costs just this stat.
            if stale <= activeWindow {
                if goal.status != "in_progress" {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "active")
                    WorkerLog.shared.append("session-reconcile",
                        why: "트랜스크립트 \(Int(stale))초 전 갱신(활성 윈도 이내)",
                        effect: "세션 '\(goalLabel(goal))' \(goal.status) → 진행중")
                }
                continue
            }

            // Not fresh. Stranded backlog goals are only reconciled inside the recency
            // window, so an ancient, abandoned session is never resurrected as 응답 대기.
            if goal.status == "backlog" && stale > reconcileWindow { continue }

            // Re-parse the transcript tail only when the file changed (a quiet session
            // stays a cheap stat, no re-read).
            if sessionSeenSize[goal.sessionId] != size {
                sessionSeenSize[goal.sessionId] = size
                let tail = transcriptTail(url)
                sessionPendingAsk[goal.sessionId] = (tail.pending == "AskUserQuestion")
                sessionTurnEnded[goal.sessionId] = (tail.pending == nil && tail.lastRole == "assistant")
            }
            let pendingAsk = sessionPendingAsk[goal.sessionId] ?? false
            let turnEnded  = sessionTurnEnded[goal.sessionId] ?? false

            switch goal.status {
            case "in_progress":
                // Quiet past the timeout, or blocked on the user -> park as 응답 대기 (the
                // waiting window is then excluded from banked active time).
                if pendingAsk || stale >= waitTimeout {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "wait")
                    WorkerLog.shared.append("session-reconcile",
                        why: pendingAsk ? "AskUserQuestion으로 사람 응답 대기"
                                        : "트랜스크립트 \(Int(stale))초 미변경(타임아웃 \(Int(waitTimeout))초)",
                        effect: "세션 '\(goalLabel(goal))' 진행중 → 응답 대기")
                }
            case "backlog":
                // Slice of design B: a goal the old idle→backlog mapping stranded rejoins
                // 응답 대기 when the transcript shows it parked on the human — an open
                // AskUserQuestion, or a finished assistant turn awaiting the next prompt.
                if pendingAsk || turnEnded {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "wait")
                    WorkerLog.shared.append("session-reconcile",
                        why: pendingAsk ? "AskUserQuestion으로 사람 응답 대기" : "턴 종료 후 다음 입력 대기",
                        effect: "세션 '\(goalLabel(goal))' 대기열 → 응답 대기 복원")
                }
            case "waiting":
                // A live session leaves waiting via priority-1 above (its transcript grows
                // again). One that never does — closed by the user, or superseded by a fork
                // under a new session_id — would otherwise sit in 응답 대기 forever, so the
                // count only grows and diverges from Claude Code's recent-session list. Past
                // waitReap of silence, retire it to 취소(cancelled): abandoned, not done, and
                // terminal (it won't bounce back). This is also what converges forks — the
                // orphaned parent goes quiet and is reaped without any prompt matching.
                if stale >= waitReap {
                    reviewStore.setStatus(id: goal.id, status: "cancelled")
                    WorkerLog.shared.append("session-reconcile",
                        why: "응답 대기 \(Int(stale))초 무변경(회수 임계 \(Int(waitReap))초) — 세션 방치/포크로 판단",
                        effect: "세션 '\(goalLabel(goal))' 응답 대기 → 취소")
                }
            default:
                break
            }
        }
    }

    // Quality check for the Claude Desktop plugin (claude-sync-check worker, 30s). For
    // every active session-linked goal, confirm its transcript is resolvable — at the
    // stored path or as <connectedFolder>/<sessionId>.jsonl. Any goal whose transcript
    // is missing is a 데이터 싱크 오류: the folder moved, the session file was deleted, or
    // the goal points at a session that isn't in the connected folder. Missing ones are
    // logged as an error (red 상태); a clean pass clears the flag.
    private func runClaudeSyncCheck() {
        let fm = FileManager.default
        let folder = pluginStore.connectedFolder("claude-desktop")
        let root = PluginStore.claudeProjectsRoot(folder)

        // Refresh per-project activity (5-level intensity) for the dashboard, then log a
        // concise summary so the worker timeline shows what's active right now.
        pluginStore.refreshClaudeProjects()
        let projects = pluginStore.claudeProjects
        let active = projects.filter { $0.inUse }                 // level 5 (≤5분)
        let recent = projects.filter { $0.level >= 1 }            // within a week
        let topName = projects.first.map { "\($0.name)(\(Formatting.agoLabel($0.lastActiveSec)))" } ?? "-"

        // Quality: every active session-linked goal's transcript must be resolvable in the
        // connected root (or at its stored path). Missing ones are a 데이터 싱크 오류.
        let live = reviewStore.goals.filter {
            !$0.sessionId.isEmpty &&
            ($0.status == "in_progress" || $0.status == "waiting" || $0.status == "backlog")
        }
        var missing: [ReviewStore.Goal] = []
        for goal in live {
            let stored = !goal.transcriptPath.isEmpty && fm.fileExists(atPath: goal.transcriptPath)
            let inRoot = root.map { transcriptExists(sessionId: goal.sessionId, under: $0) } ?? false
            if !stored && !inRoot { missing.append(goal) }
        }
        let activitySummary = "활성 \(active.count)개 · 최근(주간) \(recent.count)개 · 최다활성 \(topName)"
        if missing.isEmpty {
            WorkerRegistry.shared.recordRun("claude-sync-check",
                why: "프로젝트 \(projects.count)개 활성 점검 · 연동 목표 \(live.count)개 transcript 검사",
                effect: "정상 — \(activitySummary) · transcript 누락 0")
            WorkerRegistry.shared.clearError("claude-sync-check")
        } else {
            let labels = missing.prefix(5).map { "#\($0.seq) \(goalLabel($0))" }.joined(separator: ", ")
            let more = missing.count > 5 ? " 외 \(missing.count - 5)건" : ""
            WorkerRegistry.shared.recordError("claude-sync-check",
                why: "연동 목표 \(live.count)개 중 transcript 누락 · \(activitySummary)",
                detail: "데이터 싱크 오류 — transcript 없음: \(labels)\(more)")
        }
    }

    // 컨디션 메이트 decision loop (mate-tick, 30s). Assemble the observation context, ask the
    // active mate for its next Cue, and pass it to the director. The mate is the optional
    // comrade above the executor; the director stays the executor. Stage 1 mates return a
    // default cue (no-op), so this exercises the full seam without changing playback yet.
    private func runMateTick(isIdle: Bool) {
        let ctx = MateContext(
            date: Date(),
            activityRate: activity.activityRate,
            isIdle: isIdle,
            frontAppLabel: activeAppLabel,
            phase: director.isIdleMode ? "IDLE"
                : (director.isActive ? director.phase.rawValue : "-"),
            targetBPM: director.targetBPM,
            profileLabel: director.activeProfileLabel,
            libMinBPM: library.bpmRange?.min,
            libMaxBPM: library.bpmRange?.max
        )
        let mate = MateRegistry.shared.current
        let cue = mate.decide(context: ctx)
        director.apply(cue: cue)
        WorkerRegistry.shared.recordRun("mate-tick",
            why: "30초 주기 상황 평가 (\(mate.name))",
            effect: cue.summary)
    }

    // Is <root>/<anyProject>/<sessionId>.jsonl present? (also accepts a transcript sitting
    // directly in root, the single-project-folder case). Bounded one level deep.
    private func transcriptExists(sessionId: String, under root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(sessionId + ".jsonl").path) { return true }
        let children = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if fm.fileExists(atPath: dir.appendingPathComponent(sessionId + ".jsonl").path) { return true }
        }
        return false
    }

    // Policy 3 (.doc/session-lifecycle-policy.md): keep every session-linked goal's [seq]
    // stamped on the matching Claude desktop session title, so the two can be matched by
    // eye and the user can manually archive (desktop) / complete (web). reviewStore is
    // main-thread owned; we snapshot the (sessionId -> seq) map here, then SessionTitleStamper
    // does the directory scan + writes off-main.
    private func stampSessionTitles() {
        // Never mutate the real Claude store during dev/throwaway runs (CM_DATA_DIR set)
        // unless an explicit sessions-dir override points the stamper somewhere safe.
        if AppPaths.isCustom,
           ProcessInfo.processInfo.environment["CM_CLAUDE_SESSIONS_DIR"] == nil { return }
        var map: [String: Int] = [:]
        for g in reviewStore.goals where !g.sessionId.isEmpty { map[g.sessionId] = g.seq }
        SessionTitleStamper.stamp(seqBySession: map)
    }

    // Parse the transcript and report its tail state: the name of the last still-open
    // tool_use (nil once answered) and the role of the last user/assistant message. Walks
    // lines in order, tracking the most recent unanswered tool_use. A nil `pending` with
    // `lastRole == "assistant"` means the agent finished a turn and awaits the human.
    private func transcriptTail(_ url: URL) -> (pending: String?, lastRole: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        var pending: String? = nil   // name of an open tool_use, nil = all answered
        var lastRole: String? = nil
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            lastRole = type
            for b in content {
                switch b["type"] as? String ?? "" {
                case "tool_use":    pending = b["name"] as? String
                case "tool_result": pending = nil
                default:            break
                }
            }
        }
        return (pending, lastRole)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        // The lightning bolt (button image) IS the condition indicator now — it
        // charges bottom-up across five stages from the live 활동/최고치 비율. Cheap
        // to call every refresh; it only swaps the image when the stage changes.
        gauge.update(norm: activity.conditionNorm, working: isWorking)
        // 스포츠 모드: while working, show the 1-minute average APM — a realistic
        // sustained pace rather than the twitchy instant value, so the digit no
        // longer jumps up and down every second. The dashboard gauge still tweens
        // the live instant APM for in-the-moment focus and fun. Idle has no APM, so
        // it falls through to the clock below.
        if menuBarMode == .sports && isWorking {
            // Glide the displayed value toward the (already smooth) 1-min average.
            // Asymmetric envelope keeps a brief rise snappy while the descent stays
            // smooth; snap when essentially there so the digit settles instead of
            // crawling the last fraction.
            let target = activity.averageAPM
            let alpha = target >= displayedAPM ? 0.45 : 0.20
            displayedAPM += (target - displayedAPM) * alpha
            if abs(target - displayedAPM) < 0.5 { displayedAPM = target }
            // Pad to 4 figure-spaces (U+2007, digit-width) so the title width is fixed —
            // APM never exceeds 4 digits, so it stops growing and never jiggles.
            let s = String(Int(displayedAPM.rounded()))
            let pad = String(repeating: "\u{2007}", count: max(0, 4 - s.count))
            // No ⚡ glyph here — the bolt now lives in the button image (the gauge).
            // A leading space keeps a small gap between the bolt and the number.
            button.title = " " + pad + s
            return
        }
        // 타임 모드 (and 스포츠 while idle): the 토탈 시간 work span — the exact same
        // number the dashboard "토탈 시간" card shows (휴식·미팅 포함, 8h+ 공백 제외),
        // e.g. 6:38. The total amount (총량) of the day, not a since-start session clock.
        button.title = " " + Formatting.clock(totalSpanDisplaySec())
    }


    // Recompute the 토탈 시간 work span from today's per-minute samples — mirrors the
    // dashboard timeBuckets() total: anchors are minutes with input or a meeting; the
    // span sums consecutive-anchor gaps under 8h (an 8h+ gap is 퇴근, excluded). Inferred
    // carry-forward minutes never change this telescoped sum, so we skip that pass.
    private func recomputeTotalSpan() {
        let samples = activityLog.todaySamplesParsed()
        var anchors: [Int] = []
        for s in samples {
            let active = (s["active"] as? NSNumber)?.intValue ?? 0
            let meeting = (s["meeting"] as? Bool) ?? false
            if active > 0 || meeting, let t = (s["t"] as? NSNumber)?.intValue { anchors.append(t) }
        }
        anchors.sort()
        var base = 0.0
        if let first = anchors.first {
            base = 60                          // the first anchored minute owns its 60s
            let offGap = 8 * 3600
            for i in 1..<anchors.count {
                let gap = anchors[i] - anchors[i - 1]
                if gap < offGap { base += Double(gap) }
            }
            lastAnchorT = anchors.last ?? first
        } else {
            lastAnchorT = 0
        }
        totalSpanBaseSec = base
        totalSpanCacheAt = Date()
    }

    // Flip the menu-bar gauge between 스포츠(APM) and 타임(clock). Marks the choice as
    // user-set so the 8h auto-default stops overriding it.
    func toggleMenuBarMode() {
        menuBarMode = (menuBarMode == .sports) ? .time : .sports
        menuBarModeUserSet = true
        updateStatusTitle()
    }

    // MARK: - Manual Start/Stop Working

    func startWorking(mode: String? = nil) {
        // Remember the rail's chosen session mode (pomodoro/sprint/unlimited) even
        // when the session is already live: picking a mode during the launch
        // countdown must still switch the auto-started session's BGM playlist.
        if let mode = mode { director.setSessionMode(mode) }
        guard !isWorking else { return }
        // Each session opens on its mode's pinned first track (per-mode playlist).
        director.armModeOpener()
        session.setRunning(true)
        sessionSeconds = 0
        committedProfileKey = ""
        frontStableSeconds = 0
        activeAppLabel = ""
        // The gauge follows the live condition on the heartbeat; updateStatusTitle
        // below refreshes it immediately so the bolt lights up on session start.
        updateStatusTitle()
    }

    func stopWorking() {
        guard isWorking else { return }
        session.setRunning(false)
        committedProfileKey = ""
        activeAppLabel = ""
        director.pauseSession()
        store.saveIfNeeded()
        gauge.showIdle()
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

    // App-wide shortcut handler (see the local monitor in applicationDidFinishLaunching). Fires only
    // while the app is active, on any window/page. Match Command exactly (no extra modifiers) so we
    // don't hijack ⌘⇧M / ⌥⌘S etc. Returns nil to swallow the event, or the event to let it pass.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return event }
        // Match the physical key (keyCode), not the typed character: with a Korean input source
        // active, charactersIgnoringModifiers is "ㅡ"/"ㄴ" rather than "m"/"s", so a character
        // match falls through and the unhandled ⌘-key beeps.
        switch event.keyCode {
        case 46: toggleMute();    return nil  // kVK_ANSI_M
        case 1:  toggleWorking(); return nil  // kVK_ANSI_S
        default: return event
        }
    }

    // Mute/unmute the sound the user actually hears. `session.isMuted` is the single source of truth;
    // this flips it and syncs the two audio sources. While the app window is open the BGM webview
    // owns output (native stays force-muted — see windowOwnsAudio), so push the new state into the
    // webview's own mute control for instant feedback; the /api/bgm/now poll (which now carries
    // `muted`) reconciles the web as a backstop. When the window is closed the native AudioEngine is
    // the source, handled by applyNativeMute.
    func toggleMute() {
        session.toggleMuted()
        applyMuteToSurfaces()
        AppLog.log("⌘M mute -> \(session.isMuted) (windowOpen=\(appWindow.isOpen) nativeMuted=\(audio.muted))")
    }

    // The one place that writes audio.muted for the mute axis. Native output reflects the user's
    // mute intent, but stays force-muted while the app window owns audio (windowOwnsAudio) so the
    // native player and the BGM webview never both make sound.
    func applyNativeMute() { audio.muted = windowOwnsAudio || session.isMuted }

    // Push the current mute state to every audio surface: the BGM webview (what the user actually
    // hears while the window is open) and the native player. window.__setMute is idempotent, so
    // echoing it back to a webview that already flipped its own control is a harmless no-op — which
    // lets every surface (⌘M, the rail mute dot, the BGM player button) route through this one path.
    private func applyMuteToSurfaces() {
        if appWindow.isOpen { appWindow.setWebMute(session.isMuted) }
        applyNativeMute()
    }

    // Remote mute control from any page (POST /api/session/mute): set the source of truth and sync
    // all surfaces. Safe to call from the BGM webview itself — the echo back is a no-op (see above).
    func setMutedRemote(_ muted: Bool) {
        session.setMuted(muted)
        applyMuteToSurfaces()
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
                "[ConditionManager] loaded \(library.tracks.count) tracks (\(library.skippedCount) no-BPM defaulted)\(range)\n"
                    .data(using: .utf8)!
            )
            for t in library.tracks {
                FileHandle.standardError.write("  \(Int(t.bpm)) BPM  \(t.title)\n".data(using: .utf8)!)
            }
        }
    }

    // Whether a music source is configured: an explicit saved folder, or the
    // CM_SCAN_DIR test override. Mirrors reloadLibrary()'s path resolution.
    private var musicFolderConfigured: Bool {
        if ProcessInfo.processInfo.environment["CM_SCAN_DIR"] != nil { return true }
        if let path = Settings.shared.musicFolderPath, !path.isEmpty { return true }
        return false
    }

    // Ask the user to set a music folder when a session wants to play but none
    // is configured. Shown at most once per session (musicFolderPromptShown).
    // "예" jumps straight to the folder picker.
    private func promptForMusicFolderIfNeeded() {
        guard !musicFolderPromptShown else { return }
        musicFolderPromptShown = true

        let alert = NSAlert()
        alert.messageText = "음악 폴더 설정이 안되어 있습니다"
        alert.informativeText = "BGM을 재생하려면 음원 폴더가 필요합니다. 폴더 설정을 지금 할까요?"
        alert.addButton(withTitle: "예")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "아니오")  // .alertSecondButtonReturn
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            chooseMusicFolder()
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

    // Explicit on/off for the BGM system, used by the dashboard BGM view's remote control
    // (POST /api/bgm/control). Mirrors toggleMusic so the menu-bar widget and the dashboard
    // stay in sync. Enabling lets the heartbeat gating start the director on its next tick;
    // disabling stops it immediately (and unmutes, since the browser no longer owns output).
    func setBGMEnabled(_ on: Bool) {
        guard Settings.shared.musicEnabled != on else { return }
        Settings.shared.musicEnabled = on
        if !on { director.stop(); applyNativeMute() }
    }

    // Explicit "I don't like this track" from the menu: down-weight + cooldown +
    // immediate switch (handled by the director), plus a context snapshot to the
    // event log so the algorithm can later learn *when* it was disliked.
    func dislikeCurrentTrack() {
        guard director.isPlaying, let info = director.dislikeCurrentTrack() else { return }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let cal = Calendar.current
        var c = TrackEventLog.Context()
        c.signal = "dislike"
        c.trackKey = info.key
        c.title = info.title
        c.trackBPM = Int(info.bpm)
        c.targetBPM = Int(director.targetBPM)
        c.phase = director.phase.rawValue
        c.profile = director.activeProfileLabel
        c.app = activeAppLabel.isEmpty ? "-" : activeAppLabel
        c.site = chromeDomain.isEmpty ? "-" : chromeDomain
        c.norm = director.lastNorm
        c.rate = Int(activity.activityRate)
        c.sessionSeconds = Int(sessionSeconds)
        c.todaySeconds = Int(store.todaySeconds)
        c.totalSeconds = Int(store.data.totalSeconds)
        c.hour = cal.component(.hour, from: Date())
        c.weekday = cal.component(.weekday, from: Date())
        c.meeting = ValueTier.isMeeting(bundleID: frontBundle, site: chromeDomain)
        trackEvents.append(c)
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

    // Open (and focus) the native app window on the dashboard — no browser. The in-window toggle
    // can switch to BGM from here.
    func openDashboard() {
        dashboard.start { [weak self] port in
            DispatchQueue.main.async { self?.appWindow.show(port: port, mode: .dashboard) }
        }
    }

    // Open (and focus) the native app window in BGM mode — the guaranteed-autoplay surface. Opening
    // BGM is an explicit "I want BGM" action, so it turns the BGM system on (symmetric with close=off).
    func openBGMWindow() {
        setBGMEnabled(true)
        dashboard.start { [weak self] port in
            DispatchQueue.main.async { self?.appWindow.show(port: port, mode: .bgm) }
        }
    }

    // Toggle whether the app window auto-opens (in BGM mode) on launch; turning it on opens it now.
    func toggleBGMWindowAutoOpen() {
        let on = !Settings.shared.bgmWindowEnabled
        Settings.shared.bgmWindowEnabled = on
        if on { openBGMWindow() }
    }

    // MARK: - Unified window-toggle menu entry (single item, replaces the old two "열기" entries)

    // Read-only state for the menu label: is the window open, and which mode is it showing.
    // Mirrors the in-window segmented toggle exactly — same appWindow, same `mode`.
    var appWindowIsOpen: Bool { appWindow.isOpen }
    var appWindowMode: AppWindowController.Mode { appWindow.mode }
    // Test-only: see AppWindowController.testUserClose and the /api/debug/window-close handler.
    func appWindowTestClose() { appWindow.testUserClose() }

    // Test-only (SPEC.html screenshots): synchronously fetch a PNG snapshot of the app window's
    // WKWebView, blocking the calling (server) thread with a semaphore since HTTP GET handlers here
    // are synchronous while WKWebView.takeSnapshot is completion-based. See /api/debug/snapshot.
    func appWindowSnapshotPNG(mode: AppWindowController.Mode, tab: String?) -> Data? {
        let sema = DispatchSemaphore(value: 0)
        var result: Data?
        DispatchQueue.main.async {
            self.appWindow.snapshotPNG(mode: mode, tab: tab) { png in
                result = png
                sema.signal()
            }
        }
        _ = sema.wait(timeout: .now() + 5)
        return result
    }

    // Single toggle action for the unified menu entry:
    //  - window closed -> open it (in whatever mode it last showed, i.e. appWindow.mode default)
    //  - window open   -> switch ITS mode (same window, same toggle the in-window segmented
    //    control drives), so the menu entry and the in-window toggle always agree.
    func toggleAppWindowMode() {
        if appWindow.isOpen {
            let next: AppWindowController.Mode = (appWindow.mode == .bgm) ? .dashboard : .bgm
            if next == .bgm { openBGMWindow() } else { openDashboard() }
        } else {
            if appWindow.mode == .bgm { openBGMWindow() } else { openDashboard() }
        }
    }

    // MARK: - Session transcripts (connect + readable view)

    // ~/.claude/projects — where Claude Code stores per-project session transcripts.
    private var claudeProjectsBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // Best guess at the "current" Claude session folder: the project subdirectory that
    // holds the most recently modified .jsonl. Used as the picker's default location so
    // the user lands on the active project. Falls back to the base, then home.
    private func currentClaudeSessionDir() -> URL {
        let fm = FileManager.default
        let base = claudeProjectsBase
        let fallback = fm.fileExists(atPath: base.path) ? base : fm.homeDirectoryForCurrentUser
        guard let subs = try? fm.contentsOfDirectory(at: base,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return fallback }
        var best: (dir: URL, when: Date)?
        for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if best == nil || m > best!.when { best = (dir, m) }
            }
        }
        return best?.dir ?? fallback
    }

    // Resolve a goal's transcript file: prefer the stored path, else locate
    // <sessionId>.jsonl somewhere under ~/.claude/projects.
    private func resolveTranscript(_ goal: ReviewStore.Goal) -> URL? {
        let fm = FileManager.default
        if !goal.transcriptPath.isEmpty, fm.fileExists(atPath: goal.transcriptPath) {
            return URL(fileURLWithPath: goal.transcriptPath)
        }
        guard !goal.sessionId.isEmpty,
              let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        for dir in subs {
            let cand = dir.appendingPathComponent(goal.sessionId + ".jsonl")
            if fm.fileExists(atPath: cand.path) { return cand }
        }
        return nil
    }

    // Append a "goal-title-override" record to a session goal's transcript. The
    // session hook (cc-session-hook.sh) prefers the last such record over Claude's
    // aiTitle, so a manual rename sticks across future session events. Best-effort:
    // does nothing if the transcript can't be located or opened.
    private func writeTitleOverride(for goal: ReviewStore.Goal, title: String) {
        guard let url = resolveTranscript(goal),
              let data = "{\"type\":\"goal-title-override\",\"title\":\(jsonString(title))}\n".data(using: .utf8),
              let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        // Ensure our record starts on its own line (transcripts are line-delimited JSON).
        let end = fh.seekToEndOfFile()
        if end > 0 {
            fh.seek(toFileOffset: end - 1)
            if fh.readDataToEndOfFile() != Data([0x0a]) { fh.seekToEndOfFile(); fh.write(Data([0x0a])) }
        }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    // Open a native file picker for the user to attach a transcript to a goal. Runs on
    // the main thread (modal). The session id is the file's base name, since Claude
    // names transcripts <sessionId>.jsonl.
    private func connectSessionViaPicker(goalId: String) {
        let panel = NSOpenPanel()
        panel.title = "세션 트랜스크립트 연결"
        panel.message = "이 목표에 연결할 Claude 세션 파일(.jsonl)을 선택하세요"
        panel.prompt = "연결"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentClaudeSessionDir()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sid = url.deletingPathExtension().lastPathComponent
        reviewStore.connectSession(goalId: goalId, sessionId: sid, transcriptPath: url.path)
    }

    // Open a native folder picker to connect a plugin to a project folder. Runs on the
    // main thread (modal). The chosen folder is verified by PluginStore; an arbitrary
    // folder (no Claude transcript inside) is recorded as 잘못된 연결, not silently OK.
    private func connectPluginViaPicker(pluginId: String) {
        let panel = NSOpenPanel()
        panel.title = "플러그인 폴더 연결"
        panel.prompt = "연결"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Folder-based plugins only (toggle plugins install without a picker).
        panel.message = "Claude 루트 폴더 ~/.claude 를 선택하세요 (모든 프로젝트 세션을 연동)"
        // Default to ~/.claude so the user lands on the root (all projects), not one project.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pluginStore.connect(pluginId: pluginId, folderPath: url.path)
        pluginStore.refreshClaudeProjects()   // populate the project list right away
        syncPluginWorkers()                    // connecting activates the plugin's workers
    }

    // GET /transcript?goal=<id> -> a readable HTML rendering of the goal's transcript.
    // Returns nil (404) only when the goal id is unknown; a connected-but-missing file
    // still yields a page that explains the problem.
    func transcriptPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path) else { return nil }
        // A bare ?session=<id> view: any session linked to a goal (not just the goal's
        // primary one) can open its transcript. Resolve the .jsonl directly by id.
        if let sid = comps.queryItems?.first(where: { $0.name == "session" })?.value, !sid.isEmpty {
            guard let url = transcriptURL(forSessionId: sid) else {
                return transcriptHTML(title: "세션 \(String(sid.prefix(8)))",
                    body: "<p class=\"empty\">이 세션의 트랜스크립트 파일을 찾을 수 없습니다.</p>")
            }
            let title = transcriptTitle(url)
            return transcriptHTML(title: title.isEmpty ? "세션 \(String(sid.prefix(8)))" : title,
                                  body: renderTranscriptBody(url))
        }
        guard let id = comps.queryItems?.first(where: { $0.name == "goal" })?.value else { return nil }
        // reviewStore is main-thread owned; copy out the (value-type) goal under main.
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.id == id } }
        guard let goal = goalOpt else { return nil }
        guard let url = resolveTranscript(goal) else {
            let where_ = goal.transcriptPath.isEmpty ? "(경로 미지정)" : goal.transcriptPath
            return transcriptHTML(title: goal.text,
                body: "<p class=\"empty\">연결된 트랜스크립트 파일을 찾을 수 없습니다.<br>\(htmlEscape(where_))</p>")
        }
        return transcriptHTML(title: goal.text, body: renderTranscriptBody(url))
    }

    private func renderTranscriptBody(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "<p class=\"empty\">파일을 읽을 수 없습니다.</p>"
        }
        var out = ""
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let html = self.renderTranscriptLine(obj) else { return }
            out += html
        }
        return out.isEmpty ? "<p class=\"empty\">표시할 메시지가 없습니다.</p>" : out
    }

    // Like renderTranscriptBody but only the last `limit` conversational bubbles — the
    // "현재 내용"(latest progress) view on the goal page wants what the session is doing
    // now, not the whole history.
    private func renderTranscriptTail(_ url: URL, limit: Int) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "<p class=\"empty\">파일을 읽을 수 없습니다.</p>"
        }
        var bubbles: [String] = []
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let html = self.renderTranscriptLine(obj) else { return }
            bubbles.append(html)
        }
        if bubbles.isEmpty { return "<p class=\"empty\">표시할 메시지가 없습니다.</p>" }
        return bubbles.suffix(limit).joined()
    }

    // One transcript line -> a message bubble, or nil for non-conversational records
    // (queue-operation, mode, ai-title, last-prompt, system, …).
    private func renderTranscriptLine(_ obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""
        guard type == "user" || type == "assistant",
              let msg = obj["message"] as? [String: Any] else { return nil }
        let role = (msg["role"] as? String) ?? type
        let blocks = transcriptBlocksHTML(msg["content"])
        if blocks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let who = role == "user" ? "사용자" : "어시스턴트"
        return "<div class=\"msg \(role)\"><div class=\"who\">\(htmlEscape(who))</div><div class=\"body\">\(blocks)</div></div>"
    }

    private func transcriptBlocksHTML(_ content: Any?) -> String {
        if let s = content as? String { return "<div class=\"text\">\(htmlEscape(s))</div>" }
        guard let arr = content as? [[String: Any]] else { return "" }
        var out = ""
        for b in arr {
            switch b["type"] as? String ?? "" {
            case "text":
                if let s = b["text"] as? String { out += "<div class=\"text\">\(htmlEscape(s))</div>" }
            case "thinking":
                if let s = b["thinking"] as? String {
                    out += "<details class=\"think\"><summary>thinking</summary><pre>\(htmlEscape(s))</pre></details>"
                }
            case "tool_use":
                let name = b["name"] as? String ?? "tool"
                out += "<details class=\"tool\"><summary>🔧 \(htmlEscape(name))</summary><pre>\(htmlEscape(truncateText(prettyJSON(b["input"]), 2000)))</pre></details>"
            case "tool_result":
                out += "<details class=\"result\"><summary>↳ 결과</summary><pre>\(htmlEscape(truncateText(toolResultText(b["content"]), 2000)))</pre></details>"
            default:
                break
            }
        }
        return out
    }

    private func prettyJSON(_ v: Any?) -> String {
        guard let v = v else { return "" }
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            return String(decoding: d, as: UTF8.self)
        }
        return String(describing: v)
    }
    private func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined(separator: "\n")
        }
        return prettyJSON(content)
    }
    private func truncateText(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n… (\(s.count - n)자 생략)"
    }
    // GET /worker?id=<workerId> -> a readable run log for one background worker:
    // when it fired, why (the trigger/condition), and what changed. Backed by the
    // per-worker JSONL written by WorkerLog (size-capped; oldest lines trimmed).
    func workerLogPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        guard let info = WorkerRegistry.shared.info(id) else {
            return workerLogHTML(title: "알 수 없는 워커", subtitle: htmlEscape(id),
                body: "<p class=\"empty\">등록되지 않은 워커입니다.</p>")
        }
        let entries = WorkerLog.shared.recent(id, limit: 500)
        let s = Int(info.interval.rounded())
        let intervalLabel = (s >= 60 && s % 60 == 0) ? "\(s / 60)분" : "\(s)초"
        let subtitle = "\(htmlEscape(info.detail)) · 주기 \(intervalLabel) · 최근 \(entries.count)건 (오래된 항목은 자동 정리)"
        if entries.isEmpty {
            return workerLogHTML(title: info.name, subtitle: subtitle,
                body: "<p class=\"empty\">아직 기록된 실행이 없습니다.</p>")
        }
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "MM-dd HH:mm:ss"
        var rows = ""
        for e in entries {
            let when = tf.string(from: Date(timeIntervalSince1970: Double(e.t) / 1000))
            let cls = e.level == "error" ? " style=\"color:#e2667d\"" : ""
            let tag = e.level == "error" ? "⚠ " : ""
            rows += "<tr\(cls)><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"why\">\(tag)\(htmlEscape(e.why))</td>"
                + "<td class=\"eff\">\(htmlEscape(e.effect))</td></tr>"
        }
        let body = """
        <table>
          <thead><tr><th>시각</th><th>왜 실행했나 (실행 조건)</th><th>무엇이 바뀌었나 (영향)</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return workerLogHTML(title: info.name, subtitle: subtitle, body: body)
    }

    // GET /worker-log -> every worker's run log merged into one chronological
    // timeline (newest first), so the whole background is readable at a glance.
    // Each worker keeps a stable color so rows are easy to scan by source.
    func workerLogAllPage(_ path: String) -> String? {
        let workers = WorkerRegistry.shared.allWorkers()
        let palette = ["#5b8cff", "#36c08a", "#e2667d", "#e0a23a", "#9b7bff",
                       "#21c7b8", "#ff8a5b", "#7d8aff", "#c08adf"]
        var colorById: [String: String] = [:]
        var nameById: [String: String] = [:]
        for (i, w) in workers.enumerated() {
            colorById[w.id] = palette[i % palette.count]
            nameById[w.id] = w.name
        }
        var merged: [(t: Int, id: String, why: String, effect: String, level: String)] = []
        for w in workers {
            for e in WorkerLog.shared.recent(w.id, limit: 300) {
                merged.append((e.t, w.id, e.why, e.effect, e.level))
            }
        }
        merged.sort { $0.t > $1.t }
        if merged.count > 1000 { merged = Array(merged.prefix(1000)) }
        let subtitle = "전체 워커 통합 타임라인 · 최근 \(merged.count)건 (워커당 최대 300건, 오래된 항목은 자동 정리)"
        if merged.isEmpty {
            return workerLogHTML(title: "워커 통합 로그", subtitle: subtitle,
                body: "<p class=\"empty\">아직 기록된 실행이 없습니다.</p>")
        }
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "MM-dd HH:mm:ss"
        var rows = ""
        for e in merged {
            let when = tf.string(from: Date(timeIntervalSince1970: Double(e.t) / 1000))
            let color = colorById[e.id] ?? "#8a93a3"
            let name = nameById[e.id] ?? e.id
            let dot = "<span style=\"display:inline-block;width:8px;height:8px;border-radius:50%;"
                + "margin-right:6px;vertical-align:middle;background:\(color)\"></span>"
            let rowStyle = e.level == "error" ? " style=\"color:#e2667d\"" : ""
            let tag = e.level == "error" ? "⚠ " : ""
            rows += "<tr\(rowStyle)><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"wk\" style=\"white-space:nowrap\">\(dot)\(htmlEscape(name))</td>"
                + "<td class=\"why\">\(tag)\(htmlEscape(e.why))</td>"
                + "<td class=\"eff\">\(htmlEscape(e.effect))</td></tr>"
        }
        let body = """
        <table>
          <thead><tr><th>시각</th><th>워커</th><th>왜 실행했나 (실행 조건)</th><th>무엇이 바뀌었나 (영향)</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return workerLogHTML(title: "워커 통합 로그", subtitle: subtitle, body: body)
    }

    private func workerLogHTML(title: String, subtitle: String, body: String) -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title)) · 워커 로그</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          header a{color:var(--accent);text-decoration:none;font-size:12px}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          table{width:100%;border-collapse:collapse}
          th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
          th{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase;position:sticky;top:52px;background:var(--bg)}
          td.t{color:var(--mut);font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
          td.why{color:#cfd6e2}
          td.eff{color:#9fe0a0}
          tbody tr:hover{background:var(--panel)}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
        </style></head>
        <body>
          <header><a href="/">← 대시보드</a><h1>\(htmlEscape(title))</h1><div class="sub">\(subtitle)</div></header>
          <main>\(body)</main>
        </body></html>
        """
    }

    // GET /workers.json — the worker snapshot ONLY, so the standalone 크론(/cron) page can poll
    // cheaply without pulling the heavy /data.json review payload. Main-thread read: the registry
    // is mutated on main (heartbeat recordRun/Error), matching sessionStateJSON's pattern.
    func workersJSON() -> String {
        DispatchQueue.main.sync { "{\"workers\":\(WorkerRegistry.shared.snapshotJSON())}" }
    }

    // GET /cron — the 크론(주기 작업) surface as its OWN page, decoupled from the dashboard's view
    // system. It embeds the shared session rail (so navigation/challenge dial stay consistent) and
    // renders the worker status table from /workers.json on its own 5s poll. Nothing here depends on
    // DashboardContent; the rail's cmNav routes 크론 here via location.href.
    func cronPage() -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>크론 · 주기 작업</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;z-index:30;display:flex;align-items:center;justify-content:space-between;gap:12px;
            background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          header a{color:var(--accent);text-decoration:none;font-size:12px}
          main{max-width:1080px;margin:0 auto;padding:18px 20px 80px}
          .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
          /* narrow window → horizontal scroll instead of squeezing cells until Korean breaks per-glyph */
          .tablewrap{overflow-x:auto}
          table{width:100%;min-width:980px;border-collapse:collapse}
          th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;white-space:nowrap}
          th{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase}
          /* 하는 일: the only column allowed to wrap (at word boundaries), so the table stays sane */
          td:nth-child(3){white-space:normal;word-break:keep-all;min-width:280px}
          tbody tr:hover{background:#171c26}
          .muted{color:var(--mut)}
          .empty{color:var(--mut);text-align:center;padding:24px 0}
          .chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;margin:2px 4px 2px 0;background:#1d2230;border:1px solid var(--line);white-space:nowrap}
          .chip.bad{background:#2a1620;border-color:#5a2738;color:#ff9db0}
          .btn{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:6px 12px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-block;white-space:nowrap}
          .btn:hover{background:#242b3b}
          .btn:disabled{opacity:.5;cursor:default}
          .legend{color:var(--mut);font-size:12px;margin-top:10px;display:flex;gap:18px;flex-wrap:wrap}
          .foot{color:var(--mut);font-size:11px;text-align:center;margin-top:18px}
        </style></head>
        <body>
          <script>window.CM_PAGE='cron';</script>
          \(SessionRail.html())
          <header>
            <div><h1>크론 · 주기 작업</h1><div class="sub">주기적으로 실행해야 하는 백그라운드 작업(워커)을 등록·관리합니다</div></div>
            <a class="btn" href="/worker-log" target="_blank">전체 로그 타임라인</a>
          </header>
          <main>
            <div class="panel">
              <div class="tablewrap">
              <table>
                <thead><tr><th>워커</th><th>구분</th><th>하는 일</th><th>주기</th><th>마지막 실행</th><th>다음 실행</th><th>실행</th><th>상태</th><th>로그</th></tr></thead>
                <tbody id="workerrows"><tr><td colspan="9" class="empty">불러오는 중…</td></tr></tbody>
              </table>
              </div>
              <div class="legend"><span><span class="chip" style="margin:0">동작 중</span> = 일정대로 실행 중 · <span class="chip bad" style="margin:0">유휴</span> = 현재 멈춤(세션 비활성 등) · <span class="chip bad" style="margin:0">오류</span> = 데이터 싱크 이상(로그 확인) · <b>구분</b> 기본=항상 실행, 플러그인=연결 시에만, 자동화=외부 스케줄러(launchd)가 주기 실행, 수동=퇴근 시 손으로 실행(주기 칸은 1회 실행 중 라운드 간격)</span></div>
            </div>
            <div class="foot">127.0.0.1 로컬 전용</div>
          </main>
          <script>
          function esc(s){ return (s||'-').replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];}); }
          function post(p,b){ return fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}); }
          function fmtInterval(s){ if(s>=60&&s%60===0) return (s/60)+'분'; return s+'초'; }
          function fmtAgo(sec){ if(sec<0) return '아직 없음';
            if(sec<60) return sec+'초 전'; var m=(sec/60)|0,s=sec%60; return m+'분 '+(s>0?s+'초 ':'')+'전'; }
          var _workers=[], _workersBase=0;
          function renderWorkers(arr){
            _workers=Array.isArray(arr)?arr:[];
            _workersBase=performance.now();
            var rows=document.getElementById('workerrows');
            if(!_workers.length){ rows.innerHTML='<tr><td colspan="9" class="empty">데이터 없음</td></tr>'; return; }
            var ownerLabel=function(o,manual){
              if(manual) return '<span class="chip" style="margin:0;background:#7a8699;color:#fff" title="퇴근 시 손으로 실행(Scripts/bug-hunt.sh) — 스케줄러가 돌리지 않음">수동</span>';
              if(o==='qa') return '<span class="chip" style="margin:0;background:#3aa0ff;color:#fff" title="외부 자동화(launchd → claude -p)가 보고">자동화</span>';
              if(o&&o!=='core') return '<span class="chip" style="margin:0;background:#9b7bff;color:#fff" title="'+esc(o)+'">플러그인</span>';
              return '<span class="muted">기본</span>';
            };
            rows.innerHTML=_workers.map(function(w,i){
              var off=w.enabled===false;
              var badge;
              if(off) badge='<span class="chip bad" title="사용자가 끔">꺼짐</span>';
              else { badge=w.active?'<span class="chip">동작 중</span>':'<span class="chip bad">유휴</span>';
                if(w.error) badge='<span class="chip bad" title="'+esc(w.errorMsg||'')+'">오류 ⚠</span> '+badge; }
              var more=w.id?'<a class="btn" href="/worker?id='+encodeURIComponent(w.id)+'" target="_blank">자세히</a>':'';
              var ctrl='';
              if(w.toggleable) ctrl+=' <button class="btn" onclick="toggleWorker(\\''+esc(w.id)+'\\','+off+')">'+(off?'켜기':'끄기')+'</button>';
              if(w.runnable) ctrl+=' <button class="btn" title="지금 한 번 실행" onclick="runWorker(this,\\''+esc(w.id)+'\\')"'+(off?' disabled':'')+'>즉시 실행</button>';
              return '<tr'+(w.error&&!off?' style="background:rgba(226,102,125,0.08)"':'')+(off?' style="opacity:0.6"':'')+'><td><b>'+esc(w.name)+'</b></td>'
                +'<td>'+ownerLabel(w.owner,w.manual)+'</td>'
                +'<td class="muted">'+esc(w.detail)+'</td>'
                +'<td'+(w.manual?' title="자동 실행 주기가 아니라, 1회 실행 동안 도는 라운드 간격"':'')+'>'+(w.manual?'라운드 '+fmtInterval(w.interval):fmtInterval(w.interval))+'</td>'
                +'<td id="wk_ago_'+i+'">'+fmtAgo(w.agoSec)+'</td>'
                +'<td id="wk_next_'+i+'">'+(!off&&w.active&&w.nextSec>=0?w.nextSec+'초 후':'–')+'</td>'
                +'<td>'+(w.runs||0).toLocaleString()+'</td>'
                +'<td>'+badge+'</td>'
                +'<td>'+more+ctrl+'</td></tr>';
            }).join('');
          }
          function toggleWorker(id,wasOff){ post('/api/worker/toggle',{id:id,enabled:wasOff}).then(function(){ setTimeout(load,300); }); }
          function runWorker(btn,id){ if(btn){ btn.disabled=true; btn.textContent='실행 중…'; }
            post('/api/worker/run',{id:id}).then(function(){ setTimeout(load,1500); }); }
          function tickWorkers(){ if(!_workers.length) return;
            var elapsed=Math.floor((performance.now()-_workersBase)/1000);
            _workers.forEach(function(w,i){
              if(w.agoSec>=0){ var a=document.getElementById('wk_ago_'+i); if(a) a.textContent=fmtAgo(w.agoSec+elapsed); }
              if(w.active&&w.nextSec>=0){ var n=document.getElementById('wk_next_'+i);
                if(n) n.textContent=Math.max(0,w.nextSec-elapsed)+'초 후'; }
            });
          }
          function load(){ fetch('/workers.json').then(function(r){ return r.json(); })
            .then(function(d){ renderWorkers(d.workers); }).catch(function(){}); }
          load();
          setInterval(tickWorkers,1000);
          </script>
        </body></html>
        """
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func transcriptHTML(title: String, body: String) -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title))</title>
        <style>
          :root{--bg:#0e1116;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          .msg{margin:14px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .msg .who{font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--mut);padding:8px 14px;border-bottom:1px solid var(--line);background:#11161f}
          .msg .body{padding:12px 14px}
          .msg.user .who{color:#9fc0ff}
          .msg.assistant .who{color:#8fe3c0}
          .text{white-space:pre-wrap;word-break:break-word}
          .text+.text,.text+details,details+.text,details+details{margin-top:10px}
          details{border:1px solid var(--line);border-radius:8px;background:#0f141c}
          details summary{cursor:pointer;padding:6px 10px;color:var(--mut);font-size:12px}
          details pre{margin:0;padding:10px 12px;border-top:1px solid var(--line);white-space:pre-wrap;word-break:break-word;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#cdd4df;max-height:420px;overflow:auto}
          details.tool summary{color:#ffcf8f}
          details.result summary{color:#9fe0a0}
          details.think summary{color:#b6a8ff}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
        </style></head>
        <body>
          <header><h1>\(htmlEscape(title))</h1><div class="sub">세션 트랜스크립트 · 읽기 전용</div></header>
          <main>\(body)</main>
        </body></html>
        """
    }

    // GET /breakdown?goal=<id> -> a minute-by-minute view of a session's work:
    // tool-call summary, per-minute token usage, and a grand total token tally.
    // Like /transcript, only session-linked goals (with a resolvable transcript)
    // produce a real page; everything else explains the gap.
    func breakdownPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "goal" })?.value else { return nil }
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.id == id } }
        guard let goal = goalOpt else { return nil }
        guard let url = resolveTranscript(goal) else {
            let where_ = goal.transcriptPath.isEmpty ? "(경로 미지정)" : goal.transcriptPath
            return breakdownHTML(title: goal.text,
                body: "<p class=\"empty\">연결된 트랜스크립트 파일을 찾을 수 없습니다.<br>\(htmlEscape(where_))</p>")
        }
        return renderBreakdown(goal: goal, url: url)
    }

    // Per-minute accumulator for the breakdown view.
    private struct MinuteAgg {
        var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
        var tools: [String: Int] = [:]   // tool name -> call count this minute
        var details: [String] = []       // representative targets (file/command/…), bounded
        var firstTs: Date?
    }

    private func renderBreakdown(goal: ReviewStore.Goal, url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return breakdownHTML(title: goal.text, body: "<p class=\"empty\">파일을 읽을 수 없습니다.</p>")
        }
        var minutes: [Int: MinuteAgg] = [:]
        var order: [Int] = []                    // minute-bucket keys, in first-seen order
        var totalIn = 0, totalOut = 0, totalCC = 0, totalCR = 0
        var msgCount = 0
        var firstDate: Date?, lastDate: Date?

        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = self.parseTS(tsStr) else { return }

            let usage = msg["usage"] as? [String: Any]
            let input = (usage?["input_tokens"] as? Int) ?? 0
            let output = (usage?["output_tokens"] as? Int) ?? 0
            let cc = (usage?["cache_creation_input_tokens"] as? Int) ?? 0
            let cr = (usage?["cache_read_input_tokens"] as? Int) ?? 0

            var hits: [(name: String, detail: String)] = []
            if let arr = msg["content"] as? [[String: Any]] {
                for b in arr where (b["type"] as? String) == "tool_use" {
                    let name = b["name"] as? String ?? "tool"
                    hits.append((name, self.toolDetail(b["input"])))
                }
            }
            // Skip bookkeeping-only chunks (no tokens, no tools).
            if input == 0 && output == 0 && cc == 0 && cr == 0 && hits.isEmpty { return }

            msgCount += 1
            totalIn += input; totalOut += output; totalCC += cc; totalCR += cr
            if firstDate == nil { firstDate = ts }
            lastDate = ts

            let key = Int(ts.timeIntervalSince1970 / 60)
            if minutes[key] == nil { minutes[key] = MinuteAgg(); order.append(key) }
            minutes[key]!.input += input
            minutes[key]!.output += output
            minutes[key]!.cacheCreate += cc
            minutes[key]!.cacheRead += cr
            if minutes[key]!.firstTs == nil { minutes[key]!.firstTs = ts }
            for h in hits {
                minutes[key]!.tools[h.name, default: 0] += 1
                if !h.detail.isEmpty, minutes[key]!.details.count < 6 { minutes[key]!.details.append(h.detail) }
            }
        }

        // Headline total counts each token once: new input + output + cache writes.
        // cache_read replays already-counted context every turn, so summing it would
        // inflate a short session into millions; it's surfaced separately below.
        let total = totalIn + totalOut + totalCC
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"

        // Header card: grand total + breakdown + session facts.
        let spanFmt = DateFormatter()
        spanFmt.locale = Locale(identifier: "en_US_POSIX")
        spanFmt.dateFormat = "MM-dd HH:mm"
        let span: String = {
            guard let f = firstDate, let l = lastDate else { return "-" }
            return "\(spanFmt.string(from: f)) ~ \(hm.string(from: l))"
        }()
        let header = """
        <div class="hcard">
          <div class="big"><span class="lab">총 토큰</span><span class="n">\(fmtNum(total))</span></div>
          <div class="bd">
            <span>출력 <b>\(fmtNum(totalOut))</b></span>
            <span>입력 <b>\(fmtNum(totalIn))</b></span>
            <span>캐시생성 <b>\(fmtNum(totalCC))</b></span>
            <span class="dim">캐시읽기(재사용) <b>\(fmtNum(totalCR))</b></span>
          </div>
          <div class="bd meta">
            <span>작업시간 <b>\(fmtClock(goal.trackedSeconds))</b></span>
            <span>메시지 <b>\(msgCount)</b></span>
            <span>구간 <b>\(htmlEscape(span))</b></span>
          </div>
        </div>
        """

        if order.isEmpty {
            return breakdownHTML(title: goal.text,
                body: header + "<p class=\"empty\">표시할 작업 기록이 없습니다.</p>")
        }

        var rows = ""
        for key in order {
            guard let m = minutes[key] else { continue }
            let label = hm.string(from: m.firstTs ?? Date(timeIntervalSince1970: Double(key * 60)))
            let chips = m.tools.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "<span class=\"chip\">\(htmlEscape($0.key))<i>×\($0.value)</i></span>" }
                .joined()
            let work = chips.isEmpty ? "<span class=\"chip none\">대화</span>" : chips
            let det = m.details.isEmpty ? ""
                : "<div class=\"det\">" + m.details.map { htmlEscape($0) }.joined(separator: " · ") + "</div>"
            let mTotal = m.input + m.output + m.cacheCreate
            rows += """
            <div class="min">
              <div class="t">\(label)</div>
              <div class="work">\(work)\(det)</div>
              <div class="tok"><b>\(fmtNum(m.output))</b><span>out</span><em>\(fmtNum(mTotal))</em></div>
            </div>
            """
        }
        return breakdownHTML(title: goal.text, body: header + "<div class=\"mins\">" + rows + "</div>")
    }

    // Pull a short, human-meaningful target out of a tool_use input dict
    // (filename, command, search pattern, …). Empty when nothing fits.
    private func toolDetail(_ input: Any?) -> String {
        guard let d = input as? [String: Any] else { return "" }
        func s(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let p = s("file_path") ?? s("notebook_path") ?? s("path") {
            return (p as NSString).lastPathComponent
        }
        if let c = s("command") { return String(c.prefix(80)) }
        if let p = s("pattern") { return p }
        if let q = s("query") { return q }
        if let u = s("url") { return u }
        if let desc = s("description") { return desc }
        if let pr = s("prompt") { return String(pr.prefix(60)) }
        return ""
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func parseTS(_ s: String) -> Date? {
        Self.isoFrac.date(from: s) ?? Self.isoPlain.date(from: s)
    }

    private func fmtNum(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
    private func fmtClock(_ sec: Double) -> String {
        let s = max(0, Int(sec)); let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }

    private func breakdownHTML(title: String, body: String) -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title)) · 작업 분석</title>
        <style>
          :root{--bg:#0e1116;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#8fe3c0}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px;z-index:2}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          .hcard{border:1px solid var(--line);border-radius:14px;background:#11161f;padding:16px 18px;margin-bottom:18px}
          .hcard .big{display:flex;align-items:baseline;gap:10px}
          .hcard .big .lab{color:var(--mut);font-size:12px;letter-spacing:.04em}
          .hcard .big .n{font:600 30px/1.1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--accent)}
          .hcard .bd{display:flex;flex-wrap:wrap;gap:14px;margin-top:10px;color:var(--mut);font-size:12px}
          .hcard .bd b{color:var(--fg);font-variant-numeric:tabular-nums;font-weight:600}
          .hcard .bd.meta{margin-top:6px;padding-top:8px;border-top:1px solid var(--line)}
          .hcard .bd .dim{opacity:.6}
          .mins{display:flex;flex-direction:column;gap:1px;border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .min{display:grid;grid-template-columns:54px 1fr 120px;gap:10px;align-items:start;padding:9px 12px;background:#0f141c}
          .min:nth-child(odd){background:#10151e}
          .min .t{color:var(--mut);font:600 12px/1.8 ui-monospace,SFMono-Regular,Menlo,monospace;font-variant-numeric:tabular-nums}
          .min .work{display:flex;flex-wrap:wrap;gap:5px;align-items:center}
          .chip{display:inline-flex;align-items:center;gap:3px;background:#1a2330;border:1px solid var(--line);border-radius:7px;padding:1px 7px;font-size:12px;color:#cdd4df}
          .chip i{font-style:normal;color:var(--mut);font-size:11px}
          .chip.none{color:var(--mut);background:transparent}
          .det{flex-basis:100%;color:var(--mut);font-size:11px;margin-top:2px;word-break:break-word}
          .min .tok{text-align:right;font-variant-numeric:tabular-nums}
          .min .tok b{color:var(--accent);font-size:14px}
          .min .tok span{color:var(--mut);font-size:11px;margin-left:3px}
          .min .tok em{display:block;color:var(--mut);font-size:11px;font-style:normal}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
        </style></head>
        <body>
          <header><h1>\(htmlEscape(title))</h1><div class="sub">분 단위 작업 분석 · 툴 호출 · 토큰</div></header>
          <main>\(body)</main>
        </body></html>
        """
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
        let nowProfile = director.isPlaying ? director.activeProfileLabel : "-"
        let nowPlan: String
        if director.isPlaying && director.rainActive {
            let rem = director.rainRemaining.map { " \(Int($0/60))분" } ?? ""
            nowPlan = "🌧 폭우 리셋\(rem)"
        } else {
            nowPlan = director.isPlaying ? (bgmPlan.slot()?.label ?? "-") : "-"
        }
        let nowTrack = director.isPlaying ? (audio.currentTitle ?? "-") : "-"
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let nowSite = chromeDomain.isEmpty ? "-" : chromeDomain
        let nowTier = ValueTier.classify(bundleID: frontBundle, site: chromeDomain)
        // Accelerator gauge: live APM (pedal), redline fraction, gear phase, and the
        // next track the director is steering toward (gray "next gear" hint).
        let playing = director.isPlaying
        let nowAPM = playing ? Int(activity.instantAPM) : 0
        let nowNorm = playing ? activity.apmNorm : 0.0
        let nowGear = playing ? director.gearLabel : "-"
        let predictedNext: BPMLibrary.Track? = playing ? director.predictedNextTrack() : nil
        let nowNextBpm = predictedNext.map { Int($0.bpm) } ?? 0
        let nowNextTrack = predictedNext?.title ?? "-"
        let nowNormStr = String(format: "%.3f", nowNorm)
        let nowGearJSON = jsonString(nowGear)
        let nowNextTrackJSON = jsonString(nowNextTrack)
        return """
        {"date":"\(date)",\
        "dev":\(AppPaths.isCustom),"dataLabel":\(jsonString(AppPaths.label)),\
        "today":{"seconds":\(Int(store.todaySeconds)),"label":"\(todayLabel)"},\
        "total":{"seconds":\(Int(store.data.totalSeconds)),"label":"\(totalLabel)"},\
        "now":{"working":\(isWorking),"muted":\(session.isMuted),"status":"\(liveStatus)",\
        "app":\(jsonString(nowApp)),"profile":\(jsonString(nowProfile)),"plan":\(jsonString(nowPlan)),"track":\(jsonString(nowTrack)),\
        "site":\(jsonString(nowSite)),"key":\(Int(activity.keyRate)),"mouse":\(Int(activity.mouseRate)),\
        "tier":\(jsonString(nowTier.label)),"mult":\(nowTier.multiplier),\
        "apm":\(nowAPM),"norm":\(nowNormStr),"gear":\(nowGearJSON),\
        "nextBpm":\(nowNextBpm),"nextTrack":\(nowNextTrackJSON)},\
        "review":\(reviewJSON()),\
        "plugins":\(pluginStore.pluginsJSON()),\
        "workers":\(WorkerRegistry.shared.snapshotJSON()),\
        "samples":\(samples)}
        """
    }

    // GET /api/session/state — the shared live state the sidebar rail's challenge dial polls:
    // {working, muted} from the single source of truth, plus the current session's elapsed active
    // seconds (so the dial shows the right time when a page loads mid-session). Kept separate from
    // the heavier /data.json so any page (dashboard, goal) can poll it cheaply.
    func sessionStateJSON() -> String {
        DispatchQueue.main.sync {
            // Current sprint's wall-clock window (epoch secs) so the dial's 스프린트 mode can count
            // down to the sprint target; 0 when no sprint exists.
            let sp = self.reviewStore.currentSprint
            let spStart = sp?.startAt.map { Int($0.timeIntervalSince1970) } ?? 0
            let spTarget = sp?.targetAt.map { Int($0.timeIntervalSince1970) } ?? 0
            return "{\"working\":\(self.session.isRunning),\"muted\":\(self.session.isMuted),"
                + "\"seconds\":\(Int(self.sessionSeconds)),\"today\":\(Int(self.store.todaySeconds)),"
                + "\"bgm\":\(Settings.shared.musicEnabled),"
                + "\"sprintStart\":\(spStart),\"sprintTarget\":\(spTarget)}"
        }
    }

    // GET /api/equipment — 장비+숙련도 state for the equipment page and the rail's
    // settings-menu level chip: per-category level/XP/need, average + overall level,
    // market inflation, the recent award ledger, plus the live plugin list so the
    // page renders one box per plugin (same serialized form as /data.json uses).
    func equipmentJSON() -> String {
        let payload = equipment.statePayload()
        let base = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var s = String(decoding: base, as: UTF8.self)
        if s.hasSuffix("}") {
            s.removeLast()
            s += ",\"plugins\":\(pluginStore.pluginsJSON())}"
        }
        return s
    }

    // USER-driven usage-event counts per equipment category over the last `window`
    // seconds — the pomodoro EXP attribution input. Only deliberate user actions
    // count: skills = skill executions (skillUsageEvents), chat = dashboard chat
    // user messages. Autonomous activity is deliberately EXCLUDED — background
    // workers fire 24/7 regardless of what the user does, so counting them would
    // hand every pomodoro's EXP to 워커 (confirmed in testing). 위임/워커/팀/
    // 플러그인 join once they have a user-action signal; with no usage at all the
    // store falls back to 대화 (기본기).
    private func equipmentUsage(within window: TimeInterval) -> [String: Int] {
        let cutoff = Date().timeIntervalSince1970 - window
        var usage: [String: Int] = [:]
        usage["skills"] = skillUsageEvents().filter {
            let e = ($0["epoch"] as? Double) ?? Double(($0["epoch"] as? Int) ?? 0)
            return e >= cutoff
        }.count
        usage["chat"] = chatStore.messages.filter {
            $0.role == "user" && $0.createdAt.timeIntervalSince1970 >= cutoff
        }.count
        return usage
    }

    // GET /history.json?days=N -> compact per-day samples for the 히스토리 tab.
    // The browser runs the same carry-forward + timeBuckets + deep-focus logic on
    // each day, so daily 총/책상/집중 and 초집중 sessions match the today view exactly.
    func dashboardHistory(_ path: String) -> String {
        let daysStr = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "days" })?.value ?? ""
        let days = Int(daysStr) ?? 180
        return "{\"days\":\(activityLog.historyJSON(days: days))}"
    }

    // GET /tokens.json?days=N — real daily token usage summed from every Claude session
    // transcript under ~/.claude/projects, bucketed by the local calendar day the message
    // was written. This is the actual "how many tokens did I spend each day" timeline (the
    // token view's goal-based g.tokens field is manually set and usually empty). Each day's
    // total counts new input + output + cache-creation once; cache_read is excluded because
    // it replays already-counted context every turn and would inflate totals by orders of
    // magnitude (same convention as the per-session breakdown headline).
    func dashboardTokens(_ path: String) -> String {
        let daysStr = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "days" })?.value ?? ""
        let days = max(1, Int(daysStr) ?? 90)
        let fm = FileManager.default
        // Only look back `days` from the start of today; a transcript touched before that
        // window cannot contribute to any in-window day, so skip it by mtime (cheap stat).
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"   // LOCAL time — same day boundary the rest of the UI uses

        // Enumerate every project's *.jsonl. Missing base dir -> empty timeline.
        guard let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return "{\"days\":[]}"
        }
        var files: [URL] = []
        for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let inner = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for f in inner where f.pathExtension == "jsonl" { files.append(f) }
        }

        var totals: [String: Int] = [:]           // day -> tokens
        var sessionsPerDay: [String: Set<String>] = [:]  // day -> distinct session files that spent tokens
        for f in files {
            let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? 0
            if mtime < cutoff { continue }

            let perDay = tokensByDay(file: f, mtime: mtime, size: size)
            let sid = f.deletingPathExtension().lastPathComponent
            for (day, tok) in perDay {
                totals[day, default: 0] += tok
                sessionsPerDay[day, default: []].insert(sid)
            }
        }

        // Active human seconds per day — for the 가치 mode's time-efficiency weighting.
        let activeSec = activityLog.activeSecondsByDay(days: days)

        // Emit only in-window days (a long session can carry an out-of-window day), newest first.
        let minDay = dayFmt.string(from: cutoff)
        let rows = totals.keys.filter { $0 >= minDay }.sorted(by: >).map { day -> String in
            let tokK = Int((Double(totals[day] ?? 0) / 1000.0).rounded())   // tokens -> K, matches UI unit
            let sess = sessionsPerDay[day]?.count ?? 0
            return "{\"day\":\(jsonString(day)),\"tokens\":\(totals[day] ?? 0),\"k\":\(tokK),"
                + "\"sessions\":\(sess),\"activeSec\":\(activeSec[day] ?? 0)}"
        }
        return "{\"days\":[\(rows.joined(separator: ","))]}"
    }

    // Parse one transcript into per-local-day token totals (input + output + cache-creation;
    // cache_read excluded to avoid replayed-context inflation). Cached by (mtime,size) so an
    // unchanged file is never re-parsed — the live/growing session re-parses, completed ones
    // stay cached. Shared by the daily timeline and the per-session goal total.
    private func tokensByDay(file: URL, mtime: Date, size: Int) -> [String: Int] {
        let key = file.path
        tokenDayLock.lock()
        let cached = tokenDayCache[key]
        tokenDayLock.unlock()
        if let c = cached, c.mtime == mtime, c.size == size { return c.days }

        var perDay: [String: Int] = [:]
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"   // LOCAL time — same day boundary as the rest of the UI
        if let data = try? Data(contentsOf: file) {
            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = self.parseTS(tsStr) else { return }
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let spent = input + output + cc
                if spent == 0 { return }
                perDay[dayFmt.string(from: ts), default: 0] += spent
            }
        }
        tokenDayLock.lock(); tokenDayCache[key] = (mtime, size, perDay); tokenDayLock.unlock()
        return perDay
    }

    // Real token total (in K) for a goal's linked Claude session, summed from its transcript.
    // 0 when no transcript resolves. Cached via tokensByDay, so a completed goal parses once.
    private func sessionTokenK(for goal: ReviewStore.Goal) -> Int {
        guard let url = resolveTranscript(goal) else { return 0 }
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = rv?.contentModificationDate ?? .distantPast
        let size = rv?.fileSize ?? 0
        let total = tokensByDay(file: url, mtime: mtime, size: size).values.reduce(0, +)
        return Int((Double(total) / 1000.0).rounded())
    }

    // Tiny real-time payload for the APM gauge, polled at 1 Hz (separate from the
    // heavier 5s /data.json so the needle moves like a game HUD).
    func liveData() -> String {
        let playing = director.isPlaying
        let apm = playing ? Int(activity.instantAPM) : 0
        let norm = playing ? activity.apmNorm : 0.0
        let track = playing ? (audio.currentTitle ?? "-") : "-"
        let predicted: BPMLibrary.Track? = playing ? director.predictedNextTrack() : nil
        let nextTrack = predicted?.title ?? "-"
        let normStr = String(format: "%.3f", norm)
        let gearJSON = jsonString(playing ? director.gearLabel : "-")
        let trackJSON = jsonString(track)
        let nextJSON = jsonString(nextTrack)
        return "{\"apm\":\(apm),\"norm\":\(normStr),\"gear\":\(gearJSON),\"track\":\(trackJSON),\"nextTrack\":\(nextJSON)}"
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
                // waitingSince as epoch seconds (0 = not waiting); display-only, never
                // added to trackedSeconds. Lets the client show the live wait duration.
                let waiting = g.waitingSince.map { String($0.timeIntervalSince1970) } ?? "0"
                // Scheduling datetimes as epoch seconds (0 = unset); the client renders
                // them in the 일정관리 view and ticks D-day from targetAt.
                let target = g.targetAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let completed = g.completedAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let agents = g.agents.map { jsonString($0) }.joined(separator: ",")
                // Evidence: files expose a server download URL (/evidence/<goalId>/<id>);
                // links carry their own URL directly. `href` is what the dashboard opens.
                let evidence = g.evidence.map { e -> String in
                    let href = e.kind == "file" ? "/evidence/\(g.id)/\(e.id)" : e.url
                    return "{\"id\":\(jsonString(e.id)),\"kind\":\(jsonString(e.kind)),"
                        + "\"title\":\(jsonString(e.title)),\"href\":\(jsonString(href)),"
                        + "\"addedAt\":\(e.addedAt.timeIntervalSince1970)}"
                }.joined(separator: ",")
                // Tokens: the manual g.tokens field wins when set; otherwise fall back to the
                // real total parsed from this goal's linked session transcript (cached), so the
                // token view shows actual usage instead of an empty 0.
                let effTokens = g.tokens > 0 ? g.tokens : self.sessionTokenK(for: g)
                // Link chain (source-side): the client renders the link dot and follows these in export.
                let links = g.links.map { jsonString($0) }.joined(separator: ",")
                // Subtask summary (goal-NN/tasks/*): lets the dashboard 유형(type) filter
                // render task rows under the goal — without this, an added task is invisible
                // in the 목록 until the goal page is opened.
                let tasks = self.subtaskSummaryJSON(seq: g.seq)
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),\"parent\":\(jsonString(g.parent)),"
                    + "\"links\":[\(links)],"
                    + "\"status\":\(jsonString(g.status)),\"trackedSeconds\":\(g.trackedSeconds),\"startedAt\":\(started),\"waitingSince\":\(waiting),"
                    + "\"energy\":\(g.energy),\"agents\":[\(agents)],\"tokens\":\(effTokens),\"value\":\(g.value),"
                    + "\"evidence\":[\(evidence)],\"sessionId\":\(jsonString(g.sessionId)),"
                    + "\"targetAt\":\(target),\"completedAt\":\(completed),"
                    + "\"sprint\":\(g.sprint),\"bump\":\(g.bump),\"released\":\(g.released),\"archived\":\(g.archived),\"priority\":\(jsonString(g.priority)),"
                    + "\"tasks\":[\(tasks)]}"
            }
            .joined(separator: ",")
        // Release log (newest first): when each commit happened + the value it produced.
        let releases = reviewStore.releases
            .map { rel -> String in
                let titles = rel.titles.map { jsonString($0) }.joined(separator: ",")
                let gids = rel.goalIds.map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(rel.id)),\"sprint\":\(rel.sprint),\"code\":\(jsonString(rel.code)),"
                    + "\"releasedAt\":\(rel.releasedAt.timeIntervalSince1970),\"value\":\(rel.value),"
                    + "\"goalIds\":[\(gids)],\"titles\":[\(titles)]}"
            }
            .joined(separator: ",")
        // Sprint definitions: code(YY-n) + 결과물 + 기간 + 시작/목표 날짜. closed = released.
        let sprints = reviewStore.sprints
            .map { s -> String in
                let st = s.startAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let tg = s.targetAt.map { String($0.timeIntervalSince1970) } ?? "0"
                return "{\"number\":\(s.number),\"code\":\(jsonString(s.code)),\"goalText\":\(jsonString(s.goalText)),"
                    + "\"durationKind\":\(jsonString(s.durationKind)),\"startAt\":\(st),\"targetAt\":\(tg),\"closed\":\(s.closed)}"
            }
            .joined(separator: ",")
        // AI dedup queue (the "later" pile): candidates parked for one-by-one review.
        // Oldest first so the user works the backlog in arrival order.
        let aiQueue = reviewStore.aiQueue
            .map { item -> String in
                let matches = item.matches.map { m -> String in
                    "{\"seq\":\(m.seq),\"text\":\(jsonString(m.text)),\"why\":\(jsonString(m.why))}"
                }.joined(separator: ",")
                return "{\"id\":\(jsonString(item.id)),\"text\":\(jsonString(item.text)),"
                    + "\"parent\":\(jsonString(item.parent)),\"sprint\":\(item.sprint),"
                    + "\"status\":\(jsonString(item.status)),\"duplicate\":\(item.duplicate),"
                    + "\"kind\":\(jsonString(item.kind)),"
                    + "\"jobKind\":\(jsonString(item.jobKind)),\"title\":\(jsonString(item.title)),"
                    + "\"resultHTML\":\(jsonString(item.resultHTML)),\"error\":\(jsonString(item.error)),"
                    + "\"note\":\(jsonString(item.note)),\"refining\":\(!item.refineSession.isEmpty),"
                    + "\"refineSession\":\(jsonString(item.refineSession)),\"findOnly\":\(item.findOnly),"
                    // AI placement verdict (Option D) — the queue card pre-fills the promote form
                    // from these; the user can override parentSeq/priority at resolve time.
                    + "\"placement\":\(jsonString(item.placement)),\"suggestedParentSeq\":\(item.suggestedParentSeq),"
                    + "\"priority\":\(jsonString(item.priority)),\"confidence\":\(item.confidence),"
                    + "\"rationale\":\(jsonString(item.rationale)),"
                    + "\"matches\":[\(matches)],\"createdAt\":\(item.createdAt.timeIntervalSince1970)}"
            }
            .joined(separator: ",")
        // 큐 처리 히스토리 (newest first, last 30): what each resolution did — so the 큐 탭 can
        // show the audit trail, link to the created goal/task, and offer 번복 (undo).
        let queueHistory = reviewStore.queueHistory.suffix(30).reversed()
            .map { h -> String in
                "{\"id\":\(jsonString(h.id)),\"at\":\(h.at.timeIntervalSince1970),"
                    + "\"action\":\(jsonString(h.action)),\"text\":\(jsonString(h.text)),"
                    + "\"seq\":\(h.seq),\"parentSeq\":\(h.parentSeq),\"task\":\(jsonString(h.taskFolder)),"
                    + "\"fallback\":\(h.fallback),\"undone\":\(h.undone)}"
            }
            .joined(separator: ",")
        let contribs = r.contributions
            .map { "\(jsonString($0.key)):\($0.value)" }
            .joined(separator: ",")
        let notes = r.notes
            .map { "\(jsonString($0.key)):\(jsonString($0.value))" }
            .joined(separator: ",")
        func optInt(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return "{\"goals\":[\(goals)],\"releases\":[\(releases)],\"sprints\":[\(sprints)],"
            + "\"aiQueue\":[\(aiQueue)],\"queueHistory\":[\(queueHistory)],"
            + "\"selfScore\":\(optInt(r.selfScore)),\"submittedSelf\":\(r.submittedSelf),"
            + "\"contributions\":{\(contribs)},\"notes\":{\(notes)},"
            + "\"aiScore\":\(optInt(r.aiScore)),\"aiNote\":\(jsonString(r.aiNote)),"
            + "\"adminScore\":\(optInt(r.adminScore))}"
    }

    // Loop worklist: the queue an external auto-loop pulls from. Eligibility mirrors
    // ReviewStore.validStatuses semantics — ONLY backlog (대기) leaf goals are returned;
    // in_progress/waiting/stopped/cancelled/done are all excluded, so the loop can never
    // restart a held (중지) or abandoned (취소) goal. Parents are skipped (they roll up from
    // children and aren't executable units). Ordered by seq so the loop honors priority.
    // See .doc/loop-status-design.md.
    private func loopQueueJSON() -> String {
        let all = reviewStore.goals
        let parentIDs = Set(all.compactMap { $0.parent.isEmpty ? nil : $0.parent })
        let eligible = all
            .filter { $0.status == "backlog" && !parentIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        let queue = eligible
            .map { g -> String in
                let agents = g.agents.map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),"
                    + "\"sessionId\":\(jsonString(g.sessionId)),\"transcriptPath\":\(jsonString(g.transcriptPath)),"
                    + "\"energy\":\(g.energy),\"agents\":[\(agents)],\"trackedSeconds\":\(g.trackedSeconds)}"
            }
            .joined(separator: ",")
        return "{\"queue\":[\(queue)],\"count\":\(eligible.count)}"
    }

    // POST router (runs on the server queue; mutations hop to main for safety).
    // ===== 스킬 목록 (rail의 "스킬" 메뉴) =====
    // The user's skills live in ~/.claude/skills; each subfolder holding a SKILL.md is
    // one skill. We surface name / last-updated / author for the rail's skills overlay so
    // the user can see what's installed without memorizing folder names.
    // Default ".claude" root under the home dir when the user has not configured one.
    private var skillsRootDefault: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
    // Configurable base ".claude" folder (set on the skills page). Falls back to ~/.claude.
    // Skills are read from its /skills subfolder, so the on-disk layout is unchanged.
    private var skillsRoot: URL {
        let s = (Settings.shared.skillsRoot ?? "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return skillsRootDefault }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }
    private var skillsDir: URL {
        skillsRoot.appendingPathComponent("skills", isDirectory: true)
    }

    // Path to the append-only skill-usage log the PostToolUse hook (cc-skill-hook.sh) writes.
    // One JSONL line per skill invocation: {epoch, ts, skill, session, cwd}. This file IS
    // the history surfaced on the skills page.
    private var skillUsageLog: URL {
        AppPaths.base.appendingPathComponent("skill-usage.jsonl", isDirectory: false)
    }

    // Read + parse the usage log into events (newest LAST, i.e. file order). Each event is a
    // dict with epoch/ts/skill/session/cwd. Malformed lines are skipped. Returns [] when the
    // log does not exist yet (no skill has ever run).
    private func skillUsageEvents() -> [[String: Any]] {
        guard let text = try? String(contentsOf: skillUsageLog, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let skill = obj["skill"] as? String, !skill.isEmpty else { continue }
            out.append(obj)
        }
        return out
    }

    // Aggregate the usage log per skill slug (lowercased) -> (count, lastEpoch). Used to
    // stamp each skill row with its use count and last-used time.
    private func skillUsageAgg() -> [String: (count: Int, lastEpoch: Double)] {
        var agg: [String: (count: Int, lastEpoch: Double)] = [:]
        for ev in skillUsageEvents() {
            guard let slug = (ev["skill"] as? String)?.lowercased(), !slug.isEmpty else { continue }
            let epoch = (ev["epoch"] as? Double) ?? Double((ev["epoch"] as? Int) ?? 0)
            let prev = agg[slug] ?? (0, 0)
            agg[slug] = (prev.count + 1, max(prev.lastEpoch, epoch))
        }
        return agg
    }

    func skillsJSON() -> String {
        let fm = FileManager.default
        let dir = skillsDir
        let usage = skillUsageAgg()
        var items: [[String: Any]] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let skillMd = url.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMd.path) else { continue }   // a skill must have SKILL.md
            let text = (try? String(contentsOf: skillMd, encoding: .utf8)) ?? ""
            let meta = Self.parseSkillFrontmatter(text, fallbackName: url.lastPathComponent)
            // The one-line summary the user sees/edits: an explicit `summary:` field if
            // present, otherwise the first sentence of the (long) triggering description.
            let summary = meta.summary.isEmpty ? Self.firstSentence(meta.desc) : meta.summary
            // "Updated" = the more recent of the folder and its SKILL.md, so edits to the
            // manifest OR any bundled file both bump the date the user sees.
            let dMod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mMod = (try? skillMd.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let updated = max(dMod, mMod)
            // Merge usage stats. The hook records ONE slug per event; for user skills it is
            // usually the folder name, but match on the frontmatter `name:` too so either
            // form is counted. Union the candidate keys (they collapse when equal), summing
            // counts and taking the latest use.
            var useCount = 0
            var lastEpoch = 0.0
            var seenKeys = Set<String>()
            for key in [meta.name.lowercased(), url.lastPathComponent.lowercased()] where !key.isEmpty {
                guard seenKeys.insert(key).inserted, let u = usage[key] else { continue }
                useCount += u.count
                lastEpoch = max(lastEpoch, u.lastEpoch)
            }
            let lastUsed = lastEpoch > 0 ? Self.koShortDate(Date(timeIntervalSince1970: lastEpoch)) : ""
            items.append([
                "name": meta.name,
                "folder": url.lastPathComponent,
                "desc": meta.desc,
                "summary": summary,
                "hasSummary": !meta.summary.isEmpty,
                "author": meta.author,
                "updated": Self.koShortDate(updated),
                "updatedTs": updated.timeIntervalSince1970,
                "useCount": useCount,
                "lastUsed": lastUsed,
                "lastUsedTs": lastEpoch,
            ])
        }
        items.sort { (($0["updatedTs"] as? Double) ?? 0) > (($1["updatedTs"] as? Double) ?? 0) }
        // `root` is the configurable ".claude" folder; `dir` is its /skills subfolder actually
        // scanned. The skills page shows `root` (editable) and lists from `dir`.
        let payload: [String: Any] = ["dir": dir.path, "root": skillsRoot.path,
                                      "isDefault": Settings.shared.skillsRoot?.isEmpty ?? true,
                                      "skills": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // Read-only feed for the 에이전트 page. Surfaces every skill that follows the
    // "responsible agent" convention — a skill folder with an agent/ subfolder holding
    // agent/ACTIVE (current version) and agent/vN-*.md (version history), plus ledger/*.jsonl
    // run records. For each we compute: active version, per-version success (the retrospective
    // arc that shows why a version was replaced), overall purpose-achievement rate, and a
    // recent run timeline — so the user sees when the agent ran, whether it met its purpose,
    // and when it needs replacing.
    func agentsJSON() -> String {
        let fm = FileManager.default
        let agentsDir = skillsRoot.appendingPathComponent("agents", isDirectory: true)
        let skillsBase = skillsDir
        var items: [[String: Any]] = []
        var history = loadAgentHistory()
        var historyDirty = false
        let isoFmt = ISO8601DateFormatter()
        // Universal ledger of agent actions (keyed by "agent"); grouped per agent below into
        // the 기능 역할 (function-role) tab so the user sees which roles each agent performs,
        // how often, and — where recorded — how cleanly (rounds).
        let updateLog = loadAgentUpdateLog()
        let entries = (try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = Self.parseFrontmatter(text)
            let name = front["name"] ?? url.deletingPathExtension().lastPathComponent
            let desc = front["description"] ?? ""
            let model = front["model"] ?? "inherit"
            let harness = front["harness"] ?? ""

            // Modification history: ~/.claude/agents isn't git-tracked, so we snapshot each
            // revision (keyed by a launch-stable content hash) stamped with the file's mtime.
            // A new snapshot is recorded only when the file content actually changed, and each
            // one carries the purpose (description) as it read then — so the user can see how
            // the stated purpose evolved and whether an edit reflected the intended goal.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let sig = Self.stableHash(text)
            var hist = history[url.lastPathComponent] ?? []
            if (hist.last?["sig"] as? String) != sig {
                let snippet = desc.count > 200 ? String(desc.prefix(200)) + "…" : desc
                hist.append(["ts": isoFmt.string(from: mtime), "model": model, "desc": snippet, "sig": sig])
                if hist.count > 20 { hist = Array(hist.suffix(20)) }
                history[url.lastPathComponent] = hist
                historyDirty = true
            }
            let clientHist: [[String: Any]] = hist.map {
                ["ts": $0["ts"] ?? "", "model": $0["model"] ?? "", "desc": $0["desc"] ?? ""]
            }

            // Join run history + retrospective from the harness skill this agent belongs to
            // (declared via the agent's custom `harness:` frontmatter field).
            var runs = 0, oks = 0
            var lastTs = "", lastOutcome = "", retro = ""
            var recent: [[String: Any]] = []
            if !harness.isEmpty {
                let hdir = skillsBase.appendingPathComponent(harness, isDirectory: true)
                retro = (try? String(contentsOf: hdir.appendingPathComponent("retro.md"), encoding: .utf8)) ?? ""
                let ledgerDir = hdir.appendingPathComponent("ledger", isDirectory: true)
                let ledgerFiles = ((try? fm.contentsOfDirectory(at: ledgerDir, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])) ?? [])
                    .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for lf in ledgerFiles {
                    let t = (try? String(contentsOf: lf, encoding: .utf8)) ?? ""
                    for line in t.split(separator: "\n") {
                        guard let d = line.data(using: .utf8),
                              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                        if (o["summary"] as? Bool) == true { continue }
                        let ts = (o["ts"] as? String) ?? ""
                        if ts.isEmpty && o["report"] == nil && o["goal_id"] == nil { continue }
                        let label = (o["after"] as? String) ?? (o["report"] as? String) ?? (o["reason"] as? String) ?? ""
                        let note = (o["note"] as? String) ?? ""
                        // Exclude non-attempts (dry-runs) and infra failures (app down) — neither
                        // reflects whether the AGENT did its job well.
                        if label.hasPrefix("(dry-run") || note.contains("http-error")
                            || note.contains("spawn-error") { continue }
                        let ok = ((o["ok"] as? Bool) ?? (o["synced"] as? Bool)) ?? false
                        runs += 1; if ok { oks += 1 }
                        lastTs = ts; lastOutcome = ok ? "ok" : "fail"
                        recent.append(["ts": ts, "ok": ok, "label": label])
                    }
                }
            } else {
                // Standalone agents (no harness) don't own a harness ledger — their runs live in the
                // universal agent-update-log, keyed by agent name. Derive the SAME run headline from
                // there so they don't read as "기록 없음" despite an active ledger. `updateLog` is
                // chronological, so the last match is the most recent run.
                for o in updateLog where (o["agent"] as? String) == name {
                    let ts = (o["ts"] as? String) ?? ""
                    if ts.isEmpty { continue }
                    // A missing `ok` means a recorded, completed action — count it as a success
                    // unless the entry explicitly says otherwise.
                    let ok = (o["ok"] as? Bool) ?? true
                    let label = (o["func"] as? String) ?? (o["summary"] as? String)
                        ?? (o["type"] as? String) ?? ""
                    runs += 1; if ok { oks += 1 }
                    lastTs = ts; lastOutcome = ok ? "ok" : "fail"
                    recent.append(["ts": ts, "ok": ok, "label": label])
                }
            }
            // Headline = success over the last 20 real runs (reflects the current agent, not
            // dragged down by old ledger entries).
            let window = recent.suffix(20)
            let windowOks = window.filter { ($0["ok"] as? Bool) == true }.count
            // Per-function-role rollup from the universal ledger (this agent's entries only).
            let functions = Self.functionRoles(forAgent: name, in: updateLog)
            items.append([
                "name": name, "file": url.lastPathComponent, "desc": desc, "model": model,
                "harness": harness, "retro": retro, "runs": runs, "oks": oks,
                "okRate": runs > 0 ? Double(oks) / Double(runs) : 0,
                "recentRate": window.isEmpty ? 0 : Double(windowOks) / Double(window.count),
                "recentN": window.count, "lastTs": lastTs, "lastOutcome": lastOutcome,
                "recent": Array(recent.suffix(40)), "history": clientHist, "functions": functions,
            ])
        }
        items.sort { (($0["runs"] as? Int) ?? 0) > (($1["runs"] as? Int) ?? 0) }
        if historyDirty { saveAgentHistory(history) }
        let payload: [String: Any] = ["dir": agentsDir.path, "root": skillsRoot.path, "agents": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // Generic YAML frontmatter -> [key: value] for top-level single-line scalar fields.
    // Unwraps quoted scalars; skips comments, blank lines, and nested/indented values.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return map }
        var i = 1
        while i < lines.count {
            let raw = lines[i]; i += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") { continue }   // nested value
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { map[key] = val }
        }
        return map
    }

    // Deterministic (launch-stable) 64-bit FNV-1a hash. String.hashValue is per-process
    // seeded, so it would flag every app restart as a content change — this doesn't.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // Per-agent modification history, persisted under the app data dir (never the read-only
    // ~/.claude tree). Shape: { "<file>.md": [ {ts, model, desc, sig}, … ] }.
    private var agentHistoryURL: URL { AppPaths.base.appendingPathComponent("agent-history.json") }
    private func loadAgentHistory() -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: agentHistoryURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]]
        else { return [:] }
        return obj
    }
    private func saveAgentHistory(_ h: [String: [[String: Any]]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: h) else { return }
        try? data.write(to: agentHistoryURL)
    }

    // The universal agent action ledger — one JSON line per action, keyed by "agent".
    // Responsible agents (e.g. manager-qa) append to it whenever they perform a function-role
    // or self-update. Minimum shape: {ts, agent, type, summary}; richer entries add
    // {func, rounds, ok} so the 기능 역할 tab can grade HOW WELL a role was performed
    // (round 1 = done in one pass; many rounds = the role was hard/mis-scoped).
    // The universal ledger now lives under the data dir's `ledger/` folder. Older builds/agents
    // appended it directly under the base — we still read that legacy path and merge (legacy first,
    // so its older entries sort ahead of post-move ones), so nothing is lost during the move or if a
    // straggler appends there mid-run.
    private var agentUpdateLogURL: URL { AppPaths.base.appendingPathComponent("ledger/agent-update-log.jsonl") }
    private var agentUpdateLogLegacyURL: URL { AppPaths.base.appendingPathComponent("agent-update-log.jsonl") }
    private func loadAgentUpdateLog() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for url in [agentUpdateLogLegacyURL, agentUpdateLogURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                out.append(o)
            }
        }
        return out
    }

    // Roll an agent's ledger entries up into per-function-role rows: how many times each role
    // was performed and — when the agent recorded `rounds` — how cleanly. This is the signal
    // for "did this role get done well?": a role that keeps taking many rounds (or is performed
    // far more than others) is a candidate to split out or update. Grouped by an explicit
    // `func` label if present, else a human label mapped from `type`. Sorted by count desc.
    static func functionRoles(forAgent name: String, in log: [[String: Any]]) -> [[String: Any]] {
        func roleName(_ o: [String: Any]) -> String {
            if let f = (o["func"] as? String)?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return f }
            switch (o["type"] as? String) ?? "" {
            case "spec-update": return "SPEC 관리·동기화"
            case "agent-update": return "에이전트 자기개선"
            case "format-change": return "포맷 변경"
            case let t where !t.isEmpty: return t
            default: return "기타"
            }
        }
        func roundsOf(_ o: [String: Any]) -> Int? {
            if let i = o["rounds"] as? Int { return i }
            if let n = o["rounds"] as? NSNumber { return n.intValue }
            return nil
        }
        var order: [String] = []
        var groups: [String: [[String: Any]]] = [:]
        for o in log {
            guard ((o["agent"] as? String) ?? "") == name else { continue }
            let r = roleName(o)
            if groups[r] == nil { groups[r] = []; order.append(r) }
            groups[r]?.append(o)
        }
        var rows: [[String: Any]] = []
        for r in order {
            let entries = groups[r] ?? []
            let roundsVals = entries.compactMap(roundsOf)
            let sorted = entries.sorted { (($0["ts"] as? String) ?? "") > (($1["ts"] as? String) ?? "") }
            let lastTs = sorted.first.flatMap { $0["ts"] as? String } ?? ""
            let sample = sorted.first.flatMap { $0["summary"] as? String } ?? ""
            var row: [String: Any] = [
                "name": r, "count": entries.count, "lastTs": lastTs, "sample": sample,
            ]
            if !roundsVals.isEmpty {
                row["avgRounds"] = Double(roundsVals.reduce(0, +)) / Double(roundsVals.count)
                row["maxRounds"] = roundsVals.max() ?? 0
            }
            rows.append(row)
        }
        rows.sort { (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0) }
        return rows
    }

    // Chronological usage feed for the skills page "히스토리" tab — newest first, capped so a
    // long-lived log never bloats the response. Each entry: skill / ts / epoch / cwd.
    func skillHistoryJSON() -> String {
        let events = skillUsageEvents().reversed()   // file order is oldest-first; show newest-first
        let cap = 500
        var rows: [[String: Any]] = []
        for ev in events.prefix(cap) {
            rows.append([
                "skill": (ev["skill"] as? String) ?? "",
                "ts": (ev["ts"] as? String) ?? "",
                "epoch": (ev["epoch"] as? Double) ?? Double((ev["epoch"] as? Int) ?? 0),
                "cwd": (ev["cwd"] as? String) ?? "",
            ])
        }
        let payload: [String: Any] = ["events": rows, "count": rows.count,
                                      "total": skillUsageEvents().count]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func revealSkill(name: String) -> String {
        let base = skillsDir
        // Guard against path traversal: only a bare folder name is honored; anything with a
        // slash or ".." falls back to revealing the skills root.
        let safe = name.trimmingCharacters(in: .whitespaces)
        let target = (!safe.isEmpty && !safe.contains("/") && !safe.contains(".."))
            ? base.appendingPathComponent(safe, isDirectory: true) : base
        DispatchQueue.main.async {
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else {
                // Folder may not exist yet (no skills installed) — create it so Finder opens.
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([base])
            }
        }
        return "{\"ok\":true}"
    }

    // Reveal an official agent's .md file in ~/.claude/agents/ (selects the file in Finder;
    // falls back to the agents folder). Same bare-name path-traversal guard as revealSkill.
    func revealAgent(file: String) -> String {
        let base = skillsRoot.appendingPathComponent("agents", isDirectory: true)
        let safe = file.trimmingCharacters(in: .whitespaces)
        let target = (!safe.isEmpty && !safe.contains("/") && !safe.contains(".."))
            ? base.appendingPathComponent(safe) : base
        DispatchQueue.main.async {
            let fm = FileManager.default
            let sel = fm.fileExists(atPath: target.path) ? target : base
            NSWorkspace.shared.activateFileViewerSelecting([sel])
        }
        return "{\"ok\":true}"
    }

    // Set (or reset) the base ".claude" folder whose /skills holds the user's skills. A
    // blank folder resets to the ~/.claude default. Returns the refreshed skills listing so
    // the page updates the folder line AND the list in one round-trip.
    func setSkillsFolder(folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.skillsRoot = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        return skillsJSON()
    }

    // Open a native folder picker so the user can choose the ".claude" root. The panel runs
    // modally on main (a direct user action, so a brief block is fine); on choose, the path
    // is persisted. Returns the refreshed skills listing (unchanged if cancelled).
    func pickSkillsFolder() -> String {
        var chosen: String?
        DispatchQueue.main.sync {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "선택"
            panel.message = "스킬이 들어있는 .claude 폴더를 선택하세요 (하위 skills 폴더를 읽습니다)"
            panel.directoryURL = skillsRoot
            if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
        }
        if let c = chosen { Settings.shared.skillsRoot = c }
        return skillsJSON()
    }

    // Pull name / description / author out of a SKILL.md YAML frontmatter block. Kept
    // deliberately small — only the top-level `key: value` lines between the leading `---`
    // fences, plus folded/indented continuation lines for a multi-line description.
    static func parseSkillFrontmatter(_ text: String, fallbackName: String)
        -> (name: String, desc: String, summary: String, author: String) {
        var name = "", desc = "", summary = "", author = ""
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fallbackName, "", "", "사용자")
        }
        var i = 1
        while i < lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespaces) == "---" { break }   // end of frontmatter
            // Only parse top-level keys (no leading indent); indented lines are handled as
            // continuations of the key that opened them (used for folded descriptions).
            if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix(" ") && !raw.hasPrefix("\t") {
                let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var val = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // Folded/literal scalar (`>-`, `>`, `|`): gather the following indented lines.
                if val == ">-" || val == ">" || val == "|" || val == "|-" || val.isEmpty {
                    var parts: [String] = []
                    var j = i + 1
                    while j < lines.count {
                        let cont = lines[j]
                        if cont.hasPrefix(" ") || cont.hasPrefix("\t") {
                            parts.append(cont.trimmingCharacters(in: .whitespaces)); j += 1
                        } else { break }
                    }
                    if !parts.isEmpty { val = parts.joined(separator: " "); i = j - 1 }
                }
                // Unwrap a quoted scalar: a double-quoted value is unescaped (\" -> ", \\ -> \)
                // so a summary the user typed with quotes round-trips cleanly; a single-quoted
                // or bare value just has its surrounding quotes stripped.
                var clean = val
                if clean.count >= 2 && clean.hasPrefix("\"") && clean.hasSuffix("\"") {
                    clean = String(clean.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                } else if clean.count >= 2 && clean.hasPrefix("'") && clean.hasSuffix("'") {
                    clean = String(clean.dropFirst().dropLast())
                } else {
                    clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                switch key {
                case "name": name = clean
                case "description": desc = clean
                case "summary": summary = clean
                case "author": author = clean
                default: break
                }
            }
            i += 1
        }
        if name.isEmpty { name = fallbackName }
        if author.isEmpty { author = "사용자" }   // ~/.claude/skills entries are user-authored
        return (name, desc, summary, author)
    }

    // First sentence (or a short truncation) of a long description — the fallback shown
    // when a skill has no explicit `summary:` yet.
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if let r = t.range(of: ". ") { return String(t[t.startIndex..<r.lowerBound]) + "." }
        if t.count > 100 {
            let idx = t.index(t.startIndex, offsetBy: 100)
            return String(t[t.startIndex..<idx]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return t
    }

    // Write (or replace) the top-level `summary:` line in a skill's SKILL.md frontmatter.
    // We only ever touch that single line, so the (long, folded) `description:` used for
    // triggering is left intact. Called from POST /api/skills/summary.
    func setSkillSummary(folder: String, summary: String) -> String {
        let safe = folder.trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty, !safe.contains("/"), !safe.contains("..") else { return "{\"ok\":false}" }
        let md = skillsDir.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard var text = try? String(contentsOf: md, encoding: .utf8) else { return "{\"ok\":false}" }
        let oneLine = summary.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let escaped = oneLine.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let newLine = "summary: \"\(escaped)\""
        var lines = text.components(separatedBy: "\n")

        // No frontmatter at all -> prepend a minimal block.
        guard let openIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            text = "---\n\(newLine)\n---\n\n" + text
            try? text.write(to: md, atomically: true, encoding: .utf8)
            return "{\"ok\":true}"
        }
        var closeIdx: Int? = nil
        var k = openIdx + 1
        while k < lines.count { if lines[k].trimmingCharacters(in: .whitespaces) == "---" { closeIdx = k; break }; k += 1 }
        guard let close = closeIdx else { return "{\"ok\":false}" }

        // Replace an existing top-level `summary:` (plus any folded continuation lines)…
        var replaced = false
        var i = openIdx + 1
        while i < close {
            let raw = lines[i]
            if !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let colon = raw.firstIndex(of: ":"),
               String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == "summary" {
                var end = i + 1
                while end < close && (lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t")) { end += 1 }
                lines.replaceSubrange(i..<end, with: [newLine])
                replaced = true
                break
            }
            i += 1
        }
        // …or insert right after `name:` (falling back to just inside the opening fence).
        if !replaced {
            var insertAt = openIdx + 1
            var j = openIdx + 1
            while j < close {
                let raw = lines[j]
                if !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let colon = raw.firstIndex(of: ":"),
                   String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == "name" {
                    insertAt = j + 1; break
                }
                j += 1
            }
            lines.insert(newLine, at: insertAt)
        }
        let out = lines.joined(separator: "\n")
        try? out.write(to: md, atomically: true, encoding: .utf8)
        return "{\"ok\":true}"
    }

    // Korean short date, matching Claude Code's skill list ("26. 7. 3.").
    static func koShortDate(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        let yy = (c.year ?? 2000) % 100
        return "\(yy). \(c.month ?? 1). \(c.day ?? 1)."
    }

    func handlePost(_ path: String, _ body: String) -> String {
        let obj = (body.data(using: .utf8)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        // AI dedup pass runs an external `claude -p` (seconds, blocking). Handle it HERE
        // on the server thread — never inside the main.sync block below, or the whole UI
        // would freeze while the model thinks. It only reads a goals snapshot, so it is
        // safe off-main.
        if path == "/api/goal/aiAdd" {
            return aiDuplicateCheck(text: (obj["text"] as? String) ?? "",
                                    parent: (obj["parent"] as? String) ?? "")
        }
        // BGM view took over playback in the browser (or released it): mute/unmute the
        // native AudioEngine so the same track is not heard twice. Just a flag set on main.
        if path == "/api/bgm/native" {
            let mute = (obj["mute"] as? Bool) ?? false
            // The app window's ownership latch wins: while the window is open (either mode), native
            // stays muted even if the player (e.g. on a track switch) briefly asks to unmute.
            DispatchQueue.main.sync { self.audio.muted = mute || self.windowOwnsAudio }
            return "{\"ok\":true}"
        }
        // Test-only hook: headlessly switch the app window's mode without clicking the in-window
        // segmented toggle, so QA can exercise the dashboard<->bgm switch (and the audio-ownership
        // fix) in a scripted/CI run. Only reachable if the window is already open (see openInternal);
        // does not open the window itself.
        if path == "/api/debug/window-mode" {
            let modeStr = (obj["mode"] as? String) ?? ""
            guard let m = AppWindowController.Mode(rawValue: modeStr) else { return "{\"ok\":false}" }
            DispatchQueue.main.sync {
                if m == .bgm { self.openBGMWindow() } else { self.openDashboard() }
            }
            return "{\"ok\":true}"
        }
        // Test-only hook: headlessly simulate the user clicking the window's close button (real
        // NSWindow.close(), so the genuine windowWillClose -> onUserClose -> quit() path runs) —
        // lets QA exercise "closing the window quits the whole app" (SPEC Q1) without a real click.
        if path == "/api/debug/window-close" {
            DispatchQueue.main.sync { self.appWindowTestClose() }
            return "{\"ok\":true}"
        }
        // BGM view remote control: turn the BGM system (the widget's master switch) on/off
        // so the dashboard 액티비티 탭 and the menu-bar widget stay in sync. Mirrors the
        // menu's toggleMusic; the heartbeat starts the director on the next tick.
        if path == "/api/bgm/control" {
            let action = (obj["action"] as? String) ?? ""
            DispatchQueue.main.sync {
                if action == "play" { self.setBGMEnabled(true) }
                else if action == "stop" { self.setBGMEnabled(false) }
            }
            return "{\"ok\":true}"
        }
        // BGM view remote control for the CHALLENGE (work session) itself — the play button
        // in the 액티비티 탭 doubles as "챌린지 시작/중단" so the dashboard and the menu-bar
        // widget share one start/stop. Mirrors the menu's toggleWorking. Playback only makes
        // sound while a session is live (inSession gate), so the play button starts the session
        // here rather than only flipping the BGM master switch.
        if path == "/api/session/control" {
            let action = (obj["action"] as? String) ?? ""
            // Optional session mode from the rail's challenge dial (pomodoro /
            // sprint / unlimited) — selects the per-mode BGM playlist.
            let mode = obj["mode"] as? String
            DispatchQueue.main.sync {
                if action == "start" { self.startWorking(mode: mode) }
                else if action == "stop" { self.stopWorking() }
            }
            return "{\"ok\":true}"
        }
        // 포모도로 성공 보상 — the rail posts this when the pomodoro dial hits 25:00
        // (cmChOnComplete). The last 25 minutes' real usage decides which equipment
        // category receives the EXP (EquipmentStore.recordPomodoro); returns the
        // refreshed equipment state so the caller can show the result.
        if path == "/api/equipment/pomodoro" {
            let usage = equipmentUsage(within: 25 * 60)
            equipment.recordPomodoro(usage: usage)
            return equipmentJSON()
        }
        // Canonical music-mute control — the ONE endpoint every surface (dashboard mute dot, BGM
        // player, menu) posts to. {toggle:true} flips; {muted:bool} sets an explicit state. Source of
        // truth is session.isMuted; native output is synced from it and other webviews reconcile via
        // their poll. Returns the resulting {working,muted} so the caller can confirm.
        if path == "/api/session/mute" {
            return DispatchQueue.main.sync {
                if (obj["toggle"] as? Bool) == true { self.toggleMute() }
                else { self.setMutedRemote((obj["muted"] as? Bool) ?? self.session.isMuted) }
                return self.session.stateJSON
            }
        }
        // Switch the app window between the dashboard and the full condition (BGM) surface. Driven by
        // the rail's condition popup ("컨디션 전체 보기") and the BGM page's "← 대시보드" back button —
        // these replace the old titlebar segmented toggle. The two-webview switch is seamless and the
        // BGM webview keeps playing throughout (audio untouched).
        if path == "/api/window/mode" {
            let mode = (obj["mode"] as? String) ?? ""
            DispatchQueue.main.sync {
                if mode == "condition" || mode == "bgm" { self.openBGMWindow() } else { self.openDashboard() }
            }
            return "{\"ok\":true}"
        }
        // 폭우 리셋 manual trigger — normally the director summons it from activity, but
        // this lets QA and the user preview it on demand. {action:"start"} forces a rain
        // reset now (bypassing eligibility + daily limit); {action:"stop"} ends it early.
        // Require an EXPLICIT valid action so a malformed/empty body can't accidentally
        // summon rain (it would otherwise fall through to the default and start).
        if path == "/api/bgm/rain" {
            guard let action = obj["action"] as? String, action == "start" || action == "stop" else {
                return "{\"ok\":false,\"error\":\"action must be start|stop\"}"
            }
            DispatchQueue.main.sync { self.director?.triggerRain(stop: action == "stop") }
            return "{\"ok\":true}"
        }
        // 전략3 plan-map replace — the 관리자 AI's safe write path (agents never edit
        // bgm-plan.json directly, mirroring the goals convention). The body is the full
        // plan JSON; it is validated before committing. Unknown theme folders are
        // accepted (the library falls back rather than going silent) but reported so
        // the planner can correct them.
        if path == "/api/bgm/plan" {
            guard let data = body.data(using: .utf8), !data.isEmpty else {
                return "{\"ok\":false,\"error\":\"empty body\"}"
            }
            do {
                let (plan, known): (BGMPlanMap.Plan, Set<String>) = try DispatchQueue.main.sync {
                    let p = try self.bgmPlan.replace(jsonData: data)
                    self.director?.planDidChange()
                    return (p, Set(self.library.tracks.map(\.theme)))
                }
                let unknown = Set(plan.slots.flatMap(\.themes)).subtracting(known).sorted()
                let unkJSON = "[" + unknown.map { jsonString($0) }.joined(separator: ",") + "]"
                return "{\"ok\":true,\"slots\":\(plan.slots.count),\"unknownThemes\":\(unkJSON)}"
            } catch {
                return "{\"ok\":false,\"error\":\(jsonString(error.localizedDescription))}"
            }
        }
        // Clear the per-track play-time history (BGM 관리 "재생 시간 순위" 초기화 버튼).
        // {strategy:N} resets only that strategy's rows (the ranking filter's selection);
        // {strategy:0} or no body resets every strategy. The strategy catalog survives.
        if path == "/api/bgm/stats/reset" {
            let n = (obj["strategy"] as? Int) ?? 0
            DispatchQueue.main.sync { self.trackPlayStats.reset(strategy: n == 0 ? nil : n) }
            return "{\"ok\":true}"
        }
        // Reveal the skills folder (or one skill's folder) in Finder. Pure side effect
        // (no model, no goal state), so it is safe to handle here off-main.
        if path == "/api/skills/reveal" {
            return revealSkill(name: (obj["name"] as? String) ?? "")
        }
        // Agents page: reveal the official agent's .md file in ~/.claude/agents/.
        if path == "/api/agents/reveal" {
            return revealAgent(file: (obj["file"] as? String) ?? "")
        }
        // Save the user-edited one-line summary into the skill's SKILL.md. Pure file I/O.
        if path == "/api/skills/summary" {
            return setSkillSummary(folder: (obj["folder"] as? String) ?? "",
                                   summary: (obj["summary"] as? String) ?? "")
        }
        // Change (or reset) the skills base folder. Pure settings + directory scan.
        if path == "/api/skills/folder" {
            return setSkillsFolder(folder: (obj["folder"] as? String) ?? "")
        }
        // Native folder picker for the skills base folder (opens on main).
        if path == "/api/skills/folder/pick" {
            return pickSkillsFolder()
        }
        // Semantic search across ALL goals (including archived/released). Runs an external
        // `claude -p` (seconds, blocking) — handle here off-main like aiAdd, never inside the
        // main.sync block, so the UI never freezes while the model searches.
        if path == "/api/goal/aiSearch" {
            return aiSemanticSearch(query: (obj["query"] as? String) ?? "")
        }
        // Chat send runs `claude -p` (seconds) — handle off-main for the same reason.
        if path == "/api/chat/send" {
            return chatSend(text: (obj["text"] as? String) ?? "",
                            images: (obj["images"] as? [[String: Any]]) ?? [],
                            model: (obj["model"] as? String) ?? "")
        }
        // Per-goal "목표 명확화" chat. Send runs `claude -p` (seconds); reset routes through
        // goalChat() which itself hops to main — both must stay OUTSIDE the main.sync block.
        if path == "/api/goal/chat/send" {
            let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
            return goalChatSend(seq: seq, text: (obj["text"] as? String) ?? "",
                                model: (obj["model"] as? String) ?? "")
        }
        if path == "/api/goal/chat/reset" {
            return goalChatReset(Scope.from(body: obj))
        }
        // Streaming chat (chat2): say spawns a streaming claude turn whose events go out
        // over the scope's SSE channel; stop terminates the running turn. Non-blocking.
        if path == "/api/goal/chat2/say" {
            return chat2Say(Scope.from(body: obj), text: (obj["text"] as? String) ?? "",
                            mode: (obj["mode"] as? String) ?? "bypassPermissions",
                            model: (obj["model"] as? String) ?? "",
                            allow: (obj["allow"] as? [String]) ?? [])
        }
        if path == "/api/goal/chat2/stop" {
            chat2Stop(Scope.from(body: obj))
            return "{\"ok\":true}"
        }
        // Session link/unlink for a SUBTASK mutate its own ChatStore.linkedSessions. Handled
        // here off-main because chatStore(for:) hops to main internally (calling it inside the
        // main.sync block below would deadlock). Goal scope falls through to that block.
        if (path == "/api/goal/session/link" || path == "/api/goal/session/unlink"),
           case let scope = Scope.from(body: obj), scope.task != nil {
            let sid = (obj["sessionId"] as? String) ?? ""
            if path.hasSuffix("/link") { chatStore(for: scope)?.addLinked(sid) }
            else { chatStore(for: scope)?.removeLinked(sid) }
            return "{\"ok\":true}"
        }
        // Inline edit of a scope version: write the edited markdown straight to disk. Pure
        // file write — handle off-main like the other early returns above.
        if path == "/api/goal/definition/save" {
            return goalDefinitionSave(Scope.from(body: obj), kind: (obj["kind"] as? String) ?? "core",
                                      text: (obj["text"] as? String) ?? "")
        }
        // In-page interactive CLI: a real claude session in a PTY, bridged to the
        // dashboard's xterm.js terminal by polling. start spawns it; io ships keystrokes
        // and pulls new output; resize/stop manage its lifecycle.
        if path == "/api/goal/cli/start" {
            let cols = UInt16(clamping: (obj["cols"] as? NSNumber)?.intValue ?? 80)
            let rows = UInt16(clamping: (obj["rows"] as? NSNumber)?.intValue ?? 24)
            return cliStart(Scope.from(body: obj), cols: cols, rows: rows)
        }
        if path == "/api/goal/cli/io" {
            return cliIO(token: (obj["token"] as? String) ?? "",
                         inputB64: (obj["input"] as? String) ?? "",
                         since: (obj["since"] as? NSNumber)?.intValue ?? 0)
        }
        if path == "/api/goal/cli/resize" {
            cliResize(token: (obj["token"] as? String) ?? "",
                      cols: UInt16(clamping: (obj["cols"] as? NSNumber)?.intValue ?? 80),
                      rows: UInt16(clamping: (obj["rows"] as? NSNumber)?.intValue ?? 24))
            return "{\"ok\":true}"
        }
        if path == "/api/goal/cli/stop" {
            cliStop(token: (obj["token"] as? String) ?? "")
            return "{\"ok\":true}"
        }
        // AI추가 중복 확인 다이얼로그 안의 대화 한 턴: 목표를 AI와 상의해 다듬는다. claude 호출.
        if path == "/api/goal/aiChat" {
            return aiGoalChat(candidate: (obj["candidate"] as? String) ?? "",
                              matches: (obj["matches"] as? [[String: Any]]) ?? [],
                              history: (obj["history"] as? [[String: Any]]) ?? [],
                              message: (obj["message"] as? String) ?? "",
                              images: (obj["images"] as? [[String: Any]]) ?? [],
                              model: (obj["model"] as? String) ?? "")
        }
        // 큐 프롬프트 다듬기: 유저 프롬프트로 큐 항목을 다시 생성한다. claude 호출(수초, blocking)이라
        // main.sync 밖에서 처리한다. 성공 시 항목 텍스트+설명을 갱신하고 새 결과를 돌려준다.
        if path == "/api/goal/queue/refine" {
            let id = (obj["id"] as? String) ?? ""
            let prompt = (obj["prompt"] as? String) ?? ""
            guard !id.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "{\"ok\":false,\"error\":\"empty\"}"
            }
            // 항목 스냅샷: 현재 텍스트 + 유사 목표(첫 턴 컨텍스트) + 이어갈 세션 id (스레드 안전하게 main에서).
            let snap: (text: String, matches: [ReviewStore.QueueMatch], session: String)? = DispatchQueue.main.sync {
                guard let it = reviewStore.aiQueue.first(where: { $0.id == id }) else { return nil }
                return (it.text, it.matches, it.refineSession)
            }
            guard let s = snap else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            let v = aiRefineGoal(current: s.text, matches: s.matches, prompt: prompt, resumeSession: s.session)
            guard v.ok else { return "{\"ok\":false,\"error\":\"unavailable\"}" }
            let saved = DispatchQueue.main.sync {
                reviewStore.refineQueueItem(id: id, text: v.text, note: v.note, session: v.session)
            }
            guard saved else { return "{\"ok\":false,\"error\":\"gone\"}" }
            return "{\"ok\":true,\"text\":\(jsonString(v.text)),\"note\":\(jsonString(v.note)),\"session\":\(jsonString(v.session))}"
        }
        // 큐 항목의 다듬기 세션을 터미널에서 `claude --resume`으로 바로 연다. 세션은 앱 cwd에서
        // 생성되므로 같은 cwd로 이동해 이어붙인다. 세션이 아직 없으면(첫 refine 전) 실패한다.
        if path == "/api/goal/queue/cli" {
            let id = (obj["id"] as? String) ?? ""
            guard !id.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
            let session: String? = DispatchQueue.main.sync {
                reviewStore.aiQueue.first(where: { $0.id == id })?.refineSession
            }
            guard let sess = session, !sess.isEmpty else { return "{\"ok\":false,\"error\":\"no-session\"}" }
            guard openClaudeResume(session: sess) else { return "{\"ok\":false,\"error\":\"launch-failed\"}" }
            return "{\"ok\":true,\"session\":\(jsonString(sess))}"
        }
        // Goal-to-goal LINK: promote the source to top-level and record source→target.
        // Separate sanctioned path from setParent (never nests). Custom JSON responses so
        // the client can distinguish self/not-found; hence an early return block, not the
        // default switch. See docs/specs/goal-link-and-generic-queue.md Phase 1.
        if path == "/api/goal/link" {
            let source = (obj["id"] as? String) ?? ""
            let target = (obj["target"] as? String) ?? ""
            guard !source.isEmpty, !target.isEmpty else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            if source == target { return "{\"ok\":false,\"error\":\"self\"}" }
            return DispatchQueue.main.sync {
                let bothExist = reviewStore.goals.contains(where: { $0.id == source })
                    && reviewStore.goals.contains(where: { $0.id == target })
                guard bothExist else { return "{\"ok\":false,\"error\":\"not-found\"}" }
                reviewStore.linkGoal(id: source, to: target)
                return "{\"ok\":true}"
            }
        }
        if path == "/api/goal/unlink" {
            let source = (obj["id"] as? String) ?? ""
            let target = (obj["target"] as? String) ?? ""
            guard !source.isEmpty, !target.isEmpty else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            return DispatchQueue.main.sync {
                guard reviewStore.goals.contains(where: { $0.id == source }) else {
                    return "{\"ok\":false,\"error\":\"not-found\"}"
                }
                reviewStore.unlinkGoal(id: source, from: target)
                return "{\"ok\":true}"
            }
        }
        return DispatchQueue.main.sync {
            let day = reviewStore.todayKey
            switch path {
            case "/api/goal/add":
                if let text = obj["text"] as? String {
                    let sprint = (obj["sprint"] as? NSNumber)?.intValue ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    let bump = (obj["bump"] as? NSNumber)?.boolValue ?? (obj["bump"] as? Bool) ?? false
                    // A direct add lands as a real goal immediately. bump=true parks it in the
                    // Bump out 인박스 (raw idea, 정리 전) at the bottom of the board; bump=false
                    // creates a normal Backlog/Sprint goal. Neither routes through the AI 큐 —
                    // that background dedup pipeline is the AI추가 button's job (queue/enqueue),
                    // not a plain add. This keeps a dumped idea visible where the user put it
                    // instead of disappearing into the queue and resurfacing in Backlog.
                    reviewStore.addGoal(text: text, parent: (obj["parent"] as? String) ?? "",
                                        sprint: sprint, bump: bump)
                }
            case "/api/chat/reset":
                chatStore.reset()
            case "/api/goal/queue/add":
                // "later": park a flagged candidate for one-by-one review instead of
                // adding it now (saves the energy of deciding right away).
                if let text = obj["text"] as? String {
                    let matches = (obj["matches"] as? [[String: Any]])?.map { m in
                        ReviewStore.QueueMatch(seq: (m["seq"] as? NSNumber)?.intValue ?? 0,
                                               text: (m["text"] as? String) ?? "",
                                               why: (m["why"] as? String) ?? "")
                    } ?? []
                    reviewStore.addQueueItem(text: text, parent: (obj["parent"] as? String) ?? "",
                                             note: (obj["note"] as? String) ?? "", matches: matches)
                }
            case "/api/goal/queue/enqueue":
                // "Bump out": instantly park a freshly-dumped candidate as pending and return
                // right away — the user never waits on the AI. The background worker analyzes
                // it and flips it to ready for a one-tap 추가/수정/스킵 decision.
                if let text = obj["text"] as? String {
                    let sprint = (obj["sprint"] as? NSNumber)?.intValue ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    // `search:true` → 찾기만 후보(findOnly): 같은 큐·같은 dedup 분석을 돌리되 결과는
                    // 비슷한 목표를 보여줄 뿐 목표를 만들지 않는다 (AI목표=찾고+만들기, 검색=찾기만).
                    let findOnly = (obj["search"] as? Bool) ?? false
                    // `origin` carries the user's full raw prompt when the client has one
                    // richer than the goal line; the store defaults it to `text` otherwise.
                    if reviewStore.enqueuePending(text: text, parent: (obj["parent"] as? String) ?? "",
                                                  sprint: sprint, origin: obj["origin"] as? String,
                                                  findOnly: findOnly) != nil {
                        kickAIQueueWorker()
                    }
                }
            case "/api/goal/queue/resolve":
                // Resolve one queued candidate: add (promote to goal), task (file as a
                // 부분과제 folder under an existing goal — no new goal number), edit (rewrite
                // text, keep queued), or skip (drop). Every resolution is recorded in the
                // queue history (queue-history.json) so the user can audit / 번복 it.
                if let id = obj["id"] as? String {
                    if (obj["action"] as? String) == "task" {
                        // Recurring-round path: attach the candidate to goal #parentSeq as a
                        // tasks/<taskN> folder instead of minting a new goal (the old behavior
                        // created e.g. goal325 when the user expected a task — see history).
                        let pSeq = (obj["parentSeq"] as? NSNumber)?.intValue
                            ?? Int((obj["parentSeq"] as? String) ?? "") ?? 0
                        guard pSeq > 0, reviewStore.goals.contains(where: { $0.seq == pSeq }),
                              let item = reviewStore.aiQueue.first(where: { $0.id == id }) else {
                            return "{\"ok\":false,\"error\":\"bad-task-target\"}"
                        }
                        guard let folder = addSubtaskFolder(seq: pSeq, title: item.text, status: "",
                                                            coin: "", week: "", outputs: "") else {
                            return "{\"ok\":false,\"error\":\"create-failed\"}"
                        }
                        reviewStore.resolveQueueItemAsTask(id: id, parentSeq: pSeq, taskFolder: folder)
                        return "{\"ok\":true,\"seq\":\(pSeq),\"task\":\(jsonString(folder)),\"asTask\":true}"
                    }
                    // parentSeq contract (must distinguish "key absent" from "explicit 0"):
                    //  - key absent            → sentinel -1 = "no override, accept AI suggestion"
                    //  - present, value 0      → explicit TOP-LEVEL override (ignore AI sub suggestion)
                    //  - present, value > 0    → explicit parent #seq
                    // priority (optional): USER override of the AI-suggested bucket.
                    let hasParentSeq = obj["parentSeq"] != nil && !(obj["parentSeq"] is NSNull)
                    let parentSeq: Int = hasParentSeq
                        ? ((obj["parentSeq"] as? NSNumber)?.intValue ?? Int((obj["parentSeq"] as? String) ?? "") ?? 0)
                        : -1
                    let priority = obj["priority"] as? String
                    let res = reviewStore.resolveQueueItem(id: id, action: (obj["action"] as? String) ?? "skip",
                                                           text: obj["text"] as? String, parentSeq: parentSeq,
                                                           priority: priority)
                    // Return the created goal's #seq plus the EFFECTIVE placement (the parent it
                    // actually attached under, and whether a requested sub-attach fell back to
                    // top-level because it would break the 1-level tree) so the client can show
                    // the right "열기" link / placement note.
                    if let r = res {
                        return "{\"ok\":true,\"seq\":\(r.seq),\"parentSeq\":\(r.parentSeq),"
                            + "\"parentFallback\":\(r.parentFallback)}"
                    }
                }
            case "/api/goal/queue/undo":
                // 번복: revert one queue-history decision. Removes what the decision created
                // (add → the goal, task → the tasks/<taskN> folder while still pristine) and
                // restores the snapshotted candidate to the queue as "ready" for re-review.
                if let hid = obj["id"] as? String {
                    guard let entry = reviewStore.queueHistoryEntry(id: hid), !entry.undone else {
                        return "{\"ok\":false,\"error\":\"not-found\"}"
                    }
                    if entry.action == "add", entry.seq > 0,
                       let g = reviewStore.goals.first(where: { $0.seq == entry.seq }) {
                        // Refuse when the goal grew children since — removeGoal cascades and
                        // would delete work the queue decision never created.
                        if reviewStore.goals.contains(where: { $0.parent == g.id }) {
                            return "{\"ok\":false,\"error\":\"has-children\"}"
                        }
                        var r = reviewStore.review(day)
                        r.notes.removeValue(forKey: g.id); r.contributions.removeValue(forKey: g.id)
                        reviewStore.saveReview(r, day: day)
                        reviewStore.removeGoal(id: g.id)
                        try? FileManager.default.removeItem(at: Self.evidenceDir(goalId: g.id))
                        if let adir = IssuePaths.attachmentsDir(seq: g.seq) {
                            try? FileManager.default.removeItem(at: adir)
                        }
                    }
                    if entry.action == "task", entry.seq > 0, !entry.taskFolder.isEmpty,
                       let tdir = IssuePaths.taskDir(seq: entry.seq, task: entry.taskFolder) {
                        // Only delete while the folder still holds nothing but our _task.md
                        // anchor — never remove files the user added after the decision.
                        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? []
                        if contents.allSatisfy({ $0 == "_task.md" || $0 == ".DS_Store" }) {
                            try? FileManager.default.removeItem(at: tdir)
                        }
                    }
                    if reviewStore.undoQueueDecision(id: hid) != nil { return "{\"ok\":true}" }
                    return "{\"ok\":false,\"error\":\"not-found\"}"
                }
            case "/api/queue/retry":
                // Re-run a failed/finished queue job: clear its error, flip to pending, kick
                // the worker. Used by the 재시도 button on a non-dedup job card.
                if let id = obj["id"] as? String, reviewStore.retryQueueItem(id: id) {
                    kickAIQueueWorker()
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/queue/remove":
                // Drop a finished job card from the queue. Guarded in the store: never removes
                // an item still "analyzing" (the worker holds it).
                if let id = obj["id"] as? String, reviewStore.removeQueueItem(id: id) {
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/queue/enqueue-linkmap":
                // Phase 3: "내보내기" enqueues a background linkmap job scoped to ONE root goal's
                // link chain (fire-and-forget). The worker builds the node-link map + link-aware
                // export off-main and posts the result as a 큐 card. Returns immediately.
                if let root = obj["root"] as? String,
                   let g = reviewStore.goals.first(where: { $0.id == root }) {
                    let title = "내보내기 · goal-\(String(format: "%02d", g.seq))"
                    if let jid = reviewStore.enqueueJob(jobKind: "linkmap", title: title, origin: root) {
                        kickAIQueueWorker()
                        return "{\"ok\":true,\"id\":\(jsonString(jid))}"
                    }
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/goal/remove":
                if let id = obj["id"] as? String {
                    // Clean up notes/contributions for the goal and its children.
                    let removed = Set([id] + reviewStore.goals.filter { $0.parent == id }.map { $0.id })
                    // Capture numbers before removal so we can locate attachment folders after.
                    let removedSeqs = reviewStore.goals.filter { removed.contains($0.id) }.map { $0.seq }
                    var r = reviewStore.review(day)
                    removed.forEach { r.notes.removeValue(forKey: $0); r.contributions.removeValue(forKey: $0) }
                    reviewStore.saveReview(r, day: day)
                    reviewStore.removeGoal(id: id)
                    // Drop attached files for the removed goal(s): the legacy UUID store and
                    // the number-named folder's attachments/. The definition (goal.md) is kept.
                    removed.forEach { try? FileManager.default.removeItem(at: Self.evidenceDir(goalId: $0)) }
                    removedSeqs.forEach { seq in
                        if let dir = IssuePaths.attachmentsDir(seq: seq) {
                            try? FileManager.default.removeItem(at: dir)
                        }
                    }
                }
            case "/api/goal/note":
                if let id = obj["id"] as? String {
                    var r = reviewStore.review(day)
                    r.notes[id] = (obj["note"] as? String) ?? ""
                    reviewStore.saveReview(r, day: day)
                }
            case "/api/goal/parent":
                // Single (id) or bulk (ids) — the board's Cmd-drag fill-down sends a whole
                // column of ids at once so it commits in one save.
                if let ids = obj["ids"] as? [String] {
                    reviewStore.setParent(ids: ids, parent: (obj["parent"] as? String) ?? "")
                } else if let id = obj["id"] as? String {
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
            case "/api/goal/archive":
                // 보관 / 보관 해제 toggle. archived=true stows the goal (and its children)
                // out of the active views into the 아카이브 view; false brings it back.
                if let id = obj["id"] as? String {
                    let archived = (obj["archived"] as? Bool)
                        ?? ((obj["archived"] as? NSNumber)?.boolValue ?? true)
                    reviewStore.setArchived(id: id, archived: archived)
                }
            case "/api/goal/title":
                // Rename a goal from the dashboard. For a session-mirrored goal, also
                // append the new title to its transcript so the session hook honors it
                // over Claude's auto aiTitle (otherwise the next event overwrites it).
                if let id = obj["id"] as? String, let title = obj["title"] as? String {
                    if let g = reviewStore.setGoalTitle(id: id, title: title), !g.sessionId.isEmpty {
                        writeTitleOverride(for: g, title: g.text)
                    }
                }
            case "/api/goal/task":
                // Add a 부분과제 (subtask) under an existing goal (goal-NN/tasks/taskN-…) instead
                // of spawning a brand-new goal — e.g. a 주보상 패키지 becomes a task on goal-130.
                // Called by the goal page's "+ 태스크 추가" form AND directly by an AI so tasks
                // can be filed with or without the user. Auto-numbers taskN and writes a
                // _task.md anchor with whatever metadata was supplied.
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                let title = ((obj["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if seq > 0, !title.isEmpty {
                    if let folder = addSubtaskFolder(
                        seq: seq, title: title,
                        status: (obj["status"] as? String) ?? "",
                        coin: Self.numString(obj["coin"]), week: Self.numString(obj["week"]),
                        outputs: (obj["outputs"] as? String) ?? "") {
                        let id = folder.split(separator: "-").first.map(String.init) ?? folder
                        return "{\"ok\":true,\"seq\":\(seq),\"id\":\(jsonString(id)),\"task\":\(jsonString(folder))}"
                    }
                    return "{\"ok\":false,\"error\":\"create-failed\"}"
                }
                return "{\"ok\":false,\"error\":\"bad-request\"}"
            case "/api/session/event":
                // Driven by Claude Code session hooks (see Scripts/cc-session-hook.sh).
                // event: start | active | idle | end. The goal is keyed by sessionId
                // and auto-created on first event, so no goal id is required.
                if let sid = obj["sessionId"] as? String {
                    let event = (obj["event"] as? String) ?? "start"
                    reviewStore.recordSession(sessionId: sid, event: event,
                                              text: (obj["text"] as? String) ?? "",
                                              transcriptPath: (obj["transcriptPath"] as? String) ?? "",
                                              waitKind: (obj["waitKind"] as? String) ?? "")
                }
            case "/api/goal/connect":
                // Open a native file picker (default: the current Claude session folder)
                // so the user can attach a transcript .jsonl to this goal. Runs async on
                // the next main-loop turn so the HTTP response returns immediately; the
                // dashboard's poll (and the client's follow-up reloads) pick up the link.
                if let id = obj["id"] as? String {
                    DispatchQueue.main.async { [weak self] in self?.connectSessionViaPicker(goalId: id) }
                }
            case "/api/goal/session/link":
                // Attach an extra session id to this goal (the goal page's "세션 연결" picker).
                // A subtask scope is handled off-main in the early return above.
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                reviewStore.linkGoalSession(seq: seq, sessionId: (obj["sessionId"] as? String) ?? "")
            case "/api/goal/session/unlink":
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                reviewStore.unlinkGoalSession(seq: seq, sessionId: (obj["sessionId"] as? String) ?? "")
            case "/api/plugin/connect":
                // Open a native folder picker so the user can attach a project folder to
                // the plugin. Runs async on the next main-loop turn so the HTTP response
                // returns immediately; the dashboard poll picks up the verified result.
                if let id = obj["id"] as? String {
                    DispatchQueue.main.async { [weak self] in self?.connectPluginViaPicker(pluginId: id) }
                }
            case "/api/plugin/disconnect":
                if let id = obj["id"] as? String { pluginStore.disconnect(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/verify":
                if let id = obj["id"] as? String { pluginStore.reverify(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/install":
                // Toggle plugins (e.g. 컨디션 메이트): install IS the connection — no folder.
                if let id = obj["id"] as? String { pluginStore.install(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/uninstall":
                if let id = obj["id"] as? String { pluginStore.uninstall(pluginId: id); syncPluginWorkers() }
            case "/api/goal/energy":
                if let id = obj["id"] as? String, let e = (obj["energy"] as? NSNumber)?.intValue {
                    reviewStore.setEnergy(id: id, energy: e)
                }
            case "/api/goal/agents":
                if let id = obj["id"] as? String {
                    // Accept either a pre-split array or a comma/space-separated string.
                    let list: [String]
                    if let arr = obj["agents"] as? [String] {
                        list = arr
                    } else if let s = obj["agents"] as? String {
                        list = s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    } else {
                        list = []
                    }
                    reviewStore.setAgents(id: id, agents: list)
                }
            case "/api/goal/tokens":
                if let id = obj["id"] as? String, let t = (obj["tokens"] as? NSNumber)?.intValue {
                    reviewStore.setTokens(id: id, tokens: t)
                }
            case "/api/goal/value":
                if let id = obj["id"] as? String, let v = (obj["value"] as? NSNumber)?.intValue {
                    reviewStore.setValue(id: id, value: v)
                }
            case "/api/goal/priority":
                // Set 5-level priority. Accepts a batch ("ids":[...]) from the board's
                // Cmd-drag paint, or a single "id" from the click picker.
                if let p = obj["priority"] as? String {
                    if let ids = obj["ids"] as? [String] {
                        reviewStore.setGoalPriority(ids: ids, priority: p)
                    } else if let id = obj["id"] as? String {
                        reviewStore.setGoalPriority(ids: [id], priority: p)
                    }
                }
            case "/api/goal/target":
                // Set/clear the planned target datetime (epoch seconds; 0/absent = clear).
                if let id = obj["id"] as? String {
                    reviewStore.setTargetAt(id: id, date: Self.parseEpoch(obj["target"]))
                }
            case "/api/goal/completed":
                // Manually set/clear the completion datetime, overriding the auto-stamp.
                if let id = obj["id"] as? String {
                    reviewStore.setCompletedAt(id: id, date: Self.parseEpoch(obj["completed"]))
                }
            case "/api/goal/sprint":
                // Assign a goal's sprint number (0/absent = clear -> backlog).
                if let id = obj["id"] as? String {
                    let n = (obj["sprint"] as? NSNumber)?.intValue
                        ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    reviewStore.setGoalSprint(id: id, sprint: n)
                }
            case "/api/goal/bump":
                // Move a numbered goal into (bump=true) or out of (bump=false) the Bump out
                // 인박스. The goal keeps its unique seq either way, so demotion is safe.
                if let id = obj["id"] as? String {
                    let bump = (obj["bump"] as? NSNumber)?.boolValue ?? (obj["bump"] as? Bool) ?? false
                    reviewStore.setGoalBump(id: id, bump: bump)
                }
            case "/api/sprint/create":
                reviewStore.createSprint(goalText: (obj["goalText"] as? String) ?? "",
                                         durationKind: (obj["durationKind"] as? String) ?? "1d")
            case "/api/sprint/update":
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    // Date args use Date?? semantics: key absent = leave alone; present = set/clear.
                    let startAt: Date?? = obj.keys.contains("startAt") ? Optional(Self.parseEpoch(obj["startAt"])) : nil
                    let targetAt: Date?? = obj.keys.contains("targetAt") ? Optional(Self.parseEpoch(obj["targetAt"])) : nil
                    reviewStore.updateSprint(number: n,
                                             goalText: obj["goalText"] as? String,
                                             durationKind: obj["durationKind"] as? String,
                                             startAt: startAt, targetAt: targetAt)
                }
            case "/api/sprint/delete":
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    reviewStore.deleteSprint(number: n)
                }
            case "/api/sprint/release":
                // Commit the finished work of a sprint. sprint "all"/absent = across all
                // sprints; otherwise the given number. Done+unreleased goals are snapshotted.
                let sprint: Int?
                if let s = obj["sprint"] as? String, s == "all" { sprint = nil }
                else if let n = (obj["sprint"] as? NSNumber)?.intValue { sprint = n }
                else if let s = obj["sprint"] as? String, let n = Int(s) { sprint = n }
                else { sprint = nil }
                reviewStore.releaseSprint(sprint)
            case "/api/sprint/complete":
                // Complete a sprint and roll forward: commit done goals, carry unfinished
                // ones into a fresh successor (auto 24h), close the old one, advance the code.
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    reviewStore.completeSprint(n)
                }
            case "/api/release/restore":
                // Bring a release's committed goals back into the active list.
                if let id = obj["id"] as? String {
                    reviewStore.restoreRelease(id: id)
                }
            case "/api/goal/evidence/add":
                // A subtask scope (task set) has no Goal: write the uploaded file straight
                // into its own attachments/ folder. The link kind is goal-only.
                let evScope = Scope.from(body: obj)
                if evScope.task != nil {
                    if (obj["kind"] as? String) == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL), let dir = evScope.attachmentsDir {
                        let name = Self.sanitizeFilename((obj["filename"] as? String) ?? "file")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? raw.write(to: dir.appendingPathComponent(name), options: .atomic)
                    }
                } else if let id = obj["id"] as? String {
                    let kind = (obj["kind"] as? String) ?? "link"
                    if kind == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL) {
                        // Copy the upload into the goal's number-named folder
                        // (.issue/goal-NN/attachments); fall back to the legacy
                        // UUID-keyed store when the goal has no number yet (seq <= 0).
                        let name = Self.sanitizeFilename((obj["filename"] as? String) ?? "file")
                        let evId = UUID().uuidString
                        let dir = attachmentsDir(forGoalId: id) ?? Self.evidenceDir(goalId: id)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        // Prefix with the evidence id so duplicate file names never collide.
                        let stored = evId + "-" + name
                        if (try? raw.write(to: dir.appendingPathComponent(stored), options: .atomic)) != nil {
                            _ = reviewStore.addEvidence(goalId: id, kind: "file", title: name,
                                                        filename: stored)
                        }
                    } else if kind == "link", let url = obj["url"] as? String {
                        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !u.isEmpty {
                            let raw = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let title = (raw?.isEmpty == false) ? raw! : u
                            _ = reviewStore.addEvidence(goalId: id, kind: "link", title: title, url: u)
                        }
                    }
                }
            case "/api/goal/evidence/remove":
                // A subtask removes the named file from its attachments/ folder (the client
                // passes the bare filename as evidenceId for task scope).
                let rmScope = Scope.from(body: obj)
                if rmScope.task != nil {
                    if let name = obj["evidenceId"] as? String, let dir = rmScope.attachmentsDir {
                        let safe = Self.sanitizeFilename(name)
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe))
                    }
                } else if let id = obj["id"] as? String, let evId = obj["evidenceId"] as? String {
                    if let removed = reviewStore.removeEvidence(goalId: id, evidenceId: evId),
                       removed.kind == "file" {
                        // Remove from whichever store holds it (new number-named folder
                        // and/or the legacy UUID store).
                        if let dir = attachmentsDir(forGoalId: id) {
                            try? FileManager.default.removeItem(at: dir.appendingPathComponent(removed.filename))
                        }
                        try? FileManager.default.removeItem(
                            at: Self.evidenceDir(goalId: id).appendingPathComponent(removed.filename))
                    }
                }
            case "/api/review":
                var r = reviewStore.review(day)
                if let s = (obj["selfScore"] as? NSNumber)?.intValue { r.selfScore = s }
                if let c = obj["contributions"] as? [String: Any] {
                    r.contributions = c.compactMapValues { ($0 as? NSNumber)?.intValue }
                }
                r.submittedSelf = true
                reviewStore.saveReview(r, day: day)
            case "/api/worker/ping":
                // External workers (e.g. the QA agent launched by launchd) report a run
                // here so the dashboard's 워커 상태 row reflects reality. recordRun/Error
                // both no-op for an unregistered id, so only declared workers count.
                //   status "error" -> red 오류 badge + error-level log line
                //   anything else  -> clear any error, stamp a healthy run + log line
                if let id = obj["id"] as? String {
                    let status = (obj["status"] as? String) ?? "ok"
                    let why = (obj["why"] as? String) ?? "외부 워커 보고"
                    let effect = (obj["effect"] as? String) ?? ""
                    if status == "error" {
                        WorkerRegistry.shared.recordError(id, why: why, detail: effect)
                    } else if status == "start" {
                        // In-progress signal: log only, no run-count bump. Lets a slow AI
                        // pass show activity immediately instead of looking idle until the
                        // result lands a minute or two later.
                        WorkerLog.shared.append(id, why: why, effect: effect)
                    } else {
                        WorkerRegistry.shared.clearError(id)
                        WorkerRegistry.shared.recordRun(id, why: why, effect: effect)
                    }
                }
            case "/api/worker/toggle":
                // User on/off for a toggleable QA worker. Writes the matching *-disabled
                // flag that the runner scripts read, and mirrors the state on the registry
                // so the row shows 꺼짐 immediately. Only the two QA workers are toggleable.
                if let id = obj["id"] as? String,
                   let flag = ["qa-agent": Self.qaDisabledFlag, "qa-fix": Self.qaFixDisabledFlag,
                               "bug-hunt": Self.bugHuntDisabledFlag][id] {
                    let name = ["qa-fix": "QA 수정", "bug-hunt": "버그 헌트"][id] ?? "QA 점검"
                    let enabled = (obj["enabled"] as? Bool) ?? ((obj["enabled"] as? NSNumber)?.boolValue ?? false)
                    WorkerRegistry.shared.setEnabled(id, enabled)
                    if enabled {
                        try? FileManager.default.removeItem(at: flag)
                        WorkerLog.shared.append(id, why: "사용자 토글", effect: "\(name) 켜짐")
                    } else {
                        try? Data().write(to: flag)
                        WorkerLog.shared.append(id, why: "사용자 토글", effect: "\(name) 꺼짐")
                    }
                }
            case "/api/qa-audit":
                // The dashboard's self-audit (deterministic UI overflow/wrapping check)
                // pushes its result here on every render. Persist the raw JSON so the QA
                // runner reads exactly what a real viewport measured — no headless height
                // cutoff, no screenshot-vision guesswork. Latest write wins.
                try? Data(body.utf8).write(to: Self.qaAuditFile, options: .atomic)
            case "/api/worker/run":
                // "즉시 실행": force one scan now, bypassing the gates (even when OFF).
                if (obj["id"] as? String) == "qa-agent" {
                    WorkerLog.shared.append("qa-agent", why: "사용자 즉시 실행",
                        effect: "1회 강제 스캔 시작 — 결과·토큰은 보통 1~2분 뒤 기록됩니다")
                    triggerQARunNow()
                }
            case "/api/prefs/view":
                // Remember the last-open dashboard view so the next launch reopens to it.
                if let v = obj["view"] as? String { Settings.shared.lastView = v }
            case "/api/prefs/donecutoff":
                // Persist the 완료 컷오프 so it survives an app restart (the dynamic
                // port resets the URL-hash store). 0 = 해제(show all); >0 = epoch cutoff.
                if let n = (obj["dc"] as? NSNumber)?.doubleValue, n >= 0 {
                    Settings.shared.doneCutoff = n
                }
            case "/api/prefs/ui":
                // Persist the dashboard UI layout (보기 상태 필터 · 상위 항상 표시 · 스프린트
                // 선택 · 접기/펼치기) so it survives an app restart. The client sends its
                // already-serialized prefs JSON in `data`; store it verbatim and re-inject
                // it on the next launch. An empty/missing value clears the saved layout.
                if let s = obj["data"] as? String, !s.isEmpty {
                    Settings.shared.uiPrefs = s
                } else {
                    Settings.shared.uiPrefs = nil
                }
            case "/api/duck":
                // Dashboard is about to play a UI sound effect; duck the BGM under it.
                audio.duck()
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

    // Parse a client-sent datetime: a positive epoch-seconds number => Date;
    // 0, an empty/zero string, or an absent value => nil (clear the field).
    private static func parseEpoch(_ v: Any?) -> Date? {
        if let n = (v as? NSNumber)?.doubleValue, n > 0 { return Date(timeIntervalSince1970: n) }
        if let s = v as? String, let n = Double(s), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }

    // MARK: AI dedup (AI추가)

    // Runs an external `claude -p` pass to judge whether `text` duplicates an existing
    // goal. BLOCKING (seconds) — call OFF the main thread (see handlePost). Returns a JSON
    // string the dashboard consumes:
    //   {"ok":true,"duplicate":<bool>,"matches":[{"seq":N,"text":"…","why":"…"}],"note":"…"}
    // On any failure it returns {"ok":false,"error":"…"} so the client falls back to a
    // plain add (the AI pass is best-effort, never a hard gate).
    // MARK: AI dedup queue worker (the "bump out" background drainer)

    // Single in-flight guard, owned by main. The worker is strictly sequential: one
    // `claude -p` at a time, so CPU/token pressure stays low and the user's dump is instant.
    private var aiWorkerRunning = false
    private let aiWorkerQueue = DispatchQueue(label: "condition.ai-queue.worker")

    // Wake the worker if it is idle. Safe to call from anywhere (hops to main to check the
    // guard). No-ops when a drain is already running — that drain will pick up new items.
    func kickAIQueueWorker() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.aiWorkerRunning else { return }
            self.aiWorkerRunning = true
            self.aiWorkerQueue.async { [weak self] in self?.drainAIQueue() }
        }
    }

    // Drain loop: claim the oldest pending item (main), analyze it off-main (blocking),
    // record the verdict (main), repeat until none remain. The guard is released inside the
    // same main hop that finds the queue empty, so a concurrent enqueue can never be lost.
    private func drainAIQueue() {
        while true {
            let item: ReviewStore.AIQueueItem? = DispatchQueue.main.sync {
                if let it = self.reviewStore.claimNextPending() { return it }
                self.aiWorkerRunning = false   // queue drained: release the guard atomically
                return nil
            }
            guard let item = item else { break }
            // Branch on the generalized jobKind. Legacy items decode jobKind=="dedup" and take
            // the UNCHANGED dedup path below. Non-dedup jobs run a per-kind runner and complete
            // via completeJob. The worker stays single-serial (one item at a time).
            if item.jobKind != "dedup" {
                let (html, err) = runQueueJob(item)
                DispatchQueue.main.sync {
                    self.reviewStore.completeJob(id: item.id, resultHTML: html, error: err)
                }
                continue
            }
            let v = aiDedupVerdict(text: item.text, origin: item.originPrompt)
            // ok=false (claude missing / spawn / parse failure) is NOT a gate: surface the
            // candidate as a clean, non-duplicate verdict so it still reaches the user for a
            // one-tap decision instead of getting stuck mid-queue.
            DispatchQueue.main.sync {
                self.reviewStore.completeAnalysis(id: item.id, duplicate: v.duplicate, kind: v.kind,
                                                  note: v.ok ? v.note : "", matches: v.matches,
                                                  placement: v.placement, suggestedParentSeq: v.suggestedParentSeq,
                                                  priority: v.priority, confidence: v.confidence,
                                                  rationale: v.ok ? v.rationale : "")
            }
        }
    }

    // Per-kind runner hook for non-dedup queue jobs. Runs OFF main (called from drainAIQueue).
    // Returns (resultHTML, error); a non-empty error surfaces a 재시도 button on the card.
    // Phase 2 has no non-dedup producers yet — every kind is a stub that reports "not
    // implemented". Phase 3 will supply the "linkmap" runner here (build map + export HTML).
    private func runQueueJob(_ item: ReviewStore.AIQueueItem) -> (html: String, error: String) {
        switch item.jobKind {
        case "linkmap": return runLinkmapJob(item)   // Phase 3: node-link map + link-aware export
        default:
            return ("", "아직 지원하지 않는 작업 종류입니다: \(item.jobKind)")
        }
    }

    // ---- Phase 3: linkmap / export job -------------------------------------------------
    // A flattened goal snapshot the linkmap walker uses off-main (no store access after this).
    private struct LinkmapNode {
        let id: String; let seq: Int; let text: String; let parent: String
        let status: String; let links: [String]
    }

    // Runs OFF main (invoked from drainAIQueue's non-dedup branch). Snapshots goals on main,
    // walks the SINGLE root goal's link chain (parent-children + links, recursive, cycle-safe
    // via a visited-set keyed by goal id), builds the node-link MAP HTML (solid edges =
    // parent-child, purple dashed edges = links, plus a summary), builds a link-aware compressed
    // export, and returns the combined HTML. No claude -p is needed (the export is a deterministic
    // Markdown fold, so we avoid the LLM round-trip entirely).
    private func runLinkmapJob(_ item: ReviewStore.AIQueueItem) -> (html: String, error: String) {
        let rootId = item.originPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootId.isEmpty else { return ("", "내보내기 대상(root) goal이 지정되지 않았습니다.") }
        // (a) Snapshot goals on main — thread-safe store access, like aiDedupVerdict.
        let snapshot: [LinkmapNode] = DispatchQueue.main.sync {
            reviewStore.goals.map { LinkmapNode(id: $0.id, seq: $0.seq, text: $0.text,
                                                parent: $0.parent, status: $0.status, links: $0.links) }
        }
        let byId = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let root = byId[rootId] else { return ("", "root goal을 찾을 수 없습니다: \(rootId)") }

        // (b) Walk the chain from root with a visited-set. `order` is the include order (root
        // first, then its parent-children, then its links, recursively). `edges` records every
        // parent-child (solid) and link (dashed) edge for the map. `linkHops` counts followed
        // link edges; `dupWarnings` records edges pointing at an already-visited node (a cycle
        // or a fan-in) so the summary can surface them instead of the walk looping forever.
        var visited = Set<String>()
        var order: [String] = []
        var edges: [(from: String, to: String, kind: String)] = []   // kind: "child" | "link"
        var linkHops = 0
        var dupWarnings: [String] = []

        // Iterative DFS keyed by goal id — the visited-set makes a link cycle (01→233→…→01)
        // terminate: the second time we reach 01 it is already visited, so we record a cycle
        // warning and do NOT recurse again. Each goal is emitted into `order` exactly once.
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        func visit(_ id: String) {
            guard let node = byId[id] else { return }
            if visited.contains(id) { return }
            visited.insert(id)
            order.append(id)
            // Parent-children first (solid edges), in seq order for a stable map.
            let kids = snapshot.filter { $0.parent == id }.sorted { $0.seq < $1.seq }
            for k in kids {
                edges.append((from: id, to: k.id, kind: "child"))
                if visited.contains(k.id) {
                    dupWarnings.append("\(label(node)) → \(label(k)) (이미 포함됨)")
                } else {
                    visit(k.id)
                }
            }
            // Then links (purple dashed edges), directional source → target.
            for tgt in node.links {
                guard let tnode = byId[tgt] else { continue }
                edges.append((from: id, to: tgt, kind: "link"))
                linkHops += 1
                if visited.contains(tgt) {
                    dupWarnings.append("\(label(node)) ↗ \(label(tnode)) (링크 순환/중복)")
                } else {
                    visit(tgt)
                }
            }
        }
        visit(rootId)

        // (c) Build the node-link MAP as a self-contained inline HTML/SVG fragment.
        let mapHTML = buildLinkmapMapHTML(order: order, edges: edges, byId: byId,
                                          root: root, linkHops: linkHops, dupWarnings: dupWarnings)
        // (d) Build the compressed export markdown (link-aware, same visited order).
        let exportMD = buildLinkmapExportMarkdown(order: order, byId: byId, root: root)
        // Render markdown into a simple <pre> block (deterministic; no LLM). The card's 다운로드
        // grabs this whole resultHTML.
        let exportHTML = "<h3 style=\"margin:14px 0 6px;font:600 14px system-ui\">압축 내보내기</h3>"
            + "<pre style=\"white-space:pre-wrap;font:12px/1.5 ui-monospace,Menlo,monospace;background:#0d1016;color:#c8d0de;padding:12px;border-radius:8px;overflow-x:auto\">"
            + escapeHTML(exportMD) + "</pre>"
        let full = "<div style=\"font:13px system-ui;color:#c8d0de\">" + mapHTML + exportHTML + "</div>"
        return (full, "")
    }

    // Minimal HTML-escape for embedding text into the result fragment.
    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    // The APPROVED map design: nodes = rounded goal boxes stacked vertically; SOLID connectors =
    // parent-child; PURPLE DASHED connectors = links; a summary block on top with included count,
    // link hops, and any duplicate/cycle warnings. Compact inline SVG (no external assets).
    private func buildLinkmapMapHTML(order: [String], edges: [(from: String, to: String, kind: String)],
                                     byId: [String: LinkmapNode], root: LinkmapNode,
                                     linkHops: Int, dupWarnings: [String]) -> String {
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        // Layout: one row per included goal. y is the node's vertical center; x is fixed.
        let rowH = 54.0, boxW = 300.0, boxH = 34.0, padX = 24.0, padTop = 20.0
        let width = boxW + padX * 2 + 40   // room for the link arcs on the right
        let height = padTop * 2 + Double(order.count) * rowH
        var yOf: [String: Double] = [:]
        for (i, id) in order.enumerated() { yOf[id] = padTop + Double(i) * rowH + boxH / 2 }
        let boxX = padX
        var svg = "<svg viewBox=\"0 0 \(Int(width)) \(Int(height))\" width=\"100%\" style=\"max-width:\(Int(width))px\" xmlns=\"http://www.w3.org/2000/svg\">"
        // Edges first (under the nodes).
        for e in edges {
            guard let y1 = yOf[e.from], let y2 = yOf[e.to] else { continue }
            if e.kind == "child" {
                // Solid parent-child connector: down the left gutter.
                let gx = boxX - 8
                svg += "<path d=\"M \(gx) \(y1) L \(gx) \(y2) L \(boxX) \(y2)\" fill=\"none\" stroke=\"#5b8cff\" stroke-width=\"2\"/>"
            } else {
                // Purple DASHED link connector: an arc down the right side.
                let rx = boxX + boxW + 8
                let mx = rx + 24
                svg += "<path d=\"M \(rx) \(y1) C \(mx) \(y1), \(mx) \(y2), \(rx) \(y2)\" fill=\"none\" stroke=\"#9b7bff\" stroke-width=\"2\" stroke-dasharray=\"5 4\"/>"
                svg += "<polygon points=\"\(rx-6),\(y2-4) \(rx),\(y2) \(rx-6),\(y2+4)\" fill=\"#9b7bff\"/>"
            }
        }
        // Nodes.
        let statusColor: [String: String] = ["done": "#36c08a", "in_progress": "#9be3fb"]
        for id in order {
            guard let n = byId[id], let cy = yOf[id] else { continue }
            let y = cy - boxH / 2
            let isRoot = (id == root.id)
            let stroke = isRoot ? "#e8c15a" : "#2b3242"
            let sw = isRoot ? "2" : "1"
            let dot = statusColor[n.status] ?? "#6b7486"
            svg += "<rect x=\"\(boxX)\" y=\"\(y)\" width=\"\(Int(boxW))\" height=\"\(Int(boxH))\" rx=\"8\" fill=\"#161a22\" stroke=\"\(stroke)\" stroke-width=\"\(sw)\"/>"
            svg += "<circle cx=\"\(boxX+16)\" cy=\"\(cy)\" r=\"5\" fill=\"\(dot)\"/>"
            let tag = label(n)
            let title = n.text.count > 34 ? String(n.text.prefix(33)) + "…" : n.text
            svg += "<text x=\"\(boxX+30)\" y=\"\(cy+4)\" font-family=\"system-ui\" font-size=\"12\" fill=\"#c8d0de\">"
            svg += "<tspan fill=\"#8b93a7\">\(tag)</tspan>  \(escapeHTML(title))</text>"
        }
        svg += "</svg>"
        // Summary block.
        let warn = dupWarnings.isEmpty
            ? "<span style=\"color:var(--green,#36c08a)\">순환/중복 없음</span>"
            : "<span style=\"color:#e0a458\">경고 \(dupWarnings.count)건: " + escapeHTML(dupWarnings.joined(separator: " · ")) + "</span>"
        let summary = "<div style=\"font:12px system-ui;color:#8b93a7;margin:2px 0 10px;line-height:1.6\">"
            + "루트 <b style=\"color:#c8d0de\">\(label(root))</b> · 포함 <b style=\"color:#c8d0de\">\(order.count)</b>개 · 링크 홉 <b style=\"color:#c8d0de\">\(linkHops)</b> · " + warn
            + "<br><span style=\"color:#5b8cff\">━</span> 부모-자식 &nbsp; <span style=\"color:#9b7bff\">┈┈▸</span> 링크</div>"
        return "<h3 style=\"margin:0 0 6px;font:600 14px system-ui\">노드-링크 지도</h3>" + summary
            + "<div style=\"overflow-x:auto\">" + svg + "</div>"
    }

    // Link-aware compressed export: emits each included goal once in visited order. Parent-child
    // children are listed as bullets under their top goal; linked goals get their own section
    // marked "↗ goal-NN (링크됨)". Same visited order guarantees no goal is emitted twice.
    private func buildLinkmapExportMarkdown(order: [String], byId: [String: LinkmapNode], root: LinkmapNode) -> String {
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        func statusTag(_ s: String) -> String {
            s == "done" ? " (완료)" : (s == "in_progress" ? " (진행)" : "")
        }
        var out = "# 내보내기 · \(label(root)) 링크 체인\n\n"
        var emittedAsChild = Set<String>()   // ids already printed as a bullet child
        for id in order {
            guard let n = byId[id] else { continue }
            if emittedAsChild.contains(id) { continue }
            // A linked (non-root, promoted) goal is marked; the root and structural tops are plain.
            if id != root.id && byId.values.contains(where: { $0.links.contains(id) }) {
                out += "## ↗ \(label(n)) (링크됨) — \(n.text)\(statusTag(n.status))\n"
            } else {
                out += "## \(label(n)) — \(n.text)\(statusTag(n.status))\n"
            }
            // Its parent-children (only those in the visited order) as bullets.
            let kids = order.compactMap { byId[$0] }.filter { $0.parent == id }.sorted { $0.seq < $1.seq }
            for k in kids {
                out += "- \(label(k)) \(k.text)\(statusTag(k.status))\n"
                emittedAsChild.insert(k.id)
            }
            out += "\n"
        }
        return out
    }

    // Verdict from the dedup judge. ok=false means the check could not run (no claude,
    // spawn/parse failure) — callers treat that as "not a duplicate" (best-effort gate).
    // `kind` ∈ {new, recurring, duplicate}: recurring = repeats/continues an existing goal's
    // work (nest under it); duplicate = same goal, nothing new (skip). `duplicate` stays true
    // for BOTH overlap kinds so the "유사 목표 있음" flag is unchanged. Default "new" lets the
    // best-effort early-return failures (ok:false) omit it.
    // The judge verdict. Two orthogonal axes:
    //   dedup axis   - duplicate/kind/matches: does this overlap an existing goal?
    //   placement axis (Option D) - placement/suggestedParentSeq/priority/confidence/rationale:
    //                  WHERE should the promoted goal land? These are advisory; the user can
    //                  override every one at resolve time.
    struct DedupVerdict {
        var ok: Bool
        var duplicate: Bool
        var note: String
        var matches: [ReviewStore.QueueMatch]
        var kind: String = "new"
        var placement: String = "top"       // "top" | "sub"
        var suggestedParentSeq: Int = 0      // parent #seq when placement=="sub" (0 otherwise)
        var priority: String = "medium"      // urgent | high | medium | low | lowest
        var confidence: Double = 0           // 0.0...1.0
        var rationale: String = ""           // short Korean placement reason
    }

    // Core dedup judge shared by the synchronous /api/goal/aiAdd route and the background
    // queue worker. Runs an external `claude -p` (seconds, BLOCKING) — call OFF main.
    private func aiDedupVerdict(text: String, origin: String = "") -> DedupVerdict {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        // Snapshot existing goals (brief hop to main for thread-safe store access).
        let snapshot: [(seq: Int, text: String, status: String, transcriptPath: String)] = DispatchQueue.main.sync {
            reviewStore.goals.map { (seq: $0.seq, text: $0.text, status: $0.status, transcriptPath: $0.transcriptPath) }
        }
        guard let claude = Self.resolveClaude() else {
            return DedupVerdict(ok: false, duplicate: false, note: "", matches: [])
        }
        // Retrieval BEFORE the judge: mine the raw prompt for keywords + a time window and
        // search session transcripts and goal files, so work buried inside a goal whose
        // TITLE never mentions it (the goal-130 "NSS 리포트" case) still becomes a candidate.
        let signalSource = origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? candidate : origin
        let signals = RelatedGoalSearch.signals(from: signalSource)
        let goalRefs = snapshot.map { RelatedGoalSearch.GoalRef(seq: $0.seq, title: $0.text, transcriptPath: $0.transcriptPath) }
        let hits = RelatedGoalSearch.discover(signals: signals, goals: goalRefs, issueRoot: IssuePaths.root)
        // Build the prompt: existing goals (skip cancelled) + the candidate; demand strict JSON.
        let listText = snapshot.filter { $0.status != "cancelled" }
            .map { "#\($0.seq) \($0.text)" }.joined(separator: "\n")
        // High-priority candidates surfaced by the search, with the matched evidence so the
        // judge can see WHY they relate even when the title looks unrelated. Skip cancelled.
        let titleBySeq = Dictionary(snapshot.map { ($0.seq, $0.text) }, uniquingKeysWith: { a, _ in a })
        let cancelled = Set(snapshot.filter { $0.status == "cancelled" }.map { $0.seq })
        let relatedLines = hits.filter { !cancelled.contains($0.seq) }.prefix(8).map { h -> String in
            let title = (titleBySeq[h.seq] ?? "").isEmpty ? "(제목 없음)" : titleBySeq[h.seq]!
            return "#\(h.seq) \(title) — [\(h.source)] \"\(h.snippet)\""
        }
        // Reframes the judge: a plain title match asks "same intent?" and misses recurring
        // work (a goal titled "주보상패키지 지급" that in fact holds the NSS report script the
        // user wants to run again). This tells the judge the surfaced goal ALREADY CONTAINS
        // the prior work the new goal reuses, so a "repeat/continuation" is RECURRING (nest
        // under it), which is distinct from a pointless DUPLICATE (skip).
        let relatedText = relatedLines.isEmpty ? "" : """


        ALREADY-EXISTS EVIDENCE — a keyword/time search over the user's own session transcripts \
        and goal files found that the EXISTING goal(s) below ALREADY CONTAIN the prior work (the \
        script, earlier reports, or subtasks) that this NEW goal refers to. When the new goal is \
        phrased as repeating or reusing earlier work ("일일/매일/주간", "N일전에 만든 스크립트로 다시", \
        "동일하게", "그때 만든 것으로"), it is NOT a genuinely new goal — but it is also NOT a \
        pointless duplicate: it is a RECURRING run/subtask of that existing goal's work and is \
        worth tracking. In that case set "kind": "recurring" and put that goal in "matches" (even \
        if its title looks unrelated); "why" should say it repeats/continues that goal's work. \
        Reserve "kind": "duplicate" for when the SAME goal already fully covers this with nothing \
        left to do.
        \(relatedLines.joined(separator: "\n"))
        """
        let prompt = """
        You are a triage judge for a personal goal tracker. Classify a NEW goal against the \
        EXISTING goals into exactly one of three kinds:
        - "new": a genuinely new goal with no meaningful overlap.
        - "recurring": repeats or continues the work of an existing goal (a routine, another \
        daily/weekly run, or a subtask of it) — worth adding as a run UNDER that goal.
        - "duplicate": the same goal already exists and re-adding it accomplishes nothing.

        Then, ORTHOGONALLY, decide WHERE the goal should be placed:
        - "placement": "top" for a stand-alone task or a brand-new parent goal; "sub" for a \
        goal that clearly belongs UNDER an existing goal as a child/subtask.
        - "suggestedParentSeq": when placement is "sub", the #seq of the parent goal it should \
        nest under (0 when placement is "top"). Only suggest a TOP-LEVEL existing goal as parent.
        - "priority": one of "urgent" | "high" | "medium" | "low" | "lowest" — your best guess \
        at how important/time-sensitive this goal is (the user may override).
        - "confidence": a number 0.0..1.0 for how sure you are about the placement.
        - "rationale": one short Korean sentence explaining the placement decision.
        A "recurring" goal is almost always placement "sub" under matches[0]. A "new" goal is \
        usually placement "top" unless it is obviously a subtask of an existing goal.

        EXISTING GOALS (one per line as "#<seq> <title>"):
        \(listText.isEmpty ? "(none)" : listText)\(relatedText)

        NEW GOAL:
        \(candidate)

        Respond with ONLY a single JSON object, no prose, no code fences:
        {"kind": "new" | "recurring" | "duplicate", "matches": [{"seq": <int of an existing goal>, "why": "<short reason in Korean>"}], "note": "<one short Korean sentence>", "placement": "top" | "sub", "suggestedParentSeq": <int>, "priority": "urgent"|"high"|"medium"|"low"|"lowest", "confidence": <0.0..1.0>, "rationale": "<short Korean sentence>"}
        For "recurring" and "duplicate", "matches" MUST list the related goal(s); the first is \
        the one to nest under. Use "new" with an empty "matches" array when it is genuinely new.
        """
        // Spawn via a login shell so PATH/node resolve like the user's terminal; feed the
        // prompt on stdin to dodge arg-length and quoting pitfalls.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        // Watchdog: never let a hung model wedge the connection thread.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        // Extract the first {...} block and parse it.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
        else { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        let note = (parsed["note"] as? String) ?? ""
        // Enrich each match with the existing goal's current title (snapshot lookup).
        let bySeq = Dictionary(snapshot.map { ($0.seq, $0.text) }, uniquingKeysWith: { a, _ in a })
        let rawMatches = (parsed["matches"] as? [[String: Any]]) ?? []
        let matches: [ReviewStore.QueueMatch] = rawMatches.compactMap { m in
            guard let seq = (m["seq"] as? NSNumber)?.intValue, let gtext = bySeq[seq] else { return nil }
            return ReviewStore.QueueMatch(seq: seq, text: gtext, why: (m["why"] as? String) ?? "")
        }
        // Read the 3-way kind; fall back to the legacy boolean when an older model omits it.
        let legacyDup = (parsed["duplicate"] as? Bool) ?? false
        var kind = (parsed["kind"] as? String)?.lowercased() ?? ""
        if !["new", "recurring", "duplicate"].contains(kind) { kind = legacyDup ? "duplicate" : "new" }
        // recurring/duplicate need a concrete goal to act on; without one, treat as new.
        if kind != "new" && matches.isEmpty { kind = "new" }
        // `duplicate` flag stays true for BOTH overlap kinds (drives the "유사 목표 있음" line).
        let dupFinal = kind != "new"

        // Parse the ORTHOGONAL placement axis (Option D). All fields are advisory and
        // defensively defaulted so an older model omitting them yields a sane "top" verdict.
        var placement = (parsed["placement"] as? String)?.lowercased() ?? "top"
        if placement != "sub" { placement = "top" }
        // Suggested parent #seq must reference a live (existing) goal that is TOP-LEVEL; the
        // ReviewStore setParent guard enforces this again at promotion, but validate here so a
        // hallucinated / non-top-level #seq degrades cleanly to a top-level suggestion.
        var suggestedParentSeq = (parsed["suggestedParentSeq"] as? NSNumber)?.intValue ?? 0
        if suggestedParentSeq > 0 {
            let known = Set(snapshot.map { $0.seq })
            if !known.contains(suggestedParentSeq) { suggestedParentSeq = 0 }
        }
        // A "sub" placement with no usable parent is meaningless → fall back to "top".
        if placement == "sub" {
            // Prefer the model's explicit suggestion; else nest under the first dedup match.
            if suggestedParentSeq == 0 { suggestedParentSeq = matches.first?.seq ?? 0 }
            if suggestedParentSeq == 0 { placement = "top" }
        }
        var priority = (parsed["priority"] as? String)?.lowercased() ?? "medium"
        if !ReviewStore.validPriorities.contains(priority) { priority = "medium" }
        let confidence = max(0, min(1, (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0))
        let rationale = (parsed["rationale"] as? String) ?? ""

        return DedupVerdict(ok: true, duplicate: dupFinal, note: note, matches: matches, kind: kind,
                            placement: placement, suggestedParentSeq: suggestedParentSeq,
                            priority: priority, confidence: confidence, rationale: rationale)
    }

    // Synchronous /api/goal/aiAdd: returns the verdict as JSON (kept for any direct caller).
    private func aiDuplicateCheck(text: String, parent: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        let v = aiDedupVerdict(text: t)
        guard v.ok else { return "{\"ok\":false,\"error\":\"unavailable\"}" }
        let matches = v.matches.map {
            "{\"seq\":\($0.seq),\"text\":\(jsonString($0.text)),\"why\":\(jsonString($0.why))}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"duplicate\":\(v.duplicate),\"matches\":[\(matches)],\"note\":\(jsonString(v.note))}"
    }

    // Prompt-refine a single queued goal as a CONTINUING conversation. The refine loop
    // (프롬프트 → 생성 → 새 결과 → 다시 프롬프트) resumes ONE claude session per item, so each
    // new instruction builds on the prior turns and the similar-goal context instead of
    // starting fresh — better goal wording AND better context management. On the FIRST turn
    // (resumeSession empty) we seed the session with the current goal + the similar goals;
    // later turns pass only the new instruction and `--resume <session>`. Uses
    // `--output-format json` to capture BOTH the model reply and the session_id to resume.
    // Runs `claude -p` (seconds, BLOCKING) — call OFF main. ok=false on any failure so the
    // client keeps the current text unchanged (best-effort). Returns (ok, text, note, session).
    // Opens Terminal.app at the app's cwd and runs `claude --resume <session>` so the user can
    // continue the very conversation the refine loop built, interactively in a real shell. The
    // session was created in this process's cwd, so we cd there first (claude scopes sessions by
    // directory). Best-effort: returns false if Terminal/claude can't be resolved or launched.
    @discardableResult
    private func openClaudeResume(session: String) -> Bool {
        guard let claude = Self.resolveClaude() else { return false }
        let cwd = FileManager.default.currentDirectoryPath
        // The shell command Terminal will run. shellQuote guards path/session; PATH mirrors the
        // headless refine call so `claude` resolves the same way outside our injected env.
        let cmd = "cd \(Self.shellQuote(cwd)) && \(Self.shellQuote(claude)) --resume \(Self.shellQuote(session))"
        // Embed as an AppleScript string literal: escape backslashes then double-quotes.
        let asLit = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(asLit)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func aiRefineGoal(current: String, matches: [ReviewStore.QueueMatch], prompt: String,
                              resumeSession: String) -> (ok: Bool, text: String, note: String, session: String) {
        let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let ins = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cur.isEmpty, !ins.isEmpty else { return (false, "", "", resumeSession) }
        guard let claude = Self.resolveClaude() else { return (false, "", "", resumeSession) }
        let jsonRule = "Respond with ONLY a single JSON object, no prose, no code fences: "
            + "{\"text\": \"<the current best goal, one line, Korean>\", \"note\": \"<one short Korean sentence on what changed this turn>\"}"
        // First turn seeds full context; resumed turns carry it in the session, so send only
        // the new instruction (+ the JSON rule, since headless turns don't keep a system prompt).
        let promptText: String
        if resumeSession.isEmpty {
            let sim = matches.isEmpty ? "(none)" :
                matches.map { "#\($0.seq) \($0.text)\($0.why.isEmpty ? "" : " — \($0.why)")" }.joined(separator: "\n")
            promptText = """
            We will refine ONE goal for a personal goal tracker across a MULTI-TURN session. Each of my \
            messages is an instruction to improve the goal; keep all prior context and the similar goals \
            below in mind so we avoid duplication and manage context well. Keep the goal a single concise, \
            actionable line in Korean.

            CURRENT GOAL:
            \(cur)

            SIMILAR EXISTING GOALS (context — reuse/relate, don't duplicate):
            \(sim)

            FIRST INSTRUCTION:
            \(ins)

            \(jsonRule)
            """
        } else {
            promptText = "다음 지시로 목표를 이어서 다듬어줘: \(ins)\n\n\(jsonRule)"
        }
        var args = "-p --output-format json"
        if !resumeSession.isEmpty { args += " --resume \(Self.shellQuote(resumeSession))" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return (false, "", "", resumeSession) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        inPipe.fileHandleForWriting.write(Data(promptText.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        // Outer envelope: {result, session_id}. `result` holds the model's own {text, note} JSON.
        let raw = String(decoding: outData, as: UTF8.self)
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let env2 = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any]
        else { return (false, "", "", resumeSession) }
        let session = (env2["session_id"] as? String) ?? resumeSession
        let result = (env2["result"] as? String) ?? ""
        // Parse the inner {text, note} out of the model reply.
        guard let is0 = result.firstIndex(of: "{"), let ie = result.lastIndex(of: "}"), is0 < ie,
              let inner = try? JSONSerialization.jsonObject(with: Data(result[is0...ie].utf8)) as? [String: Any],
              let text = (inner["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return (false, "", "", session) }
        let note = (inner["note"] as? String) ?? ""
        return (true, text, note, session)
    }

    // Semantic ("AI") search over ALL goals — including archived/released ones, which are
    // hidden from every active view. Given a free-text query (a keyword, a phrase, or a loose
    // description), the model returns every goal that overlaps in intent or topic, ranked by
    // relevance with a short Korean reason. This is the "find in seconds what Jira makes you
    // hunt for by hand" capability. Best-effort: any failure returns ok:false so the client
    // can fall back to plain substring search. BLOCKING — call OFF main (see handlePost).
    private func aiSemanticSearch(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        // Snapshot ALL goals (incl. released) for a thread-safe read.
        let snapshot: [(seq: Int, text: String, status: String, released: Bool)] = DispatchQueue.main.sync {
            reviewStore.goals.map { (seq: $0.seq, text: $0.text, status: $0.status, released: $0.released) }
        }
        guard let claude = Self.resolveClaude() else {
            return "{\"ok\":false,\"error\":\"claude-not-found\"}"
        }
        // Feed the full corpus (skip nothing — archived goals are the whole point) as
        // "#<seq> <title>" lines; demand a strict JSON list of relevant seqs.
        let listText = snapshot.map { "#\($0.seq) \($0.text)" }.joined(separator: "\n")
        let prompt = """
        You are a semantic search engine for a personal goal tracker. The user gives a QUERY \
        (a keyword, phrase, or loose description). Find EVERY goal that is related to the query \
        in meaning, intent, or topic — not just literal string matches. Match across paraphrases, \
        synonyms, and different languages. Be generous about topical overlap but skip goals that \
        are clearly unrelated.

        GOALS (one per line as "#<seq> <title>"):
        \(listText.isEmpty ? "(none)" : listText)

        QUERY:
        \(q)

        Respond with ONLY a single JSON object, no prose, no code fences:
        {"matches": [{"seq": <int of a matching goal>, "why": "<short Korean reason it matches>"}]}
        Order matches from most to least relevant. Return an empty array when nothing is related.
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return "{\"ok\":false,\"error\":\"spawn-failed\"}" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
        else { return "{\"ok\":false,\"error\":\"parse-failed\"}" }
        // Keep only matches that point at a real goal; pass through seq + reason in rank order.
        let known = Set(snapshot.map { $0.seq })
        let rawMatches = (parsed["matches"] as? [[String: Any]]) ?? []
        let matches = rawMatches.compactMap { m -> String? in
            guard let seq = (m["seq"] as? NSNumber)?.intValue, known.contains(seq) else { return nil }
            let why = (m["why"] as? String) ?? ""
            return "{\"seq\":\(seq),\"why\":\(jsonString(why))}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"matches\":[\(matches)]}"
    }

    // One conversational turn inside the AI 중복 확인 다이얼로그: the user talks with Claude
    // to decide whether the candidate goal really duplicates existing ones AND to refine its
    // wording before adding. Stateless — the short dialog history is passed in each call.
    // Returns {"ok":bool,"reply":"…","suggestion":"…"} where suggestion (if present) is a
    // refined one-line goal the UI offers to apply to the editable goal field. BLOCKING —
    // called off-main (see handlePost).
    private func aiGoalChat(candidate: String, matches: [[String: Any]],
                            history: [[String: Any]], message: String,
                            images: [[String: Any]], model: String) -> String {
        let cand = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode + persist any attached images (reuse the chat attachments store), then
        // reference their paths so Claude can Read them. Off-main store access via main.sync.
        var imgPaths: [String] = []
        if !images.isEmpty {
            DispatchQueue.main.sync {
                for img in images.prefix(8) {
                    guard let b64 = img["data"] as? String, let dec = Self.decodeImageDataURL(b64) else { continue }
                    let ext = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png"
                    if let name = chatStore.saveImage(data: dec.bytes, ext: dec.ext.isEmpty ? ext : dec.ext) {
                        imgPaths.append(chatStore.imagePath(name).path)
                    }
                }
            }
        }
        if msg.isEmpty && !imgPaths.isEmpty { msg = "첨부한 이미지를 참고해서 목표를 다듬어줘." }
        guard !msg.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        guard let claude = Self.resolveClaude() else { return "{\"ok\":false,\"error\":\"claude-not-found\"}" }
        let matchText = matches.compactMap { m -> String? in
            guard let seq = (m["seq"] as? NSNumber)?.intValue else { return nil }
            let t = (m["text"] as? String) ?? ""
            let why = (m["why"] as? String) ?? ""
            return "#\(seq) \(t)" + (why.isEmpty ? "" : " — \(why)")
        }.joined(separator: "\n")
        let histText = history.compactMap { h -> String? in
            let t = ((h["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let who = (h["role"] as? String) == "assistant" ? "AI" : "사용자"
            return "\(who): \(t)"
        }.joined(separator: "\n")
        let prompt = """
        당신은 목표 관리 도구에서 사용자가 새 목표를 다듬도록 돕는 어시스턴트입니다.
        사용자가 추가하려는 새 목표가 기존 목표와 중복/유사할 수 있어 함께 상의해 결정합니다.
        지침:
        - 정말 중복이면 솔직히 말하고, 아니라면 왜 다른지 인정하세요.
        - 더 명확하고 구체적인 한 줄 목표 문구를 제안할 수 있으면 제안하세요.
        - 구체적인 목표 문구를 제안할 때는 답변 맨 마지막에 별도의 줄로 정확히
          "제안: <목표 문구>" 형식으로 한 줄만 덧붙이세요. (제안이 없으면 생략)
        - 한국어로 간결하게 답하고, 코드블록은 쓰지 마세요.

        [기존 유사 목표]
        \(matchText.isEmpty ? "(없음)" : matchText)

        [현재 작성 중인 새 목표]
        \(cand.isEmpty ? "(비어 있음)" : cand)

        [지금까지의 대화]
        \(histText.isEmpty ? "(없음)" : histText)

        [사용자의 새 메시지]
        \(msg)
        \(imgPaths.isEmpty ? "" : "\n[첨부 이미지 — Read 도구로 확인하세요]\n" + imgPaths.map { "- \($0)" }.joined(separator: "\n"))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Read-only + access to the attachments dir so the model can open attached images.
        var args = "-p --output-format json --add-dir \(Self.shellQuote(chatStore.attachmentsDir.path)) --allowedTools Read"
        if let m = Self.claudeModelAlias(model) { args += " --model \(Self.shellQuote(m))" }
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return "{\"ok\":false,\"error\":\"spawn-failed\"}" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        var reply = ""
        if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any] {
            reply = (parsed["result"] as? String) ?? ""
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if reply.isEmpty { return "{\"ok\":false,\"error\":\"empty-reply\"}" }
        // Extract a "제안: <text>" line (the refined goal wording), if the model included one.
        var suggestion = ""
        for line in reply.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            for pfx in ["제안:", "제안 :", "📝 제안:"] where s.hasPrefix(pfx) {
                suggestion = String(s.dropFirst(pfx.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "{\"ok\":true,\"reply\":\(jsonString(reply)),\"suggestion\":\(jsonString(suggestion))}"
    }

    // Locate the `claude` CLI. A GUI app launched from Finder inherits a minimal PATH, so
    // probe the common install locations first, then fall back to a login-shell `command -v`.
    private static func resolveClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "/usr/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = nil
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    // Single-quote a path for safe interpolation into a `bash -lc` command line.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Compact single-line JSON for an arbitrary value (tool input, denials array) so it
    // can be embedded in an SSE event payload. "null" if it isn't serializable.
    private static func jsonCompact(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    // Widest directory the powerful chat may touch: the multi-project workspace root.
    // A dev build sits at <workspace>/projects/<name>, so the root is two levels up.
    // nil for an installed app (no projectRoot) — bypassPermissions still lets the model
    // reach beyond its cwd, this just declares the workspace up front.
    private static func workspaceRoot() -> String? {
        guard let proj = AppPaths.projectRoot else { return nil }
        return proj.deletingLastPathComponent().deletingLastPathComponent().path
    }

    // MARK: Chat (Claude-Desktop-style 대화)

    // The conversation JSON the dashboard renders. Read on panel open + after each send.
    func chatJSON() -> String { chatJSON(chatStore) }

    // Same, for any conversation store (the global dashboard chat or a per-goal chat).
    func chatJSON(_ store: ChatStore) -> String {
        let msgs = DispatchQueue.main.sync { store.messages }
        let items = msgs.map { m -> String in
            let imgs = m.images.map { "\(jsonString("/chat-img/\($0)"))" }.joined(separator: ",")
            return "{\"id\":\(jsonString(m.id)),\"role\":\(jsonString(m.role)),"
                + "\"text\":\(jsonString(m.text)),\"images\":[\(imgs)],"
                + "\"createdAt\":\(m.createdAt.timeIntervalSince1970)}"
        }.joined(separator: ",")
        return "{\"messages\":[\(items)]}"
    }

    // GET /chat-img/<filename> -> the stored attachment bytes (inline), or nil (404).
    func serveChatImage(_ path: String) -> (Data, String, String)? {
        let name = String(path.dropFirst("/chat-img/".count))
            .removingPercentEncoding ?? ""
        return DispatchQueue.main.sync { chatStore.serveImage(name: name) }
    }

    // Send one chat turn to Claude. BLOCKING (seconds) — call OFF the main thread (see
    // handlePost). Persists the user message (+ any images), runs `claude -p` resuming the
    // conversation's session so context is kept, persists the reply, and returns the fresh
    // conversation JSON. On failure it still returns the conversation with an error note so
    // the panel stays consistent.
    private func chatSend(text: String, images: [[String: Any]], model: String) -> String {
        return chatSendTo(store: chatStore, extraAddDir: nil, preamble: "",
                          text: text, images: images, model: model)
    }

    // Generalized one-turn send against any conversation store. `extraAddDir` grants the
    // model Read access to an additional directory (a goal folder, for the per-goal chat).
    // `preamble` is prepended only on the FIRST turn of a fresh conversation (empty resume),
    // seeding the goal's context so the chat knows what it is helping to clarify.
    private func chatSendTo(store: ChatStore, extraAddDir: String?, preamble: String,
                            text: String, images: [[String: Any]], model: String,
                            powerful: Bool = false) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode + persist images first (on main for store safety); collect stored names + paths.
        var storedNames: [String] = []
        var imgPaths: [String] = []
        DispatchQueue.main.sync {
            for img in images.prefix(8) {
                guard let b64 = img["data"] as? String,
                      let data = Self.decodeImageDataURL(b64) else { continue }
                let ext = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png"
                if let name = store.saveImage(data: data.bytes, ext: data.ext.isEmpty ? ext : data.ext) {
                    storedNames.append(name)
                    imgPaths.append(store.imagePath(name).path)
                }
            }
        }
        guard !body.isEmpty || !storedNames.isEmpty else { return chatJSON(store) }

        // Record the user turn immediately so the panel shows it even if Claude is slow.
        let (resume, addDir): (String, String) = DispatchQueue.main.sync {
            store.appendUser(text: body, images: storedNames)
            return (store.sessionId, store.attachmentsDir.path)
        }
        let isFirstTurn = resume.isEmpty

        guard let claude = Self.resolveClaude() else {
            DispatchQueue.main.sync { _ = store.appendAssistant(text: "⚠️ claude CLI를 찾지 못했습니다. (~/.local/bin/claude 등)") }
            return chatJSON(store)
        }

        // Build the prompt: optional first-turn context preamble, user text, and a note
        // pointing the model at any attached images.
        var prompt = body
        if isFirstTurn, !preamble.isEmpty {
            prompt = preamble + "\n\n---\n\n" + body
        }
        if !imgPaths.isEmpty {
            let list = imgPaths.map { "- \($0)" }.joined(separator: "\n")
            prompt += "\n\n[첨부 이미지 — Read 도구로 확인하세요]\n\(list)"
        }
        // Assemble the claude args: print mode, JSON output (for result + session_id),
        // resume to keep context, optional model, image-read access to the attach dir, and
        // (for goal chats) the goal folder so the model may Read the core/detail docs.
        var args = "-p --output-format json --add-dir \(Self.shellQuote(addDir))"
        if powerful {
            // Full-auto chat (user-chosen): skip permission prompts and widen reach to the
            // whole workspace, so the model can edit files and run commands like the CLI
            // would — while the user keeps the comfortable chat input instead of a terminal.
            args += " --permission-mode bypassPermissions"
            if let ws = Self.workspaceRoot() { args += " --add-dir \(Self.shellQuote(ws))" }
        } else {
            args += " --allowedTools Read"   // global chat stays read-only
        }
        if let extra = extraAddDir, !extra.isEmpty { args += " --add-dir \(Self.shellQuote(extra))" }
        if !resume.isEmpty { args += " --resume \(Self.shellQuote(resume))" }
        if let m = Self.claudeModelAlias(model) { args += " --model \(Self.shellQuote(m))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch {
            DispatchQueue.main.sync { _ = store.appendAssistant(text: "⚠️ claude 실행에 실패했습니다.") }
            return chatJSON(store)
        }
        // Watchdog: a long answer is fine, but never hang the connection forever. Powerful
        // turns run tools (edits/Bash) and can take minutes, so they get a longer leash.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (powerful ? 900 : 180), execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        // Parse {result, session_id}; fall back to raw text if it isn't the json envelope.
        let raw = String(decoding: outData, as: UTF8.self)
        var reply = ""
        var newSession = ""
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] {
            reply = (parsed["result"] as? String) ?? ""
            newSession = (parsed["session_id"] as? String) ?? ""
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if reply.isEmpty { reply = "⚠️ 응답을 받지 못했습니다. (타임아웃이거나 빈 응답)" }
        DispatchQueue.main.sync {
            store.setSession(newSession)
            _ = store.appendAssistant(text: reply)
        }
        return chatJSON(store)
    }

    // MARK: Working scope (goal vs subtask)

    // The folder a goal-page request operates on: the parent goal itself (task == nil) or
    // one subtask under goal-NN/tasks/<task>. A subtask page reuses the whole goal-page
    // interface — messenger, CLI, docs, attachments, sessions — but every path is resolved
    // from this scope so each subtask works in isolation. Goal call sites pass a goal scope
    // (task == nil) and hit the exact same paths as before, guaranteeing zero regression.
    struct Scope {
        let seq: Int        // parent goal number (the container goal-NN), always present
        let task: String?   // subtask FOLDER NAME under goal-NN/tasks/, nil = the goal itself

        // Dictionary key for per-scope caches (chat stores, SSE streams, CLI tags).
        var key: String { task.map { "g\(seq)/t/\($0)" } ?? "g\(seq)" }

        // The folder this scope reads/writes — goal-NN for a goal, goal-NN/tasks/<task> for
        // a subtask. nil when the number/task can't resolve a folder.
        var workDir: URL? {
            if let t = task { return IssuePaths.taskDir(seq: seq, task: t) }
            return IssuePaths.goalDir(seq: seq)
        }
        var chatDir: URL? { workDir?.appendingPathComponent("chat", isDirectory: true) }
        var coreURL: URL? { workDir?.appendingPathComponent("goal-core.md") }
        var detailURL: URL? { workDir?.appendingPathComponent("goal-detail.md") }
        var attachmentsDir: URL? { workDir?.appendingPathComponent("attachments", isDirectory: true) }

        // Parse the optional task from a request: "?n=" / "seq=" for the goal number and
        // "t=" / "task=" (URL-decoded) for the subtask folder. An empty/absent task yields a
        // goal scope (task == nil), so existing seq-only links keep hitting the goal path.
        static func from(query path: String) -> Scope {
            guard let comps = URLComponents(string: "http://x" + path) else { return Scope(seq: 0, task: nil) }
            let items = comps.queryItems ?? []
            let rawSeq = items.first(where: { $0.name == "n" })?.value
                ?? items.first(where: { $0.name == "seq" })?.value ?? ""
            let seq = Int(rawSeq.replacingOccurrences(of: "goal-", with: "").filter { $0.isNumber }) ?? 0
            let rawTask = items.first(where: { $0.name == "t" })?.value
                ?? items.first(where: { $0.name == "task" })?.value ?? ""
            let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
            return Scope(seq: seq, task: task.isEmpty ? nil : task)
        }

        // Parse the scope from a POST JSON body: "seq" (int or numeric string) and an
        // optional "task" string. An empty "task" is treated as the goal scope.
        static func from(body obj: [String: Any]) -> Scope {
            let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
            let raw = (obj["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Scope(seq: seq, task: raw.isEmpty ? nil : raw)
        }
    }

    // MARK: Per-goal "목표 명확화" chat

    // One ChatStore per scope folder (goal-NN/chat or goal-NN/tasks/<task>/chat), created on
    // demand and cached by scope.key. The cache is touched only on main so the server queue
    // (GET/POST off-main) never races the dictionary.
    private var chatStores: [String: ChatStore] = [:]
    private func chatStore(for scope: Scope) -> ChatStore? {
        guard scope.seq > 0, let dir = scope.chatDir, let work = scope.workDir else { return nil }
        // A subtask whose folder doesn't exist yet has no store (the page shows an empty
        // state instead). A goal folder is created lazily by ChatStore as before.
        if scope.task != nil, !FileManager.default.fileExists(atPath: work.path) { return nil }
        let key = scope.key
        return DispatchQueue.main.sync {
            if let c = chatStores[key] { return c }
            let c = ChatStore(dir: dir)
            chatStores[key] = c
            return c
        }
    }
    // Thin seq-based wrapper so existing goal call sites compile unchanged (goal scope).
    private func goalChat(seq: Int) -> ChatStore? { chatStore(for: Scope(seq: seq, task: nil)) }

    // GET /api/goal/chat?seq=NN[&task=…] — the scope's conversation JSON (empty if no folder).
    func goalChatJSON(_ scope: Scope) -> String {
        guard let store = chatStore(for: scope) else { return "{\"messages\":[]}" }
        return chatJSON(store)
    }

    // GET /api/goal/definition?seq=NN[&task=…]&kind=core|detail — the raw markdown of one
    // version, loaded into the inline editor. Returns {"text":"…"} ("" when the file is missing).
    func goalDefinitionJSON(_ scope: Scope, kind: String) -> String {
        let url = (kind == "detail") ? scope.detailURL : scope.coreURL
        var text = ""
        if let u = url, FileManager.default.fileExists(atPath: u.path),
           let data = try? Data(contentsOf: u) {
            text = String(decoding: data, as: UTF8.self)
        }
        return "{\"text\":\(jsonString(text))}"
    }

    // POST /api/goal/definition/save — overwrite goal-core.md (or goal-detail.md) with the
    // edited markdown. Pure file write (no claude, no store mutation), so it can run on the
    // server thread without hopping to main. Creates the scope folder if needed.
    func goalDefinitionSave(_ scope: Scope, kind: String, text: String) -> String {
        guard scope.seq > 0, let url = (kind == "detail") ? scope.detailURL : scope.coreURL else {
            return "{\"ok\":false,\"error\":\"bad seq\"}"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "{\"ok\":true}"
        } catch {
            return "{\"ok\":false,\"error\":\(jsonString(error.localizedDescription))}"
        }
    }

    // POST /api/goal/chat/send — one turn against the goal's conversation. BLOCKING.
    // Runs in powerful mode (bypassPermissions + workspace add-dir) so the comfortable
    // chat input can do real work — edits, commands — without dropping to a terminal.
    func goalChatSend(seq: Int, text: String, model: String) -> String {
        guard let store = goalChat(seq: seq) else { return "{\"messages\":[]}" }
        let addDir = IssuePaths.goalDir(seq: seq)?.path
        // Chatting on a goal means work has started — promote it like the CLI does. Only
        // from 대기/응답 대기; never resurrect a deliberately set hold (stopped/cancelled/done).
        DispatchQueue.main.sync {
            if let g = reviewStore.goals.first(where: { $0.seq == seq }),
               g.status == "backlog" || g.status == "waiting" {
                reviewStore.setStatus(id: g.id, status: "in_progress")
            }
        }
        return chatSendTo(store: store, extraAddDir: addDir, preamble: goalChatPreamble(seq: seq),
                          text: text, images: [], model: model, powerful: true)
    }

    // POST /api/goal/chat/reset — clear the scope's conversation and resume id.
    func goalChatReset(_ scope: Scope) -> String {
        guard let store = chatStore(for: scope) else { return "{\"messages\":[]}" }
        DispatchQueue.main.sync { store.reset() }
        return chatJSON(store)
    }

    // MARK: In-page CLI (PTY-backed interactive claude)

    // The in-page chat runs `claude -p` (headless: Read-only, add-dir limited, can't
    // prompt for permission). The CLI here runs the real interactive claude in a PTY so
    // it can ask for permission and reach beyond the goal folder — heavier work — while
    // staying inside the web page (no native Terminal). Bridged to xterm.js by polling.

    // Live CLI sessions keyed by token. Touched from the server queue (off-main); guarded
    // by its own lock since several connections may poll/stop concurrently.
    private var cliSessions: [String: PtySession] = [:]
    // Per-token metadata (the parent goal seq for the rail's status lookup, the scope key so
    // a subtask reconnects to its own session, + a display title) so the global left rail can
    // list background sessions across pages. Guarded by the same cliLock.
    private var cliTags: [String: (seq: Int, scopeKey: String, title: String)] = [:]
    private let cliLock = NSLock()

    // The claude command + working directory for this goal's CLI, plus the session id to
    // persist so closing the in-page terminal no longer loses the conversation. Continuity
    // is resolved in four tiers:
    //   1. Resume the CLI's own session if its transcript is still on disk.
    //   2. Resume a session CONNECTED to this goal — the lifecycle session it mirrors
    //      (goal.sessionId) or one manually linked via the "세션 연결" picker
    //      (goal.linkedSessions). This is what lets "이미 세션이 있으면 세션을 불러와" work:
    //      opening the CLI continues the real working session instead of an arbitrary seed.
    //   3. First CLI open with no connection: inherit the page chat's session (carry over
    //      context), adopting its id as the CLI session so future opens resume it.
    //   4. Fresh start: mint a session id up front via --session-id so we can persist it
    //      immediately — an interactive claude never reports its id back to us otherwise.
    // Resume omits --fork-session, so repeated open/close keeps appending to one transcript.
    // Whichever id is returned is adopted as the CLI session by the caller (cliStart).
    private func cliCommand(_ scope: Scope) -> (cwd: String, command: String, sessionId: String)? {
        guard let store = chatStore(for: scope), let workDir = scope.workDir,
              let claude = Self.resolveClaude() else { return nil }
        // Tier 2's connected sessions come from the parent goal for a goal scope, but from
        // the subtask's own ChatStore.linkedSessions for a task scope (it has no Goal).
        let (cliId, pageId, connectedIds): (String, String, [String]) = DispatchQueue.main.sync {
            var ids: [String] = []
            if scope.task == nil {
                if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                    if !g.sessionId.isEmpty { ids.append(g.sessionId) }
                    ids.append(contentsOf: g.linkedSessions)
                }
            } else {
                ids.append(contentsOf: store.linkedSessions)
            }
            return (store.cliSessionId, store.sessionId, ids)
        }
        let goalPath = workDir.path
        // A `claude --resume <id>` invocation that grants Read access to the goal folder.
        func resume(_ id: String) -> String {
            "\(Self.shellQuote(claude)) --resume \(Self.shellQuote(id)) --add-dir \(Self.shellQuote(goalPath))"
        }
        // Tier 1: the CLI's own prior conversation.
        if !cliId.isEmpty, let cwd = sessionCwd(sessionId: cliId) {
            return (cwd, resume(cliId), cliId)
        }
        // Tier 2: a session connected to this goal, first one whose transcript still exists.
        if cliId.isEmpty {
            for sid in connectedIds where !sid.isEmpty {
                if let cwd = sessionCwd(sessionId: sid) { return (cwd, resume(sid), sid) }
            }
        }
        // Tier 3: inherit the page messenger chat's session.
        if cliId.isEmpty, !pageId.isEmpty, let cwd = sessionCwd(sessionId: pageId) {
            return (cwd, resume(pageId), pageId)
        }
        let newId = UUID().uuidString
        let seed = "이 폴더의 goal-core.md와 goal-detail.md(목표 정의)를 읽고, "
            + "문제정의·예상결과·예상해결방안·예상테스트시나리오 관점에서 모호한 점을 질문해 "
            + "목표를 더 또렷하게 다듬어 주세요. 특히 문제정의가 정확한지 가장 먼저 확인하세요. 한국어로 간결하게 답하세요."
        return (goalPath, "\(Self.shellQuote(claude)) --session-id \(Self.shellQuote(newId)) \(Self.shellQuote(seed))", newId)
    }

    // POST /api/goal/cli/start — reconnect to this scope's live background session if one
    // exists, otherwise spawn a fresh PTY-backed claude. Returns the token.
    func cliStart(_ scope: Scope, cols: UInt16, rows: UInt16) -> String {
        let scopeKey = scope.key
        let title = DispatchQueue.main.sync {
            reviewStore.goals.first(where: { $0.seq == scope.seq })?.text ?? "goal-\(scope.seq)"
        }
        // Reconnect: if a session for this scope is still alive in the background, hand back
        // its token instead of spawning a second claude. The client polls from offset 0 and
        // the PTY's 4MB buffer tail replays, restoring the screen where the user left off.
        // Match by scopeKey so a subtask reuses only its own session, not the parent goal's.
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive { v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k) }
        if let existing = cliSessions.first(where: { cliTags[$0.key]?.scopeKey == scopeKey && $0.value.alive }) {
            existing.value.resize(cols: max(cols, 20), rows: max(rows, 4))
            let tok = existing.key
            cliLock.unlock()
            return "{\"ok\":true,\"token\":\(jsonString(tok)),\"reused\":true}"
        }
        cliLock.unlock()

        guard let (cwd, command, sessionId) = cliCommand(scope) else {
            return "{\"ok\":false,\"error\":\"no-goal-or-claude\"}"
        }
        guard let s = PtySession(command: command, cwd: cwd, cols: max(cols, 20), rows: max(rows, 4)) else {
            return "{\"ok\":false,\"error\":\"pty-failed\"}"
        }
        // Record the session id now (we know it up front), so even an immediate close keeps
        // the conversation reachable on the next open.
        if let store = chatStore(for: scope) {
            DispatchQueue.main.sync { store.setCliSession(sessionId) }
        }
        cliLock.lock()
        cliSessions[s.token] = s
        cliTags[s.token] = (seq: scope.seq, scopeKey: scopeKey, title: title)
        cliLock.unlock()
        // Opening the CLI means work has started — reflect it in the parent goal's status
        // (a subtask's parent goal is still promoted to 진행 중, which is desired).
        // Promote only from 대기(backlog)/응답 대기(waiting); never resurrect a status the
        // user set deliberately (stopped/cancelled/done) or disturb a live in_progress run.
        DispatchQueue.main.sync {
            if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }),
               g.status == "backlog" || g.status == "waiting" {
                reviewStore.setStatus(id: g.id, status: "in_progress")
            }
        }
        return "{\"ok\":true,\"token\":\(jsonString(s.token))}"
    }

    // POST /api/goal/cli/io — write any keystrokes, return new output since `since`.
    func cliIO(token: String, inputB64: String, since: Int) -> String {
        cliLock.lock(); let s = cliSessions[token]; cliLock.unlock()
        guard let s else { return "{\"ok\":false,\"error\":\"no-session\"}" }
        if !inputB64.isEmpty, let d = Data(base64Encoded: inputB64) { s.write(d) }
        let (data, offset) = s.read(since: since)
        return "{\"ok\":true,\"data\":\(jsonString(data.base64EncodedString())),"
            + "\"offset\":\(offset),\"alive\":\(s.alive ? "true" : "false")}"
    }

    func cliResize(token: String, cols: UInt16, rows: UInt16) {
        cliLock.lock(); let s = cliSessions[token]; cliLock.unlock()
        s?.resize(cols: max(cols, 20), rows: max(rows, 4))
    }

    func cliStop(token: String) {
        cliLock.lock()
        let s = cliSessions.removeValue(forKey: token)
        cliTags.removeValue(forKey: token)
        cliLock.unlock()
        s?.terminate()
    }

    // GET /api/cli/sessions — the left rail's unified worklist. Mirrors Claude Desktop's
    // colored session list. Merges three sources and tags each with the goal's real status
    // (+waitKind) so the rail can color the dot:
    //   • live PTY sessions          -> the goal's status (in_progress = 진행 중 pulse, or
    //                                   확인/의사결정 요청 if it parked at a prompt)
    //   • idle in_progress / waiting -> shown even with the terminal closed
    //   • recently completed (done)  -> a hollow gray circle, briefly, like Claude Desktop
    // Each item: {seq, title, status, waitKind, live, token?}.
    func cliSessionsJSON() -> String {
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive { v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k) }
        // One live token per goal (the reuse logic already prevents duplicates).
        var liveBySeq: [Int: (token: String, title: String)] = [:]
        for tok in cliSessions.keys { if let tag = cliTags[tok] { liveBySeq[tag.seq] = (tok, tag.title) } }
        cliLock.unlock()

        let goals: [(seq: Int, title: String, status: String, waitKind: String, completedAt: Date?)] =
            DispatchQueue.main.sync {
                reviewStore.goals.map { (seq: $0.seq, title: $0.text, status: $0.status,
                                         waitKind: $0.waitKind, completedAt: $0.completedAt) }
            }
        var bySeq: [Int: (seq: Int, title: String, status: String, waitKind: String, completedAt: Date?)] = [:]
        for g in goals { bySeq[g.seq] = g }

        func item(seq: Int, title: String, status: String, waitKind: String, live: Bool, token: String?) -> String {
            var s = "{\"seq\":\(seq),\"title\":\(jsonString(title)),\"status\":\(jsonString(status)),"
                + "\"waitKind\":\(jsonString(waitKind)),\"live\":\(live ? "true" : "false")"
            if let token { s += ",\"token\":\(jsonString(token))" }
            return s + "}"
        }

        var items: [String] = []
        // Only live PTY sessions — i.e. goals whose page has actually been opened (the
        // in-page CLI's PTY survives navigation server-side). Idle in_progress/waiting and
        // recently-completed goals are intentionally NOT listed here: the rail is a list of
        // what you have open, not the whole goal backlog (which lives on the dashboard).
        for (seq, v) in liveBySeq.sorted(by: { $0.key < $1.key }) {
            let g = bySeq[seq]
            items.append(item(seq: seq, title: g?.title ?? v.title,
                              status: g?.status ?? "in_progress", waitKind: g?.waitKind ?? "",
                              live: true, token: v.token))
        }
        return "{\"sessions\":[\(items.joined(separator: ","))]}"
    }

    // Periodic reap: now that navigating away no longer kills the PTY, terminate sessions
    // whose terminal has gone untouched (no poll) for a long while so orphaned claude
    // processes don't accumulate. Called from the main activity tick.
    func cliReapIdle(maxIdle: TimeInterval = 30 * 60) {
        let now = Date()
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive || now.timeIntervalSince(v.lastTouched) > maxIdle {
            v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k)
        }
        cliLock.unlock()
    }

    // MARK: Streaming chat (chat2 — Claude-Desktop-style)

    // Open SSE channels keyed by scope.key (one per browser tab), and the running turn
    // process per scope.key. Touched from the server queue; guarded by its own lock.
    private var chat2Streams: [String: [SSEChannel]] = [:]
    private var chat2Procs: [String: Process] = [:]
    private let chat2Lock = NSLock()

    // GET /api/goal/chat2/stream?seq=NN[&task=…] — register a held-open SSE channel for the
    // scope (the goal, or one subtask), keyed so a subtask's events never reach the goal tab.
    func handleChat2Stream(_ path: String, _ channel: SSEChannel) {
        let scope = Scope.from(query: path)
        guard scope.seq > 0 else { channel.close(); return }
        let key = scope.key
        chat2Lock.lock(); chat2Streams[key, default: []].append(channel); chat2Lock.unlock()
        channel.onClose = { [weak self] in
            guard let self else { return }
            self.chat2Lock.lock(); self.chat2Streams[key]?.removeAll { $0 === channel }; self.chat2Lock.unlock()
        }
    }

    // Push one JSON event to every open channel for the scope.
    private func chat2Emit(_ key: String, _ json: String) {
        chat2Lock.lock(); let chans = chat2Streams[key] ?? []; chat2Lock.unlock()
        for c in chans { c.event(json) }
    }

    // POST /api/goal/chat2/say — persist the user turn, then run a streaming claude turn
    // on a background queue whose events flow out over the goal's SSE channel. Returns
    // immediately; the answer arrives via the stream, not this response.
    func chat2Say(_ scope: Scope, text: String, mode: String, model: String, allow: [String]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let store = chatStore(for: scope), let claude = Self.resolveClaude(),
              let workDir = scope.workDir else { return "{\"ok\":false}" }
        let validModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]
        let m = validModes.contains(mode) ? mode : "bypassPermissions"
        DispatchQueue.main.sync {
            store.appendUser(text: body, images: [])
            // Chatting means work has started — promote the parent goal like the other paths
            // (a subtask's parent goal is still promoted to 진행 중, which is desired).
            if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }),
               g.status == "backlog" || g.status == "waiting" {
                reviewStore.setStatus(id: g.id, status: "in_progress")
            }
        }
        let preamble = goalChatPreamble(scope)
        let key = scope.key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.chat2RunTurn(key: key, store: store, claude: claude, goalDir: workDir.path,
                               prompt: body, preamble: preamble, mode: m, model: model, allow: allow)
        }
        return "{\"ok\":true}"
    }

    // POST /api/goal/chat2/stop — terminate the scope's running turn.
    func chat2Stop(_ scope: Scope) {
        let key = scope.key
        chat2Lock.lock(); let p = chat2Procs[key]; chat2Lock.unlock()
        if let p, p.isRunning { p.terminate() }
        chat2Emit(key, "{\"t\":\"stopped\"}")
    }

    // Run one streaming turn: spawn claude in stream-json mode, write the user message,
    // and relay parsed events to the SSE channel until `result`. BLOCKING — runs on a
    // background queue (see chat2Say).
    private func chat2RunTurn(key: String, store: ChatStore, claude: String, goalDir: String,
                              prompt: String, preamble: String, mode: String, model: String, allow: [String]) {
        chat2Lock.lock(); let busy = chat2Procs[key] != nil; chat2Lock.unlock()
        if busy { chat2Emit(key, "{\"t\":\"error\",\"message\":\"이미 진행 중인 턴이 있습니다.\"}"); return }

        let resume = DispatchQueue.main.sync { store.sessionId }
        var full = prompt
        if resume.isEmpty, !preamble.isEmpty { full = preamble + "\n\n---\n\n" + prompt }

        var parts = [Self.shellQuote(claude), "-p", "--input-format", "stream-json",
                     "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--permission-mode", mode, "--add-dir", Self.shellQuote(goalDir)]
        if let ws = Self.workspaceRoot() { parts += ["--add-dir", Self.shellQuote(ws)] }
        if !allow.isEmpty { parts += ["--allowedTools"] + allow.map(Self.shellQuote) }
        if !resume.isEmpty { parts += ["--resume", Self.shellQuote(resume)] }
        if let alias = Self.claudeModelAlias(model) { parts += ["--model", Self.shellQuote(alias)] }
        let command = parts.joined(separator: " ") + " 2>/dev/null"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // This is an internal headless `claude -p` worker, not user work. Flag it so the
        // session hook (Scripts/cc-session-hook.sh) skips mirroring it as a dashboard goal —
        // otherwise the worker's fixed system prompt shows up as an echo goal.
        env["CM_SUPPRESS_SESSION_GOAL"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil

        chat2Emit(key, "{\"t\":\"start\"}")
        do { try p.run() } catch {
            chat2Emit(key, "{\"t\":\"error\",\"message\":\"claude 실행 실패\"}"); return
        }
        chat2Lock.lock(); chat2Procs[key] = p; chat2Lock.unlock()

        let userLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(jsonString(full))}}\n"
        inPipe.fileHandleForWriting.write(Data(userLine.utf8))
        try? inPipe.fileHandleForWriting.close()

        var buf = Data()
        var emittedTools = Set<String>()
        var finalText = ""
        var newSession = ""
        var finished = false
        let fh = outPipe.fileHandleForReading
        // stream-json input mode keeps the process alive after stdin EOF, so we end the
        // turn ourselves on `result` rather than waiting for a natural exit.
        outer: while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }            // EOF (process exited)
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0a) {
                let lineData = Data(buf[buf.startIndex..<nl])
                buf.removeSubrange(buf.startIndex...nl)
                guard !lineData.isEmpty,
                      let o = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                chat2Handle(o, key: key, emittedTools: &emittedTools, finalText: &finalText,
                            newSession: &newSession, finished: &finished)
                if finished { break outer }
            }
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        chat2Lock.lock(); chat2Procs[key] = nil; chat2Lock.unlock()

        let reply = finalText
        DispatchQueue.main.sync {
            if !newSession.isEmpty { store.setSession(newSession) }
            if !reply.isEmpty { _ = store.appendAssistant(text: reply) }
        }
    }

    // Translate one stream-json line into an SSE event (and accumulate turn results).
    private func chat2Handle(_ o: [String: Any], key: String, emittedTools: inout Set<String>,
                             finalText: inout String, newSession: inout String, finished: inout Bool) {
        guard let t = o["type"] as? String else { return }
        switch t {
        case "stream_event":
            guard let ev = o["event"] as? [String: Any], (ev["type"] as? String) == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], let dt = delta["type"] as? String else { return }
            if dt == "text_delta", let s = delta["text"] as? String, !s.isEmpty {
                chat2Emit(key, "{\"t\":\"delta\",\"text\":\(jsonString(s))}")
            } else if dt == "thinking_delta", let s = delta["thinking"] as? String, !s.isEmpty {
                chat2Emit(key, "{\"t\":\"think\",\"text\":\(jsonString(s))}")
            }
        case "assistant":
            guard let msg = o["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where (c["type"] as? String) == "tool_use" {
                let id = (c["id"] as? String) ?? ""
                if id.isEmpty || emittedTools.contains(id) { continue }
                emittedTools.insert(id)
                let name = (c["name"] as? String) ?? "tool"
                chat2Emit(key, "{\"t\":\"tool\",\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),"
                    + "\"input\":\(Self.jsonCompact(c["input"] ?? [:]))}")
            }
        case "user":
            // Synthetic tool_result message echoed on stdout (we don't replay our own input):
            // carry the tool's output back to its card by tool_use_id.
            guard let msg = o["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where (c["type"] as? String) == "tool_result" {
                let id = (c["tool_use_id"] as? String) ?? ""
                let isErr = (c["is_error"] as? Bool) ?? false
                var text = ""
                if let s = c["content"] as? String { text = s }
                else if let arr = c["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                if text.count > 4000 { text = String(text.prefix(4000)) + "…(생략)" }
                chat2Emit(key, "{\"t\":\"toolresult\",\"id\":\(jsonString(id)),"
                    + "\"isError\":\(isErr ? "true" : "false"),\"text\":\(jsonString(text))}")
            }
        case "result":
            finalText = (o["result"] as? String) ?? finalText
            newSession = (o["session_id"] as? String) ?? newSession
            let denials = o["permission_denials"] as? [Any] ?? []
            let cost = (o["total_cost_usd"] as? Double) ?? 0
            let isErr = (o["is_error"] as? Bool) ?? false
            chat2Emit(key, "{\"t\":\"done\",\"result\":\(jsonString(finalText)),"
                + "\"denials\":\(Self.jsonCompact(denials)),\"cost\":\(cost),\"isError\":\(isErr ? "true" : "false")}")
            finished = true
        default: break
        }
    }

    // The cwd a session was created in, read from its transcript so an interactive
    // `claude --resume` launches from the matching project directory (resume is
    // project-scoped). Scans ~/.claude/projects/*/<sessionId>.jsonl and parses the
    // first record carrying a non-empty "cwd". nil if no transcript or no cwd found.
    private func sessionCwd(sessionId: String) -> String? {
        let fm = FileManager.default
        guard let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        var found: URL?
        for dir in subs {
            let cand = dir.appendingPathComponent(sessionId + ".jsonl")
            if fm.fileExists(atPath: cand.path) { found = cand; break }
        }
        guard let url = found, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let chunk = fh.readData(ofLength: 65_536)
        guard !chunk.isEmpty else { return nil }
        for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            // Only hand back a directory that still exists. After the data store was
            // consolidated to ~/.condition-manager, old transcripts still record a path like
            // <repo>/.condition-manager/issue/goal-NN that no longer exists; returning it would
            // make the resumed CLI's process.run() throw (surfacing as "pty-failed"). Returning
            // nil instead lets cliCommand skip that resume tier and start fresh in the goal's
            // current folder, which self-heals the stored cliSessionId on the next open.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
            return cwd
        }
        return nil
    }

    // MARK: - Per-goal session list (연결된 세션 목록)

    // Locate <sessionId>.jsonl anywhere under ~/.claude/projects. Generic sibling of
    // resolveTranscript that takes a bare id (no Goal needed).
    private func transcriptURL(forSessionId sid: String) -> URL? {
        let id = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let subs = try? FileManager.default.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        for dir in subs {
            let cand = dir.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: cand.path) { return cand }
        }
        return nil
    }

    // The best human title for a transcript, mirroring the session hook's priority:
    //   goal-title-override > ai-title > custom-title > first user prompt (truncated).
    // Title records (override/ai/custom) are appended as the session runs, so the latest
    // sit near the END — read a bounded tail window for those, and only fall back to a
    // small head read for the first prompt. Bounded IO so the picker stays snappy even
    // with large transcripts. "" when no title source is present.
    private func transcriptTitle(_ url: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        func scan(_ data: Data, _ visit: (String, [String: Any]) -> Void) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let t = o["type"] as? String else { continue }
                visit(t, o)
            }
        }
        var override = "", ai = "", custom = "", first = ""
        let tailLen: UInt64 = 262_144
        try? fh.seek(toOffset: size > tailLen ? size - tailLen : 0)
        let tail = (try? fh.readToEnd()) ?? Data()
        scan(tail) { t, o in
            if t == "goal-title-override", let s = o["title"] as? String, !s.isEmpty { override = s }
            else if t == "ai-title", let s = o["aiTitle"] as? String, !s.isEmpty { ai = s }
            else if t == "custom-title", let s = o["customTitle"] as? String, !s.isEmpty { custom = s }
        }
        if override.isEmpty && ai.isEmpty && custom.isEmpty {
            try? fh.seek(toOffset: 0)
            let head = fh.readData(ofLength: 65_536)
            scan(head) { t, o in
                if t == "last-prompt", first.isEmpty, let s = o["lastPrompt"] as? String, !s.isEmpty { first = s }
            }
        }
        if !override.isEmpty { return override }
        if !ai.isEmpty { return ai }
        if !custom.isEmpty { return custom }
        let s = first.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        if s.isEmpty { return "" }
        return s.count > 48 ? String(s.prefix(48)) + "…" : s
    }

    // GET /api/goal/sessions?seq=NN[&task=…] — every session associated with the scope: its
    // primary lifecycle session, the messenger chat session, the in-page CLI session, plus
    // any manually-linked ones. Each carries its last-used time (transcript mtime), a title,
    // and a resume command, sorted newest-first so the user can tell which to continue. A
    // subtask has no lifecycle Goal, so its primary is "" and links come from the task store.
    func goalSessionsJSON(_ scope: Scope) -> String {
        var pageMsg = "", pageCli = "", primary = ""
        var linked: [String] = []
        if scope.task == nil {
            (primary, linked) = DispatchQueue.main.sync { () -> (String, [String]) in
                let g = reviewStore.goals.first { $0.seq == scope.seq }
                return (g?.sessionId ?? "", g?.linkedSessions ?? [])
            }
        }
        if let store = chatStore(for: scope) {
            let (m, c, ls) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId, store.linkedSessions) }
            pageMsg = m; pageCli = c
            if scope.task != nil { linked = ls }
        }
        var order: [(id: String, src: String)] = []
        func add(_ id: String, _ src: String) {
            let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !order.contains(where: { $0.id == t }) else { return }
            order.append((t, src))
        }
        add(primary, "세션")
        add(pageMsg, "메신저")
        add(pageCli, "CLI")
        for s in linked { add(s, "연결") }

        let fm = FileManager.default
        var rows: [(json: String, when: TimeInterval)] = []
        for e in order {
            let url = transcriptURL(forSessionId: e.id)
            var when: TimeInterval = 0
            if let u = url, let a = try? fm.attributesOfItem(atPath: u.path),
               let m = a[.modificationDate] as? Date { when = m.timeIntervalSince1970 }
            let title = url.map { transcriptTitle($0) } ?? ""
            let display = title.isEmpty ? "Claude 세션 \(e.id.prefix(8))" : title
            let removable = (e.src == "연결")
            let j = "{\"id\":\(jsonString(e.id)),\"source\":\(jsonString(e.src)),"
                + "\"title\":\(jsonString(display)),\"lastUsed\":\(Int(when)),"
                + "\"exists\":\(url != nil),\"removable\":\(removable),"
                + "\"resume\":\(jsonString("claude --resume " + e.id))}"
            rows.append((j, when))
        }
        rows.sort { $0.when > $1.when }
        return "{\"now\":\(Int(Date().timeIntervalSince1970)),\"sessions\":[\(rows.map { $0.json }.joined(separator: ","))]}"
    }

    // GET /api/sessions/recent?seq=NN[&task=…] — the most recently used Claude sessions across
    // ~/.claude/projects, for the "세션 연결" picker. Newest-first, capped, each tagged with
    // whether it is already linked to this scope so the picker can pre-check / disable it.
    func recentSessionsJSON(_ scope: Scope) -> String {
        let fm = FileManager.default
        var already = DispatchQueue.main.sync { () -> Set<String> in
            var s = Set<String>()
            if scope.task == nil, let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                if !g.sessionId.isEmpty { s.insert(g.sessionId) }
                for x in g.linkedSessions { s.insert(x) }
            }
            return s
        }
        if let store = chatStore(for: scope) {
            let (m, c, ls) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId, store.linkedSessions) }
            if !m.isEmpty { already.insert(m) }
            if !c.isEmpty { already.insert(c) }
            if scope.task != nil { for x in ls { already.insert(x) } }
        }
        var files: [(url: URL, when: Date)] = []
        if let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) {
            for dir in subs {
                let inner = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in inner where f.pathExtension == "jsonl" {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((f, m))
                }
            }
        }
        files.sort { $0.when > $1.when }
        var out: [String] = []
        for f in files.prefix(40) {
            let id = f.url.deletingPathExtension().lastPathComponent
            let title = transcriptTitle(f.url)
            let display = title.isEmpty ? "Claude 세션 \(id.prefix(8))" : title
            out.append("{\"id\":\(jsonString(id)),\"title\":\(jsonString(display)),"
                + "\"lastUsed\":\(Int(f.when.timeIntervalSince1970)),\"linked\":\(already.contains(id))}")
        }
        return "{\"now\":\(Int(Date().timeIntervalSince1970)),\"sessions\":[\(out.joined(separator: ","))]}"
    }

    // The "최신 진행 내용" block under the 세션 정보 tab: the latest progress of the goal's
    // most-recently-used session. Picks the associated session whose transcript was touched
    // last, then renders its tail (the recent turns) so the user sees what it is doing now.
    private func renderCurrentContent(seq: Int) -> String {
        let (primary, linked) = DispatchQueue.main.sync { () -> (String, [String]) in
            let g = reviewStore.goals.first { $0.seq == seq }
            return (g?.sessionId ?? "", g?.linkedSessions ?? [])
        }
        var pageMsg = "", pageCli = ""
        if let store = goalChat(seq: seq) {
            (pageMsg, pageCli) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId) }
        }
        var ids: [String] = []
        func add(_ id: String) {
            let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !ids.contains(t) { ids.append(t) }
        }
        add(primary); add(pageMsg); add(pageCli); linked.forEach(add)

        let fm = FileManager.default
        var best: (url: URL, when: Date)?
        for id in ids {
            guard let url = transcriptURL(forSessionId: id),
                  let a = try? fm.attributesOfItem(atPath: url.path),
                  let m = a[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.when { best = (url, m) }
        }
        guard let b = best else {
            return "<p class=\"empty\">연결된 세션이 없습니다. 오른쪽 메신저·CLI로 시작하거나 “세션 정보”에서 세션을 연결하면 최신 진행 내용이 여기에 표시됩니다.</p>"
        }
        let title = transcriptTitle(b.url)
        let secs = Int(max(0, Date().timeIntervalSince(b.when)))
        let ago = secs < 60 ? "방금" : secs < 3600 ? "\(secs / 60)분 전"
                : secs < 86400 ? "\(secs / 3600)시간 전" : "\(secs / 86400)일 전"
        let head = "<div class=\"curhdr\"><span class=\"ct\">\(htmlEscape(title.isEmpty ? "세션" : title))</span>"
            + "<span class=\"cage\">마지막 진행 \(ago)</span></div>"
        return head + "<div class=\"curbody\">\(renderTranscriptTail(b.url, limit: 20))</div>"
    }

    // Seq-based wrapper so the blocking goalChatSend keeps compiling (goal scope).
    private func goalChatPreamble(seq: Int) -> String { goalChatPreamble(Scope(seq: seq, task: nil)) }

    // First-turn context that tells the chat its job: clarify THIS scope through conversation.
    // For a subtask the title comes from its _task.md anchor (no Goal exists), and the file
    // paths point at the subtask's own goal-core.md / goal-detail.md.
    private func goalChatPreamble(_ scope: Scope) -> String {
        let label: String
        let title: String
        if let task = scope.task {
            label = "goal-\(scope.seq) / \(task)"
            title = subtaskTitle(scope)
        } else {
            label = "goal-\(scope.seq)"
            title = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == scope.seq }?.text ?? "" }
        }
        let core = scope.coreURL?.path ?? ""
        let detail = scope.detailURL?.path ?? ""
        return """
        이 대화의 목적은 아래 목표(골)를 대화로 점점 더 명확하게 만드는 것입니다.
        - 골 번호: \(label)
        - 제목: \(title)
        - 핵심 버전 파일: \(core)
        - 디테일 버전 파일: \(detail)
        핵심/디테일 두 버전과 4개 섹션(문제정의·예상결과·예상해결방안·예상테스트시나리오) 관점에서 모호한 점을 질문해 목표를 또렷하게 다듬어 주세요. 특히 '문제정의'가 정확한지 가장 먼저 확인하세요(잘못 정의하면 모든 방향이 달라집니다). 필요하면 위 두 파일을 직접 읽고, 사용자가 요청하면 파일을 수정하거나 명령을 실행해 작업을 진행하세요. 한국어로 간결하게 답하세요.

        사용자에게 명확화 질문을 할 때는 본문 마크다운으로 길게 풀어쓰지 말고, 반드시 아래 형식의 cm-question 코드블록 하나로만 출력하세요(블록 앞에 짧은 맥락 한두 줄은 두어도 됩니다).
        ```cm-question
        {"q":[{"ask":"질문 한 줄","opts":[{"label":"짧은 선택지","why":"추천 이유 한 줄","rec":true},{"label":"다른 선택지"}]}]}
        ```
        규칙: 물어볼 질문을 q 배열에 모두 담고, 각 질문의 opts는 2~4개로 한다. 가장 가능성 높은 선택지 하나에만 rec를 true로 두고 why에 한 줄 근거를 적는다. label은 짧게 쓴다. 사용자는 직접 입력으로도 답할 수 있으니 모든 경우를 선택지로 나열할 필요는 없다. 질문이 아닌 일반 설명·답변은 평소대로 마크다운으로 답한다.
        """
    }

    // Map the dashboard's model picker to a claude --model alias. "자동"/"" => nil (default).
    private static func claudeModelAlias(_ key: String) -> String? {
        switch key {
        case "opus": return "claude-opus-4-8"
        case "sonnet": return "claude-sonnet-4-6"
        case "haiku": return "claude-haiku-4-5"
        default: return nil   // 자동: let claude use its configured default
        }
    }

    // Decode a browser image payload. Accepts a "data:image/png;base64,…" URL (preferred,
    // carries the type) or a bare base64 string. Returns the bytes + a best-guess extension.
    private static func decodeImageDataURL(_ s: String) -> (bytes: Data, ext: String)? {
        var b64 = s, ext = ""
        if s.hasPrefix("data:") {
            guard let comma = s.firstIndex(of: ",") else { return nil }
            let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]   // e.g. image/png;base64
            if let slash = meta.firstIndex(of: "/") {
                let after = meta[meta.index(after: slash)...]
                ext = String(after.prefix { $0.isLetter || $0.isNumber })
            }
            if ext == "jpeg" { ext = "jpg" }
            b64 = String(s[s.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (data, ext)
    }

    // MARK: Evidence files

    // Legacy on-disk folder holding a goal's uploaded files, keyed by UUID. New
    // uploads go to the number-named folder (attachmentsDir(forGoalId:)); this
    // remains for reading/cleaning files written before the move.
    static func evidenceDir(goalId: String) -> URL {
        AppPaths.sub("evidence").appendingPathComponent(goalId, isDirectory: true)
    }

    // New attachment folder for a goal, keyed by its number (goal-NN/attachments).
    // nil for an unnumbered goal (seq <= 0). Reads reviewStore — call on main.
    private func attachmentsDir(forGoalId id: String) -> URL? {
        guard let seq = reviewStore.goals.first(where: { $0.id == id })?.seq else { return nil }
        return IssuePaths.attachmentsDir(seq: seq)
    }

    // GET /evidence/<goalId>/<evidenceId> -> the stored file (bytes, MIME, name).
    // Returns nil (404) for unknown ids or missing files. Prefers the number-named
    // folder, falling back to the legacy UUID store so older uploads keep working.
    func serveEvidence(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["evidence", goalId, evidenceId]
        guard comps.count >= 3, comps[0] == "evidence" else { return nil }
        let goalId = comps[1], evId = comps[2]
        return DispatchQueue.main.sync {
            guard let ev = reviewStore.evidence(goalId: goalId, evidenceId: evId),
                  ev.kind == "file" else { return nil }
            var data: Data? = nil
            if let dir = attachmentsDir(forGoalId: goalId) {
                data = try? Data(contentsOf: dir.appendingPathComponent(ev.filename))
            }
            if data == nil {
                data = try? Data(contentsOf: Self.evidenceDir(goalId: goalId).appendingPathComponent(ev.filename))
            }
            guard let bytes = data else { return nil }
            let name = ev.title.isEmpty ? ev.filename : ev.title
            return (bytes, Self.mimeType(name), name)
        }
    }

    // GET /task-file?seq=NN&task=<folder>&name=<file> — download one file from a subtask's
    // own attachments/ folder. A subtask has no ReviewStore.Goal, so its attachments are
    // plain files (not evidence records); this is the file-based counterpart to
    // serveEvidence. The name is treated as a single component (no traversal).
    func serveTaskFile(_ path: String) -> (Data, String, String)? {
        guard let comps = URLComponents(string: "http://x" + path) else { return nil }
        let items = comps.queryItems ?? []
        let scope = Scope.from(query: path)
        guard scope.task != nil, let dir = scope.attachmentsDir else { return nil }
        let name = (items.first(where: { $0.name == "name" })?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != "..", !name.hasPrefix(".") else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return (bytes, Self.mimeType(name), name)
    }

    // MARK: BGM view (library manager + venue player)

    // GET /api/bgm/list — the BGM library (BPMLibrary, scanned from the music folder)
    // as JSON for the BGM view's player. id is the index into library.tracks; the player
    // streams that file from /bgm-audio/<id>. Snapshots on main so we never race the load.
    func bgmListJSON() -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) }
                    else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        let tracks = DispatchQueue.main.sync { library.tracks }
        let items = tracks.enumerated().map { (i, t) -> String in
            let bpm = t.bpm > 0 ? String(Int(t.bpm.rounded())) : "0"
            return "{\"id\":\(i),\"title\":\"\(esc(t.title))\",\"bpm\":\(bpm)}"
        }
        return "{\"tracks\":[\(items.joined(separator: ","))]}"
    }

    // GET /api/bgm/stats[?strategy=N] — per-track cumulative play time, ranked
    // longest-first, for the BGM 관리 page's "재생 시간 순위" section. Merges the persisted
    // totals with the still-open segment (audio.currentSegment) so a long-playing track
    // shows fresh time without writing on every tick. bpm is looked up from the current
    // library by file name.
    //
    // Strategy filter: no param → the ACTIVE strategy (the default view watches the
    // current strategy's data accumulate); strategy=0 → 전체 (merged across strategies);
    // strategy=N → that strategy only. The response also carries the strategy catalog
    // (전략 히스토리 section) so the page needs no extra endpoint.
    func bgmStatsJSON(_ path: String) -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) }
                    else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        // strategy=0 → 전체 (nil filter); missing → active strategy; N → that strategy.
        let stratParam = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "strategy" })?.value
        return DispatchQueue.main.sync {
            let active = trackPlayStats.activeStrategy
            let filter: Int?
            if let raw = stratParam, let n = Int(raw) { filter = (n == 0) ? nil : n }
            else { filter = active }
            var totals = trackPlayStats.totals(strategy: filter)
            // Fold in the in-flight segment so the currently playing track counts live.
            // The open segment accrues under the ACTIVE strategy, so it only belongs in
            // views that include it (전체 or the active strategy itself).
            var liveKey: String? = nil
            if let seg = audio.currentSegment(), filter == nil || filter == active {
                liveKey = seg.key
                var s = totals[seg.key] ?? TrackPlayStat(key: seg.key, title: seg.title, strategy: active)
                if !seg.title.isEmpty && seg.title != "-" { s.title = seg.title }
                s.seconds += seg.seconds
                totals[seg.key] = s
            }
            let bpmByKey = Dictionary(library.tracks.map { ($0.url.lastPathComponent, $0.bpm) },
                                      uniquingKeysWith: { a, _ in a })
            let sorted = totals.values.sorted {
                $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.plays > $1.plays
            }
            let items = sorted.map { s -> String in
                let bpm = bpmByKey[s.key] ?? 0
                let bpmStr = bpm > 0 ? String(Int(bpm.rounded())) : "0"
                let cur = (s.key == liveKey)
                return "{\"title\":\"\(esc(s.title))\",\"seconds\":\(Int(s.seconds.rounded())),"
                    + "\"plays\":\(s.plays),\"bpm\":\(bpmStr),\"current\":\(cur)}"
            }
            let total = Int(totals.values.reduce(0.0) { $0 + $1.seconds }.rounded())
            // Strategy catalog for the 전략 히스토리 section + the filter buttons.
            let strategies = trackPlayStats.strategies.map { s -> String in
                "{\"id\":\(s.id),\"name\":\"\(esc(s.name))\",\"start\":\"\(esc(s.startedAt))\","
                    + "\"end\":\"\(esc(s.endedAt))\",\"summary\":\"\(esc(s.summary))\","
                    + "\"retro\":\"\(esc(s.retro))\"}"
            }
            return "{\"total\":\(total),\"strategy\":\(filter ?? 0),\"activeStrategy\":\(active),"
                + "\"strategies\":[\(strategies.joined(separator: ","))],"
                + "\"tracks\":[\(items.joined(separator: ","))]}"
        }
    }

    // GET /api/bgm/now — what the activity-driven BGM (ConditionDirector) is playing right
    // now: the current track's library id (so the BGM view's 액티비티 탭 can load the SAME
    // file via /bgm-audio/<id>), plus condition/phase/target-BPM/profile for the status
    // card. id = -1 when nothing is playing or the track isn't in the library.
    // GET /api/bgm/plan — the 전략3 plan map plus live planning context: the slot
    // resolved for "now" and the theme folders that actually exist in the library,
    // so a planning pass (관리자 AI) can only reference real pools.
    func bgmPlanJSON() -> String {
        DispatchQueue.main.sync {
            var counts: [String: Int] = [:]
            for t in library.tracks where !t.theme.isEmpty { counts[t.theme, default: 0] += 1 }
            let themes = counts.keys.sorted()
            let themesJSON = "[" + themes.map { jsonString($0) }.joined(separator: ",") + "]"
            let countsJSON = "{" + themes.map { "\(jsonString($0)):\(counts[$0] ?? 0)" }.joined(separator: ",") + "}"
            let slot = bgmPlan.slot()
            return "{\"plan\":\(bgmPlan.planJSON()),"
                + "\"currentSlot\":\(jsonString(slot?.label ?? "")),"
                + "\"themes\":\(themesJSON),"
                + "\"themeCounts\":\(countsJSON)}"
        }
    }

    func bgmNowJSON() -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n", "\r", "\t": o += " "
                default:
                    if c.value < 0x20 { o += " " } else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        return DispatchQueue.main.sync {
            guard let director = self.director else {
                return "{\"on\":false,\"playing\":false,\"working\":false,\"muted\":\(self.session.isMuted),\"id\":-1,\"title\":\"\",\"bpm\":0,\"phase\":\"-\",\"profile\":\"-\"}"
            }
            let tracks = library.tracks
            let id = audio.currentURL.flatMap { u in tracks.firstIndex(where: { $0.url == u }) } ?? -1
            // `on` = the BGM system is engaged (widget master on & director running). `playing`
            // = a resolvable track is actually streaming right now (id valid). They differ during
            // warm-up or a library reload — the client uses `on` for the live dot and `id>=0` to
            // decide there's a real track to follow, so it never lands in a stuck limbo.
            let on = director.isPlaying
            let playing = on && !audio.isPaused && id >= 0
            let title = audio.currentTitle ?? ""
            let phase = director.isIdleMode ? "IDLE" : (director.isActive ? director.phase.rawValue : "-")
            let profile = on ? director.activeProfileLabel : "-"
            // 전략3 plan slot: resolve live (not the director's cache) so the label is
            // right even before the first decision tick. A live 폭우 리셋 overrides the
            // shown situation (it wins over the plan gate).
            let plan: String
            if director.rainActive {
                let rem = director.rainRemaining.map { " \(Int($0/60))분" } ?? ""
                plan = "🌧 폭우 리셋\(rem)"
            } else {
                plan = self.bgmPlan.slot()?.label ?? "-"
            }
            let bpm = Int(director.targetBPM.rounded())
            return "{\"on\":\(on),\"playing\":\(playing),\"working\":\(self.isWorking),\"muted\":\(self.session.isMuted),\"id\":\(id),\"title\":\"\(esc(title))\","
                + "\"bpm\":\(bpm),\"phase\":\"\(esc(phase))\",\"profile\":\"\(esc(profile))\",\"plan\":\"\(esc(plan))\"}"
        }
    }

    // GET /bgm-audio/<id> — stream one library track's raw file bytes. Same-origin, so the
    // BGM player's createMediaElementSource and offline .wav export are not CORS-tainted.
    // The track url is snapshotted on main; the (possibly large) file read stays off-main.
    func serveBGMAudio(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["bgm-audio", id]
        guard comps.count >= 2, comps[0] == "bgm-audio", let id = Int(comps[1]) else { return nil }
        let url: URL? = DispatchQueue.main.sync {
            let t = library.tracks
            return (id >= 0 && id < t.count) ? t[id].url : nil
        }
        guard let u = url, let bytes = try? Data(contentsOf: u) else { return nil }
        let mime: String
        switch u.pathExtension.lowercased() {
        case "mp3":          mime = "audio/mpeg"
        case "m4a", "aac":   mime = "audio/mp4"
        case "wav":          mime = "audio/wav"
        case "aiff", "aif":  mime = "audio/aiff"
        case "caf":          mime = "audio/x-caf"
        default:             mime = "application/octet-stream"
        }
        return (bytes, mime, u.lastPathComponent)
    }

    // GET /api/debug/snapshot?mode=bgm|dashboard[&tab=activity|debug] — QA-only PNG snapshot of the
    // app window's WKWebView, used to embed real per-page screenshots in SPEC.html. Requires the
    // window to already be open (does not open it itself, mirroring /api/debug/window-mode).
    func serveSnapshot(_ path: String) -> (Data, String, String)? {
        let q = URLComponents(string: "http://x" + path)?.queryItems ?? []
        let modeStr = q.first(where: { $0.name == "mode" })?.value ?? "bgm"
        let tab = q.first(where: { $0.name == "tab" })?.value
        guard let mode = AppWindowController.Mode(rawValue: modeStr) else { return nil }
        guard let png = appWindowSnapshotPNG(mode: mode, tab: tab) else { return nil }
        return (png, "image/png", "snapshot.png")
    }

    // MARK: Goal page (/goal?n=<NN>[&t=<task>])

    // One goal's page: number, title, key metrics, definition (goal.md) and the
    // attachment list with add/remove/download controls. Looked up by stable seq.
    // With &t=<task> it instead renders the SUBTASK page (the same interface scoped to
    // goal-NN/tasks/<task>) — handled in goalSubtaskPage.
    func goalPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let raw = comps.queryItems?.first(where: { $0.name == "n" })?.value else { return nil }
        let digits = raw.replacingOccurrences(of: "goal-", with: "").filter { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        // A subtask request (&t=…/&task=…) routes to the subtask page; a goal request keeps
        // the exact path below unchanged.
        let scope = Scope.from(query: path)
        if let task = scope.task { return goalSubtaskPage(seq: n, task: task) }
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == n } }
        guard let goal = goalOpt else {
            // No registered Goal for this number. But a folder-only goal (e.g. an archive
            // goal created by hand and cross-linked from another goal's doc) still has a
            // goal-core.md worth showing — render it read-only so the link lands on content
            // instead of a dead end. Falls through to the real empty-state only if no folder.
            let fm = FileManager.default
            let hasFolder = IssuePaths.goalDir(seq: n).map { fm.fileExists(atPath: $0.path) } ?? false
            if hasFolder {
                return goalPageHTML(seq: n, title: IssuePaths.label(seq: n) ?? "goal-\(n)", goalId: "",
                    meta: "", sessionLink: "", sessionSummary: "",
                    coreHTML: renderVersion(scope, detail: false),
                    detailHTML: renderVersion(scope, detail: true),
                    currentHTML: "", attachments: "<p class=\"empty\">등록된 골이 아니라 첨부는 표시되지 않습니다.</p>",
                    subtasks: renderSubtasks(seq: n))
            }
            return goalPageHTML(seq: n, title: "goal-\(n)", goalId: "", meta: "", sessionLink: "",
                sessionSummary: "",
                coreHTML: "<p class=\"empty\">번호 \(n)에 해당하는 골이 없습니다.</p>", detailHTML: "",
                currentHTML: "", attachments: "<p class=\"empty\">번호 \(n)에 해당하는 골이 없습니다.</p>")
        }
        migrateDefinitionIfNeeded(scope)
        return goalPageHTML(seq: n, title: goal.text, goalId: goal.id,
            meta: goalMetaLine(goal), sessionLink: goalSessionLink(goal),
            sessionSummary: goalSessionSummary(goal),
            coreHTML: renderVersion(scope, detail: false),
            detailHTML: renderVersion(scope, detail: true),
            currentHTML: renderCurrentContent(seq: n),
            attachments: renderAttachments(goal),
            subtasks: renderSubtasks(seq: n))
    }

    // The SUBTASK page: the same interface as the goal page, scoped to goal-NN/tasks/<task>.
    // Its own messenger conversation, CLI session rooted in the subtask folder, docs,
    // attachments and linked sessions — all isolated. Renders a friendly empty state if the
    // subtask folder doesn't exist. The 부분과제 section is intentionally omitted (a subtask
    // has no nested subtasks here), and the header links back to the parent goal.
    func goalSubtaskPage(seq: Int, task: String) -> String? {
        let scope = Scope(seq: seq, task: task)
        let fm = FileManager.default
        guard let work = scope.workDir, fm.fileExists(atPath: work.path) else {
            // Folder missing: a dead subtask link. Show a calm empty state that points back
            // to the parent goal instead of a 404.
            return goalPageHTML(seq: seq, task: task, title: task, goalId: "",
                meta: "", sessionLink: "", sessionSummary: "",
                coreHTML: "<p class=\"empty\">부분과제 폴더를 찾을 수 없습니다: <code>\(htmlEscape(scope.workDir?.path ?? task))</code></p>",
                detailHTML: "", currentHTML: "",
                attachments: "<p class=\"empty\">부분과제 폴더가 없습니다.</p>",
                subtasks: "",
                backHref: "/goal?n=\(seq)", backLabel: "← goal-\(seq)")
        }
        migrateDefinitionIfNeeded(scope)
        // The subtask CLI/messenger isolate per folder; "goalId" stays "" so the goal-only
        // evidence (link upload / ReviewStore) controls don't render — the subtask uses its
        // own file-based attachments instead (handled by goalPageHTML's task branch).
        return goalPageHTML(seq: seq, task: task, title: subtaskTitle(scope), goalId: "",
            meta: "", sessionLink: "", sessionSummary: subtaskSessionSummary(),
            coreHTML: renderVersion(scope, detail: false),
            detailHTML: renderVersion(scope, detail: true),
            currentHTML: "",
            attachments: renderAttachments(scope),
            subtasks: "",
            backHref: "/goal?n=\(seq)", backLabel: "← goal-\(seq)")
    }

    // The 세션 정보 card for a subtask page: no Goal lifecycle rows, just the connected-session
    // list + picker (loaded by the same loadSessions/openSessPicker JS as a goal, scoped via
    // TASK so /api/goal/sessions and the link/unlink endpoints hit the subtask's own store).
    private func subtaskSessionSummary() -> String {
        let sessUI = """
          <div class="sesshead"><span class="sklabel">연결된 세션</span><button class="lnk" onclick="openSessPicker()">+ 세션 연결</button></div>
          <div id="sessList" class="sesslist"><span class="mut">불러오는 중…</span></div>
        """
        return "<section class=\"seccard sess\"><h3>세션 정보</h3>\(sessUI)</section>"
    }

    // When a Claude session is attached to this goal, surface a clickable link to its
    // transcript (and minute-by-minute breakdown) right under the header meta line.
    // Empty when no session is linked, so the row simply doesn't render.
    private func goalSessionLink(_ g: ReviewStore.Goal) -> String {
        guard !g.sessionId.isEmpty else { return "" }
        let gid = htmlEscape(g.id)
        return """
          <div class="slink">
            <a class="chip" href="/transcript?goal=\(gid)" target="_blank" rel="noopener">🔗 세션 트랜스크립트 보기</a>
            <a class="chip" href="/breakdown?goal=\(gid)" target="_blank" rel="noopener">📊 작업 분석</a>
          </div>
        """
    }

    // A compact "세션 정보" card shown at the top of the 핵심 버전 so a goal that has only
    // been worked on via the messenger/CLI/Claude Code session still surfaces something
    // durable: current status, accumulated work time, value/tokens, the linked session id
    // and links to its transcript and minute-by-minute breakdown.
    private func goalSessionSummary(_ g: ReviewStore.Goal) -> String {
        let labels = ["backlog": "대기", "in_progress": "진행", "waiting": "응답 대기",
                      "stopped": "중지", "cancelled": "취소", "done": "완료"]
        let st = labels[g.status] ?? g.status
        let secs = g.trackedSeconds + (g.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        var rows = ""
        rows += "<div class=\"srow\"><span class=\"sk\">상태</span><span class=\"sv\">\(htmlEscape(st))</span></div>"
        rows += "<div class=\"srow\"><span class=\"sk\">작업 시간</span><span class=\"sv\">\(h)시간 \(m)분</span></div>"
        rows += "<div class=\"srow\"><span class=\"sk\">가치 · 토큰</span><span class=\"sv\">\(g.value) · \(g.tokens)K</span></div>"
        // The session list itself is loaded by JS (loadSessions) so last-used times stay
        // fresh on reload and the picker can refresh it after linking. "세션 연결" opens the
        // recent-session picker to attach more sessions worked on this goal.
        let sessUI = """
          <div class="sesshead"><span class="sklabel">연결된 세션</span><button class="lnk" onclick="openSessPicker()">+ 세션 연결</button></div>
          <div id="sessList" class="sesslist"><span class="mut">불러오는 중…</span></div>
        """
        return "<section class=\"seccard sess\"><h3>세션 정보</h3>\(rows)\(sessUI)</section>"
    }

    // Bring an older single-version definition into the core/detail split on first page
    // open. The pre-existing detailed doc (legacy flat .issue/goal-NN.md or the folder's
    // goal.md) becomes the 디테일 버전 (goal-detail.md); the 핵심 버전 starts empty for the
    // user to fill via the messenger. Idempotent and non-destructive (a no-op once
    // goal-detail.md exists).
    private func migrateDefinitionIfNeeded(_ scope: Scope) {
        guard let dst = scope.detailURL else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path) else { return }
        if let task = scope.task {
            // A subtask has no legacy goal.md / flat doc lineage; instead promote the first
            // pre-existing doc it commonly carries into goal-detail.md (non-destructively),
            // leaving goal-core.md untouched so a subtask that already has one shows at once.
            guard let work = IssuePaths.taskDir(seq: scope.seq, task: task) else { return }
            for cand in ["goal.md", "문제정의.md", "readme.md", "README.md"] {
                let src = work.appendingPathComponent(cand)
                if fm.fileExists(atPath: src.path) {
                    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: src, to: dst)
                    return
                }
            }
            return
        }
        var src: URL? = nil
        if let d = IssuePaths.definitionURL(seq: scope.seq), fm.fileExists(atPath: d.path) { src = d }
        else if let l = IssuePaths.legacyDefinitionURL(seq: scope.seq), fm.fileExists(atPath: l.path) { src = l }
        guard let s = src else { return }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: s, to: dst)
    }

    // The four canonical goal sections, in order, each with the one-line purpose hint
    // surfaced under its title (mirrors .doc/goal-policy.md).
    private static let goalSectionHints: [(label: String, hint: String)] = [
        ("문제정의", "어떤 문제를 풀 것인가 — 가장 중요. 잘못 정의하면 모든 방향이 달라진다."),
        ("예상결과", "문제정의를 바텀업으로 검증하는 기대 결과."),
        ("예상해결방안", "당장 떠오르는 방향(확정 아닌 제안)."),
        ("예상테스트시나리오", "결과를 받았을 때 통과/실패를 즉시 판단하는 기준."),
    ]

    // Render one version (core or detail) as section cards. Reads the file, or returns an
    // empty-state pointing at the path + the messenger when the version is missing/blank.
    private func renderVersion(_ scope: Scope, detail: Bool) -> String {
        let url = detail ? scope.detailURL : scope.coreURL
        let fm = FileManager.default
        let text: String
        if let u = url, fm.fileExists(atPath: u.path), let data = try? Data(contentsOf: u) {
            text = String(decoding: data, as: UTF8.self)
        } else { text = "" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind = detail ? "디테일" : "핵심"
            let p = url?.path ?? ""
            return "<p class=\"empty\">\(kind) 버전이 비어 있습니다. <code>\(htmlEscape(p))</code> 에 작성하거나, 오른쪽 메신저로 대화하며 정리하세요.</p>"
        }
        return renderGoalDoc(text)
    }

    // Split a goal markdown doc on its H2 (## ) headings into (intro, [(heading, body)]).
    private func splitSections(_ md: String) -> (intro: String, sections: [(String, String)]) {
        var sections: [(String, String)] = []
        var intro = ""
        var heading: String? = nil
        var bodyLines: [String] = []
        func flush() {
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let h = heading { sections.append((h, body)) } else { intro = body }
            bodyLines = []
        }
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                bodyLines.append(line)
            }
        }
        flush()
        return (intro, sections)
    }

    // Render a goal doc as the four canonical section cards (in policy order), each with
    // its purpose hint. Recognized headings are matched by keyword; missing ones show a
    // placeholder; any extra headings are appended after. A doc with no headings at all
    // (legacy free-form) falls back to a single raw block so old goals still read fine.
    //
    // Each body is emitted as an HTML-escaped `.mdbody` block: the raw markdown lives as the
    // element's text, and the client renders it to formatted HTML (marked.js) on load, then
    // linkifies `goal-NN` references. The edit textarea still loads the raw markdown from the
    // API, so the input screen keeps showing plain markdown while the read view is a preview.
    private func renderGoalDoc(_ md: String) -> String {
        let (intro, secs) = splitSections(md)
        if secs.isEmpty {
            let t = md.trimmingCharacters(in: .whitespacesAndNewlines)
            return "<div class=\"mdbody\">\(htmlEscape(t))</div>"
        }
        var used = Set<Int>()
        var html = ""
        if !intro.isEmpty {
            html += "<section class=\"seccard\"><div class=\"mdbody\">\(htmlEscape(intro))</div></section>"
        }
        for canon in Self.goalSectionHints {
            var bodyHTML = "<p class=\"hint\">아직 작성되지 않았습니다 — 오른쪽 메신저로 대화하며 채워 보세요.</p>"
            var filled = false
            for i in secs.indices where !used.contains(i) {
                if secs[i].0.contains(canon.label) {
                    used.insert(i)
                    let body = secs[i].1
                    if body.isEmpty {
                        bodyHTML = "<p class=\"hint\">(비어 있음)</p>"
                    } else {
                        bodyHTML = "<div class=\"mdbody\">\(htmlEscape(body))</div>"
                        filled = true
                    }
                    break
                }
            }
            html += goalSecCard(title: canon.label, hint: canon.hint, bodyHTML: bodyHTML, empty: !filled)
        }
        for i in secs.indices where !used.contains(i) {
            let body = secs[i].1
            let bodyHTML = body.isEmpty ? "" : "<div class=\"mdbody\">\(htmlEscape(body))</div>"
            html += goalSecCard(title: secs[i].0, hint: "", bodyHTML: bodyHTML, empty: body.isEmpty)
        }
        return html
    }

    // An empty section shows only its dimmed title. The purpose hint and the
    // "아직 작성되지 않았습니다" placeholder live in the card's native tooltip so they
    // surface as guidance on hover — never inside the box masquerading as content.
    // A filled section renders fully; an empty one stays quiet.
    private func goalSecCard(title: String, hint: String, bodyHTML: String, empty: Bool) -> String {
        if empty {
            let placeholder = "아직 작성되지 않았습니다 — 오른쪽 메신저로 대화하며 채워 보세요."
            let tip = hint.isEmpty ? placeholder : "\(hint)\n\(placeholder)"
            return "<section class=\"seccard secempty\" title=\"\(htmlEscape(tip))\"><h3>\(htmlEscape(title))</h3></section>"
        }
        let h = hint.isEmpty ? "" : "<div class=\"sechint\">\(htmlEscape(hint))</div>"
        return "<section class=\"seccard\"><h3>\(htmlEscape(title))</h3>\(h)\(bodyHTML)</section>"
    }

    private func renderAttachments(_ g: ReviewStore.Goal) -> String {
        if g.evidence.isEmpty {
            return "<p class=\"empty\">첨부가 없습니다. 아래에서 링크나 파일을 추가하세요.</p>"
        }
        var items = ""
        for e in g.evidence {
            let href = e.kind == "file" ? "/evidence/\(g.id)/\(e.id)" : e.url
            let icon = e.kind == "file" ? "📄" : "🔗"
            let title = e.title.isEmpty ? href : e.title
            let extra = e.kind == "file" ? " download" : " target=\"_blank\" rel=\"noopener\""
            items += "<li><a href=\"\(htmlEscape(href))\"\(extra)>\(icon) \(htmlEscape(title))</a>"
                + "<button class=\"x\" onclick=\"rm('\(htmlEscape(e.id))')\">삭제</button></li>"
        }
        return "<ul class=\"atts\">\(items)</ul>"
    }

    // A subtask has no Goal (so no ReviewStore.evidence): list the files physically present
    // in its attachments/ folder. Each downloads via /task-file?seq=&task=&name=. Removal is
    // keyed by the bare filename (rm passes it through to /api/goal/evidence/remove).
    private func renderAttachments(_ scope: Scope) -> String {
        guard let dir = scope.attachmentsDir, let task = scope.task else {
            return "<p class=\"empty\">첨부가 없습니다.</p>"
        }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
        if names.isEmpty {
            return "<p class=\"empty\">첨부가 없습니다. 아래에서 파일을 추가하세요.</p>"
        }
        let seq = scope.seq
        let tq = Self.queryEncode(task)
        var items = ""
        for name in names {
            let href = "/task-file?seq=\(seq)&task=\(tq)&name=\(Self.queryEncode(name))"
            items += "<li><a href=\"\(htmlEscape(href))\" download>📄 \(htmlEscape(name))</a>"
                + "<button class=\"x\" onclick=\"rm('\(htmlEscape(name))')\">삭제</button></li>"
        }
        return "<ul class=\"atts\">\(items)</ul>"
    }

    // Pull one frontmatter field from a _task.md (the YAML-ish "key: value" lines between
    // the leading --- fences). A trailing inline "# comment" and surrounding whitespace are
    // stripped. nil when the field is absent. Mirrors gen-index.sh's get_field so the web
    // 부분과제 table and the on-disk INDEX.md read the same anchors identically.
    private func taskField(_ md: String, _ key: String) -> String? {
        var inFM = false
        for (i, raw) in md.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 { if trimmed == "---" { inFM = true; continue } else { return nil } }
            guard inFM else { continue }
            if trimmed == "---" { return nil }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = String(line[line.index(after: colon)...])
            if let hash = v.firstIndex(of: "#") { v = String(v[v.startIndex..<hash]) }
            return v.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // The display title for a subtask: its _task.md title (preferred), else its id, else the
    // folder name. Used for the subtask page header and the chat preamble. Never empty.
    private func subtaskTitle(_ scope: Scope) -> String {
        guard let task = scope.task, let work = IssuePaths.taskDir(seq: scope.seq, task: task) else {
            return scope.task ?? "goal-\(scope.seq)"
        }
        let anchor = work.appendingPathComponent("_task.md")
        if let data = try? Data(contentsOf: anchor) {
            let md = String(decoding: data, as: UTF8.self)
            if let t = taskField(md, "title"), !t.isEmpty { return t }
            if let i = taskField(md, "id"), !i.isEmpty { return i }
        }
        return task
    }

    // A colored pill for a subtask status, mapped to a Korean label. Unknown/blank
    // statuses (folders with no _task.md anchor) show as 미정 in the muted 대기 style.
    private func subtaskStatusBadge(_ status: String) -> String {
        let map: [String: (String, String)] = [
            "DOING": ("진행", "doing"), "BLOCKED": ("막힘", "blocked"),
            "TODO": ("대기", "todo"), "DONE": ("완료", "done"), "ARCHIVED": ("보관", "arch"),
        ]
        let (label, cls) = map[status.uppercased()] ?? (status.isEmpty ? "미정" : status, "todo")
        return "<span class=\"st \(cls)\">\(htmlEscape(label))</span>"
    }

    // Coerce a JSON value that may arrive as a string or a number into a trimmed string
    // (coin/week come in either shape from the client or an AI caller). "" when absent.
    private static func numString(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // Folder-safe slug for a subtask title: path separators, colons, quotes and hashes
    // become '-', whitespace collapses to '-', repeats fold, edges trim, capped at 40.
    // Korean is preserved. Mirrors the constraints IssuePaths.taskDir enforces so the
    // "taskN-<slug>" folder is always creatable.
    private static func taskSlug(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "/" || ch == "\\" || ch == ":" || ch == "#" || ch == "\"" || ch.isNewline || ch == "\t" || ch == " " {
                out.append("-")
            } else { out.append(ch) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return String(out.prefix(40))
    }

    // Create a new 부분과제 folder (goal-NN/tasks/taskN-<slug>) and write its _task.md anchor.
    // The next task number is 1 + the largest leading number across existing task* folders,
    // so it never collides even when earlier tasks were archived. Returns the new folder
    // name, or nil for an invalid goal number or a filesystem failure.
    private func addSubtaskFolder(seq: Int, title: String, status: String,
                                  coin: String, week: String, outputs: String) -> String? {
        guard let tasksDir = IssuePaths.tasksDir(seq: seq) else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        var maxN = 0
        if let entries = try? fm.contentsOfDirectory(atPath: tasksDir.path) {
            for name in entries where name.lowercased().hasPrefix("task") {
                var d = ""
                for ch in name.dropFirst(4) { if ch.isNumber { d.append(ch) } else { break } }
                if let n = Int(d) { maxN = max(maxN, n) }
            }
        }
        let n = maxN + 1
        let slug = Self.taskSlug(title)
        let folder = "task\(n)" + (slug.isEmpty ? "" : "-\(slug)")
        guard let dir = IssuePaths.taskDir(seq: seq, task: folder) else { return nil }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        // Single-line the title so it can't break the frontmatter fences.
        let oneLine = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusVal = st.isEmpty ? "TODO" : st.uppercased()
        var md = "---\nid: task\(n)\ntitle: \(oneLine)\nstatus: \(statusVal)\n"
        if !coin.isEmpty { md += "coin: \(coin)\n" }
        if !week.isEmpty { md += "week: \(week)\n" }
        if !outputs.isEmpty { md += "outputs: \(outputs)\n" }
        md += "---\n"
        try? md.write(to: dir.appendingPathComponent("_task.md"), atomically: true, encoding: .utf8)
        return folder
    }

    // Compact subtask summary for /data.json: one JSON object per ACTIVE (non-archived)
    // tasks/<taskN> folder — {folder,id,title,status}. The dashboard 목록 renders these as
    // task rows when the 유형(type) filter includes 'task'. Goals without a tasks/ folder
    // return "" after a single failed directory read, so the per-poll cost stays tiny.
    private func subtaskSummaryJSON(seq: Int) -> String {
        guard let dir = IssuePaths.tasksDir(seq: seq),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles])
        else { return "" }
        struct Row { var name, id, title, status: String }
        var rows: [Row] = []
        for url in entries {
            let name = url.lastPathComponent
            // _session_isolation etc.; archived subtasks stay off the active dashboard list.
            if name.hasPrefix("_") || name.hasPrefix("archived") { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            var id = name, title = "", status = ""
            let anchor = url.appendingPathComponent("_task.md")
            if let data = try? Data(contentsOf: anchor) {
                let md = String(decoding: data, as: UTF8.self)
                id = taskField(md, "id") ?? name
                title = taskField(md, "title") ?? ""
                status = taskField(md, "status") ?? ""
            } else if let dash = name.firstIndex(of: "-") {
                // No anchor: split "task1-round1-kwt" into id "task1" + title "round1-kwt".
                id = String(name[name.startIndex..<dash])
                title = String(name[name.index(after: dash)...])
            }
            if status.uppercased() == "ARCHIVED" { continue }
            rows.append(Row(name: name, id: id, title: title, status: status))
        }
        // Same ordering as the goal-page table: leading task number, then name.
        func numKey(_ n: String) -> Int {
            var d = ""
            for ch in n { if ch.isNumber { d.append(ch) } else if !d.isEmpty { break } }
            return Int(d) ?? 9999
        }
        rows.sort { a, b in
            let an = numKey(a.name), bn = numKey(b.name)
            if an != bn { return an < bn }
            return a.name < b.name
        }
        return rows.map {
            "{\"folder\":\(jsonString($0.name)),\"id\":\(jsonString($0.id)),"
                + "\"title\":\(jsonString($0.title)),\"status\":\(jsonString($0.status))}"
        }.joined(separator: ",")
    }

    // Render the goal's tasks/ subfolders as a Jira-style 부분과제 table. Each child folder
    // is one subtask; a _task.md anchor (frontmatter id/title/status/coin/week/outputs)
    // supplies metadata, else the folder name is split into a short id + title. Returns ""
    // when the goal has no tasks/ folder or it holds no task subfolders, so the section
    // simply doesn't render for the vast majority of goals that don't use subtasks.
    private func renderSubtasks(seq: Int) -> String {
        guard let dir = IssuePaths.tasksDir(seq: seq) else { return "" }
        let fm = FileManager.default
        // Missing tasks/ folder is fine — the section still renders its shell so the
        // "+ 태스크 추가" control is available on every goal (0건 included).
        let entries = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        struct Row { var name, id, title, status, coin, week, outputs: String }
        var rows: [Row] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("_") { continue }  // _session_isolation and other tooling
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }         // skip INDEX.md and stray files
            var id = name, title = "", status = "", coin = "", week = "", outputs = ""
            let anchor = url.appendingPathComponent("_task.md")
            let hasAnchor = fm.fileExists(atPath: anchor.path)
            if hasAnchor, let data = try? Data(contentsOf: anchor) {
                let md = String(decoding: data, as: UTF8.self)
                id = taskField(md, "id") ?? name
                title = taskField(md, "title") ?? ""
                status = taskField(md, "status") ?? ""
                coin = taskField(md, "coin") ?? ""
                week = taskField(md, "week") ?? ""
                outputs = taskField(md, "outputs") ?? ""
            }
            if !hasAnchor {
                // No anchor: split "task1-round1-kwt" into id "task1" + title "round1-kwt".
                if let dash = name.firstIndex(of: "-") {
                    id = String(name[name.startIndex..<dash])
                    title = String(name[name.index(after: dash)...])
                } else { id = name }
            }
            if name.hasPrefix("archived") && status.isEmpty { status = "ARCHIVED" }
            rows.append(Row(name: name, id: id, title: title, status: status,
                            coin: coin, week: week, outputs: outputs))
        }
        // Leading task number drives order (task1…task26); archived folders sink to the end.
        func numKey(_ n: String) -> Int {
            var d = ""
            for ch in n { if ch.isNumber { d.append(ch) } else if !d.isEmpty { break } }
            return Int(d) ?? 9999
        }
        rows.sort { a, b in
            let aa = a.name.hasPrefix("archived") ? 1 : 0, bb = b.name.hasPrefix("archived") ? 1 : 0
            if aa != bb { return aa < bb }
            let an = numKey(a.name), bn = numKey(b.name)
            if an != bn { return an < bn }
            return a.name < b.name
        }
        var body = ""
        var activeCount = 0
        for r in rows {
            // Archived subtasks are hidden by default; the 상태 filter reveals 보관/전체.
            let isArch = r.name.hasPrefix("archived") || r.status.uppercased() == "ARCHIVED"
            if !isArch { activeCount += 1 }
            let meta = [r.coin, r.week].filter { !$0.isEmpty && $0 != "-" }.joined(separator: " · ")
            let out = (r.outputs.isEmpty || r.outputs == "-") ? "" : "<code>\(htmlEscape(r.outputs))</code>"
            let shownTitle = r.title.isEmpty ? "—" : r.title
            let cls = isArch ? "subt-row arch" : "subt-row"
            let hidden = isArch ? " style=\"display:none\"" : ""
            // Each row's 태스크 id links to the subtask page (/goal?n=NN&t=<encoded folder>),
            // where the folder name (spaces/colons and all) is percent-encoded for the query.
            let href = "/goal?n=\(seq)&t=\(Self.queryEncode(r.name))"
            body += "<tr class=\"\(cls)\"\(hidden)>"
            body += "<td class=\"tid\"><a class=\"tlink\" href=\"\(htmlEscape(href))\">\(htmlEscape(r.id))</a></td>"
            body += "<td class=\"ttitle\">\(htmlEscape(shownTitle))</td>"
            body += "<td>\(subtaskStatusBadge(r.status))</td>"
            body += "<td class=\"tmeta\">\(htmlEscape(meta))</td>"
            body += "<td class=\"tout\">\(out)</td>"
            body += "</tr>"
        }
        // 상태 filter menu (mirrors the dashboard's Active/Archived/All control). All rows
        // ship in the HTML; the select just toggles row visibility client-side. The
        // "+ 태스크 추가" control opens an inline form that POSTs /api/goal/task — the same
        // endpoint an AI calls to file a task under this goal (e.g. a 주보상 패키지) instead
        // of creating a whole new goal.
        let tools = """
          <div class="subt-tools">
            <label class="subt-flt">상태 <select class="modesel" onchange="filterSubtasks(this.value)"><option value="active" selected>활성</option><option value="archived">보관</option><option value="all">전체</option></select></label>
            <button type="button" class="subt-addbtn" onclick="addSubtaskToggle()">+ 태스크 추가</button>
          </div>
          <div id="subtAddForm" class="subt-addform" style="display:none">
            <input id="subtAddTitle" type="text" placeholder="제목 (예: 주보상 패키지)" onkeydown="if(event.key==='Enter')submitSubtask()" />
            <select id="subtAddStatus" class="modesel">
              <option value="TODO" selected>대기</option>
              <option value="DOING">진행</option>
              <option value="DONE">완료</option>
              <option value="BLOCKED">막힘</option>
            </select>
            <input id="subtAddCoin" type="text" class="subt-addsm" placeholder="코인" />
            <input id="subtAddWeek" type="text" class="subt-addsm" placeholder="주차" />
            <input id="subtAddOut" type="text" placeholder="산출물" />
            <button id="subtAddBtn" type="button" class="subt-addgo" onclick="submitSubtask()">추가</button>
          </div>
        """
        // Empty goals still render the table shell (with a muted hint row) so the section
        // reads as an intentional place to add tasks, not a rendering gap.
        let tbody = rows.isEmpty
            ? "<tr class=\"subt-empty\"><td colspan=\"5\">아직 부분과제가 없습니다. “+ 태스크 추가”로 만들어 보세요.</td></tr>"
            : body
        let table = """
          <table class="subtasks">
            <thead><tr><th>태스크</th><th>제목</th><th>상태</th><th>코인·주차</th><th>산출물</th></tr></thead>
            <tbody>\(tbody)</tbody>
          </table>
        """
        let head = "<h2 class=\"atth\" onclick=\"toggleTasks()\">부분과제 <span id=\"subtCount\" class=\"subt-count\">\(activeCount)건</span> <span id=\"tasksToggle\" class=\"att-toggle\">▾ 접기</span></h2>"
        return head + "<div id=\"tasksWrap\">" + tools + table + "</div>"
    }

    private func goalMetaLine(_ g: ReviewStore.Goal) -> String {
        let labels = ["backlog": "대기", "in_progress": "진행", "waiting": "대기",
                      "stopped": "중지", "cancelled": "취소", "done": "완료"]
        let st = labels[g.status] ?? g.status
        let secs = g.trackedSeconds + (g.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return "상태 \(htmlEscape(st)) · 가치 \(g.value) · 토큰 \(g.tokens)K · 작업 \(h)시간 \(m)분"
    }

    private func goalPageHTML(seq: Int, task: String = "", title: String, goalId: String,
                             meta: String, sessionLink: String, sessionSummary: String,
                             coreHTML: String, detailHTML: String, currentHTML: String,
                             attachments: String, subtasks: String = "",
                             backHref: String = "/", backLabel: String = "← 대시보드") -> String {
        // A subtask page renders the same interface scoped to one tasks/<task> folder. The
        // version-editor / messenger / CLI / session / attachment controls are gated on
        // having a writable scope: real goals (goalId set) or any subtask (task set).
        let isTask = !task.isEmpty
        let editable = !goalId.isEmpty || isTask
        let label = isTask ? "goal-\(seq)" : (IssuePaths.label(seq: seq) ?? "goal-\(seq)")
        // The header chip shows the goal label for a goal, or the subtask's id (its _task.md
        // id, else the leading "taskNN" piece of the folder) for a subtask.
        let numChip: String = {
            guard isTask else { return label }
            let anchor = IssuePaths.taskDir(seq: seq, task: task)?.appendingPathComponent("_task.md")
            if let a = anchor, let data = try? Data(contentsOf: a),
               let id = taskField(String(decoding: data, as: UTF8.self), "id"), !id.isEmpty { return id }
            if let dash = task.firstIndex(of: "-") { return String(task[task.startIndex..<dash]) }
            return task
        }()
        // Inline-edit controls for the 핵심 버전 (for a real goal or a subtask). The "수정"
        // button swaps the rendered display for a textarea loaded from goal-core.md;
        // 저장 writes it back via /api/goal/definition/save and reloads.
        let coreEditHead = !editable ? "" : """
          <div class="verhead">
            <button id="coreEditBtn" onclick="enterEdit()">수정</button>
            <div id="coreEditActions" class="editacts" style="display:none">
              <button class="save" onclick="saveCore()">저장</button>
              <button class="x" onclick="cancelEdit()">취소</button>
            </div>
          </div>
        """
        let coreEditor = !editable ? "" :
          "<textarea id=\"coreEditor\" class=\"vereditor\" style=\"display:none\" placeholder=\"핵심 버전 내용을 마크다운으로 작성하세요…\"></textarea>"
        // Double-click the rendered core version to drop into edit mode (goal or subtask).
        let coreDispAttr = !editable ? "" : " class=\"coredisp\" ondblclick=\"enterEdit()\" title=\"더블클릭하면 수정\""
        // The link-add input is goal-only (a subtask stores files in its own attachments/);
        // a subtask shows just the file picker.
        let linkInput = goalId.isEmpty ? "" : """
            <input type="text" id="lk" placeholder="https://… 링크 붙여넣기" onkeydown="if(event.key==='Enter')addLink()">
            <button onclick="addLink()">링크 추가</button>
        """
        let controls = !editable ? "" : """
          <div class="add">
            \(linkInput)
            <label class="filebtn">파일 첨부<input type="file" multiple style="display:none" onchange="addFiles(this)"></label>
          </div>
        """
        // Evidence add/remove. A real goal goes through ReviewStore (id-keyed); a subtask
        // writes into / removes from its own attachments/ folder (scope-keyed: seq+task).
        // Chat script is always present.
        let evScript = !editable ? "" : """
          <script>
          const GID=\(jsonString(goalId)); const EVTASK=\(jsonString(task));
          function post(p,b){return fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});}
          function addLink(){const el=document.getElementById('lk');if(!el)return;const u=el.value.trim();if(!u)return;
            post('/api/goal/evidence/add',{id:GID,seq:\(seq),task:EVTASK,kind:'link',url:u}).then(()=>location.reload());}
          function addFiles(input){const fs=[...input.files];if(!fs.length)return;let done=0;
            fs.forEach(f=>{const r=new FileReader();r.onload=()=>{post('/api/goal/evidence/add',{id:GID,seq:\(seq),task:EVTASK,kind:'file',filename:f.name,data:r.result}).then(()=>{done++;if(done===fs.length)location.reload();});};r.readAsDataURL(f);});}
          function rm(eid){if(!confirm('이 첨부를 삭제할까요?'))return;post('/api/goal/evidence/remove',{id:GID,seq:\(seq),task:EVTASK,evidenceId:eid}).then(()=>location.reload());}
          </script>
        """
        // Per-goal "목표 명확화" messenger: load history, send a turn (optimistic bubble +
        // pending placeholder while claude runs), reset. Keyed by SEQ; no template literals
        // so Swift never mistakes JS for string interpolation.
        let chatScript = """
          <script>
          const SEQ=\(seq);
          const TASK=\(jsonString(task));
          // GET query suffix carrying the scope: empty for a goal, &task=… for a subtask.
          const TQ=TASK?('&task='+encodeURIComponent(TASK)):'';
          let streaming=false, es=null, curBub=null, curText='', thinkBub=null, thinkText='', toolCards={}, lastMode='';
          function esc(s){ return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
          // Markdown: marked from CDN (lazy), with a small sanitizer; plain-text fallback offline.
          function loadMarked(){ if(window.marked) return; var s=document.createElement('script');
            s.src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'; document.head.appendChild(s); }
          function sanitize(h){ return (h||'')
            .replace(/<\\/?(script|style|iframe|object|embed|link|meta|base)[^>]*>/gi,'')
            .replace(/ on[a-z]+\\s*=\\s*("[^"]*"|'[^']*'|[^\\s>]+)/gi,'')
            .replace(/javascript:/gi,''); }
          function md(text){ if(window.marked){ try{ return sanitize(window.marked.parse(text||'',{breaks:true})); }catch(e){} }
            return esc(text||'').replace(/\\n/g,'<br>'); }
          // Run cb once marked.js has loaded from the CDN, or after a short wait (fallback:
          // md() then degrades to plain text). Keeps the read view from flashing raw markdown.
          function whenMarked(cb,n){ if(window.marked){cb();return;} if((n||0)>60){cb();return;}
            setTimeout(function(){ whenMarked(cb,(n||0)+1); },50); }
          // Wrap every `goal-NN` reference inside an element's rendered text in a link to that
          // goal's page (/goal?n=NN). Walks text nodes only, skips text already inside an <a>,
          // and leaves "goalNN"/"agoal-1"/"goal-1a" alone (word boundaries).
          function linkifyGoals(root){
            var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null), nodes=[];
            while(w.nextNode()){ nodes.push(w.currentNode); }
            var re=/(^|[^A-Za-z0-9])goal-([0-9]+)(?![0-9A-Za-z])/gi;
            nodes.forEach(function(node){
              if(node.parentNode&&node.parentNode.closest&&node.parentNode.closest('a')) return;
              var t=node.nodeValue; if(!/goal-[0-9]/i.test(t)) return;
              var frag=document.createDocumentFragment(), last=0, m; re.lastIndex=0;
              while((m=re.exec(t))){
                var pre=m[1], num=m[2], full='goal-'+num, start=m.index+pre.length;
                frag.appendChild(document.createTextNode(t.slice(last,start)));
                var a=document.createElement('a'); a.className='goallink';
                a.href='/goal?n='+parseInt(num,10); a.title=full+' 페이지로 이동'; a.textContent=full;
                frag.appendChild(a); last=start+full.length;
              }
              frag.appendChild(document.createTextNode(t.slice(last)));
              node.parentNode.replaceChild(frag,node);
            });
          }
          // Turn each `.mdbody` block (raw markdown carried as its text) into a rendered
          // preview: parse with marked, then linkify goal references. The edit textarea is
          // unaffected — it still loads plain markdown from the API.
          function renderMdBodies(){
            var els=document.querySelectorAll('.mdbody:not(.rendered)');
            if(!els.length) return;
            whenMarked(function(){
              els.forEach(function(el){
                el.innerHTML=md(el.textContent); linkifyGoals(el); el.classList.add('rendered');
              });
            });
          }
          function bubble(role,text,pending,live){
            var w=document.createElement('div'); w.className='msg '+role+(pending?' pending':'');
            var b=document.createElement('div'); b.className='bub';
            if(role==='assistant'){ renderAssistant(b,text,live); } else { b.textContent=text; }
            w.appendChild(b); return w;
          }
          // 명확화 질문: 어시스턴트가 cm-question 블록으로 보낸 질문을 한 번에 하나씩
          // Claude 기본 다이얼로그형 카드로 보여주고, 모두 답하면 합쳐서 한 턴으로 전송한다.
          function extractQ(text){
            var re=/```cm-question\\s*([\\s\\S]*?)```/; var m=re.exec(text||'');
            if(!m) return {clean:(text||''), qs:null};
            var qs=null; try{ var o=JSON.parse(m[1]); qs=(o&&o.q)||null; }catch(e){ return {clean:text, qs:null}; }
            if(!qs||!qs.length) return {clean:text, qs:null};
            var clean=(text.slice(0,m.index)+text.slice(m.index+m[0].length)).trim();
            return {clean:clean, qs:qs};
          }
          function renderAssistant(b,text,live){
            var ex=extractQ(text);
            b.innerHTML = ex.clean ? md(ex.clean) : '';
            if(ex.qs) b.appendChild(buildQcard(ex.qs, live));
          }
          // 활성 카드의 키보드 핸들러는 항상 하나만 — 새 카드가 그릴 때 이전 것을 떼어낸다.
          var qKey=null;
          function setQKey(h){ if(qKey){ document.removeEventListener('keydown',qKey,true); } qKey=h; if(h){ document.addEventListener('keydown',h,true); } }
          function buildQcard(qs, live){
            var interactive = (live!==false);
            var answers=new Array(qs.length).fill(null), idx=0, sel=-1;
            var card=document.createElement('div'); card.className='qcard'+(interactive?'':' answered');
            function submit(){
              setQKey(null); card.classList.add('answered');
              var msg=qs.map(function(q,i){ return (i+1)+'. '+q.ask+' → '+(answers[i]||'(미응답)'); }).join('\\n');
              var box=document.getElementById('chatbody');
              box.appendChild(bubble('user',msg,false)); box.scrollTop=box.scrollHeight;
              lastMode=curMode(); openStream();
              fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:msg,mode:curMode(),model:'',allow:persistedAllow()})})
                .then(function(r){return r.json();}).then(function(d){ if(!d||!d.ok){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); } })
                .catch(function(){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); });
            }
            function advance(val){ answers[idx]=val; if(idx<qs.length-1){ idx++; draw(); } else { draw(); submit(); } }
            function confirmSel(){
              var fi=card.querySelector('.qfreein'); var fv=fi?fi.value.trim():'';
              if(fv){ advance(fv); return; }
              var opts=qs[idx].opts||[];
              if(sel>=0 && opts[sel]){ advance(opts[sel].label||('선택지 '+(sel+1))); }
            }
            function draw(){
              var q=qs[idx], opts=q.opts||[]; card.innerHTML='';
              sel=-1; for(var i=0;i<opts.length;i++){ if(opts[i].rec){ sel=i; break; } }
              if(sel<0 && opts.length) sel=0;
              var head=document.createElement('div'); head.className='qhead';
              head.innerHTML='<span class="qcount">'+(idx+1)+'/'+qs.length+'</span><span class="qtitle">'+esc(q.ask||'')+'</span>';
              var ctr=document.createElement('span'); ctr.className='qctrls';
              var col=document.createElement('button'); col.className='qicon'; col.textContent='⌄'; col.title='접기';
              var cls=document.createElement('button'); cls.className='qicon'; cls.textContent='×'; cls.title='닫기';
              ctr.appendChild(col); ctr.appendChild(cls); head.appendChild(ctr); card.appendChild(head);
              var body=document.createElement('div'); body.className='qbody'; card.appendChild(body);
              col.onclick=function(){ body.style.display=(body.style.display==='none')?'':'none'; };
              cls.onclick=function(){ setQKey(null); card.remove(); };
              function paint(){ var rs=body.querySelectorAll('.qopt'); for(var k=0;k<rs.length;k++){ rs[k].classList.toggle('sel', k===sel); } }
              opts.forEach(function(op,oi){
                var key=op.label||('선택지 '+(oi+1));
                var btn=document.createElement('button'); btn.className='qopt';
                var desc=op.why||''; if(op.rec){ desc=desc?(desc+' · 추천'):'추천'; }
                btn.innerHTML='<div class="qmain"><span class="qlabel">'+esc(key)+'</span>'+(desc?'<span class="qwhy">'+esc(desc)+'</span>':'')+'</div><span class="qnum">'+(oi+1)+'</span>';
                btn.onclick=function(){ sel=oi; var fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); };
                body.appendChild(btn);
              });
              var etc=document.createElement('button'); etc.className='qopt qetc';
              etc.innerHTML='<div class="qmain"><span class="qlabel">기타</span></div><span class="qnum">'+(opts.length+1)+'</span>';
              body.appendChild(etc);
              var fin=document.createElement('input'); fin.type='text'; fin.className='qfreein'; fin.placeholder='여기에 답변을 입력하세요';
              body.appendChild(fin);
              etc.onclick=function(){ sel=-1; paint(); fin.focus(); };
              fin.addEventListener('input',function(){ if(fin.value){ sel=-1; paint(); } });
              fin.addEventListener('keydown',function(e){ if(e.key==='Enter'){ e.preventDefault(); confirmSel(); } });
              var foot=document.createElement('div'); foot.className='qfoot';
              var skip=document.createElement('button'); skip.className='qskip'; skip.textContent='건너뛰기'; skip.onclick=function(){ advance(null); };
              var nb=document.createElement('button'); nb.className='qnextbtn'; nb.textContent=(idx<qs.length-1?'다음 ⏎':'완료 ⏎'); nb.onclick=function(){ confirmSel(); };
              foot.appendChild(skip); foot.appendChild(nb); card.appendChild(foot);
              paint();
              if(!interactive){ setQKey(null); return; }
              setQKey(function(e){
                var ae=document.activeElement, tag=ae?ae.tagName:'';
                if(tag==='INPUT'||tag==='TEXTAREA') return;
                if(e.key==='Enter'){ e.preventDefault(); confirmSel(); return; }
                var n=parseInt(e.key,10); if(isNaN(n)) return;
                if(n>=1 && n<=opts.length){ e.preventDefault(); sel=n-1; var fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); }
                else if(n===opts.length+1){ e.preventDefault(); sel=-1; paint(); fin.focus(); }
              });
            }
            draw(); return card;
          }
          // Allowlist key carries the scope so a subtask keeps its own per-folder allowlist.
          var ALLOWKEY='cmAllow:'+SEQ+(TASK?(':'+TASK):'');
          function persistedAllow(){ try{ return JSON.parse(localStorage.getItem(ALLOWKEY)||'[]'); }catch(e){ return []; } }
          function addPersistedAllow(tools){ var s=persistedAllow(); tools.forEach(function(t){ if(s.indexOf(t)<0) s.push(t); });
            try{ localStorage.setItem(ALLOWKEY, JSON.stringify(s)); }catch(e){} return s; }
          function curMode(){ var m=document.getElementById('modeSel'); return m?m.value:'bypassPermissions'; }
          function setStreaming(on){ streaming=on;
            var s=document.getElementById('btnSend'), st=document.getElementById('btnStop');
            if(s) s.style.display=on?'none':''; if(st) st.style.display=on?'':'none';
          }
          function openStream(){
            if(es) return;
            es=new EventSource('/api/goal/chat2/stream?seq='+SEQ+TQ);
            es.onmessage=function(ev){ try{ handleEvt(JSON.parse(ev.data)); }catch(e){} };
          }
          function handleEvt(o){
            var box=document.getElementById('chatbody');
            if(o.t==='start'){
              var ce=box.querySelector('.chatempty'); if(ce) ce.remove();
              curText=''; thinkText=''; thinkBub=null;
              curBub=bubble('assistant','',false); curBub.classList.add('streaming'); box.appendChild(curBub);
              setStreaming(true); box.scrollTop=box.scrollHeight;
            } else if(o.t==='delta'){
              if(!curBub) return; curText+=o.text; var db=curBub.querySelector('.bub');
              var ci=curText.indexOf('```cm-question');
              if(ci>=0){ db.innerHTML=esc(curText.slice(0,ci))+'<span class="qhint">질문 준비 중…</span>'; }
              else { db.textContent=curText; }
              box.scrollTop=box.scrollHeight;
            } else if(o.t==='think'){
              if(!thinkBub){ thinkBub=document.createElement('div'); thinkBub.className='msg assistant thinkmsg';
                var b=document.createElement('div'); b.className='bub'; thinkBub.appendChild(b); box.appendChild(thinkBub); }
              thinkText+=o.text; thinkBub.querySelector('.bub').textContent='💭 '+thinkText; box.scrollTop=box.scrollHeight;
            } else if(o.t==='tool'){
              var arg=''; try{ if(o.input){ arg=o.input.command?('$ '+o.input.command):(o.input.file_path||(o.input.pattern||'')); if(!arg) arg=JSON.stringify(o.input); } }catch(e){}
              var card=document.createElement('div'); card.className='toolcard';
              var head=document.createElement('div'); head.className='th'; head.textContent='🔧 '+o.name+(arg?('  '+arg):'');
              var res=document.createElement('div'); res.className='tr'; res.style.display='none';
              head.onclick=function(){ res.style.display=(res.style.display==='none'&&res.textContent)?'block':'none'; };
              card.appendChild(head); card.appendChild(res); box.appendChild(card);
              if(o.id) toolCards[o.id]=res; box.scrollTop=box.scrollHeight;
            } else if(o.t==='toolresult'){
              var r=toolCards[o.id]; if(r){ r.textContent=o.text||''; if(o.isError) r.classList.add('err');
                var h=r.previousSibling; if(h&&o.text) h.classList.add('has'); }
            } else if(o.t==='done'){
              if(thinkBub){ thinkBub.remove(); thinkBub=null; }
              if(curBub){ curBub.classList.remove('streaming');
                var bb=curBub.querySelector('.bub'); renderAssistant(bb, curText||o.result||'', true);
                if(o.cost){ var cf=document.createElement('div'); cf.className='costline'; cf.textContent='$'+(Math.round(o.cost*10000)/10000); curBub.appendChild(cf); }
                // Plan mode: offer to execute the presented plan (resume in acceptEdits).
                if(lastMode==='plan' && !(o.denials && o.denials.length)){
                  var pb=document.createElement('button'); pb.className='planrun'; pb.textContent='이 계획대로 실행 ▶';
                  pb.onclick=function(){ pb.disabled=true; lastMode='acceptEdits'; openStream();
                    var box2=document.getElementById('chatbody'); box2.appendChild(bubble('user','(계획 승인 — 실행)',false)); box2.scrollTop=box2.scrollHeight;
                    fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:'위 계획을 승인합니다. 계획대로 실행하세요.',mode:'acceptEdits',allow:persistedAllow()})}).catch(function(){}); };
                  curBub.appendChild(pb);
                }
              }
              if(o.denials && o.denials.length){ renderPermission(o.denials); }
              setStreaming(false); curBub=null;
            } else if(o.t==='stopped'){
              if(curBub){ curBub.classList.remove('streaming'); } setStreaming(false); curBub=null;
            } else if(o.t==='error'){
              box.appendChild(bubble('assistant','⚠️ '+(o.message||'오류'),false)); setStreaming(false); curBub=null;
            }
          }
          // Manual mode: a turn ends with denied tools. Offer 허용/거부; 허용 resumes the
          // session with those tools allowed and nudges claude to continue (deny-replay).
          function renderPermission(denials){
            var box=document.getElementById('chatbody');
            var card=document.createElement('div'); card.className='permcard';
            var lines=denials.map(function(d){ var i=d.tool_input||{}; var a=i.command?('$ '+i.command):(i.file_path||''); return d.tool_name+(a?('  '+a):''); });
            card.innerHTML='<div class="pq">권한 요청</div><div class="pl">'+lines.map(function(n){return '<code>'+esc(n)+'</code>';}).join('<br>')+'</div>';
            var tools=denials.map(function(d){return d.tool_name;}).filter(function(v,i,a){return a.indexOf(v)===i;});
            function cont(allowList){ card.remove(); openStream();
              box.appendChild(bubble('user','(권한 허용)',false)); box.scrollTop=box.scrollHeight;
              fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:'권한을 허용했습니다. 방금 하려던 작업을 계속 진행하세요.',mode:curMode(),allow:allowList})}).catch(function(){});
            }
            var row=document.createElement('div'); row.className='prow';
            var allow=document.createElement('button'); allow.className='pa'; allow.textContent='허용하고 계속';
            allow.onclick=function(){ cont(persistedAllow().concat(tools)); };
            var always=document.createElement('button'); always.className='pa2'; always.textContent='항상 허용';
            always.onclick=function(){ cont(addPersistedAllow(tools)); };
            var deny=document.createElement('button'); deny.className='pd'; deny.textContent='거부';
            deny.onclick=function(){ card.remove(); };
            row.appendChild(allow); row.appendChild(always); row.appendChild(deny); card.appendChild(row);
            box.appendChild(card); box.scrollTop=box.scrollHeight;
          }
          function showVer(v){
            document.getElementById('ver-core').style.display=(v==='core')?'':'none';
            document.getElementById('ver-detail').style.display=(v==='detail')?'':'none';
            document.getElementById('ver-session').style.display=(v==='session')?'':'none';
            document.getElementById('btnCore').classList.toggle('on',v==='core');
            document.getElementById('btnDetail').classList.toggle('on',v==='detail');
            document.getElementById('btnSession').classList.toggle('on',v==='session');
          }
          // 첨부 interface stays hidden until the heading is clicked — keeps the page calm.
          function toggleAtt(){
            var w=document.getElementById('attWrap'), t=document.getElementById('attToggle');
            var open=(w.style.display==='none'); w.style.display=open?'':'none';
            if(t) t.textContent=open?'▾ 접기':'▸ 펼치기';
          }
          // 부분과제 starts expanded (it's the Jira-style subtask list); the heading collapses it.
          function toggleTasks(){
            var w=document.getElementById('tasksWrap'), t=document.getElementById('tasksToggle');
            if(!w) return;
            var open=(w.style.display==='none'); w.style.display=open?'':'none';
            if(t) t.textContent=open?'▾ 접기':'▸ 펼치기';
          }
          // 상태 filter: active hides archived rows (default), archived shows only them, all shows everything.
          function filterSubtasks(v){
            var rows=document.querySelectorAll('#tasksWrap tr.subt-row'), shown=0;
            rows.forEach(function(r){
              var arch=r.classList.contains('arch');
              var vis=(v==='all')||(v==='archived'?arch:!arch);
              r.style.display=vis?'':'none'; if(vis) shown++;
            });
            var c=document.getElementById('subtCount'); if(c) c.textContent=shown+'건';
          }
          // 부분과제 추가: reveal the inline form and focus the title.
          function addSubtaskToggle(){
            var f=document.getElementById('subtAddForm'); if(!f) return;
            var open=(f.style.display==='none'); f.style.display=open?'':'none';
            if(open){ var t=document.getElementById('subtAddTitle'); if(t) t.focus(); }
          }
          // POST /api/goal/task — creates a tasks/<taskN> folder under this goal and reloads
          // to show it. The same endpoint the AI uses, so a task can be filed with or without
          // the user. 제목 is required; 상태/코인/주차/산출물 are optional metadata.
          function submitSubtask(){
            var titleEl=document.getElementById('subtAddTitle'); if(!titleEl) return;
            var title=titleEl.value.trim(); if(!title){ titleEl.focus(); return; }
            var g=function(id){ var e=document.getElementById(id); return e?e.value.trim():''; };
            var btn=document.getElementById('subtAddBtn'); if(btn) btn.disabled=true;
            fetch('/api/goal/task',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({seq:SEQ,title:title,status:g('subtAddStatus'),
                coin:g('subtAddCoin'),week:g('subtAddWeek'),outputs:g('subtAddOut')})})
              .then(function(r){return r.json();})
              .then(function(d){ if(d&&d.ok){ location.reload(); }
                else { if(btn) btn.disabled=false; alert('태스크 추가 실패'); } })
              .catch(function(){ if(btn) btn.disabled=false; });
          }
          function renderChat(d){
            var box=document.getElementById('chatbody'); box.innerHTML='';
            var msgs=(d&&d.messages)||[];
            if(!msgs.length){ var e=document.createElement('div'); e.className='chatempty';
              e.textContent='이 목표를 대화로 명확히 해보세요. 문제정의부터 점검합니다.'; box.appendChild(e); }
            msgs.forEach(function(m){ box.appendChild(bubble(m.role,m.text,false)); });
            box.scrollTop=box.scrollHeight;
          }
          function loadChat(){ fetch('/api/goal/chat?seq='+SEQ+TQ).then(function(r){return r.json();}).then(renderChat).catch(function(){}); }
          function sendChat(){
            var t=document.getElementById('ci'); var v=t.value.trim(); if(!v||streaming) return;
            t.value=''; t.style.height='auto';
            var box=document.getElementById('chatbody');
            var ce=box.querySelector('.chatempty'); if(ce) ce.remove();
            box.appendChild(bubble('user',v,false)); box.scrollTop=box.scrollHeight;
            lastMode=curMode(); openStream();
            fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:v,mode:curMode(),model:'',allow:persistedAllow()})})
              .then(function(r){return r.json();}).then(function(d){ if(!d||!d.ok){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); } })
              .catch(function(){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); });
          }
          function stopChat(){ fetch('/api/goal/chat2/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK})}).catch(function(){}); }
          function resetChat(){ if(!confirm('이 목표의 대화를 새로 시작할까요?')) return;
            fetch('/api/goal/chat/reset',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK})})
              .then(function(r){return r.json();}).then(renderChat); }
          function openCLI(){ cliOpen(); }
          // Inline edit of the 핵심 버전: load raw markdown into the textarea, save it back.
          // Swap the rendered display for the textarea, size it to its content, focus it.
          function showCoreEditor(){
            var ed=document.getElementById('coreEditor');
            document.getElementById('coreDisplay').style.display='none';
            ed.style.display='block';
            ed.style.height='auto'; ed.style.height=Math.max(300,ed.scrollHeight)+'px';
            document.getElementById('coreEditBtn').style.display='none';
            document.getElementById('coreEditActions').style.display='flex';
            ed.focus();
            return ed;
          }
          function enterEdit(){
            fetch('/api/goal/definition?seq='+SEQ+TQ+'&kind=core').then(function(r){return r.json();}).then(function(d){
              document.getElementById('coreEditor').value=(d&&d.text)||'';
              showCoreEditor();
            }).catch(function(){ alert('불러오기에 실패했습니다.'); });
          }
          // Locate the "## <label>" section in the markdown (matched like the server: a
          // line that starts with "## " whose title contains the label). Returns the text
          // to load plus the caret offset to drop the user at. If the section is missing,
          // append the heading; otherwise place the caret at the end of its body.
          function sectionCaret(text, label){
            var lines=text.split('\\n');
            var hi=-1;
            for(var i=0;i<lines.length;i++){
              if(lines[i].slice(0,3)==='## ' && lines[i].slice(3).indexOf(label)>=0){ hi=i; break; }
            }
            if(hi<0){
              var t=text.replace(/\\s+$/,'');
              var nt=(t.length?t+'\\n\\n':'')+'## '+label+'\\n';
              return {text:nt, caret:nt.length};
            }
            var end=lines.length;
            for(var j=hi+1;j<lines.length;j++){ if(lines[j].slice(0,3)==='## '){ end=j; break; } }
            var last=end-1;
            while(last>hi && lines[last].trim()===''){ last--; }
            return {text:text, caret:lines.slice(0,last+1).join('\\n').length};
          }
          // Click an empty section card -> open the editor with that heading inserted and
          // the caret under it, so the user types straight into the right place.
          function editSection(label){
            if(!label) return;
            fetch('/api/goal/definition?seq='+SEQ+TQ+'&kind=core').then(function(r){return r.json();}).then(function(d){
              var ed=document.getElementById('coreEditor');
              var r=sectionCaret((d&&d.text)||'', label);
              ed.value=r.text;
              showCoreEditor();
              ed.setSelectionRange(r.caret, r.caret);
            }).catch(function(){ alert('불러오기에 실패했습니다.'); });
          }
          function cancelEdit(){
            document.getElementById('coreEditor').style.display='none';
            document.getElementById('coreDisplay').style.display='';
            document.getElementById('coreEditBtn').style.display='';
            document.getElementById('coreEditActions').style.display='none';
          }
          function saveCore(){
            var text=document.getElementById('coreEditor').value;
            fetch('/api/goal/definition/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,kind:'core',text:text})})
              .then(function(r){return r.json();}).then(function(d){ if(d&&d.ok){ location.reload(); } else { alert('저장에 실패했습니다: '+((d&&d.error)||'?')); } })
              .catch(function(){ alert('저장에 실패했습니다.'); });
          }
          document.addEventListener('DOMContentLoaded',function(){
            loadMarked(); renderMdBodies(); loadChat(); openStream();
            // Make each empty 핵심 버전 section card click-to-write (gated on the editor existing).
            var cd=document.getElementById('coreDisplay');
            if(cd&&document.getElementById('coreEditor')){
              cd.querySelectorAll('.seccard.secempty').forEach(function(card){
                card.addEventListener('click',function(){
                  var h=card.querySelector('h3'); editSection(h?h.textContent.trim():'');
                });
              });
            }
            var ms=document.getElementById('modeSel');
            if(ms){ var saved=localStorage.getItem('cmChatMode'); if(saved) ms.value=saved;
              ms.addEventListener('change',function(){ localStorage.setItem('cmChatMode',ms.value); }); }
            var ci=document.getElementById('ci');
            ci.addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); sendChat(); } });
            ci.addEventListener('input',function(){ ci.style.height='auto'; ci.style.height=Math.min(160,ci.scrollHeight)+'px'; });
          });
          </script>
        """
        // In-page CLI terminal: lazy-load xterm.js, open a PTY-backed claude over the
        // /api/goal/cli/* polling bridge. Reuses the SEQ const from chatScript above.
        let cliScript = """
          <script>
          (function(){
            var XTERM_CSS='https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css';
            var XTERM_JS='https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js';
            var FIT_JS='https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js';
            var UNI_JS='https://cdn.jsdelivr.net/npm/xterm-addon-unicode11@0.6.0/lib/xterm-addon-unicode11.min.js';
            var term=null, fit=null, token='', off=0, pending='', busy=false, timer=null, libs=null;
            function b64enc(s){ var by=new TextEncoder().encode(s), bin=''; for(var i=0;i<by.length;i++) bin+=String.fromCharCode(by[i]); return btoa(bin); }
            function b64dec(b){ var bin=atob(b), a=new Uint8Array(bin.length); for(var i=0;i<bin.length;i++) a[i]=bin.charCodeAt(i); return a; }
            function loadCSS(href){ if(document.querySelector('link[href=\"'+href+'\"]')) return; var l=document.createElement('link'); l.rel='stylesheet'; l.href=href; document.head.appendChild(l); }
            function loadJS(src){ return new Promise(function(res,rej){ var s=document.createElement('script'); s.src=src; s.onload=res; s.onerror=function(){ rej(new Error('load '+src)); }; document.head.appendChild(s); }); }
            function ensureLibs(){ if(libs) return libs; loadCSS(XTERM_CSS); libs=loadJS(XTERM_JS).then(function(){ return loadJS(FIT_JS); }).then(function(){ return loadJS(UNI_JS); }); return libs; }
            function setState(txt,cls){ var e=document.getElementById('cliState'); if(e){ e.textContent=txt; e.className='st'+(cls?(' '+cls):''); } }
            function stopPolling(){ if(timer){ clearInterval(timer); timer=null; } }
            function pump(){
              if(busy||!token) return; busy=true;
              var send=pending; pending='';
              fetch('/api/goal/cli/io',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:token,since:off,input:send?b64enc(send):''})})
                .then(function(r){return r.json();}).then(function(d){
                  busy=false;
                  if(!d||!d.ok){ return; }
                  if(d.data){ term.write(b64dec(d.data)); }
                  off=d.offset;
                  if(d.alive){ setState('실행 중','live'); }
                  else { setState('세션 종료됨','dead'); stopPolling(); }
                }).catch(function(){ busy=false; pending=send+pending; });
            }
            function fitAndReport(initial){
              if(!fit||!term) return;
              try{ fit.fit(); }catch(e){}
              if(initial) return;
              if(token) fetch('/api/goal/cli/resize',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:token,cols:term.cols,rows:term.rows})});
            }
            window.cliOpen=function(){
              var ov=document.getElementById('cliOverlay'); ov.style.display='flex';
              setState('연결 중…','');
              ensureLibs().then(function(){
                if(!term){
                  term=new Terminal({fontSize:13,fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',theme:{background:'#0c0f15'},cursorBlink:true,scrollback:5000,allowProposedApi:true});
                  fit=new FitAddon.FitAddon(); term.loadAddon(fit);
                  // Match xterm's char-width table to the TUI's so CJK (2-cell) text and the
                  // cursor stay aligned — without this, Korean redraws garble the input line.
                  try{ var uni=new Unicode11Addon.Unicode11Addon(); term.loadAddon(uni); term.unicode.activeVersion='11'; }catch(e){}
                  term.open(document.getElementById('cliTerm'));
                  term.onData(function(d){ pending+=d; pump(); });
                } else { term.reset(); }
                fitAndReport(true); term.focus();
                return fetch('/api/goal/cli/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,cols:term.cols,rows:term.rows})});
              }).then(function(r){ return r.json(); }).then(function(d){
                if(!d||!d.ok){ setState('시작 실패: '+((d&&d.error)||'?'),'dead'); return; }
                token=d.token; off=0; setState('실행 중','live');
                stopPolling(); timer=setInterval(pump,90); pump();
              }).catch(function(){ setState('xterm 로드 실패 (오프라인?)','dead'); });
            };
            // 닫기 = background, NOT kill. Stop polling + hide the overlay, but leave the PTY
            // running server-side so the session keeps working and can be reopened from the
            // left rail (which replays the buffer). Explicit termination is the rail's × .
            window.cliClose=function(){
              stopPolling(); token='';
              var ov=document.getElementById('cliOverlay'); if(ov) ov.style.display='none';
            };
            window.addEventListener('resize',function(){ var ov=document.getElementById('cliOverlay'); if(ov&&ov.style.display!=='none') fitAndReport(false); });
            document.addEventListener('keydown',function(e){ var ov=document.getElementById('cliOverlay'); if(e.key==='Escape'&&ov&&ov.style.display!=='none'){ cliClose(); } });
            // Navigating away no longer kills the session — it backgrounds it. No unload beacon.
            // Auto-open when arrived via the rail (/goal?n=NN&cli=1): reconnect to the live PTY.
            try{ if(new URLSearchParams(location.search).get('cli')==='1'){
              if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded', function(){ cliOpen(); }); }
              else { cliOpen(); }
            } }catch(e){}
          })();
          </script>
        """
        // 세션 목록 + "세션 연결" 피커: loads the goal's associated sessions (last-used time +
        // resume command), and a recent-session picker to attach more. Only present when the
        // goal exists (SEQ is real); reuses SEQ from chatScript.
        let sessScript = !editable ? "" : """
          <script>
          (function(){
            function rel(now,then){ if(!then) return '기록 없음'; var s=Math.max(0,now-then);
              if(s<60) return '방금'; var m=Math.floor(s/60); if(m<60) return m+'분 전';
              var h=Math.floor(m/60); if(h<24) return h+'시간 전'; var d=Math.floor(h/24); return d+'일 전'; }
            function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
            window.loadSessions=function(){
              fetch('/api/goal/sessions?seq='+SEQ+TQ).then(function(r){return r.json();}).then(function(d){
                var box=document.getElementById('sessList'); if(!box) return;
                var now=(d&&d.now)||0, list=(d&&d.sessions)||[];
                if(!list.length){ box.innerHTML='<span class="mut">연결된 세션이 없습니다. 오른쪽 메신저·CLI로 시작하거나 “+ 세션 연결”로 추가하세요.</span>'; return; }
                box.innerHTML='';
                list.forEach(function(s){
                  var row=document.createElement('div'); row.className='sessitem'+(s.exists?'':' gone');
                  var head=document.createElement('div'); head.className='shead';
                  head.innerHTML='<span class="src">'+esc(s.source)+'</span><span class="stitle">'+esc(s.title)+'</span><span class="sage">'+(s.exists?rel(now,s.lastUsed):'파일 없음')+'</span>';
                  row.appendChild(head);
                  var act=document.createElement('div'); act.className='sact';
                  var resume=document.createElement('code'); resume.className='rcmd'; resume.textContent=s.resume; act.appendChild(resume);
                  var cp=document.createElement('button'); cp.className='mini'; cp.textContent='복사';
                  cp.onclick=function(){ (navigator.clipboard?navigator.clipboard.writeText(s.resume):Promise.reject()).then(function(){ cp.textContent='복사됨'; setTimeout(function(){cp.textContent='복사';},1200); }).catch(function(){}); };
                  act.appendChild(cp);
                  if(s.exists){ var tr=document.createElement('a'); tr.className='mini'; tr.href='/transcript?session='+encodeURIComponent(s.id); tr.target='_blank'; tr.rel='noopener'; tr.textContent='트랜스크립트'; act.appendChild(tr); }
                  if(s.removable){ var rm=document.createElement('button'); rm.className='mini x'; rm.textContent='해제'; rm.onclick=function(){ unlinkSession(s.id); }; act.appendChild(rm); }
                  row.appendChild(act); box.appendChild(row);
                });
              }).catch(function(){});
            };
            window.unlinkSession=function(id){
              fetch('/api/goal/session/unlink',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,sessionId:id})}).then(function(){ loadSessions(); });
            };
            window.openSessPicker=function(){
              var ov=document.getElementById('sessPicker'); ov.style.display='flex';
              var body=document.getElementById('pickBody'); body.innerHTML='<span class="mut">최근 세션 불러오는 중…</span>';
              fetch('/api/sessions/recent?seq='+SEQ+TQ).then(function(r){return r.json();}).then(function(d){
                var now=(d&&d.now)||0, list=(d&&d.sessions)||[];
                if(!list.length){ body.innerHTML='<span class="mut">최근 Claude 세션을 찾지 못했습니다.</span>'; return; }
                body.innerHTML='';
                list.forEach(function(s){
                  var lab=document.createElement('label'); lab.className='pickrow'+(s.linked?' linked':'');
                  var cb=document.createElement('input'); cb.type='checkbox'; cb.value=s.id; cb.disabled=!!s.linked; cb.checked=!!s.linked;
                  lab.appendChild(cb);
                  var meta=document.createElement('div'); meta.className='pmeta';
                  meta.innerHTML='<div class="ptitle">'+esc(s.title)+'</div><div class="page">'+rel(now,s.lastUsed)+(s.linked?' · 이미 연결됨':'')+'</div>';
                  lab.appendChild(meta); body.appendChild(lab);
                });
              }).catch(function(){ body.innerHTML='<span class="mut">불러오기에 실패했습니다.</span>'; });
            };
            window.closeSessPicker=function(){ var ov=document.getElementById('sessPicker'); if(ov) ov.style.display='none'; };
            window.confirmSessLink=function(){
              var body=document.getElementById('pickBody');
              var ids=[].slice.call(body.querySelectorAll('input[type=checkbox]')).filter(function(c){return c.checked && !c.disabled;}).map(function(c){return c.value;});
              if(!ids.length){ closeSessPicker(); return; }
              Promise.all(ids.map(function(id){ return fetch('/api/goal/session/link',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,sessionId:id})}); }))
                .then(function(){ closeSessPicker(); loadSessions(); });
            };
            document.addEventListener('DOMContentLoaded',function(){ loadSessions();
              document.addEventListener('keydown',function(e){ var ov=document.getElementById('sessPicker'); if(e.key==='Escape'&&ov&&ov.style.display!=='none'){ closeSessPicker(); } });
            });
          })();
          </script>
        """
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(label)) · \(htmlEscape(title))</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff;--green:#9fe0a0}
          *{box-sizing:border-box}
          html,body{height:100%}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;display:flex;flex-direction:column;height:100vh;overflow:hidden}
          /* This page loads in the app's fullSizeContentView WKWebView, so the header renders up
             under the transparent titlebar. The native TitlebarDragView (AppWindow.swift) covers the
             top ~28pt strip and swallows mouse-down there as a window-drag — everything past the 160px
             traffic-light exclusion, which (rail expanded) includes the back link. Pad the header top
             so the interactive '← 대시보드' link clears that band; the empty strip above it stays
             draggable. Matches DashboardContent's own top-strip offset. */
          header{flex:none;background:rgba(14,17,22,.92);border-bottom:1px solid var(--line);padding:36px 20px 14px}
          header a.back{color:var(--accent);text-decoration:none;font-size:12px}
          header h1{margin:6px 0 2px;font-size:17px}
          header .num{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);color:var(--accent);font-variant-numeric:tabular-nums;margin-right:6px}
          header .sub{color:var(--mut);font-size:12px}
          header .slink{margin-top:8px;display:flex;gap:8px;flex-wrap:wrap}
          header .slink a.chip{display:inline-flex;align-items:center;gap:4px;text-decoration:none;font-size:12px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:3px 11px;background:var(--panel)}
          header .slink a.chip:hover{border-color:var(--green)}
          .layout{flex:1;min-height:0;display:flex;align-items:stretch}
          .goalcol{flex:1;min-width:0;overflow-y:auto;padding:18px 20px 80px}
          .goalinner{max-width:880px;margin:0 auto}
          .verswitch{display:inline-flex;gap:4px;background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:3px}
          .verswitch button{border:none;background:transparent;color:var(--mut);border-radius:999px;padding:5px 16px;font-size:13px;cursor:pointer}
          .verswitch button.on{background:var(--accent);color:#fff}
          .verbody{margin-top:10px}
          h2{font-size:13px;color:var(--mut);letter-spacing:.04em;text-transform:uppercase;margin:26px 0 8px;border-bottom:1px solid var(--line);padding-bottom:6px}
          .seccard{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:12px 0}
          .seccard h3{margin:0 0 4px;font-size:14px;color:var(--fg)}
          .sechint{color:var(--mut);font-size:12px;margin-bottom:10px}
          /* Empty section: just a dimmed title that brightens on hover; the guidance
             lives in the card's native tooltip, never inside the box as content. */
          .seccard.secempty{opacity:.42;padding:11px 16px;transition:opacity .15s;cursor:help}
          .seccard.secempty:hover{opacity:.9}
          .seccard.secempty h3{margin:0}
          /* In the editable 핵심 버전, an empty section is click-to-write: clicking it
             opens the editor with that "## 제목" heading inserted and the caret placed
             under it. The "＋ 작성" cue surfaces on hover so the action is discoverable. */
          #coreDisplay .seccard.secempty{cursor:pointer}
          #coreDisplay .seccard.secempty:hover{opacity:.95;border-color:var(--accent)}
          #coreDisplay .seccard.secempty h3::after{content:" ＋ 작성";color:var(--accent);font-size:12px;font-weight:400;opacity:0;transition:opacity .15s}
          #coreDisplay .seccard.secempty:hover h3::after{opacity:.85}
          /* Core display is double-clickable to edit; 수정 button only on hover. */
          .coredisp{cursor:text}
          #coreEditBtn{opacity:0;transition:opacity .15s}
          #ver-core:hover #coreEditBtn{opacity:1}
          /* 첨부: heading toggles the (default-hidden) attachment interface. */
          h2.atth{cursor:pointer;user-select:none;display:flex;align-items:center;gap:8px}
          h2.atth:hover{color:var(--fg)}
          h2.atth .att-toggle{font-size:11px;color:var(--accent);text-transform:none;letter-spacing:0}
          .hint{color:var(--mut);font-size:13px;margin:0}
          /* Read-view markdown preview. Raw markdown is carried as text and rendered on load;
             before render, keep whitespace so the brief pre-render state stays legible. */
          .mdbody{word-break:break-word;font:13.5px/1.75 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;color:var(--fg)}
          .mdbody:not(.rendered){white-space:pre-wrap;color:var(--mut)}
          .mdbody>*:first-child{margin-top:0}
          .mdbody>*:last-child{margin-bottom:0}
          .mdbody h1,.mdbody h2,.mdbody h3,.mdbody h4{margin:18px 0 8px;line-height:1.35;color:var(--fg);border:none;text-transform:none;letter-spacing:0}
          .mdbody h1{font-size:19px} .mdbody h2{font-size:16px;padding:0} .mdbody h3{font-size:14px} .mdbody h4{font-size:13px;color:var(--mut)}
          .mdbody p{margin:8px 0}
          .mdbody ul,.mdbody ol{margin:8px 0;padding-left:22px}
          .mdbody li{margin:3px 0}
          .mdbody li input[type=checkbox]{margin-right:6px;vertical-align:middle}
          /* Task-list items: drop the redundant bullet (the checkbox is the marker), and
             strike through + dim a checked item so "done" reads in a glance and the eye
             lands on what's left. */
          .mdbody li:has(input[type=checkbox]){list-style:none}
          .mdbody li:has(input[type=checkbox]:checked){color:var(--mut);text-decoration:line-through;text-decoration-color:var(--mut)}
          .mdbody a{color:var(--accent);text-decoration:none}
          .mdbody a:hover{text-decoration:underline}
          .mdbody strong{color:var(--fg);font-weight:650}
          .mdbody code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--green);background:#0d1016;border:1px solid var(--line);border-radius:5px;padding:1px 5px}
          .mdbody pre{background:#0d1016;border:1px solid var(--line);border-radius:8px;padding:12px 14px;overflow-x:auto;margin:10px 0}
          .mdbody pre code{background:none;border:none;padding:0;color:var(--fg)}
          .mdbody blockquote{margin:10px 0;padding:4px 14px;border-left:3px solid var(--line);color:var(--mut)}
          .mdbody hr{border:none;border-top:1px solid var(--line);margin:16px 0}
          .mdbody table{border-collapse:collapse;margin:10px 0;font-size:13px}
          .mdbody th,.mdbody td{border:1px solid var(--line);padding:6px 10px;text-align:left}
          .mdbody th{color:var(--mut);font-weight:500}
          .mdbody a.goallink{color:var(--accent);text-decoration:none;border-bottom:1px dashed var(--accent);font-variant-numeric:tabular-nums}
          .mdbody a.goallink:hover{border-bottom-style:solid}
          ul.atts{list-style:none;margin:0;padding:0}
          ul.atts li{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;margin-bottom:6px;background:var(--panel)}
          ul.atts a{color:var(--fg);text-decoration:none;flex:1;word-break:break-all}
          ul.atts a:hover{color:var(--accent)}
          /* 부분과제: Jira-style subtask table read from the goal's tasks/ subfolders. */
          .subt-count{font-size:11px;color:var(--mut);text-transform:none;letter-spacing:0;font-variant-numeric:tabular-nums}
          .subt-tools{display:flex;align-items:center;gap:8px;margin:2px 0 8px}
          .subt-flt{display:inline-flex;align-items:center;gap:6px;color:var(--mut);font-size:12px}
          .subt-addbtn{margin-left:auto;background:transparent;border:1px solid var(--line);color:var(--accent);border-radius:7px;padding:5px 10px;font-size:12px;cursor:pointer}
          .subt-addbtn:hover{border-color:var(--accent)}
          .subt-addform{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin:0 0 10px}
          .subt-addform input{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 8px;font-size:12px}
          .subt-addform input:focus{outline:none;border-color:var(--accent)}
          .subt-addform #subtAddTitle{flex:1;min-width:160px}
          .subt-addform .subt-addsm{width:64px}
          .subt-addform .subt-addgo{background:var(--accent);border:1px solid var(--accent);color:#0b0f17;border-radius:7px;padding:6px 12px;font-size:12px;font-weight:600;cursor:pointer}
          .subt-addform .subt-addgo:disabled{opacity:.5;cursor:default}
          table.subtasks .subt-empty td{color:var(--mut);text-align:center;padding:14px 10px}
          table.subtasks{width:100%;border-collapse:collapse;font-size:13px;margin:2px 0 6px}
          table.subtasks th{text-align:left;color:var(--mut);font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.03em;padding:6px 10px;border-bottom:1px solid var(--line)}
          table.subtasks td{padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:middle}
          table.subtasks tbody tr:hover td{background:var(--panel)}
          table.subtasks .tid{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
          table.subtasks .tid a.tlink{color:var(--accent);text-decoration:none;border-bottom:1px dashed transparent}
          table.subtasks .tid a.tlink:hover{border-bottom-color:var(--accent)}
          table.subtasks .ttitle{color:var(--fg);word-break:break-word}
          table.subtasks .tmeta{color:var(--mut);white-space:nowrap}
          table.subtasks .tout code{color:var(--green)}
          .st{display:inline-block;font-size:11px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);white-space:nowrap}
          .st.done{color:var(--green);border-color:rgba(159,224,160,.4)}
          .st.doing{color:var(--accent);border-color:rgba(91,140,255,.45)}
          .st.blocked{color:#e0a0a0;border-color:rgba(224,160,160,.45)}
          .st.todo{color:var(--mut)}
          .st.arch{color:var(--mut);opacity:.7}
          button,.filebtn{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 11px;font-size:13px;cursor:pointer}
          button:hover,.filebtn:hover{border-color:var(--accent)}
          button.x{padding:3px 9px;font-size:12px;color:var(--mut)}
          .add{display:flex;gap:8px;align-items:center;margin-top:12px;flex-wrap:wrap}
          .add input[type=text]{flex:1;min-width:220px;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:7px 10px;font-size:13px}
          .empty{color:var(--mut);padding:14px 0}
          code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut)}
          .seccard.sess{background:#10141d;border-color:#2a3550}
          .seccard.sess h3{color:var(--accent)}
          .seccard.sess .srow{display:flex;gap:12px;padding:3px 0;font-size:13px}
          .seccard.sess .sk{color:var(--mut);min-width:84px;flex:none}
          .seccard.sess .sv{color:var(--fg)}
          .seccard.sess .sv.mut{color:var(--mut)}
          .seccard.sess .sv.mono{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
          .seccard.sess .slinks{display:flex;gap:8px;flex-wrap:wrap;margin-top:9px}
          .seccard.sess .slinks a.chip{display:inline-flex;align-items:center;gap:4px;text-decoration:none;font-size:12px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:3px 11px;background:var(--panel)}
          .seccard.sess .slinks a.chip:hover{border-color:var(--green)}
          .sesshead{display:flex;align-items:center;justify-content:space-between;margin:12px 0 6px;padding-top:10px;border-top:1px solid var(--line)}
          .sesshead .sklabel{color:var(--mut);font-size:12px}
          .sesshead button.lnk{background:transparent;border:1px solid var(--line);color:var(--accent);border-radius:7px;padding:4px 10px;font-size:12px}
          .sesshead button.lnk:hover{border-color:var(--accent)}
          .sesslist{display:flex;flex-direction:column;gap:8px}
          .sesslist .mut{color:var(--mut);font-size:13px}
          .sessitem{border:1px solid var(--line);border-radius:8px;padding:9px 11px;background:#0d1016}
          .sessitem.gone{opacity:.55}
          .sessitem .shead{display:flex;align-items:baseline;gap:8px}
          .sessitem .src{flex:none;font-size:11px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:1px 8px}
          .sessitem .stitle{flex:1;min-width:0;color:var(--fg);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .sessitem .sage{flex:none;color:var(--mut);font-size:12px}
          .sessitem .sact{display:flex;align-items:center;gap:6px;margin-top:7px;flex-wrap:wrap}
          .sessitem .rcmd{flex:1;min-width:160px;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut);background:#0a0d12;border:1px solid var(--line);border-radius:6px;padding:4px 8px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .sessitem .mini{flex:none;background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:3px 9px;font-size:11px;text-decoration:none;cursor:pointer}
          .sessitem .mini:hover{border-color:var(--accent)}
          .sessitem .mini.x{color:var(--mut)}
          .pickov{position:fixed;inset:0;z-index:60;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.5)}
          .pickbox{width:min(560px,94vw);max-height:82vh;display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden;box-shadow:0 18px 60px rgba(0,0,0,.5)}
          .pickhdr{display:flex;align-items:center;justify-content:space-between;padding:12px 15px;border-bottom:1px solid var(--line)}
          .pickhdr .t{font-weight:600}
          .pickhint{color:var(--mut);font-size:12px;padding:10px 15px 4px}
          .pickbody{flex:1;overflow-y:auto;padding:8px 12px 12px;display:flex;flex-direction:column;gap:6px}
          .pickrow{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;cursor:pointer;background:#0d1016}
          .pickrow:hover{border-color:var(--accent)}
          .pickrow.linked{opacity:.6;cursor:default}
          .pickrow input{flex:none}
          .pickrow .pmeta{min-width:0}
          .pickrow .ptitle{font-size:13px;color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .pickrow .page{font-size:11px;color:var(--mut);margin-top:2px}
          .pickfoot{display:flex;justify-content:flex-end;gap:8px;padding:11px 15px;border-top:1px solid var(--line)}
          .pickfoot button.save{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          .verhead{display:flex;justify-content:flex-end;gap:8px;margin:10px 0 2px}
          .verhead .editacts{display:flex;gap:8px}
          .verhead button.save{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          textarea.vereditor{width:100%;min-height:300px;resize:vertical;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:14px;font:13px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:6px}
          textarea.vereditor:focus{outline:none;border-color:var(--accent)}
          .curhdr{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin:6px 0 4px;padding-bottom:8px;border-bottom:1px solid var(--line)}
          .curhdr .ct{font-size:13px;color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .curhdr .cage{flex:none;color:var(--mut);font-size:12px}
          .curbody .msg{margin:12px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:#0d1016}
          .curbody .msg .who{font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--mut);padding:7px 13px;border-bottom:1px solid var(--line);background:#11161f}
          .curbody .msg .body{padding:11px 13px}
          .curbody .msg.user .who{color:#9fc0ff}
          .curbody .msg.assistant .who{color:#8fe3c0}
          .curbody .text{white-space:pre-wrap;word-break:break-word}
          .curbody .text+.text,.curbody .text+details,.curbody details+.text,.curbody details+details{margin-top:10px}
          .curbody details{border:1px solid var(--line);border-radius:8px;background:#0f141c}
          .curbody details summary{cursor:pointer;padding:6px 10px;color:var(--mut);font-size:12px}
          .curbody details pre{margin:0;padding:10px 12px;border-top:1px solid var(--line);white-space:pre-wrap;word-break:break-word;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#cdd4df;max-height:420px;overflow:auto}
          .curbody details.tool summary{color:#ffcf8f}
          .curbody details.result summary{color:#9fe0a0}
          .curbody details.think summary{color:#b6a8ff}
          .msgr{position:relative;width:380px;flex:none;display:flex;flex-direction:column;overflow:hidden;border-left:1px solid var(--line);background:var(--panel)}
          .msgrhdr{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:11px 14px;border-bottom:1px solid var(--line);font-size:13px;color:var(--mut)}
          .msgrhdr .t{color:var(--fg);font-weight:600}
          .msgrhdr .pwr{font-weight:500;font-size:11px;color:#f0c674;border:1px solid rgba(240,198,116,.4);border-radius:999px;padding:1px 7px;margin-left:4px;white-space:nowrap}
          .msgrhdr .hdrbtns{display:flex;gap:6px;align-items:center;flex:none}
          .modesel{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 6px;font-size:12px;cursor:pointer}
          .modesel:hover{border-color:var(--accent)}
          .msg.streaming .bub::after{content:'▋';margin-left:1px;opacity:.6;animation:blink 1s steps(1) infinite}
          @keyframes blink{50%{opacity:0}}
          .msg.thinkmsg .bub{background:transparent;border:1px dashed var(--line);color:var(--mut);font-size:12px;font-style:italic}
          .toolcard{align-self:stretch;background:#0d1320;border:1px solid rgba(91,140,255,.3);border-radius:8px;overflow:hidden}
          .toolcard .th{padding:7px 10px;color:#bcd0ff;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;cursor:default}
          .toolcard .th.has{cursor:pointer} .toolcard .th.has::after{content:' ▾';opacity:.6}
          .toolcard .tr{padding:8px 10px;border-top:1px solid var(--line);background:#0a0d14;color:var(--mut);font:11px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-all;max-height:240px;overflow:auto}
          .toolcard .tr.err{color:#e0a0a0}
          .costline{color:var(--mut);font-size:10px;margin-top:4px;text-align:right;font-variant-numeric:tabular-nums}
          .planrun{margin-top:8px;background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .planrun:disabled{opacity:.5;cursor:default}
          .msg.assistant .bub p{margin:0 0 8px} .msg.assistant .bub p:last-child{margin:0}
          .msg.assistant .bub pre.cb,.msg.assistant .bub pre{background:#0a0d14;border:1px solid var(--line);border-radius:7px;padding:10px;overflow:auto;margin:6px 0}
          .msg.assistant .bub code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(255,255,255,.06);padding:1px 4px;border-radius:4px}
          .msg.assistant .bub pre code{background:none;padding:0}
          .msg.assistant .bub ul,.msg.assistant .bub ol{margin:6px 0;padding-left:20px}
          .msg.assistant .bub h1,.msg.assistant .bub h2,.msg.assistant .bub h3{font-size:14px;margin:8px 0 4px}
          .msg.assistant .bub a{color:var(--accent)}
          .permcard{align-self:stretch;background:#1a1505;border:1px solid rgba(240,198,116,.45);border-radius:10px;padding:10px 12px}
          .permcard .pq{color:#f0c674;font-weight:600;font-size:12px;margin-bottom:6px}
          .permcard .pl code{display:inline-block;color:#e6e9ef;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
          .permcard .prow{display:flex;gap:8px;margin-top:10px}
          .permcard .pa{background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .permcard .pa2{background:#1b2230;border:1px solid var(--accent);color:var(--accent);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .permcard .pd{background:#1b2230;border:1px solid var(--line);color:var(--mut);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .qcard{align-self:stretch;display:flex;flex-direction:column;gap:10px;background:#0f131b;border:1px solid var(--line);border-radius:12px;padding:12px 13px}
          .qcard .qhead{display:flex;align-items:flex-start;gap:9px}
          .qcard .qcount{flex:none;background:rgba(240,198,116,.16);color:#f0c674;font-size:11px;font-weight:600;padding:2px 8px;border-radius:7px;line-height:1.6;font-variant-numeric:tabular-nums}
          .qcard .qtitle{flex:1;font-size:14px;font-weight:600;color:var(--fg);line-height:1.45;min-width:0}
          .qcard .qctrls{flex:none;display:flex;gap:4px}
          .qcard .qicon{background:transparent;border:1px solid var(--line);color:var(--mut);width:24px;height:24px;border-radius:7px;cursor:pointer;font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center;padding:0}
          .qcard .qicon:hover{color:var(--fg);border-color:var(--accent)}
          .qcard .qbody{display:flex;flex-direction:column;gap:7px}
          .qcard .qopt{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;width:100%;text-align:left;background:#11151f;border:1px solid var(--line);border-radius:9px;padding:9px 11px;cursor:pointer;color:var(--fg)}
          .qcard .qopt:hover{border-color:#3a4658}
          .qcard .qopt.sel{background:#1b212d;border-color:var(--accent)}
          .qcard .qopt .qmain{display:flex;flex-direction:column;gap:2px;min-width:0}
          .qcard .qopt .qlabel{font-size:13px;font-weight:600;color:var(--fg);line-height:1.4}
          .qcard .qopt .qwhy{font-size:11px;color:var(--mut);line-height:1.4}
          .qcard .qopt .qnum{flex:none;background:#0d1016;border:1px solid var(--line);color:var(--mut);font-size:11px;min-width:20px;height:20px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-variant-numeric:tabular-nums}
          .qcard .qopt.sel .qnum{color:var(--accent);border-color:var(--accent)}
          .qcard .qfreein{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:8px 10px;font-size:13px;width:100%;box-sizing:border-box}
          .qcard .qfreein:focus{border-color:var(--accent);outline:none}
          .qcard .qfoot{display:flex;justify-content:flex-end;gap:8px;margin-top:1px}
          .qcard .qskip{background:transparent;border:1px solid var(--line);color:var(--mut);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .qcard .qskip:hover{color:var(--fg)}
          .qcard .qnextbtn{background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 14px;font-size:13px;cursor:pointer}
          .qcard.answered{opacity:.5;pointer-events:none}
          .qhint{color:var(--mut);font-style:italic}
          .cliov{position:absolute;inset:0;z-index:6;display:flex}
          .clibox{width:100%;height:100%;display:flex;flex-direction:column;background:#0c0f15;overflow:hidden;animation:cliSlide .18s ease-out}
          @keyframes cliSlide{from{opacity:0}to{opacity:1}}
          .clihdr{flex:none;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 13px;border-bottom:1px solid var(--line);background:var(--panel);font-size:13px;color:var(--fg)}
          .clihdr .st{color:var(--mut);font-size:12px;margin-left:8px}
          .clihdr .st.live{color:var(--green)}
          .clihdr .st.dead{color:#e06a6a}
          .cliterm{flex:1;min-height:0;padding:8px 6px 4px 10px;background:#0c0f15}
          .cliterm .xterm{height:100%}
          .cliterm .xterm-viewport{background:#0c0f15 !important;scrollbar-width:thin;scrollbar-color:#2a3340 #0c0f15}
          .cliterm .xterm-viewport::-webkit-scrollbar{width:10px}
          .cliterm .xterm-viewport::-webkit-scrollbar-track{background:#0c0f15}
          .cliterm .xterm-viewport::-webkit-scrollbar-thumb{background:#2a3340;border-radius:6px;border:2px solid #0c0f15}
          .msgrhdr button.cli{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          .msgrhdr button.cli:hover{filter:brightness(1.08);border-color:var(--accent)}
          .msgrhdr button.cli:disabled{opacity:.6;cursor:default}
          .chatbody{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:12px}
          .chatempty{color:var(--mut);font-size:13px;text-align:center;margin:auto;padding:24px;line-height:1.7}
          .msg{display:flex;max-width:92%}
          .msg.user{align-self:flex-end}
          .msg.assistant{align-self:flex-start}
          .msg .bub{padding:8px 12px;border-radius:12px;font-size:13px;line-height:1.6;white-space:pre-wrap;word-break:break-word}
          .msg.user .bub{background:rgba(91,140,255,.16);border:1px solid rgba(91,140,255,.32)}
          .msg.assistant .bub{background:#11151f;border:1px solid var(--line)}
          .msg.pending .bub{color:var(--mut)}
          .composer{border-top:1px solid var(--line);padding:10px 12px;display:flex;gap:8px;align-items:flex-end}
          .composer textarea{flex:1;resize:none;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:8px 10px;font:13px/1.5 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;max-height:160px;min-height:38px}
          @media(max-width:1080px){
            body{height:auto;overflow:auto}
            .layout{flex-direction:column}
            .goalcol{overflow:visible}
            .msgr{width:auto;align-self:stretch;max-height:72vh;border-left:none;border-top:1px solid var(--line)}
          }
        </style></head>
        <body>
          \(SessionRail.html())
          <header>
            <a class="back" href="\(htmlEscape(backHref))">\(htmlEscape(backLabel))</a>
            <h1><span class="num">\(htmlEscape(numChip))</span>\(htmlEscape(title))</h1>
            <div class="sub">\(meta)</div>
            \(sessionLink)
          </header>
          <div class="layout">
            <div class="goalcol"><div class="goalinner">
              <div class="verswitch">
                <button id="btnCore" class="on" onclick="showVer('core')">핵심 버전</button>
                <button id="btnDetail" onclick="showVer('detail')">디테일 버전</button>
                <button id="btnSession" onclick="showVer('session')">세션 정보</button>
              </div>
              <div id="ver-core" class="verbody">\(coreEditHead)<div id="coreDisplay"\(coreDispAttr)>\(coreHTML)</div>\(coreEditor)</div>
              <div id="ver-detail" class="verbody" style="display:none">\(detailHTML)</div>
              <div id="ver-session" class="verbody" style="display:none">\(sessionSummary)<h2>최신 진행 내용</h2>\(currentHTML)</div>
              <h2 class="atth" onclick="toggleAtt()">첨부 <span id="attToggle" class="att-toggle">▸ 펼치기</span></h2>
              <div id="attWrap" style="display:none">
                \(attachments)
                \(controls)
              </div>
              \(subtasks)
            </div></div>
            <aside class="msgr">
              <div class="msgrhdr"><div class="hdrbtns"><select id="modeSel" class="modesel" title="권한 모드"><option value="default">수동</option><option value="acceptEdits">편집 자동</option><option value="plan">계획</option><option value="bypassPermissions">자동</option></select><button id="btnCli" class="cli" onclick="openCLI()" title="대화형 CLI 터미널 열기">CLI</button><button onclick="resetChat()" title="새 대화">새 대화</button></div></div>
              <div id="chatbody" class="chatbody"></div>
              <div class="composer">
                <textarea id="ci" rows="1" placeholder="이 목표를 명확히 할 질문이나 정리를 적어 보세요…"></textarea>
                <button id="btnSend" onclick="sendChat()">보내기</button>
                <button id="btnStop" onclick="stopChat()" style="display:none">중단</button>
              </div>
              <div id="cliOverlay" class="cliov" style="display:none">
                <div class="clibox">
                  <div class="clihdr">
                    <span class="t">CLI · \(htmlEscape(isTask ? numChip : "goal-\(seq)")) <span id="cliState" class="st">연결 중…</span></span>
                    <button class="x" onclick="cliClose()" title="세션 종료 (Esc)">닫기 ✕</button>
                  </div>
                  <div id="cliTerm" class="cliterm"></div>
                </div>
              </div>
            </aside>
          </div>
          <div id="sessPicker" class="pickov" style="display:none">
            <div class="pickbox">
              <div class="pickhdr"><span class="t">세션 연결 · \(htmlEscape(isTask ? numChip : "goal-\(seq)"))</span><button class="x" onclick="closeSessPicker()" title="닫기 (Esc)">✕</button></div>
              <div class="pickhint">이 목표와 관련된 최근 Claude 세션을 골라 연결하세요. 마지막 사용 시간 순입니다.</div>
              <div id="pickBody" class="pickbody"></div>
              <div class="pickfoot"><button onclick="closeSessPicker()">취소</button><button class="save" onclick="confirmSessLink()">연결</button></div>
            </div>
          </div>
          \(chatScript)
          \(cliScript)
          \(sessScript)
          \(evScript)
        </body></html>
        """
    }

    // Decode a browser FileReader payload: either a "data:<mime>;base64,…" URL or
    // bare base64. Unknown characters (stray whitespace/newlines) are ignored.
    private static func decodeDataURL(_ s: String) -> Data? {
        var b64 = s
        if s.hasPrefix("data:"), let comma = s.range(of: ",") {
            b64 = String(s[comma.upperBound...])
        }
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    // Percent-encode a value for use inside a URL query (spaces, colons, slashes, etc.).
    // Used to build subtask links whose folder name carries spaces and colons.
    private static func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // Make an uploaded name safe to store as a path component.
    private static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\u{0}").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    // Minimal extension -> MIME map for serving downloads inline-friendly.
    private static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    func quit() {
        AppLog.log("quit() — menu 종료 pressed -> dashboard.stop + NSApp.terminate")
        dashboard.stop()
        NSApp.terminate(nil)
    }
}
