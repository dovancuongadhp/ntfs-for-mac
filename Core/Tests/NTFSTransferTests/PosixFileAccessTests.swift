import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct PosixFileAccessTests {
    let access = PosixFileAccess()

    @Test func attributesDescribeFilesFoldersAndLinks() throws {
        let folder = try TempFolder()
        let file = try folder.file("a.txt", "hello")
        let sub = try folder.folder("sub")
        let link = folder.path("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")

        #expect(try access.attributes(of: file).kind == .file)
        #expect(try access.attributes(of: file).size == 5)
        #expect(try access.attributes(of: sub).kind == .directory)
        #expect(try access.attributes(of: link).kind == .symlink)
        #expect(try access.readLink(link) == "a.txt")
    }

    @Test func missingFilesThrowAndDoNotExist() throws {
        let folder = try TempFolder()
        #expect(!access.exists(folder.path("nope")))
        #expect(throws: (any Error).self) { try access.attributes(of: folder.path("nope")) }
    }

    @Test func childrenAreSortedByName() throws {
        let folder = try TempFolder()
        try folder.file("b"); try folder.file("a"); try folder.file("c")
        #expect(try access.children(of: folder.url).map(\.lastPathComponent) == ["a", "b", "c"])
    }

    @Test func writingThenReadingRoundTripsInChunks() throws {
        let folder = try TempFolder()
        let target = folder.path("out.bin")
        let payload = Data((0..<2500).map { UInt8(truncatingIfNeeded: $0) })
        let writer = try access.createForWriting(target)
        try writer.write(payload.prefix(1000))
        try writer.write(payload.suffix(from: 1000))
        try writer.sync()
        try writer.close()

        let reader = try access.openForReading(target)
        var collected = Data()
        while true {
            let chunk = try reader.read(upTo: 1024)
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        reader.close()
        #expect(collected == payload)
    }

    @Test func emptyFilesReadAsEmpty() throws {
        let folder = try TempFolder()
        let reader = try access.openForReading(try folder.file("empty", ""))
        #expect(try reader.read(upTo: 10).isEmpty)
        reader.close()
    }

    @Test func renameReplacesAnExistingFile() throws {
        let folder = try TempFolder()
        let from = try folder.file("new", "new")
        let to = try folder.file("old", "old")
        try access.rename(from, to: to)
        #expect(try folder.text("old") == "new")
        #expect(!folder.has("new"))
    }

    @Test func removeDeletesFilesAndFolders() throws {
        let folder = try TempFolder()
        try folder.file("d/f")
        try access.remove(folder.path("d"))
        #expect(!folder.has("d"))
    }

    @Test func copyMetadataKeepsTheModificationDate() throws {
        let folder = try TempFolder()
        let from = try folder.file("a")
        let to = try folder.file("b")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try folder.setModified("a", date)
        access.copyMetadata(from: from, to: to)
        #expect(abs(try access.attributes(of: to).modified.timeIntervalSince(date)) < 1)
    }

    @Test func volumeInfoReportsTheFileSystemAndFreeSpace() throws {
        let folder = try TempFolder()
        let info = try access.volumeInfo(at: folder.url)
        #expect(!info.fileSystemType.isEmpty)
        #expect(info.freeBytes > 0)
    }

    @Test func makeLinkCreatesASymbolicLink() throws {
        let folder = try TempFolder()
        try access.makeLink(at: folder.path("l"), target: "somewhere")
        #expect(try access.readLink(folder.path("l")) == "somewhere")
    }
}
