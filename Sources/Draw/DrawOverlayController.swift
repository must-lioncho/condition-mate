import AppKit

// Screen-drawing overlay ("드로우" plugin engine). Hold the LEFT OPTION key to sketch
// on top of everything with the mouse; triple-tap the LEFT COMMAND key to type 30pt
// text at the cursor; tap the FN key to wipe the canvas. (Wipe was left ⌃ originally,
// but ⌃ collides with the macOS screenshot-to-clipboard chords the user presses a lot,
// which kept erasing the canvas mid-capture. Text was a double-tap originally, but
// rapid ⌘C→⌘V copy-paste bursts produced two close-together ⌘ down edges and kept
// popping the editor, so it moved to three taps.)
//
// WHY polling instead of event taps: global keyboard monitors (NSEvent global monitor
// for .flagsChanged, CGEventTap) require the Accessibility permission. This app never
// asks for it, so the engine polls CGEventSource.keyState() — a pure state query that
// needs no permission and distinguishes LEFT option/command by hardware keycode, which
// NSEvent.modifierFlags cannot. The poll runs slow (15 Hz) while idle and ramps to
// 90 Hz only while a stroke is in progress, so the resident cost stays negligible.
//
// The overlay windows are transparent, borderless, click-through (they never intercept
// mouse events — drawing only samples NSEvent.mouseLocation), one per screen, shown
// lazily when the first stroke starts and hidden again when the canvas is wiped.
//
// Deliberately app-agnostic (like the GUI target): no ConditionManager types. The app
// wires liveness reporting via `onActivity`.
public final class DrawOverlayController {

    // Hardware keycodes (ANSI layout-independent): 58 = left ⌥, 63 = fn, 55 = left ⌘.
    private static let leftOptionKey: CGKeyCode = 58
    private static let fnKey: CGKeyCode = 63
    private static let leftCommandKey: CGKeyCode = 55

    private static let idleInterval: TimeInterval = 1.0 / 15.0   // watching for ⌥
    private static let fastInterval: TimeInterval = 1.0 / 90.0   // sampling a stroke
    // Left-⌘ down edges chain into a multi-tap while each gap stays within this
    // window; three chained taps trigger the text editor. Shortcut usage (⌘C→⌘V …)
    // normally holds ⌘ across keys = ONE down edge, and even a quick copy-paste
    // burst rarely produces three separate taps this fast.
    private static let cmdTapWindow: TimeInterval = 0.4
    private static let cmdTapsRequired = 3

    // Stroke look — the sketchy purple marker from the mock.
    public var strokeColor = NSColor(calibratedRed: 0.80, green: 0.42, blue: 0.93, alpha: 1)
    public var lineWidth: CGFloat = 5
    // Text look for the triple-⌘ writer (사이즈 요청값 30pt).
    public var textFontSize: CGFloat = 30

    // Throttled liveness tick (~every 5s while running) so the host app can stamp a
    // worker-registry heartbeat without this target depending on it.
    public var onActivity: (() -> Void)?

    public private(set) var isRunning = false

    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var windows: [DrawOverlayWindow] = []
    private var activeCanvas: DrawCanvasView?
    private var drawing = false
    private var prevFnDown = false
    private var prevCommandDown = false
    private var lastCommandDownAt = Date.distantPast
    private var commandTapCount = 0
    private var textEditor: DrawTextEditorWindow?
    private var textAnchor = NSPoint.zero
    private weak var appToRestore: NSRunningApplication?
    private var lastActivityAt = Date.distantPast
    private var screenObserver: NSObjectProtocol?

    public init() {}

