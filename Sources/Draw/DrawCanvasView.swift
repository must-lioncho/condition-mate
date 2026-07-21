import AppKit

// The stroke canvas inside one overlay window. Holds finished strokes plus the one in
// progress and renders them as smoothed marker lines (quadratic curves through segment
// midpoints, so fast mouse sampling still reads as a hand-drawn curve, not a polyline).
final class DrawCanvasView: NSView {

    var color = NSColor.systemPurple
    var width: CGFloat = 5

    // Every stroke including the in-progress one (last element while drawing).
    private var strokes: [[NSPoint]] = []

    // Committed text stamps from the double-⌘ writer (size captured per stamp so a
    // future size setting can't retroactively resize what's already on screen).
    private struct TextItem { let string: String; let origin: NSPoint; let size: CGFloat }
    private var texts: [TextItem] = []

    func beginStroke(at p: NSPoint) {
        strokes.append([p])
        needsDisplay = true
    }

    func addPoint(_ p: NSPoint) {
        guard var last = strokes.popLast() else { return }
        // Skip sub-pixel jitter so paths stay light even at the 90 Hz sample rate.
        if let prev = last.last, abs(prev.x - p.x) < 1, abs(prev.y - p.y) < 1 {
            strokes.append(last)
            return
        }
        last.append(p)
        strokes.append(last)
        needsDisplay = true
    }

    func addText(_ s: String, at p: NSPoint, size: CGFloat) {
        texts.append(TextItem(string: s, origin: p, size: size))
        needsDisplay = true
    }

    func clearAll() {
        strokes = []
        texts = []
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    // Belt and braces: the window already ignores mouse events, but make the view
    // itself untouchable too so nothing can ever swallow a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !strokes.isEmpty || !texts.isEmpty else { return }
        for t in texts {
            // Anchor at the editor's text baseline area: origin is the mouse point,
            // draw(at:) uses it as the string's bottom-left.
            NSAttributedString(string: t.string, attributes: [
                .font: NSFont.systemFont(ofSize: t.size, weight: .semibold),
                .foregroundColor: color
            ]).draw(at: NSPoint(x: t.origin.x, y: t.origin.y - t.size / 2))
        }
        color.setStroke()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if stroke.count < 3 {
                for p in stroke.dropFirst() { path.line(to: p) }
            } else {
                // Midpoint smoothing: curve to each midpoint using the vertex as control.
                for i in 1..<(stroke.count - 1) {
                    let mid = NSPoint(x: (stroke[i].x + stroke[i + 1].x) / 2,
                                      y: (stroke[i].y + stroke[i + 1].y) / 2)
                    path.curve(to: mid, controlPoint1: stroke[i], controlPoint2: stroke[i])
                }
                path.line(to: stroke[stroke.count - 1])
            }
            path.stroke()
        }
    }
}
