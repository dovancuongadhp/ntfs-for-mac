import AppKit
import SwiftUI

/// Shows the welcome and settings windows. The app has no Dock icon, so it
/// activates itself to bring them to the front.
@MainActor
final class WindowPresenter {
    static let welcomeSeenKey = "WelcomeSeen"

    private let model: AppModel
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showWelcome() {
        model.extensionStatus.refresh()
        welcomeWindow = present(welcomeWindow, title: String(localized: "Welcome to NTFS for Mac")) {
            WelcomeView(model: model) { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
                self?.welcomeWindow?.close()
            }
        }
    }

    func showSettings() {
        settingsWindow = present(settingsWindow, title: String(localized: "NTFS for Mac Settings")) {
            SettingsView(model: model)
        }
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
