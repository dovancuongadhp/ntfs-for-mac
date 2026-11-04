import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferProgressTests {
    private func job(_ id: Int, size: Int64, kind: TransferJob.Kind = .file) -> TransferJob {
        TransferJob(
            id: id, kind: kind, source: URL(fileURLWithPath: "/s/\(id)"),
            destination: URL(fileURLWithPath: "/d/\(id)"), size: size)
    }

    private let start = Date(timeIntervalSince1970: 0)

    @Test func totalsIgnoreFolders() {
        var progress = TransferProgress()
        progress.append([job(0, size: 0, kind: .directory), job(1, size: 100), job(2, size: 300)])
        #expect(progress.totalBytes == 400)
        #expect(progress.fileCount == 2)
        #expect(progress.processedBytes == 0)
        #expect(progress.fraction == 0)
    }

    @Test func eventsMoveItemsThroughTheirStates() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100), job(1, size: 100)])
        progress.apply(.started(job: 0), at: start)
        #expect(progress.items[0].state == .copying)
        progress.apply(.progress(job: 0, bytes: 40, readRate: 0, writeRate: 0), at: start)
        #expect(progress.processedBytes == 40)
        progress.apply(.finished(job: 0, bytes: 100), at: start)
        #expect(progress.items[0].state == .done)
        #expect(progress.doneCount == 1)
        #expect(progress.fraction == 0.5)
    }

    @Test func failedAndSkippedFilesCountAsProcessedSoTheBarReachesTheEnd() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100), job(1, size: 100)])
        progress.apply(.failed(job: 0, TransferFailure(.unreadable)), at: start)
        progress.apply(.skipped(job: 1), at: start)
        #expect(progress.fraction == 1)
        #expect(progress.failedItems.map(\.id) == [0])
        #expect(progress.items[0].failure?.reason == .unreadable)
    }

    @Test func onlyEmptyFilesFallBackToCountingFiles() {
        var progress = TransferProgress()
        progress.append([job(0, size: 0), job(1, size: 0)])
        progress.apply(.finished(job: 0, bytes: 0), at: start)
        #expect(progress.fraction == 0.5)
    }

    @Test func effectiveRateCombinesReadingAndWriting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 300_000_000)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.progress(job: 0, bytes: 100_000_000, readRate: 100e6, writeRate: 100e6), at: start)
        #expect(progress.effectiveRate == 50e6)
        // 200 MB left at 50 MB/s.
        #expect(progress.secondsRemaining == 4)
    }

    @Test func noRateMeansNoEstimate() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        #expect(progress.secondsRemaining == nil)
    }

    @Test func ratesAreSmoothedAndZeroSamplesAreIgnored() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        progress.apply(.progress(job: 0, bytes: 1, readRate: 100, writeRate: 100), at: start)
        progress.apply(.progress(job: 0, bytes: 2, readRate: 200, writeRate: 0), at: start)
        #expect(progress.readRate == 130)
        #expect(progress.writeRate == 100)
    }

    @Test func activeTimeCountsGapsBetweenEventsButCapsLongPauses() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.progress(job: 0, bytes: 1, readRate: 1, writeRate: 1), at: start.addingTimeInterval(1))
        progress.apply(.finished(job: 0, bytes: 100), at: start.addingTimeInterval(1000))
        #expect(progress.activeSeconds == 3)
    }

    @Test func resettingFailedItemsReturnsTheirJobsAsWaiting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 10)])
        progress.apply(.finished(job: 0, bytes: 10), at: start)
        progress.apply(.failed(job: 1, TransferFailure(.writeFailed)), at: start)
        let retry = progress.resetFailed()
        #expect(retry.map(\.id) == [1])
        #expect(progress.items[1].state == .waiting)
        #expect(progress.failedItems.isEmpty)
    }

    @Test func interruptedPutsACopyingItemBackToWaiting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10)])
        progress.apply(.started(job: 0), at: start)
        progress.interrupted()
        #expect(progress.items[0].state == .waiting)
        #expect(progress.items[0].bytesDone == 0)
    }

    @Test func cancellingMarksWhatIsLeftAsSkipped() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 10)])
        progress.apply(.finished(job: 0, bytes: 10), at: start)
        progress.cancelRemaining()
        #expect(progress.items.map(\.state) == [.done, .skipped])
    }

    @Test func summaryCountsOutcomesAndBytes() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 20), job(2, size: 30), job(3, size: 0, kind: .directory)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.finished(job: 0, bytes: 10), at: start.addingTimeInterval(1))
        progress.apply(.finished(job: 1, bytes: 20), at: start.addingTimeInterval(2))
        progress.apply(.failed(job: 2, TransferFailure(.unreadable)), at: start.addingTimeInterval(3))
        let summary = progress.summary()
        #expect(summary.copied == 2)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 0)
        #expect(summary.bytes == 30)
        #expect(summary.duration == 3)
    }
}
