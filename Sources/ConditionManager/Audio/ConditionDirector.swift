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
    // dice and — on a hit — summons a rain "reset" (the heavy_rain pool), overriding
    // whatever the plan slot would otherwise play, then returns to the plan
    // automatically. A spontaneous squall to clear the head, not a nightly schedule.
    // Also summonable on demand from the 장비 page at an EXP cost (see triggerRain).
    private let rainTheme = "heavy_rain"
    private let rainMinMinutes: TimeInterval = 30          // each rain lasts 30–60 min,
    private let rainMaxMinutes: TimeInterval = 60          // rolled fresh per summon
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
    // challenge dial (25분 포모도로 · 루프 · 무제한/트래커, see SessionRail
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

    // Base tempo band — set by the per-app BGM profile (falls back to the global
    // Settings range). 전략5 (모드 에너지) derives the EFFECTIVE band from this by
    // narrowing/shifting it per session mode; the profile stays the outer envelope.
    private var baseMinBPM: Double
    private var baseMaxBPM: Double

    // Active (mode-adjusted) tempo band the state machine ramps within. Recomputed
    // from the base band + sessionMode by applyModeEnergy(); equals the base band
    // for unknown modes. AppDelegate's debug line reads these to show the live band.
    private(set) var activeMinBPM: Double
    private(set) var activeMaxBPM: Double
    private(set) var activeProfileLabel: String = "기본"

    // 전략5 · 모드 에너지: each challenge mode targets a different BPM region of the
    // SAME plan pool, so 25분/루프/트래커 sound distinct without touching the plan
    // gate (inActivePool). lo/hi are fractions of the base band's span; ramp scales
    // the warmup climb. Unknown modes leave the full base band (see applyModeEnergy).
    private struct ModeEnergy { let lo: Double; let hi: Double; let ramp: Double }
    private static let modeEnergy: [String: ModeEnergy] = [
        "pomodoro":  ModeEnergy(lo: 0.20, hi: 0.80, ramp: 1.0),  // 집중 중속 안정 (band 중앙)
        "sprint":    ModeEnergy(lo: 0.55, hi: 1.00, ramp: 1.6),  // 고속 상승 (band 상단·빠른 램프)
        "unlimited": ModeEnergy(lo: 0.00, hi: 0.45, ramp: 0.5),  // 저속 앰비언트 (band 하단·억제)
    ]
    // Warmup-climb multiplier for the active mode (1.0 = neutral). Set by applyModeEnergy.
    private var modeRamp: Double = 1.0

    // 전략6 · 시작 컨텍스트 선곡: 세션 시작(시작 버튼·모드 전환) "순간"의 상황 —
    // 타이머 모드 × 시간대(표시 타임존 벽시계) × 업무 시작 후 경과(6h-갭 블록) — 로
    // 시작 티어를 정한다:
    //   가볍게 : 아침 첫 1시간 — 밴드 바닥에서 천천히 시동
    //   라운지 : 저녁/심야에 막 시작 — 밤을 새러 왔거나 지쳐서 온 몸을 클럽 라운지처럼
    //            맞이해, 일이 아니라 휴식을 하러 온 기분으로 앉힌다
    //   집중   : 본궤도(1~2h, 또는 낮 시작) — 기존 워밍업 그대로
    //   초집중 : 업무 2h+ — 이제 휴식이 아니라 경쟁이다. 밴드 상단에서 시작해 빠르게 점화
    // 라운지/초집중 티어는 테마 오버레이(contextOverlayMinutes): 그동안 선곡 풀 자체가
    // 해당 테마 폴더로 바뀌고(우선순위: 폭우 > 시작 컨텍스트 > 플랜 슬롯 > 모드 리스트),
    // 만료되면 자연 회전으로 플랜 풀에 복귀한다. 모드 보정(루프=한 단계 위,
    // 트래커=한 단계 아래)까지 겹쳐 같은 순간이라도 세 타이머가 다르게 들린다.
    struct StartTier {
        let label: String       // 로그/풀 칩에 보이는 한국어 이름
        let startFrac: Double   // 시작 BPM = activeMin + span * startFrac
        let ramp: Double        // 워밍업 상승 배율 (modeRamp에 곱해짐)
        let themes: [String]    // 비어있으면 풀 오버레이 없음 (기존 게이트 유지)
    }
    static let startTiers: [String: StartTier] = [
        "gentle": StartTier(label: "가볍게", startFrac: 0.00, ramp: 0.7, themes: []),
        "lounge": StartTier(label: "라운지", startFrac: 0.15, ramp: 0.6, themes: ["lounge"]),
        "focus":  StartTier(label: "집중",   startFrac: 0.35, ramp: 1.0, themes: []),
        "hyper":  StartTier(label: "초집중", startFrac: 0.70, ramp: 1.5,
                            themes: ["house", "challenge", "steel", "last_goal"]),
    ]
    private let contextOverlayMinutes: Double = 20
    // AppDelegate wires the 6h-gap work-block elapsed (분). nil-불가 계약은 두지 않는다
    // (테스트/미배선 시 0 = 방금 시작으로 동작).
    var workElapsedMinutes: (() -> Int)?
    private var contextRamp = 1.0            // active tier's ramp (1.0 until a session starts)
    private var contextThemes: [String] = [] // live overlay pool ([] = no overlay)
    private var contextUntil: Date?          // overlay expiry (nil = no overlay)
    private(set) var startContextLabel: String?  // "심야 · 업무 2.4h → 초집중" (UI/로그)

    // 표시 타임존 기준 시간대 라벨. 사용자의 벽시계가 곧 "심야/아침"의 기준이다.
    static func daypart(hour: Int) -> String {
        switch hour {
        case 5..<11:  return "아침"
        case 11..<17: return "낮"
        case 17..<23: return "저녁"
        default:      return "심야"
        }
    }

    // (모드 × 시간대 × 경과분) → 티어 키. 순수 함수 — 규칙 표가 여기 전부다.
    static func startTierKey(mode: String, daypart: String, elapsedMin: Int) -> String {
        var tier: String
        if elapsedMin < 60 {
            switch daypart {
            case "아침": tier = "gentle"       // 하루의 시동은 가볍게
            case "낮":   tier = "focus"
            default:     tier = "lounge"       // 저녁·심야 fresh = 클럽 라운지로 착각시키기
            }
        } else if elapsedMin < 120 {
            tier = "focus"                     // 본궤도
        } else {
            tier = daypart == "아침" ? "focus" : "hyper"  // 2h+ = 경쟁 모드 (이른 아침만 유예)
        }
        // 모드 보정: 루프는 스스로 고속을 골랐으니 한 단계 위로, 트래커(무제한)는
        // 오래 달릴 판이니 한 단계 아래로. 라운지의 "무드"는 위로만 벗어난다.
        if mode == "sprint" {
            tier = ["gentle": "focus", "lounge": "focus", "focus": "hyper"][tier] ?? tier
        } else if mode == "unlimited" {
            tier = ["hyper": "focus", "focus": "gentle"][tier] ?? tier
        }
        return tier
    }

    // 전략7 · 장소·컨디션 컨텍스트: the user's explicit "where am I / how do I feel"
    // pick (VenueContext catalog). Seeded from Settings so the last choice survives
    // restarts and updates; setVenue persists every change back. The venue narrows
    // the tempo envelope BEFORE 전략5's mode split (nap presets cap even 루프 low)
    // and — when it names real theme folders — owns the selection pool above every
    // automatic gate except the rain reset (the user said where they are; the app
    // should not argue). The default 2명 사무실 is a passthrough: no pool override,
    // full band, so the pre-전략7 pipeline is exactly what "기본" means.
    private(set) var venue = VenueContext.by(key: Settings.shared.bgmVenueKey ?? VenueContext.defaultKey)

    // The venue owns the pool only when it declares themes that actually exist in
    // the library — a preset pointing at missing folders degrades to the auto pool
    // instead of letting the blocked-pool fallback pretend the gate worked.
    private var venueGateActive: Bool {
        !venue.themes.isEmpty && library.tracks.contains { venue.themes.contains($0.theme) }
    }

    // Overlay liveness — mirrors rainActive's shape.
    private var contextActive: Bool {
        guard !contextThemes.isEmpty, let until = contextUntil else { return false }
        return until > Date()
    }

    // 세션이 시작되는 순간마다 컨텍스트를 다시 평가해 시작점을 심는다. targetBPM을
    // 티어의 시작 지점으로 옮기므로 항상 applyModeEnergy() 뒤, 오프너 선곡 전에 불린다.
    private func applyStartContext() {
        let elapsed = workElapsedMinutes?() ?? 0
        var cal = Calendar.current
        cal.timeZone = Settings.shared.displayTimeZone
        let part = Self.daypart(hour: cal.component(.hour, from: Date()))
        let key = Self.startTierKey(mode: sessionMode, daypart: part, elapsedMin: elapsed)
        guard let tier = Self.startTiers[key] else { return }
        contextRamp = tier.ramp
        targetBPM = activeMinBPM + (activeMaxBPM - activeMinBPM) * tier.startFrac
        // 오버레이는 실제 파일이 있는 테마만 — 빈 폴더로 게이트하면 blocked-pool 폴백이
        // 오버레이를 무의미하게 만들 뿐이다.
        contextThemes = tier.themes.filter { t in library.tracks.contains { $0.theme == t } }
        contextUntil = contextThemes.isEmpty ? nil : Date().addingTimeInterval(contextOverlayMinutes * 60)
        let h = elapsed < 60 ? "\(elapsed)분" : String(format: "%.1fh", Double(elapsed) / 60)
        startContextLabel = "\(part) · 업무 \(h) → \(tier.label)"
        var e = ActionLog.Event()
        e.kind = "system"; e.action = "startContext"
        e.detail = "시작 컨텍스트 \(startContextLabel ?? "") · 시작 \(Int(targetBPM))BPM"
            + (contextThemes.isEmpty ? "" : " · 테마 \(contextThemes.joined(separator: "·")) \(Int(contextOverlayMinutes))분")
        e.mode = sessionMode; e.phase = phase.rawValue; e.profile = activeProfileLabel
        e.pool = poolLabel
        ActionLog.shared.append(e)
    }

    // Recompute the effective band from the base band and the active session mode,
    // then reseat targetBPM into it. Callers decide whether to force an audible pick.
    // The bands for sprint (upper) and unlimited (lower) don't overlap, so the same
    // plan pool yields a different nearest-BPM pick per mode.
    private func applyModeEnergy() {
        // 전략7: the venue narrows the profile band first — the user's declared
        // place/condition is the outer envelope 전략5's mode split subdivides, so a
        // nap preset caps even 루프 low while modes still sound distinct inside it.
        let baseSpan = max(0, baseMaxBPM - baseMinBPM)
        let venueMin = baseMinBPM + baseSpan * venue.lo
        let venueMax = baseMinBPM + baseSpan * venue.hi
        let span = max(0, venueMax - venueMin)
        if let e = Self.modeEnergy[sessionMode], span > 0 {
            activeMinBPM = venueMin + span * e.lo
            activeMaxBPM = venueMin + span * e.hi
            modeRamp = e.ramp * venue.ramp
        } else {
            activeMinBPM = venueMin
            activeMaxBPM = venueMax
            modeRamp = venue.ramp
        }
        targetBPM = min(max(targetBPM, activeMinBPM), activeMaxBPM)
    }

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
        self.baseMinBPM = Settings.shared.minBPM
        self.baseMaxBPM = Settings.shared.maxBPM
        self.activeMinBPM = Settings.shared.minBPM
        self.activeMaxBPM = Settings.shared.maxBPM
        self.targetBPM = Settings.shared.minBPM
        // Seed the effective band for the default (pomodoro) mode; start()/
        // setSessionMode re-apply it on each session and mode switch.
        applyModeEnergy()
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
        // 전략5: seat the effective band for the active mode before choosing the
        // opener, so the session begins in this mode's BPM region.
        applyModeEnergy()
        // 전략6: seat the start tier (targetBPM/ramp/theme overlay) for THIS moment.
        applyStartContext()
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
    // (e.g. picking 루프 during the launch countdown while the auto-started
    // session is already live) jumps straight to the new mode's opener so the
    // switch is audible.
    func setSessionMode(_ mode: String) {
        guard Self.modePlaylists[mode] != nil, mode != sessionMode else { return }
        let previous = sessionMode
        sessionMode = mode
        // 전략5: switch into the new mode's BPM band, then make the change audible.
        applyModeEnergy()
        var e = ActionLog.Event()
        e.kind = "user"; e.action = "modeChange"
        e.detail = "세션 모드 \(previous) → \(mode) · 밴드 \(Int(activeMinBPM))-\(Int(activeMaxBPM))BPM"
        e.mode = mode; e.phase = phase.rawValue; e.profile = activeProfileLabel
        e.pool = poolLabel
        ActionLog.shared.append(e)
        // Restart the warmup climb in the new band and jump to a fitting track. If
        // the mode/slot opener isn't in the plan pool, force a gated nearest-BPM pick
        // so the switch is never silent. 전략6: a live mode switch is a fresh "start
        // moment" — re-evaluate the start context before picking.
        if isActive {
            applyStartContext()
            if !playOpener() {
                phase = .warmup
                plateauCount = 0
                releaseUntil = nil
                applyTrack(force: true)
            }
        }
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
    // everything (only heavy_rain tracks); a non-default 장소·컨디션 프리셋(전략7) comes
    // next — the user explicitly said where they are, so it outranks every automatic
    // gate; then a live 시작 컨텍스트 오버레이(전략6) (the session's opening mood owns
    // the pool for its window). Otherwise an active plan slot narrows to its theme
    // folders; else the 전략2 mode playlist applies. BPMLibrary's blocked-pool fallback
    // keeps music playing even if a gate names only missing themes.
    private func inActivePool(_ track: BPMLibrary.Track) -> Bool {
        if rainActive { return track.theme == rainTheme }
        if venueGateActive { return venue.themes.contains(track.theme) }
        if contextActive { return contextThemes.contains(track.theme) }
        if let slot = currentSlot { return slot.themes.contains(track.theme) }
        return inModePlaylist(track)
    }

    // MARK: - 액션 로그 (why-this-track audit)

    // Which gate is choosing tracks right now — mirrors inActivePool's precedence.
    // Surfaced on every trackChange event so the /actions page can show that the
    // plan slot (not the session mode) is what actually picked the music.
    private var poolLabel: String {
        if rainActive { return "폭우 리셋" }
        if venueGateActive { return "장소 · \(venue.label)" }
        if contextActive { return "시작 컨텍스트 · \(startContextLabel ?? "")" }
        if let slot = currentSlot { return "플랜 · \(slot.label)" }
        return "모드 · \(sessionMode)"
    }

    // One line per ACTUAL track switch, tagged with the selecting pool + mode/phase.
    private func logTrack(_ action: String, url: URL, title: String, detail: String) {
        var e = ActionLog.Event()
        e.kind = "bgm"
        e.action = action
        e.detail = detail
        e.mode = sessionMode
        e.track = title
        e.trackKey = url.lastPathComponent
        e.bpm = Int(library.tracks.first(where: { $0.url == url })?.bpm ?? 0)
        e.pool = poolLabel
        e.phase = phase.rawValue
        e.profile = activeProfileLabel
        ActionLog.shared.append(e)
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
        let minutes = TimeInterval.random(in: rainMinMinutes...rainMaxMinutes)
        rainUntil = Date().addingTimeInterval(minutes * 60)
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
            why: "몰입 후 활동 저하 감지 — 폭우 리셋 발동",
            effect: "🌧 폭우 리셋 시작 · \(Int(minutes.rounded()))분")
        logTrack("rainStart", url: rain.url, title: rain.title,
                 detail: "폭우 리셋 시작 · \(Int(minutes.rounded()))분")
    }

    // Rain window elapsed (or stopped): warm back up and jump to plan selection.
    private func endRain() {
        rainUntil = nil
        phase = .warmup
        targetBPM = activeMinBPM + (activeMaxBPM - activeMinBPM) * 0.25
        plateauCount = 0
        var e = ActionLog.Event()
        e.kind = "system"; e.action = "rainEnd"; e.detail = "폭우 리셋 종료 — 일반 선곡 복귀"
        e.mode = sessionMode; e.phase = phase.rawValue; e.profile = activeProfileLabel
        ActionLog.shared.append(e)
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

    // 전략5 Phase2 · 모드 어피니티. The BPM band (Phase1) can't tell tracks apart when a
    // plan pool has no BPM tags (every file falls to BPMLibrary.defaultBPM). To still make
    // 25분/루프/트래커 sound different there, pin each track to one of 3 stable buckets
    // by a deterministic filename hash and have each mode prefer its own bucket. Soft
    // (virtual-BPM penalty, never a hard gate), so an empty bucket never causes silence and
    // recency still rotates within a bucket. On BPM-TAGGED pools the band already separates
    // modes semantically, so this stays a light tiebreaker there.
    private static let modeBucket: [String: Int] = ["pomodoro": 0, "sprint": 1, "unlimited": 2]

    // Stable, process-independent hash (FNV-1a) — Swift's Hasher is per-run randomized and
    // would reshuffle buckets every launch, so we can't use it here.
    private func stableBucket(_ name: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h % 3)
    }

    private func modeAffinityPenalty(_ track: BPMLibrary.Track) -> Double {
        guard let want = Self.modeBucket[sessionMode],
              stableBucket(track.url.lastPathComponent) != want else { return 0 }
        // Untagged (flat) pools depend on this to differentiate; tagged pools already do
        // via the band, so keep it a light nudge there.
        return track.bpmResolved ? 3.0 : 9.0
    }

    // 전략5 Phase3 · hard band gate. The mode band used to be a soft target only —
    // nearest-BPM could still hand a 142BPM steel track to the 70-106 트래커 band
    // when the pool leaned high. When the active pool holds at least one playable
    // in-band track, out-of-band tracks are blocked outright, so the non-overlapping
    // sprint/unlimited bands yield provably disjoint picks. A pool with nothing in
    // band keeps the old nearest-BPM behavior (never silence over separation).
    private func outsideModeBand(_ track: BPMLibrary.Track) -> Bool {
        track.bpm < activeMinBPM || track.bpm > activeMaxBPM
    }

    private func bandGateActive(now: Date) -> Bool {
        library.tracks.contains {
            inActivePool($0) && !outsideModeBand($0)
                && !prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
                && $0.url != audio.currentURL
        }
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
        // 전략7: a non-default venue owns the opener too — the session's first sound
        // comes from the declared place/condition's pool, nearest to the tier start
        // point, with recency rotating back-to-back starts through the pool.
        if venueGateActive {
            let now = Date()
            let gateBand = bandGateActive(now: now)
            if let pick = library.track(
                forTargetBPM: targetBPM,
                excluding: audio.currentURL,
                penalty: { [prefStore] in
                    prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0)
                },
                blocked: { [prefStore] in
                    !self.venue.themes.contains($0.theme)
                        || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
                        || (gateBand && self.outsideModeBand($0))
                }),
               venue.themes.contains(pick.theme) {   // blocked-pool fallback may leak outside
                openerPending = false
                phase = .warmup
                plateauCount = 0
                releaseUntil = nil
                lastTrackChange = Date()
                notePlayed(pick.url)
                audio.play(url: pick.url, title: pick.title)
                logTrack("opener", url: pick.url, title: pick.title,
                         detail: "장소·컨디션 오프너 · \(venue.label)")
                return true
            }
        }
        // 전략6: a live theme overlay picks the opener from ITS pool — the first sound
        // of the session is the context's mood (라운지/점화), not the plan slot's. The
        // recency penalty rotates the pick, so back-to-back starts don't repeat one file.
        if contextActive {
            let now = Date()
            let gateBand = bandGateActive(now: now)
            if let pick = library.track(
                forTargetBPM: targetBPM,
                excluding: audio.currentURL,
                penalty: { [prefStore] in
                    prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0)
                },
                blocked: { [prefStore] in
                    !self.contextThemes.contains($0.theme)
                        || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
                        || (gateBand && self.outsideModeBand($0))
                }),
               contextThemes.contains(pick.theme) {   // blocked-pool fallback may leak outside
                openerPending = false
                phase = .warmup
                plateauCount = 0
                releaseUntil = nil
                lastTrackChange = Date()
                notePlayed(pick.url)
                audio.play(url: pick.url, title: pick.title)
                logTrack("opener", url: pick.url, title: pick.title,
                         detail: "시작 컨텍스트 오프너 · \(startContextLabel ?? "")")
                return true
            }
        }
        let name = currentSlot?.opener ?? Self.modePlaylists[sessionMode]?.first
        guard let name, let opener = library.track(named: name),
              inActivePool(opener) else { return false }
        openerPending = false
        phase = .warmup
        // targetBPM은 건드리지 않는다 — 모든 호출 경로가 직전에 applyStartContext()로
        // 티어 시작점을 심어두며, 여기서 밴드 바닥으로 되돌리면 그 축이 사라진다.
        plateauCount = 0
        releaseUntil = nil
        // AudioEngine.play no-ops on the same URL, so a session paused ON the
        // opener (stop → restart in the same mode) must resume instead.
        if audio.currentURL == opener.url {
            audio.resume()
            logTrack("opener", url: opener.url, title: opener.title,
                     detail: "오프너 재개 (같은 곡에서 정지했던 세션)")
        } else {
            lastTrackChange = Date()
            notePlayed(opener.url)
            audio.play(url: opener.url, title: opener.title)
            let source = currentSlot?.opener != nil ? "플랜 슬롯 고정 오프너" : "모드(\(sessionMode)) 오프너"
            logTrack("opener", url: opener.url, title: opener.title, detail: source)
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

    // 전략7: the user picked a place/condition preset (POST /api/bgm/venue). Persist
    // it, re-derive the band (venue → mode), and — if music is live — restart the
    // warmup from the new envelope with an immediate audible move into the new pool,
    // so the tap is heard within a crossfade, not on the next organic rotation.
    func setVenue(key: String) {
        let next = VenueContext.by(key: key)
        guard next.key != venue.key else { return }
        let previous = venue
        venue = next
        Settings.shared.bgmVenueKey = next.key
        applyModeEnergy()
        var e = ActionLog.Event()
        e.kind = "user"; e.action = "venueChange"
        e.detail = "장소·컨디션 \(previous.label) → \(next.label)"
            + " · 밴드 \(Int(activeMinBPM))-\(Int(activeMaxBPM))BPM"
            + (next.themes.isEmpty ? " · 자동 풀" : " · 테마 \(next.themes.joined(separator: "·"))")
        e.mode = sessionMode; e.phase = phase.rawValue; e.profile = activeProfileLabel
        e.pool = poolLabel
        ActionLog.shared.append(e)
        if isActive {
            phase = .warmup
            plateauCount = 0
            releaseUntil = nil
            targetBPM = min(max(targetBPM, activeMinBPM), activeMaxBPM)
            applyTrack(force: true)
        }
    }

    // Switch the active tempo band to a per-app BGM profile. Re-seats the
    // target into the new band and forces an audible track change.
    func applyProfile(_ profile: BGMProfile) {
        guard profile.label != activeProfileLabel
            || profile.minBPM != baseMinBPM
            || profile.maxBPM != baseMaxBPM else { return }
        // The profile is the outer envelope; 전략5 re-derives the effective band
        // from it for the active mode.
        baseMinBPM = profile.minBPM
        baseMaxBPM = profile.maxBPM
        activeProfileLabel = profile.label
        applyModeEnergy()
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
        // 전략6: a re-armed opener means a NEW work session within this launch —
        // the start context (경과·시간대) has moved on, so re-evaluate before opening.
        if openerPending { applyStartContext() }
        let openedWithModeTrack = openerPending && playOpener()
        openerPending = false
        if !openedWithModeTrack {
            refreshPlanSlot()
            if audio.currentURL == nil {
                applyTrack(force: true)
            } else if let url = audio.currentURL,
                      let playing = library.tracks.first(where: { $0.url == url }),
                      !inActivePool(playing)
                        || playing.bpm < activeMinBPM || playing.bpm > activeMaxBPM {
                // A session start is a fresh moment (전략6): when every opener
                // fallback misses (no overlay, no slot opener, mode opener outside
                // the pool), don't blind-resume the PREVIOUS mode's track — it can
                // sit outside this mode's band/pool and make 루프/트래커 sound
                // identical for a whole min-dwell window.
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
        let gateBand = bandGateActive(now: now)
        return library.track(
            forTargetBPM: targetBPM,
            excluding: audio.currentURL,
            penalty: { [prefStore] in
                prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0) + self.modeAffinityPenalty($0)
            },
            blocked: { [prefStore] in
                !self.inActivePool($0) || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
                    || (gateBand && self.outsideModeBand($0))
            }
        )
    }

    private func tick() {
        // 전략6: an expired theme overlay is cleared here (no forced switch — the
        // rotate-dwell walks selection back into the plan pool organically).
        if let until = contextUntil, until <= Date() {
            contextUntil = nil
            contextThemes = []
        }
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
            // Climb tempo to raise potential. 전략5: the active mode scales the step
            // (루프 climbs faster, 트래커 slower). 전략6: the start tier scales it
            // again (라운지는 눌러두고, 초집중은 빠르게 점화).
            targetBPM = min(maxBPM, targetBPM + warmupStep * modeRamp * contextRamp)
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
                        logTrack("trackChange", url: release.url, title: release.title,
                                 detail: "감속 진입 — 릴리즈 곡 고정")
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
        let gateBand = bandGateActive(now: now)
        guard let candidate = library.track(
            forTargetBPM: targetBPM,
            excluding: audio.currentURL,
            // Learned dis-preference plus recency, so BPM-flat plan pools rotate
            // through the whole folder instead of replaying the same pair.
            penalty: { [prefStore] in
                prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) + self.recencyPenalty($0) + self.modeAffinityPenalty($0)
            },
            // Gate selection to the active pool — the plan slot's themes (전략3) or
            // the mode playlist fallback (dislike cooldowns still apply within it) —
            // and, when the pool can serve it, to the mode's BPM band (전략5 Phase3).
            // BPMLibrary falls back to the full pool if the gate would silence
            // everything.
            blocked: { [prefStore] in
                !self.inActivePool($0) || prefStore.isBlocked(key: $0.url.lastPathComponent, now: now)
                    || (gateBand && self.outsideModeBand($0))
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
        // 전략5: surface the mode band so the action log shows the same plan pool
        // yielding a mode-specific pick.
        let modeBand = " · 모드밴드 \(sessionMode) \(Int(activeMinBPM))-\(Int(activeMaxBPM))BPM"
        logTrack("trackChange", url: candidate.url, title: candidate.title,
                 detail: (force ? "강제 전환 (슬롯/프로필 변경·싫어요·유휴 전환)"
                                : "목표 \(Int(targetBPM))BPM 근접 선곡") + modeBand)
    }
}
