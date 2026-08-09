import AppKit
import WebKit

// A single native app window that hosts an app's web surfaces (served from a local HTTP
// server) in TWO separate, persistent WKWebViews — no external browser. The two surfaces:
//   .dashboard -> config.surfacePaths[.dashboard]  (활동 / 목표 / 세션 대시보드)
//   .bgm       -> config.surfacePaths[.bgm]        (guaranteed-autoplay BGM surface)
//
// REUSABLE (GUI module): this class has no dependency on the host app. App-specific behavior
// is injected — logging (`onLog`), lifecycle tracing (`onTrace`), the screen-catalog observer
// (`screenCatalog`), and the injected JS + paths/titles/geometry (`Configuration`). The host
// app wires these once at construction; every behavioral comment below still describes the
// Condition Manager usage that shaped the design.
//
// Autoplay is enabled (mediaTypesRequiringUserActionForPlayback = []) so BGM mode plays the
// activity BGM with the space effect the moment it opens — zero clicks.
//
// SEAMLESS SWITCHING: each surface gets its OWN WKWebView, created once and loaded once. Switching
// modes only changes which webview is on top / whether the (silent) dashboard webview is attached —
// it never navigates or reloads either page. This means the BGM page's <audio> element and Web
// Audio graph are never torn down when the user looks at the dashboard, so music keeps playing
// continuously underneath, with zero gap when the user switches back.
//
// The BGM webview stays ATTACHED to the container in BOTH modes (layered under the dashboard when
// the dashboard is shown), never parked off-view. This matters: a WKWebView with no superview
// cannot begin an <audio> network load — it stays pinned at NETWORK_NO_SOURCE/HAVE_NOTHING and
// never makes sound. An earlier version removed the hidden webview from the container, which was
// fine while .bgm was the default launch mode (the BGM webview was the visible one) but silently
// broke zero-click autoplay once .dashboard became the default: the BGM webview launched off-view
// and its <audio> never started loading (manager-qa FINDING 1, 2026-07-06). NOTE: an already-
// running AudioContext/<audio> does keep advancing while covered or even detached, but STARTING a
// media load requires the webview to be in the window's view hierarchy — so we keep it attached.
//
// Audio ownership follows the window's OPEN state, not the mode: while the window is open (in
// EITHER .dashboard or .bgm mode) it owns audio output, so native BGM stays muted the whole time —
// the persistent BGM webview is the single continuous audio source, and the dashboard view is
// purely visual (no sound of its own). Ownership is released only when the window closes (user
// close or quit). This fixes a double-audio bug: previously ownership followed the mode, so
// switching to .dashboard unmuted native while the BGM webview (still attached underneath and
// playing) kept going — two audible sources at once. This replaces the old browser-based dashboard
// entirely — everything is a native window now.
// Restores titlebar drag-to-move after `fullSizeContentView`: once the content view spans the
// full window (including under the titlebar), the WKWebViews underneath capture every mouse-down
// there, so the normal "grab the empty part of the titlebar to move the window" gesture goes dead
// across the whole top strip (WKWebView also does not honor CSS `-webkit-app-region:drag`, so this
// has to be solved on the AppKit side). This transparent view is pinned across the full width of
// the titlebar area, ABOVE the webview container, and excludes the traffic-light zone (left) and
// the segmented-control accessory (right) via `hitTest` so those still receive their own clicks —
// only the empty middle/top actually starts a window drag.
private final class TitlebarDragView: NSView {
    // Rects (in this view's own coordinate space) that must NOT drag the window — the traffic
    // lights and the segmented control both live in these zones and need their own clicks.
    var excludedRects: [NSRect] = []

    override var mouseDownCanMoveWindow: Bool { true }

    // NSView.hitTest(_:)'s point is in the SUPERVIEW's coordinate space, not self — excludedRects
    // are defined in self's own coordinate space, so convert before comparing. (Bug found via QA:
    // without this conversion, a real mouse click on the segmented control was being swallowed by
    // this drag view — AXPress on the control still worked since accessibility actions bypass
    // hit-testing entirely, which is what made the coordinate-click failure easy to miss at first.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview?.convert(point, to: self) ?? point
        for r in excludedRects where r.contains(local) { return nil }
        return super.hitTest(point)
    }

    // Drive the drag explicitly via NSWindow.performDrag(with:) rather than relying only on
    // mouseDownCanMoveWindow's implicit behavior — empirically (QA testing), a plain
    // mouseDownCanMoveWindow override on a view added directly to the theme frame did NOT
    // actually start a window drag (mouse-down was confirmed reaching this view via logging, but
    // no windowDidMove ever followed), so this explicitly performs the drag from mouseDown.
    //
    // A DOUBLE-click on the empty titlebar zooms the window (maximize ⇄ restore), matching the
    // standard macOS titlebar-double-click gesture. fullSizeContentView + this drag view sitting
    // above the webviews would otherwise swallow it (the system never sees a plain titlebar
    // double-click), so drive it here: clickCount == 2 → NSWindow.zoom(_:), which toggles between
    // the zoomed frame and the user's previous size. The excluded zones (traffic lights, segmented
    // control) are already filtered out in hitTest, so their own double-clicks are unaffected.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}

// Host-app-provided screen-catalog sink (컨디션 매니저의 ScreenCatalog가 구현). The window probes
// the visible webview for its screen-state key on a timer; `observe` registers the sighting and
// answers whether this state wants a (re)shot; `record` stores the captured PNG.
public protocol AppWindowScreenCatalogObserver: AnyObject {
    func observe(key: String, mode: String, page: String, view: String, flags: String,
                 w: Int, h: Int, entered: Bool) -> Bool
    func record(key: String, png: Data)
}

