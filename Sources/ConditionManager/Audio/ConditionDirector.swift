import Foundation

// The brain. Reads the smoothed activity rate and steers BGM tempo to keep the
// user in a high-performance state:
//
//   WARMUP  : ramp the target BPM up to energize a "loose" / low-activity user.
//   SUSTAIN : hold near max BPM while fast tempo keeps activity high.
//   RELEASE : if fast tempo stops lifting performance (activity plateaus/drops
//             relative to the personal peak), drop to a low BPM for a recovery
//             window (5–10 min), then return to WARMUP from a lower floor.
final class ConditionDirector {

    enum Phase: String {
        case warmup  = "WARMUP"
        case sustain = "SUSTAIN"
        case release = "RELEASE"
    }

    // Tunables (a few are sourced live from Settings).
    private let decisionInterval: TimeInterval = 20.0 // seconds per decision tick
    private let warmupStep: Double = 5.0              // BPM added per warmup tick
    private let sustainResponsiveThreshold = 0.6      // activity/peak below this => fading
    private let stagnationTicks = 3                   // consecutive fading ticks => release
    private let trackSwitchDeltaBPM = 6.0             // min BPM move before re-selecting
    private let minTrackDwell: TimeInterval = 90.0    // min seconds a track plays before an organic switch
    private let dislikeCooldown: TimeInterval = 2 * 3600 // disliked track skipped for 2h
    // 전략3: plan pools are largely BPM-flat (untagged tracks share the library's
    // defaultBPM), so the BPM-delta gate alone would loop ONE file for a whole slot
    // (AudioEngine loops the current file). Rotate on dwell instead: after this many
    // seconds the director moves on even without a BPM reason, and the recency
    // penalty (below) walks it through the pool instead of ping-ponging two files.
    private let planRotateDwell: TimeInterval = 240.0

    // 폭우 리셋 (activity-triggered rain reset). Once a day, when the user has been in
    // sustained focus and then their activity noticeably drops, the director rolls the
    // dice and — on a hit — summons a 1-hour rain "reset" (the heavy_rain pool),
    // overriding whatever the plan slot would otherwise play, then returns to the plan
    // automatically. A spontaneous squall to clear the head, not a nightly schedule.
    private let rainTheme = "heavy_rain"
    private let rainDurationMinutes: TimeInterval = 60      // rain lasts one hour
    private let rainFocusHighNorm = 0.7                     // norm ≥ this = "focused" (builds credit)
    private let rainDropNorm = 0.5                          // norm < this = "focus dropping" (trigger window)
    private let rainFocusThreshold = 30                     // ticks (~10 min) of focus credit before eligible
    private let rainFocusCap = 90                           // credit ceiling (~30 min)
    private let rainTriggerProb = 0.25                      // per-tick chance once eligible (spontaneity)
    private var focusCredit = 0                             // accumulated "you were focused" ticks
    private var rainUntil: Date?                            // in-flight rain window end (nil = not raining)
    private var forcedRainPending = false                  // debug/manual trigger latch (see triggerRain)
    private lazy var rainStateURL = AppPaths.base.appendingPathComponent("rain-reset.txt")

    // Pure eligibility test (no side effects, no randomness) so it can be unit-tested:
    // the user built up focus credit and is now dropping, and hasn't rained today.
    static func rainEligible(norm: Double, focusCredit: Int, threshold: Int,
                             dropNorm: Double, rainedToday: Bool) -> Bool {
        !rainedToday && focusCredit >= threshold && norm < dropNorm
    }

    // Whether a rain reset is currently playing (for UI/logging).
    var rainActive: Bool { rainUntil.map { $0 > Date() } ?? false }

