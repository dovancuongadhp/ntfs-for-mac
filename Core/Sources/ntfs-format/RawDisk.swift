import Foundation
import NTFSFormat

/// The first block of a whole disk, read and written through its raw device.
///
/// Every call opens and closes the device itself. Nothing may stay open while
/// mkntfs runs: a whole disk held open read-write makes macOS withdraw its
/// partition devices, and mkntfs then can't find the partition.
enum RawDisk {
    static func readFirstBlock(of wholeDevice: String, blockSize: Int) throws -> [UInt8] {
        let descriptor = try open(wholeDevice, O_RDONLY)
        defer { close(descriptor) }
        return try read(descriptor, count: blockSize)
    }

    /// Writes `block` only if the disk still holds `expected`, so a table that
    /// changed since it was checked is never overwritten.
    static func replaceFirstBlock(of wholeDevice: String, expected: [UInt8], with block: [UInt8]) throws {
        guard block.count == expected.count else { throw FormatToolError.ioError }
        let descriptor = try open(wholeDevice, O_RDWR)
        defer { close(descriptor) }
        guard try read(descriptor, count: expected.count) == expected else { throw FormatToolError.badPartitionTable }
        guard pwrite(descriptor, block, block.count, 0) == block.count, fsync(descriptor) == 0 else {
            throw FormatToolError.ioError
        }
    }

    private static func open(_ wholeDevice: String, _ flags: Int32) throws -> Int32 {
        let descriptor = Foundation.open("/dev/r" + wholeDevice, flags)
        guard descriptor >= 0 else {
            FileHandle.standardError.write(Data("ntfs-format: open /dev/r\(wholeDevice): \(String(cString: strerror(errno)))\n".utf8))
            throw FormatToolError.ioError
        }
        return descriptor
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var block = [UInt8](repeating: 0, count: count)
        guard pread(descriptor, &block, count, 0) == count else { throw FormatToolError.ioError }
        return block
    }
}
