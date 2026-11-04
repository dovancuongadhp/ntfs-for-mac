import Foundation
import NTFSTransfer
import Testing
@testable import NTFS_for_Mac

@MainActor
struct TransferSessionTests {
    private func session() -> TransferSession {
        TransferSession(notify: { _, _ in })
    }

    private func job(_ id: Int, _ name: String, size: Int64 = 100) -> TransferJob {
        TransferJob(
            id: id, kind: .file, source: URL(fileURLWithPath: "/src/\(name)"),
            destination: URL(fileURLWithPath: "/dst/\(name)"), size: size)
    }

    @Test func nothingSelectedMeansNoDestructiveActions() {
        let session = session()
        session.activeModel.selection = []
        #expect(!session.canDelete)
        #expect(!session.canRename)
        #expect(session.canCopy == false)
    }

    @Test func ordinaryItemsCanBeDeletedAndRenamed() {
        let session = session()
        session.activeModel.selection = [URL(fileURLWithPath: "/Users/tester/Documents/a.txt")]
        #expect(session.canDelete)
        #expect(session.canRename)
        #expect(session.canCopy)
    }

    @Test func protectedItemsRefuseDeleteAndRenameButStayCopyable() {
        let session = session()
        for path in ["/System", "/Applications", "/Volumes/Backup", FileManager.default.homeDirectoryForCurrentUser.path] {
            session.activeModel.selection = [URL(fileURLWithPath: path)]
            #expect(!session.canDelete, "\(path)")
            #expect(!session.canRename, "\(path)")
            #expect(session.canCopy, "\(path)")
        }
    }

    @Test func oneProtectedItemInASelectionBlocksDelete() {
        let session = session()
        session.activeModel.selection = [
            URL(fileURLWithPath: "/Users/tester/Documents/a.txt"), URL(fileURLWithPath: "/Library"),
        ]
        #expect(!session.canDelete)
    }

    @Test func aFullDestinationIsAWarningTheUserCanOverride() {
        let jobs = [job(1, "a.bin", size: 2_000), job(2, "b.bin", size: 2_000)]
        let pending = TransferSession.review(jobs: jobs, rules: .unrestricted, freeBytes: 1_000)
        #expect(pending != nil)
        #expect(pending?.hasSpaceWarning == true)
        #expect(pending?.proceedAnyway == true)
        #expect(pending?.restOfJobs == jobs)
    }

    @Test func aFitCopyStartsWithoutAsking() {
        #expect(TransferSession.review(jobs: [job(1, "a.bin")], rules: .unrestricted, freeBytes: 1_000_000) == nil)
    }

    @Test func badNamesAreLeftOutButSpaceNeverHidesTheRest() {
        let jobs = [job(1, "ok.txt", size: 10), job(2, "bad:name.txt", size: 10)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 1_000_000)
        #expect(pending?.hasSpaceWarning == false)
        #expect(pending?.proceedAnyway == false)
        #expect(pending?.restOfJobs.map(\.id) == [1])
    }

    @Test func spaceAndNameProblemsTogetherKeepBothChoices() {
        let jobs = [job(1, "ok.txt", size: 5_000), job(2, "bad:name.txt", size: 5_000)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 100)
        #expect(pending?.hasSpaceWarning == true)
        #expect(pending?.proceedAnyway == true)
        #expect(pending?.restOfJobs.map(\.id) == [1])
    }
}
