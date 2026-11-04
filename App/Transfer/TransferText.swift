import Foundation
import NTFSTransfer

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
            if case .notEnoughSpace(let needed, let available) = problem {
                lines.append(String(localized: "Not enough space on the destination. Needed \(size(needed)), available \(size(available))."))
            }
        }
        let others = problems.filter { $0.jobID != nil }
        for problem in others.prefix(5) {
            switch problem {
            case .invalidName(_, let name):
                lines.append(String(localized: "“\(name)” can't be stored on this drive: the name isn't allowed."))
            case .fileTooLarge(_, let name):
                lines.append(String(localized: "“\(name)” is too large for this drive's file system."))
            case .notEnoughSpace:
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

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(size(Int64(bytesPerSecond)))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
