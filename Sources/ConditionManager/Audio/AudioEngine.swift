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

    var targetVolume: Float = 0.8 {
        didSet { current?.volume = isPaused ? 0 : targetVolume }
    }
    private(set) var isPaused = false

    private let fadeDuration: TimeInterval = 2.0
    private let fadeStep: TimeInterval = 0.05

    // Crossfade into a new track and loop it.
    func play(url: URL, title: String) {
        guard url != currentURL else { return }
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

    func stop() {
        fadeTimer?.invalidate(); fadeTimer = nil
        current?.stop(); current = nil
        outgoing?.stop(); outgoing = nil
        currentURL = nil
        currentTitle = nil
        isPaused = false
    }
}
