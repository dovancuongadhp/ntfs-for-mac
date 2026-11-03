import Foundation

/// What the first sector of a partition says it contains.
public enum BootSectorKind: Equatable, Sendable {
    case ntfs(serialNumber: UInt64)
    case bitLocker
    case other
}

public enum BootSector {
    public static let size = 512

    private static let ntfsSignature = Array("NTFS    ".utf8)
    private static let bitLockerSignature = Array("-FVE-FS-".utf8)

    /// Classifies a partition from its first 512 bytes.
    public static func classify(_ sector: some Collection<UInt8>) -> BootSectorKind {
        let bytes = Array(sector.prefix(size))
        guard bytes.count == size, bytes[510] == 0x55, bytes[511] == 0xAA else {
            return .other
        }
        let oemID = Array(bytes[3..<11])
        if oemID == bitLockerSignature {
            return .bitLocker
        }
        guard oemID == ntfsSignature, isPlausibleNTFS(bytes) else {
            return .other
        }
        let serial = bytes[0x48..<0x50].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return .ntfs(serialNumber: serial)
    }

    private static func isPlausibleNTFS(_ bytes: [UInt8]) -> Bool {
        let bytesPerSector = UInt16(bytes[0x0B]) | UInt16(bytes[0x0C]) << 8
        let sectorsPerCluster = bytes[0x0D]
        let validSectorSizes: Set<UInt16> = [256, 512, 1024, 2048, 4096]
        return validSectorSizes.contains(bytesPerSector) && sectorsPerCluster != 0
    }
}
