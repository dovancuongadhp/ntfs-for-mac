import Foundation
import NTFSCore
import Testing

@Suite struct ItemTests {
    @Test func rootIsAnEmptyDirectory() throws {
        try TestImage.withVolume { volume, _ in
            #expect(try volume.attributes(of: .root).type == .directory)
            let visible = try volume.entries(of: .root).filter { !$0.name.hasPrefix("$") }
            #expect(visible.isEmpty)
        }
    }

    @Test func metadataFilesAreHidden() throws {
        try TestImage.withVolume { volume, _ in
            let names = try volume.entries(of: .root).map(\.name)
            #expect(!names.contains("$MFT"))
            #expect(throws: NTFSError.notFound) { try volume.lookup("$MFT", in: .root) }
        }
    }

    @Test func createFileAndDirectory() throws {
        try TestImage.withVolume { volume, _ in
            let dir = try volume.create("Tài liệu", in: .root, type: .directory)
            let file = try volume.create("báo cáo.txt", in: dir, type: .file)
            #expect(try volume.attributes(of: dir).type == .directory)
            let attrs = try volume.attributes(of: file)
            #expect(attrs.type == .file)
            #expect(attrs.size == 0)
            #expect(attrs.flags.contains(.archive))
            #expect(try volume.lookup("báo cáo.txt", in: dir) == file)
            #expect(try volume.entries(of: dir) == [DirectoryEntry(name: "báo cáo.txt", id: file, type: .file)])
        }
    }

    @Test func duplicateNamesAreRejected() throws {
        try TestImage.withVolume { volume, _ in
            _ = try volume.makeFile("a.txt")
            #expect(throws: NTFSError.exists) { try volume.create("a.txt", in: .root, type: .file) }
        }
    }

    @Test func lookupIgnoresCaseLikeWindows() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("ReadMe.TXT")
            #expect(try volume.lookup("readme.txt", in: .root) == id)
            #expect(throws: NTFSError.exists) { try volume.create("README.txt", in: .root, type: .file) }
            #expect(try volume.entries(of: .root).contains { $0.name == "ReadMe.TXT" })
        }
    }

    @Test func decomposedNamesFindPrecomposedFiles() throws {
        try TestImage.withVolume { volume, _ in
            let precomposed = "Tiếng Việt.txt".precomposedStringWithCanonicalMapping
            let decomposed = "Tiếng Việt.txt".decomposedStringWithCanonicalMapping
            #expect(precomposed.utf8.count != decomposed.utf8.count)
            let id = try volume.makeFile(decomposed)
            #expect(try volume.lookup(precomposed, in: .root) == id)
            #expect(try volume.lookup(decomposed, in: .root) == id)
            #expect(try volume.entries(of: .root).contains { $0.name.utf8.elementsEqual(precomposed.utf8) })
        }
    }

    @Test func windowsForbiddenNamesAreRejected() throws {
        try TestImage.withVolume { volume, _ in
            for name in ["a:b", "what?", "CON", "trailing.", "x|y"] {
                #expect(throws: NTFSError.invalid, "\(name)") { try volume.create(name, in: .root, type: .file) }
            }
        }
    }

    @Test func removeFileAndEmptyDirectory() throws {
        try TestImage.withVolume { volume, _ in
            _ = try volume.makeFile("a.txt")
            let dir = try volume.create("d", in: .root, type: .directory)
            _ = try volume.makeFile("inner", in: dir)
            #expect(throws: NTFSError.notEmpty) { try volume.remove("d", in: .root) }
            try volume.remove("inner", in: dir)
            try volume.remove("d", in: .root)
            try volume.remove("a.txt", in: .root)
            #expect(try volume.entries(of: .root).filter { !$0.name.hasPrefix("$") }.isEmpty)
            #expect(throws: NTFSError.notFound) { try volume.remove("a.txt", in: .root) }
        }
    }

    @Test func manyFilesEnumerateExactlyOnce() throws {
        try TestImage.withVolume { volume, _ in
            let dir = try volume.create("many", in: .root, type: .directory)
            let names = (0..<2000).map { String(format: "file-%05d.dat", $0) }
            for name in names {
                _ = try volume.create(name, in: dir, type: .file)
            }
            let listed = try volume.entries(of: dir).map(\.name)
            #expect(listed.count == names.count)
            #expect(Set(listed) == Set(names))
        }
    }

    @Test func timesAndHiddenFlagPersist() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let modify = timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_700)
        let birth = timespec(tv_sec: 1_600_000_000, tv_nsec: 0)
        let id: ItemID
        do {
            let volume = try TestImage.mount(url)
            id = try volume.makeFile("a.txt")
            try volume.setTimes(id, modify: modify, birth: birth)
            try volume.setFlags(.hidden, on: true, for: id)
            try volume.unmount()
        }
        let volume = try TestImage.mount(url)
        let attrs = try volume.attributes(of: id)
        #expect(attrs.modifyTime.tv_sec == modify.tv_sec)
        #expect(attrs.modifyTime.tv_nsec == modify.tv_nsec)
        #expect(attrs.birthTime.tv_sec == birth.tv_sec)
        #expect(attrs.flags.contains(.hidden))
        try volume.unmount()
    }

    @Test func dataSurvivesRemount() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        var payload = Data(count: 3 << 20)
        payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        do {
            let volume = try TestImage.mount(url)
            let dir = try volume.create("keep", in: .root, type: .directory)
            _ = try volume.makeFile("blob.bin", in: dir, contents: payload)
            try volume.unmount()
        }
        let volume = try TestImage.mount(url)
        let dir = try volume.lookup("keep", in: .root)
        let file = try volume.lookup("blob.bin", in: dir)
        #expect(try volume.readAll(file) == payload)
        try volume.unmount()
    }
}
