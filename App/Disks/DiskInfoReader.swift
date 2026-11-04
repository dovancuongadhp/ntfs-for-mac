import DiskArbitration
import Foundation
import IOKit
import NTFSFormat

/// Reads a DiskArbitration disk into a `DiskInfo`.
enum DiskInfoReader {
    static func read(_ disk: DADisk) -> DiskInfo? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return nil }

        let wholeName = DADiskCopyWholeDisk(disk).flatMap { whole in
            DADiskGetBSDName(whole).map { String(cString: $0) }
        } ?? bsdName
        let isWhole = description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mediaPath = description[kDADiskDescriptionMediaPathKey as String] as? String
        let mount = (description[kDADiskDescriptionVolumePathKey as String] as? URL).flatMap(mountInfo)
        let roles = mediaPath.map { IOMedia.strings($0, "Role") } ?? []
        let isContainer = isWhole && content == DiskContent.apfsContainer

        return DiskInfo(
            bsdName: bsdName,
            wholeBSDName: wholeName,
            isWhole: isWhole,
            isLeaf: description[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false,
            size: number(description[kDADiskDescriptionMediaSizeKey as String]) ?? 0,
            blockSize: number(description[kDADiskDescriptionMediaBlockSizeKey as String]) ?? 512,
            offset: mediaPath.flatMap { IOMedia.number($0, "Base") },
            partitionID: mediaPath.flatMap { IOMedia.number($0, "Partition ID") }.map(Int.init),
            content: content,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String,
            mediaUUID: uuidString(description[kDADiskDescriptionMediaUUIDKey as String]),
            volumeKind: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            volumeName: description[kDADiskDescriptionVolumeNameKey as String] as? String,
            volumeUUID: uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]),
            mount: mount,
            isWritable: description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? true,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false,
            // Only virtual devices may lack the key; anything else unknown counts as internal.
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                ?? (deviceProtocol != DiskContent.virtualProtocol),
            deviceProtocol: deviceProtocol,
            deviceModel: (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces),
            physicalStore: isContainer ? containerParent(bsdName, path: mediaPath) : nil,
            physicalStores: isContainer ? containerAncestors(bsdName, path: mediaPath) : [],
            registryID: registryID(of: disk),
            apfsRoles: roles,
            hasTimeMachineBackup: mount.map {
                FileManager.default.fileExists(atPath: $0.path.appending(path: "Backups.backupdb").path)
            } ?? false
        )
    }

    /// The registry path fails when a node name contains a space, so fall back to the BSD name.
    private static func containerParent(_ bsdName: String, path: String?) -> String? {
        if let path, let name = IOMedia.parentBSDName(path) { return name }
        return IOMedia.parentBSDName(bsdName: bsdName)
    }

    private static func containerAncestors(_ bsdName: String, path: String?) -> [String] {
        if let path {
            let names = IOMedia.ancestorBSDNames(path)
            if !names.isEmpty { return names }
        }
        return IOMedia.ancestorBSDNames(bsdName: bsdName)
    }

    static func mountInfo(_ path: URL) -> NTFSDisk.Mount? {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return nil }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let blockSize = UInt64(info.f_bsize)
        return NTFSDisk.Mount(
            path: path,
            fileSystemType: type,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            totalBytes: info.f_blocks * blockSize,
            freeBytes: info.f_bavail * blockSize
        )
    }

    /// The `/dev` node a path is mounted from, without `/dev/`.
    static func mountSource(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let source = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : nil
    }

    /// Only valid while `disk` is alive.
    private static func registryID(of disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    private static func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String
    }
}
