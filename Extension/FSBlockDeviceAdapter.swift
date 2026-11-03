import FSKit
import NTFSCore
import NTFSProbe

/// Presents an FSKit block device to `NTFSVolumeHandle`.
///
/// With kernel-offloaded I/O the kernel writes file data straight to the
/// device. Once it may do so, libntfs-3g's own I/O goes through the kernel
/// buffer cache instead of direct I/O, which would race those writes. The
/// cache is keyed by offset, so every access uses whole blocks of `sectorSize`.
final class FSBlockDeviceAdapter: BlockDevice {
    /// The buffer cache block size for offloaded I/O. A block never holds
    /// clusters of two files, so it needs clusters that are a multiple of it.
    static let cacheBlockSize: UInt32 = 4096

    /// The kernel only offloads I/O for, and only opens the buffer cache to,
    /// modules with the FSKit entitlement. That needs a paid developer
    /// account; local builds are signed without it.
    static let hasFSKitEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.fskit.fsmodule" as CFString, nil)
        return value as? Bool == true
    }()

    private let resource: FSBlockDeviceResource
    let size: UInt64
    let sectorSize: UInt32
    let isWritable: Bool
    /// The kernel may transfer file data itself: the module is entitled and
    /// the cluster size suits the cache block.
    let supportsOffloadedIO: Bool
    private(set) var usesBufferCache = false

    init(_ resource: FSBlockDeviceResource) {
        self.resource = resource
        size = resource.blockCount * resource.blockSize
        isWritable = resource.isWritable
        let block = UInt32(resource.blockSize)
        let physical = UInt32(resource.physicalBlockSize)
        let cache = Self.cacheBlockSize
        if Self.hasFSKitEntitlement, let clusterSize = Self.clusterSize(of: resource),
           clusterSize % UInt64(cache) == 0, size % UInt64(cache) == 0,
           cache % block == 0, cache >= physical {
            sectorSize = cache
            supportsOffloadedIO = true
        } else {
            // Direct I/O must be aligned to the physical sector, which can be
            // larger than the logical block size on 512e drives.
            sectorSize = max(block, physical, 512)
            supportsOffloadedIO = false
        }
    }

    /// Called once the kernel may transfer file data, which proves it has
    /// mounted the volume: the buffer cache only works from then on. Until
    /// then direct I/O can't race the kernel.
    func kernelTransfersData() {
        if supportsOffloadedIO, !usesBufferCache {
            usesBufferCache = true
            extensionLog.info("Device I/O now goes through the buffer cache")
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard usesBufferCache else {
            return try resource.read(into: buffer, startingAt: off_t(offset), length: buffer.count)
        }
        let block = Int(sectorSize)
        for start in stride(from: 0, to: buffer.count, by: block) {
            try resource.metadataRead(
                into: UnsafeMutableRawBufferPointer(rebasing: buffer[start..<start + block]),
                startingAt: off_t(offset) + off_t(start), length: block)
        }
        return buffer.count
    }

    func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        guard usesBufferCache else {
            return try resource.write(from: buffer, startingAt: off_t(offset), length: buffer.count)
        }
        let block = Int(sectorSize)
        // Synchronous: a delayed write could later land over data the kernel wrote directly.
        for start in stride(from: 0, to: buffer.count, by: block) {
            try resource.metadataWrite(
                from: UnsafeRawBufferPointer(rebasing: buffer[start..<start + block]),
                startingAt: off_t(offset) + off_t(start), length: block)
        }
        return buffer.count
    }

    func flush() throws {
        if usesBufferCache {
            try resource.metadataFlush()
        }
    }

    /// Drops cached copies of ranges the kernel is about to write directly.
    func purge(_ ranges: [(offset: UInt64, length: UInt64)]) throws {
        guard usesBufferCache, !ranges.isEmpty else { return }
        let block = UInt64(sectorSize)
        try resource.metadataPurge(ranges.map { range in
            let start = range.offset / block * block
            let end = (range.offset + range.length + block - 1) / block * block
            return FSMetadataRange(offset: off_t(start), segmentLength: block, segmentCount: (end - start) / block)
        })
    }

    /// The NTFS cluster size from the boot sector, read directly.
    private static func clusterSize(of resource: FSBlockDeviceResource) -> UInt64? {
        let length = Int(max(resource.blockSize, resource.physicalBlockSize, 512))
        let sector = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 4096)
        defer { sector.deallocate() }
        guard (try? resource.read(into: sector, startingAt: 0, length: length)) == length else { return nil }
        return BootSector.clusterSize(Array(sector))
    }
}
