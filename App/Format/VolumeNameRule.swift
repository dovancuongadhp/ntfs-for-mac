import Foundation

enum VolumeNameError: Error, Equatable {
    case empty
    case tooLong(Int)
    case invalidCharacter(Character)
    case notASCII
}

/// Volume name limits of each file system.
enum VolumeNameRule {
    static let windowsForbidden: Set<Character> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"]
    static let fatForbidden = windowsForbidden.union(["+", ",", ".", ";", "=", "[", "]"])

    /// Returns the name as it will be written (FAT32 upper-cases it).
    static func validate(_ raw: String, for fileSystem: FormatFileSystem) -> Result<String, VolumeNameError> {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(.empty) }
        if let bad = name.first(where: { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) {
            return .failure(.invalidCharacter(bad))
        }
        switch fileSystem {
        case .fat32:
            let upper = name.uppercased()
            guard upper.allSatisfy(\.isASCII) else { return .failure(.notASCII) }
            return check(upper, forbidden: fatForbidden, max: 11) { $0.count }
        case .exfat:
            return check(name, forbidden: windowsForbidden, max: 11) { $0.utf16.count }
        case .ntfs:
            return check(name, forbidden: windowsForbidden, max: 128) { $0.utf16.count }
        case .apfs:
            return check(name, forbidden: [":"], max: 255) { $0.utf8.count }
        }
    }

    private static func check(
        _ name: String, forbidden: Set<Character>, max: Int, length: (String) -> Int
    ) -> Result<String, VolumeNameError> {
        if let bad = name.first(where: forbidden.contains) {
            return .failure(.invalidCharacter(bad))
        }
        guard length(name) <= max else { return .failure(.tooLong(max)) }
        return .success(name)
    }
}
