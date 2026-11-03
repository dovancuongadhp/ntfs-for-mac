import Foundation
import NTFSCore
import Testing

/// Rejects any transfer that is not sector-aligned, like FSKit block devices.
private final class StrictDevice: BlockDevice {
    let base: FileBlockDevice
    let sectorSize: UInt32
    var size: UInt64 { base.size }
    var isWritable: Bool { base.isWritable }
    private(set) var misaligned = 0

    init(path: String, sectorSize: UInt32) throws {
        base = try FileBlockDevice(path: path, writable: true, sectorSize: sectorSize)
        self.sectorSize = sectorSize
    }

    private func checkAligned(_ count: Int, _ offset: UInt64) throws {
        if count % Int(sectorSize) != 0 || offset % UInt64(sectorSize) != 0 {
            misaligned += 1
            throw POSIXError(.EINVAL)
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try checkAligned(buffer.count, offset)
        return try base.read(into: buffer, at: offset)
    }

    func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try checkAligned(buffer.count, offset)
        return try base.write(buffer, at: offset)
    }

    func flush() throws {
        try base.flush()
    }
}

@Suite struct AlignmentTests {
    @Test(arguments: [UInt32(512), 4096])
    func operationsOnlyIssueAlignedTransfers(sectorSize: UInt32) throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try StrictDevice(path: url.path, sectorSize: sectorSize)
        do {
            let volume = try NTFSVolumeHandle(device: device)
            let dir = try volume.create("d", in: .root, type: .directory)
            var payload = Data(count: 100_003)
            payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let id = try volume.makeFile("odd-size.bin", in: dir, contents: payload)
            try volume.writeAll(Data("patch".utf8), to: id, at: 777)
            payload.replaceSubrange(777..<782, with: Data("patch".utf8))
            #expect(try volume.readAll(id) == payload)
            try volume.rename("odd-size.bin", in: dir, to: "renamed.bin", in: .root)
            try volume.unmount()
        }
        #expect(device.misaligned == 0)

        let volume = try TestImage.mount(url)
        let id = try volume.lookup("renamed.bin", in: .root)
        #expect(try volume.attributes(of: id).size == 100_003)
        try volume.unmount()
    }
}
