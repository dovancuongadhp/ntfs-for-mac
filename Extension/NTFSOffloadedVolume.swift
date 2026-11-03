import FSKit
import NTFSCore

/// A volume whose file data the kernel transfers itself, straight to and from
/// the device, using extents from `blockmapFile`. Much faster than passing
/// every byte through the extension. Files that can't be mapped, such as
/// compressed ones, still go through `read` and `write`.
///
/// Only for devices with `FSBlockDeviceAdapter.supportsOffloadedIO`; the
/// approach follows NTFSKit (GPL-2.0).
final class NTFSOffloadedVolume: NTFSVolume, FSVolumeKernelOffloadedIOOperations, @unchecked Sendable {
    /// The packer takes at most `UInt32.max` bytes per extent.
    private static let maximumExtentLength: UInt64 = 1 << 30

    private let resource: FSBlockDeviceResource

    init(handle: NTFSVolumeHandle, device: FSBlockDeviceAdapter, resource: FSBlockDeviceResource, uuid: UUID) {
        self.resource = resource
        super.init(handle: handle, device: device, uuid: uuid)
    }

    func blockmapFile(
        _ file: FSItem,
        offset: off_t,
        length: Int,
        flags: FSBlockmapFlags,
        operationID: FSOperationID,
        packer: FSExtentPacker,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let file = file as? NTFSItem, offset >= 0, length >= 0 else {
            reply(posixError(EINVAL))
            return
        }
        // A remainder call after the packer filled up on the last extent.
        guard length > 0 else {
            reply(nil)
            return
        }
        let forWrite = flags.contains(.write)
        let resource = resource
        let blockSize = UInt32(resource.blockSize)
        let result = perform { () throws(NTFSError) in
            device.kernelTransfersData()
            var written: [(offset: UInt64, length: UInt64)] = []
            let map = { () throws(NTFSError) in
                try self.handle.blockmap(
                    file.id, offset: UInt64(offset), length: UInt64(length),
                    forWrite: forWrite, blockSize: blockSize
                ) { extent in
                    if let physical = extent.physicalOffset {
                        written.append((physical, extent.length))
                    }
                    return Self.pack(extent, into: packer, resource: resource)
                }
            }
            if forWrite {
                try modify(map)
                // The kernel is about to write these blocks directly; drop
                // cached copies before any other engine call can read them.
                do {
                    try device.purge(written)
                } catch {
                    extensionLog.error("Purging the buffer cache failed: \(error, privacy: .public)")
                    throw .io
                }
            } else {
                try map()
            }
        }
        reply(result.error)
    }

    func completeIO(
        for file: FSItem,
        offset: off_t,
        length: Int,
        status: (any Error)?,
        flags: FSCompleteIOFlags,
        operationID: FSOperationID,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard flags.contains(.write) else {
            reply(nil)
            return
        }
        guard let file = file as? NTFSItem, offset >= 0, length >= 0 else {
            reply(posixError(EINVAL))
            return
        }
        let failed = status != nil
        let result = perform { () throws(NTFSError) in
            if failed {
                try handle.abortWrite(file.id, offset: UInt64(offset), length: UInt64(length))
            } else {
                try modify { () throws(NTFSError) in
                    try handle.completeWrite(file.id, offset: UInt64(offset), length: UInt64(length))
                }
            }
        }
        reply(failed ? nil : result.error)
    }

    func createFile(
        name: FSFileName,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        packer: FSExtentPacker,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        createItem(named: name, type: .file, inDirectory: directory, attributes: attributes, replyHandler: reply)
    }

    func lookupItem(
        name: FSFileName,
        in directory: FSItem,
        packer: FSExtentPacker,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        lookupItem(named: name, inDirectory: directory, replyHandler: reply)
    }

    /// Packs `extent` in pieces the packer accepts. Returns false once the
    /// packer is full; FSKit then asks again for the rest.
    private static func pack(_ extent: Extent, into packer: FSExtentPacker, resource: FSBlockDeviceResource) -> Bool {
        var done: UInt64 = 0
        while done < extent.length {
            let length = min(extent.length - done, maximumExtentLength)
            let more = packer.packExtent(
                resource: resource,
                type: extent.physicalOffset == nil ? .zeroFill : .data,
                logicalOffset: off_t(extent.logicalOffset + done),
                physicalOffset: extent.physicalOffset.map { off_t($0 + done) } ?? 0,
                length: Int(length))
            done += length
            if !more {
                return false
            }
        }
        return true
    }
}
