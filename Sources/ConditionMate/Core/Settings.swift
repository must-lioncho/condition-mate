import Foundation

// Lightweight persistence of user preferences, backed by a JSON file under AppPaths.base
// (~/.condition-mate/settings.json — single store shared by dev and installed builds).
//
// WHY a file, not UserDefaults: the dev binary launched by Scripts/dev-run.sh is an
// UNBUNDLED SwiftPM executable (no Info.plist → Bundle.main.bundleIdentifier == nil).
// For such a process `UserDefaults.standard` maps to a domain cfprefsd does not persist
// reliably, and pending writes are lost when the process is killed for a rebuild — so
// plugin connections (cm.pluginFolders) silently reverted to 미연결 every rebuild. Worse,
// the dev binary (nil id) and the packaged .app (com.lioncho.conditionmate) used
// different domains, so a connection made in one was invisible to the other. Routing
// through AppPaths makes settings launch-independent the same way the data store already
// is, and every set is flushed to disk atomically so it survives a kill/rebuild.
//
// Kept tiny: no observation framework, just plain getters/setters. Values serialize via
// JSONSerialization, whose native types (String, Double, Bool, Array, Dictionary) cover
// every preference here.
final class Settings {
    static let shared = Settings()

    private enum K {
        static let musicFolder    = "cm.musicFolderPath"
        static let trackedApps    = "cm.trackedBundleIDs"
        static let minBPM         = "cm.minBPM"
        static let maxBPM         = "cm.maxBPM"
        static let releaseMinutes = "cm.releaseMinutes"
        static let idleSeconds    = "cm.idleSeconds"
        static let idleAmbient    = "cm.idleAmbientEnabled"
        static let idleVolScale   = "cm.idleVolumeScale"
        static let musicEnabled   = "cm.musicEnabled"
        static let trackingEnabled = "cm.trackingEnabled"
        static let volume         = "cm.volume"
        static let appProfiles    = "cm.appProfiles"
        static let pluginFolders  = "cm.pluginFolders"
        static let pluginInstalled = "cm.pluginInstalled"
        static let lastView       = "cm.lastView"
        static let doneCutoff     = "cm.doneCutoff"
        static let uiPrefs        = "cm.uiPrefs"
        static let conditionMate  = "cm.conditionMate"
        static let skillsRoot     = "cm.skillsRoot"
        static let issueFolder    = "cm.issueFolder"
        static let queueFolder    = "cm.queueFolder"
        static let bgmWindow      = "cm.bgmWindowEnabled"
        static let timeZone       = "cm.timeZone"
        static let timeZoneKSTMigrated = "cm.timeZoneKSTMigrated"
        static let activeGoalSeq  = "cm.activeGoalSeq"
        static let activeGoalAt   = "cm.activeGoalAt"
        static let recentTasks    = "cm.recentTasks"
        static let pinnedGoals    = "cm.pinnedGoalSeqs"
        static let recentParents  = "cm.recentParentSeqs"
        static let diagHosts      = "cm.diagHosts"
        static let gaComposer     = "cm.gaComposer"
        static let gaTallyHist    = "cm.gaTallyHist"
        static let drawEnabled    = "cm.drawEnabled"
        static let cameraGuardOn  = "cm.cameraGuardOn"
        static let debugButtons   = "cm.debugButtons"
        static let debugCapture   = "cm.debugCapture"
        static let bgmVenue       = "cm.bgmVenue"
        static let muted          = "cm.muted"
        static let sfxEnabled     = "cm.sfxEnabled"
        static let voiceDuckOn    = "cm.voiceDuckOn"
        static let gwMode         = "cm.gwMode"
        static let gwBaseURL      = "cm.gwBaseURL"
        static let gwScheme       = "cm.gwScheme"
        static let gwKeyService   = "cm.gwKeyService"
        static let gwKeyAccount   = "cm.gwKeyAccount"
    }

