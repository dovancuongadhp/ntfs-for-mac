import Foundation
import os

/// Lets the interface pause, skip or cancel an engine that runs on another thread.
public final class TransferControl: Sendable {
    private struct State {
        var paused = false
        var cancelled = false
        var skip = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isPaused: Bool { state.withLock { $0.paused } }
    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func pause() { state.withLock { $0.paused = true } }
    public func resume() { state.withLock { $0.paused = false } }
    public func cancel() { state.withLock { $0.cancelled = true; $0.paused = false } }
    public func skipCurrent() { state.withLock { $0.skip = true } }

    func clearSkip() { state.withLock { $0.skip = false } }

    func takeSkip() -> Bool {
        state.withLock { state in
            let wanted = state.skip
            state.skip = false
            return wanted
        }
    }

    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Measures how fast reading and writing each go, counting only the time spent in those calls.
struct RateMeter {
    private var readBytes = 0
    private var readSeconds = 0.0
    private var writeBytes = 0
    private var writeSeconds = 0.0

    mutating func addRead(bytes: Int, seconds: Double) {
        readBytes += bytes
        readSeconds += seconds
    }

    mutating func addWrite(bytes: Int, seconds: Double) {
        writeBytes += bytes
        writeSeconds += seconds
    }

    /// Bytes per second since the last call; starts a new window.
    mutating func takeRates() -> (read: Double, write: Double) {
        let rates = (
            read: readSeconds > 0 ? Double(readBytes) / readSeconds : 0,
            write: writeSeconds > 0 ? Double(writeBytes) / writeSeconds : 0)
        self = RateMeter()
        return rates
    }
}
