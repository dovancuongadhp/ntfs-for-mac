import Foundation
import NTFSFormat

extension FormatToolError {
    var message: String {
        switch self {
        case .usage: String(localized: "Internal error: invalid format request.")
        case .notFound: String(localized: "The partition is no longer connected. Nothing was erased.")
        case .notAPartition: String(localized: "Only a partition can be formatted as NTFS this way. Nothing was erased.")
        case .internalDisk: String(localized: "Internal drives are protected. Nothing was erased.")
        case .systemDisk: String(localized: "This drive holds macOS. Nothing was erased.")
        case .readOnly: String(localized: "The drive is write-protected. Nothing was erased.")
        case .mounted: String(localized: "The drive is still in use. Quit the apps using it and try again. Nothing was erased.")
        case .changed: String(localized: "The drive changed since this window opened. Nothing was erased.")
        case .invalidLabel: String(localized: "The name isn't valid for NTFS. Nothing was erased.")
        case .invalidCluster: String(localized: "The cluster size isn't valid for this drive. Nothing was erased.")
        case .unsupportedPartition: String(localized: "This kind of partition can't be formatted as NTFS. Nothing was erased.")
        case .badPartitionTable: String(localized: "The drive's partition table looks different than expected, so NTFS for Mac stopped.")
        case .ioError: String(localized: "The drive couldn't be read or written.")
        case .mkntfsFailed: String(localized: "Creating the NTFS file system failed. The partition may not be usable; format it again.")
        }
    }

    /// The reason alone, for messages that say themselves what was erased.
    var shortMessage: String {
        switch self {
        case .usage: String(localized: "invalid format request")
        case .notFound: String(localized: "the partition is no longer connected")
        case .notAPartition: String(localized: "not a partition")
        case .internalDisk: String(localized: "internal drives are protected")
        case .systemDisk: String(localized: "the drive holds macOS")
        case .readOnly: String(localized: "the drive is write-protected")
        case .mounted: String(localized: "the drive is in use")
        case .changed: String(localized: "the drive changed")
        case .invalidLabel: String(localized: "the name isn't valid for NTFS")
        case .invalidCluster: String(localized: "the cluster size isn't valid for this drive")
        case .unsupportedPartition: String(localized: "this kind of partition can't be formatted as NTFS")
        case .badPartitionTable: String(localized: "the partition table looks different than expected")
        case .ioError: String(localized: "the drive couldn't be read or written")
        case .mkntfsFailed: String(localized: "creating the NTFS file system failed")
        }
    }
}

extension FormatError {
    /// The reason alone, without "Nothing was erased."
    var shortDetail: String {
        switch self {
        case .diskChanged: String(localized: "the drive changed")
        case .busy: String(localized: "the drive is in use")
        case .cancelled: String(localized: "the administrator prompt was cancelled")
        case .unexpectedLayout: String(localized: "the new partition wasn't found")
        case .tool(let error): error.shortMessage
        case .failed(let detail), .ntfsFailedAfterErase(let detail, _), .failedAfterErase(let detail, _), .blocked(let detail):
            detail
        }
    }
}

extension FormatBlock {
    var message: String {
        switch self {
        case .internalDisk: String(localized: "Internal drives are protected and can't be formatted.")
        case .systemDisk: String(localized: "This drive holds macOS and can't be formatted.")
        case .appDisk: String(localized: "NTFS for Mac is running from this drive.")
        case .readOnlyMedia: String(localized: "The drive is write-protected.")
        case .busy: String(localized: "Another operation is running on this drive.")
        case .virtualDisk: String(localized: "Disk images can't be formatted.")
        case .unsupported: String(localized: "This partition can't be formatted.")
        }
    }
}

extension FormatWarning {
    var message: String {
        switch self {
        case .timeMachine:
            String(localized: "This drive holds Time Machine backups.")
        case .unknownUsage:
            String(localized: "The amount of data couldn't be determined — assume it holds important files.")
        case .apfsVolumes(let names):
            String(localized: "These APFS volumes will also be erased: \(names.joined(separator: ", "))")
        }
    }
}

extension FormatStage {
    var label: String {
        switch self {
        case .checking: String(localized: "Checking the drive…")
        case .unmounting: String(localized: "Unmounting…")
        case .formatting: String(localized: "Formatting…")
        case .finishing: String(localized: "Mounting…")
        }
    }
}

extension VolumeNameError {
    var message: String {
        switch self {
        case .empty: String(localized: "Enter a name.")
        case .tooLong(let limit): String(localized: "The name can have at most \(limit) characters.")
        case .invalidCharacter(let character): String(localized: "The name can't contain “\(String(character))”.")
        case .notASCII: String(localized: "FAT32 names can only use English letters, digits and simple symbols.")
        }
    }
}

extension PartitionScheme {
    var label: String {
        switch self {
        case .gpt: String(localized: "GUID Partition Map")
        case .mbr: String(localized: "Master Boot Record")
        case .none: String(localized: "None")
        }
    }
}
