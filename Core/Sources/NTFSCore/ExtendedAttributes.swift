import CNTFS
import Foundation

/// How `setExtendedAttribute` treats an existing attribute.
public enum ExtendedAttributeMode: Sendable {
    case createOrReplace
    /// Fails with `EEXIST` if the attribute exists.
    case create
    /// Fails with `ENOATTR` if the attribute doesn't exist.
    case replace
}

extension NTFSError {
    public static let noAttribute = NTFSError(code: ENOATTR)
}

/// Extended attributes are stored as NTFS alternate data streams of the same
/// name, as ntfs-3g and other macOS NTFS drivers do, so they survive a trip
/// through Windows.
extension NTFSVolumeHandle {
    public func extendedAttributeNames(of id: ItemID) throws(NTFSError) -> [String] {
        final class Collector {
            var names: [String] = []
        }
        let collector = Collector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = nb_xattr_list(try mounted(), id, context) { context, name in
            guard let context, let name else { return 0 }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            collector.names.append(StreamName.attributeName(String(cString: name)))
            return 0
        }
        try check(result)
        return collector.names
    }

    public func extendedAttribute(_ name: String, of id: ItemID) throws(NTFSError) -> Data {
        let volume = try mounted()
        let streamName = StreamName.streamName(name)
        // The stream can change size between the two calls; retry on ERANGE.
        while true {
            let size = nb_xattr_get(volume, id, streamName, nil, 0)
            guard size >= 0 else { throw NTFSError(code: Int32(-size)) }
            var data = Data(count: Int(size))
            let read = data.withUnsafeMutableBytes { buffer in
                nb_xattr_get(volume, id, streamName, buffer.baseAddress, UInt64(buffer.count))
            }
            if read == -Int64(ERANGE) { continue }
            guard read >= 0 else { throw NTFSError(code: Int32(-read)) }
            return data.prefix(Int(read))
        }
    }

    public func setExtendedAttribute(
        _ name: String, to value: Data, of id: ItemID, mode: ExtendedAttributeMode = .createOrReplace
    ) throws(NTFSError) {
        let bridgeMode: nb_xattr_mode = switch mode {
        case .createOrReplace: NB_XATTR_ANY
        case .create: NB_XATTR_CREATE
        case .replace: NB_XATTR_REPLACE
        }
        let volume = try mounted()
        let streamName = StreamName.streamName(name)
        let result = value.withUnsafeBytes { buffer in
            nb_xattr_set(volume, id, streamName, buffer.baseAddress, UInt64(buffer.count), bridgeMode)
        }
        try check(result)
    }

    public func removeExtendedAttribute(_ name: String, of id: ItemID) throws(NTFSError) {
        try check(nb_xattr_remove(try mounted(), id, StreamName.streamName(name)))
    }
}

/// Maps characters Windows forbids in stream names to the private-use range
/// U+F000+char, the Services for Macintosh convention ntfs-3g also uses, so
/// names like "com.apple.metadata:kMDItemWhereFroms" stay valid on Windows.
enum StreamName {
    private static let offset: UInt32 = 0xF000

    static func streamName(_ attributeName: String) -> String {
        String(String.UnicodeScalarView(attributeName.unicodeScalars.map { scalar in
            isForbidden(scalar.value) ? Unicode.Scalar(offset + scalar.value)! : scalar
        }))
    }

    static func attributeName(_ streamName: String) -> String {
        String(String.UnicodeScalarView(streamName.unicodeScalars.map { scalar in
            let value = scalar.value &- offset
            return scalar.value >= offset && isForbidden(value) ? Unicode.Scalar(value)! : scalar
        }))
    }

    private static func isForbidden(_ value: UInt32) -> Bool {
        value < 0x20 || "\"*/:<>?\\|".unicodeScalars.contains { $0.value == value }
    }
}
