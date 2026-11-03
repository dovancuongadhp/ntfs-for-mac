import NTFSShared

enum MountAction: Equatable {
    case none
    /// Mount with the NTFS for Mac extension, unmounting any current mount first.
    case mountWithExtension(readOnly: Bool)
}

/// Decides what to do when a disk appears or changes, without user input.
enum MountPolicy {
    /// - Parameter alreadyHandled: an automatic action already ran for this
    ///   appearance of the disk; never act twice, so a failing mount can't loop.
    static func action(for disk: NTFSDisk, writeEnabled: Bool, alreadyHandled: Bool) -> MountAction {
        guard !alreadyHandled, disk.isRecognized else {
            return .none
        }
        if disk.isMountedByExtension {
            let isReadOnly = disk.mount?.isReadOnly ?? false
            if !writeEnabled, !isReadOnly {
                return .mountWithExtension(readOnly: true)
            }
            return .none
        }
        if disk.isMountedBySystemDriver {
            // With writing disabled, macOS's own read-only mount is exactly what the user wants.
            return writeEnabled ? .mountWithExtension(readOnly: false) : .none
        }
        return .mountWithExtension(readOnly: !writeEnabled)
    }
}
