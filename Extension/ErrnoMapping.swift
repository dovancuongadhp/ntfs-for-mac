import FSKit
import NTFSCore

func posixError(_ code: Int32) -> any Error {
    fs_errorForPOSIXError(code)
}

/// Converts errors from the NTFS layer into the POSIX errors FSKit expects.
func fileSystemError(_ error: any Error) -> any Error {
    switch error {
    case let error as NTFSError:
        return posixError(error.code)
    case let error as POSIXError:
        return posixError(error.code.rawValue)
    case let error as NTFSMountError:
        switch error {
        case .notNTFS: return posixError(EINVAL)
        case .bitLocker: return posixError(ENOTSUP)
        case .failed(let underlying): return posixError(underlying.code)
        }
    default:
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain ? error : posixError(EIO)
    }
}

extension FSItem.Identifier {
    /// FSKit reserves 2 for the root directory; NTFS keeps the root in MFT
    /// record 5 and never exposes records below 16, so the two never collide.
    init(_ id: ItemID) {
        self = id == .root ? .rootDirectory : FSItem.Identifier(rawValue: id) ?? .invalid
    }
}

extension ItemType {
    var fileSystemType: FSItem.ItemType {
        switch self {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        }
    }
}
