import CNTFS
import Foundation
import NTFSProbe

/// A mounted NTFS volume.
///
/// libntfs-3g is not thread-safe: callers must serialize every call made on
/// one handle (the FSKit extension uses one serial queue per volume).
public final class NTFSVolumeHandle: @unchecked Sendable {
    private let deviceBox: DeviceBox
    private var volume: OpaquePointer?

    /// `nil` when the volume is writable.
    public private(set) var readOnlyReason: ReadOnlyReason?
    public let serialNumber: UInt64

    public var isReadOnly: Bool { readOnlyReason != nil }

    public init(device: BlockDevice, readOnly: Bool = false) throws(NTFSMountError) {
        try Self.probe(device)
        let box = DeviceBox(device: device)
        var callbacks = nb_device_callbacks(
            context: Unmanaged.passUnretained(box).toOpaque(),
            size: device.size,
            sector_size: device.sectorSize,
            writable: device.isWritable ? 1 : 0,
            read: deviceRead,
            write: deviceWrite,
            sync: deviceSync
        )
        var handle: OpaquePointer?
        var reason = NB_READ_WRITE
        let result = nb_mount(&callbacks, readOnly ? 1 : 0, &handle, &reason)
        guard result == 0, let handle else {
            throw .failed(NTFSError(code: -result))
        }
        self.deviceBox = box
        self.volume = handle
        self.readOnlyReason = ReadOnlyReason(bridgeValue: reason)
        self.serialNumber = nb_get_serial(handle)
    }

    deinit {
        if let volume {
            nb_unmount(volume)
        }
    }

    private static func probe(_ device: BlockDevice) throws(NTFSMountError) {
        let length = max(Int(device.sectorSize), BootSector.size)
        var sector = [UInt8](repeating: 0, count: length)
        let read = (try? sector.withUnsafeMutableBytes { try device.read(into: $0, at: 0) }) ?? 0
        guard read >= BootSector.size else { throw .notNTFS }
        switch BootSector.classify(sector) {
        case .ntfs: return
        case .bitLocker: throw .bitLocker
        case .other: throw .notNTFS
        }
    }

    /// Writes everything out and releases the volume. The handle is unusable afterwards.
    public func unmount() throws(NTFSError) {
        guard let volume else { return }
        self.volume = nil
        try check(nb_unmount(volume))
    }

    private func mounted() throws(NTFSError) -> OpaquePointer {
        guard let volume else { throw NTFSError(code: ENXIO) }
        return volume
    }

    /// Stops all further writes, e.g. after an I/O error on the write path.
    public func forceReadOnly(reason: ReadOnlyReason) {
        guard let volume, readOnlyReason == nil else { return }
        nb_force_read_only(volume)
        readOnlyReason = reason
    }

    public static func setLogHandler(_ handler: nb_log_fn?) {
        nb_set_log_handler(handler)
    }

    // MARK: Volume

    public var label: String {
        guard let volume else { return "" }
        var buffer = [CChar](repeating: 0, count: 512)
        let length = nb_get_label(volume, &buffer, UInt32(buffer.count))
        return length >= 0 ? decodeUTF8(buffer, length: Int(length)) : ""
    }

    public func setLabel(_ label: String) throws(NTFSError) {
        try check(nb_set_label(try mounted(), label))
    }

    public func statistics() throws(NTFSError) -> VolumeStatistics {
        var raw = nb_statistics()
        try check(nb_statistics_get(try mounted(), &raw))
        return VolumeStatistics(
            clusterSize: raw.cluster_size,
            totalClusters: raw.total_clusters,
            freeClusters: raw.free_clusters,
            totalFiles: raw.total_files,
            freeFiles: raw.free_files,
            maximumNameLength: raw.max_name_length
        )
    }

    public func setMountPoint(_ path: String) {
        guard let volume else { return }
        nb_set_mount_point(volume, path)
    }

    public func sync() throws(NTFSError) {
        try check(nb_sync(try mounted()))
    }

    // MARK: Items

    public func attributes(of id: ItemID) throws(NTFSError) -> ItemAttributes {
        var raw = nb_attributes()
        try check(nb_get_attributes(try mounted(), id, &raw))
        return ItemAttributes(raw)
    }

    public func lookup(_ name: String, in directory: ItemID) throws(NTFSError) -> ItemID {
        var id: UInt64 = 0
        try check(nb_lookup(try mounted(), directory, Self.diskName(name), &id))
        return id
    }

