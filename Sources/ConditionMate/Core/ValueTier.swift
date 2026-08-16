import Foundation

// Weighted "value" of work, by activity type. Time is multiplied by the tier
// multiplier to produce a value score that rewards active ideation over
// passive consumption.
//
//   소극 (passive, 1x): watching / casual browsing (e.g. YouTube)
//   중간 (mid, 3x):     research tools — ChatGPT / Gemini / Genspark, docs apps
//   적극 (active, 5x):  editors / deep work — Cursor, VSCode, Xcode, terminals
struct ValueTier {
    let key: String
    let label: String
    let multiplier: Int

    static let passive = ValueTier(key: "passive", label: "소극", multiplier: 1)
    static let mid      = ValueTier(key: "mid",     label: "중간", multiplier: 3)
    static let active   = ValueTier(key: "active",  label: "적극", multiplier: 5)

    // Editor / deep-work apps => active (집중).
    static let editorApps: Set<String> = [
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.microsoft.VSCode", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.jetbrains.intellij", "com.sublimetext.4",
        "com.anthropic.claudefordesktop", "com.anthropic.claude-code",  // Claude
    ]
    // Browser apps — value depends on the active site.
    static let browserApps: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
    ]
    // Docs / writing + communication apps => mid (책상).
    static let midApps: Set<String> = [
        "notion.id", "md.obsidian", "com.apple.Notes", "com.microsoft.Word",
        // communication => desk
        "com.tinyspeck.slackmacgap",                       // Slack
        "ru.keepcoder.Telegram", "org.telegram.desktop",   // Telegram
        "com.kakao.KakaoTalkMac",                          // KakaoTalk
    ]
    // Research + communication sites (mid) — substring match on host.
    static let midSites = [
        "chatgpt.com", "chat.openai.com", "gemini.google.com", "genspark.ai",
        "perplexity.ai", "bard.google.com", "poe.com", "phind.com",
        "you.com", "copilot.microsoft.com",
        // communication web => desk
        "slack.com", "web.telegram.org", "web.whatsapp.com",
    ]
    // Active context in a browser (집중): local dev + Claude.
    static let activeSites = [
        "github.dev", "vscode.dev", "stackblitz.com", "replit.com",
        "127.0.0.1", "localhost", "claude.ai",
    ]

    // Our own app (main window + follow-up windows) counts as active (집중):
    // deliberately engaging with the tracker is focused work, not rest.
    static let ownAppPrefix = "com.lioncho.conditionmate"

    static func classify(bundleID: String, site: String) -> ValueTier {
        if bundleID.hasPrefix(ownAppPrefix) { return .active }
        if editorApps.contains(bundleID) { return .active }
        if browserApps.contains(bundleID) {
            let host = site.lowercased()
            if !host.isEmpty {
                if activeSites.contains(where: { host.contains($0) }) { return .active }
                if midSites.contains(where: { host.contains($0) }) { return .mid }
            }
            return .passive // default browsing / watching
        }
        if midApps.contains(bundleID) { return .mid }
        return .passive
    }

    static func isBrowser(_ bundleID: String) -> Bool { browserApps.contains(bundleID) }

    // Meeting / call context — counts toward total time even without input,
    // but not toward desk or focus (you're not building).
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.cisco.webexmeetingsapp", "com.hnc.Discord",
    ]
    static let meetingSites = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "whereby.com", "around.co", "gather.town",
    ]
    static func isMeeting(bundleID: String, site: String) -> Bool {
        if meetingApps.contains(bundleID) { return true }
        let host = site.lowercased()
        return !host.isEmpty && meetingSites.contains { host.contains($0) }
    }
}