    // Defaults for values the user has not touched. Mirrors the old register(defaults:).
    private static let defaults: [String: Any] = [
        K.minBPM: 70.0,
        K.maxBPM: 150.0,
        K.releaseMinutes: 5.0,
        K.idleSeconds: 60.0,
        K.idleAmbient: true,
        K.idleVolScale: 0.5,
        K.musicEnabled: true,
        K.trackingEnabled: true,
        K.volume: 0.8,
        K.bgmWindow: true,
        K.drawEnabled: true,
        K.cameraGuardOn: true,
        K.debugButtons: true,
        K.sfxEnabled: true,
        K.voiceDuckOn: true,
        K.gwMode: "auto",
        K.gwScheme: "bearer",
        K.gwKeyService: "claude-code-token"
    ]

    private let fileURL: URL
    private let lock = NSLock()
    private var store: [String: Any]

    private init() {
        fileURL = AppPaths.base.appendingPathComponent("settings.json", isDirectory: false)
        store = Settings.load(from: fileURL) ?? Settings.migrateFromUserDefaults()
        // Persist immediately so a fresh install / migrated state has a file on disk.
        persist()
    }

    // MARK: Backing store

    private static func load(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // One-time seed from the legacy UserDefaults.standard store, so existing users keep
    // their music folder, tracked apps, plugin connections, etc. Reads raw (no register),
    // so only user-modified keys carry over — untouched keys fall through to `defaults`.
    private static func migrateFromUserDefaults() -> [String: Any] {
        let d = UserDefaults.standard
        let keys = [K.musicFolder, K.trackedApps, K.minBPM, K.maxBPM, K.releaseMinutes,
                    K.idleSeconds, K.idleAmbient, K.idleVolScale, K.musicEnabled,
                    K.trackingEnabled, K.volume, K.appProfiles, K.pluginFolders,
                    K.pluginInstalled, K.lastView, K.doneCutoff, K.uiPrefs, K.conditionMate]
        var seed: [String: Any] = [:]
        for k in keys { if let v = d.object(forKey: k) { seed[k] = v } }
        return seed
    }

    // Atomic write so a kill mid-write can never corrupt the file.
    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: store,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return store[key] ?? Settings.defaults[key]
    }

    private func set(_ value: Any?, _ key: String) {
        lock.lock()
        if let value = value { store[key] = value } else { store.removeValue(forKey: key) }
        persist()
        lock.unlock()
    }

    // Typed convenience readers mirroring the old UserDefaults call sites.
    private func string(_ key: String) -> String? { get(key) as? String }
    private func double(_ key: String) -> Double { (get(key) as? NSNumber)?.doubleValue ?? 0 }
    private func bool(_ key: String) -> Bool { (get(key) as? NSNumber)?.boolValue ?? false }

    // MARK: Preferences (public API unchanged)

    var musicFolderPath: String? {
        get { string(K.musicFolder) }
        set { set(newValue, K.musicFolder) }
    }

    // 전략7 · 장소·컨디션 프리셋 키 (VenueContext.key). nil = 기본(2명 사무실).
    // settings.json에 저장되므로 앱 재시작·업데이트를 넘어 마지막 선택이 유지된다.
    var bgmVenueKey: String? {
        get { string(K.bgmVenue) }
        set { set(newValue, K.bgmVenue) }
    }

    // Base ".claude" folder whose /skills subfolder holds the user's skills. Empty/absent
    // means the ~/.claude default. Configurable from the skills page so a user can keep
    // skills in a different Claude root (e.g. a shared or per-machine location).
    var skillsRoot: String? {
        get { string(K.skillsRoot) }
        set { set(newValue, K.skillsRoot) }
    }

    // Folder where a delegation issue file is created. Empty/absent means "follow the
    // folder the agent was invoked in" (IssueFolder.defaultRoot) — the default the user
    // asked for so 40 parallel projects each keep their issues next to their own code.
    // Set from the rail's ⚙️설정 panel. Resolution lives in IssueFolder, not here.
    var issueFolder: String? {
        get { string(K.issueFolder) }
        set { set(newValue, K.issueFolder) }
    }
    