public final class AppWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
                                        WKScriptMessageHandler {
    public enum Mode: String { case dashboard, bgm }

    // Everything about this window that is host-app-specific: which local paths the two surfaces
    // load, window titles, injected JS, geometry, autosave identity. Defaults match Condition
    // Manager so its construction stays a one-liner; other apps override what they need.
    public struct Configuration {
        // Local-server path each surface loads (joined with the port passed to show/autoOpen).
        public var surfacePaths: [Mode: String] = [.dashboard: "/", .bgm: "/bgm-player"]
        // Window title per visible mode.
        public var titles: [Mode: String] = [.dashboard: "대시보드", .bgm: "컨디션 관리"]
        // Labels for the (currently hidden) mode segmented control; still sized for the
        // titlebar-drag exclusion zone, so keep them realistic.
        public var segmentLabels: [String] = ["대시보드", "컨디션"]
        // NSWindow frame autosave name (persists size/position across launches per bundle id).
        public var frameAutosaveName = "ConditionMateAppWindow"
        // Window/webview background (shown during load gaps).
        public var backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.063, alpha: 1)
        // Zen fold: the rail-only width the window narrows to when no challenge runs, and the
        // width it expands to when no saved frame is usable. The page announces reveal/narrow via
        // webkit.messageHandlers.<zenMessageName>.
        public var zenWidth: CGFloat = 242     // rail 240 + right border
        public var defaultExpandedWidth: CGFloat = 1040
        public var zenMessageName = "cmzen"
        // Smallest size the user can drag the window to — a post-it. The page's own 360px
        // breakpoint fires below this, so "shrink it all the way" lands on the memo pad alone.
        // Relaxed to zenWidth while zen-folded (242 < 340) and restored on expand.
        public var minContentSize = NSSize(width: 340, height: 420)
        public var initialContentSize = NSSize(width: 1040, height: 720)
        // JS source injected at documentStart into EVERY page both webviews load (e.g. the
        // 0.5s view-trace heartbeat). Empty = nothing injected.
        public var documentStartScripts: [String] = []
        // JS probe returning the visible page's screen-state JSON (see screenCatalogTick). nil
        // disables the screen-catalog loop even when an observer is attached.
        public var screenStateScript: String?
        // In-page sub-tabs snapshotPNG may switch to (via the page's own setMode(tab) JS)
        // before capturing.
        public var snapshotTabs: [String] = ["activity", "debug", "screens", "map", "actions", "diag", "syslog"]
        public init() {}
    }

    private let config: Configuration

    // Shared with the frame-restore logic in ensureBuilt() — kept as one source of truth so the
    // save call (windowWillClose/closeForQuit) and the restore call always agree on the name.
    private var windowAutosaveName: NSWindow.FrameAutosaveName { config.frameAutosaveName }

    private var window: NSWindow?
    private var container: NSView?          // fills the content area; hosts whichever webview is visible
    private var bgmWebView: WKWebView?       // persistent — loaded once, never reloaded on mode switch
    private var dashboardWebView: WKWebView? // persistent — loaded once, never reloaded on mode switch
    private var segmented: NSSegmentedControl?
    private var dragView: TitlebarDragView?  // restores titlebar drag-to-move; see TitlebarDragView
    private var lastPort: UInt16 = 0
    public private(set) var mode: Mode = .dashboard
    private var audioProbeTimer: Timer?   // periodic instrumentation while the window is open

    // Called when the window owns audio (open, in either mode) and when it hands it back on close,
    // so the app can keep native BGM muted the whole time the window is open (no double playback),
    // and unmute once it closes.
    public var onOwnAudio: ((_ owns: Bool) -> Void)?
    // Called when the USER closes the window (not on app quit).
    public var onUserClose: (() -> Void)?
    // Host-app logging sink (컨디션 매니저: AppLog). All messages arrive pre-prefixed "app-window …".
    public var onLog: ((String) -> Void)?
    // Host-app lifecycle-trace sink (컨디션 매니저: ViewTrace.native). (event, page, detail) —
    // empty strings mean "no value", matching ViewTrace's defaulted parameters.
    public var onTrace: ((_ event: String, _ page: String, _ detail: String) -> Void)?
    // Host-app screen-catalog sink; the capture loop only runs when this AND
    // config.screenStateScript are both present.
    public weak var screenCatalog: AppWindowScreenCatalogObserver?

    private var quitting = false   // set during app termination so a quit doesn't count as a user-close

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        super.init()
    }

    private func log(_ message: String) { onLog?(message) }
    private func trace(_ event: String, page: String = "", detail: String = "") {
        onTrace?(event, page, detail)
    }

    // ===== Zen (레일 폭 시작/휴식 창) =====
    // The window is at just the rail's width whenever no challenge is running: on the app
    // session's FIRST dashboard open (the user faces only the challenge dial, not a board full
    // of in-progress work — and not a big blank right half, which reads as "still loading"),
    // and AGAIN whenever the 음원/챌린지 stops (메모리를 걷어내는 효과 — ending a session folds
    // the board away so the next start is a clean slate). The page-side counterpart is
    // body.cm-zen (SessionRail): when the challenge actually starts, the page posts
    // webkit.messageHandlers.cmzen "reveal" → expandFromZen() animates the window back to its
    // real frame while the board fades in; a running→stopped transition posts "narrow" →
    // narrowFromPage() folds it back down. The user dragging the narrow window wider is an
    // explicit "show me the board" (windowDidResize → reveal, no fighting the drag). Window
    // close quits the app, so first-open-per-process == first-load-per-session.
    private var zenActive = false
    private var zenSavedFrame: NSRect?      // the real (pre-narrow) frame to expand back to
    private var zenProgrammaticResize = false  // our own narrow animation must not read as a user drag
    private var didFirstOpen = false
    private var zenWidth: CGFloat { config.zenWidth }

    // ===== 메모장 모드 창 (post-it fold) =====
    // 메모장만 보기(SessionRail 1단계)로 들어가면 창을 포스트잇으로 줄인다: 가로는 최소폭
    // (config.minContentSize.width), 세로는 유저가 메모장 모드에서 마지막으로 고른 높이.
    // 메모장 모드를 나가면 들어오기 직전 프레임(가로)으로 되돌린다. 페이지가
    // webkit.messageHandlers.cmzen 로 "memo" / "memoExit" 를 보내 구동한다.
    // zen(레일 폭 창)과는 따로 논다 — zen 이 켜져 있으면 메모 폴드는 건너뛴다.
    private var memoActive = false
    private var memoSavedFrame: NSRect?          // 메모장 모드 진입 직전 프레임(복귀 목표)
    private var memoProgrammaticResize = false   // 우리가 만든 리사이즈는 유저 드래그로 읽지 않는다
    private var memoWidth: CGFloat { config.minContentSize.width }
    // 유저가 메모장 모드에서 마지막으로 잡은 세로 크기. 앱을 다시 켜도 그 높이로 열리도록
    // UserDefaults 에 남긴다. 값이 없으면 진입 시점의 창 높이를 그대로 쓴다.
    private var memoSavedHeight: CGFloat? {
        get {
            let v = UserDefaults.standard.double(forKey: memoHeightKey)
            return v > 0 ? CGFloat(v) : nil
        }
        set { UserDefaults.standard.set(Double(newValue ?? 0), forKey: memoHeightKey) }
    }
    private var memoHeightKey: String { "\(config.frameAutosaveName).memoHeight" }

    // The user-draggable minimum, and the loosened one used while zen-folded (the 242pt fold
    // would otherwise be clamped by the 340pt post-it minimum).
    private func setContentMinWidth(_ w: CGFloat) {
        guard let win = window else { return }
        win.contentMinSize = NSSize(width: w, height: config.minContentSize.height)
    }

    // ===== 화면 카탈로그 (ScreenCatalog) =====
    // Every ~2s while the window is open+visible, probe the VISIBLE webview for its screen-state
    // key (page + view + UI flags) and hand it to the screenCatalog observer. A state must hold
    // across two consecutive ticks (settled — no mid-transition shots) before its screenshot is
    // taken.
    private var screenCatTimer: Timer?
    private var screenCatLastKey = ""       // previous tick's key (transition + settle detection)
    private var screenCatCapturing = false  // one in-flight snapshot at a time

    // Open + focus the window in a given mode (menu action).
    public func show(port: UInt16, mode: Mode) {
        openInternal(port: port, mode: mode, activate: true)
    }

    // TEMPORARY QA hook (Korean-IME investigation, 2026-07-12): headlessly navigate the
    // dashboard webview to an arbitrary in-app path, mirroring /api/debug/window-mode /
    // window-close. Lets an automated repro drive a specific page (e.g. /goal?n=NN&cli=1)
    // without simulating clicks through the SPA-ish nav. Only reachable once the window is
    // already open (does not open it itself). Remove alongside the other IME debug taps once
    // the fix is verified, or keep — it follows the same established test-only pattern.
    public func debugNavigate(path: String, port: UInt16) {
        guard let wv = dashboardWebView, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return }
        setMode(.dashboard, forceApply: false)
        if zenActive { expandFromZen() }
        wv.load(URLRequest(url: url))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(wv)
    }



    // Auto-open on launch: bring the window on screen (so the WKWebView is not occluded and
    // therefore not throttled) without stealing key focus from the user's current app.
    public func autoOpen(port: UInt16, mode: Mode) {
        log("app-window autoOpen(port=\(port), mode=\(mode.rawValue))")
        openInternal(port: port, mode: mode, activate: false)
    }

    private func openInternal(port: UInt16, mode: Mode, activate: Bool) {
        ensureBuilt()
        lastPort = port
        loadIfNeeded(port: port)
        setMode(mode, forceApply: true)
        // Zen start: narrow the window to the rail BEFORE it comes on screen, so the first frame
        // the user ever sees is already the compact start palette (never a full-size flash).
        let firstOpen = !didFirstOpen
        didFirstOpen = true
        if firstOpen && mode == .dashboard { applyZenNarrow() }
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFrontRegardless()
        }
        // The moment the window is actually on screen — everything the user sees before the
        // page's own firstPaint event is the blank/white gap being investigated.
        trace("windowOpen",
              detail: "mode=\(mode.rawValue) firstOpen=\(firstOpen) zen=\(zenActive) activate=\(activate)")
        startAudioProbeTimer()
        startScreenCatalogTimer()
    }

    // Periodic instrumentation (independent of mode switches): every few seconds while the window
    // is open, log native-mute-intent + the BGM webview's own <audio> state together so a log scan
    // can directly see "muted native + advancing web audio" held simultaneously, proving exactly one
    // audible source regardless of which mode is currently visible.
    private func startAudioProbeTimer() {
        guard audioProbeTimer == nil else { return }
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isOpen else { return }
            self.logAudioProbe(context: "periodic mode=\(self.mode.rawValue)")
        }
        RunLoop.main.add(t, forMode: .common)
        audioProbeTimer = t
    }

    private func stopAudioProbeTimer() {
        audioProbeTimer?.invalidate()
        audioProbeTimer = nil
    }

    // MARK: - 화면 카탈로그 capture loop (see the property block above; sink = screenCatalog)

    private func startScreenCatalogTimer() {
        guard screenCatTimer == nil, screenCatalog != nil, config.screenStateScript != nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.screenCatalogTick()
        }
        RunLoop.main.add(t, forMode: .common)
        screenCatTimer = t
    }

    private func stopScreenCatalogTimer() {
        screenCatTimer?.invalidate()
        screenCatTimer = nil
        screenCatLastKey = ""
    }

    // Probe the visible webview for its screen-state identity. Everything the key needs is
    // read in ONE evaluateJavaScript round-trip; the JS (config.screenStateScript) returns a
    // compact JSON string or null (non-http page / not ready). Query VALUES are dropped from
    // the key on purpose — /goal?n=12 and /goal?n=34 are the same SCREEN — and flags capture
    // the layout-changing UI states the path can't see (zen fold, 수확 오브, running dial,
    // open modal, collapsed rail).
    private func screenCatalogTick() {
        guard let catalog = screenCatalog, let probeScript = config.screenStateScript else { return }
        guard isOpen, window?.occlusionState.contains(.visible) == true else { return }
        let curMode = mode
        let wv: WKWebView? = (curMode == .bgm) ? bgmWebView : dashboardWebView
        guard let webView = wv, webView.url != nil else { return }
        webView.evaluateJavaScript(probeScript) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let path = s["p"] as? String else { return }
            let qKeys = (s["q"] as? String) ?? ""
            let page = path + (qKeys.isEmpty ? "" : "?" + qKeys)
            let view = (s["v"] as? String) ?? ""
            let flags = (s["f"] as? String) ?? ""
            let w = (s["w"] as? NSNumber)?.intValue ?? 0
            let h = (s["h"] as? NSNumber)?.intValue ?? 0
            let key = "\(curMode.rawValue)|\(page)|\(view)|\(flags)"

            let entered = key != self.screenCatLastKey
            let settled = !entered            // same state on two consecutive ticks
            let wantsShot = catalog.observe(
                key: key, mode: curMode.rawValue, page: page, view: view, flags: flags,
                w: w, h: h, entered: entered)
            self.screenCatLastKey = key
            guard wantsShot, settled, !self.screenCatCapturing,
                  self.isOpen, self.mode == curMode else { return }
            self.screenCatCapturing = true
            let cfg = WKSnapshotConfiguration()
            cfg.rect = webView.bounds
            // Downscale wide windows so a state's PNG stays ~a few hundred KB while text in
            // the shot remains readable for UX review.
            if webView.bounds.width > 1200 { cfg.snapshotWidth = 1200 }
            webView.takeSnapshot(with: cfg) { image, _ in
                defer { self.screenCatCapturing = false }
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                catalog.record(key: key, png: png)
            }
        }
    }

    // Ask both webviews to flush unsaved page state (메모장's debounced text, etc.) BEFORE the
    // process dies. Termination is the one path where the pad's own nets all fail at once:
    // pagehide never fires (closeForQuit blanks the page with loadHTMLString), the loopback
    // server dies with the process so a late keepalive fetch has nowhere to land, and the
    // localStorage draft is stranded because the next launch binds a new port = new origin.
    // (2026-08-06: an update-relaunch ate the last minute of memo typing exactly this way.)
    //
    // Call BEFORE DashboardServer.stop() — the flush POST must still find a live server.
    // Completion fires exactly once, on main, after the pages had time to fire their saves
    // (the pad's debounce is 400ms; the wait covers debounce + loopback round-trip) or after
    // the backstop timeout if a webview never answers.
    public func drainForQuit(completion: @escaping () -> Void) {
        var done = false
        let finish = {
            if Thread.isMainThread { if !done { done = true; completion() } }
            else { DispatchQueue.main.async { if !done { done = true; completion() } } }
        }
        let views = [bgmWebView, dashboardWebView].compactMap { $0 }.filter { $0.url != nil }
        guard !views.isEmpty else { finish(); return }
        log("app-window drainForQuit — flushing \(views.count) webview(s)")
        let group = DispatchGroup()
        for wv in views {
            group.enter()
            wv.evaluateJavaScript("window.CMMemo && CMMemo.flush ? (CMMemo.flush(), 1) : 0") { _, _ in
                group.leave()
            }
        }
        // flush() may only START a save here (a keystroke <400ms old sits in the debounce, an
        // in-flight save defers to its completion) — give the follow-up POST time to land.
        group.notify(queue: .main) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: finish) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: finish)   // absolute backstop
    }

    // Called from applicationWillTerminate: stop both webviews' audio and hide the window
    // explicitly, so nothing keeps playing during the brief window before the process actually dies.
    public func closeForQuit() {
        quitting = true
        log("app-window closeForQuit (isOpen=\(isOpen))")
        saveWindowFrame()
        stopAudioProbeTimer()
        stopScreenCatalogTimer()
        onOwnAudio?(false)
        pauseWebAudio()
        bgmWebView?.loadHTMLString("", baseURL: nil)
        dashboardWebView?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
    }

    public var isOpen: Bool { window?.isVisible ?? false }

    // Test hook: close the window exactly as a user clicking the red close button would — via the
    // real NSWindow.close(), so windowWillClose fires the genuine user-close path (onUserClose ->
    // quit()), not a synthetic shortcut. Lets QA exercise Q1 ("closing the window quits the whole
    // app") headlessly.
    public func testUserClose() {
        window?.close()
    }

    // MARK: - Mode / audio

    // Swap which webview the user sees. The crux of the seamless-audio fix: neither webview is
    // loaded/reloaded here.
    //
    // The BGM webview stays ATTACHED to the container in EVERY mode — including while the dashboard
    // is the visible mode — layered UNDERNEATH the (opaque) dashboard webview. This is required for
    // zero-click autoplay-on-launch: a WKWebView with no superview cannot begin an <audio> network
    // load (it stays pinned at NETWORK_NO_SOURCE/HAVE_NOTHING and never produces sound), so parking
    // the BGM webview off-view — as the old "remove the hidden one" logic did — silently broke music
    // once .dashboard became the default landing mode (manager-qa FINDING 1, 2026-07-06). Being in
    // the window's view hierarchy, even fully covered by the dashboard on top, is enough for its
    // <audio> to load and play. The dashboard webview, by contrast, has no audio, so it is the one we
    // detach when not shown.
    private func setMode(_ newMode: Mode, forceApply: Bool = false) {
        guard forceApply || newMode != mode else { return }
        if newMode != mode { trace("modeSwitch", detail: "\(mode.rawValue) -> \(newMode.rawValue)") }
        mode = newMode
        segmented?.selectedSegment = (mode == .dashboard) ? 0 : 1
        window?.title = titleForMode

        guard let container = container, let bgmWV = bgmWebView, let dashWV = dashboardWebView else { return }
        func attach(_ wv: WKWebView) {
            if wv.superview !== container {
                wv.frame = container.bounds
                wv.autoresizingMask = [.width, .height]
                container.addSubview(wv)   // if already a subview, this just moves it to the front
            }
        }
        // BGM webview: always present (bottom layer) so its <audio> can load/play in any mode.
        attach(bgmWV)
        if mode == .bgm {
            // Showing BGM: the dashboard must not cover it — detach the (silent) dashboard webview.
            if dashWV.superview != nil { dashWV.removeFromSuperview() }
        } else {
            // Showing dashboard: keep BGM attached underneath, dashboard on top (opaque, covers it).
            attach(dashWV)
            container.addSubview(dashWV)    // bring the dashboard to the front, over the BGM webview
        }
        applyAudioOwnership()
    }

    private func applyAudioOwnership() {
        // The window owns audio in BOTH modes while open: the BGM webview keeps playing regardless
        // of which mode is visible (see file header), so native must stay muted the entire time the
        // window is open, not just while .bgm is the visible mode — otherwise switching to
        // .dashboard would unmute native while the BGM webview kept playing underneath (double
        // audio). This purely toggles which source the user HEARS (native mute) — it never
        // starts/stops the web page's own playback.
        onOwnAudio?(true)
        logAudioProbe(context: "mode=\(mode.rawValue)")
    }

    // Debug instrumentation: prove native-mute and web-audio-advancing happen SIMULTANEOUSLY.
    // Reads the dedicated BGM webview's own <audio> element (paused/currentTime) via JS — this is
    // the persistent audio source that must keep advancing in both modes while native stays muted.
    // netState/readyState were added by manager-qa (2026-07-06) to diagnose "음원 시작이 안되는데":
    // they distinguish "never started loading" (netState=NETWORK_NO_SOURCE/3, readyState=
    // HAVE_NOTHING/0 — confirmed root cause: the <audio> element cannot begin a network load while
    // its hosting WKWebView has no superview, i.e. is parked off-view in .dashboard mode) from a
    // genuinely playing element (netState=NETWORK_IDLE/1, readyState=HAVE_ENOUGH_DATA/4). Keep this
    // richer probe permanently — it is the only way to tell "paused:false but not actually loading"
    // apart from "actually playing" from the log alone.
    private func logAudioProbe(context: String) {
        bgmWebView?.evaluateJavaScript(
            "(function(){var a=document.getElementById('audio'); if(!a) return null; " +
            "return JSON.stringify({paused:a.paused, currentTime:a.currentTime, " +
            "err:(a.error?a.error.code:null), netState:a.networkState, readyState:a.readyState, " +
            "src:a.src, mode:(typeof mode!=='undefined'?mode:null), " +
            "lastNow:(typeof lastNow!=='undefined'?lastNow:null), " +
            "engaged:(typeof engaged!=='undefined'?engaged:null), " +
            "curTrack:(typeof curTrack!=='undefined'?curTrack:null)});})()"
        ) { [weak self] result, _ in
            let probe = (result as? String) ?? "unavailable"
            self?.log("app-window audio-probe(\(context)) bgmWebView.audio=\(probe)")
        }
    }

    private func pauseWebAudio() {
        bgmWebView?.evaluateJavaScript("try{document.getElementById('audio').pause()}catch(e){}", completionHandler: nil)
    }

    // Push a SPECIFIC mute state into the BGM player (source of truth is Swift's session.isMuted).
    // Uses a named JS hook (window.__setMute) rather than clicking the button, so it sets the target
    // state directly (no drift if the two ever disagree) and never loops back to the server. The BGM
    // webview owns audio in both modes, so this controls what the user hears.
    public func setWebMute(_ muted: Bool) {
        bgmWebView?.evaluateJavaScript("try{window.__setMute(\(muted))}catch(e){}", completionHandler: nil)
    }

    // Keyboard route to the rail's sidebar button (⌃⌘N): run the page's OWN 3-stage cycle
    // (cmRailToggle) rather than reimplementing it here, so the shortcut and the click can never
    // drift apart. Dashboard webview only — the rail lives there; cycling it while the BGM view is
    // showing would look like nothing happened and then surprise the user on the next visit.
    // Returns false when there's nothing to toggle, so the caller can let the key fall through.
    @discardableResult
    public func cycleRailStage() -> Bool {
        guard isOpen, mode == .dashboard, let wv = dashboardWebView, wv.url != nil else { return false }
        wv.evaluateJavaScript("try{window.cmRailToggle&&cmRailToggle()}catch(e){}", completionHandler: nil)
        return true
    }

    // QA-only: render whichever webview is asked for (regardless of which is currently the visible
    // subview) as a PNG, for SPEC.html's per-page screenshots. `tab` (only meaningful for mode=="bgm")
    // switches the in-page 액티비티/디버그 sub-tab via the page's own `setMode()` JS function
    // before snapshotting (see config.snapshotTabs). Must run on main (WKWebView requirement); the
    // caller (server thread) blocks via a semaphore since HTTP responses here are synchronous.
    public func snapshotPNG(mode: Mode, tab: String?, completion: @escaping (Data?) -> Void) {
        guard isOpen else { completion(nil); return }
        let wv: WKWebView? = (mode == .bgm) ? bgmWebView : dashboardWebView
        guard let webView = wv, webView.url != nil else { completion(nil); return }

        func snap() {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = webView.bounds
            webView.takeSnapshot(with: cfg) { image, _ in
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    completion(nil); return
                }
                completion(png)
            }
        }
        if mode == .bgm, let tab, config.snapshotTabs.contains(tab) {
            // The page's own `setMode(tab)` toggles the sub-tab; call it directly rather than
            // adding a QA-only hook.
            webView.evaluateJavaScript("try{setMode('\(tab)')}catch(e){}") { _, _ in
                // Give the sub-tab a beat to render before capturing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { snap() }
            }
        } else {
            snap()
        }
    }

    // MARK: - Zen start (narrow first-open window; see the property block above)

    private func applyZenNarrow() {
        guard let win = window else { return }
        zenSavedFrame = win.frame
        zenActive = true
        // Detach frame autosave while narrow: AppKit auto-saves on every frame change, and the
        // 242pt zen frame must never overwrite the user's real saved window size.
        win.setFrameAutosaveName("")
        setContentMinWidth(zenWidth)   // 242 < the 340 post-it minimum; let the fold through
        var f = win.frame
        f.size.width = zenWidth
        win.setFrame(f, display: true)
        log("app-window zen narrow (full frame saved: \(NSStringFromRect(zenSavedFrame ?? .zero)))")
        trace("zenNarrow")
    }

    // The page announced the board reveal (challenge started / 둘러보기) → grow the window back.
    private func expandFromZen() {
        guard zenActive, let win = window else { return }
        zenActive = false
        var target = zenSavedFrame ?? win.frame
        if target.width < 400 { target.size.width = config.defaultExpandedWidth }   // never "expand" into another sliver
        setContentMinWidth(config.minContentSize.width)   // back to the post-it floor
        win.setFrame(target, display: true, animate: true)
        win.setFrameAutosaveName(windowAutosaveName)
        log("app-window zen expand -> \(NSStringFromRect(target))")
        trace("zenExpand")
    }

    // The page re-entered zen (음원/챌린지 stopped on the dashboard) → fold the window back down
    // to the rail. Captures the CURRENT frame as the next expand target, so restarting brings
    // back exactly the size the user was working at. Ignored while the BGM surface is the
    // visible mode — that page owns the window then (the page-side visibility guard should
    // already prevent this, but the window must defend itself too).
    private func narrowFromPage() {
        guard !zenActive, mode == .dashboard, let win = window, win.isVisible else { return }
        zenSavedFrame = win.frame
        zenActive = true
        win.setFrameAutosaveName("")   // the narrow frame must never overwrite the real saved one
        setContentMinWidth(zenWidth)
        var f = win.frame
        f.size.width = zenWidth
        // Animated fold, with windowDidResize told this is OUR resize: the shrink passes through
        // widths > 320 which would otherwise read as a user drag and instantly un-zen.
        zenProgrammaticResize = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            win.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in self?.zenProgrammaticResize = false })
        log("app-window zen re-narrow (full frame saved: \(NSStringFromRect(zenSavedFrame ?? .zero)))")
        trace("zenNarrow", detail: "session stopped")
    }

    // MARK: - 메모장 모드 창 (see the property block above)

    // 페이지가 메모장만 보기(1단계)로 들어갔다 → 포스트잇 창으로 접는다. 가로는 최소폭,
    // 세로는 유저가 메모장 모드에서 마지막으로 고른 높이(없으면 지금 높이 유지). 위쪽 모서리는
    // 그대로 두고 화면 오른쪽 끝에 딱 붙인다. zen 이 켜져 있으면 그쪽이 창을 소유하므로
    // 아무것도 하지 않는다.
    private func enterMemoFold() {
        guard !memoActive, !zenActive, mode == .dashboard, let win = window, win.isVisible else { return }
        memoSavedFrame = win.frame
        memoActive = true
        win.setFrameAutosaveName("")   // 포스트잇 프레임이 진짜 창 크기를 덮어쓰면 안 된다
        var f = win.frame
        let top = f.maxY
        f.size.width = memoWidth
        if let h = memoSavedHeight { f.size.height = h }
        f.origin.y = top - f.size.height
        // 포스트잇은 화면 오른쪽 끝에 딱 붙인다 (위쪽 모서리는 그대로 유지).
        if let vis = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            f.origin.x = vis.maxX - f.size.width
        }
        memoProgrammaticResize = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            win.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in self?.memoProgrammaticResize = false })
        log("app-window memo fold -> \(NSStringFromRect(f)) (saved: \(NSStringFromRect(memoSavedFrame ?? .zero)))")
        trace("memoFold")
    }

    // 메모장 모드를 나갔다 → 들어오기 직전 가로로 되돌린다. 세로는 지금 값(메모장에서 유저가
    // 잡은 높이)을 그대로 두면 창이 두 축으로 동시에 튀므로, 저장된 프레임의 세로도 함께 복원한다.
    //
    // 우리가 접지 않았어도(memoActive=false) 창이 포스트잇 폭에 머물러 있으면 넓혀 준다. 유저가
    // 손으로 창을 좁혀 메모장이 강제된 경우가 그렇다 — 그 상태에서 2·3단계로 나가면 레일 + 보드가
    // 340pt 안에 우겨넣어져 화면이 깨진다. 다른 단계는 넓은 창을 전제로 한 레이아웃이므로,
    // 나가는 순간 쓸 만한 폭으로 되돌리는 것이 옳다. 이미 충분히 넓으면 손대지 않는다.
    // stage: 나가서 가려는 단계(2 = 메모 + 컴포저, 3 = 작업 + 대화 분할, 0 = 레일 접힘). 단계마다
    // 성립하는 최소 폭이 달라서(3단계 분할이 가장 넓다) 그만큼은 보장해 준다.
    private func exitMemoFold(stage: Int) {
        guard let win = window, !zenActive else { return }
        // 3단계(작업 + 대화 분할)는 화면 전체를 쓴다 — 보드와 대화를 좌우로 나누는 화면이라
        // 어중간한 폭에서는 두 판이 모두 좁아진다. 그래서 최소 폭을 맞추는 대신 창을 그 화면의
        // 사용 가능 영역(메뉴바·Dock 제외) 전체로 편다. 다른 단계는 종전대로 최소 폭만 보장한다.
        if stage == 3, let vis = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            memoActive = false
            memoSavedFrame = nil
            guard win.frame != vis else { return }
            memoProgrammaticResize = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                win.animator().setFrame(vis, display: true)
            }, completionHandler: { [weak self] in
                self?.memoProgrammaticResize = false
                self?.window?.setFrameAutosaveName(self?.windowAutosaveName ?? "")
            })
            log("app-window stage3 fullscreen -> \(NSStringFromRect(vis))")
            trace("memoUnfold", detail: "stage3 full")
            return
        }
        let usableWidth: CGFloat = 720
        guard memoActive || win.frame.width < usableWidth else { return }
        memoActive = false
        var target = memoSavedFrame ?? win.frame
        if target.width < usableWidth {
            // 되돌릴 만한 프레임이 없다(또는 그것도 좁다) → 이 단계가 필요로 하는 폭. 세로는 지금
            // 유저가 보고 있는 높이를 유지해 한 축만 움직인다.
            target = win.frame
            target.size.width = usableWidth
        }
        // 넓히다가 화면 밖으로 나가지 않게 물린다 — 좁은 창은 보통 화면 오른쪽 끝에 붙어 있다.
        if let vis = win.screen?.visibleFrame {
            target.size.width = min(target.width, vis.width)
            target.origin.x = min(max(target.minX, vis.minX), vis.maxX - target.width)
        }
        memoSavedFrame = nil
        memoProgrammaticResize = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            win.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.memoProgrammaticResize = false
            self?.window?.setFrameAutosaveName(self?.windowAutosaveName ?? "")
        })
        log("app-window memo unfold -> \(NSStringFromRect(target))")
        trace("memoUnfold")
    }

    // While zen-narrow, the user dragging the window wider means "show me the board without
    // starting": exit zen, reveal the page's hidden board, and let the drag own the frame
    // (no programmatic resize fighting the user's hand).
    public func windowDidResize(_ notification: Notification) {
        // 메모장 모드에서 유저가 세로를 잡으면 그 높이를 기억해 다음 진입에 쓴다. 가로를 최소폭
        // 위로 크게 끌면 "메모장이지만 넓게 보겠다"는 뜻이므로 폴드 상태에서 빠져나온다 —
        // 그래야 나중에 모드를 나갈 때 창을 유저 손에서 다시 뺏지 않는다.
        if memoActive, !memoProgrammaticResize, let win = window {
            memoSavedHeight = win.frame.height
            if win.frame.width > memoWidth + 80 {
                memoActive = false
                win.setFrameAutosaveName(windowAutosaveName)
                log("app-window memo fold exit via user resize \(NSStringFromRect(win.frame))")
            }
        }
        guard zenActive, !zenProgrammaticResize, let win = window, win.frame.width > 320 else { return }
        zenActive = false
        win.setFrameAutosaveName(windowAutosaveName)
        // Restore the post-it floor only once the drag has cleared it — snapping the minimum
        // back to 340 mid-drag would yank the window out from under the user's hand.
        if win.frame.width >= config.minContentSize.width { setContentMinWidth(config.minContentSize.width) }
        dashboardWebView?.evaluateJavaScript("try{window.cmZenReveal&&cmZenReveal()}catch(e){}",
                                             completionHandler: nil)
        log("app-window zen exit via user resize \(NSStringFromRect(win.frame))")
        trace("zenExpand", detail: "user resize")
    }

    // JS → native: SessionRail posts "reveal" when the board becomes visible (challenge started /
    // 둘러보기) and "narrow" when a stop folds the board away again. 같은 채널로 메모장 모드
    // 진입/이탈("memo" / "memoExit")도 온다 — 포스트잇 창 접기(enterMemoFold/exitMemoFold).
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard message.name == config.zenMessageName else { return }
        let cmd = (message.body as? String) ?? "reveal"
        DispatchQueue.main.async { [weak self] in
            if cmd == "narrow" { self?.narrowFromPage() }
            else if cmd == "memo" { self?.enterMemoFold() }
            else if cmd.hasPrefix("memoExit") {
                // "memoExit:<stage>" — 단계 번호는 그 단계가 필요로 하는 최소 폭을 고른다.
                let stage = Int(cmd.split(separator: ":").last.map(String.init) ?? "") ?? 3
                self?.exitMemoFold(stage: stage)
            }
            else { self?.expandFromZen() }
        }
    }

    @objc private func onSegmentChanged(_ sender: NSSegmentedControl) {
        let newMode: Mode = (sender.selectedSegment == 1) ? .bgm : .dashboard
        setMode(newMode)
    }

    private var titleForMode: String {
        config.titles[mode] ?? config.titles[.dashboard] ?? ""
    }

    // Load each surface exactly once per port (e.g. on first open, or if the server restarted on
    // a new port). Switching modes afterward never calls this again — see setMode.
    private func loadIfNeeded(port: UInt16) {
        if let wv = bgmWebView, wv.url == nil || lastPort != port,
           let path = config.surfacePaths[.bgm],
           let url = URL(string: "http://127.0.0.1:\(port)\(path)") {
            trace("loadStart", page: path)
            wv.load(URLRequest(url: url))
        }
        if let wv = dashboardWebView, wv.url == nil || lastPort != port,
           let path = config.surfacePaths[.dashboard],
           let url = URL(string: "http://127.0.0.1:\(port)\(path)") {
            trace("loadStart", page: path)
            wv.load(URLRequest(url: url))
        }
        lastPort = port
    }

    // MARK: - Build

    private func ensureBuilt() {
        guard window == nil else { return }
        let bg = config.backgroundColor

        func makeWebView() -> WKWebView {
            let cfg = WKWebViewConfiguration()
            cfg.mediaTypesRequiringUserActionForPlayback = []   // <- the guarantee: autoplay allowed
            cfg.userContentController.add(self, name: config.zenMessageName)  // zen-start reveal channel (JS → native)
            // Host-app scripts injected at documentStart into EVERY page these webviews load
            // (컨디션 매니저: the 0.5s view-trace heartbeat), so route changes (/goal-add,
            // /equipment, …) are covered without touching each page's HTML.
            for source in config.documentStartScripts {
                cfg.userContentController.addUserScript(WKUserScript(
                    source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            let wv = WKWebView(frame: .zero, configuration: cfg)
            wv.navigationDelegate = self
            wv.uiDelegate = self   // without this, JS confirm()/alert()/prompt() resolve to their
                                   // default (confirm→false) and every confirm-guarded action
                                   // (e.g. "Complete loop") silently no-ops.
            if #available(macOS 12.0, *) { wv.underPageBackgroundColor = bg }
            return wv
        }
        let bgmWV = makeWebView()
        let dashWV = makeWebView()
        bgmWebView = bgmWV
        dashboardWebView = dashWV

        // Native mode toggle, now hosted INLINE in the titlebar row itself (a right-aligned
        // titlebar accessory, next to the traffic lights) instead of a separate strip below the
        // title bar — this is what makes the top read as one continuous unified bar (item 2),
        // matching the reference where toolbar controls share the very top row.
        let seg = NSSegmentedControl(labels: config.segmentLabels, trackingMode: .selectOne,
                                     target: self, action: #selector(onSegmentChanged(_:)))
        seg.segmentStyle = .texturedRounded
        seg.controlSize = .small
        seg.selectedSegment = 0
        segmented = seg
        // Force the control to its natural fitting size NOW (in a real frame, not just via
        // constraints) — a `.right` NSTitlebarAccessoryViewController sizes its accessory view
        // from its frame at attach time, and a view built purely with Auto Layout constraints
        // (translatesAutoresizingMaskIntoConstraints=false, no fixed frame) can collapse to a
        // near-zero width there, which silently breaks hit-testing (clicks land outside the
        // segments) even though it may still render visually.
        seg.sizeToFit()

        // No opaque background here (leave it transparent) so it blends seamlessly with the
        // transparent/dark titlebar behind it instead of showing a visible seam or box.
        let barSize = NSSize(width: seg.frame.width + 12, height: 22)
        let bar = NSView(frame: NSRect(origin: .zero, size: barSize))
        seg.frame.origin = NSPoint(x: (barSize.width - seg.frame.width) / 2,
                                    y: (barSize.height - seg.frame.height) / 2)
        seg.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        bar.addSubview(seg)

        let frame = NSRect(origin: .zero, size: config.initialContentSize)
        let contentContainer = NSView(frame: frame)
        container = contentContainer

        // .fullSizeContentView + a transparent titlebar let the dark web content extend up
        // under the traffic lights, so the top row reads as one continuous unified bar
        // (like a modern app) instead of leaving a wasted plain-title strip above the content.
        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = config.titles[.dashboard] ?? ""
        win.backgroundColor = bg
        win.appearance = NSAppearance(named: .darkAqua)   // dark title bar + toggle to match the web UI
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentView = contentContainer
        win.contentMinSize = config.minContentSize
        win.isReleasedWhenClosed = false
        win.delegate = self

        // Persist + restore window frame across close/reopen AND across rebuilds of the same
        // bundle id (AppKit stores the autosave frame in UserDefaults keyed by name + bundle id).
        // Only center() on the very first-ever launch (no saved frame yet) — otherwise center()
        // would stomp the restored frame every time the window is (re)built.
        let hadSavedFrame = win.setFrameUsingName(windowAutosaveName)
        win.setFrameAutosaveName(windowAutosaveName)
        if !hadSavedFrame {
            win.center()
        }
        log("app-window ensureBuilt hadSavedFrame=\(hadSavedFrame) frame=\(NSStringFromRect(win.frame))")

        // The 대시보드/컨디션 segmented toggle is no longer shown in the titlebar — navigation is
        // unified elsewhere (the rail's condition popup "시스템관리" switches to the BGM surface,
        // and that page's "← 대시보드" button switches back). The mode-switch MECHANISM (setMode,
        // driven by openDashboard/openBGMWindow) is unchanged; only its titlebar control is removed.
        // `segmented` stays wired so setMode's selectedSegment update remains a harmless no-op.

        window = win
        installTitlebarDragView(on: win, segmentedBar: bar)
    }

    // See TitlebarDragView: restores "grab the empty top strip to move the window" after
    // fullSizeContentView made the WKWebView content capture that area's mouse-down events.
    // Hosted on the window's theme frame (contentView's superview — the real full-window view
    // that exists above contentView in fullSizeContentView mode) so it sits above the webviews;
    // pinned to the titlebar's height and full width, with the traffic-light zone and the
    // segmented-control accessory's own frame excluded so their clicks still reach them.
    private func installTitlebarDragView(on win: NSWindow, segmentedBar: NSView) {
        guard let themeFrame = win.contentView?.superview else {
            log("app-window installTitlebarDragView FAILED: no themeFrame")
            return
        }
        let titlebarHeight = win.frame.height - (win.contentView?.frame.height ?? win.frame.height)
        let height = max(titlebarHeight, 28)
        let drag = TitlebarDragView(frame: NSRect(x: 0, y: themeFrame.bounds.height - height,
                                                   width: themeFrame.bounds.width, height: height))
        drag.autoresizingMask = [.width, .minYMargin]
        // The left of the titlebar now holds, left-to-right: the native traffic lights (~78pt)
        // and then the rail's own web header controls (sidebar-toggle + session-search icons,
        // rendered inside the WKWebview at ~x84–150). None of that strip may start a window drag —
        // excluding it lets clicks fall through to the native buttons (close/minimize/zoom) AND to
        // the webview's header buttons underneath. Without this the drag view swallows the toggle/
        // search clicks (they sit in a non-excluded zone) and can interfere near the lights.
        let railHeaderZoneWidth: CGFloat = 160
        // The segmented control's own frame in screen/theme-frame coordinates — recomputed
        // lazily via a closure isn't possible on a stored rect, so approximate with the bar's
        // width (already sized via sizeToFit in ensureBuilt) anchored to the right edge, matching
        // its `.right` titlebar-accessory placement.
        let segZoneWidth = segmentedBar.frame.width + 16
        drag.excludedRects = [
            NSRect(x: 0, y: 0, width: railHeaderZoneWidth, height: height),
            NSRect(x: drag.frame.width - segZoneWidth, y: 0, width: segZoneWidth, height: height),
        ]
        themeFrame.addSubview(drag)
        dragView = drag
    }

    // Explicitly persist the current frame to the autosave name at every close point (user-close
    // AND quit), rather than relying solely on setFrameAutosaveName's own automatic save-on-resize
    // — this guarantees the frame in effect right before teardown is exactly what gets restored
    // next time, even in the narrow window where the process could be torn down (NSApp.terminate)
    // shortly after a resize/move, before AppKit's own autosave write-behind would otherwise fire.
    private func saveWindowFrame() {
        guard let window else { return }
        // Quitting while still zen-narrow must persist the REAL frame, not the 242pt sliver —
        // otherwise the next launch would restore (and zen-save) an already-narrow window.
        if zenActive, let f = zenSavedFrame { window.setFrame(f, display: false) }
        // 같은 이유로 메모장 포스트잇 상태에서 끝나도 진짜 프레임을 남긴다. 다만 메모장에서
        // 유저가 잡은 세로는 다음 진입을 위해 그대로 보관한다(memoSavedHeight).
        else if memoActive, let f = memoSavedFrame {
            memoSavedHeight = window.frame.height
            window.setFrame(f, display: false)
        }
        window.saveFrame(usingName: windowAutosaveName)
        // Force an immediate flush: the process may be killed (NSApp.terminate finishing, or the
        // OS reclaiming it) shortly after this call, before NSUserDefaults' normal write-behind
        // buffer would otherwise flush to disk on its own.
        UserDefaults.standard.synchronize()
        log("app-window saveWindowFrame \(NSStringFromRect(window.frame))")
    }

    // Screen-visibility changes the page cannot see (document.hidden stays false while the
    // window is merely covered by another app's window): macOS occlusion is ALSO when WebKit
    // throttles timers, so heartbeat gaps in the trace line up with these events.
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let win = window else { return }
        let visible = win.occlusionState.contains(.visible)
        trace("occlusion", detail: visible ? "visible" : "occluded")
    }

    // Closing stops audio: blank both pages (a WKWebView keeps playing while alive otherwise).
    public func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        stopAudioProbeTimer()
        stopScreenCatalogTimer()
        onOwnAudio?(false)
        pauseWebAudio()
        bgmWebView?.load(URLRequest(url: URL(string: "about:blank")!))
        dashboardWebView?.load(URLRequest(url: URL(string: "about:blank")!))
        trace("windowClose", detail: quitting ? "quit" : "user mode=\(mode.rawValue)")
        if quitting {
            log("app-window windowWillClose (during quit)")
        } else {
            log("app-window windowWillClose (user, mode=\(mode.rawValue))")
            onUserClose?()
        }
    }

    // View-trace path label for a webview's current URL ("/", "/bgm-player", "/goal-add?…").
    private func tracePath(_ webView: WKWebView) -> String {
        guard let url = webView.url, url.scheme == "http" else { return "" }
        return url.path + (url.query.map { "?\($0)" } ?? "")
    }

    // The three WebKit render milestones bracket the blank gap: didStartProvisionalNavigation
    // (request went out) → didCommit (first bytes accepted — the OLD content is gone and the
    // window shows the webview's background until the new page paints) → didFinish (load done).
    // Together with the injected heartbeat's boot/firstPaint these make "흰 화면 3초" a
    // measurable interval instead of a screenshot.
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let p = tracePath(webView)
        if !p.isEmpty { trace("navStart", page: p) }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let p = tracePath(webView)
        if !p.isEmpty { trace("navCommit", page: p) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.scheme == "http" {
            FileHandle.standardError.write("[app-window] loaded \(webView.url?.absoluteString ?? "")\n".data(using: .utf8)!)
            trace("navFinish", page: tracePath(webView))
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("[app-window] load failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        trace("navFail", page: tracePath(webView), detail: error.localizedDescription)
    }

    // MARK: - WKUIDelegate: JavaScript dialog panels
    // WebKit does NOT surface JS alert()/confirm()/prompt() unless the UI delegate implements
    // these. With no implementation the panels resolve to their defaults (confirm→false,
    // prompt→nil), which is why confirm-guarded actions in the dashboard did nothing.

    // WebKit also drops target="_blank" links and window.open() unless the UI delegate handles
    // the new-window request — clicking 전체 로그 타임라인(/worker-log) on the 크론 page, or the
    // dashboard's transcript/breakdown viewers, silently did nothing. This app has a single
    // webview window, so hand the URL to the default browser instead of spawning a webview.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Logged because a silent window.open is invisible to the user AND to app.log —
        // the 플랜 맵 button's "click did nothing" report was undiagnosable without this.
        log("app-window window.open \(navigationAction.request.url?.absoluteString ?? "nil")")
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "확인")
        if let win = webView.window {
            alert.beginSheetModal(for: win) { _ in completionHandler() }
        } else {
            alert.runModal(); completionHandler()
        }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        if let win = webView.window {
            alert.beginSheetModal(for: win) { resp in completionHandler(resp == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        let complete: (NSApplication.ModalResponse) -> Void = { resp in
            completionHandler(resp == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if let win = webView.window {
            alert.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }

    // WebKit does NOT show the file picker for <input type="file"> unless the UI delegate
    // implements this. With no implementation, clicking "파일 첨부" in the goal page silently
    // did nothing (the goal's addFiles() never received any files). Present a native open panel
    // and hand the chosen URLs back so FileReader can read + upload them.
    public func webView(_ webView: WKWebView,
                        runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let complete: (NSApplication.ModalResponse) -> Void = { resp in
            completionHandler(resp == .OK ? panel.urls : nil)
        }
        if let win = webView.window {
            panel.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }
}
