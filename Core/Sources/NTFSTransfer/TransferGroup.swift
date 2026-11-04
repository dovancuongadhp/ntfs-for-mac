import Foundation

/// One copy the person asked for (a press of Copy, a paste or a drop) and how its files are doing.
public struct TransferGroup: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Queued behind another copy; nothing of it has run yet.
        case waiting
        case copying
        /// Every file is done, failed or skipped.
        case over
    }

    public let id: Int
    public let started: Date
    /// The folder the copied items were in, and the folder they went to.
    public let from: URL
    public let to: URL
    public let progress: TransferProgress
    public let status: Status

    init(record: TransferQueue.CopyRecord, items: [TransferItem]) {
        id = record.firstJobID
        started = record.started
        from = record.from
        to = record.to
        progress = TransferProgress(items: items)
        status = Self.status(of: items)
    }

    static func status(of items: [TransferItem]) -> Status {
        var settled = false
        var unsettled = false
        for item in items {
            switch item.state {
            case .copying: return .copying
            case .waiting: unsettled = true
            case .done, .failed, .skipped: settled = true
            }
        }
        if !unsettled { return .over }
        return settled ? .copying : .waiting
    }
}
