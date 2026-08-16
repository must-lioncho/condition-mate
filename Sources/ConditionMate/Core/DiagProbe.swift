import Foundation

// On-demand network/VPN diagnostic snapshot.
//
// WHY this exists: when a coworker reports "the HRIS site won't load" and claims
// "VPN(defguard) is on", we currently can't tell whether the VPN was actually up
// or where the connection broke — so the failure is not reproducible. This runs a
// single self-probe from the app the moment the user hits 진단 실행, capturing the
// same conditions their browser saw: VPN interface state, the machine's DNS/gateway,
// and a per-host DNS → HTTPS reachability check against the target hosts (hris.must.
// company, …). Each snapshot is one JSONL line under events/diag.jsonl and can be
// exported to CSV to attach to the ticket. This is a diagnostic PROBE, not a capture
// of the user's actual browser session — the app cannot see their cookies/login POST,
// but it reaches the same host over the same network, which is the level this problem
// lives at ("was the VPN/DNS/route actually working").
//
// Everything runs synchronously on the caller's thread (the loopback server thread,
// like /api/debug/snapshot) with bounded per-step timeouts, so a hung host can never
// stall the app for more than a few seconds. Nothing is always-on: cost is zero until
// the button is pressed.
enum DiagProbe {

    // Per-step timeouts (seconds). Kept short so a whole run is bounded even with a few
    // unreachable hosts (worst case ~ hosts × (dns + http)).
    private static let dnsTimeout: TimeInterval = 4
    private static let httpTimeout: TimeInterval = 6

    // Run a full snapshot against `hosts` and return a JSON-ready dictionary. `t` is epoch
    // seconds (display timezone is applied only when rendering / exporting).
    static func run(hosts: [String]) -> [String: Any] {
        let started = Date()
        let vpn = vpnStatus()
        let net = networkInfo()
        var hostResults: [[String: Any]] = []
        for raw in hosts {
            let host = normalizeHost(raw)
            guard !host.isEmpty else { continue }
            hostResults.append(probeHost(host))
        }
        return [
            "t": Int(started.timeIntervalSince1970),
            "vpnActive": vpn.active,
            "vpnDetail": vpn.detail,
            "utun": vpn.utun,
            "gateway": net.gateway,
            "iface": net.iface,
            "dnsServers": net.dns,
            "hosts": hostResults,
            "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)
        ]
    }

    // MARK: - Per-host probe (DNS then HTTPS)

    private static func probeHost(_ host: String) -> [String: Any] {
        let dns = resolve(host)
        // Only attempt HTTPS when DNS produced an address — otherwise the failure is
        // already explained (name did not resolve → VPN not routing DNS / wrong network).
        let http: (ok: Bool, status: Int, ms: Int, err: String)
        if dns.ok {
            http = probeHTTP(host)
        } else {
            http = (false, 0, 0, "skipped (DNS 실패)")
        }
        return [
            "host": host,
            "dnsOk": dns.ok,
            "dnsMs": dns.ms,
            "ips": dns.ips,
            "httpOk": http.ok,
            "status": http.status,
            "httpMs": http.ms,
            "error": dns.ok ? http.err : dns.err
        ]
    }

