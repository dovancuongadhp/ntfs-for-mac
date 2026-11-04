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

    // MARK: The panel's headline

    private let someSummary = TransferSummary(copied: 3, failed: 0, skipped: 2, bytes: 4_000, duration: 9)

    @Test func aCancelledCopyDoesNotSayItWasComplete() {
        let title = TransferText.headline(phase: .finished, lastStop: .cancelled, summary: someSummary, done: 3, total: 5)
        #expect(title == "Copy cancelled")
        let detail = TransferText.detail(phase: .finished, lastStop: .cancelled, summary: someSummary)
        #expect(detail == "Files copied: 3 · Skipped: 2")
    }

    @Test func aCopyTheUserStoppedSaysSo() {
        let title = TransferText.headline(phase: .finished, lastStop: .userStopped, summary: someSummary, done: 3, total: 5)
        #expect(title == "Copy stopped")
    }

    @Test func aCleanFinishStillSaysCompleteWithTheCountSizeAndTime() {
        let clean = TransferSummary(copied: 5, failed: 0, skipped: 0, bytes: 4_000, duration: 9)
        #expect(TransferText.headline(phase: .finished, lastStop: .finished, summary: clean, done: 5, total: 5) == "Copy complete")
        #expect(TransferText.headline(phase: .finished, lastStop: nil, summary: clean, done: 5, total: 5) == "Copy complete")
        let detail = TransferText.detail(phase: .finished, lastStop: .finished, summary: clean)
        #expect(detail == "Files copied: 5 · \(TransferText.size(4_000)) · \(TransferText.duration(9))")
    }

    @Test func aFinishWithFailuresSaysSoEvenWhenTheReasonIsMissing() {
        let failed = TransferSummary(copied: 4, failed: 1, skipped: 0, bytes: 4_000, duration: 9)
        #expect(TransferText.headline(phase: .finished, lastStop: .finished, summary: failed, done: 4, total: 5) == "Copy finished with errors")
    }

    @Test func aHaltedCopyShowsWhatToDoNext() {
        let full = TransferText.headline(phase: .stopped(.noSpace), lastStop: .noSpace, summary: someSummary, done: 3, total: 5)
        #expect(full == "The destination is full")
        #expect(TransferText.detail(phase: .stopped(.noSpace), lastStop: .noSpace, summary: someSummary) == "Free some space, then resume the copy.")
        let gone = TransferText.detail(phase: .stopped(.driveRemoved), lastStop: .driveRemoved, summary: someSummary)
        #expect(gone == "Reconnect it, then resume the copy.")
    }

    @Test func whileCopyingTheHeadlineCountsFilesAndThereIsNoDetail() {
        #expect(TransferText.headline(phase: .running, lastStop: nil, summary: nil, done: 2, total: 9) == "Copying files: 2 of 9")
        #expect(TransferText.headline(phase: .paused, lastStop: nil, summary: nil, done: 2, total: 9) == "Paused")
        #expect(TransferText.detail(phase: .running, lastStop: nil, summary: nil) == nil)
        #expect(TransferText.detail(phase: .paused, lastStop: nil, summary: nil) == nil)
    }

    @Test func theQuestionNoticeSaysSomethingIsWaiting() {
        let notice = TransferText.promptNotice()
        #expect(!notice.title.isEmpty)
        #expect(!notice.body.isEmpty)
    }

    @Test func theDeleteWarningNamesOneItemAndCountsSeveral() {
        let one = TransferText.deleteMessage(for: [URL(fileURLWithPath: "/Volumes/Stick/Report.docx")])
        #expect(one.contains("Report.docx"))
        let many = TransferText.deleteMessage(for: (0..<7).map { URL(fileURLWithPath: "/Volumes/Stick/file\($0).txt") })
        #expect(many.contains("7"))
        #expect(many.contains("file0.txt"))
        #expect(many.contains("Trash"))
    }
}
