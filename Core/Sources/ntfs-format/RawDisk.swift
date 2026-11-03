import Foundation
import NTFSFormat

/// The first block of a whole disk, read and written through its raw device.
final class RawDisk {
    private let descriptor: Int32
    private let blockSize: Int

    /// Opens read-write up front, so a busy disk is refused before anything is formatted.
    init(wholeDevice: String, blockSize: Int) throws {
        descriptor = open("/dev/r" + wholeDevice, O_RDWR)
        guard descriptor >= 0 else {
            FileHandle.standardError.write(Data("ntfs-format: open /dev/r\(wholeDevice): \(String(cString: strerror(errno)))\n".utf8))
            throw FormatToolError.ioError
        }
        self.blockSize = blockSize
    }

    deinit {
        close(descriptor)
    }

    func readFirstBlock() throws -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockSize)
        guard pread(descriptor, &block, blockSize, 0) == blockSize else { throw FormatToolError.ioError }
        return block
    }

    func writeFirstBlock(_ block: [UInt8]) throws {
        guard block.count == blockSize,
              pwrite(descriptor, block, blockSize, 0) == blockSize,
              fsync(descriptor) == 0
        else { throw FormatToolError.ioError }
    }
}
