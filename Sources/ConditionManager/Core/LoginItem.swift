import Foundation
import ServiceManagement

// Login-item management via SMAppService (macOS 13+). Only works when the
// process runs from a proper .app bundle that is (ad-hoc) signed — see
// Scripts/build-app.sh. From a raw SPM binary `isBundled` is false and the
// menu shows a hint instead of the toggle.
enum LoginItem {

    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("[ConditionManager] LoginItem toggle failed: \(error)")
            return false
        }
    }
}
