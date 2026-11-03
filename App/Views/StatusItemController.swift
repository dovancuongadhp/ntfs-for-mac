import AppKit
import SwiftUI

/// The menu bar icon and the panel it opens. Unlike `MenuBarExtra`, it opens
/// on a right click as well as a left click.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = MenuPanel()
    private let content: () -> AnyView
    /// When the panel last closed because it lost focus. A click on the icon
    /// takes the focus first, and must not reopen the panel it just closed.
    private var lastAutoClose = Date.distantPast

    init(@ViewBuilder content: @escaping () -> some View) {
        self.content = { AnyView(content()) }
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        statusItem.autosaveName = "NTFSForMac"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "NTFS for Mac")
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date.now.timeIntervalSince(lastAutoClose) > 0.3 {
            show()
        }
    }

    private func show() {
        // A fresh view each time, so `onAppear` and `task` run while the panel is open.
        let hostingView = FittingHostingView(rootView: content())
        hostingView.onSizeChange = { [weak self] in self?.layoutPanel() }
        panel.setContent(hostingView)
        layoutPanel()
        statusItem.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
        panel.setContent(nil)
        statusItem.button?.highlight(false)
    }

    /// Sizes the panel to its content, just below the icon and inside the screen.
    private func layoutPanel() {
        guard let buttonWindow = statusItem.button?.window,
              let size = panel.contentFittingSize
        else { return }
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let top = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        lastAutoClose = .now
        close()
    }
}

/// A borderless panel that can take keyboard focus without activating the app,
/// like a menu bar extra window.
private final class MenuPanel: NSPanel {
    private let background = NSVisualEffectView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    var contentFittingSize: NSSize? {
        background.subviews.first?.fittingSize
    }

    func setContent(_ view: NSView?) {
        background.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            view.topAnchor.constraint(equalTo: background.topAnchor),
            view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Reports when the SwiftUI content changes size, e.g. when a drive appears.
private final class FittingHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}
