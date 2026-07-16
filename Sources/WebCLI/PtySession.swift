import Foundation
import Darwin

// A pseudo-terminal running an interactive process (claude), bridged to the web
// dashboard over plain HTTP polling — the server is one-shot per connection, so
// there is no WebSocket. The in-page xterm.js terminal writes keystrokes via
// write(_:) and pulls new output via read(since:); output is buffered with a
// monotonic byte offset so the client resumes cleanly after each poll. This is
// what lets the CLI run inside the web page instead of a native Terminal window.
public final class PtySession {
    public let token = UUID().uuidString
    private let master: Int32
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()       // output bytes from baseOffset onward
    private var baseOffset = 0        // bytes dropped off the front (sliding window)
    private var readSource: DispatchSourceRead?
    private var aliveFlag = true
    public private(set) var lastTouched = Date()

    // Keep the live tail bounded; a long session would otherwise grow without limit.
    private static let maxBuffer = 4 * 1024 * 1024

    // Spawn `command` (a full shell command line, e.g. a quoted claude + flags) inside a
    // fresh PTY sized cols×rows, running in `cwd`. Returns nil if the PTY or process fails.
    public init?(command: String, cwd: String, cols: UInt16, rows: UInt16) {
        var m: Int32 = 0, s: Int32 = 0
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &win) == 0 else {
            WebCLILog.log("cli pty openpty failed errno=\(errno) cwd=\(cwd)")
            return nil
        }
        master = m

        // Login shell so PATH/profile match an ordinary terminal; exec so claude becomes
        // the controlling process of the PTY rather than a bash child.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "exec \(command)"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["TERM"] = "xterm-256color"
        process.environment = env

        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.aliveFlag = false; self.lock.unlock()
        }
        do { try process.run() } catch {
            // Most commonly the cwd no longer exists (e.g. a resumed session whose recorded
            // working directory was removed by a data-store move) — log it so the otherwise
            // silent "pty-failed" the dashboard shows can be traced.
            WebCLILog.log("cli pty run failed cwd=\(cwd) err=\(error.localizedDescription)")
            close(m); close(s); return nil
        }
        close(s)   // the child holds the slave; the parent only needs the master

        // Drain the master into the buffer as output arrives.
        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(self.master, &buf, buf.count)
            if n > 0 {
                self.append(Data(buf[0..<n]))
            } else {                       // EOF or error: child is gone
                self.lock.lock(); self.aliveFlag = false; self.lock.unlock()
                self.readSource?.cancel()
            }
        }
        src.resume()
        readSource = src
    }

    public var alive: Bool { lock.lock(); defer { lock.unlock() }; return aliveFlag }

    private func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        if buffer.count > Self.maxBuffer {
            let drop = buffer.count - Self.maxBuffer
            buffer.removeFirst(drop)
            baseOffset += drop
        }
    }

    // New output since the client's last offset, plus the new end offset. If `since` is
    // behind the sliding window, resumes from the window start (older scrollback is lost).
    public func read(since: Int) -> (data: Data, offset: Int) {
        lock.lock(); defer { lock.unlock() }
        lastTouched = Date()
        let end = baseOffset + buffer.count
        let from = max(since, baseOffset)
        guard from < end else { return (Data(), end) }
        let lo = buffer.index(buffer.startIndex, offsetBy: from - baseOffset)
        return (Data(buffer[lo...]), end)
    }

    public func write(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); lastTouched = Date(); lock.unlock()
        d.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(master, base, raw.count)
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &win)
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
        readSource?.cancel()
        close(master)
        lock.lock(); aliveFlag = false; lock.unlock()
    }
}
