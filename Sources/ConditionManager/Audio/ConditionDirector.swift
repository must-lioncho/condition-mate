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

    private(set) var phase: Phase = .warmup
    private(set) var targetBPM: Double = 70
    private(set) var lastNorm: Double = 0             // last activity/peak ratio (for logging)
    private var peakActivity: Double = 1
    private var plateauCount = 0
    private var releaseUntil: Date?
    private var lastTrackChange: Date?               // when the current track started (for min-dwell)

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

    private let activity: ActivityMonitor
    private let library: BPMLibrary
    private let audio: AudioEngine
    private let prefStore: TrackPreferenceStore

    init(activity: ActivityMonitor, library: BPMLibrary, audio: AudioEngine,
         prefStore: TrackPreferenceStore) {
        self.activity = activity
        self.library = library
        self.audio = audio
        self.prefStore = prefStore
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
        resumeSession()
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
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: decisionInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    // The slowest sensible tempo for ambient idle: the slowest track in the
    // library, but never faster than the active band's floor.
    private func idleTargetBPM() -> Double {
        if let libMin = library.bpmRange?.min { return min(activeMinBPM, libMin) }
        return activeMinBPM
    }

    // Back in session: resume decisions and sound.
    func resumeSession() {
        guard started else { return }
        if audio.currentURL == nil {
            applyTrack(force: true)
        } else {
            audio.resume()
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: decisionInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    // Seconds remaining in a release window, for UI display (nil if not releasing).
    var releaseRemaining: TimeInterval? {
        guard phase == .release, let until = releaseUntil else { return nil }
        return max(0, until.timeIntervalSinceNow)
    }

    // Short Korean gear label for the accelerator gauge.
    var gearLabel: String {
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
            penalty: { [prefStore] in prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) },
            blocked: { [prefStore] in prefStore.isBlocked(key: $0.url.lastPathComponent, now: now) }
        )
    }

    private func tick() {
        let minBPM = activeMinBPM
        let maxBPM = activeMaxBPM
        let releaseBPM = minBPM + (maxBPM - minBPM) * 0.1 // gentle floor for recovery
        let act = activity.activityRate

        // Adaptive personal peak: slowly decays so a single burst doesn't fix it
        // forever, but always tracks the recent maximum.
        peakActivity = max(peakActivity * 0.98, max(act, 1))
        let norm = act / peakActivity // 0...1, closeness to personal peak
        lastNorm = norm

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

        applyTrack(force: false)
        WorkerRegistry.shared.recordRun("director",
            why: "20초 주기 활동률 평가 (norm \(String(format: "%.2f", lastNorm)))",
            effect: "\(phase.rawValue) · 목표 \(Int(targetBPM))BPM [\(Int(minBPM))-\(Int(maxBPM))]")
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
        let now = Date()
        guard let candidate = library.track(
            forTargetBPM: targetBPM,
            excluding: audio.currentURL,
            penalty: { [prefStore] in prefStore.bpmPenalty(key: $0.url.lastPathComponent, now: now) },
            blocked: { [prefStore] in prefStore.isBlocked(key: $0.url.lastPathComponent, now: now) }
        ) else {
            return
        }
        // Avoid thrashing: for organic (non-forced) switches, hold the current
        // track until it has played a musical minimum (min dwell) AND the target
        // has moved enough. Forced switches (profile change, dislike, idle
        // enter/exit) bypass both gates for immediate response.
        if !force, let url = audio.currentURL,
           let playing = library.tracks.first(where: { $0.url == url }) {
            if let started = lastTrackChange,
               now.timeIntervalSince(started) < minTrackDwell { return }
            if abs(playing.bpm - candidate.bpm) < trackSwitchDeltaBPM { return }
        }
        lastTrackChange = now
        audio.play(url: candidate.url, title: candidate.title)
    }
}
