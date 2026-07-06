import AppKit

/// The menu-bar condition indicator: a row of lightning bolts whose count,
/// colour, and — crucially — *motion* escalate with the live working condition.
/// It reads `ActivityMonitor.conditionNorm` (current pace ÷ your adaptive
/// personal peak, 0…1) and maps it to five stages:
///
///   Lv1 방전   (0–20%)   1 bolt,  cyan,   slow faint breath
///   Lv2 예열   (20–40%)  2 bolts, cyan,   gentle brightness wave
///   Lv3 정상   (40–60%)  3 bolts, cyan,   fast wave + occasional specular shine
///   Lv4 몰입   (60–80%)  4 bolts, red,    wave + electric flicker & white zap
///   Lv5 최고조 (80–100%) 5 bolts, purple, heartbeat double-pulse + specular shine
///
/// Each stage is a single seamless master loop. Every sub-effect (per-bolt wave,
/// shine sweep, flicker, zap, heartbeat) is expressed as a function of the loop
/// phase, so N frames per stage are pre-rendered once at init (no image assets)
/// and played back by mapping wall-clock time to a frame index on the existing
/// ~20 Hz status-title refresh — no extra timer. Bolts are full colour (not
/// templates) so the stage colour survives on both light and dark menu bars.
final class LightningGauge {

    // Frames and loop period (seconds) per stage. More frames = smoother.
    private static let spec: [Int: (frames: Int, period: Double)] = [
        1: (24, 2.8), 2: (30, 1.6), 3: (48, 3.0), 4: (44, 2.4), 5: (48, 2.8),
    ]

