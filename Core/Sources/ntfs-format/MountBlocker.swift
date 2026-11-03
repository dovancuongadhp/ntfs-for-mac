import DiskArbitration
import Foundation
import NTFSFormat

/// Refuses every mount of a whole disk and its partitions while `body` runs,
/// so DiskArbitration can't mount a volume that is being formatted or whose
/// partition table is about to be rewritten.
enum MountBlocker {
    static func blocking<T>(_ wholeDevice: String, _ body: () throws -> T) throws -> T {
        guard let session = DASessionCreate(kCFAllocatorDefault), let name = strdup(wholeDevice) else {
            throw FormatToolError.ioError
        }
        let callback: DADiskMountApprovalCallback = refuseMount
        let queue = DispatchQueue(label: "ntfs-format.mount-blocker")
        DASessionSetDispatchQueue(session, queue)
        DARegisterDiskMountApprovalCallback(session, nil, callback, name)
        defer {
            DAUnregisterCallback(session, unsafeBitCast(callback, to: UnsafeMutableRawPointer.self), name)
            DASessionSetDispatchQueue(session, nil)
            // A callback already queued still reads `name`.
            queue.sync {}
            free(name)
        }
        return try body()
    }
}

/// `context` is the whole disk's BSD name as a C string.
private func refuseMount(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) -> Unmanaged<DADissenter>? {
    guard let context, let bsdName = DADiskGetBSDName(disk) else { return nil }
    let wholeDevice = String(cString: context.assumingMemoryBound(to: CChar.self))
    let name = String(cString: bsdName)
    guard name == wholeDevice || name.hasPrefix(wholeDevice + "s") else { return nil }
    // kDAReturnBusy (0xF8DA0002) doesn't fit in a signed DAReturn, so keep its bit pattern.
    let dissenter = DADissenterCreate(
        kCFAllocatorDefault, DAReturn(truncatingIfNeeded: kDAReturnBusy), "NTFS for Mac is formatting this drive" as CFString)
    return Unmanaged.passRetained(dissenter)
}
