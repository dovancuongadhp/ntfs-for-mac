import Foundation
import Testing
@testable import NTFS_for_Mac

struct FormatSafetyTests {
    private func disk(_ infos: [DiskInfo]) throws -> PhysicalDisk {
        try #require(DiskTreeBuilder.build(infos).first)
    }

    @Test func protectedDisksAreBlocked() throws {
        let usb = try disk(Fixture.usbGPT)
        #expect(FormatSafety.blockReason(for: try disk(Fixture.internalMac), context: FormatContext()) == .internalDisk)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext(systemDisks: ["disk6"])) == .systemDisk)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext(appDisk: "disk6")) == .appDisk)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext(busy: ["disk6s2"])) == .busy)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext(busy: ["disk6"])) == .busy)
        var readOnly = usb
        readOnly.isWritable = false
        #expect(FormatSafety.blockReason(for: readOnly, context: FormatContext()) == .readOnlyMedia)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext()) == nil)
    }

    @Test func busyAPFSContainerBlocksItsDisk() throws {
        let usb = try disk(Fixture.usbAPFS)
        #expect(FormatSafety.blockReason(for: usb, context: FormatContext(busy: ["disk9"])) == .busy)
        #expect(FormatSafety.blockReason(for: .partition("disk9s1"), on: usb, context: FormatContext(busy: ["disk9"])) == .busy)
    }

    @Test func orphanContainersCantBeFormatted() throws {
        let infos = Fixture.orphanContainer.map { info in
            var info = info
            info.isInternal = false
            return info
        }
        let orphan = try disk(infos)
        #expect(orphan.bsdName == "disk4")
        #expect(FormatSafety.blockReason(for: .partition("disk4s1"), on: orphan, context: FormatContext()) == .unsupported)
        #expect(FormatSafety.blockReason(for: .partition("disk4s5"), on: orphan, context: FormatContext()) == .unsupported)
        #expect(FormatSafety.blockReason(for: .disk("disk4"), on: orphan, context: FormatContext()) == .unsupported)
        #expect(FormatSafety.fileSystems(for: .partition("disk4s1"), on: orphan, device: infos[1]).isEmpty)
        #expect(FormatSafety.fileSystems(for: .disk("disk4"), on: orphan, device: infos[0]).isEmpty)
        let preparation = FormatSafety.prepare(
            target: .disk("disk4"), disk: orphan, device: infos[0], children: [], context: FormatContext())
        #expect(preparation.block == .unsupported)
    }

    @Test func superfloppyCanBeFormatted() throws {
        let card = try disk(Fixture.superfloppy)
        #expect(FormatSafety.blockReason(for: .partition("disk10"), on: card, context: FormatContext()) == nil)
        #expect(FormatSafety.blockReason(for: .disk("disk10"), on: card, context: FormatContext()) == nil)
    }

    @Test func targetMustBelongToTheDisk() throws {
        let usb = try disk(Fixture.usbGPT)
        #expect(FormatSafety.blockReason(for: .disk("disk7"), on: usb, context: FormatContext()) == .unsupported)
        #expect(FormatSafety.blockReason(for: .disk("disk6"), on: usb, context: FormatContext()) == nil)
        #expect(FormatSafety.blockReason(for: .partition("disk7s1"), on: usb, context: FormatContext()) == .unsupported)
        let wrongDisk = FormatSafety.prepare(
            target: .disk("disk7"), disk: usb, device: Fixture.mbrFAT[0], children: [], context: FormatContext())
        #expect(wrongDisk.block == .unsupported)
    }

