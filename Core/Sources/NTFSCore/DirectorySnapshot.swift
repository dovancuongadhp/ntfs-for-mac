/// A directory's entries captured at one point in time, addressed the way
/// FSKit resumes enumeration: by position ("cookie") plus a verifier that
/// changes whenever the snapshot is re-read.
public struct DirectorySnapshot: Sendable {
    public enum Slot: Equatable, Sendable {
        case current
        case parent
        case entry(DirectoryEntry)
    }

    public let entries: [DirectoryEntry]
    public let verifier: UInt64

    public init(entries: [DirectoryEntry], verifier: UInt64) {
        self.entries = entries
        self.verifier = verifier
    }

    /// The slot at `position`. When `includeDots` is set, positions 0 and 1
    /// are `.` and `..` and the entries follow; otherwise entries start at 0.
    public func slot(at position: UInt64, includeDots: Bool) -> Slot? {
        var index = position
        if includeDots {
            switch position {
            case 0: return .current
            case 1: return .parent
            default: index -= 2
            }
        }
        guard index < UInt64(entries.count) else { return nil }
        return .entry(entries[Int(index)])
    }
}
