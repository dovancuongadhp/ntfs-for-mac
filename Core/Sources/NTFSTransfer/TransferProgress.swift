import Foundation

public struct TransferItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case waiting
        case copying
        case done
        case failed(TransferFailure)
        case skipped
    }

    public var job: TransferJob
    public var state: State = .waiting
    public var bytesDone: Int64 = 0

    public var id: Int { job.id }

    public var failure: TransferFailure? {
        if case .failed(let failure) = state { failure } else { nil }
    }
}

public struct TransferSummary: Sendable, Equatable {
    public var copied: Int
    public var failed: Int
    public var skipped: Int
    public var bytes: Int64
    public var duration: TimeInterval

    public init(copied: Int, failed: Int, skipped: Int, bytes: Int64, duration: TimeInterval) {
        self.copied = copied
        self.failed = failed
        self.skipped = skipped
        self.bytes = bytes
        self.duration = duration
    }
}

/// What the progress panel shows, built from the engine's events.
public struct TransferProgress: Sendable, Equatable {
    public private(set) var items: [TransferItem] = []
    public private(set) var readRate = 0.0
    public private(set) var writeRate = 0.0
    public private(set) var activeSeconds = 0.0
    private var lastEvent: Date?
    private var indexByID: [Int: Int] = [:]

    public init() {}

    public mutating func append(_ jobs: [TransferJob]) {
        for job in jobs {
            indexByID[job.id] = items.count
            items.append(TransferItem(job: job))
        }
    }

    public mutating func apply(_ event: TransferEvent, at date: Date) {
        if let lastEvent {
            activeSeconds += min(max(date.timeIntervalSince(lastEvent), 0), 2)
        }
        lastEvent = date
        switch event {
        case .started(let id):
            update(id) { $0.state = .copying; $0.bytesDone = 0 }
        case .progress(let id, let bytes, let read, let write):
            update(id) { $0.bytesDone = bytes }
            readRate = Self.smooth(readRate, read)
            writeRate = Self.smooth(writeRate, write)
        case .finished(let id, let bytes):
            update(id) { $0.state = .done; $0.bytesDone = bytes }
        case .skipped(let id):
            update(id) { $0.state = .skipped }
        case .failed(let id, let failure):
            update(id) { $0.state = .failed(failure) }
        }
    }

    /// Puts the failed items back to waiting and returns their jobs to run again.
    public mutating func resetFailed() -> [TransferJob] {
        var jobs: [TransferJob] = []
        for index in items.indices where items[index].failure != nil {
            items[index].state = .waiting
            items[index].bytesDone = 0
            jobs.append(items[index].job)
        }
        return jobs
    }

    /// A run ended with a file half done: it will start over, so show it as waiting.
    public mutating func interrupted() {
        for index in items.indices where items[index].state == .copying {
            items[index].state = .waiting
            items[index].bytesDone = 0
        }
    }

    public mutating func cancelRemaining() {
        for index in items.indices where items[index].state == .waiting || items[index].state == .copying {
            items[index].state = .skipped
        }
    }

    public func summary() -> TransferSummary {
        var copied = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        for item in items where !item.job.isDirectory {
            switch item.state {
            case .done:
                copied += 1
                bytes += item.bytesDone
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .waiting, .copying: break
            }
        }
        return TransferSummary(copied: copied, failed: failed, skipped: skipped, bytes: bytes, duration: activeSeconds)
    }

    // MARK: Derived

    private var files: [TransferItem] { items.filter { !$0.job.isDirectory } }

    public var fileCount: Int { files.count }

    public var doneCount: Int { files.filter { $0.state == .done }.count }

    public var failedItems: [TransferItem] { items.filter { $0.failure != nil } }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.job.size } }

    public var processedBytes: Int64 {
        files.reduce(0) { sum, item in
            switch item.state {
            case .waiting: sum
            case .copying: sum + min(item.bytesDone, item.job.size)
            case .done, .failed, .skipped: sum + item.job.size
            }
        }
    }

    public var fraction: Double {
        let total = totalBytes
        if total > 0 { return Double(processedBytes) / Double(total) }
        let count = fileCount
        guard count > 0 else { return 0 }
        let processed = files.filter { $0.state != .waiting && $0.state != .copying }.count
        return Double(processed) / Double(count)
    }

    /// Reading and writing alternate, so the speed of the whole is the two combined in series.
    public var effectiveRate: Double {
        guard readRate > 0, writeRate > 0 else { return max(readRate, writeRate) }
        return 1 / (1 / readRate + 1 / writeRate)
    }

    public var secondsRemaining: Double? {
        let rate = effectiveRate
        let left = totalBytes - processedBytes
        guard rate > 0, left >= 0 else { return nil }
        return Double(left) / rate
    }

    private mutating func update(_ id: Int, _ change: (inout TransferItem) -> Void) {
        if let index = indexByID[id] { change(&items[index]) }
    }

    private static func smooth(_ old: Double, _ new: Double) -> Double {
        guard new > 0 else { return old }
        return old == 0 ? new : old * 0.7 + new * 0.3
    }
}