    // Seconds left in the current rain reset, or nil.
    var rainRemaining: TimeInterval? {
        guard let until = rainUntil else { return nil }
        let r = until.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    // Release scene: recovery track pinned when entering RELEASE — applied only
    // when the active mode's playlist contains it (see modePlaylists below).
    private static let releaseKeyword = "창가의 바람"

    // Per-mode BGM playlists (전략2) — one list per session mode of the rail's
    // challenge dial (25분 포모도로 · 스프린트 · 무제한/트래커, see SessionRail
    // cmChModes). Entries are EXACT filenames in the music folder; the FIRST entry
    // is the mode's pinned opener. Since 전략3 these lists are the FALLBACK gate:
    // while the plan map (BGMPlanMap) resolves a slot, the slot's theme pool gates
    // selection instead; when the plan has a gap, mode playlists apply as before.
    // Unknown mode / empty list ⇒ full library; and BPMLibrary's blocked-pool
    // fallback keeps music playing even if none of the listed files exist in the
    // user's folder.
    private static let modePlaylists: [String: [String]] = [
        "pomodoro": [
            "[096] Neural Searchlight.mp3",      // opener (focus block)
            "[103] 폭발의 신호.mp3",
            "[089] Neural Ops Room (1).mp3",
            "[096] 유리문 속 세계.mp3",
            // Break-block picks. There is no break-phase audio slot — pomodoro
            // completion STOPS the session for the harvest / re-choose moment —
            // so these sit at the tail of the focus pool instead of a break scene.
            "[140] 흥겨운 골목길.mp3",
            "[105] 새 출발 엔딩.mp3",
        ],
        "sprint": [
            "[133] Glass Horizon.mp3",           // opener
            "[129] Signal Mapping.mp3",
            "[126] Open Tabs Atlas.mp3",
            "[123] Neural Dashboard Glow.mp3",
            "[140] 압도적 등장.mp3",
            "[144] Glass Cursor Drift.mp3",
        ],
        "unlimited": [
            "[082] 창가의 바람.mp3",             // opener
            "[120] Midnight Monitor Grid.mp3",
            "[123] Midnight Architecture.mp3",
            "[126] Glass Data Orbit.mp3",
            "[129] Glass Interface.mp3",
        ],
    ]

    private(set) var phase: Phase = .warmup
    private(set) var targetBPM: Double = 70
    private(set) var lastNorm: Double = 0             // last activity/peak ratio (for logging)
    private var peakActivity: Double = 1
    private var plateauCount = 0
    private var releaseUntil: Date?
    private var lastTrackChange: Date?               // when the current track started (for min-dwell)

    // The rail's session mode, set via AppDelegate.startWorking(mode:) before the
    // heartbeat starts/resumes us. Volatile (never persisted); defaults to the
    // launch auto-start's pomodoro. This replaces the old once-per-launch scripted
    // opening scene (096 유리문 → 105) — each mode now owns its opener.
    private(set) var sessionMode = "pomodoro"
    // Armed opener: the next start()/resumeSession() begins with the active
    // mode's pinned first track instead of resuming the previous pick. Re-armed
    // on every session start so a stop→start within one launch replays it.
    private var openerPending = true

    // IDLE (ambient) mode: while the user is away (no input), we don't go silent —
    // we hold the slowest available track at a softened volume. The decision timer
    // is suspended so tempo can't climb, and the pre-idle phase/target/volume are
    // saved so exitIdle() resumes exactly where the session left off.
    private(set) var isIdleMode = false
    private var savedPhase: Phase = .warmup
    private var savedTargetBPM: Double = 0
    private var savedVolume: Float = 0

    // Active tempo band — set by the per-app BGM profile (falls back to the
    // global Settings range). The state machine ramps within this band.
    private(set) var activeMinBPM: Double
    private(set) var activeMaxBPM: Double
    private(set) var activeProfileLabel: String = "기본"

    private var timer: Timer?
    private(set) var started = false

    // 전략3 · 플랜 맵: the pre-planned (day band × time band) → theme-pool map.
    // While a slot resolves, it REPLACES the mode playlist as the candidate gate;
    // when no slot matches (plan gap), the 전략2 mode playlists remain the fallback.
    private let planMap: BGMPlanMap
    private var currentSlot: BGMPlanMap.Slot?

    // Recently played filenames (most recent last). Adds a "virtual BPM" penalty so
    // selection rotates through a BPM-flat plan pool instead of ping-ponging between
    // the first two files. Soft — never blocks, only re-ranks. In-memory only.
    private var recentKeys: [String] = []
    private let recentKeysCap = 12

    private let activity: ActivityMonitor
    private let library: BPMLibrary
    private let audio: AudioEngine
    private let prefStore: TrackPreferenceStore

    init(activity: ActivityMonitor, library: BPMLibrary, audio: AudioEngine,
         prefStore: TrackPreferenceStore, planMap: BGMPlanMap) {
        self.activity = activity
        self.library = library
        self.audio = audio
        self.prefStore = prefStore
        self.planMap = planMap
        self.activeMinBPM = Settings.shared.minBPM
        self.activeMaxBPM = Settings.shared.maxBPM
        self.targetBPM = Settings.shared.minBPM
    }

    var isRunning: Bool { started }
    var isActive: Bool { timer != nil }
    // True whenever sound is engaged — active decisions OR ambient idle playback.
    var isPlaying: Bool { isActive || isIdleMode }

    // Begin a fresh condition cycle from the warmup floor.
    func start() {
        guard !started else { return }
        started = true
        phase = .warmup
        targetBPM = activeMinBPM
        plateauCount = 0
        releaseUntil = nil
        // Session opener: begin on the active mode's pinned first track so each
        // mode sounds immediately different. Falls back to normal (playlist-gated)
        // nearest-BPM selection if the opener file isn't in the library.
        if playOpener() {
            armDecisionTimer()
            return
        }
        openerPending = false
        resumeSession()
    }

    // MARK: - Session mode (per-mode playlists)

    // Session-mode seam, driven by AppDelegate.startWorking(mode:) — i.e. the
    // rail's /api/session/control start POST. Switching modes while music plays
    // (e.g. picking 스프린트 during the launch countdown while the auto-started
    // session is already live) jumps straight to the new mode's opener so the
    // switch is audible.
    func setSessionMode(_ mode: String) {
        guard Self.modePlaylists[mode] != nil, mode != sessionMode else { return }
        sessionMode = mode
        if isActive { playOpener() }
    }

    // A new work session is beginning: re-arm the opener so the first sound is
    // the mode's pinned first track even when we merely resume (started stays
    // true across stopWorking's pauseSession within one launch).
    func armModeOpener() { openerPending = true }

    // Whether a track belongs to the active mode's playlist. Modes without a
    // list (or an unknown mode string) allow the whole library.
    private func inModePlaylist(_ track: BPMLibrary.Track) -> Bool {
        guard let list = Self.modePlaylists[sessionMode], !list.isEmpty else { return true }
        return list.contains(track.url.lastPathComponent)
    }

    // MARK: - 전략3 · plan map

    // Re-resolve the plan slot for "now". Returns true when the slot changed
    // (the tick uses that to force an audible track switch into the new pool).
    @discardableResult
    private func refreshPlanSlot() -> Bool {
        let slot = planMap.slot()
        let changed = slot?.label != currentSlot?.label
        currentSlot = slot
        return changed
    }

    // The slot label for UI/logging ("-" when the plan has a gap right now).
    var planSlotLabel: String? { currentSlot?.label }

    // The plan file was replaced (POST /api/bgm/plan): re-resolve and, if music
    // is live, move into the new pool immediately so the change is audible.
    func planDidChange() {
        refreshPlanSlot()
        if isActive { applyTrack(force: true) }
    }

    // The one candidate gate every selection goes through. A live rain reset wins over
    // everything (only heavy_rain tracks). Otherwise an active plan slot narrows to its
    // theme folders; else the 전략2 mode playlist applies. BPMLibrary's blocked-pool
    // fallback keeps music playing even if a slot names only empty/missing themes.
    private func inActivePool(_ track: BPMLibrary.Track) -> Bool {
        if rainActive { return track.theme == rainTheme }
        if let slot = currentSlot { return slot.themes.contains(track.theme) }
        return inModePlaylist(track)
    }

    // MARK: - 폭우 리셋 (rain reset)

    // "Once a day" persistence: store the day-string of the last rain so a restart can't
    // grant a second one the same calendar day.
    private func todayStr() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    private func rainedToday() -> Bool {
        (try? String(contentsOf: rainStateURL))?.trimmingCharacters(in: .whitespacesAndNewlines) == todayStr()
    }
    private func markRainedToday() { try? todayStr().write(to: rainStateURL, atomically: true, encoding: .utf8) }

    // Manual/preview trigger (debug endpoint): arm a rain reset to begin on the next tick,
    // bypassing eligibility and the daily limit. Also usable to end one early (stop=true).
    func triggerRain(stop: Bool = false) {
        if stop { if rainActive { endRain() }; return }
        forcedRainPending = true
        if isActive { evaluateRain(norm: lastNorm, forced: true) }
    }

    // Begin the rain reset: pin a heavy_rain track and hold for the duration.
    private func startRain() {
        guard let rain = library.tracks.first(where: { $0.theme == rainTheme }) else { return } // no rain pool
        rainUntil = Date().addingTimeInterval(rainDurationMinutes * 60)
        markRainedToday()
        focusCredit = 0
        forcedRainPending = false
        phase = .release
        targetBPM = activeMinBPM
        plateauCount = 0
        releaseUntil = nil
        lastTrackChange = Date()
        notePlayed(rain.url)
        audio.play(url: rain.url, title: rain.title)
        WorkerRegistry.shared.recordRun("director",
            why: "몰입 후 활동 저하 감지 — 폭우 리셋 발동(하루 1회)",
            effect: "🌧 폭우 리셋 시작 · \(Int(rainDurationMinutes))분")
    }

    // Rain window elapsed (or stopped): warm back up and jump to plan selection.
    private func endRain() {
        rainUntil = nil
        phase = .warmup
        targetBPM = activeMinBPM + (activeMaxBPM - activeMinBPM) * 0.25
        plateauCount = 0
        applyTrack(force: true)
        WorkerRegistry.shared.recordRun("director",
            why: "폭우 리셋 종료", effect: "↩ 플랜 선곡으로 복귀")
    }

    // Per-tick rain evaluation: build/decay focus credit, then either honor a forced
    // trigger or roll the dice when genuinely eligible. Returns true if rain just started.
    @discardableResult
    private func evaluateRain(norm: Double, forced: Bool = false) -> Bool {
        guard !rainActive else { return false }
        if norm >= rainFocusHighNorm { focusCredit = min(rainFocusCap, focusCredit + 1) }
        else if norm < rainDropNorm { focusCredit = max(0, focusCredit - 1) }
        let go = forcedRainPending || forced
            || (Self.rainEligible(norm: norm, focusCredit: focusCredit, threshold: rainFocusThreshold,
                                  dropNorm: rainDropNorm, rainedToday: rainedToday())
                && Double.random(in: 0..<1) < rainTriggerProb)
        if go { startRain(); return true }
        return false
    }

    // Recency re-ranking (virtual BPM distance). Most recent ⇒ strongest penalty;
    // decays with age and disappears once a key falls out of the window.
    private func recencyPenalty(_ track: BPMLibrary.Track) -> Double {
        guard !recentKeys.isEmpty,
              let idx = recentKeys.firstIndex(of: track.url.lastPathComponent) else { return 0 }
        return Double(idx + 1) / Double(recentKeys.count) * 12.0
    }

    private func notePlayed(_ url: URL) {
        let key = url.lastPathComponent
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
        if recentKeys.count > recentKeysCap { recentKeys.removeFirst(recentKeys.count - recentKeysCap) }
    }

    // Play the session opener from the warmup floor: the plan slot's pinned opener
    // when one is set and loadable, else the active mode's pinned first track —
    // but only if it belongs to the active pool (a plan slot must not be opened by
    // an office-mode file). Returns false so the caller falls back to the gated
    // nearest-BPM pick inside the pool.
    @discardableResult
    private func playOpener() -> Bool {
        refreshPlanSlot()
        let name = currentSlot?.opener ?? Self.modePlaylists[sessionMode]?.first
        guard let name, let opener = library.track(named: name),
              inActivePool(opener) else { return false }
        openerPending = false
        phase = .warmup
        targetBPM = activeMinBPM
        plateauCount = 0
        releaseUntil = nil
        // AudioEngine.play no-ops on the same URL, so a session paused ON the
        // opener (stop → restart in the same mode) must resume instead.
        if audio.currentURL == opener.url {
            audio.resume()
        } else {
            lastTrackChange = Date()
            notePlayed(opener.url)
            audio.play(url: opener.url, title: opener.title)
        }
        return true
    }

    private func armDecisionTimer() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: decisionInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    // Condition-mate seam (see Plugins/ConditionMate, .doc/condition-mate.md). A connected
    // mate is the optional comrade above this executor: it hands down a Cue (intent) and we
    // translate it via the primitives we already have. Stage 1 handles the mood-band switch
    // (the cleanest existing public path); energyBias/narration/forced events are wired in
    // later stages. A default cue (no profileKey) leaves autonomous control alone.
    func apply(cue: Cue) {
        if let key = cue.profileKey { applyProfile(BGMProfile.by(key: key)) }
    }

    // Switch the active tempo band to a per-app BGM profile. Re-seats the
    // target into the new band and forces an audible track change.
    func applyProfile(_ profile: BGMProfile) {
        guard profile.label != activeProfileLabel
            || profile.minBPM != activeMinBPM
            || profile.maxBPM != activeMaxBPM else { return }
        activeMinBPM = profile.minBPM
        activeMaxBPM = profile.maxBPM
        activeProfileLabel = profile.label
        // Start the new mood from its warmup floor so the shift is noticeable.
        phase = .warmup
        plateauCount = 0
        releaseUntil = nil
        targetBPM = min(max(targetBPM, activeMinBPM), activeMaxBPM)
        if isActive { applyTrack(force: true) }
    }

    // Fully tear down (music disabled / quitting).
    func stop() {
        if isIdleMode { audio.targetVolume = savedVolume; isIdleMode = false }
        started = false
        timer?.invalidate()
        timer = nil
        audio.stop()
    }

    // The user left the session (idle / not in a tracked app): silence BGM but
    // keep phase + targetBPM so we can resume exactly where we left off.
    func pauseSession() {
        guard started else { return }
        // Leaving ambient idle for a full pause: undo idle's volume/tempo override
        // first so a later resume starts from the real session state.
        if isIdleMode {
            isIdleMode = false
            phase = savedPhase
            targetBPM = savedTargetBPM
            audio.targetVolume = savedVolume
        }
        timer?.invalidate()
        timer = nil
        audio.pause()
    }

    // Enter ambient idle: instead of going silent on idle, hold the slowest
    // available track at a softened volume. Starts a fresh session if none is
    // running so "away from keyboard" never means dead air. Idempotent.
    func enterIdle() {
        guard !isIdleMode else { return }
        if !started {
            started = true
            phase = .warmup
            plateauCount = 0
            releaseUntil = nil
            targetBPM = activeMinBPM
        }
        isIdleMode = true
        savedPhase = phase
        savedTargetBPM = targetBPM
        savedVolume = audio.targetVolume
        // Suspend decisions so tempo can't climb while the user is away.
        timer?.invalidate()
        timer = nil
        targetBPM = idleTargetBPM()
        audio.targetVolume = savedVolume * Float(Settings.shared.idleVolumeScale)
        applyTrack(force: true)
    }

    // Input resumed: restore the saved phase/target/volume and re-arm decisions.
    func exitIdle() {
        guard isIdleMode else { return }
        isIdleMode = false
        phase = savedPhase
        targetBPM = savedTargetBPM
        audio.targetVolume = savedVolume
        // Force the restore: bypass min-dwell so returning from idle lifts tempo
        // back to the session level immediately instead of lingering on the slow
        // idle track.
        applyTrack(force: true)
        armDecisionTimer()
    }

    // The slowest sensible tempo for ambient idle: the slowest track in the
    // library, but never faster than the active band's floor.
    private func idleTargetBPM() -> Double {
        if let libMin = library.bpmRange?.min { return min(activeMinBPM, libMin) }
        return activeMinBPM
    }

    // Back in session: resume decisions and sound. A freshly-armed opener (new
    // session start within this launch) overrides plain resume so every session
    // still begins on its mode's first track.
    func resumeSession() {
        guard started else { return }
        let openedWithModeTrack = openerPending && playOpener()
        openerPending = false
        if !openedWithModeTrack {
            if audio.currentURL == nil {
                applyTrack(force: true)
            } else {
                audio.resume()
            }
        }
        armDecisionTimer()
    }

    // Seconds remaining in a release window, for UI display (nil if not releasing).
    var releaseRemaining: TimeInterval? {
        guard phase == .release, let until = releaseUntil else { return nil }
        return max(0, until.timeIntervalSinceNow)
    }

    // Short Korean gear label for the accelerator gauge.
    var gearLabel: String {
        if rainActive { return "폭우" }
        if isIdleMode { return "대기" }
        switch phase {
        case .warmup:  return "가속"
        case .sustain: return "순항"
        case .release: return "감속"
        }
    }

    // The track the director is currently steering toward (nearest to targetBPM,
    // excluding what's playing). min-dwell may be holding this back, so it previews
    // where tempo is headed — surfaced as a gray "next gear" hint. Informational.
    func predictedNextTrack() -> BPMLibrary.Track? {
        guard isPlaying else { return nil }
        let now = Date()
        return library.track(
            forTargetBPM: targetBPM,
            excluding: audio.currentURL,
            penalty: { [prefStore] in
                prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0)
            },
            blocked: { [prefStore] in
                !self.inActivePool($0) || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
            }
        )
    }

