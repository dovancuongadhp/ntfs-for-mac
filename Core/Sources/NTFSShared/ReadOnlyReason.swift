/// Why a volume is mounted without write access.
public enum ReadOnlyReason: String, CaseIterable, Sendable, Equatable {
    /// The user disabled writing for this drive, or the mount asked for read-only.
    case requested
    /// Windows hibernated (or Fast Startup) with this volume in use.
    case hibernated
    /// The NTFS journal holds changes Windows has not finished applying.
    case uncleanJournal
    /// Windows marked the volume for a disk check.
    case dirty
    /// Writing failed with an I/O error, so further writes were stopped.
    case ioError
    /// The disk itself is write-protected.
    case deviceReadOnly

    /// Darwin notification posted by the file system extension when a volume
    /// falls back to read-only for this reason.
    public var notificationName: String {
        Identifiers.readOnlyNotificationPrefix + rawValue
    }

    public init?(notificationName: String) {
        guard notificationName.hasPrefix(Identifiers.readOnlyNotificationPrefix) else { return nil }
        self.init(rawValue: String(notificationName.dropFirst(Identifiers.readOnlyNotificationPrefix.count)))
    }
}
