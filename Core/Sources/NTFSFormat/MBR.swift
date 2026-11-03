/// The classic Master Boot Record partition table in a disk's first block.
public enum MBR {
    public static let ntfsType: UInt8 = 0x07

    /// Checks that primary entry `index` (1–4) spans exactly `start`/`size`
    /// bytes, and returns the byte offset of its type field.
    public static func typeFieldOffset(in sector: [UInt8], index: Int, start: UInt64, size: UInt64, blockSize: UInt64) throws -> Int {
        guard sector.count >= 512, sector[510] == 0x55, sector[511] == 0xAA,
              (1...4).contains(index), blockSize > 0
        else { throw FormatToolError.badPartitionTable }
        let entry = 446 + 16 * (index - 1)
        let firstBlock = UInt64(littleEndian32(sector, at: entry + 8))
        let blockCount = UInt64(littleEndian32(sector, at: entry + 12))
        guard firstBlock * blockSize == start, blockCount * blockSize == size else {
            throw FormatToolError.badPartitionTable
        }
        return entry + 4
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