    private func tick() {
        // 전략3: re-resolve the plan slot each decision tick; crossing a slot
        // boundary (e.g. 17:00 마감 스퍼트) forces an audible move into the new pool.
        let slotChanged = refreshPlanSlot()
        let minBPM = activeMinBPM
        let maxBPM = activeMaxBPM
        let releaseBPM = minBPM + (maxBPM - minBPM) * 0.1 // gentle floor for recovery
        let act = activity.activityRate

        // Adaptive personal peak: slowly decays so a single burst doesn't fix it
        // forever, but always tracks the recent maximum.
        peakActivity = max(peakActivity * 0.98, max(act, 1))
        let norm = act / peakActivity // 0...1, closeness to personal peak
        lastNorm = norm

        // 폭우 리셋 owns the tick while live: expire it, or just hold+rotate the rain
        // pool. Tempo steering is meaningless during ambient rain, so we skip the
        // phase machine entirely until it ends.
        if rainActive {
            applyTrack(force: false)
            let rem = rainRemaining.map { Int($0 / 60) } ?? 0
            WorkerRegistry.shared.recordRun("director",
                why: "폭우 리셋 진행 중 (norm \(String(format: "%.2f", norm)))",
                effect: "🌧 폭우 리셋 · \(rem)분 남음")
            return
        }
        if rainUntil != nil { endRain() }                 // window just elapsed this tick
        // Not raining: build/decay focus credit and maybe summon a reset. A start does
        // its own forced switch, so bail out of the normal phase machine this tick.
        if evaluateRain(norm: norm) { return }

        switch phase {
        case .warmup:
            // Climb tempo to raise potential.
            targetBPM = min(maxBPM, targetBPM + warmupStep)
            if targetBPM >= maxBPM - 0.001 {
                phase = .sustain
                plateauCount = 0
            }

        case .sustain:
            // At high tempo. Is fast BGM still lifting performance?
            if norm < sustainResponsiveThreshold {
                plateauCount += 1
                if plateauCount >= stagnationTicks {
                    // Fast tempo no longer helps => release.
                    phase = .release
                    releaseUntil = Date().addingTimeInterval(Settings.shared.releaseMinutes * 60)
                    targetBPM = releaseBPM
                    plateauCount = 0
                    // Pin the release scene (082 창가의 바람) on entry; later release
                    // ticks hold it via min-dwell. Only when the active pool (plan slot
                    // or mode playlist) contains it — otherwise fall through to the
                    // gated nearest-BPM pick.
                    if let release = library.track(matchingKeyword: Self.releaseKeyword),
                       inActivePool(release) {
                        lastTrackChange = Date()
                        notePlayed(release.url)
                        audio.play(url: release.url, title: release.title)
                    }
                }
            } else {
                plateauCount = max(0, plateauCount - 1)
            }

        case .release:
            targetBPM = releaseBPM
            if let until = releaseUntil, Date() >= until {
                // Recovery done: warm up again from a lower floor.
                phase = .warmup
                targetBPM = minBPM + (maxBPM - minBPM) * 0.25
                plateauCount = 0
                releaseUntil = nil
            }
        }

        applyTrack(force: slotChanged)
        let slotNote = currentSlot.map { " · 플랜 \($0.label)" } ?? ""
        WorkerRegistry.shared.recordRun("director",
            why: "20초 주기 활동률 평가 (norm \(String(format: "%.2f", lastNorm)))"
                + (slotChanged ? " — 플랜 슬롯 전환" : ""),
            effect: "\(phase.rawValue) · 목표 \(Int(targetBPM))BPM [\(Int(minBPM))-\(Int(maxBPM))]\(slotNote)")
    }

