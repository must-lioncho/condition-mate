import Foundation

// Lightweight persistence of user preferences, backed by a JSON file under AppPaths.base
// (~/.condition-manager/settings.json — single store shared by dev and installed builds).
//
// WHY a file, not UserDefaults: the dev binary launched by Scripts/dev-run.sh is an
// UNBUNDLED SwiftPM executable (no Info.plist → Bundle.main.bundleIdentifier == nil).
// For such a process `UserDefaults.standard` maps to a domain cfprefsd does not persist
// reliably, and pending writes are lost when the process is killed for a rebuild — so
// plugin connections (cm.pluginFolders) silently reverted to 미연결 every rebuild. Worse,
// the dev binary (nil id) and the packaged .app (com.lioncho.conditionmanager) used
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
        static let bgmWindow      = "cm.bgmWindowEnabled"
        static let timeZone       = "cm.timeZone"
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
        K.bgmWindow: true
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

    // Base ".claude" folder whose /skills subfolder holds the user's skills. Empty/absent
    // means the ~/.claude default. Configurable from the skills page so a user can keep
    // skills in a different Claude root (e.g. a shared or per-machine location).
    var skillsRoot: String? {
        get { string(K.skillsRoot) }
        set { set(newValue, K.skillsRoot) }
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

    // Dashboard UI state blob (보기 상태 필터 · 상위 항상 표시 · 스프린트 선택 · 접기/펼치기).
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
    // and the Swift-side display formatters. "system" (default) = the machine's local
    // timezone; anything else must be an IANA identifier ("Asia/Seoul", "UTC", …).
    var timeZoneID: String {
        get { string(K.timeZone) ?? "system" }
        set { set(newValue, K.timeZone) }
    }

    // The setting resolved to an actual TimeZone; invalid identifiers fall back to local
    // so a hand-edited settings.json can never break rendering.
    var displayTimeZone: TimeZone {
        let id = timeZoneID
        if id == "system" { return .current }
        return TimeZone(identifier: id) ?? .current
    }
}
