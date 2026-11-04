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