    // Explicit queue folder choice, or nil if none.
    var queueFolder: String? {
        get { string(K.queueFolder) }
        set { set(newValue, K.queueFolder) }
    }

    var trackedApps: [String] {
        get { (get(K.trackedApps) as? [String]) ?? [] }
        set { set(newValue, K.trackedApps) }
    }

    func addTrackedApp(_ bundleID: String) {
        var apps = trackedApps
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
        trackedApps = apps
    }

    func removeTrackedApp(_ bundleID: String) {
        trackedApps = trackedApps.filter { $0 != bundleID }
        var p = appProfiles
        p.removeValue(forKey: bundleID)
        appProfiles = p
    }

    // Per-app BGM profile overrides (bundleID -> profile key).
    var appProfiles: [String: String] {
        get { (get(K.appProfiles) as? [String: String]) ?? [:] }
        set { set(newValue, K.appProfiles) }
    }

    // Resolved profile key: explicit override, else well-known default.
    func profileKey(for bundleID: String) -> String {
        appProfiles[bundleID] ?? BGMProfile.defaultKey(forBundleID: bundleID)
    }

    func setProfile(_ key: String, for bundleID: String) {
        var p = appProfiles
        p[bundleID] = key
        appProfiles = p
    }

    // Per-plugin connected folder (pluginId -> absolute path). Empty/absent = not connected.
    var pluginFolders: [String: String] {
        get { (get(K.pluginFolders) as? [String: String]) ?? [:] }
        set { set(newValue, K.pluginFolders) }
    }

    func setPluginFolder(_ path: String?, for pluginId: String) {
        var p = pluginFolders
        if let path = path, !path.isEmpty { p[pluginId] = path } else { p.removeValue(forKey: pluginId) }
        pluginFolders = p
    }

    // Install state for toggle-based plugins (pluginId -> bool). These have no folder to
    // connect; "installed" is the whole connection (e.g. 컨디션 메이트). Absent = never
    // touched, so the caller supplies a per-plugin default (컨디션 메이트 defaults installed).
    var pluginInstalled: [String: Bool] {
        get {
            let raw = (get(K.pluginInstalled) as? [String: Any]) ?? [:]
            var out: [String: Bool] = [:]
            for (k, v) in raw { out[k] = (v as? NSNumber)?.boolValue ?? (v as? Bool ?? false) }
            return out
        }
        set { set(newValue, K.pluginInstalled) }
    }

    func isPluginInstalled(_ pluginId: String, default def: Bool) -> Bool {
        pluginInstalled[pluginId] ?? def
    }

    func setPluginInstalled(_ on: Bool, for pluginId: String) {
        var p = pluginInstalled
        p[pluginId] = on
        pluginInstalled = p
    }

    // 드로우 plugin sub-switch (the plugin card's draw on/off). The overlay only runs
    // while the plugin is installed AND this is on — flipping it off pauses drawing
    // without uninstalling the plugin.
    // Last music-mute state. Durable so an app update / relaunch restores the user's intent:
    // if the sound was muted when the app went down, it comes back muted. Written through
    // ChallengeSession (the single source of truth for the live flag).
    var muted: Bool {
        get { bool(K.muted) }
        set { set(newValue, K.muted) }
    }

    // 효과음(원샷 이펙트: 세션 시작·정지 큐, 포모도로 완주·수확, 레일 내비 클릭) 스위치.
    // 음악과 따로 끌 수 있어야 한다 — BGM은 집중을 돕지만 불쑥 튀는 알림음은 그 집중을 깬다.
    // 마스터 음소거(`muted`)와는 AND로 묶인다: 음소거면 이 값과 무관하게 전부 침묵
    // (AppDelegate.applySfxGate가 두 스위치를 합쳐 SoundEffects에 밀어 넣는 유일한 지점).
    var sfxEnabled: Bool {
        get { bool(K.sfxEnabled) }
        set { set(newValue, K.sfxEnabled) }
    }

