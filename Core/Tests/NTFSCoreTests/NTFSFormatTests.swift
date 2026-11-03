import NTFSFormat
import Testing

struct FormatRequestTests {
    private let request = FormatRequest(device: "disk6s2", size: 1_048_576_000, offset: 1_048_576, label: "Data", clusterSize: nil, quick: true)

    @Test func argumentsRoundTrip() throws {
        #expect(request.arguments == ["--device", "disk6s2", "--size", "1048576000", "--offset", "1048576", "--label", "Data", "--quick"])
        #expect(try FormatRequest.parse(request.arguments) == request)
        var full = request
        full.clusterSize = 8192
        full.quick = false
        full.label = "--quick \"x\" 'y' Tiếng Việt"
        #expect(try FormatRequest.parse(full.arguments) == full)
    }

    @Test func wholeDeviceComesFromThePartitionName() {
        #expect(request.wholeDevice == "disk6")
        for (device, whole) in [("disk12s10", "disk12"), ("disk6", nil), ("disk6s", nil), ("rdisk6s2", nil), ("disk6s2s1", nil), ("", nil)] {
            var other = request
            other.device = device
            #expect(other.wholeDevice == whole)
        }
    }

    @Test(arguments: [
        ["--device"],
        ["--device", "disk6s2", "--size", "1", "--offset", "0", "--label", "A", "--force"],
        ["--device", "disk6s2", "--size", "1", "--size", "2", "--offset", "0", "--label", "A"],
        ["--device", "disk6s2", "--size", "x", "--offset", "0", "--label", "A"],
        ["--device", "disk6s2", "--size", "1", "--offset", "0"],
        ["--device", "disk6s2", "--size", "1", "--offset", "0", "--label", "A", "--cluster", "big"],
    ])
    func rejectsBadCommandLines(_ arguments: [String]) {
        #expect(throws: FormatToolError.usage) { try FormatRequest.parse(arguments) }
    }
}

struct FormatGuardTests {
    private let request = FormatRequest(device: "disk6s2", size: 1_048_576_000, offset: 1_048_576, label: "Data", clusterSize: nil, quick: true)
    private let facts = DeviceFacts(wholeDevice: "disk6", size: 1_048_576_000, offset: 1_048_576, scheme: FormatGuard.gptScheme, partitionID: 2)

    @Test func acceptsAMatchingExternalPartition() throws {
        try FormatGuard.check(request, facts: facts)
        var mbr = facts
        mbr.scheme = FormatGuard.mbrScheme
        mbr.partitionID = 1
        try FormatGuard.check(request, facts: mbr)
    }

    @Test func refusesUnsafeTargets() {
        func expect(_ error: FormatToolError, request: FormatRequest? = nil, _ change: (inout DeviceFacts) -> Void = { _ in }) {
            var changed = facts
            change(&changed)
            #expect(throws: error) { try FormatGuard.check(request ?? self.request, facts: changed) }
        }
        var whole = request
        whole.device = "disk6"
        expect(.notAPartition, request: whole)
        expect(.notAPartition) { $0.isWhole = true }
        expect(.changed) { $0.wholeDevice = "disk7" }
        expect(.changed) { $0.wholeDevice = "disk61" }
        var empty = request
        empty.size = 0
        expect(.changed, request: empty) { $0.size = 0 }
        var atStart = request
        atStart.offset = 0
        expect(.unsupportedPartition, request: atStart) { $0.offset = 0 }
        expect(.internalDisk) { $0.isInternal = true }
        expect(.systemDisk) { $0.hostsSystem = true }
        expect(.readOnly) { $0.isWritable = false }
        expect(.mounted) { $0.isMounted = true }
        expect(.changed) { $0.size += 512 }
        expect(.changed) { $0.offset = 2_097_152 }
        expect(.changed) { $0.offset = nil }
        expect(.unsupportedPartition) { $0.scheme = nil }
        expect(.unsupportedPartition) { $0.scheme = FormatGuard.mbrScheme; $0.partitionID = 5 }
        expect(.unsupportedPartition) { $0.scheme = FormatGuard.mbrScheme; $0.partitionID = nil }
    }

