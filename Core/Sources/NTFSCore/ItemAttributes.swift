import CNTFS
import Foundation

/// NTFS MFT record number. The root directory is `ItemID.root`.
public typealias ItemID = UInt64

extension ItemID {
    public static let root: ItemID = NB_ROOT_ID
}

public enum ItemType: Sendable, Equatable {
    case file
    case directory
    case symlink

    init(bridgeValue: UInt32) {
        switch bridgeValue {
        case NB_TYPE_DIRECTORY.rawValue: self = .directory
        case NB_TYPE_SYMLINK.rawValue: self = .symlink
        default: self = .file
        }
    }
}

/// Windows file attribute bits that map onto macOS concepts.
public struct NTFSFileFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readOnly = NTFSFileFlags(rawValue: UInt32(NB_ATTR_READONLY))
    public static let hidden = NTFSFileFlags(rawValue: UInt32(NB_ATTR_HIDDEN))
    public static let system = NTFSFileFlags(rawValue: UInt32(NB_ATTR_SYSTEM))
    public static let archive = NTFSFileFlags(rawValue: UInt32(NB_ATTR_ARCHIVE))
    public static let sparse = NTFSFileFlags(rawValue: UInt32(NB_ATTR_SPARSE))
    public static let reparsePoint = NTFSFileFlags(rawValue: UInt32(NB_ATTR_REPARSE))
    public static let compressed = NTFSFileFlags(rawValue: UInt32(NB_ATTR_COMPRESSED))
    public static let encrypted = NTFSFileFlags(rawValue: UInt32(NB_ATTR_ENCRYPTED))
}

public struct ItemAttributes: Sendable, Equatable {
    public var id: ItemID
    public var type: ItemType
    public var flags: NTFSFileFlags
    public var size: UInt64
    public var allocatedSize: UInt64
    public var linkCount: UInt32
    public var accessTime: timespec
    public var modifyTime: timespec
    public var changeTime: timespec
    public var birthTime: timespec

    init(_ raw: nb_attributes) {
        id = raw.id
        type = ItemType(bridgeValue: raw.type)
        flags = NTFSFileFlags(rawValue: raw.ntfs_flags)
        size = raw.size
        allocatedSize = raw.alloc_size
        linkCount = raw.link_count
        accessTime = raw.access_time
        modifyTime = raw.modify_time
        changeTime = raw.change_time
        birthTime = raw.birth_time
    }

    public static func == (lhs: ItemAttributes, rhs: ItemAttributes) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.flags == rhs.flags
            && lhs.size == rhs.size && lhs.allocatedSize == rhs.allocatedSize
            && lhs.linkCount == rhs.linkCount
            && lhs.accessTime.tv_sec == rhs.accessTime.tv_sec
            && lhs.accessTime.tv_nsec == rhs.accessTime.tv_nsec
            && lhs.modifyTime.tv_sec == rhs.modifyTime.tv_sec
            && lhs.modifyTime.tv_nsec == rhs.modifyTime.tv_nsec
            && lhs.changeTime.tv_sec == rhs.changeTime.tv_sec
            && lhs.changeTime.tv_nsec == rhs.changeTime.tv_nsec
            && lhs.birthTime.tv_sec == rhs.birthTime.tv_sec
            && lhs.birthTime.tv_nsec == rhs.birthTime.tv_nsec
    }
}

public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var id: ItemID
    public var type: ItemType
}

public struct VolumeStatistics: Sendable, Equatable {
    public var clusterSize: UInt32
    public var totalClusters: UInt64
    public var freeClusters: UInt64
    public var totalFiles: UInt64
    public var freeFiles: UInt64
    public var maximumNameLength: UInt32

    public var totalBytes: UInt64 { totalClusters * UInt64(clusterSize) }
    public var freeBytes: UInt64 { freeClusters * UInt64(clusterSize) }
}

public enum ReadOnlyReason: Sendable, Equatable {
    case requested
    case hibernated
    case uncleanJournal
    case dirty
    case ioError
    case deviceReadOnly

    init?(bridgeValue: nb_readonly_reason) {
        switch bridgeValue {
        case NB_RO_REQUESTED: self = .requested
        case NB_RO_HIBERNATED: self = .hibernated
        case NB_RO_UNCLEAN_JOURNAL: self = .uncleanJournal
        case NB_RO_DIRTY: self = .dirty
        case NB_RO_IO_ERROR: self = .ioError
        case NB_RO_DEVICE: self = .deviceReadOnly
        default: return nil
        }
    }
}
