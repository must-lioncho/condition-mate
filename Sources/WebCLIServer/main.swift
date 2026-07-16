import Foundation

// webcli — a standalone web terminal that runs interactive `claude` (or any command)
// in a PTY and bridges it to a real browser over HTTP polling. It reuses the app's
// WebCLI target verbatim: PtySession for the PTY and WebCLITerminal.script() for the
// in-page xterm engine (Korean IME takeover, fonts, polling protocol). Unlike the
// in-app dashboard (WKWebView, loopback only), this serves a normal browser.
//
// Usage:
//   webcli [--port N] [--dir PATH] [--cmd "claude ..."] [--host H] [--label TEXT]
//   --port   listen port (default 7333; 0 = pick a free port)
//   --dir    working directory the command runs in (default: current directory)
//   --cmd    full command line to run in the PTY (default: "claude")
//   --host   bind address (default 127.0.0.1; use 0.0.0.0 to expose on the LAN)
//   --label  header title shown in the page (default: "CLI 세션")

func argValue(_ name: String, default def: String) -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}

let defaultDir = FileManager.default.currentDirectoryPath
let dir = (argValue("--dir", default: defaultDir) as NSString).expandingTildeInPath
let command = argValue("--cmd", default: "claude")
let host = argValue("--host", default: "127.0.0.1")
let label = argValue("--label", default: "CLI 세션")
let port = UInt16(argValue("--port", default: "7333")) ?? 7333

let registry = CLIRegistry(command: command)

// Decode a JSON body into a dictionary; missing/invalid bodies yield an empty map.
func jsonBody(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
func u16(_ any: Any?, _ def: UInt16) -> UInt16 {
    if let n = any as? Int { return UInt16(clamping: n) }
    if let d = any as? Double { return UInt16(clamping: Int(d)) }
    return def
}

let server = HTTPServer(host: host) { req in
    switch (req.method, req.path) {
    case ("GET", let p) where p == "/" || p.hasPrefix("/?"):
        return .html(WebCLIPage.html(label: label, cwd: dir))

    case ("POST", "/api/cli/start"):
        let b = jsonBody(req.body)
        let cwd = (b["cwd"] as? String) ?? dir
        return .json(registry.start(cwd: cwd, cols: u16(b["cols"], 80), rows: u16(b["rows"], 24)))

    case ("POST", "/api/cli/io"):
        let b = jsonBody(req.body)
        let token = (b["token"] as? String) ?? ""
        let since = (b["since"] as? Int) ?? Int((b["since"] as? Double) ?? 0)
        let input = (b["input"] as? String) ?? ""
        return .json(registry.io(token: token, inputB64: input, since: since))

    case ("POST", "/api/cli/resize"):
        let b = jsonBody(req.body)
        registry.resize(token: (b["token"] as? String) ?? "", cols: u16(b["cols"], 80), rows: u16(b["rows"], 24))
        return .json("{\"ok\":true}")

    case ("POST", "/api/debug/ime-log"):
        // The engine posts here only under ?imedebug=1 — accept and drop.
        return .json("{\"ok\":true}")

    default:
        return .notFound()
    }
}

// Reap idle/dead PTYs every 5 minutes so a long-running server stays clean.
let reaper = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
reaper.schedule(deadline: .now() + 300, repeating: 300)
reaper.setEventHandler { registry.reapIdle() }
reaper.resume()

// Tear down live PTYs on Ctrl-C so no orphaned claude processes linger.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { registry.terminateAll(); exit(0) }
sigint.resume()

server.start(port: port) { boundPort in
    let shown = host == "0.0.0.0" ? "127.0.0.1" : host
    print("webcli listening — open http://\(shown):\(boundPort)/")
    print("  command: \(command)")
    print("  dir:     \(dir)")
}

dispatchMain()
