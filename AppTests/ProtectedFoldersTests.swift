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

    @Test func volumeNamesAreMatchedWithoutCase() {
        #expect(isProtected("/volumes/Backup"))
        #expect(isProtected("/VOLUMES/backup"))
        #expect(!isProtected("/volumes/Backup/Photos"))
    }

    @Test func theRulesForAHomeAreBuiltOnceAndShared() {
        let first = ProtectedFolders.rules(for: URL(fileURLWithPath: "/Users/cache-probe"))
        let second = ProtectedFolders.rules(for: URL(fileURLWithPath: "/Users/cache-probe/"))
        #expect(first === second)
        let other = ProtectedFolders.rules(for: URL(fileURLWithPath: "/Users/someone-else"))
        #expect(other !== first)
        #expect(other.paths.contains("/users/someone-else"))
    }

    /// Other tests (and the app) ask for other homes in between; that must not make this home rebuild.
    @Test func askingForAnotherHomeInBetweenDoesNotMakeTheFirstOneRebuild() {
        let probe = URL(fileURLWithPath: "/Users/cache-probe-interleaved")
        let first = ProtectedFolders.rules(for: probe)
        for index in 0..<5 { _ = ProtectedFolders.rules(for: URL(fileURLWithPath: "/Users/interloper-\(index)")) }
        #expect(ProtectedFolders.rules(for: probe) === first)
    }

    @Test func aBigSelectionInOneFolderResolvesTheFolderOnce() {
        var checker = ProtectedFolders.Checker(home: home)
        for index in 0..<5_000 {
            let protected = checker.isProtected(URL(fileURLWithPath: "/Users/tester/Documents/file-\(index).txt"))
            #expect(!protected)
        }
        #expect(checker.parentLookups == 1)
        let homeIsProtected = checker.isProtected(URL(fileURLWithPath: "/Users/tester"))
        #expect(homeIsProtected)
        #expect(checker.parentLookups == 2)
    }

    @Test func aSelectionIsRefusedIfAnyItemIsProtected() {
        let ordinary = (0..<100).map { URL(fileURLWithPath: "/Users/tester/Documents/f\($0).txt") }
        #expect(!ProtectedFolders.containsProtected(ordinary, home: home))
        #expect(ProtectedFolders.containsProtected(ordinary + [URL(fileURLWithPath: "/Volumes/Backup")], home: home))
        #expect(ProtectedFolders.containsProtected([URL(fileURLWithPath: "/private/etc")] + ordinary, home: home))
    }

    // MARK: C2 – /System/Volumes/* are volume roots

    @Test func systemVolumesMountPointsAreProtected() {
        // /System/Volumes/<name> are volume roots (APFS Data, VM, Preboot, …)
        for path in ["/System/Volumes/Data", "/System/Volumes/VM",
                     "/System/Volumes/Preboot", "/System/Volumes/Update"] {
            #expect(isProtected(path), "\(path) should be protected")
        }
    }

    @Test func contentsUnderSystemVolumesAreOperable() {
        // Items INSIDE /System/Volumes/Data must remain reachable
        #expect(!isProtected("/System/Volumes/Data/Users/tester/Documents/x.pdf"))
        #expect(!isProtected("/System/Volumes/Data/Applications/Safari.app"))
    }

    @Test func theDataVolumeFormsOfProtectedFoldersAreProtected() {
        for path in ["/System/Volumes/Data/Users", "/System/Volumes/Data/Applications",
                     "/System/Volumes/Data/Library", "/System/Volumes/Data/Users/tester"] {
            #expect(isProtected(path), "\(path) should be protected")
        }
        #expect(!isProtected("/System/Volumes/Data/Users/tester/Documents"))
    }

    @Test func systemVolumesAreCaseInsensitive() {
        #expect(isProtected("/system/volumes/data"))
        #expect(isProtected("/SYSTEM/VOLUMES/DATA"))
        #expect(isProtected("/system/volumes/data/users"))
    }

    @Test func aVolumeMountedOutsideVolumesIsARoot() {
        #expect(isProtected("/dev"))
        #expect(!isProtected("/dev/null"))
    }

    @Test func aVolumeReachedThroughALinkedFolderIsStillARoot() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let link = sandbox.appending(component: "volumes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Volumes"))
        #expect(ProtectedFolders.isProtected(link.appending(component: "Backup"), home: home))
        #expect(!ProtectedFolders.isProtected(link.appending(component: "Backup").appending(component: "Photos"), home: home))
    }
}
