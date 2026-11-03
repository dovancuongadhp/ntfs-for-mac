import Testing
@testable import NTFS_for_Mac

struct VolumeNameRuleTests {
    @Test func trimsAndKeepsValidNames() {
        #expect(VolumeNameRule.validate("  Ổ dữ liệu ", for: .ntfs) == .success("Ổ dữ liệu"))
        #expect(VolumeNameRule.validate("Photos 2026", for: .apfs) == .success("Photos 2026"))
        #expect(VolumeNameRule.validate("USB 64GB", for: .exfat) == .success("USB 64GB"))
    }

    @Test func fat32IsUppercasedASCIIUpTo11() {
        #expect(VolumeNameRule.validate("kingston", for: .fat32) == .success("KINGSTON"))
        #expect(VolumeNameRule.validate("TWELVE CHARS", for: .fat32) == .failure(.tooLong(11)))
        #expect(VolumeNameRule.validate("Ổ", for: .fat32) == .failure(.notASCII))
        #expect(VolumeNameRule.validate("A.B", for: .fat32) == .failure(.invalidCharacter(".")))
    }

    @Test func lengthLimits() {
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 11), for: .exfat) == .success(String(repeating: "a", count: 11)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 12), for: .exfat) == .failure(.tooLong(11)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 129), for: .ntfs) == .failure(.tooLong(128)))
        #expect(VolumeNameRule.validate(String(repeating: "ổ", count: 100), for: .apfs) == .failure(.tooLong(255)))
    }

    @Test func limitsAreCountedInTheFileSystemsUnits() {
        // Each emoji is two UTF-16 code units.
        #expect(VolumeNameRule.validate(String(repeating: "😀", count: 5), for: .exfat) == .success(String(repeating: "😀", count: 5)))
        #expect(VolumeNameRule.validate(String(repeating: "😀", count: 6), for: .exfat) == .failure(.tooLong(11)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 128), for: .ntfs) == .success(String(repeating: "a", count: 128)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 129), for: .ntfs) == .failure(.tooLong(128)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 255), for: .apfs) == .success(String(repeating: "a", count: 255)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 256), for: .apfs) == .failure(.tooLong(255)))
    }

    @Test func rejectsEmptyAndForbiddenCharacters() {
        #expect(VolumeNameRule.validate("   ", for: .ntfs) == .failure(.empty))
        #expect(VolumeNameRule.validate("a/b", for: .ntfs) == .failure(.invalidCharacter("/")))
        #expect(VolumeNameRule.validate("a:b", for: .apfs) == .failure(.invalidCharacter(":")))
        #expect(VolumeNameRule.validate("a\u{7}b", for: .exfat) == .failure(.invalidCharacter("\u{7}")))
    }
}