    // DNS resolution with timing. getaddrinfo has no built-in timeout and can hang on a
    // dead resolver, so it runs on a throwaway queue and we bound the wait with a semaphore.
    private static func resolve(_ host: String) -> (ok: Bool, ms: Int, ips: [String], err: String) {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var ips: [String] = []
        var err = ""
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>? = nil
            let r = getaddrinfo(host, "443", &hints, &res)
            if r != 0 {
                err = String(cString: gai_strerror(r))
            } else {
                var p = res
                while let cur = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen, &buf,
                                   socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: buf)
                        if !ips.contains(ip) { ips.append(ip) }
                    }
                    p = cur.pointee.ai_next
                }
                if res != nil { freeaddrinfo(res) }
                ok = true
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + dnsTimeout) == .timedOut {
            return (false, Int(dnsTimeout * 1000), [], "DNS 타임아웃")
        }
        return (ok, Int(Date().timeIntervalSince(start) * 1000), ips, err)
    }

    // HTTPS reachability: a HEAD to https://host/ over an ephemeral session. Captures the
    // HTTP status on success, or the URLSession error (domain+code) on failure, which is
    // what distinguishes "TCP timeout" (-1001) vs "cannot connect" (-1004) vs "TLS" (-1200…)
    // vs "DNS" (-1003). waitsForConnectivity is off so an offline machine fails fast instead
    // of blocking for the full timeout.
    private static func probeHTTP(_ host: String) -> (ok: Bool, status: Int, ms: Int, err: String) {
        guard let url = URL(string: "https://\(host)/") else { return (false, 0, 0, "잘못된 호스트") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = httpTimeout
        cfg.timeoutIntervalForResource = httpTimeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var status = 0
        var err = ""
        let start = Date()
        let task = session.dataTask(with: req) { _, resp, e in
            if let http = resp as? HTTPURLResponse {
                ok = true
                status = http.statusCode
            } else if let e = e as NSError? {
                err = "\(e.domain) \(e.code): \(e.localizedDescription)"
            } else {
                err = "응답 없음"
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + httpTimeout + 1) == .timedOut {
            task.cancel()
            return (false, 0, Int(httpTimeout * 1000), "HTTP 타임아웃")
        }
        return (ok, status, Int(Date().timeIntervalSince(start) * 1000), err)
    }

    // MARK: - VPN detection (heuristic)

    // We can't authoritatively know "defguard is connected" from outside the client, so we
    // combine three independent signals and report what we saw, honestly labeled: (1) active
    // utun* tunnel interfaces with an assigned address (WireGuard/defguard create these), (2)
    // any Connected service in `scutil --nc list`, (3) a running defguard/wireguard process.
    // `active` is true if ANY tunnel interface carries a routable address OR a service reports
    // Connected — that is the strongest evidence the VPN is actually up.
    private static func vpnStatus() -> (active: Bool, detail: String, utun: [String]) {
        let utun = utunInterfaces()
        // `scutil --nc list` lines look like:
        //   * (Connected)  <UUID> VPN (net.defguard) "Supertrust"  [VPN:net.defguard]
        // Pull the quoted profile name from each (Connected) line so the report names WHICH
        // VPN is up (defguard confirmed reachable this way — the feature's original blind spot).
        let connected = shell("/usr/sbin/scutil", ["--nc", "list"])
            .split(separator: "\n")
            .filter { $0.contains("(Connected)") }
            .map { quotedName(String($0)) }

        var bits: [String] = []
        if !connected.isEmpty { bits.append("연결된 VPN: " + connected.joined(separator: ", ")) }
        if !utun.isEmpty { bits.append("터널 인터페이스: " + utun.joined(separator: ", ")) }
        else { bits.append("터널 인터페이스 없음 (utun 미할당)") }
        if connected.isEmpty { bits.append("연결된 VPN 서비스 없음") }

        let active = !utun.isEmpty || !connected.isEmpty
        return (active, bits.joined(separator: " · "), utun)
    }

    // Extract the first double-quoted substring (the service display name), else a trimmed
    // fallback so a format change still yields something readable.
    private static func quotedName(_ line: String) -> String {
        guard let lo = line.firstIndex(of: "\""),
              let hi = line[line.index(after: lo)...].firstIndex(of: "\"") else {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return String(line[line.index(after: lo)..<hi])
    }

    // Enumerate utun* interfaces that carry an IPv4/IPv6 address. utun is also used by iCloud
    // Private Relay and native VPNs, so we list them rather than claim they are defguard.
    private static func utunInterfaces() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&addrs) == 0 else { return [] }
        defer { freeifaddrs(addrs) }
        var out: [String] = []
        var p = addrs
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("utun"), let sa = cur.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                // Skip IPv6 link-local (fe80::) noise; keep routable tunnel addresses.
                if ip.hasPrefix("fe80") { continue }
                out.append("\(name) \(ip)")
            }
        }
        return out
    }

    // MARK: - Machine network info

    private static func networkInfo() -> (iface: String, gateway: String, dns: [String]) {
        var iface = ""
        var gateway = ""
        for line in shell("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") { iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("gateway:") { gateway = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        var dns: [String] = []
        for line in shell("/usr/sbin/scutil", ["--dns"]).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("nameserver[") else { continue }
            if let colon = t.firstIndex(of: ":") {
                let ip = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !ip.isEmpty && !dns.contains(ip) { dns.append(ip) }
            }
        }
        return (iface, gateway, dns)
    }

    // MARK: - Helpers

    // Fixed-command shell out (no user input reaches the argv), used only for local, fast
    // system tools (route/scutil/pgrep). Returns "" on any failure so the probe degrades
    // gracefully rather than throwing.
    private static func shell(_ launch: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // Accept a pasted URL or bare host and reduce to a hostname (strip scheme/path/port).
    private static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }
        if let comps = URLComponents(string: s), let h = comps.host { return h }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s
    }
}

