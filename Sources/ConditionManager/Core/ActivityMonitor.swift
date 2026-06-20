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

    private(set) var lastEventDate: Date = Date()

    private var monitors: [Any] = []
    private var keyCount = 0
    private var mouseCount = 0
    private var keySmoothed = 0.0
    private var mouseSmoothed = 0.0
    private var sampleTimer: Timer?

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
            self.lastEventDate = Date()
        }) {
            monitors.append(m)
        }

        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
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
    }

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastEventDate)
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    func requestAccessibilityPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
