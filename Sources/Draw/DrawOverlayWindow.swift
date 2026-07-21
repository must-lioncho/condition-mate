import AppKit

// Transparent, borderless, click-through overlay covering one screen. It never takes
// key/main status and ignores all mouse events, so the desktop underneath stays fully
// interactive while strokes render on top (level above normal windows and panels).
final class DrawOverlayWindow: NSWindow {

    let canvas: DrawCanvasView

    init(screenFrame: NSRect) {
        canvas = DrawCanvasView(frame: NSRect(origin: .zero, size: screenFrame.size))
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Follow the user across Spaces and over full-screen apps; keep out of ⌘` cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = canvas
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
