import DiskArbitration
import Foundation
import Observation

/// Every disk DiskArbitration reports, as physical disks with their partitions.
@MainActor
@Observable
final class DiskInventory {
    private(set) var tree: [PhysicalDisk] = []
    /// NTFS partitions, for the mount logic and the menu bar.
    private(set) var disks: [NTFSDisk] = []

    @ObservationIgnored let session: DASession
    @ObservationIgnored var onDiskChanged: ((NTFSDisk) -> Void)?
    @ObservationIgnored var onDiskRemoved: ((String) -> Void)?
    @ObservationIgnored private var infos: [String: DiskInfo] = [:]
    @ObservationIgnored private var callbacks: [UnsafeMutableRawPointer] = []

    /// Disk images stay hidden, except in debug builds for testing:
    /// `defaults write com.docuong.ntfsformac ShowVirtualDisks -bool YES`.
    static var showsVirtualDisks: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "ShowVirtualDisks")
        #else
        false
        #endif
    }

    var sidebarDisks: [PhysicalDisk] {
        tree.filter { !$0.isVirtual || Self.showsVirtualDisks }
    }

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)

        let appeared: DADiskAppearedCallback = { disk, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).update(disk) }
        }
        let changed: DADiskDescriptionChangedCallback = { disk, _, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).update(disk) }
        }
        let disappeared: DADiskDisappearedCallback = { disk, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).remove(disk) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, appeared, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, changed, context)
        DARegisterDiskDisappearedCallback(session, nil, disappeared, context)
        callbacks = [
            unsafeBitCast(appeared, to: UnsafeMutableRawPointer.self),
            unsafeBitCast(changed, to: UnsafeMutableRawPointer.self),
            unsafeBitCast(disappeared, to: UnsafeMutableRawPointer.self),
        ]
    }

    isolated deinit {
        // Callbacks hold an unretained pointer to self.
        let context = Unmanaged.passUnretained(self).toOpaque()
        for callback in callbacks {
            DAUnregisterCallback(session, callback, context)
        }
        DASessionSetDispatchQueue(session, nil)
    }

    private static func instance(_ context: UnsafeMutableRawPointer?) -> DiskInventory {
        Unmanaged<DiskInventory>.fromOpaque(context!).takeUnretainedValue()
    }

    func disk(named bsdName: String) -> NTFSDisk? {
        disks.first { $0.bsdName == bsdName }
    }

    func physicalDisk(named bsdName: String) -> PhysicalDisk? {
        tree.first { $0.bsdName == bsdName }
    }

    func partition(named bsdName: String) -> (partition: Partition, disk: PhysicalDisk)? {
        for disk in tree {
            if let partition = disk.partitions.first(where: { $0.bsdName == bsdName }) {
                return (partition, disk)
            }
        }
        return nil
    }

    /// Partitions (or volumes) of a whole disk, as DiskArbitration last reported them.
    func childNames(ofWhole bsdName: String) -> [String] {
        infos.values
            .filter { !$0.isWhole && $0.wholeBSDName == bsdName }
            .map(\.bsdName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Reads a disk again now, bypassing the cached tree.
    func freshInfo(_ bsdName: String) -> DiskInfo? {
        DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName).flatMap(DiskInfoReader.read)
    }

    /// Re-reads one disk, e.g. after mounting it.
    func refresh(bsdName: String) {
        if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
            update(disk)
        }
    }

    /// Re-reads free space, which DiskArbitration does not report changes to.
    func refreshUsage() {
        var changed = false
        for (name, info) in infos {
            guard let mount = info.mount,
                  let current = DiskInfoReader.mountInfo(mount.path),
                  current != mount
            else { continue }
            infos[name]?.mount = current
            changed = true
        }
        if changed {
            rebuild()
        }
    }

    /// Physical disks holding macOS itself.
    var systemDiskNames: Set<String> {
        var names = Set(tree.filter { disk in
            disk.partitions.contains {
                $0.mount?.path.path == "/" || !Set($0.apfsRoles).isDisjoint(with: DiskContent.systemRoles)
            }
        }.map(\.bsdName))
        if let boot = DiskInfoReader.mountSource("/"),
           let disk = DiskTreeBuilder.physicalDisk(containing: boot, in: tree) {
            names.insert(disk.bsdName)
        }
        return names
    }

    /// The physical disk NTFS for Mac itself runs from.
    var appDiskName: String? {
        DiskInfoReader.mountSource(Bundle.main.bundlePath)
            .flatMap { DiskTreeBuilder.physicalDisk(containing: $0, in: tree)?.bsdName }
    }

    private func update(_ disk: DADisk) {
        guard let info = DiskInfoReader.read(disk), infos[info.bsdName] != info else { return }
        infos[info.bsdName] = info
        rebuild()
    }

    private func remove(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk),
              infos.removeValue(forKey: String(cString: name)) != nil
        else { return }
        rebuild()
    }

    private func rebuild() {
        let newTree = DiskTreeBuilder.build(Array(infos.values))
        if newTree != tree {
            tree = newTree
        }
        let old = disks
        let newDisks = newTree.flatMap(\.partitions).compactMap(\.ntfsDisk)
            .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        guard newDisks != old else { return }
        disks = newDisks
        for disk in disks where old.first(where: { $0.bsdName == disk.bsdName }) != disk {
            onDiskChanged?(disk)
        }
        for disk in old where !disks.contains(where: { $0.bsdName == disk.bsdName }) {
            onDiskRemoved?(disk.bsdName)
        }
    }
}
