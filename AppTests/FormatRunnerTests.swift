import Foundation
import NTFSFormat
import Testing
@testable import NTFS_for_Mac

@MainActor
final class FakeFormatEnvironment: FormatEnvironment {
    var infos: [String: DiskInfo] = [:]
    var children: [String: [String]] = [:]
    var log: [String] = []
    var pauses: [Duration] = []
    var unmountError: (any Error)?
    /// How many of the next unmounts fail as busy.
    var failingUnmounts = 0
    var ntfsError: (any Error)?
    var afterUnmount: (() -> Void)?
    var afterDiskutil: (() -> Void)?

    init(_ list: [DiskInfo]) {
        for info in list {
            infos[info.bsdName] = info
            if !info.isWhole {
                children[info.wholeBSDName, default: []].append(info.bsdName)
            }
        }
    }

    func freshInfo(_ bsdName: String) -> DiskInfo? { infos[bsdName] }
    func childNames(ofWhole bsdName: String) -> [String] { children[bsdName] ?? [] }

    func unmount(_ bsdName: String, whole: Bool) async throws {
        log.append("unmount \(bsdName)" + (whole ? " whole" : ""))
        if let unmountError { throw unmountError }
        if failingUnmounts > 0 {
            failingUnmounts -= 1
            throw DiskOperationError(message: "in use")
        }
        afterUnmount?()
    }

    func runDiskutil(_ arguments: [String]) async throws {
        log.append("diskutil " + arguments.joined(separator: " "))
        afterDiskutil?()
    }

    func runNTFSFormat(_ request: FormatRequest) async throws {
        log.append("ntfs-format " + request.device)
        if let ntfsError { throw ntfsError }
    }

    func pause(_ duration: Duration) async {
        pauses.append(duration)
    }
}

@MainActor
struct FormatRunnerTests {
    private func job(_ steps: [FormatStep], device: DiskInfo, in infos: [DiskInfo] = Fixture.usbGPT) -> FormatJob {
        FormatJob(fingerprint: Fixture.fingerprint(device, in: infos), steps: steps)
    }

    private let s3 = Fixture.usbGPT[3]
    private var ntfsRequest: FormatRequest {
        FormatRequest(device: "disk6s3", size: s3.size, offset: s3.offset!, label: "Data", clusterSize: nil, quick: true)
    }

    @Test func formatsAPartitionAsNTFS() async throws {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        var stages: [FormatStage] = []
        try await FormatRunner(environment: environment).run(
            job([.unmount("disk6s3", whole: false), .ntfsFormat(ntfsRequest)], device: s3)) { stages.append($0) }
        #expect(environment.log == ["unmount disk6s3", "ntfs-format disk6s3"])
        #expect(stages == [.checking, .unmounting, .formatting, .finishing])
    }

