import Foundation

extension UUID {
    /// A stable UUID for an NTFS volume, derived from its 64-bit serial number
    /// so the same drive gets the same identity on every mount.
    public init(ntfsSerialNumber serial: UInt64) {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: serial.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        bytes.replaceSubrange(8..<16, with: Array("NTFS4MAC".utf8))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8: custom
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 9562 variant
        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
