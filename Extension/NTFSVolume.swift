import FSKit
import NTFSCore

/// One mounted NTFS volume.
///
/// FSKit calls in from many threads at once; every call into libntfs-3g goes
/// through `lock`, which also guards the item and directory caches.
///
/// File data goes through the extension; `NTFSOffloadedVolume` lets the
/// kernel transfer it instead where the device allows.
class NTFSVolume: FSVolume, @unchecked Sendable {
    private let lock = NSLock()
    let handle: NTFSVolumeHandle
    /// Guarded by `lock`, like the handle that uses it.
    let device: FSBlockDeviceAdapter
    private(set) var root: NTFSItem
    private var items: [ItemID: NTFSItem] = [:]
    private var snapshots: [ItemID: DirectorySnapshot] = [:]
    private var nextVerifier: UInt64 = 1

    init(handle: NTFSVolumeHandle, device: FSBlockDeviceAdapter, uuid: UUID) {
        self.handle = handle
        self.device = device
        root = NTFSItem(id: .root, parent: .root)
        let label = handle.label
        super.init(
            volumeID: FSVolume.Identifier(uuid: uuid),
            volumeName: FSFileName(string: label.isEmpty ? "NTFS" : label)
        )
        items[.root] = root
    }

    /// Flushes and releases the volume when FSKit unloads the resource.
    func close() {
        lock.withLock {
            do {
                try handle.unmount()
            } catch {
                extensionLog.error("Unmount failed: \(String(describing: error), privacy: .public)")
            }
            items.removeAll()
            snapshots.removeAll()
        }
    }

    // MARK: Helpers for the operation extensions

    /// Runs `body` under the volume lock and converts errors for FSKit.
    func perform<T>(_ body: () throws(NTFSError) -> T) -> Result<T, any Error> {
        lock.lock()
        defer { lock.unlock() }
        do {
            return .success(try body())
        } catch {
            return .failure(posixError(error.code))
        }
    }

    /// Wraps a modifying call: refuses it on a read-only volume, and turns an
    /// I/O error into a permanent switch to read-only so a failing disk is not
    /// written to again. Call only from inside `perform`.
    func modify<T>(_ body: () throws(NTFSError) -> T) throws(NTFSError) -> T {
        if handle.isReadOnly {
            throw .readOnly
        }
        do {
            return try body()
        } catch {
            if error.code == EIO {
                extensionLog.error("Write failed with EIO; volume is now read-only")
                handle.forceReadOnly(reason: .ioError)
                ReadOnlyNotifier.post(.ioError)
            }
            throw error
        }
    }

    /// The single live item for `id`, created on first use. Call only from inside `perform`.
    func item(for id: ItemID, parent: ItemID) -> NTFSItem {
        if let existing = items[id] {
            if id != .root {
                existing.parent = parent
            }
            return existing
        }
        let item = NTFSItem(id: id, parent: parent)
        items[id] = item
        return item
    }

    func forget(_ item: NTFSItem) {
        if item.id != .root, items[item.id] === item {
            items[item.id] = nil
        }
    }

    /// Call only from inside `perform`.
    func snapshot(of directory: ItemID, verifier: UInt64, restart: Bool) throws(NTFSError) -> DirectorySnapshot {
        if !restart, let cached = snapshots[directory], cached.verifier == verifier {
            return cached
        }
        let snapshot = DirectorySnapshot(entries: try handle.entries(of: directory), verifier: nextVerifier)
        nextVerifier += 1
        snapshots[directory] = snapshot
        return snapshot
    }

    func directoryChanged(_ directory: ItemID) {
        snapshots[directory] = nil
    }

    func finishedEnumerating(_ directory: ItemID) {
        snapshots[directory] = nil
    }

    func fileSystemAttributes(of item: NTFSItem) throws(NTFSError) -> FSItem.Attributes {
        fileSystemAttributes(try handle.attributes(of: item.id), parent: item.parent)
    }

    func fileSystemAttributes(_ attributes: ItemAttributes, parent: ItemID) -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = attributes.type.fileSystemType
        result.mode = UInt32(attributes.type.modeBits | attributes.type.permissions)
        // The extension sets FSVolumeAlwaysIgnoreOwnership, so the kernel
        // shows every item as owned by the user looking at it.
        result.uid = 99
        result.gid = 99
        result.linkCount = attributes.linkCount
        result.flags = Self.bsdFlags(for: attributes)
        result.size = attributes.size
        result.allocSize = attributes.allocatedSize
        result.fileID = FSItem.Identifier(attributes.id)
        result.parentID = attributes.id == .root ? .parentOfRoot : FSItem.Identifier(parent)
        result.accessTime = attributes.accessTime
        result.modifyTime = attributes.modifyTime
        result.changeTime = attributes.changeTime
        result.birthTime = attributes.birthTime
        result.supportsLimitedXAttrs = false
        // Only consulted on an `NTFSOffloadedVolume`; other files go through
        // `read` and `write`.
        result.inhibitKernelOffloadedIO = attributes.type == .file && !attributes.isMappable
        return result
    }

    /// Hidden and system items are hidden in Finder; the read-only attribute on
    /// files maps to Finder's "Locked" (`uchg`). Windows ignores read-only on folders.
    static func bsdFlags(for attributes: ItemAttributes) -> UInt32 {
        var flags: UInt32 = 0
        if !attributes.flags.isDisjoint(with: [.hidden, .system]) {
            flags |= UInt32(UF_HIDDEN)
        }
        if attributes.type == .file, attributes.flags.contains(.readOnly) {
            flags |= UInt32(UF_IMMUTABLE)
        }
        return flags
    }
}

private extension ItemType {
    var modeBits: mode_t {
        switch self {
        case .file: S_IFREG
        case .directory: S_IFDIR
        case .symlink: S_IFLNK
        }
    }

    var permissions: mode_t {
        self == .file ? 0o644 : 0o755
    }
}