    @Test func stopsWhenTheDriveChanged() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.infos["disk6s3"]?.size += 512
        await #expect(throws: FormatError.diskChanged) {
            try await FormatRunner(environment: environment).run(
                job([.unmount("disk6s3", whole: false), .ntfsFormat(ntfsRequest)], device: s3)) { _ in }
        }
        #expect(environment.log.isEmpty)
    }

    @Test func stopsWhenTheDriveDisappeared() async {
        let environment = FakeFormatEnvironment([])
        await #expect(throws: FormatError.diskChanged) {
            try await FormatRunner(environment: environment).run(job([.ntfsFormat(ntfsRequest)], device: s3)) { _ in }
        }
    }

    @Test func busyDriveIsNotFormatted() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.unmountError = DiskOperationError(message: "in use")
        await #expect(throws: FormatError.busy("in use")) {
            try await FormatRunner(environment: environment).run(
                job([.unmount("disk6s3", whole: false), .ntfsFormat(ntfsRequest)], device: s3)) { _ in }
        }
        #expect(environment.log == ["unmount disk6s3"])
    }

    @Test func skipsUnmountingWhatIsNotMounted() async throws {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.infos["disk6s3"]?.mount = nil
        var device = s3
        device.mount = nil
        try await FormatRunner(environment: environment).run(
            job([.unmount("disk6s3", whole: false), .ntfsFormat(ntfsRequest)], device: device)) { _ in }
        #expect(environment.log == ["ntfs-format disk6s3"])
    }

    private func wholeDiskNTFSJob() -> FormatJob {
        job([
            .unmount("disk6", whole: true),
            .diskutil(["eraseDisk", "ExFAT", "NTFS", "GPT", "disk6"]),
            .ntfsFormatNewPartition(whole: "disk6", label: "Data", clusterSize: nil, quick: true),
        ], device: Fixture.usbGPT[0])
    }

    /// After eraseDisk: EFI plus one new, mounted exFAT partition.
    private func eraseDisk(_ environment: FakeFormatEnvironment) {
        environment.infos["disk6s3"] = nil
        environment.infos["disk6s2"] = DiskInfo(
            bsdName: "disk6s2", wholeBSDName: "disk6", size: 511_900_000_000, offset: 209_735_680, partitionID: 2,
            content: DiskContent.microsoftBasicData, volumeKind: "exfat", volumeName: "NTFS",
            mount: Fixture.mount("/Volumes/NTFS"), isEjectable: true, deviceProtocol: "USB")
        environment.children["disk6"] = ["disk6s1", "disk6s2"]
    }

    @Test func formatsAWholeDiskAsNTFS() async throws {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in self.eraseDisk(environment) }
        try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        #expect(environment.log == [
            "unmount disk6 whole",
            "diskutil eraseDisk ExFAT NTFS GPT disk6",
            "unmount disk6s2",
            "ntfs-format disk6s2",
        ])
    }

    @Test func reportsWhenTheNTFSStepFailsAfterErasing() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in self.eraseDisk(environment) }
        environment.ntfsError = FormatError.tool(.mkntfsFailed)
        await #expect(throws: FormatError.ntfsFailedAfterErase("creating the NTFS file system failed")) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
    }

    @Test func cancelAfterErasingSaysTheDriveWasErased() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in self.eraseDisk(environment) }
        environment.ntfsError = FormatError.cancelled
        await #expect(throws: FormatError.ntfsFailedAfterErase("the administrator prompt was cancelled")) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
    }

    @Test func busyNewPartitionIsRetriedThenReportedAsErased() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in
            self.eraseDisk(environment)
            environment.unmountError = DiskOperationError(message: "in use")
        }
        await #expect(throws: FormatError.ntfsFailedAfterErase("the drive is in use")) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
        #expect(environment.log.filter { $0 == "unmount disk6s2" }.count == 5)
        #expect(environment.pauses == Array(repeating: .seconds(1), count: 4))
        #expect(!environment.log.contains("ntfs-format disk6s2"))
    }

    @Test func newPartitionUnmountSucceedsOnRetry() async throws {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in
            self.eraseDisk(environment)
            environment.failingUnmounts = 2
        }
        try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        #expect(environment.log.filter { $0 == "unmount disk6s2" }.count == 3)
        #expect(environment.pauses == [.seconds(1), .seconds(1)])
        #expect(environment.log.last == "ntfs-format disk6s2")
    }

    @Test func reportsAMissingNewPartition() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in environment.children["disk6"] = ["disk6s1"] }
        await #expect(throws: FormatError.ntfsFailedAfterErase("the new partition wasn't found")) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
    }

    @Test func stopsWhenTheDriveChangesBeforeErasing() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterUnmount = { [unowned environment] in environment.infos["disk6s3"]?.size += 512 }
        await #expect(throws: FormatError.diskChanged) {
            try await FormatRunner(environment: environment).run(
                job([.unmount("disk6s3", whole: false), .ntfsFormat(ntfsRequest)], device: s3)) { _ in }
        }
        #expect(environment.log == ["unmount disk6s3"])
    }

    @Test func stopsWhenTheDiskChangesBeforeDiskutil() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterUnmount = { [unowned environment] in environment.children["disk6"] = ["disk6s1", "disk6s2"] }
        await #expect(throws: FormatError.diskChanged) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
        #expect(environment.log == ["unmount disk6 whole"])
    }
}

struct PrivilegedOutputTests {
    @Test func mapsOsascriptErrors() {
        #expect(PrivilegedOutput.error(fromOsascript: "0:102: execution error: User canceled. (-128)\n") == .cancelled)
        #expect(PrivilegedOutput.error(fromOsascript: "0:102: execution error: ntfs-format: mounted (70)\n") == .tool(.mounted))
        #expect(PrivilegedOutput.error(fromOsascript: "something odd") == .failed("something odd"))
        #expect(PrivilegedOutput.error(fromOsascript: "0:102: execution error: sh: ntfs-format: not found (127)\n")
            == .failed("0:102: execution error: sh: ntfs-format: not found (127)"))
    }
}
