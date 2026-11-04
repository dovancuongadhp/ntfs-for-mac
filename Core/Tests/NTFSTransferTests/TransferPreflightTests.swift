import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferPreflightTests {
    private func file(_ id: Int, _ name: String, size: Int64) -> TransferJob {
        TransferJob(
            id: id, kind: .file, source: URL(fileURLWithPath: "/s/\(name)"),
            destination: URL(fileURLWithPath: "/d/\(name)"), size: size)
    }

    @Test func windowsNameRules() {
        #expect(WindowsNames.isValid("report.pdf"))
        #expect(!WindowsNames.isValid("a:b.txt"))
        #expect(!WindowsNames.isValid("what?"))
        #expect(!WindowsNames.isValid("trailing."))
        #expect(!WindowsNames.isValid("trailing "))
        #expect(!WindowsNames.isValid("CON"))
        #expect(!WindowsNames.isValid("con.txt"))
        #expect(!WindowsNames.isValid("COM3"))
        #expect(WindowsNames.isValid("CONSOLE.txt"))
        #expect(!WindowsNames.isValid(""))
        #expect(!WindowsNames.isValid("tab\there"))
    }

    @Test func rulesFollowTheFileSystem() {
        #expect(DestinationRules.forFileSystem("exfat") == .exFAT)
        #expect(DestinationRules.forFileSystem("msdos") == .fat32)
        #expect(DestinationRules.forFileSystem("ntfs") == .unrestricted)
        #expect(DestinationRules.forFileSystem("apfs") == .unrestricted)
    }

    @Test func notEnoughSpaceBlocks() {
        let jobs = [file(0, "a", size: 600), file(1, "b", size: 600)]
        let problems = TransferPreflight.check(jobs: jobs, rules: .unrestricted, freeBytes: 1000)
        #expect(problems == [.notEnoughSpace(needed: 1200, available: 1000)])
        #expect(problems[0].isBlocking)
    }

    @Test func exactFitIsFine() {
        let problems = TransferPreflight.check(jobs: [file(0, "a", size: 1000)], rules: .unrestricted, freeBytes: 1000)
        #expect(problems.isEmpty)
    }

    @Test func invalidNamesOnlyMatterOnExFATAndFAT32() {
        let jobs = [file(0, "bad:name.txt", size: 1)]
        #expect(TransferPreflight.check(jobs: jobs, rules: .exFAT, freeBytes: 10) == [.invalidName(job: 0, name: "bad:name.txt")])
        #expect(TransferPreflight.check(jobs: jobs, rules: .unrestricted, freeBytes: 10).isEmpty)
    }

    @Test func fat32RejectsFilesOverFourGigabytes() {
        let big = file(0, "big.iso", size: 4_294_967_296)
        let ok = file(1, "ok.iso", size: 4_294_967_295)
        let problems = TransferPreflight.check(jobs: [big, ok], rules: .fat32, freeBytes: .max)
        #expect(problems == [.fileTooLarge(job: 0, name: "big.iso")])
        #expect(!problems[0].isBlocking)
    }

    @Test func excludingProblemJobsAlsoDropsWhatIsInsideThem() {
        let folder = TransferJob(id: 0, kind: .directory, source: URL(fileURLWithPath: "/s/bad:dir"), destination: URL(fileURLWithPath: "/d/bad:dir"))
        let inside = TransferJob(id: 1, kind: .file, source: URL(fileURLWithPath: "/s/bad:dir/f"), destination: URL(fileURLWithPath: "/d/bad:dir/f"), size: 1)
        let other = file(2, "fine.txt", size: 1)
        let problems: [TransferProblem] = [.invalidName(job: 0, name: "bad:dir")]
        let kept = TransferPreflight.jobs([folder, inside, other], without: problems)
        #expect(kept.map(\.id) == [2])
    }
}
