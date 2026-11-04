import Foundation
import os
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

    // MARK: A stale answer must not reach the next question

    @Test func anAnswerForAnEarlierConflictIsIgnoredAndTheNewOneStaysPending() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["a.txt", "b.txt"] {
            try source.file(name, "new")
            try destination.file(name, "old")
        }
        let queue = TransferQueue()
        queue.enqueue(try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.conflict?.info.name == "a.txt" })
        let first = try #require(queue.conflict)
        queue.answer(ConflictDecision(choice: .skip), for: first)
        #expect(await waitUntil { queue.conflict?.info.name == "b.txt" })
        let second = try #require(queue.conflict)

        // A late click or a held Return on the first sheet arrives now.
        queue.answer(ConflictDecision(choice: .replace), for: first)
        #expect(queue.conflict === second)
        #expect(try destination.text("b.txt") == "old")

        queue.answer(ConflictDecision(choice: .skip), for: second)
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.conflict == nil)
        #expect(try destination.text("a.txt") == "old")
        #expect(try destination.text("b.txt") == "old")
    }

    @Test func anAnswerForTheCurrentConflictStillWorks() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        queue.answer(ConflictDecision(choice: .replace), for: try #require(queue.conflict))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(try destination.text("a.txt") == "new")
    }

    @Test func anAnswerForAnEarlierErrorIsIgnoredAndTheNewOneStaysPending() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad1.bin", "xxxx")
        try source.file("bad2.bin", "yyyy")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad1.bin", "bad2.bin"] }
        let queue = TransferQueue(access: flaky)
        queue.options = TransferOptions(askOnError: true)
        queue.enqueue(try plan(["bad1.bin", "bad2.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.errorPrompt?.info.name == "bad1.bin" })
        let first = try #require(queue.errorPrompt)
        queue.answerError(ErrorDecision(choice: .skip), for: first)
        #expect(await waitUntil { queue.errorPrompt?.info.name == "bad2.bin" })
        let second = try #require(queue.errorPrompt)

        queue.answerError(ErrorDecision(choice: .stop), for: first)
        #expect(queue.errorPrompt === second)
        #expect(queue.phase == .running)

        queue.answerError(ErrorDecision(choice: .skip), for: second)
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.lastStop == .finished)
    }

    @Test func aNewPromptTellsTheOwnerSoItCanGetAttention() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        let prompts = Counter()
        queue.onPrompt = {
            // The request is already visible when the owner is told.
            if queue.conflict != nil { prompts.increment() }
        }
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        #expect(prompts.value == 1)
        queue.answer(ConflictDecision(choice: .skip))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(prompts.value == 1)
    }

    // MARK: Why the queue ended

    @Test func aFinishedCopyRemembersItFinished() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let queue = TransferQueue()
        #expect(queue.lastStop == nil)
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.lastStop == .finished)
    }

    @Test func aCancelledCopyRemembersItWasCancelled() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "x")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        await queue.cancelAndWait()

        #expect(queue.phase == .finished)
        #expect(queue.lastStop == .cancelled)
        queue.clear()
        #expect(queue.lastStop == nil)
    }

    /// The engine says "finished" when the cancel arrives during its last file; the queue must still read it as
    /// a cancel and drop the batches that were waiting behind it.
    @Test func aCancelDuringTheLastFileOfABatchAlsoDropsTheBatchesBehindIt() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "x")
        try source.file("later.txt", "y")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))
        queue.enqueue(try plan([source.path("later.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        await queue.cancelAndWait()

        #expect(queue.phase == .finished)
        #expect(queue.lastStop == .cancelled)
        #expect(queue.summary != nil)
        #expect(!destination.has("later.txt"))
        #expect(try destination.text("a.txt") == "old")
        #expect(queue.progress.items.count == 2)
        #expect(queue.progress.items.allSatisfy { $0.state == .skipped })
    }

    @Test func aCopyStoppedByTheUserRemembersThat() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let queue = TransferQueue(access: flaky)
        queue.options = TransferOptions(askOnError: true)
        queue.enqueue(try plan([source.path("bad.bin")], into: destination.url))

        #expect(await waitUntil { queue.errorPrompt != nil })
        queue.answerError(ErrorDecision(choice: .stop))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.lastStop == .userStopped)
    }

    @Test func aHaltedCopyKnowsWhyAndAFreshCopyForgetsIt() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "aaaa")
        try source.file("b.bin", "bbbb")
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(try plan(["a.bin", "b.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .stopped(.noSpace) })
        #expect(queue.lastStop == .noSpace)

        flaky.update { $0.failWriting = [:] }
        queue.resume()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.lastStop == .finished)

        let other = try TempFolder()
        queue.enqueue(try plan([source.path("a.bin")], into: other.url))
        #expect(queue.lastStop == nil)
        #expect(await waitUntil { queue.phase == .finished })
    }

    // MARK: Updates reach the screen a few times a second

    @Test func manyEventsAreCoalescedIntoFewReportsButTheEndIsAlwaysReported() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let names = (0..<40).map { "f\($0).txt" }
        for name in names { try source.file(name) }
        let queue = TransferQueue()
        queue.progressInterval = .seconds(30)
        let reports = Counter()
        queue.onProgress = { _ in reports.increment() }

        queue.enqueue(try plan(names.map { source.path($0) }, into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })

        // 40 files make at least 80 events; a 30 s interval lets only the edges through.
        #expect(reports.value <= 5, "reports: \(reports.value)")
        #expect(queue.progress.doneCount == 40)
        #expect(queue.progress.fraction == 1)
    }

    @Test func withoutAnIntervalEveryEventIsReported() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let names = (0..<40).map { "f\($0).txt" }
        for name in names { try source.file(name) }
        let queue = TransferQueue()
        queue.progressInterval = .zero
        let reports = Counter()
        queue.onProgress = { _ in reports.increment() }

        queue.enqueue(try plan(names.map { source.path($0) }, into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })
        #expect(reports.value >= 80, "reports: \(reports.value)")
    }

    /// Stands in for `Task.sleep`: notes how long it was asked to wait and returns only when opened.
    private final class SleepGate: Sendable {
        private struct State {
            var requested: [Duration] = []
            var waiters: [CheckedContinuation<Void, Never>] = []
            var isOpen = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var requested: [Duration] { state.withLock { $0.requested } }

        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    state.requested.append(duration)
                    if state.isOpen { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    @Test func aReportThatWasHeldBackStillArrivesAfterTheInterval() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        try source.file("b.txt")
        let target = destination.path("b.txt").standardizedFileURL.path
        let gate = Gate()
        let flaky = Flaky()
        flaky.update {
            $0.beforeAttributes = { url in
                if url.standardizedFileURL.path == target, !gate.hasArrived { gate.arriveAndWait() }
            }
        }
        let queue = TransferQueue(access: flaky)
        let interval = Duration.seconds(3600)
        queue.progressInterval = interval
        let sleeps = SleepGate()
        queue.sleep = { await sleeps.sleep($0) }
        let reports = Counter()
        let doneInLastReport = Counter()
        queue.onProgress = { progress in
            reports.increment()
            doneInLastReport.set(progress.doneCount)
        }
        queue.enqueue(try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url))

        // a's events came within one interval of the last report, so they are held back and a wait is scheduled.
        #expect(await waitUntil { gate.hasArrived })
        #expect(await waitUntil { !sleeps.requested.isEmpty })
        let wait = try #require(sleeps.requested.first)
        #expect(wait > .zero && wait <= interval, "waits \(wait)")
        let before = reports.value
        #expect(doneInLastReport.value == 0)

        // When the wait is over the held-back report arrives, with a already counted.
        sleeps.open()
        #expect(await waitUntil { doneInLastReport.value == 1 })
        #expect(reports.value > before)
        gate.open()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(doneInLastReport.value == 2)
    }
}
