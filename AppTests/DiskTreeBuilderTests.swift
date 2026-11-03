import Foundation
import Testing
@testable import NTFS_for_Mac

struct DiskTreeBuilderTests {
    @Test func gptDiskListsVisiblePartitionsInOrder() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.usbGPT).first)
        #expect(disk.name == "Samsung T7 Shield")
        #expect(disk.scheme == .gpt)
        #expect(!disk.isInternal && !disk.isVirtual && disk.isEjectable)
        #expect(disk.partitions.map(\.bsdName) == ["disk6s1", "disk6s2", "disk6s3"])
        #expect(disk.sidebarPartitions.map(\.name) == ["SSD-PUBLIC", "New Volume"])
        #expect(disk.mapPartitions.count == 3)
        #expect(disk.partitions[2].fileSystem == .ntfs)
        #expect(disk.partitions[1].fileSystem == .exfat)
    }

    @Test func onlyNTFSPartitionsBecomeNTFSDisks() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.usbGPT).first)
        #expect(disk.partitions[1].ntfsDisk == nil)
        let ntfs = try #require(disk.partitions[2].ntfsDisk)
        #expect(ntfs.bsdName == "disk6s3")
        #expect(ntfs.name == "New Volume")
        #expect(ntfs.preferenceKey == "UUID-S3")
        #expect(ntfs.isRecognized)
        #expect(ntfs.isMountedByExtension)
    }

    @Test func mbrDisk() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.mbrFAT).first)
        #expect(disk.scheme == .mbr)
        #expect(disk.partitions.map(\.fileSystem) == [.fat])
        #expect(disk.partitions[0].partitionID == 1)
    }

    @Test func apfsVolumesReplaceTheirContainer() throws {
        let disks = DiskTreeBuilder.build(Fixture.usbAPFS)
        #expect(disks.map(\.bsdName) == ["disk8"])
        let disk = try #require(disks.first)
        #expect(disk.sidebarPartitions.map(\.name) == ["Photos", "Projects"])
        #expect(disk.sidebarPartitions.allSatisfy { $0.apfsStore == "disk8s1" })
        let store = try #require(disk.mapPartitions.first)
        #expect(disk.mapPartitions.count == 1)
        #expect(store.bsdName == "disk8s1" && store.isAPFSStore && store.isHidden)
        #expect(store.name == "Photos, Projects")
    }

    @Test func internalDiskHidesSystemHelperVolumes() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.internalMac).first)
        #expect(disk.isInternal)
        #expect(disk.sidebarPartitions.map(\.name) == ["Macintosh HD", "Data"])
    }

    @Test func diskWithoutPartitionTableIsItsOwnPartition() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.superfloppy).first)
        #expect(disk.scheme == .none)
        #expect(disk.partitions.map(\.bsdName) == ["disk10"])
        #expect(disk.sidebarPartitions.map(\.name) == ["CAMERA"])
    }

    @Test func diskImagesAreFlaggedVirtual() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.diskImage).first)
        #expect(disk.isVirtual)
    }

    @Test func findsThePhysicalDiskOfAnyVolume() {
        let tree = DiskTreeBuilder.build(Fixture.internalMac + Fixture.usbGPT)
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk3s1s1", in: tree)?.bsdName == "disk0")
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk6s3", in: tree)?.bsdName == "disk6")
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk6", in: tree)?.bsdName == "disk6")
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk42s1", in: tree) == nil)
    }

    @Test func disksAreSortedNaturally() {
        var two = Fixture.mbrFAT
        two[0].bsdName = "disk10"
        two[0].wholeBSDName = "disk10"
        two[1].wholeBSDName = "disk10"
        let tree = DiskTreeBuilder.build(two + Fixture.usbGPT)
        #expect(tree.map(\.bsdName) == ["disk6", "disk10"])
    }
}
