import AppKit

/// The menu-bar condition indicator: a row of lightning bolts whose count and
/// LED-style pulse encode the live working condition across five stages. It
/// reads `ActivityMonitor.conditionNorm` (current pace ÷ your adaptive personal
/// peak, 0…1) and maps it to:
///
///   Lv1 방전   (0–20%)   1 bolt,  cyan,   static (no LED)
///   Lv2 예열   (20–40%)  2 bolts, cyan,   LED pulse (medium)
///   Lv3 정상   (40–60%)  3 bolts, cyan,   LED pulse (fast)
///   Lv4 몰입   (60–80%)  4 bolts, red,    LED pulse (faster)
///   Lv5 최고조 (80–100%) 5 bolts, purple, LED pulse (fastest)
///
/// The "LED" is a breathing glow: each bolt brightens and dims with a soft halo,
/// speeding up (and shifting colour at the top two stages) as condition climbs.
/// Frames are pre-rendered once per level (no image assets), and the pulse is
/// driven by wall-clock time sampled on the existing ~20 Hz status-title refresh,
/// so there is no extra timer. The bolts are full colour (not template images)
/// so the stage colour survives on both light and dark menu bars.
final class LightningGauge {

    // Number of pre-rendered frames in one pulse cycle. The playback speed comes
    // from each level's period, not the frame count.
    private static let frameCount = 18

    // Seconds per LED breath, per level. Lower = faster. Lv1 is static.
    private static let periods: [Int: Double] = [2: 1.4, 3: 0.9, 4: 0.7, 5: 0.55]

    // Pre-rendered images: the paused/idle bolt, the static Lv1 bolt, and one
    // frame-strip per animated level (2…5).
    private let idleImage: NSImage
    private let staticImage: NSImage        // Lv1
    private var strips: [Int: [NSImage]] = [:]  // level -> pulse frames

    // Hysteresis so a value hovering on a band edge doesn't flip stages every
    // sample; a stage only changes once the norm clears the boundary by `margin`.
    private static let boundaries: [Double] = [0.2, 0.4, 0.6, 0.8]
    private static let margin = 0.03
    private var currentLevel = 0
    private var currentFrame = -1
    private var showingIdle = true

    private let apply: (NSImage) -> Void

    /// `apply` installs an image onto the status item button (main thread).
    init(apply: @escaping (NSImage) -> Void) {
        self.apply = apply
        idleImage = LightningGauge.render(level: 0, t: 0)
        staticImage = LightningGauge.render(level: 1, t: 0)
        for lv in 2...5 {
            strips[lv] = (0..<LightningGauge.frameCount).map { f in
                // Cosine easing 0→1→0 over the cycle for a smooth breath.
                let t = 0.5 - 0.5 * cos(2 * Double.pi * Double(f) / Double(LightningGauge.frameCount))
                return LightningGauge.render(level: lv, t: CGFloat(t))
            }
        }
        apply(idleImage)
    }

    /// Drive the gauge from the live condition signal. Cheap to call at ~20 Hz:
    /// it only swaps the button image when the stage or pulse frame changes. When
    /// not working it shows the dim idle bolt.
    func update(norm: Double, working: Bool) {
        guard working else { showIdle(); return }
        let lv = level(for: norm)
        if lv <= 1 {
            if showingIdle || currentLevel != lv || currentFrame != -1 {
                showingIdle = false; currentLevel = lv; currentFrame = -1
                apply(staticImage)
            }
            return
        }
        // Animated stage: pick the frame from wall-clock phase within its period.
        let period = LightningGauge.periods[lv] ?? 0.9
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let frame = min(LightningGauge.frameCount - 1, Int(phase * Double(LightningGauge.frameCount)))
        if showingIdle || lv != currentLevel || frame != currentFrame {
            showingIdle = false; currentLevel = lv; currentFrame = frame
            apply(strips[lv]?[frame] ?? staticImage)
        }
    }

    /// Return to the paused/idle bolt (session stopped).
    func showIdle() {
        if !showingIdle {
            showingIdle = true; currentLevel = 0; currentFrame = -1
            apply(idleImage)
        }
    }

    // Map 0…1 to a stage 1…5 with edge hysteresis around the fixed 20% bands.
    private func level(for norm: Double) -> Int {
        var lv = max(1, currentLevel)
        while lv < 5 && norm >= LightningGauge.boundaries[lv - 1] + LightningGauge.margin { lv += 1 }
        while lv > 1 && norm < LightningGauge.boundaries[lv - 2] - LightningGauge.margin { lv -= 1 }
        return lv
    }

    // MARK: - Rendering

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // Per-stage base colour. Cyan reads as clean "electric" for the lower three
    // stages; red then purple escalate the top two into a hotter, more urgent LED.
    private static func baseColor(_ level: Int) -> NSColor {
        switch level {
        case 4: return rgb(0xF0, 0x50, 0x45)   // red
        case 5: return rgb(0xA9, 0x7B, 0xFF)   // purple
        default: return rgb(0x33, 0xC9, 0xE6)  // cyan (idle, Lv1–3)
        }
    }

    // Scale a colour's brightness toward black (an LED dimming). f in 0…1.
    private static func scaled(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return NSColor(srgbRed: min(1, s.redComponent * f),
                       green: min(1, s.greenComponent * f),
                       blue: min(1, s.blueComponent * f), alpha: 1)
    }

    // Lightning polygon authored in a 24×30 box (y-down, like the design mockup).
    private static let boltPoints: [(CGFloat, CGFloat)] = [
        (14, 1), (4, 17), (11, 17), (9, 29), (20, 11), (13, 11),
    ]

    private static func boltPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSBezierPath {
        let sx = w / 24, sy = h / 30
        let path = NSBezierPath()
        for (i, p) in boltPoints.enumerated() {
            let pt = NSPoint(x: x + p.0 * sx, y: y + (h - p.1 * sy))   // flip y
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        return path
    }

    /// Render one frame. `level` 0 = dim idle bolt; 1 = static bolt; 2…5 = that
    /// many bolts with the LED breath at intensity `t` (0 dim … 1 bright+glow).
    private static func render(level: Int, t: CGFloat) -> NSImage {
        let animated = level >= 2
        let count = max(1, min(5, level))
        let base = baseColor(level)

        let boltH: CGFloat = 16, boltW: CGFloat = 9, gap: CGFloat = 1
        let padX: CGFloat = 3, padY: CGFloat = 2          // room for the glow halo
        let width = padX * 2 + CGFloat(count) * boltW + CGFloat(count - 1) * gap
        let height = boltH + padY * 2

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        // Brightness: dim idle, steady-bright static Lv1, breathing for animated.
        let factor: CGFloat = level == 0 ? 0.40 : (animated ? 0.55 + 0.45 * t : 0.92)
        if animated {
            let glow = NSShadow()
            glow.shadowColor = base.withAlphaComponent(0.12 + 0.55 * t)
            glow.shadowBlurRadius = 1.0 + 2.2 * t
            glow.shadowOffset = .zero
            glow.set()
        }
        LightningGauge.scaled(base, factor).setFill()
        for i in 0..<count {
            let ox = padX + CGFloat(i) * (boltW + gap)
            boltPath(x: ox, y: padY, w: boltW, h: boltH).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
