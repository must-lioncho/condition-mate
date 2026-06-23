import Foundation

// Lightweight persistence of user preferences via UserDefaults.
// Kept tiny: no observation framework, just plain getters/setters.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

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
    }

    private init() {
        // Register defaults once. Values the user has not touched fall back here.
        d.register(defaults: [
            K.minBPM: 70.0,
            K.maxBPM: 150.0,
            K.releaseMinutes: 5.0,
            K.idleSeconds: 60.0,
            K.idleAmbient: true,
            K.idleVolScale: 0.5,
            K.musicEnabled: true,
            K.trackingEnabled: true,
            K.volume: 0.8
        ])
    }

    var musicFolderPath: String? {
        get { d.string(forKey: K.musicFolder) }
        set { d.set(newValue, forKey: K.musicFolder) }
    }

    var trackedApps: [String] {
        get { d.stringArray(forKey: K.trackedApps) ?? [] }
        set { d.set(newValue, forKey: K.trackedApps) }
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
        get { (d.dictionary(forKey: K.appProfiles) as? [String: String]) ?? [:] }
        set { d.set(newValue, forKey: K.appProfiles) }
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

    var minBPM: Double {
        get { d.double(forKey: K.minBPM) }
        set { d.set(newValue, forKey: K.minBPM) }
    }
    var maxBPM: Double {
        get { d.double(forKey: K.maxBPM) }
        set { d.set(newValue, forKey: K.maxBPM) }
    }
    var releaseMinutes: Double {
        get { d.double(forKey: K.releaseMinutes) }
        set { d.set(newValue, forKey: K.releaseMinutes) }
    }
    var idleSeconds: Double {
        get { d.double(forKey: K.idleSeconds) }
        set { d.set(newValue, forKey: K.idleSeconds) }
    }
    // When idle, play slow ambient music instead of going silent.
    var idleAmbientEnabled: Bool {
        get { d.bool(forKey: K.idleAmbient) }
        set { d.set(newValue, forKey: K.idleAmbient) }
    }
    // Volume multiplier applied to the base volume while in ambient idle (0...1).
    var idleVolumeScale: Double {
        get { d.double(forKey: K.idleVolScale) }
        set { d.set(newValue, forKey: K.idleVolScale) }
    }
    var musicEnabled: Bool {
        get { d.bool(forKey: K.musicEnabled) }
        set { d.set(newValue, forKey: K.musicEnabled) }
    }
    var trackingEnabled: Bool {
        get { d.bool(forKey: K.trackingEnabled) }
        set { d.set(newValue, forKey: K.trackingEnabled) }
    }
    var volume: Double {
        get { d.double(forKey: K.volume) }
        set { d.set(newValue, forKey: K.volume) }
    }
}
