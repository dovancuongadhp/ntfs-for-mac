/// Why `ntfs-format` refused or failed. The raw value is its exit status,
/// which the app reads back through `do shell script`.
public enum FormatToolError: Int32, Error, CaseIterable, Sendable {
    case usage = 64
    case notFound
    case notAPartition
    case internalDisk
    case systemDisk
    case readOnly
    case mounted
    case changed
    case invalidLabel
    case invalidCluster
    case unsupportedPartition
    case badPartitionTable
    case ioError
    case mkntfsFailed

    public var exitCode: Int32 { rawValue }
}

/// What DiskArbitration and IOKit report about the partition right now.
public struct DeviceFacts: Equatable, Sendable {
    public var isWhole: Bool
    public var wholeDevice: String
    public var size: UInt64
    public var offset: UInt64?
    public var blockSize: UInt64
    public var isInternal: Bool
    public var isMounted: Bool
    public var isWritable: Bool
    /// Content of the whole disk, e.g. `GUID_partition_scheme`.
    public var scheme: String?
    public var partitionID: Int?
    /// The whole disk holds the startup volume (directly or as an APFS store).
    public var hostsSystem: Bool

    public init(
        isWhole: Bool = false, wholeDevice: String, size: UInt64, offset: UInt64?, blockSize: UInt64 = 512,
        isInternal: Bool = false, isMounted: Bool = false, isWritable: Bool = true,
        scheme: String?, partitionID: Int?, hostsSystem: Bool = false
    ) {
        self.isWhole = isWhole
        self.wholeDevice = wholeDevice
        self.size = size
        self.offset = offset
        self.blockSize = blockSize
        self.isInternal = isInternal
        self.isMounted = isMounted
        self.isWritable = isWritable
        self.scheme = scheme
        self.partitionID = partitionID
        self.hostsSystem = hostsSystem
    }
}

/// The checks `ntfs-format` runs as root before writing anything.
public enum FormatGuard {
    public static let gptScheme = "GUID_partition_scheme"
    public static let mbrScheme = "FDisk_partition_scheme"
    public static let maxLabelLength = 128

    public static func check(_ request: FormatRequest, facts: DeviceFacts) throws {
        guard request.device.wholeMatch(of: /disk[0-9]+s[0-9]+/) != nil, !facts.isWhole else {
            throw FormatToolError.notAPartition
        }
        guard !facts.isInternal else { throw FormatToolError.internalDisk }
        guard !facts.hostsSystem else { throw FormatToolError.systemDisk }
        guard facts.isWritable else { throw FormatToolError.readOnly }
        guard !facts.isMounted else { throw FormatToolError.mounted }
        guard facts.size == request.size, facts.offset == request.offset,
              facts.blockSize > 0, request.offset % facts.blockSize == 0
        else { throw FormatToolError.changed }

        let label = request.label
        guard !label.isEmpty, label.utf16.count <= maxLabelLength,
              !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw FormatToolError.invalidLabel }

        if let cluster = request.clusterSize {
            guard (512...65536).contains(cluster), cluster & (cluster - 1) == 0, UInt64(cluster) >= facts.blockSize else {
                throw FormatToolError.invalidCluster
            }
        }

        switch facts.scheme {
        case gptScheme?:
            break
        case mbrScheme?:
            // Logical partitions live in extended boot records, which this tool doesn't edit.
            guard let id = facts.partitionID, (1...4).contains(id) else { throw FormatToolError.unsupportedPartition }
        default:
            throw FormatToolError.unsupportedPartition
        }
    }
}