    // 받아쓰기(superwhisper) 중 음악을 잠깐 눌러 두는 스위치. 기본은 켜짐 — 말하는 동안 음악이
    // 마이크로 새는 것을 막는 게 대부분의 경우 원하는 동작이다. 끄면 감시 자체를 멈춰서
    // 전역 키 모니터와 폴더 감시가 모두 내려간다(꺼 두면 비용도 0).
    var voiceDuckOn: Bool {
        get { bool(K.voiceDuckOn) }
        set { set(newValue, K.voiceDuckOn) }
    }

    var drawEnabled: Bool {
        get { bool(K.drawEnabled) }
        set { set(newValue, K.drawEnabled) }
    }

    // 카메라 지킴이 card sub-switch (on = keep the camera alive while Gather runs).
    // Pauses the guard without uninstalling the plugin, mirroring drawEnabled.
    var cameraGuardOn: Bool {
        get { bool(K.cameraGuardOn) }
        set { set(newValue, K.cameraGuardOn) }
    }

    // 전역 디버그 버튼 노출 스위치 (레일 ⚙️ 설정). off면 각 페이지의 디버그성
    // 버튼/배지가 아예 렌더링되지 않는다. 페이지들은 피드 폴링으로 즉시 반영.
    var debugButtons: Bool {
        get { bool(K.debugButtons) }
        set { set(newValue, K.debugButtons) }
    }

    // 디버그 모드(버그 수집) 스위치 — 메뉴바 위젯의 체크 항목. 앱이 죽거나 업데이트로
    // 재시작해도 수집이 이어지도록 영속한다(재시작이 재현 절차의 일부인 버그가 많다).
    // 켜져 있는 동안에만 DebugCapture가 전수 기록을 남기고, 끄는 순간 버그 리포트
    // goal 하나가 자동으로 만들어진다. 기본 꺼짐.
    var debugCapture: Bool {
        get { bool(K.debugCapture) }
        set { set(newValue, K.debugCapture) }
    }

    // --- Claude CLI 연결(게이트웨이) 설정 -----------------------------------------
    // 앱이 spawn하는 `claude` 는 유저 터미널의 zsh 함수(키체인 토큰을 env로 주입)를 타지
    // 않으므로, 게이트웨이를 쓰는 환경에서는 앱이 직접 ANTHROPIC_* 을 넣어줘야 한다.
    // "auto"(기본)면 아무것도 주입하지 않고 CLI 자신의 로컬 로그인(OAuth)을 쓴다.
    // 비밀 값은 절대 여기 저장하지 않는다 — 키체인 항목 이름만 보관한다.

    /// "auto" = 주입 없음(로컬 OAuth) · "gateway" = ANTHROPIC_BASE_URL/토큰 주입
    var gatewayMode: String {
        get { string(K.gwMode) ?? "auto" }
        set { set(newValue, K.gwMode) }
    }
    /// 추론 게이트웨이 엔드포인트. 빈 문자열 = 미설정.
    var gatewayBaseURL: String {
        get { string(K.gwBaseURL) ?? "" }
        set { set(newValue, K.gwBaseURL) }
    }
    /// "bearer" → ANTHROPIC_AUTH_TOKEN · "apiKey" → ANTHROPIC_API_KEY
    var gatewayScheme: String {
        get { string(K.gwScheme) ?? "bearer" }
        set { set(newValue, K.gwScheme) }
    }
    /// 토큰을 담고 있는 키체인 generic-password 의 서비스명.
    var gatewayKeyService: String {
        get { string(K.gwKeyService) ?? "claude-code-token" }
        set { set(newValue, K.gwKeyService) }
    }
    /// 키체인 항목의 계정명. 빈 문자열이면 현재 로그인 유저를 쓴다.
    var gatewayKeyAccount: String {
        get { string(K.gwKeyAccount) ?? "" }
        set { set(newValue, K.gwKeyAccount) }
    }

