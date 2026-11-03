import Foundation
@testable import NTFSCore
import Testing

@Suite struct ExtendedAttributeTests {
    @Test func setGetListRemove() throws {
        try TestImage.withVolume { volume, _ in
            let file = try volume.makeFile("a.txt", contents: Data("body".utf8))
            #expect(try volume.extendedAttributeNames(of: file).isEmpty)

            let finderInfo = Data((0..<32).map { UInt8($0) })
            try volume.setExtendedAttribute("com.apple.FinderInfo", to: finderInfo, of: file)
            try volume.setExtendedAttribute("com.apple.metadata:kMDItemWhereFroms", to: Data("x".utf8), of: file)
            try volume.setExtendedAttribute("empty", to: Data(), of: file)

            #expect(Set(try volume.extendedAttributeNames(of: file))
                == ["com.apple.FinderInfo", "com.apple.metadata:kMDItemWhereFroms", "empty"])
            #expect(try volume.extendedAttribute("com.apple.FinderInfo", of: file) == finderInfo)
            #expect(try volume.extendedAttribute("empty", of: file).isEmpty)
            // The file's own contents are untouched.
            #expect(try volume.readAll(file) == Data("body".utf8))
            #expect(try volume.attributes(of: file).size == 4)

            try volume.removeExtendedAttribute("empty", of: file)
            #expect(throws: NTFSError.noAttribute) { try volume.extendedAttribute("empty", of: file) }
            #expect(throws: NTFSError.noAttribute) { try volume.removeExtendedAttribute("empty", of: file) }
        }
    }

    @Test func replaceShrinksAndGrows() throws {
        try TestImage.withVolume { volume, _ in
            let file = try volume.makeFile("a.txt")
            let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try volume.setExtendedAttribute("com.apple.ResourceFork", to: large, of: file)
            #expect(try volume.extendedAttribute("com.apple.ResourceFork", of: file) == large)
            try volume.setExtendedAttribute("com.apple.ResourceFork", to: Data("small".utf8), of: file)
            #expect(try volume.extendedAttribute("com.apple.ResourceFork", of: file) == Data("small".utf8))
            try volume.setExtendedAttribute("com.apple.ResourceFork", to: large, of: file)
            #expect(try volume.extendedAttribute("com.apple.ResourceFork", of: file) == large)
            #expect(try volume.extendedAttributeNames(of: file) == ["com.apple.ResourceFork"])
        }
    }

    @Test func modesAreEnforced() throws {
        try TestImage.withVolume { volume, _ in
            let file = try volume.makeFile("a.txt")
            #expect(throws: NTFSError.noAttribute) {
                try volume.setExtendedAttribute("k", to: Data("1".utf8), of: file, mode: .replace)
            }
            try volume.setExtendedAttribute("k", to: Data("1".utf8), of: file, mode: .create)
            #expect(throws: NTFSError.exists) {
                try volume.setExtendedAttribute("k", to: Data("2".utf8), of: file, mode: .create)
            }
            try volume.setExtendedAttribute("k", to: Data("3".utf8), of: file, mode: .replace)
            #expect(try volume.extendedAttribute("k", of: file) == Data("3".utf8))
        }
    }

    @Test func directoriesAndRootCarryAttributes() throws {
        try TestImage.withVolume { volume, _ in
            let directory = try volume.create("Folder", in: .root, type: .directory)
            try volume.setExtendedAttribute("com.apple.FinderInfo", to: Data(count: 32), of: directory)
            try volume.setExtendedAttribute("tag", to: Data("root".utf8), of: .root)
            #expect(try volume.extendedAttributeNames(of: directory) == ["com.apple.FinderInfo"])
            #expect(try volume.extendedAttribute("tag", of: .root) == Data("root".utf8))
            #expect(try volume.entries(of: directory).isEmpty)
        }
    }

    @Test func survivesRemountAndRename() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let volume = try TestImage.mount(url)
            let file = try volume.makeFile("a.txt")
            try volume.setExtendedAttribute("com.apple.quarantine", to: Data("q".utf8), of: file)
            try volume.rename("a.txt", in: .root, to: "b.txt", in: .root)
            try volume.unmount()
        }
        let volume = try TestImage.mount(url, readOnly: true)
        let file = try volume.lookup("b.txt", in: .root)
        #expect(try volume.extendedAttribute("com.apple.quarantine", of: file) == Data("q".utf8))
        #expect(throws: NTFSError.readOnly) {
            try volume.setExtendedAttribute("x", to: Data(), of: file)
        }
        try volume.unmount()
    }

    @Test func streamNamesAvoidWindowsForbiddenCharacters() {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let stream = StreamName.streamName(name)
        #expect(!stream.contains(":"))
        #expect(stream.unicodeScalars.contains { $0.value == 0xF03A })
        #expect(StreamName.attributeName(stream) == name)
        #expect(StreamName.streamName("plain.name") == "plain.name")
        #expect(StreamName.attributeName("Zone.Identifier") == "Zone.Identifier")
    }
}
