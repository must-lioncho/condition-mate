import Foundation
import Network

// A held-open Server-Sent-Events connection. Unlike every other response (one-shot,
// Content-Length, Connection: close), an SSE connection stays open and the app pushes
// `data:` frames as events arrive. Used by the streaming goal chat (chat2). All sends
// hop onto the server queue so they never race the close.
final class SSEChannel {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    // Called once when the connection drops (client navigated away / network) so the
    // app can drop this channel from its registry.
    var onClose: (() -> Void)?

    init(conn: NWConnection, queue: DispatchQueue) { self.conn = conn; self.queue = queue }

    // Push one event carrying a single-line JSON payload (no raw newlines — JSON-encode).
    func event(_ json: String) { raw("data: " + json + "\n\n") }

    func raw(_ s: String) {
        queue.async {
            guard !self.closed else { return }
            self.conn.send(content: Data(s.utf8), completion: .contentProcessed { err in
                if err != nil { self.close() }
            })
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.conn.cancel()
            self.onClose?()
            self.onClose = nil
        }
    }
}

// Minimal loopback-only HTTP server (Network framework, no deps). Started on
// demand from "대시보드 열기"; serves:
//   GET  /                       -> dashboard HTML
//   GET  /data.json              -> today's activity JSON
//   GET  /live.json              -> tiny real-time payload (APM gauge, ~250ms polling)
//   GET  /api/loop/queue         -> JSON worklist of loop-eligible (backlog) goals
//   GET  /evidence/<g>/<e>       -> a stored evidence file (binary download)
//   GET  /transcript?goal=<id>   -> readable HTML view of a session's transcript
//   GET  /breakdown?goal=<id>    -> minute-by-minute tool/token analysis of a session
//   GET  /goal?n=<NN>            -> one goal's page (definition goal.md + attachments)
//   POST /api/*                  -> JSON command endpoints
// Bound to 127.0.0.1 so nothing on the LAN can reach it.
final class DashboardServer {

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var onReady: ((UInt16) -> Void)?

    private let html: () -> String
    private let data: () -> String
    private let live: () -> String                  // tiny real-time payload for /live.json (1Hz polling)
    private let post: (String, String) -> String   // (path, body) -> JSON response
    // (path) -> (bytes, contentType, downloadName) for binary GETs; nil = 404.
    private let file: (String) -> (Data, String, String)?
    // (full path incl. query) -> readable HTML page, or nil = 404. Used by /transcript.
    private let page: (String) -> String?
    // () -> JSON worklist of loop-eligible (backlog) goals. Read by an external auto-loop
    // that pulls 대기 goals and skips 중지/취소. See /api/loop/queue below.
    private let loopFeed: () -> String
    // () -> JSON of the chat conversation (messages + session). Read by GET /api/chat
    // when the chat panel opens and after each send (NOT in the 5s data poll).
    private let chat: () -> String
    // (full path incl. query) -> JSON for dynamic GET /api/* endpoints (e.g. a per-goal
    // chat keyed by ?seq=). nil = not handled here (falls through to 404/default).
    private let apiGet: (String) -> String?
    // (full path incl. query, channel) -> register a held-open SSE channel for the
    // streaming goal chat. The app pushes events to the channel until it closes.
    private let sse: (String, SSEChannel) -> Void
    private let queue = DispatchQueue(label: "cm.dashboard", qos: .utility)

    // Hard cap on a single request (headers + body). Evidence uploads arrive as
    // base64 (~33% larger than the file), so this bounds the on-disk file to ~48MB.
    private static let maxRequestBytes = 64 * 1024 * 1024
    private static let headerSep = Data("\r\n\r\n".utf8)

    init(html: @escaping () -> String,
         data: @escaping () -> String,
         live: @escaping () -> String = { "{}" },
         post: @escaping (String, String) -> String = { _, _ in "{}" },
         file: @escaping (String) -> (Data, String, String)? = { _ in nil },
         page: @escaping (String) -> String? = { _ in nil },
         loopFeed: @escaping () -> String = { "{}" },
         chat: @escaping () -> String = { "{}" },
         apiGet: @escaping (String) -> String? = { _ in nil },
         sse: @escaping (String, SSEChannel) -> Void = { _, _ in }) {
        self.html = html
        self.data = data
        self.live = live
        self.post = post
        self.file = file
        self.page = page
        self.loopFeed = loopFeed
        self.chat = chat
        self.apiGet = apiGet
        self.sse = sse
    }

    var isRunning: Bool { listener != nil }

    func start(onReady: @escaping (UInt16) -> Void) {
        if let listener, listener.state == .ready, port != 0 {
            onReady(port)
            return
        }
        self.onReady = onReady
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else { return }

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = l.port?.rawValue {
                self.port = p
                // Publish the (dynamic) port so external tooling — notably the
                // Claude Code session hooks — can reach the loopback API without
                // guessing. Plain text, single integer, overwritten each launch.
                let portFile = AppPaths.base.appendingPathComponent("dashboard.port")
                try? String(p).write(to: portFile, atomically: true, encoding: .utf8)
                self.onReady?(p)
                self.onReady = nil
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    // Accumulate chunks until the full request (headers + Content-Length body) has
    // arrived. The previous single 8KB read truncated file uploads; this reads the
    // whole request so base64 payloads of any size (up to maxRequestBytes) survive.
    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let chunk { acc.append(chunk) }

            if acc.count > Self.maxRequestBytes { conn.cancel(); return }

            // Wait until the header block is complete.
            guard let sep = acc.range(of: Self.headerSep) else {
                if isComplete || error != nil { conn.cancel() }   // closed/malformed
                else { self.receiveRequest(conn, buffer: acc) }
                return
            }
            let headerText = String(decoding: acc[acc.startIndex..<sep.lowerBound], as: UTF8.self)
            let need = Self.contentLength(headerText)
            let have = acc.distance(from: sep.upperBound, to: acc.endIndex)
            if have < need && !isComplete && error == nil {
                self.receiveRequest(conn, buffer: acc)            // body still arriving
                return
            }
            let body = Data(acc[sep.upperBound...])
            self.respond(conn, headerText: headerText, body: body)
        }
    }

