import Foundation
import NTFSCore
import Testing

@Suite struct JournalTests {
    @Test func uncleanJournalMountsReadOnlyUntilReset() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let volume = try TestImage.mount(url)
            try volume.makeFile("kept.txt", contents: Data("kept".utf8))
            try volume.unmount()
        }
        try TestImage.corruptJournal(url)

        let before = try TestImage.mount(url)
        #expect(before.readOnlyReason == .uncleanJournal)
        try before.unmount()

        try NTFSVolumeHandle.resetJournal(device: FileBlockDevice(path: url.path, writable: true))

        let after = try TestImage.mount(url)
        #expect(after.readOnlyReason == nil)
        let id = try after.lookup("kept.txt", in: .root)
        #expect(try after.readAll(id) == Data("kept".utf8))
        try after.makeFile("new.txt")
        try after.unmount()
    }

    @Test func resetOnCleanVolumeIsHarmless() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        try NTFSVolumeHandle.resetJournal(device: FileBlockDevice(path: url.path, writable: true))
        let volume = try TestImage.mount(url)
        #expect(volume.readOnlyReason == nil)
        try volume.unmount()
    }

    @Test func resetRefusesVolumeFlaggedForChkdsk() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        try TestImage.markDirty(url)
        #expect(throws: NTFSMountError.failed(NTFSError(code: EBUSY))) {
            try NTFSVolumeHandle.resetJournal(device: FileBlockDevice(path: url.path, writable: true))
        }
    }
}
