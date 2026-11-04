import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct PathCompletionTests {
    @Test func suggestsTheSubfoldersThatStartWithWhatWasTyped() throws {
        let root = try TempFolder()
        try root.folder("Photos"); try root.folder("photo-raw"); try root.folder("Music"); try root.file("Photo.txt")

        let suggested = PathCompletion.suggestions(for: root.url.path + "/pho", home: root.url)

        #expect(suggested.map(\.lastPathComponent) == ["photo-raw", "Photos"])
    }

    @Test func aTrailingSlashListsEveryVisibleSubfolder() throws {
        let root = try TempFolder()
        try root.folder("b"); try root.folder("a"); try root.folder(".hidden")

        #expect(PathCompletion.suggestions(for: root.url.path + "/", home: root.url).map(\.lastPathComponent) == ["a", "b"])
        #expect(PathCompletion.suggestions(for: root.url.path + "/.h", home: root.url).map(\.lastPathComponent) == [".hidden"])
    }

    @Test func aTildeStandsForTheHomeFolder() throws {
        let home = try TempFolder()
        try home.folder("Documents")

        #expect(PathCompletion.suggestions(for: "~/Doc", home: home.url).map(\.lastPathComponent) == ["Documents"])
        #expect(PathCompletion.folder(for: "~/Documents", home: home.url)?.lastPathComponent == "Documents")
        #expect(PathCompletion.folder(for: "~", home: home.url)?.standardizedFileURL == home.url.standardizedFileURL)
    }

    @Test func onlyAnExistingFolderCanBeOpened() throws {
        let root = try TempFolder()
        try root.folder("Photos"); try root.file("a.txt")

        #expect(PathCompletion.folder(for: root.url.path + "/Photos/", home: root.url)?.lastPathComponent == "Photos")
        #expect(PathCompletion.folder(for: root.url.path + "/a.txt", home: root.url) == nil)
        #expect(PathCompletion.folder(for: root.url.path + "/missing", home: root.url) == nil)
        #expect(PathCompletion.folder(for: "", home: root.url) == nil)
        #expect(PathCompletion.suggestions(for: "", home: root.url).isEmpty)
    }
}

@Suite struct PathSuggestionsTests {
    private let folders = ["/a/One", "/a/Two", "/a/Three"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test func tabTakesTheFirstUntilTheArrowsPickAnother() {
        var list = PathSuggestions(folders)
        #expect(list.highlighted == nil)
        #expect(list.completion == "/a/One/")
        #expect(list.picked == nil)

        list.moveDown(); list.moveDown()
        #expect(list.highlighted == 1)
        #expect(list.completion == "/a/Two/")
        #expect(list.picked?.lastPathComponent == "Two")
    }

    @Test func theArrowsStopAtTheEndsAndUpFromTheTopGoesBackToTheText() {
        var list = PathSuggestions(folders)
        list.moveUp()
        #expect(list.highlighted == nil)
        for _ in 0..<5 { list.moveDown() }
        #expect(list.highlighted == 2)
        list.moveUp(); list.moveUp(); list.moveUp()
        #expect(list.highlighted == nil)
        #expect(list.picked == nil)
    }

    @Test func nothingToCompleteWithoutSuggestions() {
        var list = PathSuggestions()
        list.moveDown()
        #expect(list.highlighted == nil)
        #expect(list.completion == nil)
        #expect(list.picked == nil)
    }
}
