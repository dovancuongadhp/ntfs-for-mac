import AppKit
import FSKit
import NTFSShared
import Observation

/// Whether the user has enabled the file system extension in System Settings.
@MainActor
@Observable
final class ExtensionStatus {
    /// `nil` while unknown: before the first check, or when FSKit doesn't list
    /// the module and nothing has been mounted with it yet.
    private(set) var isEnabled: Bool?
    private(set) var hasChecked = false

    /// FSKit only lists modules signed with the FSKit entitlement, which ad hoc
    /// builds can't carry; for those, mounts are the only evidence.
    private var listed: Bool?
    private var observed: Bool?

    func refresh() {
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let enabled = modules?.first { $0.bundleIdentifier == Identifiers.extensionBundleID }?.isEnabled
            if let error {
                appLog.error("Listing FSKit modules failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                self.listed = enabled
                self.hasChecked = true
                self.update()
            }
        }
    }

    /// A volume is mounted by the extension, so it must be enabled.
    func noteExtensionMounted() {
        observed = true
        update()
    }

    /// A mount failed because FSKit reported the module as disabled.
    func noteExtensionDisabled() {
        observed = false
        update()
    }

    private func update() {
        let value = listed ?? observed
        if isEnabled != value {
            isEnabled = value
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
