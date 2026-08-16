// gen-icon.swift — renders the ConditionMate app icon (energy / lightning theme).
// Draws a 1024x1024 master PNG with CoreGraphics, then Scripts/build-app.sh (via iconutil)
// turns it into AppIcon.icns. No external image deps — pure AppKit/CoreGraphics.
//
// Usage:  swift Scripts/gen-icon.swift Assets/AppIcon-1024.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon-1024.png"
let S: CGFloat = 1024

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

// CoreGraphics is y-up; we author in y-down normalized coords and flip.
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * S, y: (1 - y) * S) }

// --- Rounded-rect (squircle-ish) background, macOS icon grid: content inset ~10% ---
let inset: CGFloat = S * 0.09
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner: CGFloat = rect.width * 0.235   // Apple continuous-corner ratio approx
let bg = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
// Electric gradient: deep indigo -> electric blue -> cyan (top to bottom).
let cs = CGColorSpaceCreateDeviceRGB()
let colors = [
    CGColor(red: 0.16, green: 0.11, blue: 0.42, alpha: 1),  // deep indigo
    CGColor(red: 0.11, green: 0.36, blue: 0.90, alpha: 1),  // electric blue
    CGColor(red: 0.20, green: 0.80, blue: 0.98, alpha: 1),  // cyan
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// Subtle vignette glow behind the bolt
if let glow = CGGradient(colorsSpace: cs,
    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
             CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]) {
    ctx.drawRadialGradient(glow,
        startCenter: P(0.5, 0.5), startRadius: 0,
        endCenter: P(0.5, 0.5), endRadius: S * 0.42, options: [])
}
ctx.restoreGState()

// --- Lightning bolt (closed polygon, normalized y-down coords) ---
let bolt: [CGPoint] = [
    P(0.50, 0.11),
    P(0.63, 0.11),
    P(0.51, 0.44),
    P(0.73, 0.44),
    P(0.40, 0.90),
    P(0.46, 0.55),
    P(0.28, 0.55),
]
let boltPath = CGMutablePath()
boltPath.addLines(between: bolt)
boltPath.closeSubpath()

// Keep all bolt drawing (incl. its glow) inside the rounded background.
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()

// Glow under bolt
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: CGColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.9))
ctx.addPath(boltPath)
ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.62, alpha: 1))  // warm energetic yellow
ctx.fillPath()
ctx.restoreGState()

// Re-fill crisp on top of glow with a vertical bolt gradient (white top -> amber bottom)
ctx.saveGState()
ctx.addPath(boltPath)
ctx.clip()
let boltColors = [
    CGColor(red: 1.0, green: 1.0, blue: 0.96, alpha: 1),
    CGColor(red: 1.0, green: 0.86, blue: 0.35, alpha: 1),
] as CFArray
let boltGrad = CGGradient(colorsSpace: cs, colors: boltColors, locations: [0, 1])!
ctx.drawLinearGradient(boltGrad, start: P(0.5, 0.08), end: P(0.5, 0.92), options: [])
ctx.restoreGState()

ctx.restoreGState()  // end bg clip for bolt

guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