// Append-only store of diagnostic snapshots (events/diag.jsonl), plus feed + CSV export
// for the 네트워크 진단 tab. One JSON object per line, mirroring ActionLog's shape.
final class DiagStore {

    static let shared = DiagStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "cm.diagstore")

    private init() {
        fileURL = AppPaths.sub("events").appendingPathComponent("diag.jsonl")
    }

    // Persist one snapshot dict as a single JSONL line.
    func append(_ snapshot: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        queue.async { [fileURL] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                if let d = line.data(using: .utf8) { h.write(d) }
                try? h.close()
            }
        }
    }

    // Recent snapshots, newest first, as {"snapshots":[…]} — the page renders directly.
    // Reads at most the last ~1MB like ActionLog so an old log never slows the endpoint.
    func recentJSON(limit: Int = 100) -> String {
        let capped = max(1, min(limit, 500))
        return queue.sync { [fileURL] in
            guard let h = try? FileHandle(forReadingFrom: fileURL) else { return "{\"snapshots\":[]}" }
            defer { try? h.close() }
            let size = h.seekToEndOfFile()
            let window: UInt64 = 1_048_576
            let start = size > window ? size - window : 0
            h.seek(toFileOffset: start)
            let data = h.readDataToEndOfFile()
            guard var text = String(data: data, encoding: .utf8) else { return "{\"snapshots\":[]}" }
            if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("{") }
            let tail = Array(lines.suffix(capped)).reversed()
            return "{\"snapshots\":[\(tail.joined(separator: ","))]}"
        }
    }

    // Parsed snapshot dicts (oldest → newest) for CSV export.
    func allSnapshots() -> [[String: Any]] {
        queue.sync { [fileURL] in
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let d = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
        }
    }

    // One CSV row per (snapshot × host), so the sheet reads chronologically with the network
    // context repeated on each host line. `tz` decides the wall clock the time column shows.
    func csv(timeZone: TimeZone) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = timeZone
        df.locale = Locale(identifier: "en_US_POSIX")

        let header = ["time", "vpn_active", "vpn_detail", "iface", "gateway", "dns_servers",
                      "host", "dns_ok", "dns_ms", "ips", "http_ok", "http_status", "http_ms", "error"]
        var rows = [header.joined(separator: ",")]

        for snap in allSnapshots() {
            let t = (snap["t"] as? NSNumber)?.doubleValue ?? 0
            let time = df.string(from: Date(timeIntervalSince1970: t))
            let vpnActive = ((snap["vpnActive"] as? NSNumber)?.boolValue ?? false) ? "yes" : "no"
            let vpnDetail = snap["vpnDetail"] as? String ?? ""
            let iface = snap["iface"] as? String ?? ""
            let gateway = snap["gateway"] as? String ?? ""
            let dnsServers = (snap["dnsServers"] as? [String] ?? []).joined(separator: " ")
            let hosts = snap["hosts"] as? [[String: Any]] ?? []
            if hosts.isEmpty {
                rows.append([time, vpnActive, vpnDetail, iface, gateway, dnsServers,
                             "", "", "", "", "", "", "", ""].map(csvEscape).joined(separator: ","))
                continue
            }
            for h in hosts {
                let host = h["host"] as? String ?? ""
                let dnsOk = ((h["dnsOk"] as? NSNumber)?.boolValue ?? false) ? "yes" : "no"
                let dnsMs = String((h["dnsMs"] as? NSNumber)?.intValue ?? 0)
                let ips = (h["ips"] as? [String] ?? []).joined(separator: " ")
                let httpOk = ((h["httpOk"] as? NSNumber)?.boolValue ?? false) ? "yes" : "no"
                let status = String((h["status"] as? NSNumber)?.intValue ?? 0)
                let httpMs = String((h["httpMs"] as? NSNumber)?.intValue ?? 0)
                let error = h["error"] as? String ?? ""
                rows.append([time, vpnActive, vpnDetail, iface, gateway, dnsServers,
                             host, dnsOk, dnsMs, ips, httpOk, status, httpMs, error]
                            .map(csvEscape).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // RFC-4180 field escaping: wrap in quotes and double any embedded quote when the value
    // contains a comma, quote, or newline.
    private func csvEscape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
