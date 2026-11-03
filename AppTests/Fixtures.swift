import Foundation
@testable import NTFS_for_Mac

enum Fixture {
    static func mount(_ path: String, total: UInt64 = 1000, free: UInt64 = 400, type: String = "exfat") -> NTFSDisk.Mount {
        NTFSDisk.Mount(path: URL(fileURLWithPath: path), fileSystemType: type, isReadOnly: false, totalBytes: total, freeBytes: free)
    }

    /// What `DiskFingerprint.read` takes of `device` when DiskArbitration reports `infos`.
    static func fingerprint(_ device: DiskInfo, in infos: [DiskInfo]) -> DiskFingerprint {
        let whole = infos.first { $0.isWhole && $0.bsdName == device.wholeBSDName }
        let children = device.isWhole ? infos.filter { !$0.isWhole && $0.wholeBSDName == device.bsdName } : []
        return DiskFingerprint(info: device, whole: whole, children: children)
    }

    /// USB SSD: EFI, an exFAT partition and an NTFS partition.
    static var usbGPT: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk6", wholeBSDName: "disk6", isWhole: true, isLeaf: false, size: 512_110_190_592,
                     content: "GUID_partition_scheme", mediaName: "T7 Media", isEjectable: true,
                     deviceProtocol: "USB", deviceModel: "Samsung T7 Shield"),
            DiskInfo(bsdName: "disk6s1", wholeBSDName: "disk6", size: 209_715_200, offset: 20_480, partitionID: 1,
                     content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", mediaName: "EFI System Partition",
                     volumeKind: "msdos", volumeName: "EFI", isEjectable: true, deviceProtocol: "USB"),
            DiskInfo(bsdName: "disk6s2", wholeBSDName: "disk6", size: 100_400_000_000, offset: 209_735_680, partitionID: 2,
                     content: DiskContent.microsoftBasicData, mediaUUID: "UUID-S2", volumeKind: "exfat",
                     volumeName: "SSD-PUBLIC", mount: mount("/Volumes/SSD-PUBLIC", total: 100_000, free: 96_000),
                     isEjectable: true, deviceProtocol: "USB"),
            DiskInfo(bsdName: "disk6s3", wholeBSDName: "disk6", size: 411_600_000_000, offset: 100_609_735_680, partitionID: 3,
                     content: DiskContent.microsoftBasicData, mediaUUID: "UUID-S3", volumeKind: "ntfsrw",
                     volumeName: "New Volume", mount: mount("/Volumes/New Volume", total: 400_000, free: 310_000, type: "ntfsrw"),
                     isEjectable: true, deviceProtocol: "USB"),
        ]
    }

    /// USB stick with an MBR and one FAT32 partition.
    static var mbrFAT: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk7", wholeBSDName: "disk7", isWhole: true, isLeaf: false, size: 209_715_200,
                     content: "FDisk_partition_scheme", mediaName: "Kingston Media", isEjectable: true,
                     deviceProtocol: "USB", deviceModel: "DataTraveler"),
            DiskInfo(bsdName: "disk7s1", wholeBSDName: "disk7", size: 209_714_688, offset: 512, partitionID: 1,
                     content: "DOS_FAT_32", mediaName: "Untitled 1", volumeKind: "msdos", volumeName: "KINGSTON",
                     mount: mount("/Volumes/KINGSTON"), isEjectable: true, deviceProtocol: "USB"),
        ]
    }

    /// USB drive holding one APFS container with two volumes.
    static var usbAPFS: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk8", wholeBSDName: "disk8", isWhole: true, isLeaf: false, size: 209_715_200,
                     content: "GUID_partition_scheme", isEjectable: true, deviceProtocol: "USB", deviceModel: "Portable SSD"),
            DiskInfo(bsdName: "disk8s1", wholeBSDName: "disk8", isLeaf: false, size: 209_674_240, offset: 20_480, partitionID: 1,
                     content: DiskContent.apfsStore, mediaUUID: "UUID-STORE", isEjectable: true, deviceProtocol: "USB"),
            DiskInfo(bsdName: "disk9", wholeBSDName: "disk9", isWhole: true, isLeaf: false, size: 209_674_240, blockSize: 4096,
                     content: DiskContent.apfsContainer, mediaName: "AppleAPFSMedia", isEjectable: true,
                     deviceProtocol: "USB", physicalStore: "disk8s1"),
            DiskInfo(bsdName: "disk9s1", wholeBSDName: "disk9", size: 209_674_240, blockSize: 4096,
                     content: "41504653-0000-11AA-AA11-00306543ECAC", mediaUUID: "UUID-V1", volumeKind: "apfs",
                     volumeName: "Photos", mount: mount("/Volumes/Photos", total: 1000, free: 300, type: "apfs"),
                     isEjectable: true, deviceProtocol: "USB"),
            DiskInfo(bsdName: "disk9s2", wholeBSDName: "disk9", size: 209_674_240, blockSize: 4096,
                     content: "41504653-0000-11AA-AA11-00306543ECAC", mediaUUID: "UUID-V2", volumeKind: "apfs",
                     volumeName: "Projects", mount: mount("/Volumes/Projects", total: 1000, free: 300, type: "apfs"),
                     isEjectable: true, deviceProtocol: "USB"),
        ]
    }

    /// The Mac's internal SSD with the macOS container.
    static var internalMac: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk0", wholeBSDName: "disk0", isWhole: true, isLeaf: false, size: 1_000_000_000_000,
                     content: "GUID_partition_scheme", isInternal: true, deviceProtocol: "Apple Fabric", deviceModel: "APPLE SSD AP1024Z"),
            DiskInfo(bsdName: "disk0s2", wholeBSDName: "disk0", isLeaf: false, size: 994_000_000_000, offset: 524_288_000,
                     partitionID: 2, content: DiskContent.apfsStore, isInternal: true, deviceProtocol: "Apple Fabric"),
            DiskInfo(bsdName: "disk3", wholeBSDName: "disk3", isWhole: true, isLeaf: false, size: 994_000_000_000,
                     content: DiskContent.apfsContainer, isInternal: true, deviceProtocol: "Apple Fabric", physicalStore: "disk0s2"),
            DiskInfo(bsdName: "disk3s1", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
                     volumeName: "Macintosh HD", isInternal: true, deviceProtocol: "Apple Fabric", apfsRoles: ["System"]),
            DiskInfo(bsdName: "disk3s1s1", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
                     volumeName: "Macintosh HD", mount: mount("/", type: "apfs"), isInternal: true,
                     deviceProtocol: "Apple Fabric"),
            DiskInfo(bsdName: "disk3s2", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
                     volumeName: "Preboot", isInternal: true, deviceProtocol: "Apple Fabric", apfsRoles: ["Preboot"]),
            DiskInfo(bsdName: "disk3s5", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
                     volumeName: "Data", mount: mount("/System/Volumes/Data", type: "apfs"), isInternal: true,
                     deviceProtocol: "Apple Fabric", apfsRoles: ["Data"]),
        ]
    }

    /// An APFS container whose physical store DiskArbitration doesn't report.
    static var orphanContainer: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk4", wholeBSDName: "disk4", isWhole: true, isLeaf: false, size: 500_000_000_000,
                     blockSize: 4096, content: DiskContent.apfsContainer, isInternal: true, deviceProtocol: "Apple Fabric"),
            DiskInfo(bsdName: "disk4s1", wholeBSDName: "disk4", size: 500_000_000_000, blockSize: 4096, volumeKind: "apfs",
                     volumeName: "Macintosh HD", isInternal: true, deviceProtocol: "Apple Fabric", apfsRoles: ["System"]),
            DiskInfo(bsdName: "disk4s2", wholeBSDName: "disk4", size: 500_000_000_000, blockSize: 4096, volumeKind: "apfs",
                     volumeName: "Preboot", isInternal: true, deviceProtocol: "Apple Fabric", apfsRoles: ["Preboot"]),
            DiskInfo(bsdName: "disk4s5", wholeBSDName: "disk4", size: 500_000_000_000, blockSize: 4096, volumeKind: "apfs",
                     volumeName: "Data", mount: mount("/System/Volumes/Data", type: "apfs"), isInternal: true,
                     deviceProtocol: "Apple Fabric", apfsRoles: ["Data"]),
        ]
    }

    /// A camera card formatted without a partition table.
    static var superfloppy: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk10", wholeBSDName: "disk10", isWhole: true, isLeaf: true, size: 32_000_000_000,
                     content: "DOS_FAT_32", mediaUUID: "UUID-CARD", volumeKind: "msdos", volumeName: "CAMERA",
                     mount: mount("/Volumes/CAMERA"), isEjectable: true, deviceProtocol: "Secure Digital", deviceModel: "SD Card Reader"),
        ]
    }

    static var diskImage: [DiskInfo] {
        [
            DiskInfo(bsdName: "disk11", wholeBSDName: "disk11", isWhole: true, isLeaf: false, size: 209_715_200,
                     content: "GUID_partition_scheme", mediaName: "Apple read/write Media", isEjectable: true,
                     deviceProtocol: DiskContent.virtualProtocol, deviceModel: "Disk Image"),
            DiskInfo(bsdName: "disk11s1", wholeBSDName: "disk11", size: 207_618_048, offset: 1_048_576, partitionID: 1,
                     content: DiskContent.microsoftBasicData, volumeKind: "exfat", volumeName: "GPTX",
                     isEjectable: true, deviceProtocol: DiskContent.virtualProtocol),
        ]
    }
}
