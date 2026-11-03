import Foundation

enum FormatBlock: Equatable, Sendable {
    case internalDisk, systemDisk, appDisk, readOnlyMedia, busy, virtualDisk, unsupported
}

enum FormatWarning: Hashable, Sendable {
    case timeMachine
    case unknownUsage
    case apfsVolumes([String])
}

struct FormatContext: Equatable, Sendable {
    var systemDisks: Set<String> = []
    var appDisk: String?
    var busy: Set<String> = []
    var allowsVirtualDisks = false
}

/// Everything the format sheet shows and confirms, captured when it opens.
struct FormatPreparation: Equatable, Sendable {
    let target: FormatTarget
    let disk: PhysicalDisk
    /// What the user types to confirm.
    let displayName: String
    /// The device that is actually erased.
    let device: DiskInfo
    let fingerprint: DiskFingerprint
    let affected: [Partition]
    let unaffected: [Partition]
    let usedBytes: UInt64?
    let warnings: [FormatWarning]
    let fileSystems: [FormatFileSystem]
    let block: FormatBlock?
    let suggestedName: String
}

/// Decides what may be formatted and what formatting it would erase.
enum FormatSafety {
    static func blockReason(for disk: PhysicalDisk, context: FormatContext) -> FormatBlock? {
        if disk.isInternal { return .internalDisk }
        if context.systemDisks.contains(disk.bsdName) { return .systemDisk }
        if context.appDisk == disk.bsdName { return .appDisk }
        if disk.isVirtual, !context.allowsVirtualDisks { return .virtualDisk }
        if !disk.isWritable { return .readOnlyMedia }
        let isBusy = context.busy.contains(disk.bsdName) || disk.partitions.contains {
            context.busy.contains($0.bsdName) || context.busy.contains($0.wholeBSDName)
        }
        return isBusy ? .busy : nil
    }

    static func blockReason(for target: FormatTarget, on disk: PhysicalDisk, context: FormatContext) -> FormatBlock? {
        if let reason = blockReason(for: disk, context: context) { return reason }
        guard hasKnownLayout(disk) else { return .unsupported }
        switch target {
        case .disk(let name):
            return name == disk.bsdName ? nil : .unsupported
        case .partition(let name):
            guard let partition = disk.partitions.first(where: { $0.bsdName == name }), !partition.isHidden else {
                return .unsupported
            }
            return partition.isWritable ? nil : .readOnlyMedia
        }
    }

    /// A disk without a partition table is only understood when it is a
    /// superfloppy: one file system on the whole disk. An APFS container
    /// whose store wasn't found also has no scheme, and isn't formattable.
    private static func hasKnownLayout(_ disk: PhysicalDisk) -> Bool {
        disk.scheme != .none || isSuperfloppy(disk)
    }

    private static func isSuperfloppy(_ disk: PhysicalDisk) -> Bool {
        disk.scheme == .none && disk.partitions.count == 1 && disk.partitions[0].bsdName == disk.bsdName
    }

    /// The BSD name that is erased: the disk, the partition, or for an APFS
    /// volume the partition holding its container.
    static func device(for target: FormatTarget, on disk: PhysicalDisk) -> String {
        switch target {
        case .disk(let name):
            return name
        case .partition(let name):
            return disk.partitions.first { $0.bsdName == name }?.apfsStore ?? name
        }
    }

    static func affected(by target: FormatTarget, on disk: PhysicalDisk) -> [Partition] {
        switch target {
        case .disk:
            return disk.sidebarPartitions
        case .partition(let name):
            guard let partition = disk.partitions.first(where: { $0.bsdName == name }) else { return [] }
            guard let store = partition.apfsStore else { return [partition] }
            return disk.sidebarPartitions.filter { $0.apfsStore == store }
        }
    }

    static func unaffected(by target: FormatTarget, on disk: PhysicalDisk) -> [Partition] {
        guard case .partition = target else { return [] }
        let erased = Set(affected(by: target, on: disk).map(\.bsdName))
        return disk.sidebarPartitions.filter { !erased.contains($0.bsdName) }
    }

