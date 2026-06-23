import AppKit

/// A tiny pixel-art bard that lives in the menu bar. It stands idle and, while a
/// work session is active, plays a short "buff" performance once a minute —
/// musical notes rise from its raised hand — mirroring the app's job of buffing
/// your working condition with BGM.
///
/// The character is drawn purely in code (no image assets): each frame is a grid
/// of single-char codes mapped to a colour palette, rendered nearest-neighbour so
/// the pixels stay crisp at menu-bar size and on Retina. The pixel data here is
/// the exact same data used in the design preview.
final class MenuBarBard {

    // Palette: maps a frame character to a colour. "." is transparent.
    private static let palette: [Character: NSColor] = [
        "o": rgb(0x2a, 0x24, 0x40),   // outline
        "p": rgb(0x7b, 0x5c, 0xff),   // hat (purple)
        "r": rgb(0xff, 0x6b, 0x3d),   // feather
        "s": rgb(0xff, 0xd0, 0xa3),   // skin
        "e": rgb(0x15, 0x10, 0x1f),   // eye
        "t": rgb(0x21, 0xc7, 0xb8),   // tunic (teal)
        "b": rgb(0x4a, 0x3b, 0x73),   // belt / boots
        "w": rgb(0xe0, 0x86, 0x3a),   // lute wood
        "m": rgb(0xff, 0xd9, 0xa0),   // lute highlight
        "n": rgb(0xff, 0xd8, 0x4d),   // musical note / sparkle
    ]

    private static let idle = [
        "................",
        ".......oo.......",
        "......orro......",
        "....oorppo......",
        "...opppppo......",
        "...opppppo......",
        "...osssso.......",
        "...oseseo.......",
        "...osssso.......",
        "....oooo........",
        "...ottto........",
        "..otttttto......",
        "..ottwwwtto.....",
        "..obtwmwwto.....",
        "...otwwwto......",
        "...oo..oo......."]

    private static let cast1 = [
        "................", ".......oo.......", "......orro......", "....oorppo......",
        "...opppppo......", "...opppppo......", "...osssso....n..", "...oseseo.......",
        "...osssso..oso..", "....oooo..osso..", "...ottto.oso....", "..otttttto......",
        "..ottwwwtto.....", "..obtwmwwto.....", "...otwwwto......", "...oo..oo......."]

    private static let cast2 = [
        "................", ".......oo.......", "......orro......", "....oorppo......",
        "...opppppo...n..", "...opppppo......", "...osssso...n...", "...oseseo.......",
        "...osssso..oso..", "....oooo..osso..", "...ottto.oso....", "..otttttto......",
        "..ottwwwtto.....", "..obtwmwwto.....", "...otwwwto......", "...oo..oo......."]

    private static let cast3 = [
        "................", ".......oo.......", "......orro....n.", "....oorppo...n..",
        "...opppppo......", "...opppppo...n..", "...osssso.......", "...oseseo.......",
        "...osssso..oso..", "....oooo..osso..", "...ottto.oso....", "..otttttto......",
        "..ottwwwtto.....", "..obtwmwwto.....", "...otwwwto......", "...oo..oo......."]

    private static let cast4 = [
        "..............n.", ".......oo.......", "......orro......", "....oorppo...n..",
        "...opppppo......", "...opppppo......", "...osssso.......", "...oseseo.......",
        "...osssso..oso..", "....oooo..osso..", "...ottto.oso....", "..otttttto......",
        "..ottwwwtto.....", "..obtwmwwto.....", "...otwwwto......", "...oo..oo......."]

    // Pre-rendered images.
    private let idleImage: NSImage
    private let castImages: [NSImage]

    // Cadence: one buff performance per minute while active.
    private let buffInterval: TimeInterval = 60
    // Each cast frame holds this long; cycling the 4 frames repeatedly fills the
    // performance window. ~0.13s × ~27 frames ≈ 3.5s.
    private let frameInterval: TimeInterval = 0.13
    private let buffDuration: TimeInterval = 3.5

    private var cadenceTimer: Timer?
    private var frameTimer: Timer?
    private var apply: (NSImage) -> Void

    /// `apply` installs an image onto the status item button (called on the main thread).
    init(apply: @escaping (NSImage) -> Void) {
        self.apply = apply
        idleImage = MenuBarBard.render(MenuBarBard.idle)
        castImages = [MenuBarBard.cast1, MenuBarBard.cast2, MenuBarBard.cast3, MenuBarBard.cast4]
            .map { MenuBarBard.render($0) }
        apply(idleImage)
    }

    /// Show the idle bard without any cadence (used at launch, before working).
    func showIdle() {
        frameTimer?.invalidate(); frameTimer = nil
        apply(idleImage)
    }

    /// Begin the per-minute buff cadence. Plays one buff immediately as feedback
    /// that the session started, then repeats every minute.
    func startBuffing() {
        guard cadenceTimer == nil else { return }
        playBuff()
        cadenceTimer = Timer.scheduledTimer(withTimeInterval: buffInterval, repeats: true) { [weak self] _ in
            self?.playBuff()
        }
    }

    /// Stop the cadence and return to idle.
    func stop() {
        cadenceTimer?.invalidate(); cadenceTimer = nil
        frameTimer?.invalidate(); frameTimer = nil
        apply(idleImage)
    }

    private func playBuff() {
        WorkerRegistry.shared.recordRun("bard",
            why: "세션 활성 · 60초 주기", effect: "버프 연출 재생(메뉴바 픽셀 애니메이션)")
        frameTimer?.invalidate()
        let start = Date()
        var i = 0
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if Date().timeIntervalSince(start) >= self.buffDuration {
                t.invalidate()
                self.frameTimer = nil
                self.apply(self.idleImage)
                return
            }
            self.apply(self.castImages[i % self.castImages.count])
            i += 1
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Rendering

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Render a pixel grid into an 18pt-tall NSImage, drawn nearest-neighbour so
    /// each cell is a crisp square. Not a template image — the bard is full colour.
    private static func render(_ grid: [String]) -> NSImage {
        let cols = grid.map(\.count).max() ?? 16
        let rows = grid.count
        let pt: CGFloat = 18                       // logical menu-bar height
        let cell = pt / CGFloat(rows)
        let size = NSSize(width: cell * CGFloat(cols), height: pt)

        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (y, line) in grid.enumerated() {
            for (x, ch) in line.enumerated() {
                guard let color = palette[ch] else { continue }
                color.setFill()
                // Grid row 0 is the top; AppKit's origin is bottom-left, so flip y.
                let rect = NSRect(x: CGFloat(x) * cell,
                                  y: CGFloat(rows - 1 - y) * cell,
                                  width: cell, height: cell)
                rect.fill()
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
