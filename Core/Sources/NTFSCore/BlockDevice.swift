import Foundation

/// Raw storage holding an NTFS file system.
///
/// `NTFSVolumeHandle` only issues reads and writes whose offset and length are
/// multiples of `sectorSize`.
public protocol BlockDevice: AnyObject {
    var size: UInt64 { get }
    var sectorSize: UInt32 { get }
    var isWritable: Bool { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
    func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int
    func flush() throws
}

/// A block device backed by a regular file or a `/dev/rdisk` node.
public final class FileBlockDevice: BlockDevice {
    public let size: UInt64
    public let sectorSize: UInt32
    public let isWritable: Bool
    private let descriptor: Int32

    public init(path: String, writable: Bool, sectorSize: UInt32 = 512) throws {
        let fd = open(path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = fd
        self.size = UInt64(info.st_size)
        self.sectorSize = sectorSize
        self.isWritable = writable
    }

    deinit {
        close(descriptor)
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let n = pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }

    public func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        let n = pwrite(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }

    public func flush() throws {
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

func errnoValue(for error: any Error) -> Int32 {
    if let posix = error as? POSIXError {
        return posix.code.rawValue
    }
    if let ntfs = error as? NTFSError {
        return ntfs.code
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        return Int32(nsError.code)
    }
    return EIO
}
