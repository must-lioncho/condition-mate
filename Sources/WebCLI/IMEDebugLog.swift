import Foundation

// Diagnostic tap for the web CLI's IME handling (born in the 2026-07-12 Korean-IME/xterm
// investigation, kept as gated instrumentation). In-memory only (no disk persistence, no
// action-log noise) — a capped ring buffer fed by the CMWebCLI engine's composition tap,
// active only with ?imedebug=1 on the page URL (see WebCLITerminal.swift setupTap). The app
// exposes it via POST /api/debug/ime-log and GET /api/debug/ime-log/list (AppDelegate).
public final class IMEDebugLog {
    public static let shared = IMEDebugLog()
    private let queue = DispatchQueue(label: "cm.imedebug", qos: .utility)
    private var lines: [String] = []
    private let cap = 4000

    // POST /api/debug/ime-log body: {"events":[{...}, ...]} — each event re-encoded through a
    // key whitelist, nothing from the webview written verbatim beyond clamped strings.
    public func appendBatch(_ body: String) -> Int {
        guard let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return 0 }
        var out: [String] = []
        for e in events.prefix(500) {
            var line = "{"
            var parts: [String] = []
            if let t = (e["t"] as? NSNumber)?.doubleValue { parts.append("\"t\":\(t)") }
            for key in ["type", "key", "data", "value", "src", "inputType"] {
                if let v = e[key] as? String {
                    parts.append("\"\(key)\":\(js(String(v.prefix(400))))")
                }
            }
            if let v = (e["keyCode"] as? NSNumber)?.intValue { parts.append("\"keyCode\":\(v)") }
            if let v = e["isComposing"] as? Bool { parts.append("\"isComposing\":\(v)") }
            if let v = (e["selStart"] as? NSNumber)?.intValue { parts.append("\"selStart\":\(v)") }
            if let v = (e["selEnd"] as? NSNumber)?.intValue { parts.append("\"selEnd\":\(v)") }
            line += parts.joined(separator: ",")
            line += "}"
            out.append(line)
        }
        queue.sync {
            lines.append(contentsOf: out)
            if lines.count > cap { lines.removeFirst(lines.count - cap) }
        }
        return out.count
    }

    public func recentJSON(limit: Int = 4000) -> String {
        queue.sync {
            let tail = lines.suffix(max(1, min(limit, cap)))
            return "{\"events\":[\(tail.joined(separator: ","))]}"
        }
    }

    public func clear() { queue.sync { lines.removeAll() } }

    private func js(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}
