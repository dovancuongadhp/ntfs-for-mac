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

    // MARK: Cached aggregates

    /// A small deterministic generator, so a failure can be reproduced.
    private struct Lcg: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// The aggregates worked out the slow way, straight from the items.
    private struct Recount: Equatable {
        var fileCount = 0
        var doneCount = 0
        var failedIDs: [Int] = []
        var totalBytes: Int64 = 0
        var processedBytes: Int64 = 0
        var fraction = 0.0
        var summary = TransferSummary(copied: 0, failed: 0, skipped: 0, bytes: 0, duration: 0)

        init(_ progress: TransferProgress) {
            let files = progress.items.filter { !$0.job.isDirectory }
            fileCount = files.count
            doneCount = files.filter { $0.state == .done }.count
            failedIDs = progress.items.filter { $0.failure != nil }.map(\.id)
            totalBytes = files.reduce(0) { $0 + $1.job.size }
            processedBytes = files.reduce(0) { sum, item in
                switch item.state {
                case .waiting: sum
                case .copying: sum + min(item.bytesDone, item.job.size)
                case .done, .failed, .skipped: sum + item.job.size
                }
            }
            if totalBytes > 0 {
                fraction = Double(processedBytes) / Double(totalBytes)
            } else if fileCount > 0 {
                fraction = Double(files.filter { $0.state != .waiting && $0.state != .copying }.count) / Double(fileCount)
            }
            var copied = 0, failed = 0, skipped = 0
            var bytes: Int64 = 0
            for item in files {
                switch item.state {
                case .done: copied += 1; bytes += item.bytesDone
                case .failed: failed += 1
                case .skipped: skipped += 1
                case .waiting, .copying: break
                }
            }
            summary = TransferSummary(copied: copied, failed: failed, skipped: skipped, bytes: bytes, duration: progress.activeSeconds)
        }
    }

    private func check(_ progress: TransferProgress, _ note: String) {
        let expected = Recount(progress)
        #expect(progress.fileCount == expected.fileCount, "\(note)")
        #expect(progress.doneCount == expected.doneCount, "\(note)")
        #expect(progress.failedItems.map(\.id) == expected.failedIDs, "\(note)")
        #expect(progress.failedCount == expected.failedIDs.count, "\(note)")
        #expect(progress.totalBytes == expected.totalBytes, "\(note)")
        #expect(progress.processedBytes == expected.processedBytes, "\(note)")
        #expect(progress.fraction == expected.fraction, "\(note)")
        #expect(progress.summary() == expected.summary, "\(note)")
    }

    @Test func cachedAggregatesMatchARecountAfterRandomEventSequences() {
        for seed in 1...20 {
            var random = Lcg(state: UInt64(seed))
            var progress = TransferProgress()
            var nextID = 0
            var clock = start
            for step in 0..<400 {
                clock = clock.addingTimeInterval(0.1)
                switch Int.random(in: 0..<20, using: &random) {
                case 0:
                    let jobs = (0..<Int.random(in: 1...6, using: &random)).map { _ -> TransferJob in
                        defer { nextID += 1 }
                        let kind: TransferJob.Kind = Int.random(in: 0..<5, using: &random) == 0 ? .directory : .file
                        let size = Int.random(in: 0..<4, using: &random) == 0 ? 0 : Int64.random(in: 1...1000, using: &random)
                        return job(nextID, size: kind == .directory ? 0 : size, kind: kind)
                    }
                    progress.append(jobs)
                case 1: _ = progress.resetFailed()
                case 2: progress.interrupted()
                case 3 where step > 300: progress.cancelRemaining()
                default:
                    guard nextID > 0 else { continue }
                    let id = Int.random(in: 0..<nextID, using: &random)
                    let size = progress.items[id].job.size
                    let bytes = Int64.random(in: 0...max(size * 2, 1), using: &random)
                    switch Int.random(in: 0..<5, using: &random) {
                    case 0: progress.apply(.started(job: id), at: clock)
                    case 1: progress.apply(.progress(job: id, bytes: bytes, readRate: 10, writeRate: 10), at: clock)
                    case 2: progress.apply(.finished(job: id, bytes: size), at: clock)
                    case 3: progress.apply(.skipped(job: id), at: clock)
                    default: progress.apply(.failed(job: id, TransferFailure(.unreadable)), at: clock)
                    }
                }
                check(progress, "seed \(seed) step \(step)")
            }
        }
    }

    @Test func fiftyThousandItemsAndAHundredThousandEventsStayFastEvenWhileTheTotalsAreRead() {
        let count = 50_000
        var progress = TransferProgress()
        progress.append((0..<count).map { job($0, size: 1_000) })
        let began = ContinuousClock.now
        var clock = start
        var sink = 0.0
        for index in 0..<count {
            clock = clock.addingTimeInterval(0.001)
            progress.apply(.started(job: index), at: clock)
            progress.apply(.finished(job: index, bytes: 1_000), at: clock)
            // The panel reads the totals on every update.
            if index % 25 == 0 {
                sink += progress.fraction + Double(progress.doneCount + progress.failedCount + progress.fileCount)
                sink += Double(progress.processedBytes + progress.totalBytes) + (progress.secondsRemaining ?? 0)
            }
        }
        let elapsed = ContinuousClock.now - began
        #expect(progress.doneCount == count)
        #expect(progress.fraction == 1)
        #expect(sink > 0)
        // Quadratic work took minutes here; the bound is generous so a slow machine does not flake.
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }
}
