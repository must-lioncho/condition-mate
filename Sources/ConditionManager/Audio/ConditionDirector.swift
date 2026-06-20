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
    private let warmupStep: Double = 8.0              // BPM added per warmup tick
    private let sustainResponsiveThreshold = 0.6      // activity/peak below this => fading
    private let stagnationTicks = 3                   // consecutive fading ticks => release
    private let trackSwitchDeltaBPM = 6.0             // min BPM move before re-selecting

    private(set) var phase: Phase = .warmup
    private(set) var targetBPM: Double = 70
    private var peakActivity: Double = 1
    private var plateauCount = 0
    private var releaseUntil: Date?

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

    init(activity: ActivityMonitor, library: BPMLibrary, audio: AudioEngine) {
        self.activity = activity
        self.library = library
        self.audio = audio
        self.activeMinBPM = Settings.shared.minBPM
        self.activeMaxBPM = Settings.shared.maxBPM
        self.targetBPM = Settings.shared.minBPM
    }

    var isRunning: Bool { started }
    var isActive: Bool { timer != nil }

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
        started = false
        timer?.invalidate()
        timer = nil
        audio.stop()
    }

    // The user left the session (idle / not in a tracked app): silence BGM but
    // keep phase + targetBPM so we can resume exactly where we left off.
    func pauseSession() {
        guard started else { return }
        timer?.invalidate()
        timer = nil
        audio.pause()
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

    private func tick() {
        let minBPM = activeMinBPM
        let maxBPM = activeMaxBPM
        let releaseBPM = minBPM + (maxBPM - minBPM) * 0.1 // gentle floor for recovery
        let act = activity.activityRate

        // Adaptive personal peak: slowly decays so a single burst doesn't fix it
        // forever, but always tracks the recent maximum.
        peakActivity = max(peakActivity * 0.98, max(act, 1))
        let norm = act / peakActivity // 0...1, closeness to personal peak

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
    }

    // Select and crossfade to the track nearest the current target BPM.
    private func applyTrack(force: Bool) {
        guard let candidate = library.track(forTargetBPM: targetBPM, excluding: audio.currentURL) else {
            return
        }
        // Avoid thrashing: only switch when the target moved enough, when forced,
        // or when nothing is playing yet.
        if !force, let url = audio.currentURL,
           let playing = library.tracks.first(where: { $0.url == url }) {
            if abs(playing.bpm - candidate.bpm) < trackSwitchDeltaBPM { return }
        }
        audio.play(url: candidate.url, title: candidate.title)
    }
}
