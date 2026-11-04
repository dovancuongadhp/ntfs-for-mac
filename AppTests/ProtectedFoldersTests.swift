import Foundation
import Testing
@testable import NTFS_for_Mac

struct ProtectedFoldersTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func isProtected(_ path: String) -> Bool {
        ProtectedFolders.isProtected(URL(fileURLWithPath: path), home: home)
    }

    @Test func systemFoldersAreProtected() {
        for path in ["/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
                     "/etc", "/var", "/Applications", "/Users", "/Volumes"] {
            #expect(isProtected(path), "\(path) should be protected")
        }
    }

    @Test func theRealTargetsOfSystemLinksAreProtected() {
        #expect(isProtected("/private/etc"))
        #expect(isProtected("/private/var"))
    }

    @Test func theContentsOfProtectedFoldersAreNot() {
        for path in ["/System/Library", "/Library/Caches", "/usr/local", "/Applications/Safari.app",
                     "/Users/someone", "/Users/Shared", "/private/tmp", "/tmp/file", "/etc/hosts", "/var/log"] {
            #expect(!isProtected(path), "\(path) should be operable")
        }
    }

    @Test func theHomeFolderItselfIsProtectedButNotItsContents() {
        #expect(isProtected("/Users/tester"))
        #expect(isProtected("/Users/tester/"))
        #expect(!isProtected("/Users/tester/Documents"))
        #expect(!isProtected("/Users/tester/Downloads/file.txt"))
    }

    @Test func volumeRootsAreProtectedButNotTheirContents() {
        #expect(isProtected("/Volumes/Backup"))
        #expect(isProtected("/Volumes/Macintosh HD"))
        #expect(!isProtected("/Volumes/Backup/Photos"))
        #expect(!isProtected("/Volumes/Backup/Photos/a.jpg"))
    }

    @Test func pathsAreStandardizedAndCaseInsensitive() {
        #expect(isProtected("/System/../System"))
        #expect(isProtected("/Users/tester/Documents/.."))
        #expect(isProtected("/system"))
        #expect(!isProtected("/System/Library/.."  + "/Library"))
    }

    @Test func aLinkToAProtectedFolderCanStillBeRemoved() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let link = sandbox.appending(component: "shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System"))
        #expect(!ProtectedFolders.isProtected(link, home: home))
    }

    @Test func aHomeReachedThroughASymlinkedPathIsStillProtected() throws {
        // The temporary directory lives under /var, a link to /private/var.
        let sandbox = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let fakeHome = sandbox.appending(component: "me")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let resolved = sandbox.resolvingSymlinksInPath().appending(component: "me")
        #expect(ProtectedFolders.isProtected(fakeHome, home: resolved))
        #expect(ProtectedFolders.isProtected(resolved, home: fakeHome))
        #expect(!ProtectedFolders.isProtected(fakeHome.appending(component: "Documents"), home: resolved))
    }
}
