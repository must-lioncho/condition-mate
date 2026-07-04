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

    // Rolling 1-minute average APM (actual actions over the trailing 60s, scaled
    // to per-minute). The menu-bar widget reads this instead of instantAPM so the
    // number reflects a realistic sustained pace and stops flickering up and down
    // each second — while the dashboard gauge keeps using the twitchy instant APM.
    private(set) var averageAPM: Double = 0
    private var minuteBuckets: [Int] = []           // per-tick event counts over the trailing minute
    private let apmAverageSeconds: Double = 60.0

    // "Condition" signal (0...1) for the menu-bar lightning gauge: the 1-minute
    // average APM measured against an adaptive personal peak that slowly decays.
    // Unlike apmNorm (fixed redline), this reads how hot the current pace is
    // relative to your *own* recent best — 1.0 means "at your peak", low means
    // "well below it". It mirrors ConditionDirector.lastNorm (activity/peak) but
    // is computed here on the always-live sampler, so the gauge keeps moving even
    // when BGM/디렉터 is stopped (plugin not installed, idle, untracked app).
    private(set) var conditionNorm: Double = 0
    private var conditionPeak: Double = 1

    private(set) var lastEventDate: Date = Date()

    private var monitors: [Any] = []
    private var keyCount = 0
    private var mouseCount = 0
    private var keySmoothed = 0.0
    private var mouseSmoothed = 0.0
    private var sampleTimer: Timer?

    private var liveCount = 0               // events since the last live tick
    private var apmBuckets: [Int] = []      // sub-second event counts (rolling window)

    // Scroll coalescing: a single physical scroll gesture (trackpad momentum, a
    // mouse-wheel spin) fires a dense stream of .scrollWheel events. Counting
    // each one pins the APM gauge, so we collapse a continuous burst into one
    // activity: a scroll only counts if it arrives after a quiet gap.
    private var lastScrollDate: Date?
    private let scrollCoalesceGap: TimeInterval = 0.3
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
            let now = Date()
            switch event.type {
            case .keyDown, .flagsChanged:
                self.keyCount += 1
            case .scrollWheel:
                // Collapse a continuous scroll burst into a single activity:
                // skip events that fall within the coalescing gap of the last.
                if let last = self.lastScrollDate, now.timeIntervalSince(last) < self.scrollCoalesceGap {
                    self.lastScrollDate = now
                    self.lastEventDate = now   // still "active", just not a new activity
                    return
                }
                self.lastScrollDate = now
                self.mouseCount += 1
            default:
                self.mouseCount += 1
            }
            self.liveCount += 1
            self.lastEventDate = now
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
        let live = liveCount
        liveCount = 0
        apmBuckets.append(live)
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

        // Rolling 1-minute average: sum the same per-tick counts over a 60s window.
        // Before the window fills, scale by the elapsed span so it reads correctly
        // from the first minute. This is a plain average, no envelope, so the
        // menu-bar number moves smoothly instead of twitching each second.
        minuteBuckets.append(live)
        let maxMinute = max(1, Int((apmAverageSeconds / liveInterval).rounded()))
        if minuteBuckets.count > maxMinute { minuteBuckets.removeFirst() }
        let mSum = minuteBuckets.reduce(0, +)
        let mSpan = Double(minuteBuckets.count) * liveInterval
        averageAPM = Double(mSum) * 60.0 / max(liveInterval, mSpan)
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

        // Adaptive personal peak with a slow decay (~6 min half-life at this 5s
        // cadence) so a single burst doesn't pin the scale forever, then express
        // the current sustained pace as a fraction of it. Floor the peak at 1 so a
        // quiet session reads as low condition rather than dividing toward 0/0.
        conditionPeak = max(conditionPeak * 0.99, max(averageAPM, 1))
        conditionNorm = min(1.0, averageAPM / conditionPeak)

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
