import Foundation

/// Capture timestamps are resolved once to an instant, never in the display timezone.
/// Legacy zone-less queue cards were written in India local time (see session store).
/// Date-only records stay dates; reading a card never rewrites its source file.
enum WorkQueueTimestamp {
    static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard s.count > 10 else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ssZ",
                       "yyyy-MM-dd'T'HH:mmZ", "yyyy-MM-dd HH:mmZ",
                       "yyyy-MM-dd-HHmm", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func utc(_ raw: String) -> String? {
        guard let d = date(raw) else { return nil }
        return ISO8601DateFormatter().string(from: d)
    }
}