    // Arm the overlay: start the idle poll and track screen topology changes.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        syncWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.syncWindows() }
        schedule(interval: Self.idleInterval)
    }

    // Disarm: stop polling, wipe strokes, hide every overlay window.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil; timerInterval = 0
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        drawing = false
        activeCanvas = nil
        clear()
    }

    // Wipe all strokes/text and hide the (now empty) overlay windows. Also discards
    // an open text editor — a wipe means "everything off the screen".
    public func clear() {
        textEditor?.cancelNow()
        for w in windows {
            w.canvas.clearAll()
            w.orderOut(nil)
        }
        activeCanvas = nil
        drawing = false
    }

    // MARK: Poll loop

    private func schedule(interval: TimeInterval) {
        guard timerInterval != interval else { return }
        timerInterval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let optionDown = CGEventSource.keyState(.combinedSessionState, key: Self.leftOptionKey)
        let fnDown = CGEventSource.keyState(.combinedSessionState, key: Self.fnKey)
        let commandDown = CGEventSource.keyState(.combinedSessionState, key: Self.leftCommandKey)

        // fn: wipe on the down EDGE only, so holding it doesn't spin.
        if fnDown && !prevFnDown { clear() }
        prevFnDown = fnDown

        // Left command: three down edges, each within the tap window of the previous
        // one, open the text editor at the cursor (another triple-tap commits and
        // closes it). A longer gap resets the chain to tap #1.
        if commandDown && !prevCommandDown {
            let now = Date()
            if now.timeIntervalSince(lastCommandDownAt) <= Self.cmdTapWindow {
                commandTapCount += 1
            } else {
                commandTapCount = 1
            }
            lastCommandDownAt = now
            if commandTapCount >= Self.cmdTapsRequired {
                commandTapCount = 0
                lastCommandDownAt = .distantPast
                toggleTextEditor(at: NSEvent.mouseLocation)
            }
        }
        prevCommandDown = commandDown

        if optionDown {
            addSample(NSEvent.mouseLocation, strokeStart: !drawing)
            drawing = true
            schedule(interval: Self.fastInterval)
        } else if drawing {
            drawing = false
            activeCanvas = nil
            schedule(interval: Self.idleInterval)
        }

        let now = Date()
        if now.timeIntervalSince(lastActivityAt) >= 5 {
            lastActivityAt = now
            onActivity?()
        }
    }

    // Route a global-coordinate sample to the canvas of the screen under the cursor.
    // Crossing into another screen mid-stroke starts a fresh stroke there (the two
    // windows cannot share one path).
    private func addSample(_ global: NSPoint, strokeStart: Bool) {
        guard let window = windows.first(where: { $0.frame.contains(global) }) ?? windows.first else { return }
        let canvas = window.canvas
        canvas.color = strokeColor
        canvas.width = lineWidth
        let local = NSPoint(x: global.x - window.frame.origin.x,
                            y: global.y - window.frame.origin.y)
        if strokeStart || canvas !== activeCanvas {
            activeCanvas = canvas
            window.orderFrontRegardless()
            canvas.beginStroke(at: local)
        } else {
            canvas.addPoint(local)
        }
    }

    // MARK: Text (triple left-⌘)

    // Open the 30pt text editor at the cursor, or — if one is already up — commit
    // what's typed and close it (triple-tap works as an open/commit toggle).
    private func toggleTextEditor(at global: NSPoint) {
        if let editor = textEditor { editor.finishNow(); return }
        textAnchor = global
        // Remember who had focus so committing hands it right back (we're a menu-bar
        // app; stealing focus permanently would be rude).
        appToRestore = NSWorkspace.shared.frontmostApplication
        let editor = DrawTextEditorWindow(
            at: global, fontSize: textFontSize, color: strokeColor,
            commit: { [weak self] text in self?.commitText(text) },
            onClosed: { [weak self] in
                guard let self else { return }
                self.textEditor = nil
                if let prev = self.appToRestore, prev != NSRunningApplication.current {
                    prev.activate()
                }
                self.appToRestore = nil
            })
        textEditor = editor
        NSApp.activate(ignoringOtherApps: true)
        editor.focus()
    }

    // Stamp committed text onto the canvas of the screen where the editor was opened.
    private func commitText(_ text: String) {
        guard let window = windows.first(where: { $0.frame.contains(textAnchor) }) ?? windows.first else { return }
        let canvas = window.canvas
        canvas.color = strokeColor
        let local = NSPoint(x: textAnchor.x - window.frame.origin.x,
                            y: textAnchor.y - window.frame.origin.y)
        window.orderFrontRegardless()
        canvas.addText(text, at: local, size: textFontSize)
    }

    // MARK: Windows

    // One overlay window per screen, rebuilt when displays are added/removed/rearranged.
    // Existing strokes on surviving screens are kept (windows are matched by frame).
    private func syncWindows() {
        let screens = NSScreen.screens
        var kept: [DrawOverlayWindow] = []
        for screen in screens {
            if let w = windows.first(where: { $0.frame == screen.frame }) {
                kept.append(w)
            } else {
                kept.append(DrawOverlayWindow(screenFrame: screen.frame))
            }
        }
        for old in windows where !kept.contains(where: { $0 === old }) {
            old.orderOut(nil)
        }
        windows = kept
        activeCanvas = nil
    }
}
