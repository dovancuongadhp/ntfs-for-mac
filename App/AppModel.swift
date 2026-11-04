import AppKit
import NTFSShared
import Observation

/// Wires disk events, per-drive settings, mounting and formatting together.
@MainActor
@Observable
final class AppModel {
    let inventory = DiskInventory()
    let extensionStatus = ExtensionStatus()
    let preferences = VolumePreferences()
    let launchAtLogin = LaunchAtLogin()
    /// Disks and partitions with a mount, unmount or eject in progress.
    private(set) var busy: Set<String> = []
    /// Physical disks being formatted.
    private(set) var formatting: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private lazy var mounter = MountController(session: inventory.session)
    @ObservationIgnored private lazy var formatter = FormatRunner(
        environment: LiveFormatEnvironment(inventory: inventory, mounter: mounter))
    @ObservationIgnored private let notifier = Notifier()
    /// Disks already auto-mounted during their current connection.
    @ObservationIgnored private var handled: Set<String> = []
    private var reasons: [String: ReadOnlyReason] = [:]
    /// A read-only signal that arrived before its disk showed up as mounted.
    @ObservationIgnored private var pendingReason: (reason: ReadOnlyReason, date: Date)?

    var isFormatting: Bool { !formatting.isEmpty }

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

    // MARK: NTFS drives

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
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.mountWithExtension(bsdName: disk.bsdName, volumeName: disk.name, readOnly: readOnly)
        }
    }

    /// Remounts a drive left read-only by an unclean journal, discarding the journal.
    func allowWritingAnyway(_ disk: NTFSDisk) {
        reasons[disk.bsdName] = nil
        handled.insert(disk.bsdName)
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.mountWithExtension(
                bsdName: disk.bsdName, volumeName: disk.name, readOnly: false, resetJournal: true)
        }
    }

    func eject(_ disk: NTFSDisk) {
        guard let physical = inventory.partition(named: disk.bsdName)?.disk, !isProtected(physical) else { return }
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
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

    // MARK: Any drive

    func mount(_ partition: Partition) {
        if let disk = partition.ntfsDisk {
            mount(disk)
            return
        }
        handled.insert(partition.bsdName)
        perform(on: partition.bsdName, name: partition.name) { [mounter] in
            try await mounter.mountDefault(bsdName: partition.bsdName)
        }
    }

    func unmount(_ partition: Partition) {
        guard let disk = inventory.partition(named: partition.bsdName)?.disk, !isProtected(disk) else { return }
        handled.insert(partition.bsdName)
        perform(on: partition.bsdName, name: partition.name) { [mounter] in
            try await mounter.unmount(bsdName: partition.bsdName)
        }
    }

    func eject(_ disk: PhysicalDisk) {
        guard !isProtected(disk) else { return }
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.eject(bsdName: disk.bsdName)
        }
    }

    func reveal(_ partition: Partition) {
        if let path = partition.mount?.path {
            NSWorkspace.shared.open(path)
        }
    }

    var formatContext: FormatContext {
        FormatContext(
            systemDisks: inventory.systemDiskNames,
            appDisk: inventory.appDiskName,
            busy: busy.union(formatting),
            allowsVirtualDisks: DiskInventory.showsVirtualDisks)
    }

    /// Internal and macOS drives, and the drive the app runs from: shown, but
    /// never unmounted, ejected or formatted.
    func isProtected(_ disk: PhysicalDisk) -> Bool {
        disk.isInternal || inventory.systemDiskNames.contains(disk.bsdName) || inventory.appDiskName == disk.bsdName
    }

    func canUnmount(_ partition: Partition, on disk: PhysicalDisk) -> Bool {
        partition.mount != nil && !isProtected(disk) && !busy.contains(partition.bsdName) && !formatting.contains(disk.bsdName)
    }

    func canEject(_ disk: PhysicalDisk) -> Bool {
        disk.isEjectable && !isProtected(disk) && !busy.contains(disk.bsdName) && !formatting.contains(disk.bsdName)
    }

    // MARK: Formatting

    func prepareFormat(_ target: FormatTarget) -> FormatPreparation? {
        let disk: PhysicalDisk? = switch target {
        case .disk(let name): inventory.physicalDisk(named: name)
        case .partition(let name): inventory.partition(named: name)?.disk
        }
        guard let disk else { return nil }
        let deviceName = FormatSafety.device(for: target, on: disk)
        guard let device = inventory.freshInfo(deviceName), let fingerprint = currentFingerprint(of: deviceName) else {
            return nil
        }
        return FormatSafety.prepare(
            target: target, disk: disk, device: device, fingerprint: fingerprint, context: formatContext)
    }

    /// Whether the drive a format sheet was opened for is still there, unchanged.
    func isCurrent(_ preparation: FormatPreparation) -> Bool {
        FormatSafety.isCurrent(
            preparation,
            disk: inventory.physicalDisk(named: preparation.disk.bsdName),
            fingerprint: currentFingerprint(of: preparation.device.bsdName))
    }

    private func currentFingerprint(of bsdName: String) -> DiskFingerprint? {
        let inventory = inventory
        return DiskFingerprint.read(
            bsdName, freshInfo: { inventory.freshInfo($0) }, childNames: { inventory.childNames(ofWhole: $0) })
    }

    func format(
        _ preparation: FormatPreparation, options: FormatOptions,
        progress: @escaping @MainActor (FormatStage) -> Void
    ) async throws {
        let diskName = preparation.disk.bsdName
        if let block = preparation.block {
            throw FormatError.blocked(block.message)
        }
        guard preparation.fileSystems.contains(options.fileSystem) else {
            throw FormatError.blocked(String(localized: "This format isn't available for this drive."))
        }
        guard let current = inventory.physicalDisk(named: diskName) else { throw FormatError.diskChanged }
        if let reason = FormatSafety.blockReason(for: preparation.target, on: current, context: formatContext) {
            throw FormatError.blocked(reason.message)
        }
        let job = FormatPlanner.job(for: preparation, options: options)
        formatting.insert(diskName)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Formatting a drive")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            formatting.remove(diskName)
            finishFormat(preparation)
        }
        appLog.notice("Formatting \(String(describing: preparation.fingerprint), privacy: .public) as \(options.fileSystem.rawValue, privacy: .public): \(String(describing: job.steps), privacy: .public)")
        do {
            try await formatter.run(job, progress: progress)
            appLog.notice("Formatting \(diskName, privacy: .public) finished")
            // DiskArbitration often keeps the old exFAT kind until the volume is mounted.
            if options.fileSystem == .ntfs {
                await mountFormattedNTFS(preparation, name: options.name)
            }
        } catch {
            appLog.error("Formatting \(diskName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Mounts what was just formatted as NTFS. The probe of the whole disk can fail
    /// while other partitions stay mounted, so the kind stays exFAT until this mount.
    private func mountFormattedNTFS(_ preparation: FormatPreparation, name: String) async {
        let targets: [String]
        switch preparation.target {
        case .partition(let bsdName):
            targets = [bsdName]
        case .disk(let whole):
            inventory.refresh(bsdName: whole)
            targets = inventory.childNames(ofWhole: whole).filter { child in
                guard let info = inventory.freshInfo(child) else { return false }
                return !DiskContent.hidden.contains(info.content ?? "")
            }
        }
        for bsdName in targets {
            let key = inventory.freshInfo(bsdName)?.preferenceKey ?? preparation.device.preferenceKey
            do {
                try await mounter.mountWithExtension(
                    bsdName: bsdName, volumeName: name, readOnly: !preferences.isWriteEnabled(key))
            } catch {
                appLog.error("Mounting \(bsdName, privacy: .public) after format failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Lets the usual mount logic pick up the freshly formatted partitions,
    /// leaving the rest of the disk as the user left it.
    private func finishFormat(_ preparation: FormatPreparation) {
        let device = preparation.device.bsdName
        var names = Set([device] + preparation.affected.map(\.bsdName))
        if preparation.device.isWhole {
            names.formUnion(inventory.childNames(ofWhole: device))
        }
        for name in names {
            handled.remove(name)
            reasons[name] = nil
            inventory.refresh(bsdName: name)
        }
        for partition in inventory.physicalDisk(named: preparation.disk.bsdName)?.partitions ?? []
        where names.contains(partition.bsdName) {
            if let disk = partition.ntfsDisk {
                diskChanged(disk)
            }
        }
    }

    /// Whether a disk, or the physical disk holding a partition, is being formatted.
    func isBeingFormatted(_ bsdName: String) -> Bool {
        guard !formatting.isEmpty else { return false }
        if formatting.contains(bsdName) { return true }
        return inventory.partition(named: bsdName).map { formatting.contains($0.disk.bsdName) } ?? false
    }

    // MARK: Internals

    private func perform(on bsdName: String, name: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(bsdName), !isBeingFormatted(bsdName) else { return }
        busy.insert(bsdName)
        lastError = nil
        Task {
            do {
                try await operation()
            } catch {
                appLog.error("\(bsdName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if error.localizedDescription.contains("is disabled") {
                    self.extensionStatus.noteExtensionDisabled()
                }
                self.lastError = String(localized: "“\(name)”: \(error.localizedDescription)")
            }
            self.busy.remove(bsdName)
            self.inventory.refresh(bsdName: bsdName)
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
        guard !busy.contains(disk.bsdName), !isBeingFormatted(disk.bsdName) else { return }
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
