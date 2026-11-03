import Foundation

/// A failure reported by libntfs-3g, carrying the POSIX error number.
public struct NTFSError: Error, Equatable, CustomStringConvertible, Sendable {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }

    public var posixCode: POSIXErrorCode? { POSIXErrorCode(rawValue: code) }

    public var description: String {
        "NTFSError(\(code): \(String(cString: strerror(code))))"
    }

    public static let notFound = NTFSError(code: ENOENT)
    public static let exists = NTFSError(code: EEXIST)
    public static let notEmpty = NTFSError(code: ENOTEMPTY)
    public static let readOnly = NTFSError(code: EROFS)
    public static let io = NTFSError(code: EIO)
    public static let invalid = NTFSError(code: EINVAL)
    public static let notSupported = NTFSError(code: EOPNOTSUPP)
}

/// Why a volume could not be mounted at all.
public enum NTFSMountError: Error, Equatable, Sendable {
    case notNTFS
    case bitLocker
    case failed(NTFSError)
}

@discardableResult
func check(_ result: Int32) throws(NTFSError) -> Int32 {
    if result < 0 {
        throw NTFSError(code: -result)
    }
    return result
}

@discardableResult
func check(_ result: Int64) throws(NTFSError) -> Int64 {
    if result < 0 {
        throw NTFSError(code: Int32(-result))
    }
    return result
}