    // User explicitly disliked the current track: down-weight it, open a cooldown
    // so it won't be re-selected for a while, and switch away immediately.
    // Returns the disliked track's identity (for event logging), nil if nothing
    // is playing. See .issue/goal-11.md section 6.
    @discardableResult
    func dislikeCurrentTrack() -> (key: String, title: String, bpm: Double)? {
        guard let url = audio.currentURL else { return nil }
        let key = url.lastPathComponent
        let title = audio.currentTitle ?? key
        let bpm = library.tracks.first(where: { $0.url == url })?.bpm ?? 0
        prefStore.recordDislike(key: key, at: Date(), cooldown: dislikeCooldown)
        applyTrack(force: true)
        return (key, title, bpm)
    }

    // Select and crossfade to the track nearest the current target BPM, biased by
    // learned preference (disliked tracks ranked lower, cooled-down tracks skipped).
    private func applyTrack(force: Bool) {
        // Forced switches can arrive outside the tick cadence (idle enter/exit,
        // dislike, profile change) — make sure they land in the CURRENT plan slot.
        if force { refreshPlanSlot() }
        let now = Date()
        guard let candidate = library.track(
            forTargetBPM: targetBPM,
            excluding: audio.currentURL,
            // Learned dis-preference plus recency, so BPM-flat plan pools rotate
            // through the whole folder instead of replaying the same pair.
            penalty: { [prefStore] in
                prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0)
            },
            // Gate selection to the active pool — the plan slot's themes (전략3) or
            // the mode playlist fallback (dislike cooldowns still apply within it).
            // BPMLibrary falls back to the full pool if the gate would silence
            // everything.
            blocked: { [prefStore] in
                !self.inActivePool($0) || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
            }
        ) else {
            return
        }
        // Avoid thrashing: for organic (non-forced) switches, hold the current
        // track until it has played a musical minimum (min dwell), then require a
        // reason to move. Under a plan slot the reason is EITHER tempo (the target
        // moved enough) OR time served (planRotateDwell) — untagged pool tracks all
        // share the default BPM, so tempo alone would loop one file forever. Without
        // a slot the original tempo-only rule applies. Forced switches (slot change,
        // profile change, dislike, idle enter/exit) bypass all gates.
        if !force, let url = audio.currentURL,
           let playing = library.tracks.first(where: { $0.url == url }) {
            if let started = lastTrackChange,
               now.timeIntervalSince(started) < minTrackDwell { return }
            let bpmMoved = abs(playing.bpm - candidate.bpm) >= trackSwitchDeltaBPM
            if currentSlot != nil {
                let dwell = lastTrackChange.map { now.timeIntervalSince($0) } ?? .infinity
                if !bpmMoved && dwell < planRotateDwell { return }
            } else if !bpmMoved {
                return
            }
        }
        lastTrackChange = now
        notePlayed(candidate.url)
        audio.play(url: candidate.url, title: candidate.title)
    }
}
