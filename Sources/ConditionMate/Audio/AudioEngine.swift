import Foundation
import AVFoundation
import AppKit

// Minimal looping player with a short crossfade between tracks.
// Uses AVAudioPlayer (not AVAudioEngine) — lower memory and zero graph setup
// for the simple "loop one file" use case.
final class AudioEngine {

    private var current: AVAudioPlayer?
    private var outgoing: AVAudioPlayer?
    private var fadeTimer: Timer?

    private(set) var currentURL: URL?
    private(set) var currentTitle: String?

    // Play-time accounting. AudioEngine is the single chokepoint that knows when a
    // track is actually audible, so it times each contiguous "segment" (from when a
    // track starts/resumes until it switches, pauses, or stops) and reports it. The
    // TrackPlayStatsStore (wired in AppDelegate) accrues the seconds and play counts
    // that feed the BGM 관리 page's "재생 시간 순위" section. A pause/mute does not
    // count (segment closes on pause; mute leaves the segment running since the same
    // track is still the director's active pick, just voiced by the browser instead).
    var onSegmentEnd: ((_ key: String, _ title: String, _ seconds: Double) -> Void)?
    var onTrackStart: ((_ key: String, _ title: String) -> Void)?
    private var segKey: String?
    private var segTitle: String?
    private var segStart: Date?
    private var sleepObservers: [NSObjectProtocol] = []

