import Foundation
import NTFSShared

extension ReadOnlyReason {
    /// Short reason shown next to "Read-only" in the menu.
    var shortDescription: String {
        switch self {
        case .requested: String(localized: "writing turned off")
        case .hibernated: String(localized: "Windows is hibernated")
        case .uncleanJournal: String(localized: "not ejected safely")
        case .dirty: String(localized: "disk needs checking")
        case .ioError: String(localized: "write error")
        case .deviceReadOnly: String(localized: "disk is write-protected")
        }
    }

    /// What the user can do about it, shown in notifications.
    var advice: String {
        switch self {
        case .requested:
            String(localized: "Turn on “Allow writing” for this drive to make changes.")
        case .hibernated:
            String(localized: "Windows was hibernated or Fast Startup is on. Start Windows and choose Shut Down while holding Shift, or turn off Fast Startup, then reconnect the drive.")
        case .uncleanJournal:
            String(localized: "This drive wasn't ejected safely, or Windows didn't shut down cleanly. Connect it to Windows and shut down normally, or choose Allow Writing Anyway.")
        case .dirty:
            String(localized: "Windows flagged this drive for a disk check. Run “chkdsk /f” on it in Windows, then reconnect it.")
        case .ioError:
            String(localized: "A write to the drive failed, so writing was stopped to protect your data. Eject the drive and check the cable or the drive itself.")
        case .deviceReadOnly:
            String(localized: "The drive is write-protected. Check its lock switch, if it has one.")
        }
    }
}

extension DiskState {
    var label: String {
        switch self {
        case .readWrite:
            String(localized: "Read & write")
        case .readOnly(let reason?):
            String(localized: "Read-only — \(reason.shortDescription)")
        case .readOnly(nil):
            String(localized: "Read-only")
        case .systemReadOnly:
            String(localized: "Read-only (macOS driver)")
        case .notMounted:
            String(localized: "Not mounted")
        case .unrecognized:
            String(localized: "Not supported — encrypted (BitLocker) or damaged")
        }
    }
}
