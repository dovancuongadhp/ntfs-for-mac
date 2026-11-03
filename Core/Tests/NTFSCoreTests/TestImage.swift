import Foundation
import NTFSCore

/// Fresh NTFS disk images for tests, formatted by the bundled `ntfs-mkfs`.
enum TestImage {
    static let defaultSize: UInt64 = 64 << 20
    static let label = "Test"

    private static let templates = TemplateCache()

    /// A newly formatted image (cloned from a per-size template).
    static func make(size: UInt64 = defaultSize) throws -> URL {
        let template = try templates.template(size: size)
        let url = scratchDirectory.appendingPathComponent("\(UUID().uuidString).img")
        try FileManager.default.copyItem(at: template, to: url)
        return url
    }

    static func mount(_ url: URL, readOnly: Bool = false) throws -> NTFSVolumeHandle {
        let device = try FileBlockDevice(path: url.path, writable: true)
        return try NTFSVolumeHandle(device: device, readOnly: readOnly)
    }

    static func withVolume<T>(size: UInt64 = defaultSize, _ body: (NTFSVolumeHandle, URL) throws -> T) throws -> T {
        let url = try make(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let volume = try mount(url)
        defer { try? volume.unmount() }
        return try body(volume, url)
    }

    static let scratchDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ntfs-core-tests")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Sets VOLUME_IS_DIRTY in the $Volume record, as Windows does when it schedules chkdsk.
    static func markDirty(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let boot = try read(handle, at: 0, count: 512)
        let bytesPerSector = UInt64(boot.u16(0x0B))
        let clusterSize = bytesPerSector * UInt64(boot[0x0D])
        let mftOffset = boot.u64(0x30) * clusterSize
        let clustersPerRecord = Int8(bitPattern: boot[0x40])
        let recordSize = clustersPerRecord < 0
            ? UInt64(1) << UInt64(-Int(clustersPerRecord))
            : UInt64(clustersPerRecord) * clusterSize
        // $Volume is record 3, which $MFTMirr duplicates; both copies must match.
        for tableOffset in [mftOffset, boot.u64(0x38) * clusterSize] {
            try setDirtyFlag(handle, recordOffset: tableOffset + 3 * recordSize, recordSize: recordSize)
        }
    }

    /// Overwrites the first page of $LogFile (record 2) with zeros: neither
    /// empty nor a valid restart page, so libntfs-3g treats the journal as unclean.
    static func corruptJournal(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let boot = try read(handle, at: 0, count: 512)
        let clusterSize = UInt64(boot.u16(0x0B)) * UInt64(boot[0x0D])
        let clustersPerRecord = Int8(bitPattern: boot[0x40])
        let recordSize = clustersPerRecord < 0
            ? UInt64(1) << UInt64(-Int(clustersPerRecord))
            : UInt64(clustersPerRecord) * clusterSize
        let record = try read(handle, at: boot.u64(0x30) * clusterSize + 2 * recordSize, count: Int(recordSize))

        var attribute = Int(record.u16(0x14))
        while attribute + 8 < record.count {
            let type = record.u32(attribute)
            let length = Int(record.u32(attribute + 4))
            guard type != 0xFFFF_FFFF, length > 0 else { break }
            if type == 0x80, record[attribute + 8] == 1 {
                let runs = attribute + Int(record.u16(attribute + 0x20))
                let lengthBytes = Int(record[runs] & 0x0F)
                let offsetBytes = Int(record[runs] >> 4)
                let lcn = (0..<offsetBytes).reduce(UInt64(0)) {
                    $0 | UInt64(record[runs + 1 + lengthBytes + $1]) << (8 * UInt64($1))
                }
                handle.seek(toFileOffset: lcn * clusterSize)
                handle.write(Data(count: 4096))
                return
            }
            attribute += length
        }
        throw NTFSError.notFound
    }

    private static func setDirtyFlag(_ handle: FileHandle, recordOffset volumeRecordOffset: UInt64, recordSize: UInt64) throws {
        var record = try read(handle, at: volumeRecordOffset, count: Int(recordSize))

        var attribute = Int(record.u16(0x14))
        while attribute + 8 < record.count {
            let type = record.u32(attribute)
            let length = Int(record.u32(attribute + 4))
            guard type != 0xFFFF_FFFF, length > 0 else { break }
            if type == 0x70 {
                let valueOffset = attribute + Int(record.u16(attribute + 0x14))
                record[valueOffset + 0x0A] |= 0x01
                handle.seek(toFileOffset: volumeRecordOffset)
                handle.write(record)
                return
            }
            attribute += length
        }
        throw NTFSError.notFound
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        handle.seek(toFileOffset: offset)
        return handle.readData(ofLength: count)
    }
}

private final class TemplateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var templates: [UInt64: URL] = [:]

    func template(size: UInt64) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let url = templates[size] {
            return url
        }
        let url = TestImage.scratchDirectory.appendingPathComponent("template-\(size)-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()

        let process = Process()
        process.executableURL = mkfsURL
        process.arguments = ["-F", "-f", "-q", "-L", TestImage.label, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NTFSError.io
        }
        templates[size] = url
        return url
    }

    private var mkfsURL: URL {
        let testBundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        let productsDirectory = testBundle?.bundleURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug")
        return productsDirectory.appendingPathComponent("ntfs-mkfs")
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    func u64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * UInt64($1)) }
    }
}

extension NTFSVolumeHandle {
    func writeAll(_ data: Data, to id: ItemID, at offset: UInt64 = 0) throws {
        let written = try data.withUnsafeBytes { try write(id, at: offset, from: $0) }
        precondition(written == data.count)
    }

    func readAll(_ id: ItemID) throws -> Data {
        let size = try attributes(of: id).size
        var data = Data(count: Int(size))
        let read = try data.withUnsafeMutableBytes { try self.read(id, at: 0, into: $0) }
        return data.prefix(read)
    }

    func makeFile(_ name: String, in directory: ItemID = .root, contents: Data = Data()) throws -> ItemID {
        let id = try create(name, in: directory, type: .file)
        if !contents.isEmpty {
            try writeAll(contents, to: id)
        }
        return id
    }
}