    // Wall-clock deltas are only trustworthy while the machine is awake: system sleep
    // suspends the process with the segment still open, so an overnight sleep used to
    // land verbatim in a track's cumulative seconds ("2회인데 23시간"). Close the
    // segment right before sleep and reopen it on wake; maxSegmentSeconds below is the
    // backstop for any path where the sleep notification never fires.
    init() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.endSegment()
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let url = self.currentURL, !self.isPaused else { return }
            self.beginSegment(url.lastPathComponent, self.currentTitle ?? url.lastPathComponent)
        })
    }
    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.forEach { nc.removeObserver($0) }
    }

    // No single uninterrupted audible segment is plausibly this long (the director
    // switches tracks with activity, and an idle machine sleeps well before this), so
    // any longer delta is clock leakage — count only the cap, not the gap.
    private let maxSegmentSeconds: TimeInterval = 4 * 3600

    private func beginSegment(_ key: String, _ title: String) {
        endSegment()
        segKey = key; segTitle = title; segStart = Date()
    }
    private func endSegment() {
        guard let k = segKey, let t = segTitle, let s = segStart else { return }
        segKey = nil; segTitle = nil; segStart = nil
        onSegmentEnd?(k, t, min(Date().timeIntervalSince(s), maxSegmentSeconds))
    }
    // The still-open segment's elapsed seconds, folded into the ranking at read time so
    // a long-playing track shows fresh totals without writing on every tick.
    func currentSegment() -> (key: String, title: String, seconds: Double)? {
        guard let k = segKey, let t = segTitle, let s = segStart else { return nil }
        return (k, t, min(Date().timeIntervalSince(s), maxSegmentSeconds))
    }

    // One-shot CoreAudio warm-up. The very first AVAudioPlayer in the process can
    // report isPlaying == true yet route no audio to the output device until the
    // output unit has been started once. That is why a fresh launch was silent
    // until the user toggled BGM off/on (the toggle tears down and recreates the
    // player — the second one is audible). We reproduce that warm-up ourselves the
    // first time we ever play, so the first real track is audible immediately.
    private var primed = false
    private var primer: AVAudioPlayer?

    var targetVolume: Float = 0.8 {
        didSet { applyVolume() }
    }
    private(set) var isPaused = false

    // Force-silence the native output without disturbing targetVolume (which the
    // ConditionDirector manages for idle softening etc.). Used when the dashboard's
    // BGM view takes over playback in the browser, so the same track is not heard
    // twice. Re-applied on every volume-setting path so a crossfade can't unmute it.
    var muted = false {
        didSet { applyVolume() }
    }

    // 받아쓰기 덕킹. superwhisper 가 녹음을 시작하면 음악을 끄는 대신 5% 로 눌러 둔다 —
    // 목소리는 또렷해지면서도 "음악이 끊겼다"는 느낌은 남지 않는다. `muted` 와는 다른 축이다:
    // muted 는 사용자의 의도(⌘M)이거나 웹뷰가 출력을 가져간 상태라 오래 간다면, 이건 몇 초짜리
    // 일시적 억제다. 서로를 덮어쓰지 않고 effectiveVolume 에서 합쳐지며, 더 조용한 쪽이 이긴다.
    // 켜고 끌 때 곧바로 값을 바꾸지 않고 램프를 태우는 이유는 계단식 볼륨 변화가 클릭처럼
    // 들리기 때문 — 내려갈 때는 빠르게(말이 이미 시작됐다), 올라올 때는 느긋하게.
    var voiceDucked = false {
        didSet {
            guard oldValue != voiceDucked else { return }
            // 효과음 덕킹(duck())이 돌고 있으면 그 타이머가 볼륨을 되돌려 놓으므로 먼저 끊는다.
            duckTimer?.invalidate(); duckTimer = nil
            rampVolume(over: voiceDucked ? 0.25 : 0.6)
        }
    }
    private let voiceDuckDepth: Float = 0.05
    private var voiceTimer: Timer?

    // 지금 이 순간 스피커로 나가야 할 볼륨. 볼륨을 정하는 모든 경로가 여기 하나를 거치므로
    // 뮤트·일시정지·덕킹이 어떤 순서로 겹쳐도 결과가 갈라지지 않는다.
    private var effectiveVolume: Float {
        if isPaused || muted { return 0 }
        return voiceDucked ? targetVolume * voiceDuckDepth : targetVolume
    }

    private func applyVolume() {
        // 즉시 확정하는 경로(뮤트 토글, 타깃 볼륨 변경)라 진행 중인 램프보다 우선한다.
        voiceTimer?.invalidate(); voiceTimer = nil
        current?.volume = effectiveVolume
        if isPaused || muted { outgoing?.volume = 0 }
    }

    // 현재 볼륨에서 effectiveVolume 까지 부드럽게 이동. 도중에 뮤트·트랙 전환이 끼어들면
    // 그쪽이 applyVolume/startCrossfade 로 램프를 끊고 자기 값을 쓴다.
    private func rampVolume(over duration: TimeInterval) {
        voiceTimer?.invalidate()
        guard let player = current else { return }
        let from = player.volume
        let to = effectiveVolume
        guard abs(to - from) > 0.001 else { player.volume = to; return }
        let start = Date()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: fadeStep, repeats: true) { [weak self] timer in
            guard let self = self, let p = self.current else { timer.invalidate(); return }
            let prog = min(1.0, Date().timeIntervalSince(start) / duration)
            p.volume = from + (to - from) * Float(prog)
            if prog >= 1.0 {
                timer.invalidate(); self.voiceTimer = nil
                // 램프가 도는 사이 타깃이 움직였을 수 있으니 마지막엔 현재 값으로 확정한다.
                p.volume = self.effectiveVolume
            }
        }
    }

    private let fadeDuration: TimeInterval = 2.0
    private let fadeStep: TimeInterval = 0.05
    private var duckTimer: Timer?

    // Crossfade into a new track and loop it.
    func play(url: URL, title: String) {
        guard url != currentURL else { return }
        // Warm the output unit before the first audible track so it is not silent.
        primeOutputIfNeeded()
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return }
        next.numberOfLoops = -1
        next.volume = 0
        next.prepareToPlay()
        next.play()

        // Demote the existing player to "outgoing" so the fade can lower it.
        outgoing?.stop()
        outgoing = current
        current = next
        currentURL = url
        currentTitle = title
        isPaused = false

        // A genuine new selection: bump the play count and open a fresh play-time
        // segment (which flushes the outgoing track's segment first).
        let key = url.lastPathComponent
        onTrackStart?(key, title)
        beginSegment(key, title)

        startCrossfade()
    }

    private func startCrossfade() {
        fadeTimer?.invalidate()
        // 크로스페이드가 매 틱 볼륨을 직접 쓰므로 받아쓰기 램프와 겹치면 서로 값을 덮어쓴다.
        // 여기서 램프를 끊고, 대신 아래 틱이 effectiveVolume 을 천장으로 써서 덕킹을 이어받는다.
        voiceTimer?.invalidate(); voiceTimer = nil
        var elapsed: TimeInterval = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeStep, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += self.fadeStep
            let progress = min(1.0, elapsed / self.fadeDuration)
            let ceiling = self.effectiveVolume
            self.current?.volume = Float(progress) * ceiling
            self.outgoing?.volume = Float(1 - progress) * ceiling
            if progress >= 1.0 {
                timer.invalidate()
                self.fadeTimer = nil
                self.outgoing?.stop()
                self.outgoing = nil
            }
        }
    }

    func pause() {
        isPaused = true
        endSegment()               // clock stops while paused
        fadeTimer?.invalidate(); fadeTimer = nil
        current?.pause()
        outgoing?.stop(); outgoing = nil
    }

    func resume() {
        guard let player = current else { return }
        isPaused = false
        player.volume = effectiveVolume
        player.play()
        // Resume continues the same track — reopen a segment but do not count a new play.
        if let u = currentURL { beginSegment(u.lastPathComponent, currentTitle ?? u.lastPathComponent) }
    }

    // Audio ducking: briefly drop the BGM so a UI sound effect (e.g. the task-done
    // ka-ching) cuts through, then ramp back to targetVolume. Hold low for `hold`,
    // then release over `release`. No-op while paused. Self-correcting: volume always
    // ends at targetVolume even if a crossfade was running.
    // 받아쓰기 덕킹 중에는 건너뛴다 — 이미 더 낮게 눌려 있고, 이 타이머가 끝나면서
    // 볼륨을 targetVolume 으로 되돌려 놓으면 말하는 도중에 음악이 되살아난다.
    func duck(depth: Float = 0.22, hold: TimeInterval = 0.55, release: TimeInterval = 0.5) {
        guard !isPaused, !muted, !voiceDucked, let player = current else { return }
        duckTimer?.invalidate()
        let low = targetVolume * max(0, min(1, depth))
        player.volume = low
        let start = Date()
        duckTimer = Timer.scheduledTimer(withTimeInterval: fadeStep, repeats: true) { [weak self] timer in
            guard let self = self, let p = self.current, !self.isPaused else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < hold { p.volume = low; return }
            let prog = min(1.0, (elapsed - hold) / release)
            p.volume = low + (self.targetVolume - low) * Float(prog)
            if prog >= 1.0 { timer.invalidate(); self.duckTimer = nil; p.volume = self.targetVolume }
        }
    }

    // Start CoreAudio's output unit once, via a brief burst of silence, so the
    // first real track routes to the device instead of playing into the void.
    private func primeOutputIfNeeded() {
        guard !primed else { return }
        primed = true
        guard let player = try? AVAudioPlayer(data: AudioEngine.silenceWAV) else { return }
        player.volume = 0
        player.prepareToPlay()
        player.play()
        primer = player   // retain so it isn't deallocated mid-playback
    }

    // ~0.2s of 16-bit mono PCM silence wrapped in a minimal WAV container.
    // Internal (not private): SoundEffects reuses it for its own output warm-up.
    static let silenceWAV: Data = {
        let sampleRate: UInt32 = 44_100
        let numSamples = sampleRate / 5          // 0.2 seconds
        let dataSize = numSamples * 2            // 16-bit mono
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data()
        d.append("RIFF".data(using: .ascii)!)
        d.append(le32(36 + dataSize))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(le32(16))                       // PCM fmt chunk size
        d.append(le16(1))                        // format = PCM
        d.append(le16(1))                        // channels = mono
        d.append(le32(sampleRate))
        d.append(le32(sampleRate * 2))           // byte rate
        d.append(le16(2))                        // block align
        d.append(le16(16))                       // bits per sample
        d.append("data".data(using: .ascii)!)
        d.append(le32(dataSize))
        d.append(Data(count: Int(dataSize)))     // silence
        return d
    }()

    func stop() {
        endSegment()               // flush the final segment before going silent
        fadeTimer?.invalidate(); fadeTimer = nil
        duckTimer?.invalidate(); duckTimer = nil
        voiceTimer?.invalidate(); voiceTimer = nil
        current?.stop(); current = nil
        outgoing?.stop(); outgoing = nil
        currentURL = nil
        currentTitle = nil
        isPaused = false
    }
}
