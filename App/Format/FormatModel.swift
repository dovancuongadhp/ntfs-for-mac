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
/// it differs when the work starts. Mount state and partition content are
/// left out: unmounting and re-typing the partition must not change it.
struct DiskFingerprint: Equatable, Sendable {
    struct Child: Equatable, Sendable {
        var bsdName: String
        var mediaUUID: String?
        var volumeUUID: String?
    }

    var bsdName: String
    var wholeBSDName: String
    var size: UInt64
    var offset: UInt64?
    var mediaUUID: String?
    /// Of the whole drive, so an identical-looking replacement is noticed.
    var deviceModel: String?
    var mediaName: String?
    /// For a whole disk: its partitions.
    var children: [Child]

    /// `whole` is the drive holding `info`, or `info` itself for a whole disk.
    init(info: DiskInfo, whole: DiskInfo?, children: [DiskInfo]) {
        let whole = info.isWhole ? info : whole
        bsdName = info.bsdName
        wholeBSDName = info.wholeBSDName
        size = info.size
        offset = info.offset
        mediaUUID = info.mediaUUID
        deviceModel = whole?.deviceModel
        mediaName = whole?.mediaName
        self.children = children.map { Child(bsdName: $0.bsdName, mediaUUID: $0.mediaUUID, volumeUUID: $0.volumeUUID) }
    }

    /// Reads the device, its drive and, for a whole disk, its partitions again
    /// now; `nil` if any of them is gone.
    @MainActor
    static func read(
        _ bsdName: String, freshInfo: (String) -> DiskInfo?, childNames: (String) -> [String]
    ) -> DiskFingerprint? {
        guard let info = freshInfo(bsdName) else { return nil }
        let whole = info.isWhole ? info : freshInfo(info.wholeBSDName)
        guard whole != nil else { return nil }
        var children: [DiskInfo] = []
        if info.isWhole {
            for name in childNames(bsdName) {
                guard let child = freshInfo(name) else { return nil }
                children.append(child)
            }
        }
        return DiskFingerprint(info: info, whole: whole, children: children)
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
            String(localized: "The drive was erased and formatted as exFAT, but NTFS formatting didn't finish (\(detail)). Format it again as NTFS.")
        case .blocked(let reason):
            reason
        }
    }
}
