import Foundation
import NTFSTransfer
import os

/// The words the transfer screens use. The package reports reasons; this turns them into text.
enum TransferText {
    static func failure(_ reason: TransferFailureReason) -> String {
        switch reason {
        case .unreadable: String(localized: "Can't read this file. It may be damaged.")
        case .writeFailed: String(localized: "Couldn't write to the destination.")
        case .noSpace: String(localized: "The destination is full.")
        case .driveRemoved: String(localized: "The drive was disconnected.")
        case .permissionDenied: String(localized: "No permission to read or write here.")
        case .invalidName: String(localized: "The name isn't allowed on the destination.")
        case .checksumMismatch: String(localized: "The copy didn't match the original.")
        case .sizeMismatch: String(localized: "The file changed while copying.")
        case .sourceMissing: String(localized: "The file was removed before it could be copied.")
        case .conflictingKind: String(localized: "A folder and a file have the same name.")
        case .fileTooLarge: String(localized: "The file is too large for the destination's file system.")
        }
    }

    static func problems(_ problems: [TransferProblem]) -> String {
        var lines: [String] = []
        for problem in problems {
            switch problem {
            case .notEnoughSpace(let needed, let available):
                lines.append(String(localized: "Not enough space on the destination. Needed \(size(needed)), available \(size(available))."))
            case .destinationReadOnly:
                lines.append(String(localized: "This drive is read-only. Turn on writing for it in its drive page."))
            default:
                break
            }
        }
        let others = problems.filter { $0.jobID != nil }
        for problem in others.prefix(5) {
            switch problem {
            case .invalidName(_, let name):
                lines.append(String(localized: "“\(name)” can't be stored on this drive: the name isn't allowed."))
            case .fileTooLarge(_, let name):
                lines.append(String(localized: "“\(name)” is too large for this drive's file system."))
            case .notEnoughSpace, .destinationReadOnly:
                break
            }
        }
        if others.count > 5 {
            lines.append(String(localized: "…and \(others.count - 5) more"))
        }
        return lines.joined(separator: "\n")
    }

    static func notice(for summary: TransferSummary, stop: TransferStop) -> (title: String, body: String) {
        switch stop {
        case .finished where summary.failed == 0:
            (String(localized: "Copy complete"),
             String(localized: "Files copied: \(summary.copied) · \(size(summary.bytes)) · \(duration(summary.duration))"))
        case .finished:
            (String(localized: "Copy finished with errors"),
             String(localized: "Files copied: \(summary.copied) · Failed: \(summary.failed)"))
        case .cancelled:
            (String(localized: "Copy cancelled"),
             String(localized: "Files copied: \(summary.copied) · Skipped: \(summary.skipped)"))
        case .noSpace:
            (String(localized: "The destination is full"),
             String(localized: "Free some space, then resume the copy."))
        case .driveRemoved:
            (String(localized: "A drive was disconnected"),
             String(localized: "Reconnect it, then resume the copy."))
        case .userStopped:
            (String(localized: "Copy stopped"),
             String(localized: "Files copied: \(summary.copied) · Failed: \(summary.failed)"))
        }
    }

    /// The panel's headline: how far along, or why the copy ended.
    static func headline(
        phase: TransferQueue.Phase, lastStop: TransferStop?, summary: TransferSummary?, done: Int, total: Int
    ) -> String {
        switch phase {
        case .idle, .running: String(localized: "Copying files: \(done) of \(total)")
        case .paused: String(localized: "Paused")
        case .stopped(let stop): notice(for: summary ?? empty, stop: stop).title
        case .finished: notice(for: summary ?? empty, stop: endedBy(lastStop)).title
        }
    }

    /// The line under the headline once the copy has ended, with what to do next if it halted; nil while
    /// it is under way.
    static func detail(phase: TransferQueue.Phase, lastStop: TransferStop?, summary: TransferSummary?) -> String? {
        switch phase {
        case .idle, .running, .paused: nil
        case .stopped(let stop): notice(for: summary ?? empty, stop: stop).body
        case .finished: notice(for: summary ?? empty, stop: endedBy(lastStop)).body
        }
    }

    private static let empty = TransferSummary(copied: 0, failed: 0, skipped: 0, bytes: 0, duration: 0)

    /// A finished queue ended by finishing, or because the person cancelled or stopped it.
    private static func endedBy(_ stop: TransferStop?) -> TransferStop {
        switch stop {
        case .cancelled?: .cancelled
        case .userStopped?: .userStopped
        default: .finished
        }
    }

    /// What to tell the person when a question is waiting and they may not be looking.
    static func promptNotice() -> (title: String, body: String) {
        (String(localized: "Copying is waiting for you"),
         String(localized: "A file needs your decision. Open NTFS for Mac to continue."))
    }

    /// The warning before items are deleted for good, either because their volume has no Trash or on request.
    static func deleteMessage(for request: DeleteRequest) -> String {
        let urls = request.urls
        guard let first = urls.first else { return "" }
        if urls.count == 1 {
            let name = first.lastPathComponent
            return switch request.reason {
            case .noTrash: String(localized: "“\(name)” can't be moved to the Trash. It will be deleted permanently.")
            case .chosen: String(localized: "“\(name)” will be deleted immediately. You can't undo this action.")
            }
        }
        var names = urls.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
        if urls.count > 3 { names += " " + String(localized: "…and \(urls.count - 3) more") }
        let summary = switch request.reason {
        case .noTrash: String(localized: "\(urls.count) items can't be moved to the Trash. They will be deleted permanently.")
        case .chosen: String(localized: "\(urls.count) items will be deleted immediately. You can't undo this action.")
        }
        return summary + "\n" + names
    }

    /// One formatter for every size on screen: making one per call was the cost of every list row.
    private static let sizeFormatter = OSAllocatedUnfairLock(uncheckedState: {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }())

    static func size(_ bytes: Int64) -> String {
        sizeFormatter.withLock { $0.string(fromByteCount: bytes) }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(size(Int64(bytesPerSecond)))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
