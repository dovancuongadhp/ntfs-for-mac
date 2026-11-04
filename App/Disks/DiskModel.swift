import Foundation
import NTFSShared

/// Media content values reported by DiskArbitration.
enum DiskContent {
    static let apfsStore = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    static let apfsContainer = "EF57347C-0000-11AA-AA11-00306543ECAC"
    static let microsoftBasicData = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
    static let virtualProtocol = "Virtual Interface"

    static func isAPFSStore(_ content: String?) -> Bool {
        content?.uppercased() == apfsStore || content == "Apple_APFS"
    }

    /// Partitions that hold no user data and stay out of the sidebar.
    static let hidden: Set<String> = [
        "EFI", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
        "Apple_Boot", "426F6F74-0000-11AA-AA11-00306543ECAC",
        "Apple_APFS_Recovery", "52637672-7900-11AA-AA11-00306543ECAC",
        "Microsoft Reserved", "E3C9E316-0B5C-4DB8-817D-F92DF00215AE",
        "Apple_partition_map", "Apple_Free", "Apple_Void",
    ]

    /// APFS roles of the volumes that make up macOS.
    static let systemRoles: Set<String> = [
        "System", "Data", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband", "Installer",
    ]
    /// System helper volumes that never appear in the sidebar.
    static let hiddenRoles: Set<String> = ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband"]
}

/// One DiskArbitration disk object, with what IOKit adds.
struct DiskInfo: Equatable, Sendable {
    var bsdName: String
    var wholeBSDName: String
    var isWhole = false
    var isLeaf = true
    var size: UInt64 = 0
    var blockSize: UInt64 = 512
    /// Byte offset of a partition on its disk (IOMedia "Base").
    var offset: UInt64?
    var partitionID: Int?
    var content: String?
    var mediaName: String?
    var mediaUUID: String?
    var volumeKind: String?
    var volumeName: String?
    var volumeUUID: String?
    var mount: NTFSDisk.Mount?
    var isWritable = true
    var isEjectable = false
    var isInternal = false
    var deviceProtocol: String?
    var deviceModel: String?
    var isRemovable = false
    /// "Solid State" or "Rotational", when the device reports it.
    var mediumType: String?
    var interconnect: String?
    /// For an APFS container's whole disk: the partition that stores it.
    var physicalStore: String?
    /// For an APFS container's whole disk: every partition it is stored on.
    /// More than one (a Fusion-style container) can't be formatted safely.
    var physicalStores: [String] = []
    /// IORegistry entry ID of the IOMedia object; a new one each time the drive is attached.
    var registryID: UInt64?
    var apfsRoles: [String] = []
    var hasTimeMachineBackup = false

    var displayName: String {
        volumeName ?? mediaName ?? bsdName
    }

    /// Same key 1.0.1 used, so "Allow writing" settings survive the update.
    var preferenceKey: String {
        mediaUUID ?? volumeUUID ?? "\(bsdName)-\(size)"
    }
}

enum PartitionScheme: Equatable, Sendable {
    case gpt, mbr, none

    init(content: String?) {
        switch content {
        case "GUID_partition_scheme": self = .gpt
        case "FDisk_partition_scheme": self = .mbr
        default: self = .none
        }
    }
}

enum FileSystemKind: Hashable, Sendable {
    case ntfs, exfat, fat, apfs, hfs
    case other(String)
    case unknown

    init(volumeKind: String?, content: String?, mountedAs: String? = nil) {
        if NTFSDisk.isNTFSFileSystem(mountedAs) {
            self = .ntfs
            return
        }
        switch volumeKind {
        case Identifiers.systemDriverTypeName?, Identifiers.fileSystemTypeName?: self = .ntfs
        case "exfat"?: self = .exfat
        case "msdos"?: self = .fat
        case "apfs"?: self = .apfs
        case "hfs"?: self = .hfs
        case let kind?: self = .other(kind)
        case nil:
            switch content {
            case "Windows_NTFS"?: self = .ntfs
            case DiskContent.apfsStore?, "Apple_APFS"?: self = .apfs
            default: self = .unknown
            }
        }
    }

    var label: String {
        switch self {
        case .ntfs: "NTFS"
        case .exfat: "exFAT"
        case .fat: "FAT"
        case .apfs: "APFS"
        case .hfs: "Mac OS Extended"
        case .other(let kind): kind
        case .unknown: "—"
        }
    }
}

struct Partition: Identifiable, Equatable, Sendable {
    var id: String { bsdName }

    let bsdName: String
    let wholeBSDName: String
    var name: String
    var fileSystem: FileSystemKind
    var size: UInt64
    var offset: UInt64?
    var partitionID: Int?
    var content: String?
    var volumeKind: String?
    var preferenceKey: String
    var volumeUUID: String?
    var mount: NTFSDisk.Mount?
    var isWritable: Bool
    var isHidden: Bool
    var apfsRoles: [String]
    var isTimeMachine: Bool
    /// For an APFS volume: the partition holding its container. Formatting the
    /// volume formats that partition.
    var apfsStore: String?
    /// For an APFS store or volume: how many partitions its container is
    /// stored on, or `nil` if no container was found.
    var containerStoreCount: Int?

    var isRecognized: Bool { volumeKind != nil || NTFSDisk.isNTFSFileSystem(mount?.fileSystemType) }
    var isAPFSStore: Bool { DiskContent.isAPFSStore(content) }

    /// The view the NTFS mount logic works with, for NTFS partitions.
    var ntfsDisk: NTFSDisk? {
        guard NTFSDisk.isCandidate(content: content, volumeKind: volumeKind, mountedAs: mount?.fileSystemType) else {
            return nil
        }
        return NTFSDisk(
            bsdName: bsdName, name: name, preferenceKey: preferenceKey,
            isRecognized: isRecognized, isWritableMedia: isWritable, mount: mount)
    }
}

/// What kind of storage a physical disk is, as far as macOS tells us.
enum DriveKind: Equatable, Sendable {
    case ssd, hdd, sdCard, usbFlash, unknown

    /// A USB flash drive reports no medium type, so it is recognised as a
    /// removable USB device with none; an enclosure that also reports nothing
    /// stays `unknown` rather than being guessed.
    static func classify(mediumType: String?, interconnect: String?, isRemovable: Bool) -> DriveKind {
        if interconnect == "Secure Digital" { return .sdCard }
        switch mediumType {
        case "Solid State": return .ssd
        case "Rotational": return .hdd
        default: break
        }
        return interconnect == "USB" && isRemovable ? .usbFlash : .unknown
    }

    var label: String? {
        switch self {
        case .ssd: "SSD"
        case .hdd: String(localized: "Hard drive (HDD)")
        case .sdCard: String(localized: "SD card")
        case .usbFlash: String(localized: "USB flash drive")
        case .unknown: nil
        }
    }

    var symbol: String? {
        self == .sdCard ? "sdcard" : nil
    }
}

struct PhysicalDisk: Identifiable, Equatable, Sendable {
    var id: String { bsdName }

    let bsdName: String
    var name: String
    var size: UInt64
    var scheme: PartitionScheme
    var isInternal: Bool
    var isVirtual: Bool
    var isEjectable: Bool
    var isWritable: Bool
    var connection: String?
    var kind: DriveKind = .unknown
    var blockSize: UInt64
    /// Partitions in disk order, each APFS store followed by its volumes.
    var partitions: [Partition]

    var sidebarPartitions: [Partition] { partitions.filter { !$0.isHidden } }
    /// Partitions as laid out on the disk, for the partition map.
    var mapPartitions: [Partition] { partitions.filter { $0.apfsStore == nil } }
}
