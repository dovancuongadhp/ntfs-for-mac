import AppKit
import SwiftUI

/// Shows the main, welcome and settings windows. The app has no Dock icon
/// except while the main window is open.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let welcomeSeenKey = "WelcomeSeen"

    private let model: AppModel
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showMain() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        model.extensionStatus.refresh()
        welcomeWindow = present(welcomeWindow, title: String(localized: "Welcome to NTFS for Mac")) {
            WelcomeView(model: model) { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
                self?.welcomeWindow?.close()
                self?.showMain()
            }
        }
    }

    func showSettings() {
        settingsWindow = present(settingsWindow, title: String(localized: "NTFS for Mac Settings")) {
            SettingsView(model: model)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(rootView: MainWindowView(model: model))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.title = "NTFS for Mac"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, model.isFormatting else { return true }
        NSSound.beep()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func present(_ existing: NSWindow?, title: String, @ViewBuilder content: () -> some View) -> NSWindow {
        let window = existing ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
