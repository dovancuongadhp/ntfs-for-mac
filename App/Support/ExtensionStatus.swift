import AppKit
import FSKit
import NTFSShared
import Observation

/// Whether the user has enabled the file system extension in System Settings.
@MainActor
@Observable
final class ExtensionStatus {
    /// `nil` until the first check finishes.
    private(set) var isEnabled: Bool?

    func refresh() {
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let enabled = modules?.first { $0.bundleIdentifier == Identifiers.extensionBundleID }?.isEnabled
            if let error {
                appLog.error("Listing FSKit modules failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                self.isEnabled = enabled ?? false
            }
        }
    }

    /// Opens General → Login Items & Extensions → File System Extensions.
    func openSystemSettings() {
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() {
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
