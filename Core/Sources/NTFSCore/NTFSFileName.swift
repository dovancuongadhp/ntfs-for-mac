import Foundation

/// Turns names macOS allows into names NTFS will store, and back.
///
/// NTFS rejects `" * / : < > ? \ |`, control characters, a trailing space or
/// dot, and the DOS device names (`CON`, `COM1`, …). Finder then fails the
/// whole copy with error -50. Those names are stored with the Services for
/// Macintosh private-use characters (U+F001…), which Windows accepts and
/// which this type turns back into the original characters.
public enum NTFSFileName {
    /// The form written to the volume. `.` and `..` are unchanged.
    public static func forDisk(_ name: String) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        if composed == "." || composed == ".." { return composed }
        var scalars = composed.unicodeScalars.map(diskScalar)
        if let last = scalars.last {
            if last == " " { scalars[scalars.index(before: scalars.endIndex)] = trailingSpace }
            else if last == "." { scalars[scalars.index(before: scalars.endIndex)] = trailingDot }
        }
        if let stem = reservedStemLength(scalars) {
            scalars.insert(reservedMark, at: stem)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The form shown on macOS.
    public static func forMac(_ name: String) -> String {
        if name == "." || name == ".." { return name }
        var scalars = Array(name.unicodeScalars)
        if let mark = scalars.firstIndex(of: reservedMark) {
            var without = scalars
            without.remove(at: mark)
            if reservedStemLength(without) == mark {
                scalars = without
            }
        }
        if let last = scalars.last {
            if last == trailingSpace { scalars[scalars.index(before: scalars.endIndex)] = " " }
            else if last == trailingDot { scalars[scalars.index(before: scalars.endIndex)] = "." }
        }
        return String(String.UnicodeScalarView(scalars.map(macScalar)))
    }

    /// A symlink target, with each path component translated.
    public static func forMacPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { forMac(String($0)) }
            .joined(separator: "/")
    }

    // U+F020…U+F028 are `" * / : < > ? \ |` in that order, matching Apple's
    // Services for Macintosh mapping. Controls use U+F000 plus their code.
    private static let punctuation: [(UInt32, Unicode.Scalar)] = [
        (0x22, Unicode.Scalar(0xF020)!), (0x2A, Unicode.Scalar(0xF021)!),
        (0x2F, Unicode.Scalar(0xF022)!), (0x3A, Unicode.Scalar(0xF023)!),
        (0x3C, Unicode.Scalar(0xF024)!), (0x3E, Unicode.Scalar(0xF025)!),
        (0x3F, Unicode.Scalar(0xF026)!), (0x5C, Unicode.Scalar(0xF027)!),
        (0x7C, Unicode.Scalar(0xF028)!),
    ]
    private static let trailingDot = Unicode.Scalar(0xF029)!
    private static let trailingSpace = Unicode.Scalar(0xF02A)!
    private static let reservedMark = Unicode.Scalar(0xF02B)!

    private static func diskScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if (0x01...0x1F).contains(scalar.value) {
            return Unicode.Scalar(0xF000 + scalar.value)!
        }
        return punctuation.first { $0.0 == scalar.value }?.1 ?? scalar
    }

    private static func macScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if (0xF001...0xF01F).contains(scalar.value) {
            return Unicode.Scalar(scalar.value - 0xF000)!
        }
        if let match = punctuation.first(where: { $0.1 == scalar }) {
            return Unicode.Scalar(match.0)!
        }
        return scalar
    }

    /// Where a DOS device name ends, so a mark can be inserted after it.
    /// `CON` and `CON.txt` match; `CONSOLE` does not. `COM1` and `COM1.txt` match; `COM10` does not.
    private static func reservedStemLength(_ scalars: [Unicode.Scalar]) -> Int? {
        func upper(_ index: Int) -> UInt32? {
            guard scalars.indices.contains(index) else { return nil }
            let value = scalars[index].value
            return (97...122).contains(value) ? value - 32 : value
        }
        func word(_ text: String) -> Bool {
            let expected = text.unicodeScalars.map(\.value)
            for (index, value) in expected.enumerated() where upper(index) != value { return false }
            return true
        }
        let dot: UInt32 = 0x2E
        if word("CON") || word("PRN") || word("AUX") || word("NUL") {
            if scalars.count == 3 || upper(3) == dot { return 3 }
        }
        if (word("COM") || word("LPT")), let fourth = upper(3), (0x31...0x39).contains(fourth) {
            if scalars.count == 4 || upper(4) == dot { return 4 }
        }
        return nil
    }
}
