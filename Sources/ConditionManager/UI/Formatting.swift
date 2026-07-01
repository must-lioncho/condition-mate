import Foundation

// Game-style progress formatting: cumulative hours + milestone tiers.
enum Formatting {

    // Milestone tiers that give the "I'm leveling up" feeling.
    static let milestones: [Double] = [10, 50, 100, 200, 500, 1000, 2000, 5000, 10000]

    static func hours(fromSeconds seconds: Double) -> Double {
        seconds / 3600.0
    }

    // "1,024.5h"
    static func hoursLabel(_ seconds: Double) -> String {
        let h = hours(fromSeconds: seconds)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        let s = nf.string(from: NSNumber(value: h)) ?? String(format: "%.1f", h)
        return "\(s)h"
    }

    // Next milestone above current hours, or nil once everything is cleared.
    static func nextMilestone(forSeconds seconds: Double) -> Double? {
        let h = hours(fromSeconds: seconds)
        return milestones.first { $0 > h }
    }

    // Progress text toward the next milestone, e.g. "다음 1,000h까지 75.5h 남음".
    static func milestoneProgress(forSeconds seconds: Double) -> String {
        let h = hours(fromSeconds: seconds)
        guard let next = nextMilestone(forSeconds: seconds) else {
            return "모든 마일스톤 달성"
        }
        let remain = next - h
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        let nextStr = nf.string(from: NSNumber(value: next)) ?? "\(Int(next))"
        return String(format: "다음 %@h까지 %.1fh", nextStr, remain)
    }

    // Stopwatch clock, e.g. "01:08:31".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // Relative "time ago" label from a seconds-elapsed count, e.g. "3분 전", "2시간 전",
    // "5일 전". Used for project activity recency.
    static func agoLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds))초 전" }
        if seconds < 3600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }

    // Compact status-bar label, e.g. "1024h".
    static func compactHours(_ seconds: Double) -> String {
        let h = hours(fromSeconds: seconds)
        if h >= 1000 { return String(format: "%.0fh", h) }
        return String(format: "%.1fh", h)
    }
}
