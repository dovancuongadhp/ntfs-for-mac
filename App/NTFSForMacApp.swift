import SwiftUI

@main
struct NTFSForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon comes from `StatusItemController` and every window
        // from `WindowPresenter`; this empty scene only carries the main menu's
        // Settings… item, which opens the settings page of the main window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.windows.showSettings() }
                        .keyboardShortcut(",")
                }
            }
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
            UserDefaults.standard.set(true, forKey: WindowPresenter.welcomeSeenKey)
            windows.showSettings()
        } else if !launchedAsLoginItem {
            windows.showMain()
        }
        // Remind the user if the extension is still switched off; an open
        // window already shows the reminder.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if model.extensionStatus.isEnabled == false, !windows.isMainWindowVisible {
                windows.showSettings()
            }
        }
    }

    /// Opening the app again from Finder while it's running shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showMain()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isFormatting {
            WindowPresenter.showFormattingInProgress()
            return .terminateCancel
        }
        return quit.shouldTerminate().appKitReply
    }

    /// Asks before quitting in the middle of a copy; see `QuitCoordinator`.
    private lazy var quit = QuitCoordinator(
        phase: { [model] in model.transfer.queue.phase },
        // The app has no Dock icon and the menu panel does not activate it, so without this the alert can
        // open behind other windows and Quit looks like a hang.
        activate: { NSApp.activate() },
        confirmQuit: {
            let alert = NSAlert()
            alert.messageText = String(localized: "Files are still being copied")
            alert.informativeText = String(localized: "Quitting now cancels the copy and removes the unfinished files.")
            alert.addButton(withTitle: String(localized: "Keep Copying"))
            alert.addButton(withTitle: String(localized: "Quit"))
            return alert.runModal() != .alertFirstButtonReturn
        },
        cancelAndWait: { [model] in await model.transfer.queue.cancelAndWait() },
        reply: { NSApp.reply(toApplicationShouldTerminate: $0) })

    /// Started by "Open at login" rather than by the user.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

private extension QuitCoordinator.Reply {
    var appKitReply: NSApplication.TerminateReply {
        switch self {
        case .terminateNow: .terminateNow
        case .terminateCancel: .terminateCancel
        case .terminateLater: .terminateLater
        }
    }
}
