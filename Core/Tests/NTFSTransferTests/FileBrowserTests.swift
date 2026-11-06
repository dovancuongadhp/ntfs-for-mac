import Foundation
import Testing
@testable import NTFSTransfer

@MainActor
@Suite struct FileBrowserModelTests {
    @Test func listsFoldersFirstThenFilesByName() async throws {
        let folder = try TempFolder()
        try folder.file("beta.txt"); try folder.file("alpha.txt"); try folder.folder("Zeta")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(model.entries.map(\.name) == ["Zeta", "alpha.txt", "beta.txt"])
        #expect(model.entries.first?.isFolder == true)
        #expect(model.errorMessage == nil)
        #expect((model.freeBytes ?? 0) > 0)
    }

    @Test func hiddenFilesAreOnlyShownOnRequest() async throws {
        let folder = try TempFolder()
        try folder.file(".secret"); try folder.file("shown")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(model.entries.map(\.name) == ["shown"])
        model.showsHidden = true // reloads by itself
        for _ in 0..<300 where model.entries.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(model.entries.map(\.name)) == [".secret", "shown"])
    }

    @Test func sortingBySizeDescendingKeepsFoldersFirst() async throws {
        let folder = try TempFolder()
        try folder.file("small", "1"); try folder.file("large", "12345"); try folder.folder("dir")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        model.sort = FileSort(key: .size, ascending: false)
        #expect(model.entries.map(\.name) == ["dir", "large", "small"])
    }

    @Test func navigationKeepsAHistory() async throws {
        let folder = try TempFolder()
        try folder.folder("inner")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(!model.canGoBack)

        model.open(folder.path("inner"))
        await model.reload()
        #expect(model.folder.lastPathComponent == "inner")
        #expect(model.canGoBack)

        model.goBack()
        await model.reload()
        #expect(model.folder.standardizedFileURL == folder.url.standardizedFileURL)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.folder.lastPathComponent == "inner")
        model.goUp()
        #expect(model.folder.standardizedFileURL == folder.url.standardizedFileURL)
    }

    @Test func theUpRowPointsAtTheParentExceptAtTheRoot() {
        let model = FileBrowserModel(folder: URL(fileURLWithPath: "/Users/tester/Photos"))
        #expect(model.parentURL?.path == "/Users/tester")
        #expect(FileBrowserModel(folder: URL(fileURLWithPath: "/")).parentURL == nil)
    }

    @Test func theUpRowIsNeverPartOfWhatActionsUse() {
        let model = FileBrowserModel(folder: URL(fileURLWithPath: "/Users/tester/Photos"))
        let photo = URL(fileURLWithPath: "/Users/tester/Photos/a.jpg")
        model.selection = [URL(fileURLWithPath: "/Users/tester"), photo]
        #expect(model.actionableSelection == [photo])
        model.selection = [URL(fileURLWithPath: "/Users/tester")]
        #expect(model.actionableSelection.isEmpty)
    }

    @Test func aMissingFolderReportsAnErrorAndNoEntries() async throws {
        let folder = try TempFolder()
        let model = FileBrowserModel(folder: folder.path("missing"))
        await model.reload()
        #expect(model.errorMessage != nil)
        #expect(model.entries.isEmpty)
    }

    @Test func selectionDropsFilesThatDisappear() async throws {
        let folder = try TempFolder()
        try folder.file("a"); try folder.file("b")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        model.selection = Set(model.entries.map(\.url))
        try FileManager.default.removeItem(at: folder.path("a"))
        await model.reload()
        #expect(model.selection.map(\.lastPathComponent) == ["b"])
        #expect(model.selectedEntries.map(\.name) == ["b"])
    }
}

@Suite struct LocationsTests {
    @Test func containingPicksTheDeepestMatchOnAPathBoundary() {
        let places = [
            FileLocation(name: "Root", url: URL(fileURLWithPath: "/"), symbol: "internaldrive"),
            FileLocation(name: "Home", url: URL(fileURLWithPath: "/Users/me"), symbol: "house"),
            FileLocation(name: "Docs", url: URL(fileURLWithPath: "/Users/me/Documents"), symbol: "doc"),
        ]
        #expect(Locations.containing(URL(fileURLWithPath: "/Users/me/Documents/x"), in: places)?.name == "Docs")
        #expect(Locations.containing(URL(fileURLWithPath: "/Users/me/DocumentsOld"), in: places)?.name == "Home")
        #expect(Locations.containing(URL(fileURLWithPath: "/Applications"), in: places)?.name == "Root")
    }

    @Test func availableIncludesHomeAndAtLeastOneVolume() {
        let places = Locations.available()
        #expect(places.contains { $0.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL })
        #expect(places.contains { $0.symbol.hasSuffix("drive") })
    }

