import Foundation
import NTFSFormat

enum FormatTarget: Hashable, Identifiable, Sendable {
    case partition(String)
    case disk(String)

    var id: String {
        switch self {
        case .partition(let name): "partition:" + name
        case .disk(let name): "disk:" + name
        }
    }

    var isDisk: Bool {
        if case .disk = self { true } else { false }
    }
}

enum FormatFileSystem: String, CaseIterable, Identifiable, Sendable {
    case ntfs, exfat, fat32, apfs

    var id: Self { self }

    var title: String {
        switch self {
        case .ntfs: "NTFS"
        case .exfat: "exFAT"
        case .fat32: "FAT32"
        case .apfs: "APFS"
        }
    }

    /// The name `diskutil` uses; NTFS is formatted by `ntfs-format` instead.
    var diskutilName: String? {
        switch self {
        case .ntfs: nil
        case .exfat: "ExFAT"
        case .fat32: "MS-DOS FAT32"
        case .apfs: "APFS"
        }
    }
}

struct FormatOptions: Equatable, Sendable {
    /// Already validated by `VolumeNameRule`.
    var name: String
    var fileSystem: FormatFileSystem
    /// Whole-disk formats only.
    var scheme: PartitionScheme = .gpt
    /// NTFS only; `nil` lets mkntfs choose.
    var clusterSize: Int?
    /// NTFS only; a full format writes zeros over the partition.
    var quick = true
}

/// What identifies the device the user confirmed. Formatting stops if any of
/// it differs when the work starts.
struct DiskFingerprint: Equatable, Sendable {
    var bsdName: String
    var wholeBSDName: String
    var size: UInt64
    var offset: UInt64?
    var mediaUUID: String?
    /// For a whole disk: its partitions.
    var children: [String]

    init(info: DiskInfo, children: [String]) {
        bsdName = info.bsdName
        wholeBSDName = info.wholeBSDName
        size = info.size
        offset = info.offset
        mediaUUID = info.mediaUUID
        self.children = children
    }
}

enum FormatStage: Equatable, Sendable {
    case checking, unmounting, formatting, finishing
}

enum FormatError: LocalizedError, Equatable {
    case diskChanged
    case busy(String)
    case cancelled
    case unexpectedLayout
    case tool(FormatToolError)
    case failed(String)
    case ntfsFailedAfterErase(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .diskChanged:
            String(localized: "The drive changed since this window opened. Nothing was erased.")
        case .busy(let detail):
            String(localized: "The drive is in use. Quit the apps using it and try again. (\(detail))")
        case .cancelled:
            String(localized: "Formatting was cancelled. Nothing was erased.")
        case .unexpectedLayout:
            String(localized: "The new partition could not be found. The drive may not be usable; format it again.")
        case .tool(let error):
            error.message
        case .failed(let detail):
            String(localized: "Formatting failed: \(detail)")
        case .ntfsFailedAfterErase(let detail):
            String(localized: "The drive was erased and formatted as exFAT, but formatting it as NTFS failed: \(detail)")
        case .blocked(let reason):
            reason
        }
    }
}
