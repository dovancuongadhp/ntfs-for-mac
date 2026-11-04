import Foundation

public enum FileKind: Sendable, Equatable {
    case file, directory, symlink, other
}

public struct FileAttributes: Sendable, Equatable {
    public var kind: FileKind
    public var size: Int64
    public var modified: Date

    public init(kind: FileKind, size: Int64 = 0, modified: Date = .distantPast) {
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// One thing to create at the destination: a folder, a file or a symbolic link.
public struct TransferJob: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case directory
        case file
        case symlink(target: String)
    }

    public var id: Int
    public var kind: Kind
    public var source: URL
    public var destination: URL
    public var size: Int64
    public var modified: Date

    public init(id: Int, kind: Kind, source: URL, destination: URL, size: Int64 = 0, modified: Date = .distantPast) {
        self.id = id
        self.kind = kind
        self.source = source
        self.destination = destination
        self.size = size
        self.modified = modified
    }

    public var name: String { destination.lastPathComponent }
    public var isDirectory: Bool { kind == .directory }

    /// The temporary URL used while this file is being written.
    ///
    /// For short names the form is `.<name>.ntfs-part`.  When the name is long enough that
    /// appending the prefix and suffix would exceed 255 bytes the form is `.ntfs-part-<id>`
    /// so the path stays valid on every file system.
    public var tempURL: URL {
        let folder = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let proposed = ".\(name).ntfs-part"
        if proposed.utf8.count <= 255 {
            return folder.appending(component: proposed)
        }
        return folder.appending(component: ".ntfs-part-\(id)")
    }
}

public enum TransferFailureReason: Sendable, Equatable, Codable {
    case unreadable
    case writeFailed
    case noSpace
    case driveRemoved
    case permissionDenied
    case invalidName
    case checksumMismatch
    case sizeMismatch
    case sourceMissing
    case conflictingKind
    case fileTooLarge

    /// These end the whole run, not just the file they happened on.
    public var stopsTransfer: Bool { self == .noSpace || self == .driveRemoved }
}

public struct TransferFailure: Error, Sendable, Equatable, Codable {
    public var reason: TransferFailureReason
    /// The system's own words, for the error list. Not meant for the main message.
    public var detail: String

    public init(_ reason: TransferFailureReason, detail: String = "") {
        self.reason = reason
        self.detail = detail
    }

    /// Turns an error thrown by a read or a write into a reason the user can act on.
    public static func classify(_ error: any Error, reading: Bool) -> TransferFailure {
        let detail = error.localizedDescription
        let fallback: TransferFailureReason = reading ? .unreadable : .writeFailed
        guard let code = errnoCode(of: error) else { return TransferFailure(fallback, detail: detail) }
        switch code {
        case ENOSPC, EDQUOT: return TransferFailure(.noSpace, detail: detail)
        case ENXIO, ENODEV, ENOTCONN, ESTALE: return TransferFailure(.driveRemoved, detail: detail)
        case EACCES, EPERM, EROFS: return TransferFailure(.permissionDenied, detail: detail)
        case EILSEQ, ENAMETOOLONG: return TransferFailure(.invalidName, detail: detail)
        case EFBIG: return TransferFailure(.fileTooLarge, detail: detail)
        case ENOENT where reading: return TransferFailure(.sourceMissing, detail: detail)
        default: return TransferFailure(fallback, detail: detail)
        }
    }

    private static func errnoCode(of error: any Error) -> Int32? {
        if let posix = error as? POSIXError { return posix.code.rawValue }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }
}
