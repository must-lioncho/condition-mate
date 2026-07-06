import Foundation

// Lightweight append-to-file logger for lifecycle/shutdown debugging. Writes timestamped,
// pid-tagged lines to <data dir>/app.log AND stderr, so "앱을 꺼도 위젯이 안 꺼진다" can be traced:
// which process launched, whether it terminated an older instance, when it began terminating,
// when the BGM window opened/closed, and when audio was muted/stopped.
//
// Read it with:  tail -f "$(cat ~/.condition-manager/…)"  — or the path AppLog.path prints once.
enum AppLog {
    private static let queue = DispatchQueue(label: "cm.applog", qos: .utility)
    static let fileURL: URL = AppPaths.base.appendingPathComponent("app.log")
    // KST (Asia/Seoul) is the reference clock for all logs, e.g. "2026-07-05 04:08:17.765 KST".
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func log(_ msg: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "\(df.string(from: Date())) KST [pid \(pid)] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let data = Data(line.utf8)
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(data)
            } else {
                // File does not exist yet — create it (and its directory).
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: fileURL)
            }
        }
    }
}
