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
    private(set) var director: ConditionDirector!

    // Local dashboard web server (loopback only, started on demand).
    private lazy var dashboard = DashboardServer(
        html: { DashboardContent.html() },
        data: { [weak self] in self?.dashboardData() ?? "{}" },
        live: { [weak self] in self?.liveData() ?? "{}" },
        post: { [weak self] path, body in self?.handlePost(path, body) ?? "{}" },
        file: { [weak self] path in self?.serveEvidence(path) },
        page: { [weak self] path in
            if path.hasPrefix("/worker-log") { return self?.workerLogAllPage(path) }
            if path.hasPrefix("/worker") { return self?.workerLogPage(path) }
            if path.hasPrefix("/breakdown") { return self?.breakdownPage(path) }
            return self?.transcriptPage(path)
        },
        loopFeed: { [weak self] in self?.loopQueueJSON() ?? "{}" }
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
        r.register(id: "session-reconcile", name: "세션 상태 동기화",
                   detail: "트랜스크립트로 세션 진행중·응답 대기 실시간 판정", interval: 1)
        r.register(id: "activity-sample", name: "활동 샘플",
                   detail: "키·마우스 입력률 평활화(APM 산출)", interval: 5)
        r.register(id: "browser-domain", name: "브라우저 도메인",
                   detail: "활성 탭 도메인 갱신(가치 분류용)", interval: 5)
        r.register(id: "director", name: "BGM 디렉터",
                   detail: "활동률 기반 BGM 템포 결정(세션 활성 시)", interval: 20)
        r.register(id: "autosave", name: "상태 저장",
                   detail: "누적 시간 디스크 플러시", interval: 30)
        r.register(id: "title-stamp", name: "세션 제목 스탬프",
                   detail: "데스크톱 세션 제목에 [seq] 재기입", interval: 30)
        r.register(id: "bard", name: "메뉴바 음유시인",
                   detail: "분당 버프 애니메이션(세션 활성 시)", interval: 60)
        r.register(id: "timeline-sample", name: "타임라인 기록",
                   detail: "분 단위 활동 샘플을 대시보드 타임라인에 적립", interval: sampleInterval)
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

        // Gate music to the active session.
        if s.musicEnabled && inSession && !musicFolderConfigured {
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

        // Reconcile session goal status from transcripts every heartbeat (cheap stat per
        // goal; full re-parse only on growth) — keeps 진행중 real-time (priority 1).
        reconcileSessionStates(); WorkerRegistry.shared.recordRun("session-reconcile")

        // Policy 3: re-stamp [seq] onto Claude desktop session titles so a human can
        // eyeball-match a desktop session to its goal (file IO, throttled, off-main).
        if tick % 30 == 0 { stampSessionTitles()
            WorkerRegistry.shared.recordRun("title-stamp",
                why: "30초 주기 세션 제목 동기화", effect: "데스크톱 세션 제목에 [seq] 재기입 점검") }

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
            default:
                break   // waiting stays waiting until it grows again (priority 1 resumes it)
            }
        }
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
            // Pad to 4 figure-spaces (U+2007, digit-width) so the title width is fixed —
            // APM never exceeds 4 digits, so it stops growing and never jiggles.
            let s = String(Int(activity.instantAPM))
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
            rows += "<tr><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"why\">\(htmlEscape(e.why))</td>"
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
        var merged: [(t: Int, id: String, why: String, effect: String)] = []
        for w in workers {
            for e in WorkerLog.shared.recent(w.id, limit: 300) {
                merged.append((e.t, w.id, e.why, e.effect))
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
            rows += "<tr><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"wk\" style=\"white-space:nowrap\">\(dot)\(htmlEscape(name))</td>"
                + "<td class=\"why\">\(htmlEscape(e.why))</td>"
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
                    + "\"targetAt\":\(target),\"completedAt\":\(completed)}"
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
                    // Drop any attached evidence files for the removed goal(s).
                    removed.forEach { try? FileManager.default.removeItem(at: Self.evidenceDir(goalId: $0)) }
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
            case "/api/goal/evidence/add":
                if let id = obj["id"] as? String {
                    let kind = (obj["kind"] as? String) ?? "link"
                    if kind == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL) {
                        // Copy the upload into the app's evidence store, keyed by goal.
                        let name = Self.sanitizeFilename((obj["filename"] as? String) ?? "file")
                        let evId = UUID().uuidString
                        let dir = Self.evidenceDir(goalId: id)
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

    // MARK: Evidence files

    // On-disk folder holding a goal's uploaded evidence files.
    static func evidenceDir(goalId: String) -> URL {
        AppPaths.sub("evidence").appendingPathComponent(goalId, isDirectory: true)
    }

    // GET /evidence/<goalId>/<evidenceId> -> the stored file (bytes, MIME, name).
    // Returns nil (404) for unknown ids or missing files.
    func serveEvidence(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["evidence", goalId, evidenceId]
        guard comps.count >= 3, comps[0] == "evidence" else { return nil }
        let goalId = comps[1], evId = comps[2]
        return DispatchQueue.main.sync {
            guard let ev = reviewStore.evidence(goalId: goalId, evidenceId: evId),
                  ev.kind == "file" else { return nil }
            let url = Self.evidenceDir(goalId: goalId).appendingPathComponent(ev.filename)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let name = ev.title.isEmpty ? ev.filename : ev.title
            return (data, Self.mimeType(name), name)
        }
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
