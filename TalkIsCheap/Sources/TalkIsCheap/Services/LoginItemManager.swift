import ServiceManagement
import Foundation

/// Manage auto-start at login
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.write("Login item registered")
            } else {
                try SMAppService.mainApp.unregister()
                Log.write("Login item unregistered")
            }
        } catch {
            Log.write("Login item error: \(error)")
        }
    }
}
