import Foundation
import NTFSCore
import Testing

@Suite struct MountTests {
    @Test func freshImageMountsReadWrite() throws {
        try TestImage.withVolume { volume, _ in
            #expect(volume.readOnlyReason == nil)
            #expect(volume.label == TestImage.label)
            #expect(volume.serialNumber != 0)
            let stats = try volume.statistics()
            #expect(stats.totalBytes > 60 << 20)
            #expect(stats.freeBytes > 0 && stats.freeBytes < stats.totalBytes)
            #expect(stats.maximumNameLength == 255)
        }
    }

    @Test func readOnlyRequestIsHonoured() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let volume = try TestImage.mount(url, readOnly: true)
        #expect(volume.readOnlyReason == .requested)
        #expect(throws: NTFSError.readOnly) { try volume.create("a.txt", in: .root, type: .file) }
        try volume.unmount()
    }

    @Test func readOnlyDeviceMountsReadOnly() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try FileBlockDevice(path: url.path, writable: false)
        let volume = try NTFSVolumeHandle(device: device)
        #expect(volume.readOnlyReason == .deviceReadOnly)
        try volume.unmount()
    }

    @Test func dirtyVolumeMountsReadOnly() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        try TestImage.markDirty(url)
        let volume = try TestImage.mount(url)
        #expect(volume.readOnlyReason == .dirty)
        try volume.unmount()
    }

    @Test func hibernatedWindowsMountsReadOnly() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let volume = try TestImage.mount(url)
            var header = Data("hibr".utf8)
            header.append(Data(count: 8192 - header.count))
            _ = try volume.makeFile("hiberfil.sys", contents: header)
            try volume.unmount()
        }
        let volume = try TestImage.mount(url)
        #expect(volume.readOnlyReason == .hibernated)
        try volume.unmount()
    }

    @Test func randomBytesAreNotNTFS() throws {
        let url = TestImage.scratchDirectory.appendingPathComponent("\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data(count: 1 << 20)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: url)
        #expect(throws: NTFSMountError.notNTFS) { try TestImage.mount(url) }
    }

    @Test func bitLockerVolumeIsRecognised() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        handle.seek(toFileOffset: 3)
        handle.write(Data("-FVE-FS-".utf8))
        try handle.close()
        #expect(throws: NTFSMountError.bitLocker) { try TestImage.mount(url) }
    }

    @Test func labelCanBeChanged() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let volume = try TestImage.mount(url)
            try volume.setLabel("Ổ đĩa Windows")
            try volume.unmount()
        }
        let volume = try TestImage.mount(url)
        #expect(volume.label == "Ổ đĩa Windows")
        try volume.unmount()
    }

    @Test func forcedReadOnlyBlocksWrites() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("a.txt")
            volume.forceReadOnly(reason: .ioError)
            #expect(volume.readOnlyReason == .ioError)
            #expect(throws: NTFSError.readOnly) { try volume.writeAll(Data([1]), to: id) }
        }
    }
}