    @Test func preparedDeviceMustBeTheErasedOne() throws {
        let usb = try disk(Fixture.usbGPT)
        let otherPartition = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: Fixture.usbGPT[2], children: [], context: FormatContext())
        #expect(otherPartition.block == .unsupported)
        let wholeForPartition = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: Fixture.usbGPT[0], children: [], context: FormatContext())
        #expect(wholeForPartition.block == .unsupported)
        let partitionForWhole = FormatSafety.prepare(
            target: .disk("disk6"), disk: usb, device: Fixture.usbGPT[3], children: [], context: FormatContext())
        #expect(partitionForWhole.block == .unsupported)

        let apfs = try disk(Fixture.usbAPFS)
        let volume = Fixture.usbAPFS[4]
        let store = Fixture.usbAPFS[1]
        #expect(FormatSafety.prepare(
            target: .partition("disk9s2"), disk: apfs, device: volume, children: [], context: FormatContext()).block == .unsupported)
        #expect(FormatSafety.prepare(
            target: .partition("disk9s2"), disk: apfs, device: store, children: [], context: FormatContext()).block == nil)
    }

    @Test func diskImagesNeedTheDebugSwitch() throws {
        let image = try disk(Fixture.diskImage)
        #expect(FormatSafety.blockReason(for: image, context: FormatContext()) == .virtualDisk)
        #expect(FormatSafety.blockReason(for: image, context: FormatContext(allowsVirtualDisks: true)) == nil)
    }

    @Test func hiddenPartitionsCantBeFormatted() throws {
        let usb = try disk(Fixture.usbGPT)
        #expect(FormatSafety.blockReason(for: .partition("disk6s1"), on: usb, context: FormatContext()) == .unsupported)
        #expect(FormatSafety.blockReason(for: .partition("disk6s3"), on: usb, context: FormatContext()) == nil)
        #expect(FormatSafety.blockReason(for: .partition("disk99s1"), on: usb, context: FormatContext()) == .unsupported)
    }

    @Test func partitionTargetErasesOnlyThatPartition() throws {
        let usb = try disk(Fixture.usbGPT)
        #expect(FormatSafety.device(for: .partition("disk6s3"), on: usb) == "disk6s3")
        #expect(FormatSafety.affected(by: .partition("disk6s3"), on: usb).map(\.bsdName) == ["disk6s3"])
        #expect(FormatSafety.unaffected(by: .partition("disk6s3"), on: usb).map(\.name) == ["SSD-PUBLIC"])
    }

    @Test func apfsVolumeTargetErasesTheWholeContainer() throws {
        let usb = try disk(Fixture.usbAPFS)
        #expect(FormatSafety.device(for: .partition("disk9s2"), on: usb) == "disk8s1")
        let affected = FormatSafety.affected(by: .partition("disk9s2"), on: usb)
        #expect(affected.map(\.name) == ["Photos", "Projects"])
        #expect(FormatSafety.warnings(for: affected).contains(.apfsVolumes(["Photos", "Projects"])))
        // Volumes share the container, so used space isn't added twice.
        #expect(FormatSafety.usedBytes(affected) == 700)
    }

    @Test func diskTargetErasesEverything() throws {
        let usb = try disk(Fixture.usbGPT)
        #expect(FormatSafety.device(for: .disk("disk6"), on: usb) == "disk6")
        #expect(FormatSafety.affected(by: .disk("disk6"), on: usb).map(\.name) == ["SSD-PUBLIC", "New Volume"])
        #expect(FormatSafety.unaffected(by: .disk("disk6"), on: usb).isEmpty)
        #expect(FormatSafety.usedBytes(FormatSafety.affected(by: .disk("disk6"), on: usb)) == 4_000 + 90_000)
    }

    @Test func fileSystemsDependOnTheTarget() throws {
        let gpt = try disk(Fixture.usbGPT)
        let s3 = try #require(Fixture.usbGPT.last)
        #expect(FormatSafety.fileSystems(for: .partition("disk6s3"), on: gpt, device: s3) == [.ntfs, .exfat, .fat32, .apfs])
        #expect(FormatSafety.fileSystems(for: .disk("disk6"), on: gpt, device: Fixture.usbGPT[0]) == [.ntfs, .exfat, .fat32, .apfs])

        let mbr = try disk(Fixture.mbrFAT)
        var s1 = Fixture.mbrFAT[1]
        #expect(FormatSafety.fileSystems(for: .partition("disk7s1"), on: mbr, device: s1) == [.ntfs, .exfat, .fat32])
        s1.partitionID = 5
        #expect(FormatSafety.fileSystems(for: .partition("disk7s1"), on: mbr, device: s1) == [.exfat, .fat32])

        let card = try disk(Fixture.superfloppy)
        #expect(FormatSafety.fileSystems(for: .partition("disk10"), on: card, device: Fixture.superfloppy[0]) == [.exfat, .fat32, .apfs])
    }

    @Test func warnings() throws {
        var infos = Fixture.usbGPT
        infos[3].mount = nil
        infos[2].hasTimeMachineBackup = true
        let usb = try disk(infos)
        let affected = FormatSafety.affected(by: .disk("disk6"), on: usb)
        #expect(FormatSafety.usedBytes(affected) == nil)
        #expect(Set(FormatSafety.warnings(for: affected)) == [.timeMachine, .unknownUsage])
    }

    @Test func preparationForAPartition() throws {
        let usb = try disk(Fixture.usbGPT)
        let device = Fixture.usbGPT[3]
        let preparation = FormatSafety.prepare(target: .partition("disk6s3"), disk: usb, device: device, children: [], context: FormatContext())
        #expect(preparation.displayName == "New Volume")
        #expect(preparation.suggestedName == "New Volume")
        #expect(preparation.fingerprint == DiskFingerprint(info: device, children: []))
        #expect(preparation.block == nil)
        #expect(preparation.usedBytes == 90_000)
    }

    @Test func preparationForADisk() throws {
        let usb = try disk(Fixture.usbGPT)
        let preparation = FormatSafety.prepare(
            target: .disk("disk6"), disk: usb, device: Fixture.usbGPT[0],
            children: ["disk6s1", "disk6s2", "disk6s3"], context: FormatContext())
        #expect(preparation.displayName == "Samsung T7 Shield")
        #expect(preparation.suggestedName == "Untitled")
        #expect(preparation.fingerprint.children == ["disk6s1", "disk6s2", "disk6s3"])
    }

    @Test func fingerprintNoticesAnyChange() {
        let info = Fixture.usbGPT[3]
        let original = DiskFingerprint(info: info, children: [])
        var resized = info
        resized.size += 512
        var moved = info
        moved.offset = 0
        var other = info
        other.mediaUUID = "SOMETHING-ELSE"
        #expect(DiskFingerprint(info: resized, children: []) != original)
        #expect(DiskFingerprint(info: moved, children: []) != original)
        #expect(DiskFingerprint(info: other, children: []) != original)
        #expect(DiskFingerprint(info: info, children: ["disk6s4"]) != original)
    }
}
