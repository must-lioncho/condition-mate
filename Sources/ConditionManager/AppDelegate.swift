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
    let pluginStore = PluginStore()
    let chatStore = ChatStore()
    private(set) var director: ConditionDirector!

    // Local dashboard web server (loopback only, started on demand).
    private lazy var dashboard = DashboardServer(
        html: { DashboardContent.html(lastView: Settings.shared.lastView, doneCutoff: Settings.shared.doneCutoff, uiPrefs: Settings.shared.uiPrefs) },
        data: { [weak self] in self?.dashboardData() ?? "{}" },
        live: { [weak self] in self?.liveData() ?? "{}" },
        post: { [weak self] path, body in self?.handlePost(path, body) ?? "{}" },
        file: { [weak self] path in
            if path.hasPrefix("/chat-img/") { return self?.serveChatImage(path) }
            return self?.serveEvidence(path)
        },
        page: { [weak self] path in
            if path.hasPrefix("/goal") { return self?.goalPage(path) }
            if path.hasPrefix("/worker-log") { return self?.workerLogAllPage(path) }
            if path.hasPrefix("/worker") { return self?.workerLogPage(path) }
            if path.hasPrefix("/breakdown") { return self?.breakdownPage(path) }
            return self?.transcriptPage(path)
        },
        loopFeed: { [weak self] in self?.loopQueueJSON() ?? "{}" },
        chat: { [weak self] in self?.chatJSON() ?? "{}" }
    )
    private var minuteInput = 0   // input-present seconds while working (any app), this minute
    private var minuteAppSeconds: [String: Int] = [:] // frontmost seconds per app this minute
    private var minuteSiteSeconds: [String: Int] = [:] // browser-domain seconds this minute
    private var chromeDomain = ""              // cached active-tab domain (refreshed periodically)
    private var siteRefreshing = false

    private var statusItem: NSStatusItem!
    private var bard: MenuBarBard!
    private var menuController: MenuController!
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
        let live = (isWorking && tail < 6 * 3600) ? max(0, tail) : 0
        return totalSpanBaseSec + live
    }

    // Master switch (Hubstaff-style Start/Stop Working). Tracking + music only
    // run while this is on. Auto-started on launch (see applicationDidFinishLaunching);
    // the menu button remains available to pause/resume mid-session.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        director = ConditionDirector(activity: activity, library: library, audio: audio, prefStore: trackPrefs)
        audio.targetVolume = Float(Settings.shared.volume)

        activity.start()
        reloadLibrary()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            // Monospaced digits so the APM number and clock keep a constant width —
            // the title never jiggles as the digit count changes (ofSize 0 = default).
            button.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        }
        // Pixel-art bard: idle by default, plays a buff performance once a minute
        // while a work session is active. Drives only the button image; the clock
        // text is the button title (updateStatusTitle).
        bard = MenuBarBard { [weak self] image in
            self?.statusItem.button?.image = image
        }
        menuController = MenuController(delegate: self)
        statusItem.menu = menuController.menu

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveIfNeeded()
        director.stop()
        activity.stop()
        bard?.stop()
        heartbeat?.invalidate()
        titleTimer?.invalidate()
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
        r.register(id: "bard", name: "메뉴바 음유시인",
                   detail: "분당 버프 애니메이션(세션 활성 시)", interval: 60)
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
            liveStatus = "작업 중"
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
        // 스포츠 모드: while working, show live APM (bounces up/down each heartbeat) —
        // the same redline-relative number the dashboard gauge tweens, for in-the-moment
        // focus and a bit of fun. Idle has no APM, so it falls through to the clock below.
        if menuBarMode == .sports && isWorking {
            // Glide the displayed value toward the live target. Asymmetric envelope
            // (fast attack, slower release) keeps bursts twitchy while the descent
            // stays smooth — matching the dashboard gauge's feel. At ~20 Hz these
            // alphas converge in a few hundred ms; snap when essentially there so the
            // digit settles instead of crawling the last fraction.
            let target = activity.instantAPM
            let alpha = target >= displayedAPM ? 0.45 : 0.20
            displayedAPM += (target - displayedAPM) * alpha
            if abs(target - displayedAPM) < 0.5 { displayedAPM = target }
            // Pad to 4 figure-spaces (U+2007, digit-width) so the title width is fixed —
            // APM never exceeds 4 digits, so it stops growing and never jiggles.
            let s = String(Int(displayedAPM.rounded()))
            let pad = String(repeating: "\u{2007}", count: max(0, 4 - s.count))
            button.title = " ⚡" + pad + s
            return
        }
        // 타임 모드 (and 스포츠 while idle): the 토탈 시간 work span — the exact same
        // number the dashboard "토탈 시간" card shows (휴식·미팅 포함, 6h+ 공백 제외),
        // e.g. 6:38. The total amount (총량) of the day, not a since-start session clock.
        button.title = " " + Formatting.clock(totalSpanDisplaySec())
    }


    // Recompute the 토탈 시간 work span from today's per-minute samples — mirrors the
    // dashboard timeBuckets() total: anchors are minutes with input or a meeting; the
    // span sums consecutive-anchor gaps under 6h (a 6h+ gap is 퇴근, excluded). Inferred
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
            let sixH = 6 * 3600
            for i in 1..<anchors.count {
                let gap = anchors[i] - anchors[i - 1]
                if gap < sixH { base += Double(gap) }
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

    func startWorking() {
        guard !isWorking else { return }
        isWorking = true
        sessionSeconds = 0
        committedProfileKey = ""
        frontStableSeconds = 0
        activeAppLabel = ""
        bard.startBuffing()
        updateStatusTitle()
    }

    func stopWorking() {
        guard isWorking else { return }
        isWorking = false
        committedProfileKey = ""
        activeAppLabel = ""
        director.pauseSession()
        store.saveIfNeeded()
        bard.stop()
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

    func openDashboard() {
        dashboard.start { port in
            DispatchQueue.main.async {
                if let url = URL(string: "http://127.0.0.1:\(port)/") {
                    NSWorkspace.shared.open(url)
                }
            }
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
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "goal" })?.value else { return nil }
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
        "now":{"working":\(isWorking),"status":"\(liveStatus)",\
        "app":\(jsonString(nowApp)),"profile":\(jsonString(nowProfile)),"track":\(jsonString(nowTrack)),\
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
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),\"parent\":\(jsonString(g.parent)),"
                    + "\"status\":\(jsonString(g.status)),\"trackedSeconds\":\(g.trackedSeconds),\"startedAt\":\(started),\"waitingSince\":\(waiting),"
                    + "\"energy\":\(g.energy),\"agents\":[\(agents)],\"tokens\":\(g.tokens),\"value\":\(g.value),"
                    + "\"evidence\":[\(evidence)],\"sessionId\":\(jsonString(g.sessionId)),"
                    + "\"targetAt\":\(target),\"completedAt\":\(completed),"
                    + "\"sprint\":\(g.sprint),\"released\":\(g.released),\"priority\":\(jsonString(g.priority))}"
            }
            .joined(separator: ",")
        // Release log (newest first): when each commit happened + the value it produced.
        let releases = reviewStore.releases
            .map { rel -> String in
                let titles = rel.titles.map { jsonString($0) }.joined(separator: ",")
                let gids = rel.goalIds.map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(rel.id)),\"sprint\":\(rel.sprint),"
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
                    + "\"parent\":\(jsonString(item.parent)),\"note\":\(jsonString(item.note)),"
                    + "\"matches\":[\(matches)],\"createdAt\":\(item.createdAt.timeIntervalSince1970)}"
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
            + "\"aiQueue\":[\(aiQueue)],"
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
        // AI추가 중복 확인 다이얼로그 안의 대화 한 턴: 목표를 AI와 상의해 다듬는다. claude 호출.
        if path == "/api/goal/aiChat" {
            return aiGoalChat(candidate: (obj["candidate"] as? String) ?? "",
                              matches: (obj["matches"] as? [[String: Any]]) ?? [],
                              history: (obj["history"] as? [[String: Any]]) ?? [],
                              message: (obj["message"] as? String) ?? "",
                              images: (obj["images"] as? [[String: Any]]) ?? [],
                              model: (obj["model"] as? String) ?? "")
        }
        return DispatchQueue.main.sync {
            let day = reviewStore.todayKey
            switch path {
            case "/api/goal/add":
                if let text = obj["text"] as? String {
                    let sprint = (obj["sprint"] as? NSNumber)?.intValue ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    reviewStore.addGoal(text: text, parent: (obj["parent"] as? String) ?? "", sprint: sprint)
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
            case "/api/goal/queue/resolve":
                // Resolve one queued candidate: add (promote to goal), edit (rewrite text,
                // keep queued), or skip (drop).
                if let id = obj["id"] as? String {
                    reviewStore.resolveQueueItem(id: id, action: (obj["action"] as? String) ?? "skip",
                                                 text: obj["text"] as? String)
                }
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
            case "/api/goal/title":
                // Rename a goal from the dashboard. For a session-mirrored goal, also
                // append the new title to its transcript so the session hook honors it
                // over Claude's auto aiTitle (otherwise the next event overwrites it).
                if let id = obj["id"] as? String, let title = obj["title"] as? String {
                    if let g = reviewStore.setGoalTitle(id: id, title: title), !g.sessionId.isEmpty {
                        writeTitleOverride(for: g, title: g.text)
                    }
                }
            case "/api/session/event":
                // Driven by Claude Code session hooks (see Scripts/cc-session-hook.sh).
                // event: start | active | idle | end. The goal is keyed by sessionId
                // and auto-created on first event, so no goal id is required.
                if let sid = obj["sessionId"] as? String {
                    let event = (obj["event"] as? String) ?? "start"
                    reviewStore.recordSession(sessionId: sid, event: event,
                                              text: (obj["text"] as? String) ?? "",
                                              transcriptPath: (obj["transcriptPath"] as? String) ?? "")
                }
            case "/api/goal/connect":
                // Open a native file picker (default: the current Claude session folder)
                // so the user can attach a transcript .jsonl to this goal. Runs async on
                // the next main-loop turn so the HTTP response returns immediately; the
                // dashboard's poll (and the client's follow-up reloads) pick up the link.
                if let id = obj["id"] as? String {
                    DispatchQueue.main.async { [weak self] in self?.connectSessionViaPicker(goalId: id) }
                }
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
                if let id = obj["id"] as? String {
                    let kind = (obj["kind"] as? String) ?? "link"
                    if kind == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL) {
                        // Copy the upload into the goal's number-named folder
                        // (.claude/issue/goal-NN/attachments); fall back to the legacy
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
                if let id = obj["id"] as? String, let evId = obj["evidenceId"] as? String {
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
    private func aiDuplicateCheck(text: String, parent: String) -> String {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        // Snapshot existing goals (brief hop to main for thread-safe store access).
        let snapshot: [(seq: Int, text: String, status: String)] = DispatchQueue.main.sync {
            reviewStore.goals.map { (seq: $0.seq, text: $0.text, status: $0.status) }
        }
        guard let claude = Self.resolveClaude() else {
            return "{\"ok\":false,\"error\":\"claude-not-found\"}"
        }
        // Build the prompt: existing goals (skip cancelled) + the candidate; demand strict JSON.
        let listText = snapshot.filter { $0.status != "cancelled" }
            .map { "#\($0.seq) \($0.text)" }.joined(separator: "\n")
        let prompt = """
        You are a deduplication judge for a personal goal tracker. Decide whether a NEW goal \
        duplicates or substantially overlaps any EXISTING goal (same intent, even if worded \
        differently or in a different language).

        EXISTING GOALS (one per line as "#<seq> <title>"):
        \(listText.isEmpty ? "(none)" : listText)

        NEW GOAL:
        \(candidate)

        Respond with ONLY a single JSON object, no prose, no code fences:
        {"duplicate": true or false, "matches": [{"seq": <int of an existing goal>, "why": "<short reason in Korean>"}], "note": "<one short Korean sentence>"}
        Use "duplicate": false with an empty "matches" array when the new goal is genuinely new.
        """
        // Spawn via a login shell so PATH/node resolve like the user's terminal; feed the
        // prompt on stdin to dodge arg-length and quoting pitfalls.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return "{\"ok\":false,\"error\":\"spawn-failed\"}" }
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
        else { return "{\"ok\":false,\"error\":\"parse-failed\"}" }
        let duplicate = (parsed["duplicate"] as? Bool) ?? false
        let note = (parsed["note"] as? String) ?? ""
        // Enrich each match with the existing goal's current title (snapshot lookup).
        let bySeq = Dictionary(snapshot.map { ($0.seq, $0.text) }, uniquingKeysWith: { a, _ in a })
        let rawMatches = (parsed["matches"] as? [[String: Any]]) ?? []
        let matches = rawMatches.compactMap { m -> String? in
            guard let seq = (m["seq"] as? NSNumber)?.intValue else { return nil }
            let why = (m["why"] as? String) ?? ""
            let gtext = bySeq[seq] ?? ""
            return "{\"seq\":\(seq),\"text\":\(jsonString(gtext)),\"why\":\(jsonString(why))}"
        }.joined(separator: ",")
        // A duplicate verdict is only actionable if it actually points at a known goal.
        let dupFinal = duplicate && !matches.isEmpty
        return "{\"ok\":true,\"duplicate\":\(dupFinal),\"matches\":[\(matches)],\"note\":\(jsonString(note))}"
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

    // MARK: Chat (Claude-Desktop-style 대화)

    // The conversation JSON the dashboard renders. Read on panel open + after each send.
    func chatJSON() -> String {
        let msgs = DispatchQueue.main.sync { chatStore.messages }
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
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode + persist images first (on main for store safety); collect stored names + paths.
        var storedNames: [String] = []
        var imgPaths: [String] = []
        DispatchQueue.main.sync {
            for img in images.prefix(8) {
                guard let b64 = img["data"] as? String,
                      let data = Self.decodeImageDataURL(b64) else { continue }
                let ext = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png"
                if let name = chatStore.saveImage(data: data.bytes, ext: data.ext.isEmpty ? ext : data.ext) {
                    storedNames.append(name)
                    imgPaths.append(chatStore.imagePath(name).path)
                }
            }
        }
        guard !body.isEmpty || !storedNames.isEmpty else { return chatJSON() }

        // Record the user turn immediately so the panel shows it even if Claude is slow.
        let (resume, addDir): (String, String) = DispatchQueue.main.sync {
            chatStore.appendUser(text: body, images: storedNames)
            return (chatStore.sessionId, chatStore.attachmentsDir.path)
        }

        guard let claude = Self.resolveClaude() else {
            DispatchQueue.main.sync { _ = chatStore.appendAssistant(text: "⚠️ claude CLI를 찾지 못했습니다. (~/.local/bin/claude 등)") }
            return chatJSON()
        }

        // Build the prompt: user text + a note pointing the model at any attached images.
        var prompt = body
        if !imgPaths.isEmpty {
            let list = imgPaths.map { "- \($0)" }.joined(separator: "\n")
            prompt += "\n\n[첨부 이미지 — Read 도구로 확인하세요]\n\(list)"
        }
        // Assemble the claude args: print mode, JSON output (for result + session_id),
        // resume to keep context, optional model, and image-read access to the attach dir.
        var args = "-p --output-format json --add-dir \(Self.shellQuote(addDir)) --allowedTools Read"
        if !resume.isEmpty { args += " --resume \(Self.shellQuote(resume))" }
        if let m = Self.claudeModelAlias(model) { args += " --model \(Self.shellQuote(m))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch {
            DispatchQueue.main.sync { _ = chatStore.appendAssistant(text: "⚠️ claude 실행에 실패했습니다.") }
            return chatJSON()
        }
        // Watchdog: a long answer is fine, but never hang the connection forever.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
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
            chatStore.setSession(newSession)
            _ = chatStore.appendAssistant(text: reply)
        }
        return chatJSON()
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

    // MARK: Goal page (/goal?n=<NN>)

    // One goal's page: number, title, key metrics, definition (goal.md) and the
    // attachment list with add/remove/download controls. Looked up by stable seq.
    func goalPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let raw = comps.queryItems?.first(where: { $0.name == "n" })?.value else { return nil }
        let digits = raw.replacingOccurrences(of: "goal-", with: "").filter { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == n } }
        guard let goal = goalOpt else {
            return goalPageHTML(seq: n, title: "goal-\(n)", goalId: "", meta: "", sessionLink: "",
                definition: "", attachments: "<p class=\"empty\">번호 \(n)에 해당하는 골이 없습니다.</p>")
        }
        migrateDefinitionIfNeeded(seq: n)
        return goalPageHTML(seq: n, title: goal.text, goalId: goal.id,
            meta: goalMetaLine(goal), sessionLink: goalSessionLink(goal), definition: renderDefinition(seq: n),
            attachments: renderAttachments(goal))
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

    // Consolidate a legacy flat definition (.claude/issue/goal-NN.md) into the
    // folder (goal-NN/goal.md) on first page open. Idempotent and non-destructive
    // (a no-op once goal.md exists).
    private func migrateDefinitionIfNeeded(seq: Int) {
        guard let dst = IssuePaths.definitionURL(seq: seq),
              let legacy = IssuePaths.legacyDefinitionURL(seq: seq) else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: dst)
    }

    private func renderDefinition(seq: Int) -> String {
        let fm = FileManager.default
        var url: URL? = nil
        if let d = IssuePaths.definitionURL(seq: seq), fm.fileExists(atPath: d.path) { url = d }
        else if let l = IssuePaths.legacyDefinitionURL(seq: seq), fm.fileExists(atPath: l.path) { url = l }
        guard let u = url, let data = try? Data(contentsOf: u) else {
            let p = IssuePaths.definitionURL(seq: seq)?.path ?? ""
            return "<p class=\"empty\">정의 문서가 없습니다. <code>\(htmlEscape(p))</code> 에 goal.md를 두면 여기 표시됩니다.</p>"
        }
        return "<pre class=\"def\">\(htmlEscape(String(decoding: data, as: UTF8.self)))</pre>"
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

    private func goalMetaLine(_ g: ReviewStore.Goal) -> String {
        let labels = ["backlog": "대기", "in_progress": "진행", "waiting": "대기",
                      "stopped": "중지", "cancelled": "취소", "done": "완료"]
        let st = labels[g.status] ?? g.status
        let secs = g.trackedSeconds + (g.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return "상태 \(htmlEscape(st)) · 가치 \(g.value) · 토큰 \(g.tokens)K · 작업 \(h)시간 \(m)분"
    }

    private func goalPageHTML(seq: Int, title: String, goalId: String,
                             meta: String, sessionLink: String, definition: String, attachments: String) -> String {
        let label = IssuePaths.label(seq: seq) ?? "goal-\(seq)"
        let controls = goalId.isEmpty ? "" : """
          <div class="add">
            <input type="text" id="lk" placeholder="https://… 링크 붙여넣기" onkeydown="if(event.key==='Enter')addLink()">
            <button onclick="addLink()">링크 추가</button>
            <label class="filebtn">파일 첨부<input type="file" multiple style="display:none" onchange="addFiles(this)"></label>
          </div>
        """
        let script = goalId.isEmpty ? "" : """
          <script>
          const GID=\(jsonString(goalId));
          function post(p,b){return fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});}
          function addLink(){const el=document.getElementById('lk');const u=el.value.trim();if(!u)return;
            post('/api/goal/evidence/add',{id:GID,kind:'link',url:u}).then(()=>location.reload());}
          function addFiles(input){const fs=[...input.files];if(!fs.length)return;let done=0;
            fs.forEach(f=>{const r=new FileReader();r.onload=()=>{post('/api/goal/evidence/add',{id:GID,kind:'file',filename:f.name,data:r.result}).then(()=>{done++;if(done===fs.length)location.reload();});};r.readAsDataURL(f);});}
          function rm(eid){if(!confirm('이 첨부를 삭제할까요?'))return;post('/api/goal/evidence/remove',{id:GID,evidenceId:eid}).then(()=>location.reload());}
          </script>
        """
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(label)) · \(htmlEscape(title))</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff;--green:#9fe0a0}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header a.back{color:var(--accent);text-decoration:none;font-size:12px}
          header h1{margin:6px 0 2px;font-size:17px}
          header .num{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);color:var(--accent);font-variant-numeric:tabular-nums;margin-right:6px}
          header .sub{color:var(--mut);font-size:12px}
          header .slink{margin-top:8px;display:flex;gap:8px;flex-wrap:wrap}
          header .slink a.chip{display:inline-flex;align-items:center;gap:4px;text-decoration:none;font-size:12px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:3px 11px;background:var(--panel)}
          header .slink a.chip:hover{border-color:var(--green)}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          h2{font-size:13px;color:var(--mut);letter-spacing:.04em;text-transform:uppercase;margin:26px 0 8px;border-bottom:1px solid var(--line);padding-bottom:6px}
          pre.def{white-space:pre-wrap;word-break:break-word;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px;font:13px/1.7 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;margin:0}
          ul.atts{list-style:none;margin:0;padding:0}
          ul.atts li{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;margin-bottom:6px;background:var(--panel)}
          ul.atts a{color:var(--fg);text-decoration:none;flex:1;word-break:break-all}
          ul.atts a:hover{color:var(--accent)}
          button,.filebtn{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 11px;font-size:13px;cursor:pointer}
          button:hover,.filebtn:hover{border-color:var(--accent)}
          button.x{padding:3px 9px;font-size:12px;color:var(--mut)}
          .add{display:flex;gap:8px;align-items:center;margin-top:12px;flex-wrap:wrap}
          .add input[type=text]{flex:1;min-width:220px;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:7px 10px;font-size:13px}
          .empty{color:var(--mut);padding:14px 0}
          code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut)}
        </style></head>
        <body>
          <header>
            <a class="back" href="/">← 대시보드</a>
            <h1><span class="num">\(htmlEscape(label))</span>\(htmlEscape(title))</h1>
            <div class="sub">\(meta)</div>
            \(sessionLink)
          </header>
          <main>
            <h2>정의</h2>
            \(definition)
            <h2>첨부</h2>
            \(attachments)
            \(controls)
          </main>
          \(script)
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
        dashboard.stop()
        NSApp.terminate(nil)
    }
}
