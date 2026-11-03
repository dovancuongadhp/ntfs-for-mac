import Foundation
import NTFSFormat
import Testing
@testable import NTFS_for_Mac

struct FormatPlannerTests {
    private func preparation(_ target: FormatTarget, _ infos: [DiskInfo], device: DiskInfo) throws -> FormatPreparation {
        let disk = try #require(DiskTreeBuilder.build(infos).first)
        return FormatSafety.prepare(target: target, disk: disk, device: device, fingerprint: Fixture.fingerprint(device, in: infos), context: FormatContext())
    }

    @Test func partitionToExFAT() throws {
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk6s3"), Fixture.usbGPT, device: Fixture.usbGPT[3]),
            options: FormatOptions(name: "Data", fileSystem: .exfat))
        #expect(job.steps == [
            .unmount("disk6s3", whole: false),
            .diskutil(["eraseVolume", "ExFAT", "Data", "disk6s3"]),
        ])
    }

    @Test func partitionToNTFS() throws {
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk6s3"), Fixture.usbGPT, device: Fixture.usbGPT[3]),
            options: FormatOptions(name: "It's \"mine\"", fileSystem: .ntfs, clusterSize: 8192, quick: false))
        #expect(job.steps == [
            .unmount("disk6s3", whole: false),
            .ntfsFormat(FormatRequest(device: "disk6s3", size: 411_600_000_000, offset: 100_609_735_680,
                                      label: "It's \"mine\"", clusterSize: 8192, quick: false)),
        ])
    }

    @Test func basicDataPartitionIsFormattedInPlace() throws {
        var infos = Fixture.usbGPT
        infos[3].content = DiskContent.microsoftBasicData.lowercased()
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk6s3"), infos, device: infos[3]),
            options: FormatOptions(name: "Data", fileSystem: .ntfs))
        #expect(job.steps == [
            .unmount("disk6s3", whole: false),
            .ntfsFormat(FormatRequest(device: "disk6s3", size: 411_600_000_000, offset: 100_609_735_680,
                                      label: "Data", clusterSize: nil, quick: true)),
        ])
    }

    @Test func hfsPartitionIsRetypedBeforeNTFS() throws {
        var infos = Fixture.usbGPT
        infos[3].content = "48465300-0000-11AA-AA11-00306543ECAC"
        infos[3].volumeKind = "hfs"
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk6s3"), infos, device: infos[3]),
            options: FormatOptions(name: "Windows", fileSystem: .ntfs))
        #expect(job.steps == [
            .unmount("disk6s3", whole: false),
            .diskutil(["eraseVolume", "ExFAT", "NTFS", "disk6s3"]),
            .unmountErased("disk6s3"),
            .ntfsFormat(FormatRequest(device: "disk6s3", size: 411_600_000_000, offset: 100_609_735_680,
                                      label: "Windows", clusterSize: nil, quick: true)),
        ])
    }

    @Test func apfsVolumeToNTFSRetypesItsStore() throws {
        let store = Fixture.usbAPFS[1]
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk9s1"), Fixture.usbAPFS, device: store),
            options: FormatOptions(name: "Windows", fileSystem: .ntfs, clusterSize: 4096))
        #expect(job.steps == [
            .unmount("disk9s1", whole: false),
            .unmount("disk9s2", whole: false),
            .diskutil(["apfs", "deleteContainer", "disk8s1", "NFMTEMP"]),
            .diskutil(["eraseVolume", "ExFAT", "NTFS", "disk8s1"]),
            .unmountErased("disk8s1"),
            .ntfsFormat(FormatRequest(device: "disk8s1", size: store.size, offset: store.offset!,
                                      label: "Windows", clusterSize: 4096, quick: true)),
        ])
    }

    @Test func mbrPartitionIsNotRetypedByDiskutil() throws {
        let partition = Fixture.mbrFAT[1]
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk7s1"), Fixture.mbrFAT, device: partition),
            options: FormatOptions(name: "Windows", fileSystem: .ntfs))
        #expect(job.steps == [
            .unmount("disk7s1", whole: false),
            .ntfsFormat(FormatRequest(device: "disk7s1", size: partition.size, offset: partition.offset!,
                                      label: "Windows", clusterSize: nil, quick: true)),
        ])
    }

    @Test func unmountedPartitionsAreNotUnmounted() throws {
        var infos = Fixture.usbGPT
        infos[3].mount = nil
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk6s3"), infos, device: infos[3]),
            options: FormatOptions(name: "Data", fileSystem: .fat32))
        #expect(job.steps == [.diskutil(["eraseVolume", "MS-DOS FAT32", "Data", "disk6s3"])])
    }

    @Test func apfsVolumeErasesItsStore() throws {
        let job = FormatPlanner.job(
            for: try preparation(.partition("disk9s1"), Fixture.usbAPFS, device: Fixture.usbAPFS[1]),
            options: FormatOptions(name: "Backup", fileSystem: .exfat))
        #expect(job.steps == [
            .unmount("disk9s1", whole: false),
            .unmount("disk9s2", whole: false),
            .diskutil(["apfs", "deleteContainer", "disk8s1", "NFMTEMP"]),
            .diskutil(["eraseVolume", "ExFAT", "Backup", "disk8s1"]),
        ])
    }

    @Test func wholeDiskFormats() throws {
        let prepared = try preparation(.disk("disk6"), Fixture.usbGPT, device: Fixture.usbGPT[0])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "STICK", fileSystem: .fat32, scheme: .mbr)).steps == [
            .unmount("disk6", whole: true),
            .diskutil(["eraseDisk", "MS-DOS FAT32", "STICK", "MBR", "disk6"]),
        ])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "Mac", fileSystem: .apfs, scheme: .mbr)).steps == [
            .unmount("disk6", whole: true),
            .diskutil(["eraseDisk", "APFS", "Mac", "GPT", "disk6"]),
        ])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "Windows Data", fileSystem: .ntfs)).steps == [
            .unmount("disk6", whole: true),
            .diskutil(["eraseDisk", "ExFAT", "NTFS", "GPT", "disk6"]),
            .ntfsFormatNewPartition(whole: "disk6", label: "Windows Data", clusterSize: nil, quick: true),
        ])
    }

    @Test func superfloppyFormats() throws {
        let card = Fixture.superfloppy
        let prepared = try preparation(.partition("disk10"), card, device: card[0])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "CARD", fileSystem: .exfat)).steps == [
            .unmount("disk10", whole: false),
            .diskutil(["eraseVolume", "ExFAT", "CARD", "disk10"]),
        ])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "CARD", fileSystem: .fat32)).steps == [
            .unmount("disk10", whole: false),
            .diskutil(["eraseVolume", "MS-DOS FAT32", "CARD", "disk10"]),
        ])
        #expect(FormatPlanner.job(for: prepared, options: FormatOptions(name: "Mac", fileSystem: .apfs)).steps == [
            .unmount("disk10", whole: true),
            .diskutil(["eraseDisk", "APFS", "Mac", "GPT", "disk10"]),
        ])

        var unmounted = card
        unmounted[0].mount = nil
        let preparedUnmounted = try preparation(.partition("disk10"), unmounted, device: unmounted[0])
        #expect(FormatPlanner.job(for: preparedUnmounted, options: FormatOptions(name: "Mac", fileSystem: .apfs)).steps == [
            .diskutil(["eraseDisk", "APFS", "Mac", "GPT", "disk10"]),
        ])
    }
}
