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
        if context.busy.contains(disk.bsdName) || disk.partitions.contains(where: { context.busy.contains($0.bsdName) }) {
            return .busy
        }
        return nil
    }

    static func blockReason(for target: FormatTarget, on disk: PhysicalDisk, context: FormatContext) -> FormatBlock? {
        if let reason = blockReason(for: disk, context: context) { return reason }
        guard case .partition(let name) = target else { return nil }
        guard let partition = disk.partitions.first(where: { $0.bsdName == name }), !partition.isHidden else {
            return .unsupported
        }
        return partition.isWritable ? nil : .readOnlyMedia
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
            return [.exfat, .fat32]
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

    static func prepare(
        target: FormatTarget, disk: PhysicalDisk, device: DiskInfo, children: [String], context: FormatContext
    ) -> FormatPreparation {
        let affected = affected(by: target, on: disk)
        let displayName: String
        let suggestedName: String
        switch target {
        case .disk:
            displayName = disk.name
            suggestedName = String(localized: "Untitled")
        case .partition(let name):
            displayName = disk.partitions.first { $0.bsdName == name }?.name ?? name
            suggestedName = displayName
        }
        return FormatPreparation(
            target: target,
            disk: disk,
            displayName: displayName,
            device: device,
            fingerprint: DiskFingerprint(info: device, children: children),
            affected: affected,
            unaffected: unaffected(by: target, on: disk),
            usedBytes: usedBytes(affected),
            warnings: warnings(for: affected),
            fileSystems: fileSystems(for: target, on: disk, device: device),
            block: blockReason(for: target, on: disk, context: context),
            suggestedName: suggestedName
        )
    }
}
