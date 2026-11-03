import Foundation

/// Turns flat DiskArbitration records into physical disks with their partitions.
enum DiskTreeBuilder {
    static func build(_ infos: [DiskInfo]) -> [PhysicalDisk] {
        let containers = infos.filter { $0.isWhole && $0.content == DiskContent.apfsContainer }
        return infos
            .filter { $0.isWhole && $0.content != DiskContent.apfsContainer }
            .sorted { naturalOrder($0.bsdName, $1.bsdName) }
            .map { whole in physicalDisk(whole, infos: infos, containers: containers) }
    }

    /// The physical disk holding a partition or volume, also for snapshot
    /// devices such as `disk3s1s1` that aren't in the tree themselves.
    static func physicalDisk(containing bsdName: String, in tree: [PhysicalDisk]) -> PhysicalDisk? {
        var name = bsdName
        while true {
            if let disk = tree.first(where: { $0.bsdName == name || $0.partitions.contains { $0.bsdName == name } }) {
                return disk
            }
            guard let suffix = name.range(of: "s[0-9]+$", options: .regularExpression) else { return nil }
            name.removeSubrange(suffix)
        }
    }

    private static func physicalDisk(_ whole: DiskInfo, infos: [DiskInfo], containers: [DiskInfo]) -> PhysicalDisk {
        let scheme = PartitionScheme(content: whole.content)
        let children = infos
            .filter { !$0.isWhole && $0.wholeBSDName == whole.bsdName }
            .sorted(by: diskOrder)

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
                store.name = volumes
                    .filter { Set($0.apfsRoles).isDisjoint(with: DiskContent.hiddenRoles) }
                    .map(\.displayName)
                    .joined(separator: ", ")
            }
            partitions.append(store)
            for volume in volumes {
                var item = partition(volume, hidden: !Set(volume.apfsRoles).isDisjoint(with: DiskContent.hiddenRoles))
                item.apfsStore = child.bsdName
                partitions.append(item)
            }
        }

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
            apfsStore: nil
        )
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
