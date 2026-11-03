import FSKit
import NTFSCore

extension NTFSVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let item = item as? NTFSItem, modes.contains(.write) else {
            reply(nil)
            return
        }
        let result = perform { () throws(NTFSError) in
            if handle.isReadOnly {
                throw .readOnly
            }
            item.isOpenForWriting = true
        }
        reply(result.error)
    }

    /// `modes` are the access modes the kernel still holds after this close.
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let item = item as? NTFSItem, !modes.contains(.write) else {
            reply(nil)
            return
        }
        let result = perform { () throws(NTFSError) in
            guard item.isOpenForWriting else { return }
            item.isOpenForWriting = false
            if !handle.isReadOnly {
                try modify { () throws(NTFSError) in try handle.closeFile(item.id) }
            }
        }
        reply(result.error)
    }
}

extension NTFSVolume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem, offset >= 0 else {
            reply(0, posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) -> Int in
            try buffer.withUnsafeMutableBytes { (bytes) throws(NTFSError) -> Int in
                let count = min(length, bytes.count)
                return try handle.read(
                    item.id, at: UInt64(offset),
                    into: UnsafeMutableRawBufferPointer(rebasing: bytes[0..<count]))
            }
        }
        switch result {
        case .success(let count): reply(count, nil)
        case .failure(let error): reply(0, error)
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem, offset >= 0 else {
            reply(0, posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) -> Int in
            try modify { () throws(NTFSError) -> Int in
                try contents.withUnsafeBytes { bytes in
                    Result { () throws(NTFSError) in try handle.write(item.id, at: UInt64(offset), from: bytes) }
                }.get()
            }
        }
        switch result {
        case .success(let count): reply(count, nil)
        case .failure(let error): reply(0, error)
        }
    }
}
