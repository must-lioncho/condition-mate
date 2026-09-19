import AppKit
import ApplicationServices
import CoreMediaIO

// 카메라 지킴이 (camera-guard plugin, worker id "camera-watch").
//
// The problem this solves: Gather (GatherV2) auto-disables the camera when it
// decides the user is away ("사람이 없을 때 개더타운이 자꾸 카메라를 끔"). The
// user wants the camera to stay ON the whole time Gather is running.
//
// Three lines of defense while the plugin is installed and its switch is on:
//   1. KEEP-ALIVE — while Gather runs, post a zero-delta synthetic mouse-move
//      every 30s. Gather's away detection keys off system input idle (Electron
//      powerMonitor); a synthetic event resets that clock, so the "away → camera
//      off" path never triggers. The cursor does not visibly move.
//   2. AUTO-RECOVER — if the camera still goes off (focus-based detection, or
//      Gather's own UI toggle) and stays off past the grace period, don't just
//      report it: turn it back on. macOS never lets one app force another app's
//      capture session on directly, so we drive Gather's OWN toggle by posting
//      its video shortcut. Verified from the shipped bundle, not guessed:
//        /Applications/GatherV2.app/Contents/Resources/app.asar
//        → TOGGLE_VIDEO_SHORTCUT = "CommandOrControl+Shift+V"
//      registered inside app.on("browser-window-focus") and torn down again by
//      globalShortcut.unregisterAll() on blur. THAT is why recovery activates
//      Gather first — an unfocused Gather has no ⌘⇧V registered and the keys
//      would land on whatever app is frontmost instead.
//   3. ALERT — only after recovery has been tried and failed does onViolation
//      fire, once per off-episode, so the user flips it back by hand.
//
// Gather quitting needs nothing: macOS tears the capture session down with the
// app, which IS the "로그아웃 → 카메라 OFF" behavior, for free.
//
// Camera state comes from CoreMediaIO's DeviceIsRunningSomewhere property — the
// same signal as the menu-bar green dot. Reading it never starts a capture
// session and needs no camera TCC grant. Polled every 2s (two property reads
// per device — effectively free next to the 1 Hz heartbeat).
//
// Gather is matched by bundle id / app name containing "gather" (the desktop app
// ships as "GatherV2"), so an app-store rename or the classic client both match.
final class CameraMonitor {

    // Live snapshot (main-thread only), for the menu/dashboard if ever needed.
    private(set) var gatherRunning = false
    private(set) var cameraOn = false

    // Fired on main once per off-episode, AFTER auto-recovery has been tried and
    // the camera is still off. The app decides the reaction (sound/notification);
    // the monitor only detects.
    var onViolation: ((String) -> Void)?
    // Fired on main when the camera comes back ON while a recovery attempt was in
    // flight — i.e. the detect → re-enable chain actually closed. This is the
    // event the demo is about: it proves the two halves are wired to each other.
    var onRecovered: ((String) -> Void)?
    // Fired once per app run when recovery is blocked purely by the missing
    // Accessibility grant. A warn line in a jsonl is not visible to anyone; this is.
    var onAccessibilityMissing: ((String) -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var offSince: Date?
    private var alertedThisEpisode = false
    private let pollInterval: TimeInterval = 2.0
    // The camera legitimately blinks off for a beat on device switches or a Gather
    // tab reload; only a sustained OFF counts as a violation.
    private let graceSeconds: TimeInterval = 10.0
    // Keep-alive cadence. Well under Gather's away thresholds (minutes); frequent
    // enough that the idle clock never accumulates, rare enough to be invisible.
    private let keepAliveInterval: TimeInterval = 30.0
    private var lastKeepAlive = Date.distantPast
    // Auto-recovery bookkeeping, reset at every ON transition and every episode end.
    private var recoveryAttempts = 0
    // Attempts that actually put ⌘⇧V on the wire. Separate from recoveryAttempts,
    // which also counts attempts refused before any key was sent (no grant, Gather
    // gone) — without the split we would claim "자동 재활성화 성공" for a camera the
    // user turned back on by hand.
    private var keysSent = 0
    private var lastRecoveryAt: Date?
    // Two attempts, not more. ⌘⇧V is a TOGGLE (Gather sends !videoEnabled), so an
    // attempt that silently succeeded on Gather's side but was slow to bring the
    // capture session up would be undone by a third press. Two gives one retry for
    // a dropped keystroke while keeping the worst case at "back where we started".
    private let maxRecoveryAttempts = 2
    // Spacing between attempts. The camera device takes a beat to report
    // DeviceIsRunningSomewhere == true after Gather re-enables video; 8s is well
    // past that, so a retry only happens when the first press truly did nothing.
    private let recoveryRetryInterval: TimeInterval = 8.0
    // Gather registers ⌘⇧V on browser-window-focus, so the activation has to land
    // before the keys do. Activation is async and we now WAIT for it (see
    // waitForFrontmost) instead of guessing a settle delay; this is the give-up point.
    private let activationTimeout: TimeInterval = 2.0
    // Gap between "Gather is frontmost" and actually pressing the key. Electron's
    // browser-window-focus (which registers the shortcut) lands after the OS flip.
    private let focusSettle: TimeInterval = 0.7
    private var promptedForAccessibility = false

    // Idempotent: syncPluginWorkers re-calls start() on every plugin sync.
    func start() {
        guard timer == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isGather(app) else { return }
            self.setGather(running: true, via: app.localizedName ?? "Gather")
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isGather(app) else { return }
            // Helper processes can outlive the window that quit — re-scan instead of
            // blindly flipping to false.
            self.setGather(running: Self.gatherIsRunningNow(), via: app.localizedName ?? "Gather")
        })

