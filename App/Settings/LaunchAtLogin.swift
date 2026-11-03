import Observation
import ServiceManagement

/// Registers the app as a login item. The registration disappears with the app.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appLog.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
