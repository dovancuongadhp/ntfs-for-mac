import Foundation

/// Turns flat DiskArbitration records into physical disks with their partitions.
enum DiskTreeBuilder {
    static func build(_ infos: [DiskInfo]) -> [PhysicalDisk] {
        let snapshots = infos.filter { isSnapshot($0.bsdName) }
        let infos = infos.filter { !isSnapshot($0.bsdName) }.map { info in
            guard info.mount == nil,
                  let snapshot = snapshots.first(where: { $0.mount != nil && snapshotParent($0.bsdName) == info.bsdName })
            else { return info }
            var info = info
            info.mount = snapshot.mount
            return info
        }
        let containers = infos.filter { $0.isWhole && $0.content == DiskContent.apfsContainer }
        let wholes = infos.filter { $0.isWhole && $0.content != DiskContent.apfsContainer }
        let wholeNames = Set(wholes.map(\.bsdName))
        let partitionNames = Set(infos.filter { !$0.isWhole && wholeNames.contains($0.wholeBSDName) }.map(\.bsdName))
        // A container whose store isn't among the partitions is listed as a disk of its own.
        let orphans = containers.filter { !partitionNames.contains($0.physicalStore ?? "") }
        return (wholes + orphans)
            .sorted { naturalOrder($0.bsdName, $1.bsdName) }
            .map { whole in physicalDisk(whole, infos: infos, containers: containers) }
    }

    /// The physical disk holding a partition or volume, also for snapshot
    /// devices such as `disk3s1s1` that aren't in the tree themselves, and
    /// for APFS container disks such as `disk3`.
    static func physicalDisk(containing bsdName: String, in tree: [PhysicalDisk]) -> PhysicalDisk? {
        var name = bsdName
        while true {
            if let disk = tree.first(where: { disk in
                disk.bsdName == name || disk.partitions.contains { $0.bsdName == name || $0.wholeBSDName == name }
            }) {
                return disk
            }
            guard let suffix = name.range(of: "s[0-9]+$", options: .regularExpression) else { return nil }
            name.removeSubrange(suffix)
        }
    }

    /// Every partition the one APFS container stored on `store` spans, or
    /// `nil` unless exactly one container is stored on it.
    static func physicalStores(ofStore store: String, in infos: [DiskInfo]) -> [String]? {
        let containers = infos.filter {
            $0.isWhole && $0.content == DiskContent.apfsContainer
                && ($0.physicalStore == store || $0.physicalStores.contains(store))
        }
        guard containers.count == 1 else { return nil }
        return containers[0].physicalStores
    }

    private static func physicalDisk(_ whole: DiskInfo, infos: [DiskInfo], containers: [DiskInfo]) -> PhysicalDisk {
        let scheme = PartitionScheme(content: whole.content)
        let children = infos
            .filter { !$0.isWhole && $0.wholeBSDName == whole.bsdName }
            .sorted(by: diskOrder)

        guard whole.content != DiskContent.apfsContainer else {
            return disk(whole, scheme: scheme, partitions: children.map { partition($0, hidden: hasHiddenRole($0)) })
        }

        var partitions: [Partition] = []
        if children.isEmpty, whole.isLeaf {
            partitions.append(partition(whole, hidden: false))
        }
        for child in children {
            let volumes = containers
                .filter { $0.physicalStore == child.bsdName }
                .flatMap { container in infos.filter { !$0.isWhole && $0.wholeBSDName == container.bsdName } }
                .sorted(by: diskOrder)
            var store = partition(child, hidden: !volumes.isEmpty || DiskContent.hidden.contains(child.content ?? ""))
            if !volumes.isEmpty {
                let names = volumes.filter { !hasHiddenRole($0) }.map(\.displayName)
                store.name = names.isEmpty ? child.displayName : names.joined(separator: ", ")
            }
            let storeCount = physicalStores(ofStore: child.bsdName, in: containers)?.count
            if DiskContent.isAPFSStore(child.content) || !volumes.isEmpty {
                store.containerStoreCount = storeCount
            }
            partitions.append(store)
            for volume in volumes {
                var item = partition(volume, hidden: hasHiddenRole(volume))
                item.apfsStore = child.bsdName
                item.containerStoreCount = storeCount
                partitions.append(item)
            }
        }
        return disk(whole, scheme: scheme, partitions: partitions)
    }

    private static func disk(_ whole: DiskInfo, scheme: PartitionScheme, partitions: [Partition]) -> PhysicalDisk {
        let model = whole.deviceModel.flatMap { $0.isEmpty ? nil : $0 }
        return PhysicalDisk(
            bsdName: whole.bsdName,
            name: model ?? whole.mediaName ?? whole.bsdName,
            size: whole.size,
            scheme: scheme,
            isInternal: whole.isInternal,
            isVirtual: whole.deviceProtocol == DiskContent.virtualProtocol,
            isEjectable: whole.isEjectable,
            isWritable: whole.isWritable,
            connection: whole.deviceProtocol,
            blockSize: whole.blockSize,
            partitions: partitions
        )
    }

    private static func partition(_ info: DiskInfo, hidden: Bool) -> Partition {
        Partition(
            bsdName: info.bsdName,
            wholeBSDName: info.wholeBSDName,
            name: info.displayName,
            fileSystem: FileSystemKind(volumeKind: info.volumeKind, content: info.content),
            size: info.size,
            offset: info.offset,
            partitionID: info.partitionID,
            content: info.content,
            volumeKind: info.volumeKind,
            preferenceKey: info.preferenceKey,
            volumeUUID: info.volumeUUID,
            mount: info.mount,
            isWritable: info.isWritable,
            isHidden: hidden,
            apfsRoles: info.apfsRoles,
            isTimeMachine: info.hasTimeMachineBackup || info.apfsRoles.contains("Backup"),
            apfsStore: nil,
            containerStoreCount: nil
        )
    }

    private static func hasHiddenRole(_ info: DiskInfo) -> Bool {
        !Set(info.apfsRoles).isDisjoint(with: DiskContent.hiddenRoles)
    }

    /// APFS snapshot devices (`disk3s1s1`), such as the sealed system snapshot macOS boots from.
    private static func isSnapshot(_ bsdName: String) -> Bool {
        bsdName.range(of: "^disk[0-9]+s[0-9]+s[0-9]+$", options: .regularExpression) != nil
    }

    /// The volume a snapshot device belongs to: `disk3s1` for `disk3s1s1`.
    private static func snapshotParent(_ bsdName: String) -> String? {
        guard let suffix = bsdName.range(of: "s[0-9]+$", options: .regularExpression) else { return nil }
        return String(bsdName[..<suffix.lowerBound])
    }

    private static func diskOrder(_ a: DiskInfo, _ b: DiskInfo) -> Bool {
        switch (a.offset, b.offset) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: naturalOrder(a.bsdName, b.bsdName)
        }
    }

    private static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
