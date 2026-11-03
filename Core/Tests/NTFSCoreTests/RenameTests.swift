import Foundation
import NTFSCore
import Testing

@Suite struct RenameTests {
    @Test func renameWithinDirectory() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("old.txt", contents: Data("x".utf8))
            try volume.rename("old.txt", in: .root, to: "new.txt", in: .root)
            #expect(try volume.lookup("new.txt", in: .root) == id)
            #expect(throws: NTFSError.notFound) { try volume.lookup("old.txt", in: .root) }
            #expect(try volume.readAll(id) == Data("x".utf8))
        }
    }

    @Test func moveAcrossDirectories() throws {
        try TestImage.withVolume { volume, _ in
            let a = try volume.create("a", in: .root, type: .directory)
            let b = try volume.create("b", in: .root, type: .directory)
            let id = try volume.makeFile("f", in: a)
            try volume.rename("f", in: a, to: "g", in: b)
            #expect(try volume.entries(of: a).isEmpty)
            #expect(try volume.lookup("g", in: b) == id)
        }
    }

    @Test func moveNonEmptyDirectory() throws {
        try TestImage.withVolume { volume, _ in
            let src = try volume.create("src", in: .root, type: .directory)
            let child = try volume.makeFile("child", in: src)
            let dst = try volume.create("dst", in: .root, type: .directory)
            try volume.rename("src", in: .root, to: "moved", in: dst)
            let moved = try volume.lookup("moved", in: dst)
            #expect(moved == src)
            #expect(try volume.lookup("child", in: moved) == child)
        }
    }

    @Test func replaceExistingFile() throws {
        try TestImage.withVolume { volume, _ in
            let source = try volume.makeFile("draft", contents: Data("new".utf8))
            _ = try volume.makeFile("final", contents: Data("old".utf8))
            try volume.rename("draft", in: .root, to: "final", in: .root)
            #expect(try volume.lookup("final", in: .root) == source)
            #expect(try volume.readAll(source) == Data("new".utf8))
            let names = try volume.entries(of: .root).map(\.name).filter { !$0.hasPrefix("$") }
            #expect(names == ["final"])
        }
    }

    @Test func replacingNonEmptyDirectoryFails() throws {
        try TestImage.withVolume { volume, _ in
            _ = try volume.create("a", in: .root, type: .directory)
            let b = try volume.create("b", in: .root, type: .directory)
            _ = try volume.makeFile("x", in: b)
            #expect(throws: NTFSError.notEmpty) { try volume.rename("a", in: .root, to: "b", in: .root) }
        }
    }

    @Test func caseOnlyRename() throws {
        try TestImage.withVolume { volume, _ in
            let id = try volume.makeFile("photo.jpg")
            try volume.rename("photo.jpg", in: .root, to: "Photo.JPG", in: .root)
            let names = try volume.entries(of: .root).map(\.name).filter { !$0.hasPrefix("$") }
            #expect(names == ["Photo.JPG"])
            #expect(try volume.lookup("Photo.JPG", in: .root) == id)
        }
    }

    @Test func directoryCannotMoveIntoItself() throws {
        try TestImage.withVolume { volume, _ in
            let outer = try volume.create("outer", in: .root, type: .directory)
            let inner = try volume.create("inner", in: outer, type: .directory)
            #expect(throws: NTFSError.invalid) { try volume.rename("outer", in: .root, to: "x", in: inner) }
        }
    }
}
