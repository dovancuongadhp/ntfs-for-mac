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
        #expect(disk.partitions[0].name == "EFI" && disk.partitions[0].isHidden)
    }

    @Test func driveNameKeepsTheMakerAndDropsTheMediaSuffix() {
        #expect(DiskTreeBuilder.driveName(mediaName: "Lexar E6 Media", model: "E6") == "Lexar E6")
        #expect(DiskTreeBuilder.driveName(mediaName: "USB SanDisk 3.2Gen1 Media", model: " SanDisk 3.2Gen1") == "USB SanDisk 3.2Gen1")
        #expect(DiskTreeBuilder.driveName(mediaName: nil, model: "E6") == "E6")
        #expect(DiskTreeBuilder.driveName(mediaName: "Mediabox", model: nil) == "Mediabox")
        #expect(DiskTreeBuilder.driveName(mediaName: nil, model: nil) == nil)
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

    @Test func apfsVolumeOnASharedDiskStaysUnderThatDisk() throws {
        var infos = Fixture.usbGPT
        infos.append(DiskInfo(
            bsdName: "disk6s4", wholeBSDName: "disk6", isLeaf: false, size: 50_000_000_000, offset: 512_000_000_000,
            partitionID: 4, content: DiskContent.apfsStore, mediaName: "Untitled 4", deviceProtocol: "USB"))
        infos.append(DiskInfo(
            bsdName: "disk12", wholeBSDName: "disk12", isWhole: true, isLeaf: false, size: 50_000_000_000,
            content: DiskContent.apfsContainer, mediaName: "T7 Media", deviceProtocol: "USB",
            physicalStore: "disk6s4", physicalStores: ["disk6s4"]))
        infos.append(DiskInfo(
            bsdName: "disk12s1", wholeBSDName: "disk12", size: 50_000_000_000, volumeKind: "apfs",
            volumeName: "SSD-MACOS", deviceProtocol: "USB"))
        let tree = DiskTreeBuilder.build(infos)
        #expect(tree.map(\.bsdName) == ["disk6"])
        #expect(tree[0].sidebarPartitions.map(\.name) == ["SSD-PUBLIC", "New Volume", "SSD-MACOS"])
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

    @Test func ejectingUnmountsTheAPFSContainerThatLivesOnTheDisk() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.usbAPFS).first)
        #expect(AppModel.apfsContainers(on: disk).count == 1)
        #expect(AppModel.apfsContainers(on: disk) != [disk.bsdName])
        let plain = try #require(DiskTreeBuilder.build(Fixture.usbGPT).first)
        #expect(AppModel.apfsContainers(on: plain).isEmpty)
    }

    @Test func storeOfOnlyHiddenVolumesKeepsItsOwnName() throws {
        var infos = Fixture.usbAPFS
        infos[3].apfsRoles = ["Preboot"]
        infos[4].apfsRoles = ["Recovery"]
        let disk = try #require(DiskTreeBuilder.build(infos).first)
        #expect(disk.sidebarPartitions.isEmpty)
        #expect(disk.mapPartitions.map(\.name) == ["disk8s1"])
    }

    @Test func internalDiskHidesSystemHelperVolumes() throws {
        let disk = try #require(DiskTreeBuilder.build(Fixture.internalMac).first)
        #expect(disk.isInternal)
        #expect(disk.sidebarPartitions.map(\.name) == ["Macintosh HD", "Data"])
        let system = try #require(disk.partitions.first { $0.bsdName == "disk3s1" })
        #expect(system.mount?.path.path == "/")
        let store = try #require(disk.partitions.first { $0.bsdName == "disk0s2" })
        #expect(store.isHidden)
        let preboot = try #require(disk.partitions.first { $0.bsdName == "disk3s2" })
        #expect(preboot.isHidden)
    }

    @Test func snapshotDevicesAreLeftOut() throws {
        let tree = DiskTreeBuilder.build(Fixture.internalMac)
        #expect(tree.map(\.bsdName) == ["disk0"])
        #expect(!tree.flatMap(\.partitions).contains { $0.bsdName == "disk3s1s1" })
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk3s1s1", in: tree)?.bsdName == "disk0")
    }

    @Test func containerWithoutKnownStoreIsItsOwnDisk() throws {
        let tree = DiskTreeBuilder.build(Fixture.orphanContainer + Fixture.usbGPT)
        #expect(tree.map(\.bsdName) == ["disk4", "disk6"])
        let disk = try #require(tree.first)
        #expect(disk.isInternal && !disk.isEjectable)
        #expect(disk.connection == "Apple Fabric")
        #expect(disk.partitions.map(\.bsdName) == ["disk4s1", "disk4s2", "disk4s5"])
        #expect(disk.sidebarPartitions.map(\.name) == ["Macintosh HD", "Data"])
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk4s1", in: tree)?.bsdName == "disk4")
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk4", in: tree)?.bsdName == "disk4")
    }

    @Test func containerWithUnmatchedStoreIsItsOwnDisk() {
        var infos = Fixture.orphanContainer
        infos[0].physicalStore = "disk99s2"
        let tree = DiskTreeBuilder.build(infos)
        #expect(tree.map(\.bsdName) == ["disk4"])
        #expect(tree.first?.partitions.count == 3)
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
        #expect(DiskTreeBuilder.physicalDisk(containing: "disk3", in: tree)?.bsdName == "disk0")
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

struct DriveKindTests {
    @Test func mediumTypeDecidesSSDAndHDD() {
        #expect(DriveKind.classify(mediumType: "Solid State", interconnect: "USB", isRemovable: false) == .ssd)
        #expect(DriveKind.classify(mediumType: "Solid State", interconnect: "Apple Fabric", isRemovable: false) == .ssd)
        #expect(DriveKind.classify(mediumType: "Rotational", interconnect: "USB", isRemovable: false) == .hdd)
    }

    @Test func secureDigitalIsAnSDCardEvenWithoutAMediumType() {
        #expect(DriveKind.classify(mediumType: nil, interconnect: "Secure Digital", isRemovable: true) == .sdCard)
        #expect(DriveKind.classify(mediumType: "Solid State", interconnect: "Secure Digital", isRemovable: true) == .sdCard)
    }

    @Test func removableUSBWithNoMediumTypeIsAFlashDrive() {
        #expect(DriveKind.classify(mediumType: nil, interconnect: "USB", isRemovable: true) == .usbFlash)
    }

    @Test func anEnclosureThatReportsNothingIsNotGuessed() {
        #expect(DriveKind.classify(mediumType: nil, interconnect: "USB", isRemovable: false) == .unknown)
        #expect(DriveKind.classify(mediumType: nil, interconnect: nil, isRemovable: false) == .unknown)
        #expect(DriveKind.unknown.label == nil)
    }
}
