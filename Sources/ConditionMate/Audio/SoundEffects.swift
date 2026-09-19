import AVFoundation

// One-shot native UI sound effects (포모도로 성공 차임 etc.), separate from the BGM
// pipeline: effects must work even when the session audio is stopped (pomodoro
// completion stops the session FIRST, so the chime lands in silence), and their
// assets live in <data>/sound — deliberately apart from bgm/, which is the
// director's music selection pool. Anything in bgm/ can be picked as a track;
// sound/ files never are.
final class SoundEffects {

    static let shared = SoundEffects()

    // Finished players are pruned on the next play; each is retained here so a
    // one-shot isn't deallocated mid-playback. Main-thread only.
    private var players: [AVAudioPlayer] = []
    private var primed = false
    private var primer: AVAudioPlayer?

    // 효과음 전역 게이트. 마스터 음소거(⌃⌘M)와 효과음 스위치(레일 설정 팝업)가 만나는 곳으로,
    // AppDelegate.applySfxGate가 유일한 writer다. 음소거는 "지금은 조용히 하라"는 뜻이므로
    // 음악만 끄고 알림음이 튀어나오면 그 의도가 깨진다 — 여기서 한 번에 막는다.
    // 막힌 재생은 조용한 no-op이고 playFirst는 nil을 돌려주므로, 호출부의 액션 로그도
    // "울리지 않은 소리"를 기록하지 않는다.
    var muted = false

    private init() {}

    // Play <data>/sound/<name> once. A missing or unreadable file is a silent
    // no-op — effects are cosmetic and must never fail the calling endpoint.
    func play(_ name: String, volume: Float = 0.9) {
        guard !muted else { return }
        let url = AppPaths.sub("sound").appendingPathComponent(name)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        primeOutputIfNeeded()
        players.removeAll { !$0.isPlaying }
        player.volume = volume
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    // Play the first candidate that exists on disk and report which one — lets a
    // user-dropped asset (e.g. pomodoro-start.mp3) override the generated default
    // without a settings UI; the sound folder is the interface.
    @discardableResult
    func playFirst(_ names: [String], volume: Float = 0.9) -> String? {
        guard !muted else { return nil }
        let dir = AppPaths.sub("sound")
        for n in names where FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
            play(n, volume: volume)
            return n
        }
        return nil
    }

    // Same CoreAudio warm-up as AudioEngine: the very first AVAudioPlayer in the
    // process can report isPlaying yet route nothing to the output device. BGM
    // usually primes first (launch auto-start), but the chime must also be audible
    // when it IS the process's first sound.
    private func primeOutputIfNeeded() {
        guard !primed else { return }
        primed = true
        guard let p = try? AVAudioPlayer(data: AudioEngine.silenceWAV) else { return }
        p.volume = 0
        p.prepareToPlay()
        p.play()
        primer = p
    }
}
