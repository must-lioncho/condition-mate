import Foundation
import AVFoundation

// Minimal looping player with a short crossfade between tracks.
// Uses AVAudioPlayer (not AVAudioEngine) — lower memory and zero graph setup
// for the simple "loop one file" use case.
final class AudioEngine {

    private var current: AVAudioPlayer?
    private var outgoing: AVAudioPlayer?
    private var fadeTimer: Timer?

    private(set) var currentURL: URL?
    private(set) var currentTitle: String?

    // One-shot CoreAudio warm-up. The very first AVAudioPlayer in the process can
    // report isPlaying == true yet route no audio to the output device until the
    // output unit has been started once. That is why a fresh launch was silent
    // until the user toggled BGM off/on (the toggle tears down and recreates the
    // player — the second one is audible). We reproduce that warm-up ourselves the
    // first time we ever play, so the first real track is audible immediately.
    private var primed = false
    private var primer: AVAudioPlayer?

    var targetVolume: Float = 0.8 {
        didSet { current?.volume = isPaused ? 0 : targetVolume }
    }
    private(set) var isPaused = false

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

        startCrossfade()
    }

    private func startCrossfade() {
        fadeTimer?.invalidate()
        var elapsed: TimeInterval = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeStep, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += self.fadeStep
            let progress = min(1.0, elapsed / self.fadeDuration)
            self.current?.volume = Float(progress) * self.targetVolume
            self.outgoing?.volume = Float(1 - progress) * self.targetVolume
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
        fadeTimer?.invalidate(); fadeTimer = nil
        current?.pause()
        outgoing?.stop(); outgoing = nil
    }

    func resume() {
        guard let player = current else { return }
        isPaused = false
        player.volume = targetVolume
        player.play()
    }

    // Audio ducking: briefly drop the BGM so a UI sound effect (e.g. the task-done
    // ka-ching) cuts through, then ramp back to targetVolume. Hold low for `hold`,
    // then release over `release`. No-op while paused. Self-correcting: volume always
    // ends at targetVolume even if a crossfade was running.
    func duck(depth: Float = 0.22, hold: TimeInterval = 0.55, release: TimeInterval = 0.5) {
        guard !isPaused, let player = current else { return }
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
    private static let silenceWAV: Data = {
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
        fadeTimer?.invalidate(); fadeTimer = nil
        duckTimer?.invalidate(); duckTimer = nil
        current?.stop(); current = nil
        outgoing?.stop(); outgoing = nil
        currentURL = nil
        currentTitle = nil
        isPaused = false
    }
}
