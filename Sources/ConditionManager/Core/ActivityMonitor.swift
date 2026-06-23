import AppKit

// Estimates how "active" the user is by counting global input events over a
// rolling window. Keyboard and mouse are tracked separately so the dashboard
// can distinguish active typing (coding/research) from passive pointing
// (browsing/watching). The combined rate drives the ConditionDirector.
//
// Keyboard events require Accessibility trust; mouse/scroll do not. Without
// trust the keyboard rate is undercounted but the app degrades gracefully.
final class ActivityMonitor {

    private(set) var keyRate: Double = 0    // keyboard events/min (smoothed)
    private(set) var mouseRate: Double = 0  // mouse+scroll events/min (smoothed)
    var activityRate: Double { keyRate + mouseRate }

    // Real-time APM (actions/min) for the dashboard gauge. Computed from a short
    // rolling window updated every second, so the number reacts like an in-game
    // APM counter — independent of the slower 5s rate that steers the director.
    private(set) var instantAPM: Double = 0
    // Fixed redline (actions/min). The gauge is a tachometer, not a personal-best
    // tracker: it always reads against this constant so the needle swings up and
    // down with the live rate regardless of any past peak. A one-off burst (e.g.
    // spinning the scroll wheel) no longer pins the scale and flattens the gauge.
    let apmRedline: Double = 250
    // Live APM as a 0...1 fraction of the fixed redline.
    var apmNorm: Double { min(1.0, instantAPM / apmRedline) }

    private(set) var lastEventDate: Date = Date()

    private var monitors: [Any] = []
    private var keyCount = 0
    private var mouseCount = 0
    private var keySmoothed = 0.0
    private var mouseSmoothed = 0.0
    private var sampleTimer: Timer?

    private var liveCount = 0               // events since the last live tick
    private var apmBuckets: [Int] = []      // sub-second event counts (rolling window)
    private let liveInterval: TimeInterval = 0.1   // 10 Hz sampling for a twitchy gauge
    private let apmWindowSeconds: Double = 1.2      // short window => immediate rise/fall
    private let releaseAlpha: Double = 0.25 // per-tick glide when falling (smooth descent)
    private var liveTimer: Timer?

    private let sampleInterval: TimeInterval = 5.0
    private let smoothingAlpha: Double = 0.4

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self = self else { return }
            switch event.type {
            case .keyDown, .flagsChanged: self.keyCount += 1
            default:                      self.mouseCount += 1
            }
            self.liveCount += 1
            self.lastEventDate = Date()
        }) {
            monitors.append(m)
        }

        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: liveInterval, repeats: true) { [weak self] _ in
            self?.liveSample()
        }
    }

    // 10 Hz: roll sub-second event counts through a short window and recompute the
    // live APM, so the gauge rises and falls quickly against the fixed redline.
    private func liveSample() {
        apmBuckets.append(liveCount)
        liveCount = 0
        let maxBuckets = max(1, Int((apmWindowSeconds / liveInterval).rounded()))
        if apmBuckets.count > maxBuckets { apmBuckets.removeFirst() }
        let sum = apmBuckets.reduce(0, +)
        let span = Double(apmBuckets.count) * liveInterval   // seconds covered so far
        let raw = Double(sum) * 60.0 / max(liveInterval, span)
        // Asymmetric envelope (audio-style fast attack / slow release): snap up
        // instantly so bursts stay twitchy, but glide down smoothly so the gauge
        // doesn't stutter or flicker to zero on brief gaps between keystrokes.
        if raw >= instantAPM {
            instantAPM = raw
        } else {
            instantAPM += (raw - instantAPM) * releaseAlpha
        }
    }

    private func sample() {
        let scale = 60.0 / sampleInterval
        let keyPerMin = Double(keyCount) * scale
        let mousePerMin = Double(mouseCount) * scale
        keyCount = 0
        mouseCount = 0
        keySmoothed = keySmoothed * (1 - smoothingAlpha) + keyPerMin * smoothingAlpha
        mouseSmoothed = mouseSmoothed * (1 - smoothingAlpha) + mousePerMin * smoothingAlpha
        keyRate = keySmoothed
        mouseRate = mouseSmoothed
        WorkerRegistry.shared.recordRun("activity-sample",
            why: "5초 입력 집계·평활화",
            effect: "APM \(Int(instantAPM)) · ⌨ \(Int(keyRate))/분 · 🖱 \(Int(mouseRate))/분")
    }

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastEventDate)
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        liveTimer?.invalidate()
        liveTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    func requestAccessibilityPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