    private let idleImage: NSImage
    private var strips: [Int: [NSImage]] = [:]  // level -> master-loop frames
    private var periods: [Int: Double] = [:]

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
        idleImage = LightningGauge.render(level: 0, u: 0)
        for (lv, s) in LightningGauge.spec {
            periods[lv] = s.period
            strips[lv] = (0..<s.frames).map { LightningGauge.render(level: lv, u: Double($0) / Double(s.frames)) }
        }
        apply(idleImage)
    }

    /// Drive the gauge from the live condition signal. Cheap to call at ~20 Hz:
    /// it only swaps the button image when the stage or master-loop frame changes.
    /// When not working it shows the dim idle bolt.
    func update(norm: Double, working: Bool) {
        guard working else { showIdle(); return }
        let lv = level(for: norm)
        guard let frames = strips[lv], let period = periods[lv], !frames.isEmpty else { return }
        // Frame from wall-clock phase within this stage's master period.
        let u = LightningGauge.frac(Date().timeIntervalSinceReferenceDate / period)
        let frame = min(frames.count - 1, Int(u * Double(frames.count)))
        if showingIdle || lv != currentLevel || frame != currentFrame {
            showingIdle = false; currentLevel = lv; currentFrame = frame
            apply(frames[frame])
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

    // MARK: - Motion math (all functions of loop phase u ∈ [0,1), so loops close)

    private static func frac(_ x: Double) -> Double { x - floor(x) }
    // A smooth 0…1 bump centred at c with width w.
    private static func bump(_ u: Double, _ c: Double, _ w: Double) -> Double { exp(-pow((u - c) / w, 2)) }
    // Per-bolt brightness wave: `cycles` breaths per loop, phase-staggered by bolt.
    private static func wave(_ u: Double, _ i: Int, cycles: Double, offset: Double) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * (cycles * u - Double(i) * offset))
    }
    // Double-beat "lub-dub" envelope over one heartbeat (x ∈ 0…1), then rest.
    private static func heart(_ x: Double) -> Double { min(1, bump(x, 0.10, 0.05) + 0.85 * bump(x, 0.27, 0.05)) }
    // Neon flicker multiplier: mostly on, with a few soft dips. m(0) ≈ m(1) so it loops.
    private static func flicker(_ u: Double) -> Double {
        var m = 0.92
        m -= 0.32 * bump(u, 0.16, 0.012)
        m -= 0.38 * bump(u, 0.42, 0.012)
        m -= 0.28 * bump(u, 0.70, 0.012)
        m += 0.08 * bump(u, 0.55, 0.030)
        return max(0.35, min(1.0, m))
    }

    // MARK: - Rendering

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // Per-stage base colour: cyan (electric) for the lower three, then red and
    // purple escalate the top two into a hotter, more urgent LED.
    private static func baseColor(_ level: Int) -> NSColor {
        switch level {
        case 4: return rgb(0xF0, 0x50, 0x45)   // red
        case 5: return rgb(0xA9, 0x7B, 0xFF)   // purple
        default: return rgb(0x33, 0xC9, 0xE6)  // cyan (idle, Lv1–3)
        }
    }

    // Scale a colour's brightness toward black (an LED dimming). f ∈ 0…1.
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

    // Geometry (points). Padding leaves room for the glow halo so it isn't clipped.
    private static let boltH: CGFloat = 16, boltW: CGFloat = 9, gap: CGFloat = 1, pad: CGFloat = 4

    /// Render one frame at loop phase `u`. `level` 0 = dim idle bolt, 1…5 = that
    /// stage's motion sampled at `u`.
    private static func render(level: Int, u: Double) -> NSImage {
        let count = max(1, min(5, level))
        let base = baseColor(level)

        // Resolve the stage's per-bolt brightness/glow and any shine / zap overlay.
        var bri = [Double](repeating: 0.9, count: count)
        var glow = [Double](repeating: 0.0, count: count)
        var shine: Double? = nil       // specular sweep progress 0…1 when active
        var zap: Double = 0            // white flash alpha

        switch level {
        case 0:
            bri = [0.40]; glow = [0.0]
        case 1:
            let w = wave(u, 0, cycles: 1, offset: 0)      // one slow faint breath
            bri = [0.80 + 0.16 * w]; glow = [0.10 + 0.18 * w]
        case 2:
            for i in 0..<count { let w = wave(u, i, cycles: 1, offset: 0.16); bri[i] = 0.45 + 0.55 * w; glow[i] = w }
        case 3:
            for i in 0..<count { let w = wave(u, i, cycles: 3, offset: 0.12); bri[i] = 0.48 + 0.52 * w; glow[i] = w }
            if u < 0.33 { shine = u / 0.33 }
        case 4:
            let m = flicker(u)
            for i in 0..<count { let w = wave(u, i, cycles: 3, offset: 0.10); bri[i] = (0.42 + 0.58 * w) * m; glow[i] = w * m }
            zap = 0.70 * bump(u, 0.82, 0.018)
        case 5:
            let hb = heart(frac(u * 2))     // two heartbeats per master loop
            for i in 0..<count { bri[i] = 0.42 + 0.58 * hb; glow[i] = hb }
            if u < 0.30 { shine = u / 0.30 }
        default:
            break
        }

        let width = pad * 2 + CGFloat(count) * boltW + CGFloat(count - 1) * gap
        let height = boltH + pad * 2
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        func path(_ i: Int) -> NSBezierPath {
            boltPath(x: pad + CGFloat(i) * (boltW + gap), y: pad, w: boltW, h: boltH)
        }

        // Bolts, each with its own brightness and glow halo.
        for i in 0..<count {
            NSGraphicsContext.saveGraphicsState()
            if glow[i] > 0.02 {
                let sh = NSShadow()
                sh.shadowColor = base.withAlphaComponent(0.15 + 0.5 * CGFloat(glow[i]))
                sh.shadowBlurRadius = 0.8 + 2.4 * CGFloat(glow[i])
                sh.shadowOffset = .zero
                sh.set()
            }
            scaled(base, CGFloat(bri[i])).setFill()
            path(i).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Specular shine: a soft white diagonal band sweeping across, clipped to
        // the bolt shapes so the gloss rides the metal. Rare and quick = premium.
        if let p = shine {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            for i in 0..<count { clip.append(path(i)) }
            clip.addClip()
            let bandW: CGFloat = 11
            let x = -bandW + CGFloat(p) * (width + 2 * bandW)
            if let grad = NSGradient(colors: [.white.withAlphaComponent(0),
                                              .white.withAlphaComponent(0.68),
                                              .white.withAlphaComponent(0)]) {
                grad.draw(in: NSRect(x: x, y: -2, width: bandW, height: height + 4), angle: -72)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Zap: a brief white discharge flash over the bolts.
        if zap > 0.01 {
            NSColor.white.withAlphaComponent(min(1, zap)).setFill()
            for i in 0..<count { path(i).fill() }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
