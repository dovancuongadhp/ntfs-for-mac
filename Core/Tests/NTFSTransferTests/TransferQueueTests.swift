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

    @Test func cancellingWhileTheEngineIsAboutToAskDoesNotHang() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let jobs = try plan([source.path("a.txt")], into: destination.url)
        let target = destination.path("a.txt").standardizedFileURL.path
        let gate = Gate()
        let flaky = Flaky()
        flaky.update {
            $0.beforeAttributes = { url in
                if url.standardizedFileURL.path == target, !gate.hasArrived { gate.arriveAndWait() }
            }
        }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(jobs)

        // The engine is now held just before it looks at the existing file, so it has not asked yet.
        #expect(await waitUntil { gate.hasArrived })
        queue.cancel()
        gate.open()

        let returned = Counter()
        let waiter = Task {
            await queue.cancelAndWait()
            returned.increment()
        }
        let done = await waitUntil(timeout: .seconds(5)) { returned.value > 0 }
        // Unstick a pre-fix hang so the test can end.
        if !done { queue.answer(ConflictDecision(choice: .skip)) }
        await waiter.value
        #expect(done)
        #expect(queue.phase == .finished)
        #expect(queue.conflict == nil)
        #expect(try destination.text("a.txt") == "old")
    }

    @Test func cancellingWhileTheEngineIsAboutToReportAnErrorDoesNotHang() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        let jobs = try plan([source.path("bad.bin")], into: destination.url)
        let gate = Gate()
        let flaky = Flaky()
        flaky.update {
            // The engine is held inside the read; the read then fails, which is what makes it ask.
            $0.onSourceRead = {
                gate.arriveAndWait()
                throw POSIXError(.EIO)
            }
        }
        let queue = TransferQueue(access: flaky)
        queue.options = TransferOptions(askOnError: true)
        queue.enqueue(jobs)

        #expect(await waitUntil { gate.hasArrived })
        queue.cancel()
        gate.open()

        let returned = Counter()
        let waiter = Task {
            await queue.cancelAndWait()
            returned.increment()
        }
        let done = await waitUntil(timeout: .seconds(5)) { returned.value > 0 }
        if !done { queue.answerError(ErrorDecision(choice: .skip)) }
        await waiter.value
        #expect(done)
        #expect(queue.errorPrompt == nil)
    }

    @Test func cancellingAnIdleOrFinishedQueueDoesNotFinishAgain() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let queue = TransferQueue()
        let finishes = Counter()
        queue.onFinish = { _, _ in finishes.increment() }

        queue.cancel()
        #expect(queue.phase == .idle)
        #expect(finishes.value == 0)

        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(finishes.value == 1)

        queue.cancel()
        await queue.cancelAndWait()
        #expect(queue.phase == .finished)
        #expect(finishes.value == 1)
        #expect(queue.summary?.copied == 1)
    }

    @Test func cancellingAHaltedQueueRemovesLeftoverTemporaryFiles() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "aaaa")
        try source.file("b.bin", "bbbb")
        try source.file("c.bin", "cccc")
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let queue = TransferQueue(access: flaky)
        let finishes = Counter()
        queue.onFinish = { _, _ in finishes.increment() }
        queue.enqueue(try plan(["a.bin", "b.bin", "c.bin"].map { source.path($0) }, into: destination.url))
        #expect(await waitUntil { queue.phase == .stopped(.noSpace) })
        #expect(finishes.value == 1)
        try destination.file(".b.bin.ntfs-part", "half")
        try destination.file(".c.bin.ntfs-part", "half")
        try destination.file(".unrelated.ntfs-part", "keep")

        queue.cancel()

        #expect(queue.phase == .finished)
        #expect(finishes.value == 2)
        #expect(try destination.names() == [".unrelated.ntfs-part", "a.bin"])
        #expect(queue.progress.items.filter { $0.state == .skipped }.count == 2)
    }
}
