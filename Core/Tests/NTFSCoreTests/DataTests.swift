import Foundation
import NTFSCore
import Testing

@Suite struct DataTests {
    @Test(arguments: [1, 700, 4096, 1 << 20])
    func writeThenReadBack(size: Int) throws {
        try TestImage.withVolume { volume, _ in
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let id = try volume.makeFile("f.bin", contents: payload)
            #expect(try volume.attributes(of: id).size == UInt64(size))
            #expect(try volume.readAll(id) == payload)
        }
    }

    @Test func readPastEndReturnsShortCount() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("f", contents: Data("hello".utf8))
            var buffer = Data(count: 100)
            let n = try buffer.withUnsafeMutableBytes { try volume.read(id, at: 3, into: $0) }
            #expect(n == 2)
            #expect(buffer.prefix(2) == Data("lo".utf8))
            let none = try buffer.withUnsafeMutableBytes { try volume.read(id, at: 10, into: $0) }
            #expect(none == 0)
        }
    }

    @Test func overwriteInTheMiddle() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("f", contents: Data("aaaaaaaaaa".utf8))
            try volume.writeAll(Data("BB".utf8), to: id, at: 4)
            #expect(try volume.readAll(id) == Data("aaaaBBaaaa".utf8))
        }
    }

    @Test func truncateShrinksAndGrowsWithZeros() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("f", contents: Data("0123456789".utf8))
            try volume.truncate(id, to: 4)
            #expect(try volume.readAll(id) == Data("0123".utf8))
            try volume.truncate(id, to: 8)
            #expect(try volume.readAll(id) == Data("0123".utf8) + Data(count: 4))
        }
    }

    @Test func fileLargerThanFourGigabytes() throws {
        try TestImage.withVolume(size: 8 << 30) { volume, _ in
            let id = try volume.makeFile("big.bin")
            let offset: UInt64 = (4 << 30) + 12345
            try volume.writeAll(Data("tail".utf8), to: id, at: offset)
            #expect(try volume.attributes(of: id).size == offset + 4)
            var buffer = Data(count: 4)
            _ = try buffer.withUnsafeMutableBytes { try volume.read(id, at: offset, into: $0) }
            #expect(buffer == Data("tail".utf8))
            var head = Data(repeating: 0xFF, count: 16)
            _ = try head.withUnsafeMutableBytes { try volume.read(id, at: 1 << 30, into: $0) }
            #expect(head == Data(count: 16))
        }
    }

    @Test func writingBeyondFreeSpaceFails() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("huge")
            let chunk = Data(count: 8 << 20)
            var failure: NTFSError?
            for index in 0..<16 {
                do {
                    try volume.writeAll(chunk, to: id, at: UInt64(index * chunk.count))
                } catch {
                    failure = error as? NTFSError
                    break
                }
            }
            #expect(failure == NTFSError(code: ENOSPC))
        }
    }

    @Test func directoriesCannotBeReadAsFiles() throws {
        try TestImage.withVolume { volume, _ in
            let dir = try volume.create("d", in: .root, type: .directory)
            var buffer = Data(count: 1)
            #expect(throws: NTFSError(code: EISDIR)) {
                _ = try buffer.withUnsafeMutableBytes { try volume.read(dir, at: 0, into: $0) }
            }
        }
    }
}
