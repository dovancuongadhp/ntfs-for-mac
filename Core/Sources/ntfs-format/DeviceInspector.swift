import DiskArbitration
import Foundation
import NTFSFormat

/// Gathers `DeviceFacts` from DiskArbitration and IOKit.
enum DeviceInspector {
    static let apfsContainerContent = "EF57347C-0000-11AA-AA11-00306543ECAC"

    static func facts(for device: String) throws -> DeviceFacts {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { throw FormatToolError.notFound }

        let whole = DADiskCopyWholeDisk(disk)
        let wholeName = whole.flatMap { DADiskGetBSDName($0) }.map { String(cString: $0) } ?? device
        let wholeDescription = whole.flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mediaPath = description[kDADiskDescriptionMediaPathKey as String] as? String
        let boot = bootPhysicalDisk(session)

        return DeviceFacts(
            isWhole: description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? true,
            wholeDevice: wholeName,
            size: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
            offset: mediaPath.flatMap { IOMedia.number($0, "Base") },
            blockSize: (description[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
            // Only virtual devices may lack the key; anything else unknown counts as internal.
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                ?? (deviceProtocol != "Virtual Interface"),
            isMounted: description[kDADiskDescriptionVolumePathKey as String] != nil || mountedDevices().contains("/dev/" + device),
            isWritable: description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? false,
            scheme: wholeDescription[kDADiskDescriptionMediaContentKey as String] as? String,
            partitionID: mediaPath.flatMap { IOMedia.number($0, "Partition ID") }.map(Int.init),
            // If the startup disk can't be determined, treat every disk as the startup disk.
            hostsSystem: boot.map { $0 == wholeName } ?? true
        )
    }

    /// The physical whole disk holding `/`, following APFS containers to their store.
    static func bootPhysicalDisk(_ session: DASession) -> String? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let source = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard source.hasPrefix("/dev/") else { return nil }
        return physicalWholeDisk(of: String(source.dropFirst(5)), session)
    }

    private static func physicalWholeDisk(of name: String, _ session: DASession) -> String? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
              let whole = DADiskCopyWholeDisk(disk),
              let wholeName = DADiskGetBSDName(whole).map({ String(cString: $0) }),
              let description = DADiskCopyDescription(whole) as? [String: Any]
        else { return nil }
        if description[kDADiskDescriptionMediaContentKey as String] as? String == apfsContainerContent {
            guard let path = description[kDADiskDescriptionMediaPathKey as String] as? String,
                  let store = IOMedia.parentBSDName(path)
            else { return nil }
            return physicalWholeDisk(of: store, session)
        }
        return wholeName
    }

    private static func mountedDevices() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        return Set((0..<Int(count)).map { index in
            withUnsafeBytes(of: mounts[index].f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        })
    }
}
