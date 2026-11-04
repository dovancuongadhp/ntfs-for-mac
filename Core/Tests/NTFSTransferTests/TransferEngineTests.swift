import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferEngineTests {
    private func choosing(_ choice: ConflictChoice, applyToAll: Bool = false, counter: Counter? = nil) -> TransferPrompts {
        TransferPrompts(
            conflict: { _ in
                counter?.increment()
                return ConflictDecision(choice: choice, applyToAll: applyToAll)
            },
            error: { _ in ErrorDecision(choice: .skip) })
    }

    // MARK: Copying

    @Test func copiesFilesAndFoldersWithTheirContents() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("tree/a.txt", "alpha")
        try source.file("tree/sub/b.txt", "beta")
        try source.file("tree/empty.txt", "")
        let jobs = try plan([source.path("tree")], into: destination.url)

        let result = await run(jobs)

        #expect(result.outcome.stop == .finished)
        #expect(result.outcome.copied == 3)
        #expect(result.outcome.failed == 0)
        #expect(try destination.text("tree/a.txt") == "alpha")
        #expect(try destination.text("tree/sub/b.txt") == "beta")
        #expect(destination.has("tree/empty.txt"))
        let finished = result.events.filter { if case .finished = $0 { true } else { false } }
        #expect(finished.count == jobs.count)
    }

    @Test func aFileLargerThanOneChunkIsCopiedExactly() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let original = try source.data("big.bin", count: 3_000_000)
        let jobs = try plan([original], into: destination.url)

        let result = await run(jobs, chunk: 1_000_000)

        #expect(result.outcome.bytes == 3_000_000)
        #expect(try Data(contentsOf: destination.path("big.bin")) == Data(contentsOf: original))
    }

    @Test func noTemporaryFilesAreLeftBehind() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        _ = await run(try plan([source.path("a.txt")], into: destination.url))
        #expect(try destination.names() == ["a.txt"])
    }

    @Test func progressEventsCarryBytesAndRates() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let original = try source.data("f.bin", count: 5000)
        let result = await run(try plan([original], into: destination.url), chunk: 1000)
        let progress = result.events.compactMap { event -> Int64? in
            if case .progress(_, let bytes, _, _) = event { bytes } else { nil }
        }
        #expect(progress == [1000, 2000, 3000, 4000, 5000])
    }

    @Test func symbolicLinksAreRecreatedAsLinks() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("real.txt")
        try FileManager.default.createSymbolicLink(atPath: source.path("l").path, withDestinationPath: "real.txt")
        _ = await run(try plan([source.path("l")], into: destination.url))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path("l").path) == "real.txt")
    }

    @Test func modificationDatesAreKept() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try source.setModified("a.txt", date)
        _ = await run(try plan([source.path("a.txt")], into: destination.url))
        let copied = try PosixFileAccess().attributes(of: destination.path("a.txt"))
        #expect(abs(copied.modified.timeIntervalSince(date)) < 1)
    }

    // MARK: Conflicts

    private func conflict(_ choice: ConflictChoice, sourceIsNewer: Bool) async throws -> (TempFolder, TransferOutcome) {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let older = Date(timeIntervalSince1970: 1_000_000_000)
        let newer = Date(timeIntervalSince1970: 1_600_000_000)
        try source.setModified("a.txt", sourceIsNewer ? newer : older)
        try destination.setModified("a.txt", sourceIsNewer ? older : newer)
        let jobs = try plan([source.path("a.txt")], into: destination.url)
        let result = await run(jobs, prompts: choosing(choice))
        return (destination, result.outcome)
    }

    @Test func replaceOverwritesTheExistingFile() async throws {
        let (destination, outcome) = try await conflict(.replace, sourceIsNewer: false)
        #expect(try destination.text("a.txt") == "new")
        #expect(outcome.copied == 1)
    }

    @Test func keepBothAddsANumberedCopy() async throws {
        let (destination, _) = try await conflict(.keepBoth, sourceIsNewer: false)
        #expect(try destination.text("a.txt") == "old")
        #expect(try destination.text("a 2.txt") == "new")
    }

    @Test func skipLeavesTheExistingFile() async throws {
        let (destination, outcome) = try await conflict(.skip, sourceIsNewer: true)
        #expect(try destination.text("a.txt") == "old")
        #expect(outcome.skipped == 1)
        #expect(outcome.copied == 0)
    }

    @Test func replaceIfNewerReplacesOnlyWhenTheSourceIsNewer() async throws {
        let (replaced, _) = try await conflict(.replaceIfNewer, sourceIsNewer: true)
        #expect(try replaced.text("a.txt") == "new")
        let (kept, outcome) = try await conflict(.replaceIfNewer, sourceIsNewer: false)
        #expect(try kept.text("a.txt") == "old")
        #expect(outcome.skipped == 1)
    }

    @Test func applyToAllAsksOnlyOnce() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["a.txt", "b.txt", "c.txt"] {
            try source.file(name, "new")
            try destination.file(name, "old")
        }
        let jobs = try plan(["a.txt", "b.txt", "c.txt"].map { source.path($0) }, into: destination.url)
        let asked = Counter()
        let result = await run(jobs, prompts: choosing(.replace, applyToAll: true, counter: asked))
        #expect(asked.value == 1)
        #expect(result.outcome.copied == 3)
        #expect(try destination.text("c.txt") == "new")
    }

    @Test func copyingAFileOntoItselfMakesANumberedCopyWithoutAsking() async throws {
        let source = try TempFolder()
        let file = try source.file("a.txt", "same")
        let asked = Counter()
        let result = await run(try plan([file], into: source.url), prompts: choosing(.replace, counter: asked))
        #expect(asked.value == 0)
        #expect(result.outcome.copied == 1)
        #expect(try source.text("a 2.txt") == "same")
        #expect(try source.text("a.txt") == "same")
    }

    @Test func aFolderWhereAFileIsExpectedFailsThatItemOnly() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("x", "file")
        try destination.folder("x")
        try source.file("y", "ok")
        let jobs = try plan([source.path("x"), source.path("y")], into: destination.url)
        let result = await run(jobs)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.conflictingKind])
    }

    // MARK: Errors

    @Test func anUnreadableFileFailsAndTheRunContinues() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        try source.file("good.bin", "yyyy")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let jobs = try plan(["bad.bin", "good.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .finished)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["good.bin"])
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.unreadable])
    }

    @Test func runningOutOfSpaceStopsAndKeepsTheRestWaiting() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["a.bin", "b.bin", "c.bin"] { try source.file(name, "data") }
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let jobs = try plan(["a.bin", "b.bin", "c.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .noSpace)
        #expect(result.outcome.remaining.map(\.name) == ["b.bin", "c.bin"])
        #expect(try destination.names() == ["a.bin"])
        let failed = result.events.filter { if case .failed = $0 { true } else { false } }
        #expect(failed.isEmpty)
    }

    @Test func aVanishedDriveStopsTheRun() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "data")
        try source.file("b.bin", "data")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["b.bin"]; $0.vanished = true }
        let jobs = try plan(["a.bin", "b.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .driveRemoved)
        #expect(result.outcome.remaining.map(\.name) == ["b.bin"])
    }

    @Test func askingOnErrorCanRetryThenSkip() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "data")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let asked = Counter()
        let answers = Counter()
        let prompts = TransferPrompts(
            conflict: { _ in ConflictDecision(choice: .skip) },
            error: { _ in
                asked.increment()
                answers.increment()
                return ErrorDecision(choice: answers.value == 1 ? .retry : .skip)
            })

        let result = await run(try plan([source.path("bad.bin")], into: destination.url), access: flaky, askOnError: true, prompts: prompts)

        #expect(asked.value == 2)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.stop == .finished)
    }

    @Test func choosingStopEndsTheRunAndKeepsTheRest() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["bad.bin", "next.bin"] { try source.file(name, "data") }
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let prompts = TransferPrompts(
            conflict: { _ in ConflictDecision(choice: .skip) },
            error: { _ in ErrorDecision(choice: .stop) })
        let jobs = try plan(["bad.bin", "next.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky, askOnError: true, prompts: prompts)

        #expect(result.outcome.stop == .userStopped)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.remaining.map(\.name) == ["next.bin"])
    }

    // MARK: Verification

    @Test func verifyAcceptsAnIdenticalCopy() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("a.bin", count: 5000)
        let result = await run(try plan([source.path("a.bin")], into: destination.url), verify: true)
        #expect(result.outcome.copied == 1)
        #expect(result.outcome.failed == 0)
    }

    @Test func verifyCatchesACorruptedCopyAndRemovesIt() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("b.bin", count: 5000)
        try source.data("c.bin", count: 100)
        let flaky = Flaky()
        flaky.update { $0.corrupt = ["b.bin"] }
        let jobs = try plan(["b.bin", "c.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky, verify: true)

        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["c.bin"])
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.checksumMismatch])
    }

    // MARK: Control

    @Test func aPausedEngineDoesNothingUntilResumed() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let jobs = try plan([source.path("a.txt")], into: destination.url)
        let control = TransferControl()
        control.pause()

        let task = Task { await run(jobs, control: control) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!destination.has("a.txt"))

        control.resume()
        let result = await task.value
        #expect(result.outcome.copied == 1)
        #expect(destination.has("a.txt"))
    }

    @Test func cancellingBeforeTheStartCopiesNothing() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        try source.file("b.txt")
        let jobs = try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url)
        let control = TransferControl()
        control.cancel()

        let result = await run(jobs, control: control)

        #expect(result.outcome.stop == .cancelled)
        #expect(result.outcome.remaining.count == 2)
        #expect(try destination.names().isEmpty)
    }

    @Test func cancellingMidFileRemovesThePartialCopy() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("big.bin", count: 10_000)
        let control = TransferControl()
        let jobs = try plan([source.path("big.bin")], into: destination.url)

        let result = await run(jobs, chunk: 1000, control: control) { event in
            if case .progress(_, let bytes, _, _) = event, bytes >= 3000 { control.cancel() }
        }

        #expect(result.outcome.stop == .cancelled)
        #expect(try destination.names().isEmpty)
    }

    @Test func skippingTheCurrentFileMovesOnToTheNextOne() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("big.bin", count: 10_000)
        try source.file("small.txt", "ok")
        let control = TransferControl()
        let jobs = try plan(["big.bin", "small.txt"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, chunk: 1000, control: control) { event in
            if case .progress(_, let bytes, _, _) = event, bytes == 2000 { control.skipCurrent() }
        }

        #expect(result.outcome.skipped == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["small.txt"])
    }
}