    var minBPM: Double {
        get { double(K.minBPM) }
        set { set(newValue, K.minBPM) }
    }
    var maxBPM: Double {
        get { double(K.maxBPM) }
        set { set(newValue, K.maxBPM) }
    }
    var releaseMinutes: Double {
        get { double(K.releaseMinutes) }
        set { set(newValue, K.releaseMinutes) }
    }
    var idleSeconds: Double {
        get { double(K.idleSeconds) }
        set { set(newValue, K.idleSeconds) }
    }
    // When idle, play slow ambient music instead of going silent.
    var idleAmbientEnabled: Bool {
        get { bool(K.idleAmbient) }
        set { set(newValue, K.idleAmbient) }
    }
    // Volume multiplier applied to the base volume while in ambient idle (0...1).
    var idleVolumeScale: Double {
        get { double(K.idleVolScale) }
        set { set(newValue, K.idleVolScale) }
    }
    var musicEnabled: Bool {
        get { bool(K.musicEnabled) }
        set { set(newValue, K.musicEnabled) }
    }
    // Auto-open the native BGM window (an in-app WKWebView with autoplay enabled) on launch,
    // so the activity BGM plays with the space effect with zero clicks. Default on.
    var bgmWindowEnabled: Bool {
        get { bool(K.bgmWindow) }
        set { set(newValue, K.bgmWindow) }
    }
    var trackingEnabled: Bool {
        get { bool(K.trackingEnabled) }
        set { set(newValue, K.trackingEnabled) }
    }
    var volume: Double {
        get { double(K.volume) }
        set { set(newValue, K.volume) }
    }

    // Dashboard view the user last had open. Restored on next launch so the app
    // reopens to the same view. Stored here (not browser localStorage) because the
    // server port is dynamic each launch, which would reset a per-origin store.
    var lastView: String {
        get { string(K.lastView) ?? "input" }
        set { set(newValue, K.lastView) }
    }

    // The goal/task page the user most recently opened. Surfaced in the left rail as
    // "보는 중" so "what I'm working on right now" survives an app quit/relaunch — the
    // live-PTY session list (cliSessions) is in-memory only and vanishes on quit, which is
    // why a page you were reading disappeared from the rail after closing the app. Stamped
    // on every /goal GET; `activeGoalAt` is the epoch of that open so the marker can age out.
    // Subtask pages stamp their PARENT goal seq (the rail is a goal-level worklist).
    var activeGoalSeq: Int? {
        get { (get(K.activeGoalSeq) as? NSNumber)?.intValue }
        set { set(newValue.map { NSNumber(value: $0) }, K.activeGoalSeq) }
    }
    var activeGoalAt: Double? {
        get { (get(K.activeGoalAt) as? NSNumber)?.doubleValue }
        set { set(newValue.map { NSNumber(value: $0) }, K.activeGoalAt) }
    }
    // Record that goal `seq` was just opened. Called from the /goal page handler.
    func markActiveGoal(_ seq: Int, at epoch: Double) {
        activeGoalSeq = seq
        activeGoalAt = epoch
    }

    // Recently-VIEWED subtask pages, newest-first. Each entry is (parent goal seq, task
    // folder name, epoch of the view). This is the task-level twin of activeGoalSeq: a
    // subtask page stamps itself here so the left rail can show real "task-NN 보는 중" rows
    // — several of them, in recency order — instead of collapsing every task into its
    // parent goal. Persisted (survives an app quit/relaunch) and aged out like the goal
    // marker (see cliSessionsJSON's 12h window).
    struct RecentTask { let seq: Int; let task: String; let at: Double }
    var recentTasks: [RecentTask] {
        get {
            let arr = (get(K.recentTasks) as? [[String: Any]]) ?? []
            return arr.compactMap { d in
                guard let seq = (d["seq"] as? NSNumber)?.intValue,
                      let task = d["task"] as? String, !task.isEmpty else { return nil }
                let at = (d["at"] as? NSNumber)?.doubleValue ?? 0
                return RecentTask(seq: seq, task: task, at: at)
            }
        }
        set {
            set(newValue.map { ["seq": NSNumber(value: $0.seq), "task": $0.task,
                                "at": NSNumber(value: $0.at)] as [String: Any] }, K.recentTasks)
        }
    }
    // Record that a subtask page (goal `seq` / `task` folder) was just opened. Upserts the
    // entry to the front (most-recent first), dedupes the same task, and caps the list so a
    // long browsing history can't grow the rail without bound.
    func markActiveTask(_ seq: Int, _ task: String, at epoch: Double) {
        var list = recentTasks.filter { !($0.seq == seq && $0.task == task) }
        list.insert(RecentTask(seq: seq, task: task, at: epoch), at: 0)
        if list.count > 6 { list = Array(list.prefix(6)) }
        recentTasks = list
    }
    // Drop every recently-viewed task under `seq` (used when the parent goal is archived so
    // its tasks don't linger in the rail as 보는 중).
    func clearRecentTasks(seq: Int) {
        let filtered = recentTasks.filter { $0.seq != seq }
        if filtered.count != recentTasks.count { recentTasks = filtered }
    }

