import SwiftUI

@main
struct NTFSForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon comes from `StatusItemController`; the app has no scenes of its own.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var windows = WindowPresenter(model: model)
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        statusItem = StatusItemController { [model, windows] in
            MenuContentView(model: model, windows: windows)
        }
        model.start()
        if !UserDefaults.standard.bool(forKey: WindowPresenter.welcomeSeenKey) {
            windows.showWelcome()
        }
        // Remind the user if the extension is still switched off.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if model.extensionStatus.isEnabled == false {
                windows.showWelcome()
            }
        }
    }

    /// Opening the app again from Finder while it's running shows the guide.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showWelcome()
        return false
    }
}
