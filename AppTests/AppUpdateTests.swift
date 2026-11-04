import Foundation
import Testing
@testable import NTFS_for_Mac

struct AppUpdateTests {
    @Test func versionsCompareNumerically() throws {
        let current = try #require(AppVersion("2.0.1"))
        #expect(current == AppVersion(major: 2, minor: 0, patch: 1))
        #expect(AppVersion("v2.0.2")! > current)
        #expect(AppVersion("2.0.10")! > AppVersion("2.0.9")!)
        #expect(AppVersion("2.1")! > current)
        #expect(AppVersion("2")! == AppVersion(major: 2, minor: 0, patch: 0))
        #expect(AppVersion("2.0.1")! == current)
        #expect(AppVersion("v2.0.2-beta") == nil)
        #expect(AppVersion("lotus") == nil)
        #expect(AppVersion("2.0.1.1") == nil)
    }

    @Test func latestReleaseMustBeTheProjectsDiskImage() throws {
        let release = try GitHubRelease.latest(from: Data("""
        {"tag_name":"v2.0.2","assets":[
          {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
          {"name":"NTFS-for-Mac.dmg","browser_download_url":"https://github.com/dovancuongadhp/ntfs-for-mac/releases/download/v2.0.2/NTFS-for-Mac.dmg"}
        ]}
        """.utf8))
        #expect(release.version == AppVersion(major: 2, minor: 0, patch: 2))
        #expect(release.downloadURL.lastPathComponent == "NTFS-for-Mac.dmg")
    }

    @Test func aDiskImageFromAnywhereElseIsRejected() {
        let foreign = Data("""
        {"tag_name":"v2.0.2","assets":[
          {"name":"NTFS-for-Mac.dmg","browser_download_url":"https://example.com/NTFS-for-Mac.dmg"}
        ]}
        """.utf8)
        #expect(throws: UpdateError.untrustedDownload) { try GitHubRelease.latest(from: foreign) }
    }
}