    @Test func listsTheStartupDiskAndBrowsableDrivesUnderVolumes() {
        #expect(Locations.isListedVolume(path: "/", browsable: true))
        #expect(Locations.isListedVolume(path: "/Volumes/USB_CUONG", browsable: true))
        #expect(Locations.isListedVolume(path: "/Volumes/Stick", browsable: nil))
        #expect(!Locations.isListedVolume(path: "/Volumes/Recovery", browsable: false))
        #expect(!Locations.isListedVolume(path: "/System/Volumes/VM", browsable: true))
        #expect(!Locations.isListedVolume(path: "/Users/me/Library/Developer/CoreDevice/DeviceFS", browsable: true))
        #expect(!Locations.isListedVolume(path: "/Volumes/A/B", browsable: true))
    }
}

@Suite struct FavoriteFoldersTests {
    @Test func togglePinsThenUnpinsAndKeepsTheOthersInOrder() {
        var favorites = FavoriteFolders()
        let photos = URL(fileURLWithPath: "/Volumes/USB/Photos")
        favorites.toggle(photos)
        #expect(favorites.contains(URL(fileURLWithPath: "/Volumes/USB/Photos/")))
        #expect(favorites.urls.map(\.path) == [photos.standardizedFileURL.path])

        favorites.toggle(URL(fileURLWithPath: "/Volumes/USB/Docs"))
        favorites.toggle(photos)
        #expect(favorites.paths == ["/Volumes/USB/Docs"])
    }
}

@Suite struct FileOperationsTests {
    @Test func makeFolderCreatesItAndRefusesDuplicatesAndBadNames() throws {
        let folder = try TempFolder()
        let made = try FileOperations.makeFolder(named: "New", in: folder.url)
        #expect(made.lastPathComponent == "New")
        #expect(folder.has("New"))
        #expect(throws: FileOperationError.alreadyExists("New")) { try FileOperations.makeFolder(named: "New", in: folder.url) }
        #expect(throws: FileOperationError.invalidName) { try FileOperations.makeFolder(named: "a/b", in: folder.url) }
        #expect(throws: FileOperationError.invalidName) { try FileOperations.makeFolder(named: "  ", in: folder.url) }
    }

    @Test func renameMovesTheItemAndRefusesAnExistingName() throws {
        let folder = try TempFolder()
        let original = try folder.file("old.txt", "x")
        try folder.file("taken.txt")
        let renamed = try FileOperations.rename(original, to: "new.txt")
        #expect(renamed.lastPathComponent == "new.txt")
        #expect(folder.has("new.txt"))
        #expect(!folder.has("old.txt"))
        #expect(throws: FileOperationError.alreadyExists("taken.txt")) { try FileOperations.rename(renamed, to: "taken.txt") }
    }

    @Test func renamingToTheSameNameWithDifferentCaseIsAllowed() throws {
        let folder = try TempFolder()
        let original = try folder.file("file.txt")
        let renamed = try FileOperations.rename(original, to: "FILE.txt")
        #expect(renamed.lastPathComponent == "FILE.txt")
    }

    @Test func deletePermanentlyRemovesFilesAndFolders() throws {
        let folder = try TempFolder()
        let file = try folder.file("a")
        let dir = try folder.folder("d")
        try FileOperations.deletePermanently([file, dir])
        #expect(!folder.has("a"))
        #expect(!folder.has("d"))
    }

    @Test func validateRejectsEmptySlashAndDots() {
        #expect(FileOperations.validate("ok name"))
        #expect(!FileOperations.validate(""))
        #expect(!FileOperations.validate("a/b"))
        #expect(!FileOperations.validate("."))
        #expect(!FileOperations.validate(".."))
    }

    // MARK: C1 – trash refuses permission errors, does not offer permanent delete

    /// A parent that is mode 0555 makes trashItem fail with EACCES / permission-denied,
    /// NOT with the "volume has no Trash" code. The return value must NOT classify the item
    /// as "stuck" (suitable for permanent delete) and the item's contents must survive.
    @Test func trashRefusedByPermissionIsNotTreatedAsNoTrash() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(component: "ft-c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let victim = parent.appending(component: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: victim.appending(component: "content.txt"))
        // Make parent read-only so trashItem fails with permission denied, not "no Trash"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)

        let result = FileOperations.trash([victim])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        // A permission error must NOT be presented as permanent-delete candidate
        #expect(result.stuck.isEmpty, "Permission error must not appear as 'no Trash on volume'")
        #expect(result.error != nil, "Permission error must be surfaced")
        // Contents survived (the item was never touched by removeItem)
        #expect(
            FileManager.default.fileExists(atPath: victim.appending(component: "content.txt").path),
            "File contents must survive a failed trash attempt")
    }

    // MARK: C1 – deletePermanently refuses when parent is not writable

    /// When the parent directory is read-only, deletePermanently must throw
    /// without touching any of the item's contents.
    @Test func permanentDeleteIsRefusedWhenParentIsReadOnly() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(component: "ft-c1b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let victim = parent.appending(component: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let content = victim.appending(component: "content.txt")
        try Data("keep me".utf8).write(to: content)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)

        #expect(throws: (any Error).self) {
            try FileOperations.deletePermanently([victim])
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        #expect(
            FileManager.default.fileExists(atPath: content.path),
            "Contents must survive a refused permanent delete")
    }
}
