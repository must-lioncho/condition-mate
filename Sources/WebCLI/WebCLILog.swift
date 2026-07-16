import Foundation

// WebCLI is a standalone target and must not depend on the app's AppLog. The app injects
// its logger at startup (AppDelegate sets `WebCLILog.sink = AppLog.log`); until then logs
// go nowhere, which is fine for a library.
public enum WebCLILog {
    public static var sink: (String) -> Void = { _ in }
    static func log(_ message: String) { sink(message) }
}