    /// All entries of a directory except `.`, `..`, DOS short names and NTFS metadata files.
    public func entries(of directory: ItemID) throws(NTFSError) -> [DirectoryEntry] {
        final class Collector {
            var entries: [DirectoryEntry] = []
        }
        let collector = Collector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = nb_read_directory(try mounted(), directory, context) { context, name, id, type in
            guard let context, let name else { return 0 }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            collector.entries.append(DirectoryEntry(
                name: String(cString: name), id: id, type: ItemType(bridgeValue: type)))
            return 0
        }
        try check(result)
        return collector.entries
    }

    public func create(_ name: String, in directory: ItemID, type: ItemType) throws(NTFSError) -> ItemID {
        let bridgeType: nb_item_type
        switch type {
        case .file: bridgeType = NB_TYPE_FILE
        case .directory: bridgeType = NB_TYPE_DIRECTORY
        case .symlink: throw .notSupported
        }
        var id: UInt64 = 0
        try check(nb_create(try mounted(), directory, Self.diskName(name), bridgeType, &id))
        return id
    }

    public func remove(_ name: String, in directory: ItemID) throws(NTFSError) {
        try check(nb_remove(try mounted(), directory, Self.diskName(name)))
    }

    public func rename(_ name: String, in source: ItemID, to newName: String, in destination: ItemID) throws(NTFSError) {
        try check(nb_rename(try mounted(), source, Self.diskName(name), destination, Self.diskName(newName)))
    }

    public func readLink(_ id: ItemID) throws(NTFSError) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let length = try check(nb_read_link(try mounted(), id, &buffer, UInt32(buffer.count)))
        return decodeUTF8(buffer, length: Int(length))
    }

    // MARK: Data

    public func read(_ id: ItemID, at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(NTFSError) -> Int {
        guard buffer.count > 0 else { return 0 }
        return Int(try check(nb_read(try mounted(), id, buffer.baseAddress, UInt64(buffer.count), offset)))
    }

    public func write(_ id: ItemID, at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(NTFSError) -> Int {
        guard buffer.count > 0 else { return 0 }
        return Int(try check(nb_write(try mounted(), id, buffer.baseAddress, UInt64(buffer.count), offset)))
    }

    public func truncate(_ id: ItemID, to size: UInt64) throws(NTFSError) {
        try check(nb_truncate(try mounted(), id, size))
    }

    public func closeFile(_ id: ItemID) throws(NTFSError) {
        try check(nb_close_file(try mounted(), id))
    }

    // MARK: Metadata

    public func setTimes(_ id: ItemID, access: timespec? = nil, modify: timespec? = nil, birth: timespec? = nil) throws(NTFSError) {
        let volume = try mounted()
        let result = withOptionalPointer(access) { access in
            withOptionalPointer(modify) { modify in
                withOptionalPointer(birth) { birth in
                    nb_set_times(volume, id, access, modify, birth)
                }
            }
        }
        try check(result)
    }

    public func setFlags(_ flags: NTFSFileFlags, on: Bool, for id: ItemID) throws(NTFSError) {
        try check(nb_set_flag(try mounted(), id, flags.rawValue, on ? 1 : 0))
    }

    /// Names are stored in NFC, the form Windows uses.
    static func diskName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}

private func decodeUTF8(_ buffer: [CChar], length: Int) -> String {
    String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func withOptionalPointer<T, R>(_ value: T?, _ body: (UnsafePointer<T>?) -> R) -> R {
    guard var value else { return body(nil) }
    return withUnsafePointer(to: &value) { body($0) }
}

private final class DeviceBox {
    let device: BlockDevice
    init(device: BlockDevice) { self.device = device }
}

private func box(_ context: UnsafeMutableRawPointer?) -> DeviceBox {
    Unmanaged<DeviceBox>.fromOpaque(context!).takeUnretainedValue()
}

private let deviceRead: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt64, UInt64) -> Int64 = {
    context, buffer, count, offset in
    do {
        let target = UnsafeMutableRawBufferPointer(start: buffer, count: Int(count))
        return Int64(try box(context).device.read(into: target, at: offset))
    } catch {
        return -Int64(errnoValue(for: error))
    }
}

private let deviceWrite: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt64, UInt64) -> Int64 = {
    context, buffer, count, offset in
    do {
        let source = UnsafeRawBufferPointer(start: buffer, count: Int(count))
        return Int64(try box(context).device.write(source, at: offset))
    } catch {
        return -Int64(errnoValue(for: error))
    }
}

private let deviceSync: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    do {
        try box(context).device.flush()
        return 0
    } catch {
        return -errnoValue(for: error)
    }
}
