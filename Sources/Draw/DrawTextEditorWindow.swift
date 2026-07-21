import AppKit

// Floating single-line text entry summoned by a quick double-tap of LEFT COMMAND —
// the only Draw window that ever takes key focus (it's our own window receiving the
// keystrokes, so text input needs no Accessibility permission either). Return commits
// the text onto the overlay canvas, Escape cancels, and losing focus commits whatever
// was typed (clicking away after typing should not eat the text).
final class DrawTextEditorWindow: NSWindow, NSTextFieldDelegate, NSWindowDelegate {

    private let field = NSTextField()
    private var commit: ((String) -> Void)?
    private var onClosed: (() -> Void)?
    private var finished = false

    init(at global: NSPoint, fontSize: CGFloat, color: NSColor,
         commit: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        self.commit = commit
        self.onClosed = onClosed
        let size = NSSize(width: 620, height: fontSize * 1.9)
        let origin = NSPoint(x: global.x, y: global.y - size.height / 2)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        delegate = self

        // Subtle translucent backdrop so the caret and typing area are visible over
        // any desktop content without looking like a dialog.
        let back = NSView(frame: NSRect(origin: .zero, size: size))
        back.wantsLayer = true
        back.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        back.layer?.cornerRadius = 8

        field.frame = NSRect(x: 12, y: (size.height - fontSize * 1.4) / 2,
                             width: size.width - 24, height: fontSize * 1.4)
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        field.placeholderString = "글씨 입력 후 ⏎"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        back.addSubview(field)
        contentView = back
    }

    override var canBecomeKey: Bool { true }

    func focus() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    // Commit whatever is typed right now (double-⌘ toggle while open lands here).
    func finishNow() { finish(commitText: true) }
    // Discard without committing (left-⌃ wipe / engine stop).
    func cancelNow() { finish(commitText: false) }

    private func finish(commitText: Bool) {
        guard !finished else { return }
        finished = true
        let text = field.stringValue
        if commitText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit?(text)
        }
        commit = nil
        orderOut(nil)
        onClosed?()
        onClosed = nil
    }

    // ⏎ commits, Esc cancels — handled at the field-editor level so the borderless
    // window needs no menu/responder plumbing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finish(commitText: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finish(commitText: false); return true }
        return false
    }

    // Clicking anywhere else takes focus away → commit-if-typed, close.
    func windowDidResignKey(_ notification: Notification) { finish(commitText: true) }
}
