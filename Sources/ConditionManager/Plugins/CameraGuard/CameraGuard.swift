import AppKit
import CoreMediaIO

// 카메라 지킴이 (camera-guard plugin, worker id "camera-watch").
//
// The problem this solves: Gather (GatherV2) auto-disables the camera when it
// decides the user is away ("사람이 없을 때 개더타운이 자꾸 카메라를 끔"). The
// user wants the camera to stay ON the whole time Gather is running.
//
// Two lines of defense while the plugin is installed and its switch is on:
//   1. KEEP-ALIVE — while Gather runs, post a zero-delta synthetic mouse-move
//      every 30s. Gather's away detection keys off system input idle (Electron
//      powerMonitor); a synthetic event resets that clock, so the "away → camera
//      off" path never triggers. The cursor does not visibly move.
//   2. DETECT & ALERT — macOS never lets one app force another app's capture
//      session back on, so if the camera still goes off (e.g. focus-based
//      detection, or Gather's own UI toggle) and stays off past a grace period,
//      fire onViolation once per off-episode so the user flips it back on.
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

    // Fired on main once per off-episode after the grace period. The app decides
    // the reaction (sound/notification); the monitor only detects.
    var onViolation: ((String) -> Void)?

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
        offSince = nil
        alertedThisEpisode = false
        WorkerLog.shared.append("camera-watch", why: "카메라 지킴이 중지 (제거/off)", effect: "감시 해제")
    }

    // MARK: - State transitions

    private func setGather(running: Bool, via name: String) {
        guard running != gatherRunning else { return }
        gatherRunning = running
        offSince = nil
        alertedThisEpisode = false
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
            offSince = nil
            alertedThisEpisode = false
            return
        }
        if on {
            offSince = nil
            alertedThisEpisode = false
            return
        }
        if offSince == nil { offSince = Date() }
        guard let since = offSince, !alertedThisEpisode,
              Date().timeIntervalSince(since) >= graceSeconds else { return }
        alertedThisEpisode = true
        let msg = "개더타운이 실행 중인데 카메라가 \(Int(graceSeconds))초째 꺼져 있습니다."
        WorkerLog.shared.append("camera-watch", why: "상시-ON 위반", effect: msg, level: "warn")
        onViolation?(msg)
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
