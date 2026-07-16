import Foundation
import Network

// Minimal HTTP/1.1 server on the Network framework — no third-party deps. A slimmed
// sibling of the app's DashboardServer: it accumulates chunks until the full request
// (headers + Content-Length body) has arrived, then dispatches to a single handler.
// Bind host is configurable so this standalone build can serve a real browser (not
// just loopback WKWebView) — pass "0.0.0.0" to reach it from another device on the LAN.
final class HTTPServer {
    struct Request {
        let method: String
        let path: String       // includes query string
        let body: Data
    }
    struct Response {
        var status: String = "200 OK"
        var contentType: String = "text/plain; charset=utf-8"
        var body: Data = Data()
        var extra: String = ""

        static func html(_ s: String) -> Response {
            Response(contentType: "text/html; charset=utf-8", body: Data(s.utf8))
        }
        static func json(_ s: String) -> Response {
            Response(contentType: "application/json; charset=utf-8", body: Data(s.utf8))
        }
        static func notFound() -> Response {
            Response(status: "404 Not Found", body: Data("not found".utf8))
        }
    }

    private let host: NWEndpoint.Host
    private let handler: (Request) -> Response
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "webcli.server", qos: .userInitiated)

    private static let maxRequestBytes = 8 * 1024 * 1024
    private static let headerSep = Data("\r\n\r\n".utf8)

    init(host: String, handler: @escaping (Request) -> Response) {
        self.host = NWEndpoint.Host(host)
        self.handler = handler
    }

    // Start listening on `port` (0 = any free port). onReady receives the bound port.
    func start(port: UInt16, onReady: @escaping (UInt16) -> Void) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        guard let l = try? NWListener(using: params, on: nwPort) else {
            FileHandle.standardError.write(Data("failed to open listener on port \(port)\n".utf8))
            exit(1)
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let p = l.port?.rawValue { onReady(p) }
            case .failed(let err):
                FileHandle.standardError.write(Data("listener failed: \(err)\n".utf8))
                exit(1)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = buffer
            if let chunk { acc.append(chunk) }
            if acc.count > Self.maxRequestBytes { conn.cancel(); return }

            guard let sep = acc.range(of: Self.headerSep) else {
                if isComplete || error != nil { conn.cancel() }
                else { self.receive(conn, buffer: acc) }
                return
            }
            let headerText = String(decoding: acc[acc.startIndex..<sep.lowerBound], as: UTF8.self)
            let need = Self.contentLength(headerText)
            let have = acc.distance(from: sep.upperBound, to: acc.endIndex)
            if have < need && !isComplete && error == nil {
                self.receive(conn, buffer: acc)
                return
            }
            let body = Data(acc[sep.upperBound...])
            let req = Request(method: Self.first(headerText, 0),
                              path: Self.first(headerText, 1),
                              body: body)
            let resp = self.handler(req)
            self.send(conn, resp)
        }
    }

    private func send(_ conn: NWConnection, _ resp: Response) {
        var header = "HTTP/1.1 \(resp.status)\r\n"
        header += "Content-Type: \(resp.contentType)\r\n"
        header += "Content-Length: \(resp.body.count)\r\n"
        header += resp.extra
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // Parse the request line: index 0 = method, 1 = path.
    private static func first(_ header: String, _ idx: Int) -> String {
        guard let line = header.split(separator: "\r\n", maxSplits: 1).first else { return idx == 0 ? "GET" : "/" }
        let parts = line.split(separator: " ")
        return parts.count > idx ? String(parts[idx]) : (idx == 0 ? "GET" : "/")
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
}
