import Foundation

// Reads the active tab's domain from supported browsers via AppleScript
// (osascript on a background queue, so the heartbeat never blocks — and the
// one-time Automation permission prompt happens out of band).
//
// Requires the user to allow "ConditionManager wants to control <Browser>"
// (Automation). If denied, returns "" and the app simply omits site info.
enum BrowserInspector {

    // Chromium browsers expose "active tab of front window"; Safari uses
    // "current tab of front window".
    static func script(forBundleID id: String) -> String? {
        let chromium: (String) -> String = { app in
            "tell application \"\(app)\"\n"
            + "if (count of windows) > 0 then return URL of active tab of front window\n"
            + "end tell"
        }
        switch id {
        case "com.google.Chrome", "com.google.Chrome.canary": return chromium("Google Chrome")
        case "com.brave.Browser": return chromium("Brave Browser")
        case "com.microsoft.edgemac": return chromium("Microsoft Edge")
        case "company.thebrowser.Browser": return chromium("Arc")
        case "com.apple.Safari":
            return "tell application \"Safari\"\n"
                + "if (count of windows) > 0 then return URL of current tab of front window\n"
                + "end tell"
        default: return nil
        }
    }

    // Runs osascript and returns the active-tab domain (host minus "www."), or "".
    static func activeDomain(bundleID: String) -> String {
        guard let src = script(forBundleID: bundleID) else { return "" }
        let url = runOsascript(src)
        return domain(from: url)
    }

    private static func runOsascript(_ source: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func domain(from urlString: String) -> String {
        guard let u = URL(string: urlString), let host = u.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
