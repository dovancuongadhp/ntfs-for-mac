import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferPlannerTests {
    @Test func foldersComeBeforeTheirContentsAndIdsAreSequential() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("tree/a.txt", "12345")
        try source.file("tree/sub/b.txt", "1")
        let jobs = try plan([source.path("tree")], into: destination.url)

        #expect(jobs.map(\.id) == [0, 1, 2, 3])
        #expect(jobs.map(\.name) == ["tree", "a.txt", "sub", "b.txt"])
        #expect(jobs.map(\.isDirectory) == [true, false, true, false])
        #expect(jobs[1].size == 5)
        #expect(jobs[1].destination == destination.path("tree/a.txt"))
    }

    @Test func anItemGivenTwiceOrInsideAnotherSourceIsCopiedOnce() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("tree/a.txt", "1")
        try source.file("tree/sub/b.txt", "1")
        let tree = source.path("tree")
        let jobs = try plan(
            [tree, URL(fileURLWithPath: tree.path + "/"), source.path("tree/sub/b.txt"), source.path("tree/sub")],
            into: destination.url)
        #expect(jobs.map(\.name) == ["tree", "a.txt", "sub", "b.txt"])
        #expect(jobs.map(\.id) == [0, 1, 2, 3])
    }

    @Test func aSingleFileIsOneJob() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let jobs = try plan([try source.file("one.txt")], into: destination.url)
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .file)
    }

    @Test func symbolicLinksStayLinks() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("real.txt")
        try FileManager.default.createSymbolicLink(atPath: source.path("link").path, withDestinationPath: "real.txt")
        let jobs = try plan([source.path("link")], into: destination.url)
        #expect(jobs.map(\.kind) == [.symlink(target: "real.txt")])
    }

    @Test func aFolderCannotGoIntoItselfOrBelowItself() throws {
        let source = try TempFolder()
        try source.folder("a/b")
        #expect(throws: TransferPlanner.PlanError.destinationInsideSource("a")) {
            try plan([source.path("a")], into: source.path("a"))
        }
        #expect(throws: TransferPlanner.PlanError.destinationInsideSource("a")) {
            try plan([source.path("a")], into: source.path("a/b"))
        }
    }

    @Test func aFileMayBeCopiedIntoItsOwnFolder() throws {
        let source = try TempFolder()
        let file = try source.file("a.txt")
        let jobs = try plan([file], into: source.url)
        #expect(jobs.count == 1)
    }

    @Test func uniqueNameAddsANumberBeforeTheExtension() {
        let taken: Set<String> = ["/x/a 2.txt", "/x/a 3.txt"]
        let url = UniqueName.make(for: URL(fileURLWithPath: "/x/a.txt")) { taken.contains($0.path) }
        #expect(url.path == "/x/a 4.txt")
    }

    @Test func uniqueNameWorksWithoutAnExtension() {
        let url = UniqueName.make(for: URL(fileURLWithPath: "/x/folder")) { _ in false }
        #expect(url.path == "/x/folder 2")
    }
}
