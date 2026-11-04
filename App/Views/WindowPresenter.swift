import AppKit
import SwiftUI

/// What the main window's sidebar shows, kept outside the window so the menu
/// can open it on a given page.
@MainActor
@Observable
final class MainNavigation {
    var selection: SidebarSelection?
}

/// Shows the main window, which also holds settings and setup. The app has no
/// Dock icon except while the window is open.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let welcomeSeenKey = "WelcomeSeen"

    private let model: AppModel
    private let navigation = MainNavigation()
    private var mainWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isMainWindowVisible: Bool {
        mainWindow?.isVisible == true
    }

    func showMain() {
        // This is a menu-bar app until a window opens. The SwiftUI content has to
        // be created after the app becomes a normal app; otherwise Light Mode
        // draws the drive list in white on white.
        NSApp.setActivationPolicy(.regular)
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        window.appearance = NSApp.effectiveAppearance
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.toolbar?.displayMode = .iconAndLabel
    }

    func showSettings() {
        model.extensionStatus.refresh()
        navigation.selection = .settings
        showMain()
    }

    private func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(rootView: MainWindowView(model: model, navigation: navigation))
        controller.sceneBridgingOptions = [.toolbars, .title]
        // The window sets the size, not the page: a long page (or a banner above
        // it) used to make the content taller than the window and spill out of it.
        controller.sizingOptions = []
        controller.view.appearance = NSApp.effectiveAppearance
        let window = NSWindow(contentViewController: controller)
        window.title = "NTFS for Mac"
        // The sidebar floats beside the content and the window controls sit in it,
        // as in Disk Utility. Every page is a Form, which keeps clear of the toolbar.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Small enough that the sidebar folds away on a narrow window instead of
        // the page being cut off on both sides.
        window.contentMinSize = NSSize(width: 460, height: 400)
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, model.isFormatting else { return true }
        Self.showFormattingInProgress(closingWindow: true)
        return false
    }

    /// Dropping the window tears down its views, so they stop refreshing while
    /// it's closed; the frame is restored from the autosave name.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        mainWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Explains why the app won't quit, or the main window won't close, mid-format.
    static func showFormattingInProgress(closingWindow: Bool = false) {
        let alert = NSAlert()
        alert.messageText = String(localized: "A drive is being formatted")
        alert.informativeText = closingWindow
            ? String(localized: "NTFS for Mac is formatting a drive. Wait until it finishes before closing this window.")
            : String(localized: "Wait until formatting finishes before quitting NTFS for Mac.")
        NSApp.activate()
        alert.runModal()
    }
}
