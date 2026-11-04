import Foundation
import NTFSTransfer
import Testing
@testable import NTFS_for_Mac

struct TransferTextTests {
    @Test func everyFailureReasonHasAMessage() {
        let reasons: [TransferFailureReason] = [
            .unreadable, .writeFailed, .noSpace, .driveRemoved, .permissionDenied,
            .invalidName, .checksumMismatch, .sizeMismatch, .sourceMissing, .conflictingKind,
            .fileTooLarge,
        ]
        for reason in reasons {
            #expect(!TransferText.failure(reason).isEmpty)
        }
        #expect(Set(reasons.map(TransferText.failure)).count == reasons.count)
    }

    @Test func aCleanFinishSaysTheCountSizeAndTime() {
        let summary = TransferSummary(copied: 14, failed: 0, skipped: 0, bytes: 5_000_000_000, duration: 252)
        let notice = TransferText.notice(for: summary, stop: .finished)
        #expect(notice.title == "Copy complete")
        #expect(notice.body == "Files copied: 14 · \(TransferText.size(5_000_000_000)) · \(TransferText.duration(252))")
    }

    @Test func failuresChangeTheTitleAndMentionTheCount() {
        let summary = TransferSummary(copied: 12, failed: 2, skipped: 0, bytes: 1000, duration: 5)
        let notice = TransferText.notice(for: summary, stop: .finished)
        #expect(notice.title == "Copy finished with errors")
        #expect(notice.body == "Files copied: 12 · Failed: 2")
    }

    @Test func eachStopReasonHasItsOwnTitle() {
        let summary = TransferSummary(copied: 1, failed: 0, skipped: 1, bytes: 1, duration: 1)
        let titles = [TransferStop.cancelled, .noSpace, .driveRemoved, .userStopped]
            .map { TransferText.notice(for: summary, stop: $0).title }
        #expect(Set(titles).count == 4)
    }

    @Test func problemsListTheFirstFiveAndCountTheRest() {
        let problems = (0..<8).map { TransferProblem.invalidName(job: $0, name: "bad\($0):") }
        let text = TransferText.problems(problems)
        #expect(text.contains("bad0:"))
        #expect(text.contains("bad4:"))
        #expect(!text.contains("bad5:"))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 6)
        #expect(lines.last == "…and 3 more")
    }

    @Test func spaceProblemsMentionBothSizes() {
        let text = TransferText.problems([.notEnoughSpace(needed: 2_000_000_000, available: 1_000_000_000)])
        #expect(text.contains(TransferText.size(2_000_000_000)))
        #expect(text.contains(TransferText.size(1_000_000_000)))
    }

    @Test func oversizedFilesAreNamed() {
        let text = TransferText.problems([.fileTooLarge(job: 1, name: "movie.mkv")])
        #expect(text.contains("movie.mkv"))
    }

    @Test func ratesAndDurationsAreReadable() {
        #expect(TransferText.rate(100_000_000).hasSuffix("/s"))
        #expect(!TransferText.duration(252).isEmpty)
    }
}