        gatherRunning = Self.gatherIsRunningNow()
        cameraOn = Self.anyCameraOn()
        WorkerLog.shared.append("camera-watch",
            why: "카메라 지킴이 시작 (개더 실행=\(gatherRunning ? "예" : "아니오"))",
            effect: "카메라 \(cameraOn ? "ON" : "OFF")")

        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.5
        timer = t
    }

    // Idempotent: also the off-path of every plugin sync.
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
        resetEpisode()
        WorkerLog.shared.append("camera-watch", why: "카메라 지킴이 중지 (제거/off)", effect: "감시 해제")
    }

    // MARK: - State transitions

    // One place to clear everything an off-episode accumulates, so a new episode
    // never inherits a spent attempt counter (that would skip recovery entirely).
    private func resetEpisode() {
        offSince = nil
        alertedThisEpisode = false
        recoveryAttempts = 0
        keysSent = 0
        lastRecoveryAt = nil
    }

    private func setGather(running: Bool, via name: String) {
        guard running != gatherRunning else { return }
        gatherRunning = running
        resetEpisode()
        WorkerLog.shared.append("camera-watch",
            why: "개더 \(running ? "실행" : "종료") 감지 (\(name))",
            effect: running ? "keep-alive 시작 — 자리비움 카메라-끄기 방지"
                            : "감시 대기 — 종료와 함께 카메라는 OS가 내려줌")
    }

    private func poll() {
        WorkerRegistry.shared.recordRun("camera-watch")
        keepAliveTick()
        let on = Self.anyCameraOn()
        if on != cameraOn {
            cameraOn = on
            // Transition-only logging, heartbeat-style: the 2s poll itself stays silent.
            WorkerLog.shared.append("camera-watch",
                why: "카메라 상태 변화",
                effect: "카메라 \(on ? "ON" : "OFF")" + (gatherRunning ? " · 개더 실행 중" : ""))
        }
        guard gatherRunning else {
            resetEpisode()
            return
        }
        if on {
            // Came back ON while we were pressing ⌘⇧V — the detect → re-enable chain
            // closed. Report it once, then the episode is over.
            if keysSent > 0 {
                let n = keysSent
                let msg = "카메라가 꺼진 것을 감지해 개더에 ⌘⇧V를 보냈고, \(n)번째 시도에서 다시 켜졌습니다."
                WorkerLog.shared.append("camera-watch", why: "자동 재활성화 성공", effect: msg)
                onRecovered?(msg)
            }
            resetEpisode()
            return
        }
        if offSince == nil { offSince = Date() }
        guard let since = offSince,
              Date().timeIntervalSince(since) >= graceSeconds else { return }

        // Past the grace period. Try to turn it back on BEFORE bothering the human —
        // the alert is the fallback now, not the whole feature.
        if recoveryAttempts < maxRecoveryAttempts {
            if let last = lastRecoveryAt,
               Date().timeIntervalSince(last) < recoveryRetryInterval { return }
            recoveryAttempts += 1
            lastRecoveryAt = Date()
            attemptRecovery(reason: "카메라 \(Int(graceSeconds))초 이상 OFF · 시도 \(recoveryAttempts)/\(maxRecoveryAttempts)")
            return
        }

        guard !alertedThisEpisode else { return }
        alertedThisEpisode = true
        let msg = "개더타운이 실행 중인데 카메라가 꺼져 있어 \(maxRecoveryAttempts)번 자동으로 켜 봤지만 실패했습니다."
        WorkerLog.shared.append("camera-watch", why: "상시-ON 위반 (자동 재활성화 실패)",
                                effect: msg, level: "warn")
        onViolation?(msg)
    }

    // MARK: - Auto-recovery (drive Gather's own video toggle)

    // Turn the camera back on by making Gather do it. Public so a manual trigger
    // (POST /api/camera/recover) can fire the exact same path the poller fires —
    // the demo must not have a second, prettier code path of its own.
    //
    // Chosen branch, and what it assumes:
    //   · We do NOT try to open the capture device ourselves. macOS gives no API to
    //     resume another process's AVCaptureSession, and a session opened by
    //     Condition Mate would be OUR camera feed, not the one Gather sends.
    //   · We DO steal focus, and we do not give it back afterwards. Gather's
    //     shortcut only exists while Gather is focused, so activation is mandatory;
    //     restoring the previous app right after would be a second focus jump on
    //     screen, and "Gather is in front when the camera comes back" is where the
    //     user wants to be anyway. Assumed acceptable for this feature.
    //   · Posting synthetic keys needs the Accessibility (손쉬운 사용) grant. The
    //     keep-alive mouse event already needs it, so this adds no new permission —
    //     but we check explicitly and log, because a missing grant fails silently.
    @discardableResult
    func attemptRecovery(reason: String) -> Bool {
        // ⌘⇧V is a toggle, so firing it while the camera is already ON would TURN IT
        // OFF — the exact opposite of this feature. The poller can't reach here in
        // that state, but the manual trigger can, so the guard lives here where both
        // paths pass through.
        if Self.anyCameraOn() {
            WorkerLog.shared.append("camera-watch", why: "자동 재활성화 건너뜀 (\(reason))",
                effect: "카메라가 이미 켜져 있다 — 토글을 보내면 오히려 꺼진다")
            return false
        }
        guard let gather = Self.gatherApp() else {
            WorkerLog.shared.append("camera-watch", why: "자동 재활성화 건너뜀 (\(reason))",
                effect: "개더가 실행 중이 아니라 키를 보낼 대상이 없다", level: "warn")
            return false
        }

        // Accessibility (손쉬운 사용) is not optional here, and there is no way around it.
        // Measured on 2026-09-05, not assumed: the obvious escape hatch — spawn
        // osascript and let System Events press the key — hits the SAME wall, because
        // TCC blames the responsible process (us), not osascript:
        //   osascript status=1 execution error: System Events got an error:
        //   osascript is not allowed to send keystrokes. (1002)
        // So the fallback was deleted again. One path, and a loud ask when it is shut.
        //
        // What IS verified to work, with this exact sequence run from a process that
        // holds the grant: activate Gather → wait for it to actually be frontmost →
        // post ⌘⇧V → 카메라가 OFF 에서 ON 으로 바뀐다.
        guard AXIsProcessTrusted() else {
            WorkerLog.shared.append("camera-watch", why: "자동 재활성화 불가 (\(reason))",
                effect: "손쉬운 사용 권한이 없어 ⌘⇧V를 보낼 수 없다 — 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용",
                level: "warn")
            // The app is ad-hoc signed, so its cdhash changes on every build and the TCC
            // row goes stale: System Settings keeps SHOWING ConditionMate switched on
            // while this returns false. Three duplicate stale rows existed on
            // 2026-09-05. A stale row also suppresses the system dialog, which is why
            // the user saw nothing at all — so we open the pane ourselves and say it in
            // a banner, once per app run.
            if !promptedForAccessibility {
                promptedForAccessibility = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(u)
                }
                onAccessibilityMissing?("카메라를 다시 켜려면 손쉬운 사용 권한이 필요합니다. 목록의 ConditionMate를 켜 주세요.")
            }
            return false
        }
        gather.unhide()
        // NOT NSRunningApplication.activate(). Measured on macOS 15 (2026-09-05): calling
        // activate() from this menu-bar app left Gather in the background and the log read
        //   "개더가 2.0초 안에 최전면이 되지 않았다 — 지금 최전면은 Condition Mate"
        // so the key was never sent. openApplication(at:configuration:) with activates=true
        // goes through LaunchServices instead and wins: measured 3/3, frontmost flipped to
        // GatherV2 in 0.1s from a background process.
        if let url = gather.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        } else {
            gather.activate()
        }
        WorkerLog.shared.append("camera-watch", why: "자동 재활성화 시도 (\(reason))",
            effect: "개더(\(gather.localizedName ?? "Gather"))를 앞으로 올리는 중 — 최전면 확인 후 ⌘⇧V(TOGGLE_VIDEO) 전송")
        // Wait for the activation to LAND rather than sleeping on a guessed number.
        // Gather registers ⌘⇧V inside app.on("browser-window-focus"), so a key posted
        // before the focus switch either vanishes or hits the app that was frontmost.
        // Measured: a fixed 1.0s wait was already too short once on this Mac.
        waitForFrontmost(pid: gather.processIdentifier,
                         deadline: Date().addingTimeInterval(activationTimeout))
        return true
    }

    // Recursive asyncAfter rather than a sleep loop — this runs on main and must not
    // block the 2s poll timer or the UI.
    private func waitForFrontmost(pid: pid_t, deadline: Date) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == pid {
            // Frontmost flips at the OS level before Electron's browser-window-focus
            // handler runs, and that handler is what registers ⌘⇧V. Give it a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + focusSettle) { [weak self] in
                // Counted HERE, not at the top of attemptRecovery: only a key that
                // actually went out may later be claimed as the cause of the camera
                // coming back on.
                self?.keysSent += 1
                Self.postToggleVideoShortcut()
                WorkerLog.shared.append("camera-watch", why: "⌘⇧V 전송",
                    effect: "개더가 최전면인 것을 확인하고 키를 보냈다 — 카메라가 켜지는지 다음 폴에서 확인")
            }
            return
        }
        guard Date() < deadline else {
            WorkerLog.shared.append("camera-watch", why: "자동 재활성화 실패 (포커스)",
                effect: "개더가 \(String(format: "%.1f", activationTimeout))초 안에 최전면이 되지 않았다 — 지금 최전면은 \(front?.localizedName ?? "알 수 없음"). 키를 보내지 않았다",
                level: "warn")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForFrontmost(pid: pid, deadline: deadline)
        }
    }

    // ⌘⇧V, posted at the HID tap so Gather's globalShortcut sees it. Key code 9 is
    // kVK_ANSI_V (hard-coded rather than importing Carbon for one constant).
    private static func postToggleVideoShortcut() {
        let vKey: CGKeyCode = 9
        let src = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        if let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    // The window-owning Gather process, not one of its helpers (helpers are
    // .prohibited and cannot be activated, so keys sent after activating one would
    // land on whatever app is actually frontmost).
    private static func gatherApp() -> NSRunningApplication? {
        let all = NSWorkspace.shared.runningApplications.filter { isGather($0) }
        return all.first { $0.activationPolicy == .regular } ?? all.first
    }

    // MARK: - Keep-alive (defeat Gather's away detection)

    // Post a synthetic mouse-move at the CURRENT cursor position (zero delta — the
    // pointer does not move on screen). This resets the system input-idle clock
    // that Electron's powerMonitor reads, so Gather never reaches its away
    // threshold while it is running. Runs only while Gather runs; the Mac idles
    // normally otherwise. Note: this also keeps the display awake during Gather
    // sessions — desired here (the camera feed should stay visibly on).
    private func keepAliveTick() {
        guard gatherRunning else { return }
        guard Date().timeIntervalSince(lastKeepAlive) >= keepAliveInterval else { return }
        lastKeepAlive = Date()
        let pos = CGEvent(source: nil)?.location ?? .zero
        if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: pos, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Gather detection

    private static func isGather(_ app: NSRunningApplication) -> Bool {
        let bid = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return bid.contains("gather") || name.contains("gather")
    }

    private static func gatherIsRunningNow() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isGather($0) }
    }

    // MARK: - CoreMediaIO: is any camera capturing?

    // "Is running somewhere" is true while ANY process holds an active capture
    // session on the device — exactly the green-dot condition. Virtual cameras
    // (OBS 등) count too, which is what we want: 화면에 나가고 있으면 ON이다.
    private static func anyCameraOn() -> Bool {
        cameraDeviceIDs().contains { deviceIsRunningSomewhere($0) }
    }

    private static func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var dataSize: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &address, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &address, 0, nil, dataSize, &used, &ids) == 0
        else { return [] }
        return ids
    }

    private static func deviceIsRunningSomewhere(_ id: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        guard CMIOObjectHasProperty(id, &address) else { return false }
        var on: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(id, &address, 0, nil, size, &used, &on) == 0
        else { return false }
        return on != 0
    }
}
