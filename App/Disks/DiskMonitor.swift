import DiskArbitration
import Foundation
import Observation

/// Tracks NTFS partitions as they appear, change (mount/unmount) and disappear.
@MainActor
@Observable
final class DiskMonitor {
    private(set) var disks: [NTFSDisk] = []

    @ObservationIgnored let session: DASession
    @ObservationIgnored var onDiskChanged: ((NTFSDisk) -> Void)?
    @ObservationIgnored var onDiskRemoved: ((String) -> Void)?

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let match = [kDADiskDescriptionMediaLeafKey as String: true] as CFDictionary
        DARegisterDiskAppearedCallback(session, match, { disk, context in
            MainActor.assumeIsolated { DiskMonitor.instance(context).refresh(disk) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, match, nil, { disk, _, context in
            MainActor.assumeIsolated { DiskMonitor.instance(context).refresh(disk) }
        }, context)
        DARegisterDiskDisappearedCallback(session, match, { disk, context in
            MainActor.assumeIsolated { DiskMonitor.instance(context).remove(disk) }
        }, context)
    }

    isolated deinit {
        // Callbacks hold an unretained pointer to self.
        DASessionSetDispatchQueue(session, nil)
    }

    private static func instance(_ context: UnsafeMutableRawPointer?) -> DiskMonitor {
        Unmanaged<DiskMonitor>.fromOpaque(context!).takeUnretainedValue()
    }

    func disk(named bsdName: String) -> NTFSDisk? {
        disks.first { $0.bsdName == bsdName }
    }

    /// Re-reads one disk, e.g. after mounting it.
    func refresh(bsdName: String) {
        if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
            refresh(disk)
        }
    }

    private func refresh(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return }

        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let kind = description[kDADiskDescriptionVolumeKindKey as String] as? String
        guard NTFSDisk.isCandidate(content: content, volumeKind: kind) else {
            remove(bsdName: bsdName)
            return
        }

        let updated = NTFSDisk(
            bsdName: bsdName,
            name: (description[kDADiskDescriptionVolumeNameKey as String] as? String)
                ?? (description[kDADiskDescriptionMediaNameKey as String] as? String)
                ?? bsdName,
            preferenceKey: Self.preferenceKey(description, bsdName: bsdName),
            isRecognized: kind != nil,
            isWritableMedia: description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? true,
            mount: (description[kDADiskDescriptionVolumePathKey as String] as? URL).flatMap(Self.mountInfo)
        )

        if let index = disks.firstIndex(where: { $0.bsdName == bsdName }) {
            guard disks[index] != updated else { return }
            disks[index] = updated
        } else {
            disks.append(updated)
            disks.sort { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        }
        onDiskChanged?(updated)
    }

    private func remove(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk) else { return }
        remove(bsdName: String(cString: name))
    }

    private func remove(bsdName: String) {
        guard let index = disks.firstIndex(where: { $0.bsdName == bsdName }) else { return }
        disks.remove(at: index)
        onDiskRemoved?(bsdName)
    }

    private static func preferenceKey(_ description: [String: Any], bsdName: String) -> String {
        for key in [kDADiskDescriptionMediaUUIDKey, kDADiskDescriptionVolumeUUIDKey] {
            if let value = description[key as String], CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
                let uuid = value as! CFUUID
                return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            }
        }
        let size = description[kDADiskDescriptionMediaSizeKey as String] as? UInt64 ?? 0
        return "\(bsdName)-\(size)"
    }

    private static func mountInfo(_ path: URL) -> NTFSDisk.Mount? {
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
}
