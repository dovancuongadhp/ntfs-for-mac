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

    /// Proves the first block can be written later. The whole disk can't be
    /// opened read-write while any of its partitions is mounted.
    static func checkWritable(_ wholeDevice: String) throws {
        close(try open(wholeDevice, O_RDWR, ifBusy: .mounted))
    }

    /// Opens and closes the whole disk read-write, which makes macOS re-probe
    /// its partitions and DiskArbitration notice a new file system.
    static func reprobe(_ wholeDevice: String) throws {
        close(try open(wholeDevice, O_RDWR, busyRetries: 10))
    }

    /// Writes `block` only if the disk still holds `expected`, so a table that
    /// changed since it was checked is never overwritten.
    static func replaceFirstBlock(of wholeDevice: String, expected: [UInt8], with block: [UInt8]) throws {
        guard block.count == expected.count else { throw FormatToolError.ioError }
        let descriptor = try open(wholeDevice, O_RDWR, busyRetries: 10)
        defer { close(descriptor) }
        guard try read(descriptor, count: expected.count) == expected else { throw FormatToolError.badPartitionTable }
        guard pwrite(descriptor, block, block.count, 0) == block.count, fsync(descriptor) == 0 else {
            throw FormatToolError.ioError
        }
    }

    private static func open(
        _ wholeDevice: String, _ flags: Int32, ifBusy busyError: FormatToolError = .ioError, busyRetries: Int = 0
    ) throws -> Int32 {
        var retries = busyRetries
        while true {
            let descriptor = Foundation.open("/dev/r" + wholeDevice, flags)
            if descriptor >= 0 { return descriptor }
            let error = errno
            if error == EBUSY, retries > 0 {
                retries -= 1
                usleep(500_000)
                continue
            }
            FileHandle.standardError.write(Data("ntfs-format: open /dev/r\(wholeDevice): \(String(cString: strerror(error)))\n".utf8))
            throw error == EBUSY ? busyError : FormatToolError.ioError
        }
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var block = [UInt8](repeating: 0, count: count)
        guard pread(descriptor, &block, count, 0) == count else { throw FormatToolError.ioError }
        return block
    }
}
