import Darwin
import Foundation
import NTFSFormat

/// The first block of a whole disk, read and written through an already
/// authorized descriptor.
///
/// Nothing may stay open while mkntfs runs: a whole disk held open read-write
/// makes macOS withdraw its partition devices, and mkntfs then can't find the
/// partition. Callers open, use, and close the descriptor around each step.
enum RawDisk {
    static func readFirstBlock(fd: Int32, blockSize: Int) throws -> [UInt8] {
        try read(fd, count: blockSize)
    }

    /// Writes `block` only if the disk still holds `expected`, so a table that
    /// changed since it was checked is never overwritten.
    static func replaceFirstBlock(fd: Int32, expected: [UInt8], with block: [UInt8]) throws {
        guard block.count == expected.count else { throw FormatToolError.ioError }
        guard try read(fd, count: expected.count) == expected else { throw FormatToolError.badPartitionTable }
        guard pwrite(fd, block, block.count, 0) == block.count, fsync(fd) == 0 else {
            throw FormatToolError.ioError
        }
    }

    private static func read(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var block = [UInt8](repeating: 0, count: count)
        guard pread(descriptor, &block, count, 0) == count else { throw FormatToolError.ioError }
        return block
    }
}
