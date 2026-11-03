import CNTFS

/// Where a range of a file's data lives on the device.
public struct Extent: Sendable, Equatable {
    public var logicalOffset: UInt64
    /// `nil` when the range reads as zeros.
    public var physicalOffset: UInt64?
    public var length: UInt64

    public init(logicalOffset: UInt64, physicalOffset: UInt64?, length: UInt64) {
        self.logicalOffset = logicalOffset
        self.physicalOffset = physicalOffset
        self.length = length
    }
}

/// Kernel-offloaded I/O: the kernel transfers file data itself, using extents
/// handed out here.
extension NTFSVolumeHandle {
    /// Reports the extents covering `[offset, offset + length)`, in order.
    ///
    /// For writes, clusters for the whole range are allocated first; the data
    /// only counts as written once `completeWrite` records it. `pack` returns
    /// false when it can't take more extents, which stops the mapping early.
    /// Files that can't be mapped throw `EOPNOTSUPP`.
    public func blockmap(
        _ id: ItemID,
        offset: UInt64,
        length: UInt64,
        forWrite: Bool,
        blockSize: UInt32,
        pack: (Extent) -> Bool
    ) throws(NTFSError) {
        let volume = try mounted()
        let result = withoutActuallyEscaping(pack) { pack in
            let packer = Packer(pack)
            return withExtendedLifetime(packer) {
                nb_blockmap(
                    volume, id, offset, length, forWrite ? 1 : 0, blockSize,
                    { context, logical, physical, length in
                        let packer = Unmanaged<Packer>.fromOpaque(context!).takeUnretainedValue()
                        let extent = Extent(
                            logicalOffset: logical,
                            physicalOffset: physical < 0 ? nil : UInt64(physical),
                            length: length)
                        return packer.pack(extent) ? 0 : 1
                    },
                    Unmanaged.passUnretained(packer).toOpaque())
            }
        }
        try check(result)
    }

    /// Records that the kernel finished writing a range from `blockmap`.
    public func completeWrite(_ id: ItemID, offset: UInt64, length: UInt64) throws(NTFSError) {
        try check(nb_complete_write(try mounted(), id, offset, length))
    }

    /// Records that the kernel failed to write a range from `blockmap`.
    public func abortWrite(_ id: ItemID, offset: UInt64, length: UInt64) throws(NTFSError) {
        try check(nb_abort_write(try mounted(), id, offset, length))
    }
}

private final class Packer {
    let pack: (Extent) -> Bool
    init(_ pack: @escaping (Extent) -> Bool) { self.pack = pack }
}
