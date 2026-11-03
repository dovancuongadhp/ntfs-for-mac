import Foundation
import NTFSFormat

enum FormatStep: Equatable, Sendable {
    /// Unmount without forcing; `whole` unmounts every volume on the disk.
    case unmount(String, whole: Bool)
    /// Unmount a partition that `diskutil` just formatted and mounted,
    /// retrying while macOS still holds it.
    case unmountErased(String)
    /// Arguments for `/usr/sbin/diskutil`.
    case diskutil([String])
    /// Run `ntfs-format` with administrator rights.
    case ntfsFormat(FormatRequest)
    /// After `eraseDisk`: format the disk's single new data partition as NTFS.
    case ntfsFormatNewPartition(whole: String, label: String, clusterSize: Int?, quick: Bool)
}

struct FormatJob: Equatable, Sendable {
    var fingerprint: DiskFingerprint
    var steps: [FormatStep]
}

enum FormatPlanner {
    static func job(for preparation: FormatPreparation, options: FormatOptions) -> FormatJob {
        let device = preparation.device
        var steps: [FormatStep] = []
        switch preparation.target {
        case .partition(let name) where name == preparation.disk.bsdName && options.fileSystem == .apfs:
            // A superfloppy has no partition to hold an APFS container, so it gets a new GPT.
            if preparation.affected.contains(where: { $0.mount != nil }) {
                steps.append(.unmount(device.bsdName, whole: true))
            }
            steps.append(.diskutil(["eraseDisk", "APFS", options.name, "GPT", device.bsdName]))
        case .partition:
            steps += preparation.affected.filter { $0.mount != nil }.map { .unmount($0.bsdName, whole: false) }
            if DiskContent.isAPFSStore(device.content) {
                // diskutil won't erase an APFS physical store. Deleting its container
                // with a new name keeps the partition, as an HFS+ placeholder.
                steps.append(.diskutil(["apfs", "deleteContainer", device.bsdName, "NFMTEMP"]))
            }
            if let diskutilName = options.fileSystem.diskutilName {
                steps.append(.diskutil(["eraseVolume", diskutilName, options.name, device.bsdName]))
            } else {
                if preparation.disk.scheme == .gpt, !isBasicData(device.content) {
                    // Windows only mounts NTFS from Basic Data partitions; an exFAT
                    // placeholder makes diskutil re-type the partition.
                    steps.append(.diskutil(["eraseVolume", "ExFAT", "NTFS", device.bsdName]))
                    steps.append(.unmountErased(device.bsdName))
                }
                steps.append(.ntfsFormat(FormatRequest(
                    device: device.bsdName, size: device.size, offset: device.offset ?? 0,
                    label: options.name, clusterSize: options.clusterSize, quick: options.quick)))
            }
        case .disk:
            steps.append(.unmount(device.bsdName, whole: true))
            let scheme = options.scheme == .mbr && options.fileSystem != .apfs ? "MBR" : "GPT"
            if let diskutilName = options.fileSystem.diskutilName {
                steps.append(.diskutil(["eraseDisk", diskutilName, options.name, scheme, device.bsdName]))
            } else {
                // exFAT is a placeholder that diskutil can create on any scheme;
                // its partition is then reformatted as NTFS.
                steps.append(.diskutil(["eraseDisk", "ExFAT", "NTFS", scheme, device.bsdName]))
                steps.append(.ntfsFormatNewPartition(
                    whole: device.bsdName, label: options.name, clusterSize: options.clusterSize, quick: options.quick))
            }
        }
        return FormatJob(fingerprint: preparation.fingerprint, steps: steps)
    }

    /// The store whose APFS container the arguments delete, if they do.
    static func deletedContainerStore(_ arguments: [String]) -> String? {
        arguments.count == 4 && arguments.starts(with: ["apfs", "deleteContainer"]) ? arguments[2] : nil
    }

    private static func isBasicData(_ content: String?) -> Bool {
        content?.uppercased() == DiskContent.microsoftBasicData
    }
}
