import FSKit
import NTFSCore

/// Presents an FSKit block device to `NTFSVolumeHandle`.
final class FSBlockDeviceAdapter: BlockDevice {
    private let resource: FSBlockDeviceResource
    let size: UInt64
    let sectorSize: UInt32
    let isWritable: Bool

    init(_ resource: FSBlockDeviceResource) {
        self.resource = resource
        size = resource.blockCount * resource.blockSize
        // Direct I/O must be aligned to the physical sector, which can be
        // larger than the logical block size on 512e drives.
        sectorSize = UInt32(max(resource.blockSize, resource.physicalBlockSize, 512))
        isWritable = resource.isWritable
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try resource.read(into: buffer, startingAt: off_t(offset), length: buffer.count)
    }

    func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try resource.write(from: buffer, startingAt: off_t(offset), length: buffer.count)
    }

    func flush() throws {
        // Direct reads and writes bypass the buffer cache, so there is nothing to flush.
    }
}
