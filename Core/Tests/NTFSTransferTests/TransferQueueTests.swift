import Foundation
import Testing
@testable import NTFSTransfer

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
@Suite struct TransferQueueTests {
    @Test func copiesEverythingAndReportsTheSummary() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "alpha")
        try source.file("b.txt", "beta")
        let queue = TransferQueue()
        var finished: (TransferSummary, TransferStop)?
        queue.onFinish = { summary, stop in finished = (summary, stop) }

        queue.enqueue(try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.summary?.copied == 2)
        #expect(finished?.0.copied == 2)
        #expect(finished?.1 == .finished)
        #expect(try destination.text("b.txt") == "beta")
        #expect(!queue.isBusy)
    }

    @Test func aSecondBatchWhileRunningIsAppendedAndRunsAfterTheFirst() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("one.bin", count: 2_000_000)
        try source.file("two.txt", "2")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("one.bin")], into: destination.url))
        queue.enqueue(try plan([source.path("two.txt")], into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.fileCount == 2)
        #expect(queue.summary?.copied == 2)
        #expect(destination.has("two.txt"))
    }

    @Test func failedFilesCanBeRetried() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        try source.file("good.bin", "yyyy")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(try plan(["bad.bin", "good.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.failedItems.count == 1)
        #expect(queue.summary?.failed == 1)

        flaky.update { $0.failReading = [] }
        queue.retryFailed()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.failedItems.isEmpty)
        #expect(queue.summary?.copied == 2)
        #expect(try destination.text("bad.bin") == "xxxx")
    }

    @Test func aConflictIsAskedThroughTheQueue() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        #expect(queue.conflict?.info.name == "a.txt")
        queue.answer(ConflictDecision(choice: .replace))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.conflict == nil)
        #expect(try destination.text("a.txt") == "new")
    }

    @Test func runningOutOfSpaceHaltsAndResumeContinues() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "aaaa")
        try source.file("b.bin", "bbbb")
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(try plan(["a.bin", "b.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .stopped(.noSpace) })
        #expect(queue.progress.items.last?.state == .waiting)

        flaky.update { $0.failWriting = [:] }
        queue.resume()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(try destination.text("b.bin") == "bbbb")
    }

    @Test func cancellingMarksTheRestSkippedAndFinishes() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "x")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        await queue.cancelAndWait()

        #expect(queue.phase == .finished)
        #expect(queue.progress.items.allSatisfy { $0.state == .skipped })
        #expect(try destination.text("a.txt") == "old")
    }

    @Test func clearingAFinishedQueueGoesBackToIdle() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })
        queue.clear()
        #expect(queue.phase == .idle)
        #expect(queue.progress.items.isEmpty)
        #expect(queue.summary == nil)
    }
}