    // Goals the user has PINNED (고정됨) in the left rail. Persisted so a pinned goal always
    // surfaces at the top of the rail — even when it has no live terminal, is not in_progress,
    // and is not the page being viewed — and survives an app quit/relaunch. Stored newest-pin-
    // first (the toggle prepends), which is the order the "고정됨" section renders in.
    var pinnedGoalSeqs: [Int] {
        get { ((get(K.pinnedGoals) as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
        set { set(newValue.map { NSNumber(value: $0) }, K.pinnedGoals) }
    }
    func isPinned(_ seq: Int) -> Bool { pinnedGoalSeqs.contains(seq) }
    // Toggle (or force) a goal's pinned state; returns the resulting pinned flag. A new pin
    // goes to the front so the most recently pinned sits at the top of the 고정됨 section.
    @discardableResult
    func setPinnedGoal(_ seq: Int, pinned: Bool? = nil) -> Bool {
        var list = pinnedGoalSeqs
        let currentlyPinned = list.contains(seq)
        let target = pinned ?? !currentlyPinned
        guard target != currentlyPinned else { return currentlyPinned }
        if target { list.removeAll { $0 == seq }; list.insert(seq, at: 0) }
        else { list.removeAll { $0 == seq } }
        pinnedGoalSeqs = list
        return target
    }

    // Goals recently used AS A PARENT (부모#). Newest-first, capped — this drives the "최근 사용"
    // section of the parent dropdown and mildly boosts the automatic parent suggestion.
    // Server-side rather than localStorage for the same reason as lastView/doneCutoff: the
    // dashboard port changes every launch, which wipes the browser origin's storage.
    var recentParentSeqs: [Int] {
        get { ((get(K.recentParents) as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
        set { set(newValue.map { NSNumber(value: $0) }, K.recentParents) }
    }
    // Record that `seq` was just chosen as a parent. Upserts to the front so the list reads
    // as "what I've been filing under lately".
    func noteParentUse(_ seq: Int) {
        guard seq > 0 else { return }
        var list = recentParentSeqs.filter { $0 != seq }
        list.insert(seq, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentParentSeqs = list
    }

    // Dashboard "완료 컷오프" — completion-time cutoff for hiding old 완료 goals.
    // Persisted server-side for the same reason as lastView: the dynamic port resets
    // any browser-side store (URL hash / localStorage) on every launch.
    // nil  = never touched → client falls back to its built-in default cutoff.
    // 0    = explicitly cleared (해제) → show all 완료 goals.
    // >0   = epoch seconds of the active cutoff instant.
    var doneCutoff: Double? {
        get { (get(K.doneCutoff) as? NSNumber)?.doubleValue }
        set { set(newValue.map { NSNumber(value: $0) }, K.doneCutoff) }
    }

    // Dashboard UI state blob (보기 상태 필터 · 상위 항상 표시 · 루프 선택 · 접기/펼치기).
    // Persisted server-side for the same reason as lastView/doneCutoff: the dynamic server
    // port resets any browser-side store (URL hash / localStorage) on every launch, so the
    // last filter/expand layout would otherwise be lost when the app restarts. Stored as the
    // raw JSON string the client produced; the client re-applies it verbatim on boot.
    // nil = never touched → client uses its built-in defaults.
    var uiPrefs: String? {
        get { string(K.uiPrefs) }
        set { set(newValue, K.uiPrefs) }
    }

    // Active condition mate id (see Plugins/ConditionMate). Resolved by MateRegistry;
    // only meaningful while the condition-mate plugin is connected. Default: routine.
    var conditionMate: String {
        get { string(K.conditionMate) ?? "routine" }
        set { set(newValue, K.conditionMate) }
    }

    // 표시 타임존. Storage stays epoch (UTC-based) everywhere; this only decides which
    // wall clock timestamps are RENDERED in — both the dashboard JS (via window.CM_TZ)
    // and the Swift-side display formatters. "Asia/Seoul" (default, KST) = 라이언의 하루;
    // "system" = the machine's local timezone; anything else must be a valid IANA
    // identifier ("UTC", …).
    //
    // WHY the default is KST and not "system" (2026-09-05, issue/2026-09-05-token-view-
    // timezone-directive.md): the app already hardcodes Asia/Seoul in three places
    // (AppLog.logTimeZone, isoWeek(of:), aiTaskNameParts), so a "system" display default
    // makes two different "오늘" coexist inside one app. This product counts a HUMAN's
    // workday, and a workday's boundary is decided by where the person lives, not by
    // whatever the laptop happens to be set to — this Mac is set to IST (UTC+5.5), which
    // was never a chosen value, and it silently shifted every day boundary by 3h30m.
    // Reversible: the header selector still offers 시스템 / Asia/Seoul / UTC.
    var timeZoneID: String {
        get { string(K.timeZone) ?? "Asia/Seoul" }
        set { set(newValue, K.timeZone) }
    }

    // 1회 마이그레이션 플래그 — 기본값을 "system" → "Asia/Seoul" 로 바꾼 날(2026-09-05)에
    // 이미 디스크에 "system" 이 저장돼 있던 설치본을 한 번만 KST 로 옮기기 위한 것.
    // (AppDelegate.migrateTimeZoneKSTDefault() 가 유일한 소비자.)
    var timeZoneKSTMigrated: Bool {
        get { bool(K.timeZoneKSTMigrated) }
        set { set(newValue, K.timeZoneKSTMigrated) }
    }

    // Target hosts probed by the 네트워크 진단 (DiagProbe) — the sites whose reachability we
    // check when a user reports "the page won't load". Defaults to the HRIS host that triggered
    // this feature; editable from the 진단 tab so new internal hosts can be added without a build.
    // Stored as a plain string array; entries may be bare hosts or pasted URLs (normalized at probe time).
    var diagHosts: [String] {
        get {
            let arr = (get(K.diagHosts) as? [String])?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
            return arr.isEmpty ? ["hris.must.company"] : arr
        }
        set { set(newValue.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, K.diagHosts) }
    }

    // 목표 추가(/goal-add) 컴포저의 마지막 실행 컨텍스트 — 고른 작업 폴더(cwd·표시이름·브랜치),
    // 작업량(effort)·모드(mode), 그리고 최근 사용 폴더 MRU(recents, 최신 우선·최대 8).
    // Persisted server-side for the same reason as lastView/doneCutoff/uiPrefs: the dynamic
    // server port resets any browser-side store (localStorage) on every launch, so a folder
    // the user picked would revert to "기본" after each rebuild/relaunch. Stored as a plain
    // JSON-native dict/array so it round-trips through JSONSerialization untouched; the page
    // reads it (injected at render as window._gaServerCtx) and writes it back on every change.
    struct FolderRef { let cwd: String; let name: String; let branch: String }
    struct ComposerContext {
        var cwd: String; var name: String; var branch: String
        var effort: String; var mode: String; var model: String
        var recents: [FolderRef]
    }
    var gaComposer: ComposerContext {
        get {
            let d = (get(K.gaComposer) as? [String: Any]) ?? [:]
            let recents = ((d["recents"] as? [[String: Any]]) ?? []).compactMap { r -> FolderRef? in
                guard let cwd = r["cwd"] as? String, !cwd.isEmpty else { return nil }
                return FolderRef(cwd: cwd, name: (r["name"] as? String) ?? cwd,
                                 branch: (r["branch"] as? String) ?? "")
            }
            return ComposerContext(cwd: (d["cwd"] as? String) ?? "",
                                   name: (d["name"] as? String) ?? "",
                                   branch: (d["branch"] as? String) ?? "",
                                   effort: (d["effort"] as? String) ?? "",
                                   mode: (d["mode"] as? String) ?? "",
                                   model: (d["model"] as? String) ?? "",
                                   recents: recents)
        }
        set {
            let recents = newValue.recents.prefix(8).map {
                ["cwd": $0.cwd, "name": $0.name, "branch": $0.branch] as [String: Any]
            }
            set(["cwd": newValue.cwd, "name": newValue.name, "branch": newValue.branch,
                 "effort": newValue.effort, "mode": newValue.mode, "model": newValue.model,
                 "recents": recents] as [String: Any], K.gaComposer)
        }
    }
    // Upsert the composer's execution context from one change on the page. When `cwd` is a
    // real folder it is also promoted to the front of the recents MRU (deduped, capped at 8),
    // so the server owns the MRU bookkeeping and the client stays a thin writer.
    func markComposer(cwd: String, name: String, branch: String, effort: String, mode: String, model: String) {
        var ctx = gaComposer
        ctx.cwd = cwd; ctx.name = name; ctx.branch = branch
        ctx.effort = effort; ctx.mode = mode; ctx.model = model
        if !cwd.isEmpty {
            var list = ctx.recents.filter { $0.cwd != cwd }
            list.insert(FolderRef(cwd: cwd, name: name.isEmpty ? cwd : name, branch: branch), at: 0)
            ctx.recents = Array(list.prefix(8))
        }
        gaComposer = ctx
    }
    // The composer context serialized as the exact JSON the page injects as window._gaServerCtx.
    func gaComposerJSON() -> String {
        let c = gaComposer
        let recents = c.recents.map {
            ["cwd": $0.cwd, "name": $0.name, "branch": $0.branch] as [String: Any]
        }
        let dict: [String: Any] = ["cwd": c.cwd, "name": c.name, "branch": c.branch,
                                   "effort": c.effort, "mode": c.mode, "model": c.model,
                                   "recents": recents]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // 담김 히스토리 (simple-큐): goal-add 페이지의 '담김' 목록. localStorage 는 dynamic 포트
    // (=매 실행 새 origin)에 리셋되므로 서버에 영속해야 재빌드/재시작(업데이트) 후에도 기록이
    // 남는다 — gaComposer 와 같은 이유·같은 패턴. 항목은 페이지가 쓰는 필드만 골라 담고
    // (kind/text/id/st/seq/resolved/ts) 최근 100건으로 상한.
    var gaTallyHist: [[String: Any]] {
        get { (get(K.gaTallyHist) as? [[String: Any]]) ?? [] }
        set { set(Array(newValue.suffix(100)), K.gaTallyHist) }
    }
    // 렌더 시 window._gaTallyHist 로 인라인 주입되는 JSON. 항목 text 는 사용자 입력이므로
    // "</" 를 JSON 이스케이프("<\/")로 바꿔 인라인 <script> 를 깨고 나가는 것을 막는다.
    func gaTallyHistJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: gaTallyHist),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s.replacingOccurrences(of: "</", with: "<\\/")
    }

    // The setting resolved to an actual TimeZone; invalid identifiers fall back to the
    // KST default so a hand-edited settings.json can never break rendering.
    // "system" stays an EXPLICIT, honored choice (the header selector's 시스템 (맥 설정)),
    // so only the FALLBACK moved to Asia/Seoul on 2026-09-05 — not the "system" branch.
    var displayTimeZone: TimeZone {
        let id = timeZoneID
        if id == "system" { return .current }
        return TimeZone(identifier: id) ?? TimeZone(identifier: "Asia/Seoul") ?? .current
    }
}
