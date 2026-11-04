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

/// What identifies the device the user confirmed. It is checked before every
/// write to a known device, including ntfs-format after diskutil re-typed the
/// partition, and formatting stops if any of it differs. Mount state and
/// partition content are left out: unmounting and re-typing must not change it.
/// Erasing can give a partition a new GUID, so after diskutil erased it only
/// `matchesErased` holds; after `eraseDisk` only `matchesDrive`.
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
    var wholeSize: UInt64?
    /// Changes whenever the drive is attached again, even under the same BSD name.
    var wholeRegistryID: UInt64?
    /// For a whole disk: its partitions.
    var children: [Child]

    var isPartition: Bool { bsdName != wholeBSDName }

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
        wholeSize = whole?.size
        wholeRegistryID = whole?.registryID
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

    /// The same drive and the same partition on it, whatever GUID and file-system
    /// size erasing left. `diskutil` reports the new file system, which is smaller
    /// than the partition it was written on.
    func matchesErased(_ current: DiskFingerprint) -> Bool {
        var current = current
        current.mediaUUID = mediaUUID
        current.size = size
        return current == self
    }

    /// The same drive, still attached since the sheet opened, whatever its
    /// partitions are now. `drive` is read from the whole disk alone.
    func matchesDrive(_ drive: DiskFingerprint) -> Bool {
        drive.bsdName == wholeBSDName && drive.wholeBSDName == wholeBSDName
            && drive.wholeRegistryID == wholeRegistryID && drive.deviceModel == deviceModel
            && drive.mediaName == mediaName && drive.wholeSize == wholeSize
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
    /// `partition`: only that partition was erased, not the whole drive.
    /// After the exFAT placeholder for NTFS was created.
    case ntfsFailedAfterErase(String, partition: Bool = false)
    /// After anything else was erased.
    case failedAfterErase(String, partition: Bool = false)
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
        case .ntfsFailedAfterErase(let detail, partition: true):
            String(localized: "The partition was erased and formatted as exFAT, but NTFS formatting didn't finish (\(detail)). Format it again as NTFS.")
        case .ntfsFailedAfterErase(let detail, partition: false):
            String(localized: "The drive was erased and formatted as exFAT, but NTFS formatting didn't finish (\(detail)). Format it again as NTFS.")
        case .failedAfterErase(let detail, partition: true):
            String(localized: "The partition was erased, but formatting didn't finish (\(detail)). Format it again.")
        case .failedAfterErase(let detail, partition: false):
            String(localized: "The drive was erased, but formatting didn't finish (\(detail)). Format it again.")
        case .blocked(let reason):
            reason
        }
    }
}