    static func fileSystems(for target: FormatTarget, on disk: PhysicalDisk, device: DiskInfo) -> [FormatFileSystem] {
        guard hasKnownLayout(disk) else { return [] }
        if target.isDisk {
            return FormatFileSystem.allCases
        }
        switch disk.scheme {
        case .gpt:
            return device.offset == nil ? [.exfat, .fat32, .apfs] : [.ntfs, .exfat, .fat32, .apfs]
        case .mbr:
            let canNTFS = device.offset != nil && (1...4).contains(device.partitionID ?? 0)
            return canNTFS ? [.ntfs, .exfat, .fat32] : [.exfat, .fat32]
        case .none:
            return [.exfat, .fat32, .apfs]
        }
    }

    /// Used space of the erased partitions, or `nil` when any isn't mounted.
    /// APFS volumes report their whole container, so each container counts once.
    static func usedBytes(_ partitions: [Partition]) -> UInt64? {
        var total: UInt64 = 0
        var containers: [String: UInt64] = [:]
        for partition in partitions {
            guard let mount = partition.mount else { return nil }
            let used = mount.totalBytes - min(mount.freeBytes, mount.totalBytes)
            if let store = partition.apfsStore {
                containers[store] = max(containers[store] ?? 0, used)
            } else {
                total += used
            }
        }
        return total + containers.values.reduce(0, +)
    }

    static func warnings(for partitions: [Partition]) -> [FormatWarning] {
        var warnings: [FormatWarning] = []
        if partitions.contains(where: \.isTimeMachine) {
            warnings.append(.timeMachine)
        }
        if partitions.contains(where: { $0.mount == nil }) {
            warnings.append(.unknownUsage)
        }
        let volumes = partitions.filter { $0.apfsStore != nil }
        if volumes.count > 1 {
            warnings.append(.apfsVolumes(volumes.map(\.name)))
        }
        return warnings
    }

    /// Whether the typed text confirms erasing `displayName`. Nothing empty confirms anything.
    static func isConfirmed(_ typed: String, displayName: String) -> Bool {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        let expected = displayName.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && !expected.isEmpty && typed == expected
    }

    /// Whether the drive the sheet was prepared for is still connected and unchanged.
    static func isCurrent(_ preparation: FormatPreparation, disk: PhysicalDisk?, fingerprint: DiskFingerprint?) -> Bool {
        disk?.bsdName == preparation.disk.bsdName && fingerprint == preparation.fingerprint
    }

    static func prepare(
        target: FormatTarget, disk: PhysicalDisk, device: DiskInfo, fingerprint: DiskFingerprint, context: FormatContext
    ) -> FormatPreparation {
        let affected = affected(by: target, on: disk)
        let name: String
        let suggestedName: String
        switch target {
        case .disk(let bsdName):
            name = disk.name.trimmingCharacters(in: .whitespaces).isEmpty ? bsdName : disk.name
            suggestedName = String(localized: "Untitled")
        case .partition(let bsdName):
            let partitionName = disk.partitions.first { $0.bsdName == bsdName }?.name ?? ""
            let isUnnamed = partitionName.trimmingCharacters(in: .whitespaces).isEmpty
            // An unnamed volume is confirmed by typing its device name.
            name = isUnnamed ? bsdName : partitionName
            suggestedName = isUnnamed ? String(localized: "Untitled") : partitionName
        }
        return FormatPreparation(
            target: target,
            disk: disk,
            displayName: name,
            device: device,
            fingerprint: fingerprint,
            affected: affected,
            unaffected: unaffected(by: target, on: disk),
            usedBytes: usedBytes(affected),
            warnings: warnings(for: affected),
            fileSystems: fileSystems(for: target, on: disk, device: device),
            block: blockReason(for: target, on: disk, context: context)
                ?? (device.bsdName == self.device(for: target, on: disk) ? nil : .unsupported),
            suggestedName: suggestedName
        )
    }
}
