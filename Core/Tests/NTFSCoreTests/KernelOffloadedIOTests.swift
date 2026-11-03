import Foundation
import NTFSCore
import Testing

/// These tests play the kernel's part: they read and write the image directly
/// at the extents `blockmap` hands out.
@Suite struct KernelOffloadedIOTests {
    @Test func writtenDataReadsBackThroughTheLibraryAndAfterRemount() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Self.random(1 << 20 + 7)
        let id: ItemID
        do {
            let volume = try TestImage.mount(url)
            id = try volume.makeFile("f.bin")
            #expect(try volume.attributes(of: id).isMappable)
            try Kernel(volume, url).write(payload, to: id, at: 0)
            #expect(try volume.attributes(of: id).size == UInt64(payload.count))
            #expect(try volume.readAll(id) == payload)
            try volume.unmount()
        }
        let volume = try TestImage.mount(url, readOnly: true)
        defer { try? volume.unmount() }
        #expect(try volume.readAll(id) == payload)
        #expect(try Kernel(volume, url).read(id, length: payload.count) == payload)
    }

    @Test func smallFileMovesOutOfTheRecordWhenMapped() throws {
        try TestImage.withVolume { volume, url in
            let id = try volume.makeFile("small.txt", contents: Data("xin chào".utf8))
            #expect(try Kernel(volume, url).read(id, length: 9) == Data("xin chào".utf8))
            #expect(try volume.readAll(id) == Data("xin chào".utf8))
        }
    }

    @Test func gapBeforeAWriteReadsAsZerosNotStaleClusters() throws {
        try TestImage.withVolume { volume, url in
            // Leave non-zero data in free clusters for the new file to reuse.
            let old = try volume.makeFile("old.bin", contents: Data(repeating: 0xEE, count: 4 << 20))
            _ = old
            try volume.remove("old.bin", in: .root)

            let id = try volume.makeFile("f.bin", contents: Data("head".utf8))
            let tail = Self.random(5000)
            let kernel = Kernel(volume, url)
            try kernel.write(tail, to: id, at: 2 << 20)

            let expected = Data("head".utf8) + Data(count: (2 << 20) - 4) + tail
            #expect(try volume.readAll(id) == expected)
            #expect(try kernel.read(id, length: expected.count) == expected)
        }
    }

    @Test func completionsOutOfOrder() throws {
        try TestImage.withVolume { volume, url in
            let id = try volume.makeFile("f.bin")
            let first = Self.random(64 << 10)
            let second = Self.random(64 << 10)
            let kernel = Kernel(volume, url)
            let firstExtents = try kernel.map(id, offset: 0, length: first.count, forWrite: true)
            let secondExtents = try kernel.map(id, offset: UInt64(first.count), length: second.count, forWrite: true)
            try kernel.put(second, at: UInt64(first.count), extents: secondExtents)
            try volume.completeWrite(id, offset: UInt64(first.count), length: UInt64(second.count))
            try kernel.put(first, at: 0, extents: firstExtents)
            try volume.completeWrite(id, offset: 0, length: UInt64(first.count))
            #expect(try volume.readAll(id) == first + second)
        }
    }

    @Test func abortedWriteReadsAsZeros() throws {
        try TestImage.withVolume { volume, url in
            let old = try volume.makeFile("old.bin", contents: Data(repeating: 0xEE, count: 1 << 20))
            _ = old
            try volume.remove("old.bin", in: .root)

            let id = try volume.makeFile("f.bin")
            let kernel = Kernel(volume, url)
            let length = 64 << 10
            _ = try kernel.map(id, offset: 0, length: length, forWrite: true)
            try volume.abortWrite(id, offset: 0, length: UInt64(length))
            #expect(try volume.readAll(id) == Data(count: length))
            #expect(try kernel.read(id, length: length) == Data(count: length))
        }
    }

    @Test func overwriteKeepsTheRest() throws {
        try TestImage.withVolume { volume, url in
            let original = Self.random(200_000)
            let id = try volume.makeFile("f.bin", contents: original)
            let patch = Self.random(8192)
            try Kernel(volume, url).write(patch, to: id, at: 65536)
            var expected = original
            expected.replaceSubrange(65536..<65536 + 8192, with: patch)
            #expect(try volume.readAll(id) == expected)
        }
    }

    @Test func holesMapAsZeros() throws {
        try TestImage.withVolume { volume, url in
            let id = try volume.makeFile("sparse.bin", contents: Data("a".utf8))
            try volume.truncate(id, to: 8 << 20)
            let kernel = Kernel(volume, url)
            let extents = try kernel.map(id, offset: 1 << 20, length: 1 << 20, forWrite: false)
            #expect(extents.allSatisfy { $0.physicalOffset == nil })
            #expect(try kernel.read(id, length: 8 << 20) == Data("a".utf8) + Data(count: (8 << 20) - 1))

            let middle = Self.random(4096)
            try kernel.write(middle, to: id, at: 4 << 20)
            var expected = Data("a".utf8) + Data(count: (8 << 20) - 1)
            expected.replaceSubrange((4 << 20)..<(4 << 20) + 4096, with: middle)
            #expect(try volume.readAll(id) == expected)
        }
    }

    @Test func residentFilesAreNotMappableOnReadOnlyVolumes() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let small: ItemID
        let large: ItemID
        do {
            let volume = try TestImage.mount(url)
            small = try volume.makeFile("small.txt", contents: Data("hi".utf8))
            large = try volume.makeFile("large.bin", contents: Self.random(100_000))
            try volume.unmount()
        }
        let volume = try TestImage.mount(url, readOnly: true)
        defer { try? volume.unmount() }
        #expect(try volume.attributes(of: small).isMappable == false)
        #expect(try volume.attributes(of: large).isMappable)
        #expect(throws: NTFSError.notSupported) {
            try Kernel(volume, url).map(small, offset: 0, length: 2, forWrite: false)
        }
    }

    static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return data
    }
}

