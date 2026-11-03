import Foundation
import NTFSProbe
import Testing

@Suite struct BootSectorTests {
    @Test func formattedImageIsNTFS() throws {
        let url = try TestImage.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let sector = try Data(contentsOf: url).prefix(512)
        guard case .ntfs(let serial) = BootSector.classify(sector) else {
            Issue.record("not classified as NTFS")
            return
        }
        #expect(serial == sector.u64(0x48))
    }

    @Test func bitLockerSignature() {
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(3..<11, with: Array("-FVE-FS-".utf8))
        sector[510] = 0x55
        sector[511] = 0xAA
        #expect(BootSector.classify(sector) == .bitLocker)
    }

    @Test func shortOrUnsignedSectorsAreOther() {
        #expect(BootSector.classify([UInt8](repeating: 0, count: 100)) == .other)
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        #expect(BootSector.classify(sector) == .other)
    }
}
