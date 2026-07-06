import AppKit
import WebKit

// A single native app window that hosts the app's web surfaces (served from the local
// DashboardServer) in TWO separate, persistent WKWebViews — no external browser. A segmented
// toggle in the title bar switches which one is visible:
//   .dashboard -> "/"           (활동 / 목표 / 세션 대시보드)
//   .bgm       -> "/bgm-player" (guaranteed-autoplay BGM surface, with the venue Web Audio effect)
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
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class AppWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    enum Mode: String { case dashboard, bgm }

    // Shared with the frame-restore logic in ensureBuilt() — kept as one source of truth so the
    // save call (windowWillClose/closeForQuit) and the restore call always agree on the name.
    private let windowAutosaveName = NSWindow.FrameAutosaveName("ConditionMateAppWindow")

    private var window: NSWindow?
    private var container: NSView?          // fills the content area; hosts whichever webview is visible
    private var bgmWebView: WKWebView?       // persistent — loaded once, never reloaded on mode switch
    private var dashboardWebView: WKWebView? // persistent — loaded once, never reloaded on mode switch
    private var segmented: NSSegmentedControl?
    private var dragView: TitlebarDragView?  // restores titlebar drag-to-move; see TitlebarDragView
    private var lastPort: UInt16 = 0
    private(set) var mode: Mode = .dashboard
    private var audioProbeTimer: Timer?   // periodic instrumentation while the window is open

    // Called when the window owns audio (open, in either mode) and when it hands it back on close,
    // so the app can keep native BGM muted the whole time the window is open (no double playback),
    // and unmute once it closes.
    var onOwnAudio: ((_ owns: Bool) -> Void)?
    // Called when the USER closes the window (not on app quit).
    var onUserClose: (() -> Void)?
    private var quitting = false   // set during app termination so a quit doesn't count as a user-close

    // Open + focus the window in a given mode (menu action).
    func show(port: UInt16, mode: Mode) {
        openInternal(port: port, mode: mode, activate: true)
    }

    // Auto-open on launch: bring the window on screen (so the WKWebView is not occluded and
    // therefore not throttled) without stealing key focus from the user's current app.
    func autoOpen(port: UInt16, mode: Mode) {
        AppLog.log("app-window autoOpen(port=\(port), mode=\(mode.rawValue))")
        openInternal(port: port, mode: mode, activate: false)
    }

    private func openInternal(port: UInt16, mode: Mode, activate: Bool) {
        ensureBuilt()
        lastPort = port
        loadIfNeeded(port: port)
        setMode(mode, forceApply: true)
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFrontRegardless()
        }
        startAudioProbeTimer()
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

    // Called from applicationWillTerminate: stop both webviews' audio and hide the window
    // explicitly, so nothing keeps playing during the brief window before the process actually dies.
    func closeForQuit() {
        quitting = true
        AppLog.log("app-window closeForQuit (isOpen=\(isOpen))")
        saveWindowFrame()
        stopAudioProbeTimer()
        onOwnAudio?(false)
        pauseWebAudio()
        bgmWebView?.loadHTMLString("", baseURL: nil)
        dashboardWebView?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // Test hook: close the window exactly as a user clicking the red close button would — via the
    // real NSWindow.close(), so windowWillClose fires the genuine user-close path (onUserClose ->
    // quit()), not a synthetic shortcut. Lets QA exercise Q1 ("closing the window quits the whole
    // app") headlessly.
    func testUserClose() {
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
        ) { result, _ in
            let probe = (result as? String) ?? "unavailable"
            AppLog.log("app-window audio-probe(\(context)) bgmWebView.audio=\(probe)")
        }
    }

    private func pauseWebAudio() {
        bgmWebView?.evaluateJavaScript("try{document.getElementById('audio').pause()}catch(e){}", completionHandler: nil)
    }

    // Push a SPECIFIC mute state into the BGM player (source of truth is Swift's session.isMuted).
    // Uses a named JS hook (window.__setMute) rather than clicking the button, so it sets the target
    // state directly (no drift if the two ever disagree) and never loops back to the server. The BGM
    // webview owns audio in both modes, so this controls what the user hears.
    func setWebMute(_ muted: Bool) {
        bgmWebView?.evaluateJavaScript("try{window.__setMute(\(muted))}catch(e){}", completionHandler: nil)
    }

    // QA-only: render whichever webview is asked for (regardless of which is currently the visible
    // subview) as a PNG, for SPEC.html's per-page screenshots. `tab` (only meaningful for mode=="bgm")
    // switches the in-page 액티비티/디버그 sub-tab via BGMPlayerContent.swift's own `setMode()` JS
    // function before snapshotting. Must run on main (WKWebView requirement); the caller (server
    // thread) blocks via a semaphore since HTTP responses here are synchronous.
    func snapshotPNG(mode: Mode, tab: String?, completion: @escaping (Data?) -> Void) {
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
        if mode == .bgm, let tab, tab == "activity" || tab == "debug" {
            // BGMPlayerContent.swift's own `setMode('activity'|'debug')` toggles the sub-tab; call
            // it directly rather than adding a QA-only hook.
            webView.evaluateJavaScript("try{setMode('\(tab)')}catch(e){}") { _, _ in
                // Give the sub-tab a beat to render before capturing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { snap() }
            }
        } else {
            snap()
        }
    }

    @objc private func onSegmentChanged(_ sender: NSSegmentedControl) {
        let newMode: Mode = (sender.selectedSegment == 1) ? .bgm : .dashboard
        setMode(newMode)
    }

    private var titleForMode: String { mode == .bgm ? "컨디션 관리" : "대시보드" }

    // Load each surface exactly once per port (e.g. on first open, or if the server restarted on
    // a new port). Switching modes afterward never calls this again — see setMode.
    private func loadIfNeeded(port: UInt16) {
        if let wv = bgmWebView, wv.url == nil || lastPort != port,
           let url = URL(string: "http://127.0.0.1:\(port)/bgm-player") {
            wv.load(URLRequest(url: url))
        }
        if let wv = dashboardWebView, wv.url == nil || lastPort != port,
           let url = URL(string: "http://127.0.0.1:\(port)/") {
            wv.load(URLRequest(url: url))
        }
        lastPort = port
    }

    // MARK: - Build

    private func ensureBuilt() {
        guard window == nil else { return }
        let bg = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.063, alpha: 1)

        func makeWebView() -> WKWebView {
            let cfg = WKWebViewConfiguration()
            cfg.mediaTypesRequiringUserActionForPlayback = []   // <- the guarantee: autoplay allowed
            let wv = WKWebView(frame: .zero, configuration: cfg)
            wv.navigationDelegate = self
            wv.uiDelegate = self   // without this, JS confirm()/alert()/prompt() resolve to their
                                   // default (confirm→false) and every confirm-guarded action
                                   // (e.g. "Complete sprint") silently no-ops.
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
        let seg = NSSegmentedControl(labels: ["대시보드", "컨디션"], trackingMode: .selectOne,
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

        let frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
        let contentContainer = NSView(frame: frame)
        container = contentContainer

        // .fullSizeContentView + a transparent titlebar let the dark web content extend up
        // under the traffic lights, so the top row reads as one continuous unified bar
        // (like a modern app) instead of leaving a wasted plain-title strip above the content.
        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "대시보드"
        win.backgroundColor = bg
        win.appearance = NSAppearance(named: .darkAqua)   // dark title bar + toggle to match the web UI
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentView = contentContainer
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
        AppLog.log("app-window ensureBuilt hadSavedFrame=\(hadSavedFrame) frame=\(NSStringFromRect(win.frame))")

        // The 대시보드/컨디션 segmented toggle is no longer shown in the titlebar — navigation is
        // unified elsewhere (the rail's condition popup "컨디션 전체 보기" switches to the BGM surface,
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
            AppLog.log("app-window installTitlebarDragView FAILED: no themeFrame")
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
        window.saveFrame(usingName: windowAutosaveName)
        // Force an immediate flush: the process may be killed (NSApp.terminate finishing, or the
        // OS reclaiming it) shortly after this call, before NSUserDefaults' normal write-behind
        // buffer would otherwise flush to disk on its own.
        UserDefaults.standard.synchronize()
        AppLog.log("app-window saveWindowFrame \(NSStringFromRect(window.frame))")
    }

    // Closing stops audio: blank both pages (a WKWebView keeps playing while alive otherwise).
    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        stopAudioProbeTimer()
        onOwnAudio?(false)
        pauseWebAudio()
        bgmWebView?.load(URLRequest(url: URL(string: "about:blank")!))
        dashboardWebView?.load(URLRequest(url: URL(string: "about:blank")!))
        if quitting {
            AppLog.log("app-window windowWillClose (during quit)")
        } else {
            AppLog.log("app-window windowWillClose (user, mode=\(mode.rawValue))")
            onUserClose?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.scheme == "http" {
            FileHandle.standardError.write("[app-window] loaded \(webView.url?.absoluteString ?? "")\n".data(using: .utf8)!)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("[app-window] load failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    }

    // MARK: - WKUIDelegate: JavaScript dialog panels
    // WebKit does NOT surface JS alert()/confirm()/prompt() unless the UI delegate implements
    // these. With no implementation the panels resolve to their defaults (confirm→false,
    // prompt→nil), which is why confirm-guarded actions in the dashboard did nothing.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
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

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
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

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
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
    func webView(_ webView: WKWebView,
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