    @Test func refusesBadOptions() {
        for label in ["", String(repeating: "a", count: 129), "bell\u{7}"] {
            var bad = request
            bad.label = label
            #expect(throws: FormatToolError.invalidLabel) { try FormatGuard.check(bad, facts: facts) }
        }
        for cluster in [256, 3000, 131_072] {
            var bad = request
            bad.clusterSize = cluster
            #expect(throws: FormatToolError.invalidCluster) { try FormatGuard.check(bad, facts: facts) }
        }
        var unaligned = request
        unaligned.offset = 1000
        var unalignedFacts = facts
        unalignedFacts.offset = 1000
        #expect(throws: FormatToolError.changed) { try FormatGuard.check(unaligned, facts: unalignedFacts) }
    }

    @Test func exitCodesAreDistinct() {
        let codes = FormatToolError.allCases.map(\.exitCode)
        #expect(Set(codes).count == codes.count)
        #expect(FormatToolError(rawValue: 70) == .mounted)
    }
}

struct MBRTests {
    private func sector(type: UInt8 = 0x0B, start: UInt32 = 2048, count: UInt32 = 204_800) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[510] = 0x55
        bytes[511] = 0xAA
        bytes[450] = type
        for i in 0..<4 {
            bytes[454 + i] = UInt8((start >> (8 * UInt32(i))) & 0xFF)
            bytes[458 + i] = UInt8((count >> (8 * UInt32(i))) & 0xFF)
        }
        return bytes
    }

    @Test func findsTheMatchingEntry() throws {
        #expect(try MBR.typeFieldOffset(in: sector(), index: 1, start: 2048 * 512, size: 204_800 * 512, blockSize: 512) == 450)
    }

    @Test func refusesMismatches() {
        #expect(throws: FormatToolError.badPartitionTable) {
            try MBR.typeFieldOffset(in: sector(), index: 1, start: 4096 * 512, size: 204_800 * 512, blockSize: 512)
        }
        #expect(throws: FormatToolError.badPartitionTable) {
            try MBR.typeFieldOffset(in: sector(), index: 1, start: 2048 * 512, size: 1, blockSize: 512)
        }
        var unsigned = sector()
        unsigned[511] = 0
        #expect(throws: FormatToolError.badPartitionTable) {
            try MBR.typeFieldOffset(in: unsigned, index: 1, start: 2048 * 512, size: 204_800 * 512, blockSize: 512)
        }
        #expect(throws: FormatToolError.badPartitionTable) {
            try MBR.typeFieldOffset(in: sector(), index: 5, start: 2048 * 512, size: 204_800 * 512, blockSize: 512)
        }
    }
}

struct MkntfsCommandTests {
    @Test func quickFormat() {
        let request = FormatRequest(device: "disk6s2", size: 1_048_576_000, offset: 1_048_576, label: "Data", clusterSize: nil, quick: true)
        #expect(MkntfsCommand.arguments(request, sectorSize: 512)
            == ["-s", "512", "-p", "2048", "-H", "255", "-S", "63", "-L", "Data", "-Q", "/dev/disk6s2"])
    }

    @Test func fullFormatWithClusterSize() {
        let request = FormatRequest(device: "disk6s2", size: 1_048_576_000, offset: 1_048_576, label: "Data", clusterSize: 8192, quick: false)
        #expect(MkntfsCommand.arguments(request, sectorSize: 4096)
            == ["-s", "4096", "-p", "256", "-H", "255", "-S", "63", "-L", "Data", "-c", "8192", "/dev/disk6s2"])
    }

    @Test func startSectorBeyond32BitsIsLeftAtZero() {
        let request = FormatRequest(device: "disk6s2", size: 1 << 30, offset: 3 << 40, label: "Big", clusterSize: nil, quick: true)
        #expect(MkntfsCommand.arguments(request, sectorSize: 512)[3] == "0")
    }
}
