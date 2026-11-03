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
            target: .disk("disk4"), disk: orphan, device: infos[0], fingerprint: Fixture.fingerprint(infos[0], in: infos), context: FormatContext())
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
            target: .disk("disk7"), disk: usb, device: Fixture.mbrFAT[0], fingerprint: Fixture.fingerprint(Fixture.mbrFAT[0], in: Fixture.mbrFAT), context: FormatContext())
        #expect(wrongDisk.block == .unsupported)
    }

    @Test func preparedDeviceMustBeTheErasedOne() throws {
        let usb = try disk(Fixture.usbGPT)
        let otherPartition = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: Fixture.usbGPT[2], fingerprint: Fixture.fingerprint(Fixture.usbGPT[2], in: Fixture.usbGPT), context: FormatContext())
        #expect(otherPartition.block == .unsupported)
        let wholeForPartition = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: Fixture.usbGPT[0], fingerprint: Fixture.fingerprint(Fixture.usbGPT[0], in: Fixture.usbGPT), context: FormatContext())
        #expect(wholeForPartition.block == .unsupported)
        let partitionForWhole = FormatSafety.prepare(
            target: .disk("disk6"), disk: usb, device: Fixture.usbGPT[3], fingerprint: Fixture.fingerprint(Fixture.usbGPT[3], in: Fixture.usbGPT), context: FormatContext())
        #expect(partitionForWhole.block == .unsupported)

        let apfs = try disk(Fixture.usbAPFS)
        let volume = Fixture.usbAPFS[4]
        let store = Fixture.usbAPFS[1]
        #expect(FormatSafety.prepare(
            target: .partition("disk9s2"), disk: apfs, device: volume, fingerprint: Fixture.fingerprint(volume, in: Fixture.usbAPFS), context: FormatContext()).block == .unsupported)
        #expect(FormatSafety.prepare(
            target: .partition("disk9s2"), disk: apfs, device: store, fingerprint: Fixture.fingerprint(store, in: Fixture.usbAPFS), context: FormatContext()).block == nil)
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
        let fingerprint = Fixture.fingerprint(device, in: Fixture.usbGPT)
        let preparation = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: device, fingerprint: fingerprint, context: FormatContext())
        #expect(preparation.displayName == "New Volume")
        #expect(preparation.suggestedName == "New Volume")
        #expect(preparation.fingerprint == fingerprint)
        #expect(fingerprint.deviceModel == "Samsung T7 Shield")
        #expect(fingerprint.mediaName == "T7 Media")
        #expect(preparation.block == nil)
        #expect(preparation.usedBytes == 90_000)
    }

    @Test func preparationForADisk() throws {
        let usb = try disk(Fixture.usbGPT)
        let preparation = FormatSafety.prepare(
            target: .disk("disk6"), disk: usb, device: Fixture.usbGPT[0],
            fingerprint: Fixture.fingerprint(Fixture.usbGPT[0], in: Fixture.usbGPT), context: FormatContext())
        #expect(preparation.displayName == "Samsung T7 Shield")
        #expect(preparation.suggestedName == "Untitled")
        #expect(preparation.fingerprint.children.map(\.bsdName) == ["disk6s1", "disk6s2", "disk6s3"])
        #expect(preparation.fingerprint.children.map(\.mediaUUID) == [nil, "UUID-S2", "UUID-S3"])
    }

    @Test func unnamedPartitionIsConfirmedByItsDeviceName() throws {
        var infos = Fixture.usbGPT
        infos[3].volumeName = ""
        let preparation = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: try disk(infos), device: infos[3],
            fingerprint: Fixture.fingerprint(infos[3], in: infos), context: FormatContext())
        #expect(preparation.displayName == "disk6s3")
        #expect(preparation.suggestedName == "Untitled")
        #expect(!FormatSafety.isConfirmed("", displayName: preparation.displayName))
        #expect(FormatSafety.isConfirmed("disk6s3", displayName: preparation.displayName))
    }

    @Test func confirmationMustMatchAndCantBeEmpty() {
        #expect(FormatSafety.isConfirmed("New Volume", displayName: "New Volume"))
        #expect(FormatSafety.isConfirmed(" New Volume ", displayName: "New Volume"))
        #expect(!FormatSafety.isConfirmed("new volume", displayName: "New Volume"))
        #expect(!FormatSafety.isConfirmed("New", displayName: "New Volume"))
        #expect(!FormatSafety.isConfirmed("", displayName: "New Volume"))
        #expect(!FormatSafety.isConfirmed("", displayName: ""))
        #expect(!FormatSafety.isConfirmed("  ", displayName: " "))
    }

    @Test func sheetGoesStaleWhenTheDriveIsGoneOrReplaced() throws {
        let usb = try disk(Fixture.usbGPT)
        let device = Fixture.usbGPT[3]
        let fingerprint = Fixture.fingerprint(device, in: Fixture.usbGPT)
        let preparation = FormatSafety.prepare(
            target: .partition("disk6s3"), disk: usb, device: device, fingerprint: fingerprint, context: FormatContext())
        #expect(FormatSafety.isCurrent(preparation, disk: usb, fingerprint: fingerprint))
        #expect(!FormatSafety.isCurrent(preparation, disk: nil, fingerprint: fingerprint))
        #expect(!FormatSafety.isCurrent(preparation, disk: usb, fingerprint: nil))
        var replacement = Fixture.usbGPT
        replacement[0].deviceModel = "Samsung T7"
        #expect(!FormatSafety.isCurrent(
            preparation, disk: try disk(replacement), fingerprint: Fixture.fingerprint(replacement[3], in: replacement)))
        let other = try disk(Fixture.mbrFAT)
        #expect(!FormatSafety.isCurrent(preparation, disk: other, fingerprint: fingerprint))
    }

    @Test func fingerprintNoticesAnyChange() {
        let infos = Fixture.usbGPT
        let info = infos[3]
        let original = Fixture.fingerprint(info, in: infos)
        func changed(_ index: Int, _ change: (inout DiskInfo) -> Void) -> DiskFingerprint {
            var copy = infos
            change(&copy[index])
            return Fixture.fingerprint(copy[3], in: copy)
        }
        #expect(changed(3) { $0.size += 512 } != original)
        #expect(changed(3) { $0.offset = 0 } != original)
        #expect(changed(3) { $0.mediaUUID = "SOMETHING-ELSE" } != original)
        #expect(changed(0) { $0.deviceModel = "Another Stick" } != original)
        #expect(changed(0) { $0.mediaName = "Another Media" } != original)
        #expect(DiskFingerprint(info: info, whole: nil, children: []) != original)

        let whole = infos[0]
        let wholeOriginal = Fixture.fingerprint(whole, in: infos)
        func changedChild(_ change: (inout DiskInfo) -> Void) -> DiskFingerprint {
            var copy = infos
            change(&copy[2])
            return Fixture.fingerprint(whole, in: copy)
        }
        #expect(changedChild { $0.mediaUUID = "NEW-PARTITION" } != wholeOriginal)
        #expect(changedChild { $0.volumeUUID = "NEW-VOLUME" } != wholeOriginal)
        #expect(Fixture.fingerprint(whole, in: Array(infos.dropLast())) != wholeOriginal)
    }

    @Test func fingerprintIgnoresMountsAndContent() {
        let infos = Fixture.usbGPT
        var changed = infos
        for index in changed.indices {
            changed[index].mount = nil
            changed[index].content = "48465300-0000-11AA-AA11-00306543ECAC"
            changed[index].volumeKind = nil
        }
        #expect(Fixture.fingerprint(changed[3], in: changed) == Fixture.fingerprint(infos[3], in: infos))
        #expect(Fixture.fingerprint(changed[0], in: changed) == Fixture.fingerprint(infos[0], in: infos))
    }
}

@MainActor
struct DiskFingerprintReadTests {
    @Test func readsTheDeviceItsDriveAndItsPartitions() {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        func read(_ name: String) -> DiskFingerprint? {
            DiskFingerprint.read(
                name, freshInfo: { environment.freshInfo($0) }, childNames: { environment.childNames(ofWhole: $0) })
        }
        #expect(read("disk6s3") == Fixture.fingerprint(Fixture.usbGPT[3], in: Fixture.usbGPT))
        #expect(read("disk6") == Fixture.fingerprint(Fixture.usbGPT[0], in: Fixture.usbGPT))
        #expect(read("disk9s9") == nil)
        environment.infos["disk6s2"] = nil
        #expect(read("disk6") == nil)
        environment.infos["disk6"] = nil
        #expect(read("disk6s3") == nil)
    }
}
