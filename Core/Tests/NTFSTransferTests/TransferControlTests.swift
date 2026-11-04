import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferControlTests {
    @Test func pauseAndResumeToggleTheFlag() {
        let control = TransferControl()
        #expect(!control.isPaused)
        control.pause()
        #expect(control.isPaused)
        control.resume()
        #expect(!control.isPaused)
    }

    @Test func cancelLiftsAPauseSoWaitersWakeUp() {
        let control = TransferControl()
        control.pause()
        control.cancel()
        #expect(control.isCancelled)
        #expect(!control.isPaused)
    }

    @Test func pausingAfterCancellingDoesNothing() {
        let control = TransferControl()
        control.cancel()
        control.pause()
        #expect(!control.isPaused)
    }

    @Test func waitingReturnsAtOnceWhenCancelled() async throws {
        let control = TransferControl()
        control.pause()
        control.cancel()
        control.pause()
        let returned = Counter()
        let waiter = Task {
            await control.waitWhilePaused()
            returned.increment()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while returned.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let stuck = returned.value == 0
        waiter.cancel()
        await waiter.value
        #expect(!stuck)
    }

    @Test func waitingCanBeInterruptedBySkip() async throws {
        let control = TransferControl()
        control.pause()
        let waiter = Task { await control.waitWhilePaused(interruptedBySkip: true) }
        try await Task.sleep(for: .milliseconds(80))
        control.skipCurrent()
        await waiter.value
        #expect(control.isPaused)
        #expect(control.takeSkip())
    }

    @Test func skipIsTakenOnceAndCanBeCleared() {
        let control = TransferControl()
        control.skipCurrent()
        #expect(control.takeSkip())
        #expect(!control.takeSkip())
        control.skipCurrent()
        control.clearSkip()
        #expect(!control.takeSkip())
    }

    @Test func waitingReturnsOnceResumed() async throws {
        let control = TransferControl()
        control.pause()
        let waiter = Task { await control.waitWhilePaused() }
        try await Task.sleep(for: .milliseconds(120))
        control.resume()
        await waiter.value
    }

    @Test func rateMeterReportsBytesPerSecondOfEachSideAndResets() {
        var meter = RateMeter()
        meter.addRead(bytes: 1000, seconds: 0.5)
        meter.addWrite(bytes: 1000, seconds: 0.25)
        let first = meter.takeRates()
        #expect(first.read == 2000)
        #expect(first.write == 4000)
        let second = meter.takeRates()
        #expect(second.read == 0)
        #expect(second.write == 0)
    }
}
