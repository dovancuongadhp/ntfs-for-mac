import SwiftUI

@main
struct NTFSForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon comes from `StatusItemController`; this scene backs
        // the Settings… item of the main menu while the main window is open.
        Settings { SettingsView(model: appDelegate.model) }
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
        } else if !launchedAsLoginItem {
            windows.showMain()
        }
        // Remind the user if the extension is still switched off.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if model.extensionStatus.isEnabled == false {
                windows.showWelcome()
            }
        }
    }

    /// Opening the app again from Finder while it's running shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showMain()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isFormatting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "A drive is being formatted")
        alert.informativeText = String(localized: "Wait until formatting finishes before quitting NTFS for Mac.")
        NSApp.activate()
        alert.runModal()
        return .terminateCancel
    }

    /// Started by "Open at login" rather than by the user.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
