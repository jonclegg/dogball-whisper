import Foundation
import ServiceManagement

/// Launch at login via SMAppService. No helper bundle and no deprecated
/// LSSharedFileList shimming: registering the main app is enough.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error.localizedDescription)")
        }
    }
}
