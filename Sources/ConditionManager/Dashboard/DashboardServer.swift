import Foundation
import Network

// Minimal loopback-only HTTP server (Network framework, no deps). Started on
// demand from "대시보드 열기"; serves exactly two routes:
//   GET /            -> dashboard HTML
//   GET /data.json   -> today's activity JSON
// Bound to 127.0.0.1 so nothing on the LAN can reach it.
final class DashboardServer {

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var onReady: ((UInt16) -> Void)?

    private let html: () -> String
    private let data: () -> String
    private let post: (String, String) -> String   // (path, body) -> JSON response
    private let queue = DispatchQueue(label: "cm.dashboard", qos: .utility)

    init(html: @escaping () -> String,
         data: @escaping () -> String,
         post: @escaping (String, String) -> String = { _, _ in "{}" }) {
        self.html = html
        self.data = data
        self.post = post
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = chunk.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let method = Self.parseMethod(request)
            let path = Self.parsePath(request)

            let body: String
            let type: String
            if method == "POST" && path.hasPrefix("/api/") {
                let reqBody = Self.parseBody(request)
                body = self.post(path, reqBody)
                type = "application/json; charset=utf-8"
            } else if path.hasPrefix("/data.json") {
                body = self.data()
                type = "application/json; charset=utf-8"
            } else {
                body = self.html()
                type = "text/html; charset=utf-8"
            }
            let bodyData = body.data(using: .utf8) ?? Data()

            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(type)\r\n"
            header += "Content-Length: \(bodyData.count)\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"

            var response = Data(header.utf8)
            response.append(bodyData)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
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

    private static func parseBody(_ request: String) -> String {
        guard let range = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[range.upperBound...])
    }
}