    private func respond(_ conn: NWConnection, headerText: String, body reqBody: Data) {
        let method = Self.parseMethod(headerText)
        let path = Self.parsePath(headerText)

        if method == "GET" && path.hasPrefix("/api/goal/chat2/stream") {
            // Held-open SSE stream for the streaming chat. Must be checked BEFORE the
            // generic /api/goal/chat GET branch (which would otherwise swallow it).
            startSSE(conn, path: path)
        } else if method == "POST" && path.hasPrefix("/api/") {
            let json = self.post(path, String(decoding: reqBody, as: UTF8.self))
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(json.utf8), extra: "")
        } else if method == "GET" && path.hasPrefix("/evidence/") {
            if let (bytes, ctype, name) = self.file(path) {
                let extra = "Content-Disposition: attachment; filename=\"\(Self.sanitizeHeader(name))\"\r\n"
                send(conn, status: "200 OK", contentType: ctype, body: bytes, extra: extra)
            } else {
                send(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                     body: Data("not found".utf8), extra: "")
            }
        } else if method == "GET" && path.hasPrefix("/chat-img/") {
            // Chat image attachment: inline (not a download) so the bubble can show it.
            if let (bytes, ctype, _) = self.file(path) {
                send(conn, status: "200 OK", contentType: ctype, body: bytes, extra: "")
            } else {
                send(conn, status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                     body: Data("not found".utf8), extra: "")
            }
        } else if method == "GET" && (path.hasPrefix("/api/goal/chat") || path.hasPrefix("/api/goal/definition")
                                      || path.hasPrefix("/api/goal/sessions") || path.hasPrefix("/api/sessions/recent")
                                      || path.hasPrefix("/api/cli/sessions") || path.hasPrefix("/api/skills")
                                      || path.hasPrefix("/history.json")) {
            // Per-goal chat, the raw core/detail definition text, the goal's linked-session
            // list, the recent-session picker feed (all keyed by ?seq=), and the 히스토리
            // tab's per-day activity feed. Dynamic, so routed via apiGet.
            let json = self.apiGet(path) ?? "{\"messages\":[]}"
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(json.utf8), extra: "")
        } else if method == "GET" && path.hasPrefix("/api/chat") {
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(self.chat().utf8), extra: "")
        } else if method == "GET" && path.hasPrefix("/api/loop/queue") {
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(self.loopFeed().utf8), extra: "")
        } else if path.hasPrefix("/live.json") {
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(self.live().utf8), extra: "")
        } else if path.hasPrefix("/data.json") {
            send(conn, status: "200 OK", contentType: "application/json; charset=utf-8",
                 body: Data(self.data().utf8), extra: "")
        } else if method == "GET" && (path.hasPrefix("/transcript") || path.hasPrefix("/breakdown") || path.hasPrefix("/worker") || path.hasPrefix("/goal")) {
            if let pageHTML = self.page(path) {
                send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                     body: Data(pageHTML.utf8), extra: "")
            } else {
                send(conn, status: "404 Not Found", contentType: "text/html; charset=utf-8",
                     body: Data("<h1>not found</h1>".utf8), extra: "")
            }
        } else {
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(self.html().utf8), extra: "")
        }
    }

    // Open an SSE stream: send the streaming headers (no Content-Length, keep alive),
    // hand a channel to the app to push events, and watch for the client closing.
    private func startSSE(_ conn: NWConnection, path: String) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: keep-alive\r\n"
        header += "X-Accel-Buffering: no\r\n\r\n"
        let channel = SSEChannel(conn: conn, queue: queue)
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] err in
            guard let self else { channel.close(); return }
            if err != nil { channel.close(); return }
            channel.raw(": connected\n\n")    // initial comment flushes the stream open
            self.sse(path, channel)
        })
        drainForClose(conn, channel)
    }

    // SSE is one-way (server -> client), but we keep reading so a client disconnect
    // (EOF/error) is detected promptly and the channel is torn down.
    private func drainForClose(_ conn: NWConnection, _ channel: SSEChannel) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { channel.close(); return }
            self?.drainForClose(conn, channel)
        }
    }

    private func send(_ conn: NWConnection, status: String, contentType: String, body: Data, extra: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += extra
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func parsePath(_ request: String) -> String {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return "/" }
        let parts = firstLine.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    private static func parseMethod(_ request: String) -> String {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first,
              let m = firstLine.split(separator: " ").first else { return "GET" }
        return String(m)
    }

    private static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    // Strip characters that would break or inject into the Content-Disposition header.
    private static func sanitizeHeader(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" }.map(Character.init))
    }
}
