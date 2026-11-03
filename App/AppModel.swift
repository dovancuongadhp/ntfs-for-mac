import AppKit
import NTFSShared
import Observation

/// Wires disk events, per-drive settings and mounting together.
@MainActor
@Observable
final class AppModel {
    let inventory = DiskInventory()
    let extensionStatus = ExtensionStatus()
    let preferences = VolumePreferences()
    let launchAtLogin = LaunchAtLogin()
    /// Disks with a mount or eject in progress.
    private(set) var busy: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private lazy var mounter = MountController(session: inventory.session)
    @ObservationIgnored private let notifier = Notifier()
    /// Disks already auto-mounted during their current connection.
    @ObservationIgnored private var handled: Set<String> = []
    private var reasons: [String: ReadOnlyReason] = [:]
    /// A read-only signal that arrived before its disk showed up as mounted.
    @ObservationIgnored private var pendingReason: (reason: ReadOnlyReason, date: Date)?

    func start() {
        notifier.requestAuthorization()
        notifier.observeReadOnlyFallbacks { [weak self] reason in
            self?.extensionReportedReadOnly(reason)
        }
        inventory.onDiskChanged = { [weak self] disk in
            self?.diskChanged(disk)
        }
        inventory.onDiskRemoved = { [weak self] bsdName in
            self?.handled.remove(bsdName)
            self?.reasons[bsdName] = nil
        }
        extensionStatus.refresh()
        for disk in inventory.disks {
            diskChanged(disk)
        }
    }

    func state(of disk: NTFSDisk) -> DiskState {
        disk.state(reason: reasons[disk.bsdName], writeEnabled: preferences.isWriteEnabled(disk.preferenceKey))
    }

    func isWriteEnabled(_ disk: NTFSDisk) -> Bool {
        preferences.isWriteEnabled(disk.preferenceKey)
    }

    func setWriteEnabled(_ enabled: Bool, for disk: NTFSDisk) {
        preferences.setWriteEnabled(enabled, for: disk.preferenceKey)
        guard disk.isRecognized, disk.mount != nil || enabled else { return }
        reasons[disk.bsdName] = nil
        mount(disk, readOnly: !enabled)
    }

    func mount(_ disk: NTFSDisk, readOnly: Bool? = nil) {
        let readOnly = readOnly ?? !preferences.isWriteEnabled(disk.preferenceKey)
        handled.insert(disk.bsdName)
        perform(on: disk) { [mounter] in
            try await mounter.mountWithExtension(bsdName: disk.bsdName, volumeName: disk.name, readOnly: readOnly)
        }
    }

    /// Remounts a drive left read-only by an unclean journal, discarding the journal.
    func allowWritingAnyway(_ disk: NTFSDisk) {
        reasons[disk.bsdName] = nil
        handled.insert(disk.bsdName)
        perform(on: disk) { [mounter] in
            try await mounter.mountWithExtension(
                bsdName: disk.bsdName, volumeName: disk.name, readOnly: false, resetJournal: true)
        }
    }

    func eject(_ disk: NTFSDisk) {
        perform(on: disk) { [mounter] in
            try await mounter.eject(bsdName: disk.bsdName)
        }
    }

    func reveal(_ disk: NTFSDisk) {
        if let path = disk.mount?.path {
            NSWorkspace.shared.open(path)
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func perform(on disk: NTFSDisk, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(disk.bsdName) else { return }
        busy.insert(disk.bsdName)
        lastError = nil
        Task {
            do {
                try await operation()
            } catch {
                appLog.error("\(disk.bsdName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if error.localizedDescription.contains("is disabled") {
                    self.extensionStatus.noteExtensionDisabled()
                }
                self.lastError = String(localized: "“\(disk.name)”: \(error.localizedDescription)")
            }
            self.busy.remove(disk.bsdName)
            self.inventory.refresh(bsdName: disk.bsdName)
        }
    }

    private func diskChanged(_ disk: NTFSDisk) {
        if disk.isMountedByExtension {
            extensionStatus.noteExtensionMounted()
        }
        if disk.isMountedByExtension, disk.mount?.isReadOnly == true, reasons[disk.bsdName] == nil,
           let pending = pendingReason, Date().timeIntervalSince(pending.date) < 60 {
            reasons[disk.bsdName] = pending.reason
            pendingReason = nil
        }
        guard !busy.contains(disk.bsdName) else { return }
        let action = MountPolicy.action(
            for: disk,
            writeEnabled: preferences.isWriteEnabled(disk.preferenceKey),
            alreadyHandled: handled.contains(disk.bsdName)
        )
        if case .mountWithExtension(let readOnly) = action {
            mount(disk, readOnly: readOnly)
        }
    }

    private func extensionReportedReadOnly(_ reason: ReadOnlyReason) {
        let candidates = inventory.disks.filter {
            $0.isMountedByExtension && $0.mount?.isReadOnly == true && reasons[$0.bsdName] == nil
        }
        if candidates.count == 1 {
            reasons[candidates[0].bsdName] = reason
        } else {
            pendingReason = (reason, Date())
        }
        notifier.post(title: String(localized: "NTFS drive opened read-only"), body: reason.advice)
    }
}
