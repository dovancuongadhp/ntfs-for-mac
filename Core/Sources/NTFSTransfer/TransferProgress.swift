import Foundation

public struct TransferItem: Identifiable, Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
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
///
/// The totals the panel reads on every update are kept as counters that change with each event, so
/// reading them costs nothing however many files there are.
public struct TransferProgress: Sendable, Equatable {
    public private(set) var items: [TransferItem] = []
    public private(set) var readRate = 0.0
    public private(set) var writeRate = 0.0
    public private(set) var activeSeconds = 0.0
    private var lastEvent: Date?
    private var indexByID: [Int: Int] = [:]
    private var totals = Totals()

    /// What the files (not the folders) add up to.
    private struct Totals: Sendable, Equatable {
        var files = 0
        var done = 0
        var failed = 0
        var skipped = 0
        var bytes: Int64 = 0
        var processedBytes: Int64 = 0
        /// Files that are neither waiting nor copying.
        var settled = 0
        var copiedBytes: Int64 = 0
        /// Failures of folders too, which the error list shows.
        var failedItems = 0

        mutating func add(_ item: TransferItem, sign: Int) {
            let sign64 = Int64(sign)
            if item.failure != nil { failedItems += sign }
            guard !item.job.isDirectory else { return }
            files += sign
            bytes += sign64 * item.job.size
            switch item.state {
            case .waiting:
                break
            case .copying:
                processedBytes += sign64 * min(item.bytesDone, item.job.size)
            case .done:
                done += sign
                settled += sign
                processedBytes += sign64 * item.job.size
                copiedBytes += sign64 * item.bytesDone
            case .failed:
                failed += sign
                settled += sign
                processedBytes += sign64 * item.job.size
            case .skipped:
                skipped += sign
                settled += sign
                processedBytes += sign64 * item.job.size
            }
        }
    }

    public init() {}

    /// Totals for items already under way or over, such as one copy's share of the list.
    init(items: [TransferItem]) {
        self.items = items
        for (index, item) in items.enumerated() {
            indexByID[item.id] = index
            totals.add(item, sign: 1)
        }
    }

    public mutating func append(_ jobs: [TransferJob]) {
        items.reserveCapacity(items.count + jobs.count)
        for job in jobs {
            indexByID[job.id] = items.count
            let item = TransferItem(job: job)
            totals.add(item, sign: 1)
            items.append(item)
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
            change(at: index) { $0.state = .waiting; $0.bytesDone = 0 }
            jobs.append(items[index].job)
        }
        return jobs
    }

    /// A run ended with a file half done: it will start over, so show it as waiting.
    public mutating func interrupted() {
        for index in items.indices where items[index].state == .copying {
            change(at: index) { $0.state = .waiting; $0.bytesDone = 0 }
        }
    }

    public mutating func cancelRemaining() {
        for index in items.indices where items[index].state == .waiting || items[index].state == .copying {
            change(at: index) { $0.state = .skipped }
        }
    }

    public func summary() -> TransferSummary {
        TransferSummary(
            copied: totals.done, failed: totals.failed, skipped: totals.skipped,
            bytes: totals.copiedBytes, duration: activeSeconds)
    }

    // MARK: Derived

    public var fileCount: Int { totals.files }

    public var doneCount: Int { totals.done }

    /// How many items failed, without building the list.
    public var failedCount: Int { totals.failedItems }

    public var failedItems: [TransferItem] { items.filter { $0.failure != nil } }

    public var totalBytes: Int64 { totals.bytes }

    public var processedBytes: Int64 { totals.processedBytes }

    public var fraction: Double {
        if totals.bytes > 0 { return Double(totals.processedBytes) / Double(totals.bytes) }
        guard totals.files > 0 else { return 0 }
        return Double(totals.settled) / Double(totals.files)
    }

    /// Reading and writing alternate, so the speed of the whole is the two combined in series.
    public var effectiveRate: Double {
        guard readRate > 0, writeRate > 0 else { return max(readRate, writeRate) }
        return 1 / (1 / readRate + 1 / writeRate)
    }

    public var secondsRemaining: Double? {
        let rate = effectiveRate
        let left = totals.bytes - totals.processedBytes
        guard rate > 0, left >= 0 else { return nil }
        return Double(left) / rate
    }

    private mutating func update(_ id: Int, _ body: (inout TransferItem) -> Void) {
        if let index = indexByID[id] { change(at: index, body) }
    }

    /// Every change to an item goes through here, which keeps the counters right.
    private mutating func change(at index: Int, _ body: (inout TransferItem) -> Void) {
        totals.add(items[index], sign: -1)
        body(&items[index])
        totals.add(items[index], sign: 1)
    }

    private static func smooth(_ old: Double, _ new: Double) -> Double {
        guard new > 0 else { return old }
        return old == 0 ? new : old * 0.7 + new * 0.3
    }
}