/// Transfers file data the way the kernel does with offloaded I/O.
private struct Kernel {
    let volume: NTFSVolumeHandle
    let image: URL

    init(_ volume: NTFSVolumeHandle, _ image: URL) {
        self.volume = volume
        self.image = image
    }

    func map(_ id: ItemID, offset: UInt64, length: Int, forWrite: Bool) throws -> [Extent] {
        var extents: [Extent] = []
        var next = offset
        let end = offset + UInt64(length)
        // A full packer stops the mapping early; ask again for the rest.
        while next < end {
            var batch: [Extent] = []
            try volume.blockmap(id, offset: next, length: end - next, forWrite: forWrite, blockSize: 512) {
                batch.append($0)
                return batch.count < 3
            }
            guard let last = batch.last else { break }
            #expect(last.logicalOffset + last.length > next)
            extents += batch
            next = last.logicalOffset + last.length
        }
        return extents
    }

    func put(_ data: Data, at offset: UInt64, extents: [Extent]) throws {
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        for extent in extents {
            let physical = try #require(extent.physicalOffset)
            let from = Int(max(extent.logicalOffset, offset) - offset)
            let to = Int(min(extent.logicalOffset + extent.length, offset + UInt64(data.count)) - offset)
            guard to > from else { continue }
            try handle.seek(toOffset: physical + (offset + UInt64(from) - extent.logicalOffset))
            try handle.write(contentsOf: data[data.startIndex + from..<data.startIndex + to])
        }
    }

    func write(_ data: Data, to id: ItemID, at offset: UInt64) throws {
        let extents = try map(id, offset: offset, length: data.count, forWrite: true)
        try put(data, at: offset, extents: extents)
        try volume.completeWrite(id, offset: offset, length: UInt64(data.count))
    }

    func read(_ id: ItemID, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        var result = Data()
        for extent in try map(id, offset: 0, length: length, forWrite: false) {
            let count = Int(min(extent.length, UInt64(length - result.count)))
            if let physical = extent.physicalOffset {
                try handle.seek(toOffset: physical)
                result += try handle.read(upToCount: count) ?? Data()
            } else {
                result += Data(count: count)
            }
            if result.count >= length { break }
        }
        return result
    }
}
