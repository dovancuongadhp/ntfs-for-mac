import Foundation
import NTFSShared

/// An NTFS partition as seen through DiskArbitration, plus where and how it is mounted.
struct NTFSDisk: Identifiable, Equatable, Sendable {
    var id: String { bsdName }

    let bsdName: String
    var name: String
    /// Key for per-drive settings: the partition UUID when there is one, so the
    /// setting survives remounting with a different driver.
    var preferenceKey: String
    /// DiskArbitration recognised a file system on the partition.
    var isRecognized: Bool
    var isWritableMedia: Bool
    var mount: Mount?

    struct Mount: Equatable, Sendable {
        var path: URL
        var fileSystemType: String
        var isReadOnly: Bool
        var totalBytes: UInt64
        var freeBytes: UInt64
    }

    var isMountedByExtension: Bool {
        guard let mount else { return false }
        return mount.fileSystemType != Identifiers.systemDriverTypeName
    }

    var isMountedBySystemDriver: Bool {
        mount?.fileSystemType == Identifiers.systemDriverTypeName
    }

    /// Partition content hints that may hold NTFS: MBR type 0x07 and the GPT
    /// Microsoft Basic Data type (shared with FAT and exFAT).
    static let contentHints: Set<String> = ["Windows_NTFS", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"]

    /// A live mount reports this when the volume is NTFS, whichever driver claimed it.
    static func isNTFSFileSystem(_ type: String?) -> Bool {
        type == Identifiers.systemDriverTypeName
            || type == Identifiers.fileSystemTypeName
            || type == Identifiers.fileSystemShortName
    }

    /// Whether a partition with this content hint and volume kind should be listed.
    /// `mountedAs` wins: DiskArbitration can keep the previous kind (exFAT, FAT)
    /// after `mkntfs` until something mounts the new file system.
    static func isCandidate(content: String?, volumeKind: String?, mountedAs: String? = nil) -> Bool {
        if isNTFSFileSystem(mountedAs) { return true }
        if let volumeKind {
            return isNTFSFileSystem(volumeKind)
        }
        return content.map(contentHints.contains) ?? false
    }
}

enum DiskState: Equatable {
    case readWrite
    /// Mounted read-only by this app; `nil` when the reason is not known.
    case readOnly(ReadOnlyReason?)
    /// Mounted by macOS's own read-only NTFS driver.
    case systemReadOnly
    case notMounted
    /// No file system was recognised, e.g. a BitLocker-encrypted partition.
    case unrecognized
}

extension NTFSDisk {
    func state(reason: ReadOnlyReason?, writeEnabled: Bool) -> DiskState {
        guard let mount else {
            return isRecognized ? .notMounted : .unrecognized
        }
        if isMountedBySystemDriver {
            return .systemReadOnly
        }
        guard mount.isReadOnly else {
            return .readWrite
        }
        if !isWritableMedia {
            return .readOnly(.deviceReadOnly)
        }
        return .readOnly(reason ?? (writeEnabled ? nil : .requested))
    }
}
