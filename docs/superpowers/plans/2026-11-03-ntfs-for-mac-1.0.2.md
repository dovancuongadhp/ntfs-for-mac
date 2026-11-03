# NTFS for Mac 1.0.2 (Disk Manager + Format) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the menu-bar utility into a Disk Utility–style drive manager that lists every drive, mounts/unmounts/ejects them, and formats partitions or whole external drives as NTFS, exFAT, FAT32 or APFS without ever risking data the user didn't choose to erase.

**Architecture:** A `DiskInventory` (DiskArbitration + IOKit) builds a tree of physical disks → partitions that drives both the new SwiftUI main window and the existing NTFS mount logic. Formatting is planned by pure, tested code (`FormatSafety`, `FormatPlanner`) and executed by `FormatRunner`: `diskutil` for exFAT/FAT32/APFS and partition tables, and a bundled root helper `ntfs-format` (Swift, in the Core package) that re-checks the target and runs the bundled `ntfs-mkfs` (mkntfs) for NTFS.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS 26), DiskArbitration, IOKit, SwiftPM (Core package), XcodeGen, Swift Testing, `diskutil`, ntfs-3g's `mkntfs`.

**Spec:** `docs/superpowers/specs/2026-11-03-ntfs-for-mac-1.0.2-ui-format-design.md`

## Global Constraints

- Deployment target macOS 26.0; app `SWIFT_VERSION = 6.0`; Core `swift-tools-version: 6.2`. Tests use Swift Testing (`import Testing`).
- Do **not** modify `Extension/` or the NTFS read/write code in `Core/Sources/CNTFS`, `Core/Sources/NTFSCore`. Only additions to `Core/Package.swift`, new Core targets and tests.
- English source strings; every new user-visible string gets a Vietnamese translation in `App/Localizable.xcstrings` (Task 11).
- **Data safety while developing (user's rule):**
  - Only one real volume may be touched: the external NTFS partition "New Volume" (`disk5s3` when connected; check the BSD name with `diskutil list external` first). Allowed: read its info, mount/unmount it, write test files and delete them again. **Never format it.**
  - Every other real disk (internal disks, "SSD-PUBLIC", any other drive) must not be touched at all — no mount/unmount/erase commands.
  - All format testing happens only on scratch disk images created by the test itself, checked by device name before every destructive command.
  - Never pass `force` to `diskutil`/DiskArbitration. Never `pkill` the extension (wedges `fskit_agent`).
- Never ask the user for their password; administrator rights come only from the macOS authorization dialog (`with administrator privileges`).
- After adding/removing files under `App/` or `AppTests/`, regenerate the project: `/tmp/XcodeGen/.build/release/xcodegen generate` (commit `NTFSForMac.xcodeproj` changes).
- Commands:
  - Core tests: `swift test --package-path Core`
  - App tests: `xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData test -quiet`
  - Use `/usr/bin/log` (zsh shadows `log`).

## File Structure

Core package (`Core/`):
- `Sources/NTFSFormat/FormatRequest.swift` — request ⇄ command line for `ntfs-format`.
- `Sources/NTFSFormat/FormatGuard.swift` — `DeviceFacts`, `FormatToolError`, `FormatGuard.check`.
- `Sources/NTFSFormat/MBR.swift` — MBR entry verification.
- `Sources/NTFSFormat/MkntfsCommand.swift` — mkntfs arguments.
- `Sources/NTFSFormat/IOMedia.swift` — IOKit IOMedia properties (shared with the app).
- `Sources/ntfs-format/main.swift`, `DeviceInspector.swift`, `RawDisk.swift` — the root helper.
- `Tests/NTFSCoreTests/NTFSFormatTests.swift`.

App (`App/`):
- `Disks/DiskModel.swift` — `DiskInfo`, `PhysicalDisk`, `Partition`, `FileSystemKind`, `PartitionScheme`, `DiskContent`.
- `Disks/DiskTreeBuilder.swift` — pure tree building.
- `Disks/DiskInfoReader.swift` — DA/IOKit → `DiskInfo`.
- `Disks/DiskInventory.swift` — replaces `DiskMonitor.swift`.
- `Disks/MountController.swift` — add `mountDefault`, `unmount`.
- `Format/FormatModel.swift` — targets, options, fingerprint, stages, errors.
- `Format/VolumeNameRule.swift`, `Format/FormatSafety.swift`, `Format/FormatPlanner.swift`, `Format/FormatRunner.swift`, `Format/LiveFormatEnvironment.swift`, `Format/FormatMessages.swift`.
- `Views/Main/` — `MainWindowView.swift`, `SidebarView.swift`, `PartitionDetailView.swift`, `DiskDetailView.swift`, `Components.swift`, `FormatSheet.swift`.
- `Views/AllowWritingConfirmation.swift`; modified `DiskRowView.swift`, `MenuContentView.swift`, `WindowPresenter.swift`, `NTFSForMacApp.swift`, `AppModel.swift`.

Scripts: `scripts/embed-helpers.sh` (new), `scripts/format-integration-test.sh` (new), `scripts/build-local.sh`, `scripts/release.sh` (modified).

---

### Task 1: NTFSFormat library (request, guard, MBR, mkntfs arguments)

**Files:**
- Modify: `Core/Package.swift`
- Create: `Core/Sources/NTFSFormat/FormatRequest.swift`, `FormatGuard.swift`, `MBR.swift`, `MkntfsCommand.swift`, `IOMedia.swift`
- Test: `Core/Tests/NTFSCoreTests/NTFSFormatTests.swift`

**Interfaces:**
- Produces: `FormatRequest(device:size:offset:label:clusterSize:quick:)`, `.arguments: [String]`, `FormatRequest.parse(_:) throws`; `FormatToolError: Int32` (`exitCode`); `DeviceFacts`; `FormatGuard.check(_:facts:) throws`, `FormatGuard.gptScheme`, `.mbrScheme`; `MBR.typeFieldOffset(in:index:start:size:blockSize:) throws -> Int`, `MBR.ntfsType`; `MkntfsCommand.arguments(_:sectorSize:) -> [String]`; `IOMedia.number(_:_:)`, `IOMedia.strings(_:_:)`, `IOMedia.parentBSDName(_:)`.

- [ ] **Step 1: Add the target to the package**

In `Core/Package.swift`, add to `products`:

```swift
        .library(name: "NTFSFormat", targets: ["NTFSFormat"]),
```

add to `targets` (before the test target):

```swift
        .target(name: "NTFSFormat"),
```

and add `"NTFSFormat"` to the `NTFSCoreTests` dependencies:

```swift
            dependencies: ["NTFSCore", "NTFSProbe", "NTFSShared", "NTFSFormat", "ntfs-mkfs"]
```

- [ ] **Step 2: Write the failing tests**

Create `Core/Tests/NTFSCoreTests/NTFSFormatTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core --filter "FormatRequestTests|FormatGuardTests|MBRTests|MkntfsCommandTests"`
Expected: build failure — `no such module 'NTFSFormat'` / missing types.

- [ ] **Step 4: Implement `FormatRequest.swift`**

```swift
/// What the app asks `ntfs-format` to do, and the command line that carries it.
public struct FormatRequest: Equatable, Sendable {
    /// BSD name of the partition, e.g. `disk6s2`.
    public var device: String
    /// Partition size and start on the disk, in bytes, as the app saw them.
    public var size: UInt64
    public var offset: UInt64
    public var label: String
    /// Bytes per cluster; `nil` lets mkntfs choose.
    public var clusterSize: Int?
    public var quick: Bool

    public init(device: String, size: UInt64, offset: UInt64, label: String, clusterSize: Int?, quick: Bool) {
        self.device = device
        self.size = size
        self.offset = offset
        self.label = label
        self.clusterSize = clusterSize
        self.quick = quick
    }

    public var arguments: [String] {
        var arguments = ["--device", device, "--size", String(size), "--offset", String(offset), "--label", label]
        if let clusterSize {
            arguments += ["--cluster", String(clusterSize)]
        }
        if quick {
            arguments.append("--quick")
        }
        return arguments
    }

    public static func parse(_ arguments: [String]) throws -> FormatRequest {
        var values: [String: String] = [:]
        var quick = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--quick":
                quick = true
            case "--device", "--size", "--offset", "--label", "--cluster":
                guard values[argument] == nil, let value = iterator.next() else { throw FormatToolError.usage }
                values[argument] = value
            default:
                throw FormatToolError.usage
            }
        }
        guard let device = values["--device"],
              let size = values["--size"].flatMap(UInt64.init),
              let offset = values["--offset"].flatMap(UInt64.init),
              let label = values["--label"]
        else { throw FormatToolError.usage }
        var clusterSize: Int?
        if let text = values["--cluster"] {
            guard let value = Int(text) else { throw FormatToolError.usage }
            clusterSize = value
        }
        return FormatRequest(device: device, size: size, offset: offset, label: label, clusterSize: clusterSize, quick: quick)
    }
}
```

- [ ] **Step 5: Implement `FormatGuard.swift`**

```swift
/// Why `ntfs-format` refused or failed. The raw value is its exit status,
/// which the app reads back through `do shell script`.
public enum FormatToolError: Int32, Error, CaseIterable, Sendable {
    case usage = 64
    case notFound
    case notAPartition
    case internalDisk
    case systemDisk
    case readOnly
    case mounted
    case changed
    case invalidLabel
    case invalidCluster
    case unsupportedPartition
    case badPartitionTable
    case ioError
    case mkntfsFailed

    public var exitCode: Int32 { rawValue }
}

/// What DiskArbitration and IOKit report about the partition right now.
public struct DeviceFacts: Equatable, Sendable {
    public var isWhole: Bool
    public var wholeDevice: String
    public var size: UInt64
    public var offset: UInt64?
    public var blockSize: UInt64
    public var isInternal: Bool
    public var isMounted: Bool
    public var isWritable: Bool
    /// Content of the whole disk, e.g. `GUID_partition_scheme`.
    public var scheme: String?
    public var partitionID: Int?
    /// The whole disk holds the startup volume (directly or as an APFS store).
    public var hostsSystem: Bool

    public init(
        isWhole: Bool = false, wholeDevice: String, size: UInt64, offset: UInt64?, blockSize: UInt64 = 512,
        isInternal: Bool = false, isMounted: Bool = false, isWritable: Bool = true,
        scheme: String?, partitionID: Int?, hostsSystem: Bool = false
    ) {
        self.isWhole = isWhole
        self.wholeDevice = wholeDevice
        self.size = size
        self.offset = offset
        self.blockSize = blockSize
        self.isInternal = isInternal
        self.isMounted = isMounted
        self.isWritable = isWritable
        self.scheme = scheme
        self.partitionID = partitionID
        self.hostsSystem = hostsSystem
    }
}

/// The checks `ntfs-format` runs as root before writing anything.
public enum FormatGuard {
    public static let gptScheme = "GUID_partition_scheme"
    public static let mbrScheme = "FDisk_partition_scheme"
    public static let maxLabelLength = 128

    public static func check(_ request: FormatRequest, facts: DeviceFacts) throws {
        guard request.device.wholeMatch(of: /disk[0-9]+s[0-9]+/) != nil, !facts.isWhole else {
            throw FormatToolError.notAPartition
        }
        guard !facts.isInternal else { throw FormatToolError.internalDisk }
        guard !facts.hostsSystem else { throw FormatToolError.systemDisk }
        guard facts.isWritable else { throw FormatToolError.readOnly }
        guard !facts.isMounted else { throw FormatToolError.mounted }
        guard facts.size == request.size, facts.offset == request.offset,
              facts.blockSize > 0, request.offset % facts.blockSize == 0
        else { throw FormatToolError.changed }

        let label = request.label
        guard !label.isEmpty, label.utf16.count <= maxLabelLength,
              !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw FormatToolError.invalidLabel }

        if let cluster = request.clusterSize {
            guard (512...65536).contains(cluster), cluster & (cluster - 1) == 0, UInt64(cluster) >= facts.blockSize else {
                throw FormatToolError.invalidCluster
            }
        }

        switch facts.scheme {
        case gptScheme?:
            break
        case mbrScheme?:
            // Logical partitions live in extended boot records, which this tool doesn't edit.
            guard let id = facts.partitionID, (1...4).contains(id) else { throw FormatToolError.unsupportedPartition }
        default:
            throw FormatToolError.unsupportedPartition
        }
    }
}
```

- [ ] **Step 6: Implement `MBR.swift`**

```swift
/// The classic Master Boot Record partition table in a disk's first block.
public enum MBR {
    public static let ntfsType: UInt8 = 0x07

    /// Checks that primary entry `index` (1–4) spans exactly `start`/`size`
    /// bytes, and returns the byte offset of its type field.
    public static func typeFieldOffset(in sector: [UInt8], index: Int, start: UInt64, size: UInt64, blockSize: UInt64) throws -> Int {
        guard sector.count >= 512, sector[510] == 0x55, sector[511] == 0xAA,
              (1...4).contains(index), blockSize > 0
        else { throw FormatToolError.badPartitionTable }
        let entry = 446 + 16 * (index - 1)
        let firstBlock = UInt64(littleEndian32(sector, at: entry + 8))
        let blockCount = UInt64(littleEndian32(sector, at: entry + 12))
        guard firstBlock * blockSize == start, blockCount * blockSize == size else {
            throw FormatToolError.badPartitionTable
        }
        return entry + 4
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
```

- [ ] **Step 7: Implement `MkntfsCommand.swift`**

```swift
/// The `mkntfs` command line for a request.
public enum MkntfsCommand {
    /// Runs on the block device without `-F`, so mkntfs itself refuses a
    /// mounted partition. Geometry and start sector go in the boot sector,
    /// where Windows expects them.
    public static func arguments(_ request: FormatRequest, sectorSize: UInt64) -> [String] {
        let startSector = request.offset / sectorSize
        var arguments = [
            "-s", String(sectorSize),
            "-p", String(startSector <= UInt64(UInt32.max) ? startSector : 0),
            "-H", "255", "-S", "63",
            "-L", request.label,
        ]
        if let clusterSize = request.clusterSize {
            arguments += ["-c", String(clusterSize)]
        }
        if request.quick {
            arguments.append("-Q")
        }
        arguments.append("/dev/" + request.device)
        return arguments
    }
}
```

- [ ] **Step 8: Implement `IOMedia.swift`**

```swift
import Foundation
import IOKit

/// IOKit properties of IOMedia objects that DiskArbitration doesn't report.
/// `path` is DiskArbitration's `DAMediaPath`.
public enum IOMedia {
    public static func number(_ path: String, _ key: String) -> UInt64? {
        withEntry(path) { (property($0, key) as? NSNumber)?.uint64Value }.flatMap { $0 }
    }

    public static func strings(_ path: String, _ key: String) -> [String] {
        withEntry(path) { property($0, key) as? [String] }.flatMap { $0 } ?? []
    }

    /// The BSD name of the nearest IOMedia above this one, e.g. the partition
    /// that stores an APFS container.
    public static func parentBSDName(_ path: String) -> String? {
        withEntry(path) { entry -> String? in
            var current = entry
            IOObjectRetain(current)
            defer { IOObjectRelease(current) }
            var parent: io_registry_entry_t = 0
            while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
                IOObjectRelease(current)
                current = parent
                if IOObjectConformsTo(current, "IOMedia") != 0 {
                    return property(current, "BSD Name") as? String
                }
            }
            return nil
        }.flatMap { $0 }
    }

    private static func withEntry<T>(_ path: String, _ body: (io_registry_entry_t) -> T) -> T? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        return body(entry)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `swift test --package-path Core --filter "FormatRequestTests|FormatGuardTests|MBRTests|MkntfsCommandTests"`
Expected: all pass. Then `swift test --package-path Core` — all 63 existing tests still pass.

- [ ] **Step 10: Commit**

```bash
git add Core/Package.swift Core/Sources/NTFSFormat Core/Tests/NTFSCoreTests/NTFSFormatTests.swift
git commit -m "Add NTFSFormat: format request, safety checks, MBR and mkntfs arguments"
```

---

### Task 2: The `ntfs-format` root helper

**Files:**
- Modify: `Core/Package.swift`
- Create: `Core/Sources/ntfs-format/main.swift`, `DeviceInspector.swift`, `RawDisk.swift`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces: executable `ntfs-format` (same directory as `ntfs-mkfs`). Usage: `ntfs-format --device diskNsM --size BYTES --offset BYTES --label NAME [--cluster BYTES] [--quick]`. Exit 0 on success, `FormatToolError.rawValue` otherwise.

- [ ] **Step 1: Add the product and target**

In `Core/Package.swift` `products`:

```swift
        .executable(name: "ntfs-format", targets: ["ntfs-format"]),
```

`targets`:

```swift
        .executableTarget(name: "ntfs-format", dependencies: ["NTFSFormat"]),
```

- [ ] **Step 2: Create `DeviceInspector.swift`**

```swift
import DiskArbitration
import Foundation
import NTFSFormat

/// Gathers `DeviceFacts` from DiskArbitration and IOKit.
enum DeviceInspector {
    static let apfsContainerContent = "EF57347C-0000-11AA-AA11-00306543ECAC"

    static func facts(for device: String) throws -> DeviceFacts {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { throw FormatToolError.notFound }

        let whole = DADiskCopyWholeDisk(disk)
        let wholeName = whole.flatMap { DADiskGetBSDName($0) }.map { String(cString: $0) } ?? device
        let wholeDescription = whole.flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mediaPath = description[kDADiskDescriptionMediaPathKey as String] as? String
        let boot = bootPhysicalDisk(session)

        return DeviceFacts(
            isWhole: description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? true,
            wholeDevice: wholeName,
            size: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
            offset: mediaPath.flatMap { IOMedia.number($0, "Base") },
            blockSize: (description[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
            // Only virtual devices may lack the key; anything else unknown counts as internal.
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                ?? (deviceProtocol != "Virtual Interface"),
            isMounted: description[kDADiskDescriptionVolumePathKey as String] != nil || mountedDevices().contains("/dev/" + device),
            isWritable: description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? false,
            scheme: wholeDescription[kDADiskDescriptionMediaContentKey as String] as? String,
            partitionID: mediaPath.flatMap { IOMedia.number($0, "Partition ID") }.map(Int.init),
            // If the startup disk can't be determined, treat every disk as the startup disk.
            hostsSystem: boot.map { $0 == wholeName } ?? true
        )
    }

    /// The physical whole disk holding `/`, following APFS containers to their store.
    static func bootPhysicalDisk(_ session: DASession) -> String? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let source = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard source.hasPrefix("/dev/") else { return nil }
        return physicalWholeDisk(of: String(source.dropFirst(5)), session)
    }

    private static func physicalWholeDisk(of name: String, _ session: DASession) -> String? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
              let whole = DADiskCopyWholeDisk(disk),
              let wholeName = DADiskGetBSDName(whole).map({ String(cString: $0) }),
              let description = DADiskCopyDescription(whole) as? [String: Any]
        else { return nil }
        if description[kDADiskDescriptionMediaContentKey as String] as? String == apfsContainerContent {
            guard let path = description[kDADiskDescriptionMediaPathKey as String] as? String,
                  let store = IOMedia.parentBSDName(path)
            else { return nil }
            return physicalWholeDisk(of: store, session)
        }
        return wholeName
    }

    private static func mountedDevices() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        return Set((0..<Int(count)).map { index in
            withUnsafeBytes(of: mounts[index].f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        })
    }
}
```

- [ ] **Step 3: Create `RawDisk.swift`**

```swift
import Foundation
import NTFSFormat

/// The first block of a whole disk, read and written through its raw device.
final class RawDisk {
    private let descriptor: Int32
    private let blockSize: Int

    /// Opens read-write up front, so a busy disk is refused before anything is formatted.
    init(wholeDevice: String, blockSize: Int) throws {
        descriptor = open("/dev/r" + wholeDevice, O_RDWR)
        guard descriptor >= 0 else {
            FileHandle.standardError.write(Data("ntfs-format: open /dev/r\(wholeDevice): \(String(cString: strerror(errno)))\n".utf8))
            throw FormatToolError.ioError
        }
        self.blockSize = blockSize
    }

    deinit {
        close(descriptor)
    }

    func readFirstBlock() throws -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockSize)
        guard pread(descriptor, &block, blockSize, 0) == blockSize else { throw FormatToolError.ioError }
        return block
    }

    func writeFirstBlock(_ block: [UInt8]) throws {
        guard block.count == blockSize,
              pwrite(descriptor, block, blockSize, 0) == blockSize,
              fsync(descriptor) == 0
        else { throw FormatToolError.ioError }
    }
}
```

- [ ] **Step 4: Create `main.swift`**

```swift
import Foundation
import NTFSFormat

// Formats one external partition as NTFS. Runs as root through the app's
// administrator prompt, so it re-checks everything the app checked and
// verifies the partition table before writing anything.

func formatPartition() throws {
    let request = try FormatRequest.parse(Array(CommandLine.arguments.dropFirst()))
    let facts = try DeviceInspector.facts(for: request.device)
    try FormatGuard.check(request, facts: facts)

    var table: (disk: RawDisk, original: [UInt8], typeField: Int)?
    if facts.scheme == FormatGuard.mbrScheme, let index = facts.partitionID {
        let disk = try RawDisk(wholeDevice: facts.wholeDevice, blockSize: Int(facts.blockSize))
        let block = try disk.readFirstBlock()
        let typeField = try MBR.typeFieldOffset(
            in: block, index: index, start: request.offset, size: request.size, blockSize: facts.blockSize)
        if block[typeField] != MBR.ntfsType {
            table = (disk, block, typeField)
        }
    }

    try runMkntfs(MkntfsCommand.arguments(request, sectorSize: facts.blockSize))

    if let table {
        var block = try table.disk.readFirstBlock()
        guard block == table.original else { throw FormatToolError.badPartitionTable }
        block[table.typeField] = MBR.ntfsType
        try table.disk.writeFirstBlock(block)
    }
}

func runMkntfs(_ arguments: [String]) throws {
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let process = Process()
    process.executableURL = directory.appendingPathComponent("ntfs-mkfs")
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("ntfs-format: cannot run ntfs-mkfs: \(error.localizedDescription)\n".utf8))
        throw FormatToolError.mkntfsFailed
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FormatToolError.mkntfsFailed }
}

do {
    try formatPartition()
} catch let error as FormatToolError {
    FileHandle.standardError.write(Data("ntfs-format: \(error)\n".utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("ntfs-format: \(error.localizedDescription)\n".utf8))
    exit(FormatToolError.ioError.exitCode)
}
```

- [ ] **Step 5: Build and smoke-test refusals (no root, touches no disk)**

Run:
```bash
swift build --package-path Core -c release --product ntfs-format
BIN="$(swift build --package-path Core -c release --show-bin-path)"
"$BIN/ntfs-format" --bogus; echo "exit $?"
"$BIN/ntfs-format" --device disk999s1 --size 1 --offset 0 --label X; echo "exit $?"
```
Expected: `exit 64` (usage), then `exit 65` (notFound — no such disk).

- [ ] **Step 6: Commit**

```bash
git add Core/Package.swift Core/Sources/ntfs-format
git commit -m "Add ntfs-format, the root helper that formats an external partition as NTFS"
```

---

### Task 3: Disk model and tree builder

**Files:**
- Create: `App/Disks/DiskModel.swift`, `App/Disks/DiskTreeBuilder.swift`
- Create: `AppTests/Fixtures.swift`, `AppTests/DiskTreeBuilderTests.swift`

**Interfaces:**
- Produces: `DiskInfo` (memberwise init, fields in the order below), `PhysicalDisk`, `Partition` (`ntfsDisk: NTFSDisk?`, `isAPFSStore`), `FileSystemKind` (`label`), `PartitionScheme(content:)`, `DiskContent` constants, `DiskTreeBuilder.build(_:) -> [PhysicalDisk]`, `DiskTreeBuilder.physicalDisk(containing:in:) -> PhysicalDisk?`; test fixtures `Fixture.usbGPT`, `.mbrFAT`, `.usbAPFS`, `.internalMac`, `.superfloppy`, `.diskImage`, `Fixture.mount(_:total:free:type:)`.

- [ ] **Step 1: Write the fixtures**

Create `AppTests/Fixtures.swift` (values mirror real DiskArbitration/IOKit output probed from scratch images):

```swift
import Foundation
@testable import NTFS_for_Mac

enum Fixture {
    static func mount(_ path: String, total: UInt64 = 1000, free: UInt64 = 400, type: String = "exfat") -> NTFSDisk.Mount {
        NTFSDisk.Mount(path: URL(fileURLWithPath: path), fileSystemType: type, isReadOnly: false, totalBytes: total, freeBytes: free)
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
                     volumeName: "Macintosh HD", mount: mount("/", type: "apfs"), isInternal: true,
                     deviceProtocol: "Apple Fabric", apfsRoles: ["System"]),
            DiskInfo(bsdName: "disk3s2", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
                     volumeName: "Preboot", isInternal: true, deviceProtocol: "Apple Fabric", apfsRoles: ["Preboot"]),
            DiskInfo(bsdName: "disk3s5", wholeBSDName: "disk3", size: 994_000_000_000, volumeKind: "apfs",
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
```

- [ ] **Step 2: Write the failing tests**

Create `AppTests/DiskTreeBuilderTests.swift`:

```swift
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
```

Note: `bsdName` on `DiskInfo` is `var`, so the last test can rename it.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData test -quiet`
Expected: build failure — `DiskInfo`, `DiskTreeBuilder` not found.

- [ ] **Step 4: Implement `App/Disks/DiskModel.swift`**

```swift
import Foundation
import NTFSShared

/// Media content values reported by DiskArbitration.
enum DiskContent {
    static let apfsStore = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    static let apfsContainer = "EF57347C-0000-11AA-AA11-00306543ECAC"
    static let microsoftBasicData = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
    static let virtualProtocol = "Virtual Interface"

    /// Partitions that hold no user data and stay out of the sidebar.
    static let hidden: Set<String> = [
        "EFI", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
        "Apple_Boot", "426F6F74-0000-11AA-AA11-00306543ECAC",
        "Apple_APFS_Recovery", "52637672-7900-11AA-AA11-00306543ECAC",
        "Microsoft Reserved", "E3C9E316-0B5C-4DB8-817D-F92DF00215AE",
        "Apple_partition_map", "Apple_Free", "Apple_Void",
    ]

    /// APFS roles of the volumes that make up macOS.
    static let systemRoles: Set<String> = [
        "System", "Data", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband", "Installer",
    ]
    /// System helper volumes that never appear in the sidebar.
    static let hiddenRoles: Set<String> = ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband"]
}

/// One DiskArbitration disk object, with what IOKit adds.
struct DiskInfo: Equatable, Sendable {
    var bsdName: String
    var wholeBSDName: String
    var isWhole = false
    var isLeaf = true
    var size: UInt64 = 0
    var blockSize: UInt64 = 512
    /// Byte offset of a partition on its disk (IOMedia "Base").
    var offset: UInt64?
    var partitionID: Int?
    var content: String?
    var mediaName: String?
    var mediaUUID: String?
    var volumeKind: String?
    var volumeName: String?
    var volumeUUID: String?
    var mount: NTFSDisk.Mount?
    var isWritable = true
    var isEjectable = false
    var isInternal = false
    var deviceProtocol: String?
    var deviceModel: String?
    /// For an APFS container's whole disk: the partition that stores it.
    var physicalStore: String?
    var apfsRoles: [String] = []
    var hasTimeMachineBackup = false

    var displayName: String {
        volumeName ?? mediaName ?? bsdName
    }

    /// Same key `DiskMonitor` used, so "Allow writing" settings survive the update.
    var preferenceKey: String {
        mediaUUID ?? volumeUUID ?? "\(bsdName)-\(size)"
    }
}

enum PartitionScheme: Equatable, Sendable {
    case gpt, mbr, none

    init(content: String?) {
        switch content {
        case "GUID_partition_scheme": self = .gpt
        case "FDisk_partition_scheme": self = .mbr
        default: self = .none
        }
    }
}

enum FileSystemKind: Hashable, Sendable {
    case ntfs, exfat, fat, apfs, hfs
    case other(String)
    case unknown

    init(volumeKind: String?, content: String?) {
        switch volumeKind {
        case Identifiers.systemDriverTypeName?, Identifiers.fileSystemTypeName?: self = .ntfs
        case "exfat"?: self = .exfat
        case "msdos"?: self = .fat
        case "apfs"?: self = .apfs
        case "hfs"?: self = .hfs
        case let kind?: self = .other(kind)
        case nil:
            switch content {
            case "Windows_NTFS"?: self = .ntfs
            case DiskContent.apfsStore?, "Apple_APFS"?: self = .apfs
            default: self = .unknown
            }
        }
    }

    var label: String {
        switch self {
        case .ntfs: "NTFS"
        case .exfat: "exFAT"
        case .fat: "FAT"
        case .apfs: "APFS"
        case .hfs: "Mac OS Extended"
        case .other(let kind): kind
        case .unknown: "—"
        }
    }
}

struct Partition: Identifiable, Equatable, Sendable {
    var id: String { bsdName }

    let bsdName: String
    let wholeBSDName: String
    var name: String
    var fileSystem: FileSystemKind
    var size: UInt64
    var offset: UInt64?
    var partitionID: Int?
    var content: String?
    var volumeKind: String?
    var preferenceKey: String
    var volumeUUID: String?
    var mount: NTFSDisk.Mount?
    var isWritable: Bool
    var isHidden: Bool
    var apfsRoles: [String]
    var isTimeMachine: Bool
    /// For an APFS volume: the partition holding its container. Formatting the
    /// volume formats that partition.
    var apfsStore: String?

    var isRecognized: Bool { volumeKind != nil }
    var isAPFSStore: Bool { content == DiskContent.apfsStore || content == "Apple_APFS" }

    /// The view the NTFS mount logic works with, for NTFS partitions.
    var ntfsDisk: NTFSDisk? {
        guard NTFSDisk.isCandidate(content: content, volumeKind: volumeKind) else { return nil }
        return NTFSDisk(
            bsdName: bsdName, name: name, preferenceKey: preferenceKey,
            isRecognized: isRecognized, isWritableMedia: isWritable, mount: mount)
    }
}

struct PhysicalDisk: Identifiable, Equatable, Sendable {
    var id: String { bsdName }

    let bsdName: String
    var name: String
    var size: UInt64
    var scheme: PartitionScheme
    var isInternal: Bool
    var isVirtual: Bool
    var isEjectable: Bool
    var isWritable: Bool
    var connection: String?
    var blockSize: UInt64
    /// Partitions in disk order, each APFS store followed by its volumes.
    var partitions: [Partition]

    var sidebarPartitions: [Partition] { partitions.filter { !$0.isHidden } }
    /// Partitions as laid out on the disk, for the partition map.
    var mapPartitions: [Partition] { partitions.filter { $0.apfsStore == nil } }
}
```

- [ ] **Step 5: Implement `App/Disks/DiskTreeBuilder.swift`**

```swift
import Foundation

/// Turns flat DiskArbitration records into physical disks with their partitions.
enum DiskTreeBuilder {
    static func build(_ infos: [DiskInfo]) -> [PhysicalDisk] {
        let containers = infos.filter { $0.isWhole && $0.content == DiskContent.apfsContainer }
        return infos
            .filter { $0.isWhole && $0.content != DiskContent.apfsContainer }
            .sorted { naturalOrder($0.bsdName, $1.bsdName) }
            .map { whole in physicalDisk(whole, infos: infos, containers: containers) }
    }

    /// The physical disk holding a partition or volume, also for snapshot
    /// devices such as `disk3s1s1` that aren't in the tree themselves.
    static func physicalDisk(containing bsdName: String, in tree: [PhysicalDisk]) -> PhysicalDisk? {
        var name = bsdName
        while true {
            if let disk = tree.first(where: { $0.bsdName == name || $0.partitions.contains { $0.bsdName == name } }) {
                return disk
            }
            guard let suffix = name.range(of: "s[0-9]+$", options: .regularExpression) else { return nil }
            name.removeSubrange(suffix)
        }
    }

    private static func physicalDisk(_ whole: DiskInfo, infos: [DiskInfo], containers: [DiskInfo]) -> PhysicalDisk {
        let scheme = PartitionScheme(content: whole.content)
        let children = infos
            .filter { !$0.isWhole && $0.wholeBSDName == whole.bsdName }
            .sorted(by: diskOrder)

        var partitions: [Partition] = []
        if children.isEmpty, whole.isLeaf {
            partitions.append(partition(whole, hidden: false))
        }
        for child in children {
            let volumes = containers
                .filter { $0.physicalStore == child.bsdName }
                .flatMap { container in infos.filter { !$0.isWhole && $0.wholeBSDName == container.bsdName } }
                .sorted(by: diskOrder)
            var store = partition(child, hidden: !volumes.isEmpty || DiskContent.hidden.contains(child.content ?? ""))
            if !volumes.isEmpty {
                store.name = volumes
                    .filter { Set($0.apfsRoles).isDisjoint(with: DiskContent.hiddenRoles) }
                    .map(\.displayName)
                    .joined(separator: ", ")
            }
            partitions.append(store)
            for volume in volumes {
                var item = partition(volume, hidden: !Set(volume.apfsRoles).isDisjoint(with: DiskContent.hiddenRoles))
                item.apfsStore = child.bsdName
                partitions.append(item)
            }
        }

        let model = whole.deviceModel.flatMap { $0.isEmpty ? nil : $0 }
        return PhysicalDisk(
            bsdName: whole.bsdName,
            name: model ?? whole.mediaName ?? whole.bsdName,
            size: whole.size,
            scheme: scheme,
            isInternal: whole.isInternal,
            isVirtual: whole.deviceProtocol == DiskContent.virtualProtocol,
            isEjectable: whole.isEjectable,
            isWritable: whole.isWritable,
            connection: whole.deviceProtocol,
            blockSize: whole.blockSize,
            partitions: partitions
        )
    }

    private static func partition(_ info: DiskInfo, hidden: Bool) -> Partition {
        Partition(
            bsdName: info.bsdName,
            wholeBSDName: info.wholeBSDName,
            name: info.displayName,
            fileSystem: FileSystemKind(volumeKind: info.volumeKind, content: info.content),
            size: info.size,
            offset: info.offset,
            partitionID: info.partitionID,
            content: info.content,
            volumeKind: info.volumeKind,
            preferenceKey: info.preferenceKey,
            volumeUUID: info.volumeUUID,
            mount: info.mount,
            isWritable: info.isWritable,
            isHidden: hidden,
            apfsRoles: info.apfsRoles,
            isTimeMachine: info.hasTimeMachineBackup || info.apfsRoles.contains("Backup"),
            apfsStore: nil
        )
    }

    private static func diskOrder(_ a: DiskInfo, _ b: DiskInfo) -> Bool {
        switch (a.offset, b.offset) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: naturalOrder(a.bsdName, b.bsdName)
        }
    }

    private static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData test -quiet`
Expected: all tests pass (11 existing + 9 new).

- [ ] **Step 7: Commit**

```bash
git add App/Disks/DiskModel.swift App/Disks/DiskTreeBuilder.swift AppTests/Fixtures.swift AppTests/DiskTreeBuilderTests.swift NTFSForMac.xcodeproj
git commit -m "Model every disk as physical disks with partitions"
```

---

### Task 4: Live DiskInventory replacing DiskMonitor

**Files:**
- Create: `App/Disks/DiskInfoReader.swift`, `App/Disks/DiskInventory.swift`
- Delete: `App/Disks/DiskMonitor.swift`
- Modify: `App/AppModel.swift`, `App/Views/MenuContentView.swift`, `project.yml`

**Interfaces:**
- Consumes: Task 3 types; `IOMedia` from Task 1.
- Produces: `DiskInventory` with `tree`, `sidebarDisks`, `disks: [NTFSDisk]`, `session`, `onDiskChanged`, `onDiskRemoved`, `disk(named:)`, `physicalDisk(named:)`, `partition(named:) -> (partition: Partition, disk: PhysicalDisk)?`, `childNames(ofWhole:)`, `freshInfo(_:)`, `refresh(bsdName:)`, `refreshUsage()`, `systemDiskNames`, `appDiskName`, `static showsVirtualDisks`. `AppModel.inventory` (renamed from `monitor`).

- [ ] **Step 1: Link NTFSFormat into the app**

In `project.yml`, under `targets.NTFSForMac.dependencies`, add:

```yaml
      - package: NTFSCore
        product: NTFSFormat
```

- [ ] **Step 2: Create `App/Disks/DiskInfoReader.swift`**

```swift
import DiskArbitration
import Foundation
import NTFSFormat

/// Reads a DiskArbitration disk into a `DiskInfo`.
enum DiskInfoReader {
    static func read(_ disk: DADisk) -> DiskInfo? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String
        else { return nil }

        let wholeName = DADiskCopyWholeDisk(disk).flatMap { DADiskGetBSDName($0) }.map { String(cString: $0) } ?? bsdName
        let isWhole = description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        let content = description[kDADiskDescriptionMediaContentKey as String] as? String
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mediaPath = description[kDADiskDescriptionMediaPathKey as String] as? String
        let mount = (description[kDADiskDescriptionVolumePathKey as String] as? URL).flatMap(mountInfo)
        let roles = mediaPath.map { IOMedia.strings($0, "Role") } ?? []

        return DiskInfo(
            bsdName: bsdName,
            wholeBSDName: wholeName,
            isWhole: isWhole,
            isLeaf: description[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false,
            size: number(description[kDADiskDescriptionMediaSizeKey as String]) ?? 0,
            blockSize: number(description[kDADiskDescriptionMediaBlockSizeKey as String]) ?? 512,
            offset: mediaPath.flatMap { IOMedia.number($0, "Base") },
            partitionID: mediaPath.flatMap { IOMedia.number($0, "Partition ID") }.map(Int.init),
            content: content,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String,
            mediaUUID: uuidString(description[kDADiskDescriptionMediaUUIDKey as String]),
            volumeKind: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            volumeName: description[kDADiskDescriptionVolumeNameKey as String] as? String,
            volumeUUID: uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]),
            mount: mount,
            isWritable: description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? true,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false,
            // Only virtual devices may lack the key; anything else unknown counts as internal.
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                ?? (deviceProtocol != DiskContent.virtualProtocol),
            deviceProtocol: deviceProtocol,
            deviceModel: (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
                .trimmingCharacters(in: .whitespaces),
            physicalStore: isWhole && content == DiskContent.apfsContainer ? mediaPath.flatMap(IOMedia.parentBSDName) : nil,
            apfsRoles: roles,
            hasTimeMachineBackup: mount.map {
                FileManager.default.fileExists(atPath: $0.path.appending(path: "Backups.backupdb").path)
            } ?? false
        )
    }

    static func mountInfo(_ path: URL) -> NTFSDisk.Mount? {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return nil }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let blockSize = UInt64(info.f_bsize)
        return NTFSDisk.Mount(
            path: path,
            fileSystemType: type,
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            totalBytes: info.f_blocks * blockSize,
            freeBytes: info.f_bavail * blockSize
        )
    }

    /// The `/dev` node a path is mounted from, without `/dev/`.
    static func mountSource(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let source = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : nil
    }

    private static func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String
    }
}
```

- [ ] **Step 3: Create `App/Disks/DiskInventory.swift` and delete the old monitor**

```bash
git rm App/Disks/DiskMonitor.swift
```

```swift
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

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).update(disk) }
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).update(disk) }
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            MainActor.assumeIsolated { DiskInventory.instance(context).remove(disk) }
        }, context)
    }

    isolated deinit {
        // Callbacks hold an unretained pointer to self.
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
        tree = DiskTreeBuilder.build(Array(infos.values))
        let old = disks
        disks = tree.flatMap(\.partitions).compactMap(\.ntfsDisk)
            .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        for disk in disks where old.first(where: { $0.bsdName == disk.bsdName }) != disk {
            onDiskChanged?(disk)
        }
        for disk in old where !disks.contains(where: { $0.bsdName == disk.bsdName }) {
            onDiskRemoved?(disk.bsdName)
        }
    }
}
```

- [ ] **Step 4: Switch AppModel and the menu to the inventory**

In `App/AppModel.swift` replace `let monitor = DiskMonitor()` with `let inventory = DiskInventory()`, and replace every `monitor.` with `inventory.` (`mounter` session, `start()`, `perform`). In `App/Views/MenuContentView.swift` replace `model.monitor.` with `model.inventory.` (three places).

Run: `rg -n "monitor" App` — Expected: no matches.

- [ ] **Step 5: Build, run all tests**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData test -quiet`
Expected: all tests pass.

- [ ] **Step 6: Manual check — NTFS behavior unchanged (New Volume only)**

Build and install (`scripts/build-local.sh`, then the install cycle: `diskutil unmount disk5s3`, `timeout 10 osascript -e 'quit app "NTFS for Mac"'`, `rm -rf "/Applications/NTFS for Mac.app"`, `ditto "build/DerivedData/Build/Products/Release/NTFS for Mac.app" "/Applications/NTFS for Mac.app"`, `diskutil mount disk5s3` twice, `open -g "/Applications/NTFS for Mac.app"`). Touch no other disk.
Expected: the menu lists only "New Volume" as before, read & write; `mount | grep "New Volume"` shows `ntfsrw`. SSD-PUBLIC (exFAT) is not in the menu.

- [ ] **Step 7: Commit**

```bash
git add -A App project.yml NTFSForMac.xcodeproj
git commit -m "Track every disk with DiskInventory; NTFS mount logic reads from it"
```

---

### Task 5: Format rules — names, safety, preparation

**Files:**
- Create: `App/Format/FormatModel.swift`, `App/Format/VolumeNameRule.swift`, `App/Format/FormatSafety.swift`
- Test: `AppTests/VolumeNameRuleTests.swift`, `AppTests/FormatSafetyTests.swift`

**Interfaces:**
- Consumes: Task 3 types, `FormatToolError` (Task 1).
- Produces:
  - `FormatTarget` (`.partition(String)`, `.disk(String)`, `id`, `isDisk`), `FormatFileSystem` (`title`, `diskutilName`), `FormatOptions(name:fileSystem:scheme:clusterSize:quick:)`, `DiskFingerprint(info:children:)`, `FormatStage` (`checking, unmounting, formatting, finishing`), `FormatError` (LocalizedError: `diskChanged, busy(String), cancelled, unexpectedLayout, tool(FormatToolError), failed(String), ntfsFailedAfterErase(String), blocked(String)`).
  - `VolumeNameRule.validate(_:for:) -> Result<String, VolumeNameError>`.
  - `FormatBlock`, `FormatWarning`, `FormatContext`, `FormatPreparation`, `FormatSafety.blockReason(for: PhysicalDisk, context:)`, `FormatSafety.blockReason(for: FormatTarget, on:context:)`, `.device(for:on:)`, `.affected(by:on:)`, `.unaffected(by:on:)`, `.fileSystems(for:on:device:)`, `.usedBytes(_:)`, `.warnings(for:)`, `.prepare(target:disk:device:children:context:)`.

- [ ] **Step 1: Write the failing tests**

`AppTests/VolumeNameRuleTests.swift`:

```swift
import Testing
@testable import NTFS_for_Mac

struct VolumeNameRuleTests {
    @Test func trimsAndKeepsValidNames() {
        #expect(VolumeNameRule.validate("  Ổ dữ liệu ", for: .ntfs) == .success("Ổ dữ liệu"))
        #expect(VolumeNameRule.validate("Photos 2026", for: .apfs) == .success("Photos 2026"))
        #expect(VolumeNameRule.validate("USB 64GB", for: .exfat) == .success("USB 64GB"))
    }

    @Test func fat32IsUppercasedASCIIUpTo11() {
        #expect(VolumeNameRule.validate("kingston", for: .fat32) == .success("KINGSTON"))
        #expect(VolumeNameRule.validate("TWELVE CHARS", for: .fat32) == .failure(.tooLong(11)))
        #expect(VolumeNameRule.validate("Ổ", for: .fat32) == .failure(.notASCII))
        #expect(VolumeNameRule.validate("A.B", for: .fat32) == .failure(.invalidCharacter(".")))
    }

    @Test func lengthLimits() {
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 11), for: .exfat) == .success(String(repeating: "a", count: 11)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 12), for: .exfat) == .failure(.tooLong(11)))
        #expect(VolumeNameRule.validate(String(repeating: "a", count: 129), for: .ntfs) == .failure(.tooLong(128)))
        #expect(VolumeNameRule.validate(String(repeating: "ổ", count: 100), for: .apfs) == .failure(.tooLong(255)))
    }

    @Test func rejectsEmptyAndForbiddenCharacters() {
        #expect(VolumeNameRule.validate("   ", for: .ntfs) == .failure(.empty))
        #expect(VolumeNameRule.validate("a/b", for: .ntfs) == .failure(.invalidCharacter("/")))
        #expect(VolumeNameRule.validate("a:b", for: .apfs) == .failure(.invalidCharacter(":")))
        #expect(VolumeNameRule.validate("a\u{7}b", for: .exfat) == .failure(.invalidCharacter("\u{7}")))
    }
}
```

`AppTests/FormatSafetyTests.swift`:

```swift
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
        #expect(FormatSafety.fileSystems(for: .partition("disk10"), on: card, device: Fixture.superfloppy[0]) == [.exfat, .fat32])
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild ... test -quiet` (full command in Global Constraints)
Expected: build failure — missing `VolumeNameRule`, `FormatSafety`, …

- [ ] **Step 3: Implement `App/Format/FormatModel.swift`**

```swift
import Foundation
import NTFSFormat

enum FormatTarget: Hashable, Identifiable, Sendable {
    case partition(String)
    case disk(String)

    var id: String {
        switch self {
        case .partition(let name): "partition:" + name
        case .disk(let name): "disk:" + name
        }
    }

    var isDisk: Bool {
        if case .disk = self { true } else { false }
    }
}

enum FormatFileSystem: String, CaseIterable, Identifiable, Sendable {
    case ntfs, exfat, fat32, apfs

    var id: Self { self }

    var title: String {
        switch self {
        case .ntfs: "NTFS"
        case .exfat: "exFAT"
        case .fat32: "FAT32"
        case .apfs: "APFS"
        }
    }

    /// The name `diskutil` uses; NTFS is formatted by `ntfs-format` instead.
    var diskutilName: String? {
        switch self {
        case .ntfs: nil
        case .exfat: "ExFAT"
        case .fat32: "MS-DOS FAT32"
        case .apfs: "APFS"
        }
    }
}

struct FormatOptions: Equatable, Sendable {
    /// Already validated by `VolumeNameRule`.
    var name: String
    var fileSystem: FormatFileSystem
    /// Whole-disk formats only.
    var scheme: PartitionScheme = .gpt
    /// NTFS only; `nil` lets mkntfs choose.
    var clusterSize: Int?
    /// NTFS only; a full format writes zeros over the partition.
    var quick = true
}

/// What identifies the device the user confirmed. Formatting stops if any of
/// it differs when the work starts.
struct DiskFingerprint: Equatable, Sendable {
    var bsdName: String
    var wholeBSDName: String
    var size: UInt64
    var offset: UInt64?
    var mediaUUID: String?
    /// For a whole disk: its partitions.
    var children: [String]

    init(info: DiskInfo, children: [String]) {
        bsdName = info.bsdName
        wholeBSDName = info.wholeBSDName
        size = info.size
        offset = info.offset
        mediaUUID = info.mediaUUID
        self.children = children
    }
}

enum FormatStage: Equatable, Sendable {
    case checking, unmounting, formatting, finishing
}

enum FormatError: LocalizedError, Equatable {
    case diskChanged
    case busy(String)
    case cancelled
    case unexpectedLayout
    case tool(FormatToolError)
    case failed(String)
    case ntfsFailedAfterErase(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .diskChanged:
            String(localized: "The drive changed since this window opened. Nothing was erased.")
        case .busy(let detail):
            String(localized: "The drive is in use. Quit the apps using it and try again. (\(detail))")
        case .cancelled:
            String(localized: "Formatting was cancelled. Nothing was erased.")
        case .unexpectedLayout:
            String(localized: "The new partition could not be found. The drive may not be usable; format it again.")
        case .tool(let error):
            error.message
        case .failed(let detail):
            String(localized: "Formatting failed: \(detail)")
        case .ntfsFailedAfterErase(let detail):
            String(localized: "The drive was erased and formatted as exFAT, but formatting it as NTFS failed: \(detail)")
        case .blocked(let reason):
            reason
        }
    }
}
```

- [ ] **Step 4: Implement `App/Format/VolumeNameRule.swift`**

```swift
import Foundation

enum VolumeNameError: Error, Equatable {
    case empty
    case tooLong(Int)
    case invalidCharacter(Character)
    case notASCII
}

/// Volume name limits of each file system.
enum VolumeNameRule {
    static let windowsForbidden: Set<Character> = ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"]
    static let fatForbidden = windowsForbidden.union(["+", ",", ".", ";", "=", "[", "]"])

    /// Returns the name as it will be written (FAT32 upper-cases it).
    static func validate(_ raw: String, for fileSystem: FormatFileSystem) -> Result<String, VolumeNameError> {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(.empty) }
        if let bad = name.first(where: { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) {
            return .failure(.invalidCharacter(bad))
        }
        switch fileSystem {
        case .fat32:
            let upper = name.uppercased()
            guard upper.allSatisfy(\.isASCII) else { return .failure(.notASCII) }
            return check(upper, forbidden: fatForbidden, max: 11) { $0.count }
        case .exfat:
            return check(name, forbidden: windowsForbidden, max: 11) { $0.utf16.count }
        case .ntfs:
            return check(name, forbidden: windowsForbidden, max: 128) { $0.utf16.count }
        case .apfs:
            return check(name, forbidden: [":"], max: 255) { $0.utf8.count }
        }
    }

    private static func check(
        _ name: String, forbidden: Set<Character>, max: Int, length: (String) -> Int
    ) -> Result<String, VolumeNameError> {
        if let bad = name.first(where: forbidden.contains) {
            return .failure(.invalidCharacter(bad))
        }
        guard length(name) <= max else { return .failure(.tooLong(max)) }
        return .success(name)
    }
}
```

- [ ] **Step 5: Implement `App/Format/FormatSafety.swift`**

```swift
import Foundation

enum FormatBlock: Equatable, Sendable {
    case internalDisk, systemDisk, appDisk, readOnlyMedia, busy, virtualDisk, unsupported
}

enum FormatWarning: Hashable, Sendable {
    case timeMachine
    case unknownUsage
    case apfsVolumes([String])
}

struct FormatContext: Equatable, Sendable {
    var systemDisks: Set<String> = []
    var appDisk: String?
    var busy: Set<String> = []
    var allowsVirtualDisks = false
}

/// Everything the format sheet shows and confirms, captured when it opens.
struct FormatPreparation: Equatable, Sendable {
    let target: FormatTarget
    let disk: PhysicalDisk
    /// What the user types to confirm.
    let displayName: String
    /// The device that is actually erased.
    let device: DiskInfo
    let fingerprint: DiskFingerprint
    let affected: [Partition]
    let unaffected: [Partition]
    let usedBytes: UInt64?
    let warnings: [FormatWarning]
    let fileSystems: [FormatFileSystem]
    let block: FormatBlock?
    let suggestedName: String
}

/// Decides what may be formatted and what formatting it would erase.
enum FormatSafety {
    static func blockReason(for disk: PhysicalDisk, context: FormatContext) -> FormatBlock? {
        if disk.isInternal { return .internalDisk }
        if context.systemDisks.contains(disk.bsdName) { return .systemDisk }
        if context.appDisk == disk.bsdName { return .appDisk }
        if disk.isVirtual, !context.allowsVirtualDisks { return .virtualDisk }
        if !disk.isWritable { return .readOnlyMedia }
        if context.busy.contains(disk.bsdName) || disk.partitions.contains(where: { context.busy.contains($0.bsdName) }) {
            return .busy
        }
        return nil
    }

    static func blockReason(for target: FormatTarget, on disk: PhysicalDisk, context: FormatContext) -> FormatBlock? {
        if let reason = blockReason(for: disk, context: context) { return reason }
        guard case .partition(let name) = target else { return nil }
        guard let partition = disk.partitions.first(where: { $0.bsdName == name }), !partition.isHidden else {
            return .unsupported
        }
        return partition.isWritable ? nil : .readOnlyMedia
    }

    /// The BSD name that is erased: the disk, the partition, or for an APFS
    /// volume the partition holding its container.
    static func device(for target: FormatTarget, on disk: PhysicalDisk) -> String {
        switch target {
        case .disk(let name):
            return name
        case .partition(let name):
            return disk.partitions.first { $0.bsdName == name }?.apfsStore ?? name
        }
    }

    static func affected(by target: FormatTarget, on disk: PhysicalDisk) -> [Partition] {
        switch target {
        case .disk:
            return disk.sidebarPartitions
        case .partition(let name):
            guard let partition = disk.partitions.first(where: { $0.bsdName == name }) else { return [] }
            guard let store = partition.apfsStore else { return [partition] }
            return disk.sidebarPartitions.filter { $0.apfsStore == store }
        }
    }

    static func unaffected(by target: FormatTarget, on disk: PhysicalDisk) -> [Partition] {
        guard case .partition = target else { return [] }
        let erased = Set(affected(by: target, on: disk).map(\.bsdName))
        return disk.sidebarPartitions.filter { !erased.contains($0.bsdName) }
    }

    static func fileSystems(for target: FormatTarget, on disk: PhysicalDisk, device: DiskInfo) -> [FormatFileSystem] {
        if target.isDisk {
            return FormatFileSystem.allCases
        }
        switch disk.scheme {
        case .gpt:
            return device.offset == nil ? [.exfat, .fat32, .apfs] : [.ntfs, .exfat, .fat32, .apfs]
        case .mbr:
            let canNTFS = device.offset != nil && (1...4).contains(device.partitionID ?? 0)
            return canNTFS ? [.ntfs, .exfat, .fat32] : [.exfat, .fat32]
        case .none:
            return [.exfat, .fat32]
        }
    }

    /// Used space of the erased partitions, or `nil` when any isn't mounted.
    /// APFS volumes report their whole container, so each container counts once.
    static func usedBytes(_ partitions: [Partition]) -> UInt64? {
        var total: UInt64 = 0
        var containers: [String: UInt64] = [:]
        for partition in partitions {
            guard let mount = partition.mount else { return nil }
            let used = mount.totalBytes - min(mount.freeBytes, mount.totalBytes)
            if let store = partition.apfsStore {
                containers[store] = max(containers[store] ?? 0, used)
            } else {
                total += used
            }
        }
        return total + containers.values.reduce(0, +)
    }

    static func warnings(for partitions: [Partition]) -> [FormatWarning] {
        var warnings: [FormatWarning] = []
        if partitions.contains(where: \.isTimeMachine) {
            warnings.append(.timeMachine)
        }
        if partitions.contains(where: { $0.mount == nil }) {
            warnings.append(.unknownUsage)
        }
        let volumes = partitions.filter { $0.apfsStore != nil }
        if volumes.count > 1 {
            warnings.append(.apfsVolumes(volumes.map(\.name)))
        }
        return warnings
    }

    static func prepare(
        target: FormatTarget, disk: PhysicalDisk, device: DiskInfo, children: [String], context: FormatContext
    ) -> FormatPreparation {
        let affected = affected(by: target, on: disk)
        let displayName: String
        let suggestedName: String
        switch target {
        case .disk:
            displayName = disk.name
            suggestedName = String(localized: "Untitled")
        case .partition(let name):
            displayName = disk.partitions.first { $0.bsdName == name }?.name ?? name
            suggestedName = displayName
        }
        return FormatPreparation(
            target: target,
            disk: disk,
            displayName: displayName,
            device: device,
            fingerprint: DiskFingerprint(info: device, children: children),
            affected: affected,
            unaffected: unaffected(by: target, on: disk),
            usedBytes: usedBytes(affected),
            warnings: warnings(for: affected),
            fileSystems: fileSystems(for: target, on: disk, device: device),
            block: blockReason(for: target, on: disk, context: context),
            suggestedName: suggestedName
        )
    }
}
```

`String(localized: "Untitled")` returns "Untitled" in tests (English), matching the test.

- [ ] **Step 6: Add the messages file (needed for `error.message`)**

Create `App/Format/FormatMessages.swift`:

```swift
import Foundation
import NTFSFormat

extension FormatToolError {
    var message: String {
        switch self {
        case .usage: String(localized: "Internal error: invalid format request.")
        case .notFound: String(localized: "The partition is no longer connected. Nothing was erased.")
        case .notAPartition: String(localized: "Only a partition can be formatted as NTFS this way. Nothing was erased.")
        case .internalDisk: String(localized: "Internal drives are protected. Nothing was erased.")
        case .systemDisk: String(localized: "This drive holds macOS. Nothing was erased.")
        case .readOnly: String(localized: "The drive is write-protected. Nothing was erased.")
        case .mounted: String(localized: "The partition is still in use. Quit the apps using it and try again. Nothing was erased.")
        case .changed: String(localized: "The drive changed since this window opened. Nothing was erased.")
        case .invalidLabel: String(localized: "The name isn't valid for NTFS. Nothing was erased.")
        case .invalidCluster: String(localized: "The cluster size isn't valid for this drive. Nothing was erased.")
        case .unsupportedPartition: String(localized: "This kind of partition can't be formatted as NTFS. Nothing was erased.")
        case .badPartitionTable: String(localized: "The drive's partition table looks different than expected, so NTFS for Mac stopped.")
        case .ioError: String(localized: "The drive couldn't be read or written.")
        case .mkntfsFailed: String(localized: "Creating the NTFS file system failed. The partition may not be usable; format it again.")
        }
    }
}

extension FormatBlock {
    var message: String {
        switch self {
        case .internalDisk: String(localized: "Internal drives are protected and can't be formatted.")
        case .systemDisk: String(localized: "This drive holds macOS and can't be formatted.")
        case .appDisk: String(localized: "NTFS for Mac is running from this drive.")
        case .readOnlyMedia: String(localized: "The drive is write-protected.")
        case .busy: String(localized: "Another operation is running on this drive.")
        case .virtualDisk: String(localized: "Disk images can't be formatted.")
        case .unsupported: String(localized: "This partition can't be formatted.")
        }
    }
}

extension FormatWarning {
    var message: String {
        switch self {
        case .timeMachine:
            String(localized: "This drive holds Time Machine backups.")
        case .unknownUsage:
            String(localized: "The amount of data couldn't be determined — assume it holds important files.")
        case .apfsVolumes(let names):
            String(localized: "These APFS volumes will also be erased: \(names.joined(separator: ", "))")
        }
    }
}

extension FormatStage {
    var label: String {
        switch self {
        case .checking: String(localized: "Checking the drive…")
        case .unmounting: String(localized: "Unmounting…")
        case .formatting: String(localized: "Formatting…")
        case .finishing: String(localized: "Mounting…")
        }
    }
}

extension VolumeNameError {
    var message: String {
        switch self {
        case .empty: String(localized: "Enter a name.")
        case .tooLong(let limit): String(localized: "The name can have at most \(limit) characters.")
        case .invalidCharacter(let character): String(localized: "The name can't contain “\(String(character))”.")
        case .notASCII: String(localized: "FAT32 names can only use English letters, digits and simple symbols.")
        }
    }
}

extension PartitionScheme {
    var label: String {
        switch self {
        case .gpt: String(localized: "GUID Partition Map")
        case .mbr: String(localized: "Master Boot Record")
        case .none: String(localized: "None")
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild ... test -quiet`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add App/Format AppTests/VolumeNameRuleTests.swift AppTests/FormatSafetyTests.swift NTFSForMac.xcodeproj
git commit -m "Add format safety rules, volume name limits and format preparation"
```

---

### Task 6: Format planner, runner and AppModel integration

**Files:**
- Create: `App/Format/FormatPlanner.swift`, `App/Format/FormatRunner.swift`, `App/Format/LiveFormatEnvironment.swift`
- Modify: `App/Disks/MountController.swift`, `App/AppModel.swift`, `App/NTFSForMacApp.swift`
- Test: `AppTests/FormatPlannerTests.swift`, `AppTests/FormatRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5.
- Produces: `FormatStep`, `FormatJob`, `FormatPlanner.job(for:options:)`; `FormatEnvironment` protocol; `FormatRunner(environment:)`, `run(_:progress:) async throws`; `PrivilegedOutput.error(fromOsascript:) -> FormatError`; `MountController.mountDefault(bsdName:)`, `unmount(bsdName:whole:)`; `AppModel`: `formatting`, `isFormatting`, `formatContext`, `isProtected(_:)`, `canUnmount(_:on:)`, `canEject(_:)`, `mount(_ partition:)`, `unmount(_:)`, `eject(_ disk: PhysicalDisk)`, `reveal(_ partition:)`, `prepareFormat(_:) -> FormatPreparation?`, `format(_:options:progress:) async throws`.

- [ ] **Step 1: Write the failing tests**

`AppTests/FormatPlannerTests.swift`:

```swift
import Foundation
import NTFSFormat
import Testing
@testable import NTFS_for_Mac

struct FormatPlannerTests {
    private func preparation(_ target: FormatTarget, _ infos: [DiskInfo], device: DiskInfo) throws -> FormatPreparation {
        let disk = try #require(DiskTreeBuilder.build(infos).first)
        return FormatSafety.prepare(target: target, disk: disk, device: device, children: [], context: FormatContext())
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
}
```

`AppTests/FormatRunnerTests.swift`:

```swift
import Foundation
import NTFSFormat
import Testing
@testable import NTFS_for_Mac

@MainActor
final class FakeFormatEnvironment: FormatEnvironment {
    var infos: [String: DiskInfo] = [:]
    var children: [String: [String]] = [:]
    var log: [String] = []
    var unmountError: (any Error)?
    var ntfsError: (any Error)?
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
    }

    func runDiskutil(_ arguments: [String]) async throws {
        log.append("diskutil " + arguments.joined(separator: " "))
        afterDiskutil?()
    }

    func runNTFSFormat(_ request: FormatRequest) async throws {
        log.append("ntfs-format " + request.device)
        if let ntfsError { throw ntfsError }
    }

    func pause() async {}
}

@MainActor
struct FormatRunnerTests {
    private func job(_ steps: [FormatStep], device: DiskInfo, children: [String] = []) -> FormatJob {
        FormatJob(fingerprint: DiskFingerprint(info: device, children: children), steps: steps)
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
        ], device: Fixture.usbGPT[0], children: ["disk6s1", "disk6s2", "disk6s3"])
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
        environment.ntfsError = FormatError.cancelled
        await #expect(throws: FormatError.ntfsFailedAfterErase(FormatError.cancelled.localizedDescription)) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
    }

    @Test func reportsAMissingNewPartition() async {
        let environment = FakeFormatEnvironment(Fixture.usbGPT)
        environment.afterDiskutil = { [unowned environment] in environment.children["disk6"] = ["disk6s1"] }
        await #expect(throws: FormatError.unexpectedLayout) {
            try await FormatRunner(environment: environment).run(wholeDiskNTFSJob()) { _ in }
        }
    }
}

struct PrivilegedOutputTests {
    @Test func mapsOsascriptErrors() {
        #expect(PrivilegedOutput.error(fromOsascript: "0:102: execution error: User canceled. (-128)\n") == .cancelled)
        #expect(PrivilegedOutput.error(fromOsascript: "0:102: execution error: ntfs-format: mounted (70)\n") == .tool(.mounted))
        #expect(PrivilegedOutput.error(fromOsascript: "something odd") == .failed("something odd"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild ... test -quiet`
Expected: build failure — missing `FormatPlanner`, `FormatRunner`, `FormatEnvironment`, `PrivilegedOutput`.

- [ ] **Step 3: Implement `App/Format/FormatPlanner.swift`**

```swift
import Foundation
import NTFSFormat

enum FormatStep: Equatable, Sendable {
    /// Unmount without forcing; `whole` unmounts every volume on the disk.
    case unmount(String, whole: Bool)
    /// Arguments for `/usr/sbin/diskutil`.
    case diskutil([String])
    /// Run `ntfs-format` with administrator rights.
    case ntfsFormat(FormatRequest)
    /// After `eraseDisk`: format the disk's single new data partition as NTFS.
    case ntfsFormatNewPartition(whole: String, label: String, clusterSize: Int?, quick: Bool)
}

struct FormatJob: Equatable, Sendable {
    var fingerprint: DiskFingerprint
    var steps: [FormatStep]
}

enum FormatPlanner {
    static func job(for preparation: FormatPreparation, options: FormatOptions) -> FormatJob {
        let device = preparation.device
        var steps: [FormatStep] = []
        switch preparation.target {
        case .partition:
            steps += preparation.affected.filter { $0.mount != nil }.map { .unmount($0.bsdName, whole: false) }
            if let diskutilName = options.fileSystem.diskutilName {
                steps.append(.diskutil(["eraseVolume", diskutilName, options.name, device.bsdName]))
            } else {
                steps.append(.ntfsFormat(FormatRequest(
                    device: device.bsdName, size: device.size, offset: device.offset ?? 0,
                    label: options.name, clusterSize: options.clusterSize, quick: options.quick)))
            }
        case .disk:
            steps.append(.unmount(device.bsdName, whole: true))
            let scheme = options.scheme == .mbr && options.fileSystem != .apfs ? "MBR" : "GPT"
            if let diskutilName = options.fileSystem.diskutilName {
                steps.append(.diskutil(["eraseDisk", diskutilName, options.name, scheme, device.bsdName]))
            } else {
                // exFAT is a placeholder that diskutil can create on any scheme;
                // its partition is then reformatted as NTFS.
                steps.append(.diskutil(["eraseDisk", "ExFAT", "NTFS", scheme, device.bsdName]))
                steps.append(.ntfsFormatNewPartition(
                    whole: device.bsdName, label: options.name, clusterSize: options.clusterSize, quick: options.quick))
            }
        }
        return FormatJob(fingerprint: preparation.fingerprint, steps: steps)
    }
}
```

- [ ] **Step 4: Implement `App/Format/FormatRunner.swift`**

```swift
import Foundation
import NTFSFormat

/// The side effects formatting needs, so the runner can be tested with a fake.
@MainActor
protocol FormatEnvironment {
    func freshInfo(_ bsdName: String) -> DiskInfo?
    func childNames(ofWhole bsdName: String) -> [String]
    func unmount(_ bsdName: String, whole: Bool) async throws
    func runDiskutil(_ arguments: [String]) async throws
    func runNTFSFormat(_ request: FormatRequest) async throws
    /// Waits briefly for DiskArbitration to catch up.
    func pause() async
}

/// Executes a format job, re-checking the drive before anything is erased.
@MainActor
final class FormatRunner {
    private let environment: any FormatEnvironment

    init(environment: any FormatEnvironment) {
        self.environment = environment
    }

    func run(_ job: FormatJob, progress: @MainActor (FormatStage) -> Void) async throws {
        progress(.checking)
        guard let info = environment.freshInfo(job.fingerprint.bsdName),
              DiskFingerprint(info: info, children: info.isWhole ? environment.childNames(ofWhole: info.bsdName) : [])
                == job.fingerprint
        else { throw FormatError.diskChanged }

        var erased = false
        for step in job.steps {
            switch step {
            case .unmount(let name, let whole):
                progress(.unmounting)
                try await unmount(name, whole: whole)
            case .diskutil(let arguments):
                progress(.formatting)
                try await environment.runDiskutil(arguments)
                erased = true
            case .ntfsFormat(let request):
                progress(.formatting)
                try await formatNTFS(request, afterErase: erased)
            case .ntfsFormatNewPartition(let whole, let label, let clusterSize, let quick):
                progress(.formatting)
                let partition = try await newDataPartition(onWhole: whole)
                if partition.mount != nil {
                    try await unmount(partition.bsdName, whole: false)
                }
                guard let offset = partition.offset else { throw FormatError.unexpectedLayout }
                try await formatNTFS(
                    FormatRequest(device: partition.bsdName, size: partition.size, offset: offset,
                                  label: label, clusterSize: clusterSize, quick: quick),
                    afterErase: true)
            }
        }
        progress(.finishing)
    }

    private func unmount(_ name: String, whole: Bool) async throws {
        let names = whole ? [name] + environment.childNames(ofWhole: name) : [name]
        guard names.contains(where: { environment.freshInfo($0)?.mount != nil }) else { return }
        do {
            try await environment.unmount(name, whole: whole)
        } catch {
            throw FormatError.busy(error.localizedDescription)
        }
    }

    private func formatNTFS(_ request: FormatRequest, afterErase: Bool) async throws {
        do {
            try await environment.runNTFSFormat(request)
        } catch {
            if afterErase {
                throw FormatError.ntfsFailedAfterErase(error.localizedDescription)
            }
            throw error
        }
    }

    private func newDataPartition(onWhole whole: String) async throws -> DiskInfo {
        for _ in 0..<20 {
            let data = environment.childNames(ofWhole: whole)
                .compactMap(environment.freshInfo)
                .filter { !DiskContent.hidden.contains($0.content ?? "") }
            if data.count == 1 {
                return data[0]
            }
            await environment.pause()
        }
        throw FormatError.unexpectedLayout
    }
}
```

- [ ] **Step 5: Implement `App/Format/LiveFormatEnvironment.swift`**

```swift
import Foundation
import NTFSFormat

/// Formats real drives: DiskArbitration, `diskutil`, and `ntfs-format` through
/// the macOS administrator prompt.
@MainActor
struct LiveFormatEnvironment: FormatEnvironment {
    let inventory: DiskInventory
    let mounter: MountController

    func freshInfo(_ bsdName: String) -> DiskInfo? {
        inventory.freshInfo(bsdName)
    }

    func childNames(ofWhole bsdName: String) -> [String] {
        inventory.childNames(ofWhole: bsdName)
    }

    func unmount(_ bsdName: String, whole: Bool) async throws {
        try await mounter.unmount(bsdName: bsdName, whole: whole)
    }

    func runDiskutil(_ arguments: [String]) async throws {
        let result = try await CommandLineTool.run("/usr/sbin/diskutil", arguments)
        appLog.notice("diskutil \(arguments.joined(separator: " "), privacy: .public): \(result.status) \(result.output, privacy: .public)")
        guard result.status == 0 else { throw FormatError.failed(result.lastLine) }
    }

    func runNTFSFormat(_ request: FormatRequest) async throws {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ntfs-format").path
        let command = ([helper] + request.arguments).map(MountController.shellQuoted).joined(separator: " ") + " 2>&1"
        let script = "do shell script \(MountController.appleScriptQuoted(command)) with administrator privileges"
        // osascript, not NSAppleScript: a full format can take hours and must not block the main thread.
        let result = try await CommandLineTool.run("/usr/bin/osascript", ["-e", script])
        appLog.notice("ntfs-format \(request.device, privacy: .public): \(result.status) \(result.output, privacy: .public)")
        guard result.status == 0 else { throw PrivilegedOutput.error(fromOsascript: result.output) }
    }

    func pause() async {
        try? await Task.sleep(for: .milliseconds(500))
    }
}

struct CommandResult: Sendable {
    var status: Int32
    var output: String

    var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

enum CommandLineTool {
    static func run(_ path: String, _ arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Reads why `do shell script … with administrator privileges` failed. The
/// error number at the end is the script's exit status, or -128 for Cancel.
enum PrivilegedOutput {
    static func error(fromOsascript output: String) -> FormatError {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /\((-?[0-9]+)\)$/), let code = Int32(match.1) else {
            return .failed(trimmed)
        }
        if code == -128 {
            return .cancelled
        }
        if let error = FormatToolError(rawValue: code) {
            return .tool(error)
        }
        return .failed(trimmed)
    }
}
```

- [ ] **Step 6: Add `mountDefault` and `unmount` to MountController**

In `App/Disks/MountController.swift`, after `eject(bsdName:)` add:

```swift
    /// Mounts with whichever driver macOS picks, e.g. for exFAT or APFS.
    func mountDefault(bsdName: String) async throws {
        try await mount(try diskObject(bsdName), arguments: [])
    }

    /// Unmounts without forcing, so it fails while an app has files open.
    func unmount(bsdName: String, whole: Bool = false) async throws {
        let disk = try diskObject(bsdName)
        let target = whole ? (DADiskCopyWholeDisk(disk) ?? disk) : disk
        let options = whole ? kDADiskUnmountOptionWhole : kDADiskUnmountOptionDefault
        try await unmount(target, options: DADiskUnmountOptions(options))
    }
```

- [ ] **Step 7: Integrate formatting and generic disk actions into AppModel**

Replace `App/AppModel.swift` with:

```swift
import AppKit
import NTFSShared
import Observation

/// Wires disk events, per-drive settings, mounting and formatting together.
@MainActor
@Observable
final class AppModel {
    let inventory = DiskInventory()
    let extensionStatus = ExtensionStatus()
    let preferences = VolumePreferences()
    let launchAtLogin = LaunchAtLogin()
    /// Disks and partitions with a mount, unmount or eject in progress.
    private(set) var busy: Set<String> = []
    /// Physical disks being formatted.
    private(set) var formatting: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private lazy var mounter = MountController(session: inventory.session)
    @ObservationIgnored private lazy var formatter = FormatRunner(
        environment: LiveFormatEnvironment(inventory: inventory, mounter: mounter))
    @ObservationIgnored private let notifier = Notifier()
    /// Disks already auto-mounted during their current connection.
    @ObservationIgnored private var handled: Set<String> = []
    private var reasons: [String: ReadOnlyReason] = [:]
    /// A read-only signal that arrived before its disk showed up as mounted.
    @ObservationIgnored private var pendingReason: (reason: ReadOnlyReason, date: Date)?

    var isFormatting: Bool { !formatting.isEmpty }

    func start() {
        notifier.requestAuthorization()
        notifier.observeReadOnlyFallbacks { [weak self] reason in
            self?.extensionReportedReadOnly(reason)
        }
        inventory.onDiskChanged = { [weak self] disk in
            self?.diskChanged(disk)
        }
        inventory.onDiskRemoved = { [weak self] bsdName in
            self?.handled.remove(bsdName)
            self?.reasons[bsdName] = nil
        }
        extensionStatus.refresh()
        for disk in inventory.disks {
            diskChanged(disk)
        }
    }

    // MARK: NTFS drives

    func state(of disk: NTFSDisk) -> DiskState {
        disk.state(reason: reasons[disk.bsdName], writeEnabled: preferences.isWriteEnabled(disk.preferenceKey))
    }

    func isWriteEnabled(_ disk: NTFSDisk) -> Bool {
        preferences.isWriteEnabled(disk.preferenceKey)
    }

    func setWriteEnabled(_ enabled: Bool, for disk: NTFSDisk) {
        preferences.setWriteEnabled(enabled, for: disk.preferenceKey)
        guard disk.isRecognized, disk.mount != nil || enabled else { return }
        reasons[disk.bsdName] = nil
        mount(disk, readOnly: !enabled)
    }

    func mount(_ disk: NTFSDisk, readOnly: Bool? = nil) {
        let readOnly = readOnly ?? !preferences.isWriteEnabled(disk.preferenceKey)
        handled.insert(disk.bsdName)
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.mountWithExtension(bsdName: disk.bsdName, volumeName: disk.name, readOnly: readOnly)
        }
    }

    /// Remounts a drive left read-only by an unclean journal, discarding the journal.
    func allowWritingAnyway(_ disk: NTFSDisk) {
        reasons[disk.bsdName] = nil
        handled.insert(disk.bsdName)
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.mountWithExtension(
                bsdName: disk.bsdName, volumeName: disk.name, readOnly: false, resetJournal: true)
        }
    }

    func eject(_ disk: NTFSDisk) {
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.eject(bsdName: disk.bsdName)
        }
    }

    func reveal(_ disk: NTFSDisk) {
        if let path = disk.mount?.path {
            NSWorkspace.shared.open(path)
        }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: Any drive

    func mount(_ partition: Partition) {
        if let disk = partition.ntfsDisk {
            mount(disk)
            return
        }
        handled.insert(partition.bsdName)
        perform(on: partition.bsdName, name: partition.name) { [mounter] in
            try await mounter.mountDefault(bsdName: partition.bsdName)
        }
    }

    func unmount(_ partition: Partition) {
        handled.insert(partition.bsdName)
        perform(on: partition.bsdName, name: partition.name) { [mounter] in
            try await mounter.unmount(bsdName: partition.bsdName)
        }
    }

    func eject(_ disk: PhysicalDisk) {
        perform(on: disk.bsdName, name: disk.name) { [mounter] in
            try await mounter.eject(bsdName: disk.bsdName)
        }
    }

    func reveal(_ partition: Partition) {
        if let path = partition.mount?.path {
            NSWorkspace.shared.open(path)
        }
    }

    var formatContext: FormatContext {
        FormatContext(
            systemDisks: inventory.systemDiskNames,
            appDisk: inventory.appDiskName,
            busy: busy.union(formatting),
            allowsVirtualDisks: DiskInventory.showsVirtualDisks)
    }

    /// Internal and macOS drives: shown, but never unmounted, ejected or formatted.
    func isProtected(_ disk: PhysicalDisk) -> Bool {
        disk.isInternal || inventory.systemDiskNames.contains(disk.bsdName)
    }

    func canUnmount(_ partition: Partition, on disk: PhysicalDisk) -> Bool {
        partition.mount != nil && !isProtected(disk) && !busy.contains(partition.bsdName) && !formatting.contains(disk.bsdName)
    }

    func canEject(_ disk: PhysicalDisk) -> Bool {
        disk.isEjectable && !isProtected(disk) && !busy.contains(disk.bsdName) && !formatting.contains(disk.bsdName)
    }

    // MARK: Formatting

    func prepareFormat(_ target: FormatTarget) -> FormatPreparation? {
        let disk: PhysicalDisk? = switch target {
        case .disk(let name): inventory.physicalDisk(named: name)
        case .partition(let name): inventory.partition(named: name)?.disk
        }
        guard let disk else { return nil }
        let deviceName = FormatSafety.device(for: target, on: disk)
        guard let device = inventory.freshInfo(deviceName) else { return nil }
        let children = device.isWhole ? inventory.childNames(ofWhole: deviceName) : []
        return FormatSafety.prepare(target: target, disk: disk, device: device, children: children, context: formatContext)
    }

    func format(
        _ preparation: FormatPreparation, options: FormatOptions,
        progress: @escaping @MainActor (FormatStage) -> Void
    ) async throws {
        let diskName = preparation.disk.bsdName
        if let reason = FormatSafety.blockReason(for: preparation.target, on: preparation.disk, context: formatContext) {
            throw FormatError.blocked(reason.message)
        }
        let job = FormatPlanner.job(for: preparation, options: options)
        formatting.insert(diskName)
        defer {
            formatting.remove(diskName)
            finishFormat(on: diskName)
        }
        appLog.notice("Formatting \(String(describing: preparation.fingerprint), privacy: .public) as \(options.fileSystem.rawValue, privacy: .public): \(String(describing: job.steps), privacy: .public)")
        do {
            try await formatter.run(job, progress: progress)
            appLog.notice("Formatting \(diskName, privacy: .public) finished")
        } catch {
            appLog.error("Formatting \(diskName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Lets the usual mount logic pick up the freshly formatted partitions.
    private func finishFormat(on diskName: String) {
        for name in inventory.childNames(ofWhole: diskName) + [diskName] {
            handled.remove(name)
            reasons[name] = nil
            inventory.refresh(bsdName: name)
        }
        for partition in inventory.physicalDisk(named: diskName)?.partitions ?? [] {
            if let disk = partition.ntfsDisk {
                diskChanged(disk)
            }
        }
    }

    private func isBeingFormatted(_ bsdName: String) -> Bool {
        guard !formatting.isEmpty else { return false }
        if formatting.contains(bsdName) { return true }
        return inventory.partition(named: bsdName).map { formatting.contains($0.disk.bsdName) } ?? false
    }

    // MARK: Internals

    private func perform(on bsdName: String, name: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy.contains(bsdName) else { return }
        busy.insert(bsdName)
        lastError = nil
        Task {
            do {
                try await operation()
            } catch {
                appLog.error("\(bsdName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if error.localizedDescription.contains("is disabled") {
                    self.extensionStatus.noteExtensionDisabled()
                }
                self.lastError = String(localized: "“\(name)”: \(error.localizedDescription)")
            }
            self.busy.remove(bsdName)
            self.inventory.refresh(bsdName: bsdName)
        }
    }

    private func diskChanged(_ disk: NTFSDisk) {
        if disk.isMountedByExtension {
            extensionStatus.noteExtensionMounted()
        }
        if disk.isMountedByExtension, disk.mount?.isReadOnly == true, reasons[disk.bsdName] == nil,
           let pending = pendingReason, Date().timeIntervalSince(pending.date) < 60 {
            reasons[disk.bsdName] = pending.reason
            pendingReason = nil
        }
        guard !busy.contains(disk.bsdName), !isBeingFormatted(disk.bsdName) else { return }
        let action = MountPolicy.action(
            for: disk,
            writeEnabled: preferences.isWriteEnabled(disk.preferenceKey),
            alreadyHandled: handled.contains(disk.bsdName)
        )
        if case .mountWithExtension(let readOnly) = action {
            mount(disk, readOnly: readOnly)
        }
    }

    private func extensionReportedReadOnly(_ reason: ReadOnlyReason) {
        let candidates = inventory.disks.filter {
            $0.isMountedByExtension && $0.mount?.isReadOnly == true && reasons[$0.bsdName] == nil
        }
        if candidates.count == 1 {
            reasons[candidates[0].bsdName] = reason
        } else {
            pendingReason = (reason, Date())
        }
        notifier.post(title: String(localized: "NTFS drive opened read-only"), body: reason.advice)
    }
}
```

- [ ] **Step 8: Refuse to quit while formatting**

In `App/NTFSForMacApp.swift`, add to `AppDelegate`:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isFormatting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "A drive is being formatted")
        alert.informativeText = String(localized: "Wait until formatting finishes before quitting NTFS for Mac.")
        NSApp.activate()
        alert.runModal()
        return .terminateCancel
    }
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild ... test -quiet`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add -A App AppTests NTFSForMac.xcodeproj
git commit -m "Plan and run formats with fingerprint checks; refuse to quit mid-format"
```

---

### Task 7: Bundle the helpers into the app

**Files:**
- Create: `scripts/embed-helpers.sh`
- Modify: `project.yml`, `scripts/build-local.sh`, `scripts/release.sh`

**Interfaces:**
- Produces: `NTFS for Mac.app/Contents/Helpers/ntfs-format` and `ntfs-mkfs`, signed (by `build-local.sh` / Xcode / `release.sh`).

- [ ] **Step 1: Create `scripts/embed-helpers.sh`** (then `chmod +x scripts/embed-helpers.sh`)

```bash
#!/bin/bash
# Xcode build phase: builds the ntfs-format and ntfs-mkfs helpers from the Core
# package and copies them into Contents/Helpers, signed like the app.
set -euo pipefail

HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
SCRATCH="$DERIVED_FILE_DIR/helpers"
ARCH_FLAGS=()
for arch in $ARCHS; do
    ARCH_FLAGS+=(--arch "$arch")
done

# Xcode's build environment (SDKROOT, toolchain variables…) confuses SwiftPM.
swiftpm() {
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" DEVELOPER_DIR="$DEVELOPER_DIR" \
        /usr/bin/xcrun swift build --package-path "$SRCROOT/Core" --scratch-path "$SCRATCH" \
        -c release "${ARCH_FLAGS[@]}" "$@"
}

swiftpm --product ntfs-mkfs
swiftpm --product ntfs-format
BIN="$(swiftpm --show-bin-path)"

mkdir -p "$HELPERS"
for tool in ntfs-format ntfs-mkfs; do
    cp -f "$BIN/$tool" "$HELPERS/$tool"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$HELPERS/$tool"
    fi
done
```

- [ ] **Step 2: Add the build phase**

In `project.yml`, under `targets.NTFSForMac`, add:

```yaml
    postBuildScripts:
      - name: Embed format helpers
        script: '"$SRCROOT/scripts/embed-helpers.sh"'
        basedOnDependencyAnalysis: false
```

and under `targets.NTFSForMac.settings.base`:

```yaml
        ENABLE_USER_SCRIPT_SANDBOXING: NO
```

- [ ] **Step 3: Sign the helpers in `scripts/build-local.sh`**

Replace the line `# Inside out: the extension first, then the app that seals it.` and the extension `codesign` line after it with:

```bash
# Inside out: helpers and the extension first, then the app that seals them.
for tool in "$APP/Contents/Helpers/"*; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$tool"
done
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/Extensions/NTFSExtension.appex"
```

- [ ] **Step 4: Re-sign the helpers with a timestamp in `scripts/release.sh`**

After the `xcodebuild -exportArchive …` command and before `codesign --verify --deep --strict "$APP"`, insert:

```bash
# The build phase signs the helpers without a secure timestamp, which notarization requires.
for tool in "$APP/Contents/Helpers/"*; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$tool"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --preserve-metadata=entitlements,requirements,flags "$APP"
```

- [ ] **Step 5: Verify**

Run:
```bash
/tmp/XcodeGen/.build/release/xcodegen generate
scripts/build-local.sh
APP="build/DerivedData/Build/Products/Release/NTFS for Mac.app"
ls "$APP/Contents/Helpers"
lipo -archs "$APP/Contents/Helpers/ntfs-format"
codesign --verify --deep --strict "$APP" && echo signed
"$APP/Contents/Helpers/ntfs-format" --bogus; echo "exit $?"
```
Expected: `ntfs-format ntfs-mkfs`; `x86_64 arm64`; `signed`; `exit 64`.
Then run the app tests command again — still passes (helpers are built in Debug too).

- [ ] **Step 6: Commit**

```bash
git add scripts/embed-helpers.sh scripts/build-local.sh scripts/release.sh project.yml NTFSForMac.xcodeproj
git commit -m "Bundle ntfs-format and ntfs-mkfs in Contents/Helpers"
```

---

### Task 8: Main window

**Files:**
- Create: `App/Views/Main/Components.swift`, `SidebarView.swift`, `PartitionDetailView.swift`, `DiskDetailView.swift`, `MainWindowView.swift`, `App/Views/AllowWritingConfirmation.swift`
- Modify: `App/Views/WindowPresenter.swift`, `App/NTFSForMacApp.swift`, `App/Views/DiskRowView.swift`

**Interfaces:**
- Consumes: AppModel API from Task 6, inventory from Task 4, messages from Task 5.
- Produces: `WindowPresenter.showMain()`, `MainWindowView(model:)`, `SidebarSelection`, `AllowWritingConfirmation.run(model:disk:)`, `DiskState.color`, shared components (`Badge`, `LegendItem`, `SegmentedBar`, `InfoRow`, `InfoGrid`, `ErrorBanner`, `DriveIcon`). Task 9 adds `FormatSheet`; until then the toolbar's Format… button sets `formatTarget` and the `.sheet` shows `FormatSheet` — so create Task 9's file before building, or build after Task 9. **Order: write Task 8 and Task 9 files, then build and test once at the end of Task 9.**

- [ ] **Step 1: Shared components — `App/Views/Main/Components.swift`**

```swift
import SwiftUI

struct Badge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A rounded bar split into coloured segments: used space, or a partition map.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = segments.count > 1 ? 2 : 0
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    segment.color.frame(width: max(3, available * min(max(segment.fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.15))
        .clipShape(.rect(cornerRadius: height / 2))
    }
}

struct InfoRow: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

struct InfoGrid: View {
    let rows: [InfoRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                GridRow {
                    cell(rows[index])
                    if index + 1 < rows.count {
                        cell(rows[index + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private func cell(_ row: InfoRow) -> some View {
        HStack {
            Text(row.label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(row.value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.yellow.opacity(0.12))
    }
}

struct DriveIcon: View {
    let systemImage: String
    let colors: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
```

- [ ] **Step 2: Shared "Allow Writing Anyway" confirmation — `App/Views/AllowWritingConfirmation.swift`**

Move the alert out of `DiskRowView` (strings unchanged, so existing translations still apply):

```swift
import AppKit

@MainActor
enum AllowWritingConfirmation {
    static func run(model: AppModel, disk: NTFSDisk) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Allow writing to “\(disk.name)”?")
        alert.informativeText = String(localized: "This drive wasn't ejected safely, or Windows didn't shut down cleanly. To write to it, NTFS for Mac clears the NTFS journal, and changes Windows hadn't finished saving may be lost.\n\nIf the drive belongs to a Windows PC that is hibernating or uses Fast Startup, shut that PC down fully instead.")
        alert.addButton(withTitle: String(localized: "Allow Writing"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.allowWritingAnyway(disk)
        }
    }
}
```

In `App/Views/DiskRowView.swift`: delete `confirmAllowWriting()`, call `AllowWritingConfirmation.run(model: model, disk: disk)` instead, and replace the private `stateColor` property with a shared extension at the end of the file (use `state.color` where `stateColor` was):

```swift
extension DiskState {
    var color: Color {
        switch self {
        case .readWrite: .green
        case .readOnly, .systemReadOnly: .orange
        case .notMounted: .secondary
        case .unrecognized: .red
        }
    }
}
```

- [ ] **Step 3: Sidebar — `App/Views/Main/SidebarView.swift`**

```swift
import SwiftUI

enum SidebarSelection: Hashable {
    case disk(String)
    case partition(String)
}

struct SidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        let disks = model.inventory.sidebarDisks
        List(selection: $selection) {
            section("External", disks.filter { !$0.isInternal })
            section("Internal", disks.filter(\.isInternal))
        }
        .listStyle(.sidebar)
        .overlay {
            if disks.isEmpty {
                ContentUnavailableView(
                    "No Drives", systemImage: "externaldrive",
                    description: Text("Connect a drive and it will appear here."))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ disks: [PhysicalDisk]) -> some View {
        if !disks.isEmpty {
            Section(title) {
                ForEach(disks) { disk in
                    DiskSidebarRow(model: model, disk: disk)
                        .tag(SidebarSelection.disk(disk.bsdName))
                    ForEach(disk.sidebarPartitions) { partition in
                        PartitionSidebarRow(model: model, partition: partition)
                            .padding(.leading, 14)
                            .tag(SidebarSelection.partition(partition.bsdName))
                    }
                }
            }
        }
    }
}

private struct DiskSidebarRow: View {
    let model: AppModel
    let disk: PhysicalDisk

    var body: some View {
        HStack {
            Label(disk.name, systemImage: disk.isInternal ? "internaldrive" : "externaldrive")
                .lineLimit(1)
            Spacer()
            if model.busy.contains(disk.bsdName) || model.formatting.contains(disk.bsdName) {
                ProgressView().controlSize(.small)
            } else if model.isProtected(disk) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("Protected")
                    .accessibilityLabel("Protected")
            } else if model.canEject(disk) {
                Button {
                    model.eject(disk)
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .help("Eject")
                .accessibilityLabel("Eject")
            }
        }
    }
}

private struct PartitionSidebarRow: View {
    let model: AppModel
    let partition: Partition

    var body: some View {
        HStack {
            Label(partition.name, systemImage: partition.mount == nil ? "externaldrive" : "externaldrive.fill")
                .lineLimit(1)
                .opacity(partition.mount == nil ? 0.6 : 1)
            Spacer()
            if model.busy.contains(partition.bsdName) {
                ProgressView().controlSize(.small)
            }
            Text(partition.fileSystem.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Partition detail — `App/Views/Main/PartitionDetailView.swift`**

```swift
import NTFSShared
import SwiftUI

struct PartitionDetailView: View {
    let model: AppModel
    let partition: Partition
    let disk: PhysicalDisk

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let mount = partition.mount, mount.totalBytes > 0 {
                    usage(mount)
                }
                InfoGrid(rows: rows)
                if let ntfs = partition.ntfsDisk {
                    NTFSOptionsView(model: model, disk: ntfs)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DriveIcon(systemImage: "externaldrive.fill", colors: partition.mount == nil ? [.gray, .secondary] : [.blue, .indigo])
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(partition.name).font(.title2.bold()).lineLimit(1)
                    Badge(text: partition.fileSystem.label)
                    Badge(text: status.text, tint: status.color)
                }
                Text([disk.name, partition.bsdName, disk.connection].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: (text: String, color: Color) {
        if let ntfs = partition.ntfsDisk {
            let state = model.state(of: ntfs)
            return (state.label, state.color)
        }
        guard let mount = partition.mount else { return (String(localized: "Not mounted"), .secondary) }
        return mount.isReadOnly ? (String(localized: "Read-only"), .orange) : (String(localized: "Read & write"), .green)
    }

    private func usage(_ mount: NTFSDisk.Mount) -> some View {
        let used = mount.totalBytes - min(mount.freeBytes, mount.totalBytes)
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedBar(segments: [
                .init(id: "used", fraction: Double(used) / Double(mount.totalBytes), color: .accentColor),
            ])
            HStack(spacing: 16) {
                LegendItem(color: .accentColor, text: String(localized: "Used \(used.formatted(.byteCount(style: .file)))"))
                LegendItem(color: .secondary.opacity(0.3), text: String(localized: "Free \(mount.freeBytes.formatted(.byteCount(style: .file)))"))
                Spacer()
                Text("Total \(mount.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rows: [InfoRow] {
        [
            InfoRow(label: String(localized: "Mounted at"), value: partition.mount?.path.path ?? String(localized: "Not mounted")),
            InfoRow(label: String(localized: "Capacity"), value: (partition.mount?.totalBytes ?? partition.size).formatted(.byteCount(style: .file))),
            InfoRow(label: String(localized: "Device"), value: partition.bsdName),
            InfoRow(label: String(localized: "Driver"), value: driver),
            InfoRow(label: "UUID", value: partition.volumeUUID ?? "—"),
        ]
    }

    private var driver: String {
        guard let mount = partition.mount else { return "—" }
        switch mount.fileSystemType {
        case Identifiers.fileSystemTypeName: return "NTFS for Mac"
        case Identifiers.systemDriverTypeName: return String(localized: "macOS (read-only)")
        default: return "macOS"
        }
    }
}

/// "Allow writing" and read-only advice for an NTFS partition.
struct NTFSOptionsView: View {
    let model: AppModel
    let disk: NTFSDisk

    private var isBusy: Bool { model.busy.contains(disk.bsdName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if disk.isRecognized {
                Toggle(isOn: Binding(
                    get: { model.isWriteEnabled(disk) },
                    set: { model.setWriteEnabled($0, for: disk) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow writing")
                        Text("Turn off to always mount this drive read-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(isBusy || !disk.isWritableMedia)
            }
            if case .readOnly(let reason?) = model.state(of: disk), reason != .requested {
                Text(reason.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == .uncleanJournal, model.isWriteEnabled(disk), !isBusy {
                    Button("Allow Writing Anyway…") { AllowWritingConfirmation.run(model: model, disk: disk) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
```

- [ ] **Step 5: Disk detail — `App/Views/Main/DiskDetailView.swift`**

```swift
import SwiftUI

struct DiskDetailView: View {
    let model: AppModel
    let disk: PhysicalDisk

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    DriveIcon(
                        systemImage: disk.isInternal ? "internaldrive.fill" : "externaldrive.fill",
                        colors: [Color(white: 0.45), Color(white: 0.2)])
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(disk.name).font(.title2.bold()).lineLimit(1)
                            if model.isProtected(disk) {
                                Badge(text: String(localized: "Protected"), tint: .secondary)
                            }
                        }
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Partition map").font(.headline)
                    SegmentedBar(segments: segments, height: 22)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(disk.mapPartitions.enumerated()), id: \.element.id) { index, partition in
                            LegendItem(
                                color: color(index, partition),
                                text: "\(partition.name) · \(partition.fileSystem.label) · \(partition.size.formatted(.byteCount(style: .file)))")
                        }
                    }
                }

                InfoGrid(rows: [
                    InfoRow(label: String(localized: "Capacity"), value: disk.size.formatted(.byteCount(style: .file))),
                    InfoRow(label: String(localized: "Connection"), value: disk.connection ?? "—"),
                    InfoRow(label: String(localized: "Partition scheme"), value: disk.scheme.label),
                    InfoRow(label: String(localized: "Partitions"), value: String(disk.sidebarPartitions.count)),
                    InfoRow(label: String(localized: "Device"), value: disk.bsdName),
                ])
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        [
            disk.isInternal ? String(localized: "Internal drive") : String(localized: "External drive"),
            disk.connection,
            disk.scheme.label,
            disk.bsdName,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var segments: [SegmentedBar.Segment] {
        disk.mapPartitions.enumerated().map { index, partition in
            SegmentedBar.Segment(
                id: partition.bsdName,
                fraction: disk.size == 0 ? 0 : Double(partition.size) / Double(disk.size),
                color: color(index, partition))
        }
    }

    private func color(_ index: Int, _ partition: Partition) -> Color {
        partition.isHidden && !partition.isAPFSStore ? .gray : Self.palette[index % Self.palette.count]
    }
}
```

- [ ] **Step 6: Main window — `App/Views/Main/MainWindowView.swift`**

```swift
import SwiftUI

struct MainWindowView: View {
    let model: AppModel
    @State private var selection: SidebarSelection?
    @State private var formatTarget: FormatTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.dismissError() }
                }
                detail
            }
        }
        .toolbar { toolbar }
        .sheet(item: $formatTarget) { target in
            FormatSheet(model: model, target: target)
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear(perform: selectDefault)
        .onChange(of: model.inventory.tree) { _, _ in keepSelectionValid() }
        .task {
            while !Task.isCancelled {
                model.inventory.refreshUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let found = selectedPartition {
            PartitionDetailView(model: model, partition: found.partition, disk: found.disk)
        } else if case .disk = selection, let disk = selectedDisk {
            DiskDetailView(model: model, disk: disk)
        } else {
            ContentUnavailableView("Select a drive or partition", systemImage: "externaldrive")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let found = selectedPartition {
                if found.partition.mount != nil {
                    Button("Unmount", systemImage: "eject.circle") { model.unmount(found.partition) }
                        .disabled(!model.canUnmount(found.partition, on: found.disk))
                } else {
                    Button("Mount", systemImage: "arrow.up.circle") { model.mount(found.partition) }
                        .disabled(!found.partition.isRecognized || model.isProtected(found.disk)
                                  || model.busy.contains(found.partition.bsdName))
                }
            }
            Button("Eject", systemImage: "eject") {
                if let disk = selectedDisk { model.eject(disk) }
            }
            .disabled(!(selectedDisk.map(model.canEject) ?? false))
            Button("Show in Finder", systemImage: "folder") {
                if let partition = selectedPartition?.partition { model.reveal(partition) }
            }
            .disabled(selectedPartition?.partition.mount == nil)
            Button("Format…", systemImage: "eraser") { formatTarget = currentFormatTarget }
                .disabled(currentFormatTarget == nil || formatBlock != nil)
                .help(formatBlock?.message ?? String(localized: "Erase and format"))
        }
    }

    private var selectedPartition: (partition: Partition, disk: PhysicalDisk)? {
        guard case .partition(let name)? = selection else { return nil }
        return model.inventory.partition(named: name)
    }

    private var selectedDisk: PhysicalDisk? {
        switch selection {
        case .disk(let name)?: model.inventory.physicalDisk(named: name)
        case .partition(let name)?: model.inventory.partition(named: name)?.disk
        case nil: nil
        }
    }

    private var currentFormatTarget: FormatTarget? {
        switch selection {
        case .disk(let name)?: .disk(name)
        case .partition(let name)?: .partition(name)
        case nil: nil
        }
    }

    private var formatBlock: FormatBlock? {
        guard let target = currentFormatTarget, let disk = selectedDisk else { return nil }
        return FormatSafety.blockReason(for: target, on: disk, context: model.formatContext)
    }

    private func selectDefault() {
        guard selection == nil else { return }
        let disks = model.inventory.sidebarDisks
        let disk = disks.first { !$0.isInternal } ?? disks.first
        if let partition = disk?.sidebarPartitions.first {
            selection = .partition(partition.bsdName)
        } else if let disk {
            selection = .disk(disk.bsdName)
        }
    }

    private func keepSelectionValid() {
        let isValid = switch selection {
        case .partition(let name)?: model.inventory.partition(named: name) != nil
        case .disk(let name)?: model.inventory.physicalDisk(named: name) != nil
        case nil: false
        }
        if !isValid {
            selection = nil
            selectDefault()
        }
    }
}
```

- [ ] **Step 7: Show the window — `App/Views/WindowPresenter.swift`**

Replace the file with:

```swift
import AppKit
import SwiftUI

/// Shows the main, welcome and settings windows. The app has no Dock icon
/// except while the main window is open.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let welcomeSeenKey = "WelcomeSeen"

    private let model: AppModel
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showMain() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        model.extensionStatus.refresh()
        welcomeWindow = present(welcomeWindow, title: String(localized: "Welcome to NTFS for Mac")) {
            WelcomeView(model: model) { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
                self?.welcomeWindow?.close()
                self?.showMain()
            }
        }
    }

    func showSettings() {
        settingsWindow = present(settingsWindow, title: String(localized: "NTFS for Mac Settings")) {
            SettingsView(model: model)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(rootView: MainWindowView(model: model))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.title = "NTFS for Mac"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, model.isFormatting else { return true }
        NSSound.beep()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func present(_ existing: NSWindow?, title: String, @ViewBuilder content: () -> some View) -> NSWindow {
        let window = existing ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
```

- [ ] **Step 8: Launch behavior and the Settings menu item — `App/NTFSForMacApp.swift`**

Replace the `body` scene with:

```swift
    var body: some Scene {
        // The menu bar icon comes from `StatusItemController`; this scene backs
        // the Settings… item of the main menu while the main window is open.
        Settings { SettingsView(model: appDelegate.model) }
    }
```

In `AppDelegate.applicationDidFinishLaunching`, replace

```swift
        if !UserDefaults.standard.bool(forKey: WindowPresenter.welcomeSeenKey) {
            windows.showWelcome()
        }
```

with

```swift
        if !UserDefaults.standard.bool(forKey: WindowPresenter.welcomeSeenKey) {
            windows.showWelcome()
        } else if !launchedAsLoginItem {
            windows.showMain()
        }
```

replace `applicationShouldHandleReopen` with

```swift
    /// Opening the app again from Finder while it's running shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showMain()
        return false
    }
```

and add

```swift
    /// Started by "Open at login" rather than by the user.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
```

- [ ] **Step 9: Continue with Task 9 before building** (the main window references `FormatSheet`).

---

### Task 9: Format sheet

**Files:**
- Create: `App/Views/Main/FormatSheet.swift`

**Interfaces:**
- Consumes: `AppModel.prepareFormat`, `AppModel.format`, `FormatPreparation`, `VolumeNameRule`, messages.

- [ ] **Step 1: Implement `App/Views/Main/FormatSheet.swift`**

```swift
import SwiftUI

struct FormatSheet: View {
    let model: AppModel
    let target: FormatTarget

    @Environment(\.dismiss) private var dismiss
    @State private var preparation: FormatPreparation?
    @State private var name = ""
    @State private var fileSystem: FormatFileSystem = .ntfs
    @State private var scheme: PartitionScheme = .gpt
    @State private var clusterSize = 0
    @State private var quick = true
    @State private var showsAdvanced = false
    @State private var confirmation = ""
    @State private var phase: Phase = .editing

    private enum Phase: Equatable {
        case editing
        case running(FormatStage)
        case failed(String)
        case finished
    }

    private static let clusterSizes = [4096, 8192, 16384, 32768, 65536]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preparation {
                content(preparation)
            } else {
                Text("This drive is no longer available.")
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .interactiveDismissDisabled(isRunning)
        .onAppear(perform: prepare)
        .onChange(of: fileSystem) { _, newValue in
            if newValue == .apfs { scheme = .gpt }
        }
    }

    @ViewBuilder
    private func content(_ preparation: FormatPreparation) -> some View {
        if preparation.target.isDisk {
            Text("Erase “\(preparation.displayName)”?").font(.title3.bold())
        } else {
            Text("Format “\(preparation.displayName)”?").font(.title3.bold())
        }

        WarningBox(preparation: preparation)

        if let block = preparation.block {
            Label(block.message, systemImage: "lock.fill").foregroundStyle(.secondary)
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField("Name", text: $name).labelsHidden()
            }
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("Format", selection: $fileSystem) {
                    ForEach(preparation.fileSystems) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if preparation.target.isDisk {
                GridRow {
                    Text("Scheme").foregroundStyle(.secondary)
                    Picker("Scheme", selection: $scheme) {
                        Text(PartitionScheme.gpt.label).tag(PartitionScheme.gpt)
                        Text(PartitionScheme.mbr.label).tag(PartitionScheme.mbr)
                    }
                    .labelsHidden()
                    .disabled(fileSystem == .apfs)
                }
            }
        }
        .disabled(isRunning || phase == .finished)

        if fileSystem == .ntfs {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Cluster size", selection: $clusterSize) {
                        Text("Automatic").tag(0)
                        ForEach(Self.clusterSizes, id: \.self) { size in
                            Text(Int64(size).formatted(.byteCount(style: .memory))).tag(size)
                        }
                    }
                    Toggle("Quick format", isOn: $quick)
                    if !quick {
                        Text("A full format writes zeros over the whole partition and can take a long time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .disabled(isRunning || phase == .finished)
        }

        if case .failure(let error) = nameCheck, !name.isEmpty {
            Text(error.message).font(.caption).foregroundStyle(.red)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Type “\(preparation.displayName)” to confirm").font(.callout)
            TextField(preparation.displayName, text: $confirmation)
                .disabled(isRunning || phase == .finished)
        }

        switch phase {
        case .editing:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage.label)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .finished:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }

        HStack {
            Spacer()
            if phase == .finished {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button("Erase and Format", role: .destructive) { start(preparation) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canStart(preparation))
            }
        }
    }

    private var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    private var nameCheck: Result<String, VolumeNameError> {
        VolumeNameRule.validate(name, for: fileSystem)
    }

    private func canStart(_ preparation: FormatPreparation) -> Bool {
        guard phase == .editing, preparation.block == nil, preparation.fileSystems.contains(fileSystem),
              case .success = nameCheck
        else { return false }
        return confirmation.trimmingCharacters(in: .whitespaces) == preparation.displayName
    }

    private func prepare() {
        guard preparation == nil, let prepared = model.prepareFormat(target) else { return }
        preparation = prepared
        name = prepared.suggestedName
        fileSystem = prepared.fileSystems.first ?? .exfat
    }

    private func start(_ preparation: FormatPreparation) {
        guard case .success(let finalName) = nameCheck else { return }
        let options = FormatOptions(
            name: finalName, fileSystem: fileSystem, scheme: scheme,
            clusterSize: fileSystem == .ntfs && clusterSize != 0 ? clusterSize : nil,
            quick: fileSystem != .ntfs || quick)
        phase = .running(.checking)
        Task {
            do {
                try await model.format(preparation, options: options) { stage in
                    phase = .running(stage)
                }
                phase = .finished
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

private struct WarningBox: View {
    let preparation: FormatPreparation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline).bold()
            Text(detail)
            if !preparation.unaffected.isEmpty {
                Text("Not affected: \(preparation.unaffected.map(\.name).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            ForEach(preparation.warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.callout)
        .foregroundStyle(Color.red)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private var headline: String {
        let name = preparation.displayName
        if let used = preparation.usedBytes {
            return String(localized: "All \(used.formatted(.byteCount(style: .file))) of data on “\(name)” will be erased permanently.")
        }
        return String(localized: "Everything on “\(name)” will be erased permanently.")
    }

    private var detail: String {
        let size = preparation.device.size.formatted(.byteCount(style: .file))
        if preparation.target.isDisk {
            return String(localized: "Whole drive \(preparation.device.bsdName) · \(size) · every partition and volume on it.")
        }
        return String(localized: "Partition \(preparation.device.bsdName) · \(size) · on \(preparation.disk.name).")
    }
}
```

- [ ] **Step 2: Build and run all tests**

Run: `/tmp/XcodeGen/.build/release/xcodegen generate && xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData test -quiet`
Expected: builds with no warnings from the new files; all tests pass.

- [ ] **Step 3: Manual check of the window (New Volume only, no formatting of real disks)**

Build and install (install cycle from Task 4, Step 6). Open the app from Finder.
Expected:
- The main window opens with a Dock icon; the sidebar shows "Ổ ngoài/External" with the external SSD and its partitions, and "Internal" with a lock.
- Selecting "New Volume" shows NTFS + Read & write badges, the usage bar, the info grid and the "Allow writing" switch.
- Selecting the SSD shows the partition map.
- Selecting an internal disk: Unmount/Eject/Format… are disabled; hovering Format… explains why.
- Unmount and Mount "New Volume" from the toolbar: it remounts read-write via the extension (`mount | grep "New Volume"` shows `ntfsrw`). Do not unmount or eject anything else.
- Format… on "New Volume" opens the sheet with the red warning stating its used size and that SSD-PUBLIC is not affected; the red button stays disabled until the exact name is typed. **Press Cancel — do not format.**
- Closing the window removes the Dock icon; the menu bar icon remains.

- [ ] **Step 4: Manual format test on a scratch image (Debug build)**

```bash
xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac -configuration Debug -derivedDataPath build/DebugData CODE_SIGNING_ALLOWED=NO build -quiet
defaults write com.docuong.ntfsformac ShowVirtualDisks -bool YES
mkdir -p /tmp/nfm-manual && hdiutil create -quiet -size 300m -fs ExFAT -volname MANUAL -layout GPTSPUD /tmp/nfm-manual/manual.dmg
hdiutil attach /tmp/nfm-manual/manual.dmg
```
Quit the installed app, open `build/DebugData/Build/Products/Debug/NTFS for Mac.app`. In the sidebar select the disk image's "MANUAL" partition (Disk Image device — check the device name in the detail pane matches the `hdiutil attach` output) and format it as NTFS (the admin dialog appears; the user enters their password). Expected: stages show, then Done; the partition remounts as NTFS read-write. Then format the image's whole disk as exFAT/MBR. Afterwards:

```bash
hdiutil detach /tmp/nfm-manual/manual.dmg 2>/dev/null || true; rm -rf /tmp/nfm-manual
defaults delete com.docuong.ntfsformac ShowVirtualDisks
```

- [ ] **Step 5: Commit**

```bash
git add -A App NTFSForMac.xcodeproj
git commit -m "Add the main window: drive sidebar, details, toolbar and format sheet"
```

---

### Task 10: Slim menu bar

**Files:**
- Modify: `App/Views/MenuContentView.swift`, `App/Views/DiskRowView.swift`

- [ ] **Step 1: Slim the row**

In `App/Views/DiskRowView.swift`, delete the usage block (`if let mount = disk.mount, mount.totalBytes > 0 { … }`) and the `Toggle("Allow writing", …)` block. Keep the header row, the actions and the "Allow Writing Anyway…" button (which calls `AllowWritingConfirmation.run`).

- [ ] **Step 2: Add "Open NTFS for Mac…"**

In `App/Views/MenuContentView.swift`, replace the block after `Divider()` with:

```swift
            Button {
                windows.showMain()
            } label: {
                Label("Open NTFS for Mac…", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            HStack {
                Button("Settings…") { windows.showSettings() }
                Button("Setup Guide") { windows.showWelcome() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
```

- [ ] **Step 3: Build, test, manual check**

Run the app tests command. Install and open the menu: only NTFS drives with status, Eject and Finder buttons; "Open NTFS for Mac…" opens the main window.

- [ ] **Step 4: Commit**

```bash
git add App/Views NTFSForMac.xcodeproj
git commit -m "Slim the menu bar panel and link it to the main window"
```

---

### Task 11: Vietnamese translations

**Files:**
- Modify: `App/Localizable.xcstrings`

- [ ] **Step 1: Let Xcode extract the new keys**

Run: `xcodebuild -project NTFSForMac.xcodeproj -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO -destination "platform=macOS" -derivedDataPath build/TestData build -quiet`
Expected: `App/Localizable.xcstrings` gains the new English keys.

- [ ] **Step 2: Add the translations**

Run:

```bash
python3 - <<'EOF'
import json
path = "App/Localizable.xcstrings"
vi = {
    "External": "Ổ ngoài",
    "Internal": "Trong máy",
    "No Drives": "Không có ổ nào",
    "Connect a drive and it will appear here.": "Cắm một ổ vào máy, ổ sẽ hiện ở đây.",
    "Protected": "Được bảo vệ",
    "Select a drive or partition": "Chọn một ổ hoặc phân vùng",
    "Unmount": "Tháo",
    "Format…": "Định dạng…",
    "Erase and format": "Xóa và định dạng",
    "Used %@": "Đã dùng %@",
    "Free %@": "Trống %@",
    "Total %@": "Tổng %@",
    "Mounted at": "Gắn tại",
    "Capacity": "Dung lượng",
    "Device": "Thiết bị",
    "Driver": "Driver",
    "macOS (read-only)": "macOS (chỉ đọc)",
    "Turn off to always mount this drive read-only.": "Tắt để luôn gắn ổ này ở chế độ chỉ đọc.",
    "Partition map": "Bản đồ phân vùng",
    "Connection": "Kết nối",
    "Partition scheme": "Bảng phân vùng",
    "Partitions": "Số phân vùng",
    "Internal drive": "Ổ trong máy",
    "External drive": "Ổ ngoài",
    "GUID Partition Map": "GUID (GPT)",
    "Master Boot Record": "Master Boot Record (MBR)",
    "None": "Không có",
    "Untitled": "Không tên",
    "Erase “%@”?": "Xóa toàn bộ “%@”?",
    "Format “%@”?": "Định dạng “%@”?",
    "Name": "Tên",
    "Format": "Định dạng",
    "Scheme": "Bảng phân vùng",
    "Advanced": "Nâng cao",
    "Cluster size": "Kích thước cluster",
    "Automatic": "Tự động",
    "Quick format": "Định dạng nhanh",
    "A full format writes zeros over the whole partition and can take a long time.": "Định dạng đầy đủ ghi số 0 lên toàn bộ phân vùng và có thể mất nhiều thời gian.",
    "Type “%@” to confirm": "Gõ “%@” để xác nhận",
    "Done": "Xong",
    "Erase and Format": "Xóa và định dạng",
    "Close": "Đóng",
    "This drive is no longer available.": "Ổ này không còn kết nối.",
    "All %@ of data on “%@” will be erased permanently.": "Toàn bộ %1$@ dữ liệu trên “%2$@” sẽ bị xóa vĩnh viễn.",
    "Everything on “%@” will be erased permanently.": "Mọi dữ liệu trên “%@” sẽ bị xóa vĩnh viễn.",
    "Whole drive %@ · %@ · every partition and volume on it.": "Toàn bộ ổ %1$@ · %2$@ · mọi phân vùng và ổ con trên đó.",
    "Partition %@ · %@ · on %@.": "Phân vùng %1$@ · %2$@ · trên %3$@.",
    "Not affected: %@": "Không bị ảnh hưởng: %@",
    "This drive holds Time Machine backups.": "Ổ này chứa bản sao lưu Time Machine.",
    "The amount of data couldn't be determined — assume it holds important files.": "Không xác định được dữ liệu — hãy coi như có dữ liệu quan trọng.",
    "These APFS volumes will also be erased: %@": "Các ổ APFS sau cũng sẽ bị xóa: %@",
    "Checking the drive…": "Đang kiểm tra ổ…",
    "Unmounting…": "Đang tháo…",
    "Formatting…": "Đang định dạng…",
    "Mounting…": "Đang gắn…",
    "Enter a name.": "Hãy nhập tên.",
    "The name can have at most %lld characters.": "Tên chỉ được tối đa %lld ký tự.",
    "The name can't contain “%@”.": "Tên không được chứa “%@”.",
    "FAT32 names can only use English letters, digits and simple symbols.": "Tên FAT32 chỉ được dùng chữ cái không dấu, chữ số và ký hiệu đơn giản.",
    "The drive changed since this window opened. Nothing was erased.": "Ổ đã thay đổi kể từ khi mở hộp thoại; không có gì bị xóa.",
    "The drive is in use. Quit the apps using it and try again. (%@)": "Ổ đang được dùng. Hãy đóng các ứng dụng đang dùng ổ rồi thử lại. (%@)",
    "Formatting was cancelled. Nothing was erased.": "Đã hủy định dạng. Không có gì bị xóa.",
    "The new partition could not be found. The drive may not be usable; format it again.": "Không tìm thấy phân vùng mới. Ổ có thể chưa dùng được; hãy định dạng lại.",
    "Formatting failed: %@": "Định dạng thất bại: %@",
    "The drive was erased and formatted as exFAT, but formatting it as NTFS failed: %@": "Ổ đã được xóa và định dạng exFAT, nhưng bước định dạng NTFS thất bại: %@",
    "Internal error: invalid format request.": "Lỗi nội bộ: yêu cầu định dạng không hợp lệ.",
    "The partition is no longer connected. Nothing was erased.": "Phân vùng không còn kết nối. Không có gì bị xóa.",
    "Only a partition can be formatted as NTFS this way. Nothing was erased.": "Chỉ có thể định dạng NTFS cho một phân vùng theo cách này. Không có gì bị xóa.",
    "Internal drives are protected. Nothing was erased.": "Ổ trong máy được bảo vệ. Không có gì bị xóa.",
    "This drive holds macOS. Nothing was erased.": "Ổ này chứa macOS. Không có gì bị xóa.",
    "The drive is write-protected. Nothing was erased.": "Ổ đang được chống ghi. Không có gì bị xóa.",
    "The partition is still in use. Quit the apps using it and try again. Nothing was erased.": "Phân vùng vẫn đang được dùng. Hãy đóng các ứng dụng đang dùng nó rồi thử lại. Không có gì bị xóa.",
    "The name isn't valid for NTFS. Nothing was erased.": "Tên không hợp lệ với NTFS. Không có gì bị xóa.",
    "The cluster size isn't valid for this drive. Nothing was erased.": "Kích thước cluster không hợp lệ với ổ này. Không có gì bị xóa.",
    "This kind of partition can't be formatted as NTFS. Nothing was erased.": "Loại phân vùng này không định dạng NTFS được. Không có gì bị xóa.",
    "The drive's partition table looks different than expected, so NTFS for Mac stopped.": "Bảng phân vùng của ổ khác với dự kiến nên NTFS for Mac đã dừng lại.",
    "The drive couldn't be read or written.": "Không đọc hoặc ghi được ổ.",
    "Creating the NTFS file system failed. The partition may not be usable; format it again.": "Tạo hệ thống file NTFS thất bại. Phân vùng có thể chưa dùng được; hãy định dạng lại.",
    "Internal drives are protected and can't be formatted.": "Ổ trong máy được bảo vệ, không thể định dạng.",
    "This drive holds macOS and can't be formatted.": "Ổ này chứa macOS, không thể định dạng.",
    "NTFS for Mac is running from this drive.": "NTFS for Mac đang chạy từ ổ này.",
    "The drive is write-protected.": "Ổ đang được chống ghi.",
    "Another operation is running on this drive.": "Ổ đang có thao tác khác chạy.",
    "Disk images can't be formatted.": "Không định dạng ảnh đĩa.",
    "This partition can't be formatted.": "Phân vùng này không thể định dạng.",
    "Open NTFS for Mac…": "Mở NTFS for Mac…",
    "A drive is being formatted": "Một ổ đang được định dạng",
    "Wait until formatting finishes before quitting NTFS for Mac.": "Hãy chờ định dạng xong rồi mới thoát NTFS for Mac.",
}
with open(path, encoding="utf-8") as f:
    catalog = json.load(f)
strings = catalog["strings"]
missing = [key for key in vi if key not in strings]
for key, value in vi.items():
    entry = strings.setdefault(key, {})
    entry["localizations"] = {"vi": {"stringUnit": {"state": "translated", "value": value}}}
with open(path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    f.write("\n")
print("keys not extracted by Xcode (check spelling against the code):", missing)
EOF
```

Expected: `keys not extracted by Xcode …: []`. Any listed key means the Swift literal and the dictionary differ — fix the dictionary to match the code exactly and rerun.

- [ ] **Step 3: Check nothing new is left untranslated**

```bash
python3 - <<'EOF'
import json
strings = json.load(open("App/Localizable.xcstrings", encoding="utf-8"))["strings"]
todo = [k for k, v in strings.items() if v.get("shouldTranslate", True) and "vi" not in v.get("localizations", {})]
print("\n".join(todo) or "all translated")
EOF
```
Expected: `all translated`, or only strings that need no translation (e.g. `UUID`) — mark those `"shouldTranslate" : false` in the catalog.

- [ ] **Step 4: Manual check in Vietnamese**

Install, set the app language to Tiếng Việt in Settings, reopen; the main window, sheet and menu show Vietnamese text.

- [ ] **Step 5: Commit**

```bash
git add App/Localizable.xcstrings
git commit -m "Translate the disk manager and format sheet into Vietnamese"
```

---

### Task 12: Format integration test on scratch images

**Files:**
- Create: `scripts/format-integration-test.sh`

- [ ] **Step 1: Write the script** (then `chmod +x scripts/format-integration-test.sh`)

```bash
#!/bin/bash
# Formats scratch disk images exactly as NTFS for Mac does — ntfs-format for
# NTFS (GPT and MBR, quick and full) and diskutil for the other formats — and
# checks every result. It touches only the disk images it creates, and checks
# each device name against them before any destructive command.
#
# Requires the app in /Applications with the extension enabled (NTFS results
# are checked by mounting them). Asks once for an administrator password
# through the macOS dialog.
# Usage: scripts/format-integration-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $EUID -ne 0 ]]; then
    swift build --package-path Core -c release --product ntfs-mkfs -q
    swift build --package-path Core -c release --product ntfs-format -q
    BIN="$(swift build --package-path Core -c release --show-bin-path)"
    LOG="$(mktemp /tmp/ntfs-ftest-log.XXXXXX)"
    APP_WAS_RUNNING=false
    if pgrep -xq "NTFS for Mac"; then
        APP_WAS_RUNNING=true
        osascript -e 'quit app "NTFS for Mac"'
    fi
    status=0
    osascript -e "do shell script \"BIN='$BIN' '$PWD/scripts/format-integration-test.sh' > '$LOG' 2>&1\" with administrator privileges" \
        >/dev/null || status=$?
    cat "$LOG"
    rm -f "$LOG"
    if $APP_WAS_RUNNING; then
        open -g -a "NTFS for Mac" || true
    fi
    exit $status
fi

: "${BIN:?run this script without sudo}"
FORMAT="$BIN/ntfs-format"
WORK="$(cd "$(mktemp -d /tmp/ntfs-ftest.XXXXXX)" && pwd -P)"
MNT="$WORK/mnt"
IMAGES=()
DEV=""

cleanup() {
    if mount | grep -q " on $MNT "; then
        umount "$MNT" 2>/dev/null || true
    fi
    for dev in "${IMAGES[@]+"${IMAGES[@]}"}"; do
        hdiutil detach "$dev" -force -quiet || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--> $*"; }

# Creates and attaches an image; sets DEV to its whole-disk node, e.g. disk12.
new_image() { # name size layout fs
    local image="$WORK/$1.dmg"
    hdiutil create -quiet -size "$2" -layout "$3" -fs "$4" -volname "$1" "$image"
    DEV="$(hdiutil attach -nomount "$image" | awk 'NR == 1 { sub("/dev/", "", $1); print $1 }')"
    [[ "$DEV" =~ ^disk[0-9]+$ ]] || fail "could not attach $image"
    IMAGES+=("$DEV")
}

# Refuses any device that isn't on one of this script's images.
ours() {
    local whole="${1%%s[0-9]*}"
    for dev in "${IMAGES[@]}"; do
        [[ "$dev" == "$whole" ]] && return 0
    done
    fail "refusing to touch $1: not a scratch image"
}

info() { diskutil info -plist "/dev/$1" | plutil -extract "$2" raw -o - -; }

# Runs ntfs-format on a partition with its real size and offset; prints the exit status.
run_format() { # device args...
    local dev="$1"
    shift
    ours "$dev"
    local status=0
    "$FORMAT" --device "$dev" --size "$(info "$dev" TotalSize)" --offset "$(info "$dev" PartitionMapPartitionOffset)" "$@" \
        >"$WORK/format.log" 2>&1 || status=$?
    echo "$status"
}

expect_format() { # expected-status device args...
    local expected="$1"
    shift
    local status
    status="$(run_format "$@")"
    [[ "$status" == "$expected" ]] || { cat "$WORK/format.log"; fail "ntfs-format $* exited $status, expected $expected"; }
}

check_ntfs() { # partition
    ours "$1"
    mkdir -p "$MNT"
    mount -F -t ntfsrw "/dev/$1" "$MNT" || fail "$1 did not mount as NTFS"
    mount | grep " on $MNT " | grep -q "(ntfsrw" || fail "$1 is not mounted by ntfsrw"
    head -c $((3 * 1024 * 1024 + 5)) /dev/urandom > "$WORK/data.bin"
    cp "$WORK/data.bin" "$MNT/data.bin"
    umount "$MNT"
    mount -F -t ntfsrw -o rdonly "/dev/$1" "$MNT" || fail "$1 did not remount"
    cmp -s "$WORK/data.bin" "$MNT/data.bin" || fail "data on $1 changed after remount"
    umount "$MNT"
}

mbr_type() { # whole disk -> type byte of entry 1
    ours "$1"
    dd if="/dev/r$1" bs=512 count=1 2>/dev/null | xxd -s 450 -l 1 -p
}

step "Refusals on a GPT image"
new_image GPTX 300m GPTSPUD ExFAT
GPT="$DEV"
P="${GPT}s1"
ours "$P"
diskutil mount "$P" >/dev/null
expect_format 70 "$P" --label X --quick
diskutil unmount "$P" >/dev/null
size="$(info "$P" TotalSize)"
offset="$(info "$P" PartitionMapPartitionOffset)"
status=0; "$FORMAT" --device "$P" --size $((size - 512)) --offset "$offset" --label X --quick >/dev/null 2>&1 || status=$?
[[ $status == 71 ]] || fail "accepted a wrong size (exit $status)"
status=0; "$FORMAT" --device "$GPT" --size "$(info "$GPT" TotalSize)" --offset 0 --label X --quick >/dev/null 2>&1 || status=$?
[[ $status == 66 ]] || fail "accepted a whole disk (exit $status)"
expect_format 72 "$P" --label "" --quick
expect_format 73 "$P" --label X --cluster 3000 --quick

step "NTFS on GPT, quick"
expect_format 0 "$P" --label "Thử NTFS" --quick
check_ntfs "$P"

step "NTFS on MBR, full format, 8 KB clusters"
new_image MBRF 128m MBRSPUD MS-DOS
MBR="$DEV"
[[ "$(mbr_type "$MBR")" != "07" ]] || fail "the MBR image already has type 07"
expect_format 0 "${MBR}s1" --label MBRNTFS --cluster 8192
[[ "$(mbr_type "$MBR")" == "07" ]] || fail "MBR type was not set to NTFS"
check_ntfs "${MBR}s1"

step "diskutil partition formats: exFAT, FAT32, APFS, then APFS store back to exFAT"
for fs in "ExFAT:exfat" "MS-DOS FAT32:msdos" "APFS:apfs" "ExFAT:exfat"; do
    name="${fs%%:*}"
    kind="${fs##*:}"
    ours "$P"
    diskutil eraseVolume "$name" NFMTEST "$P" >/dev/null || fail "eraseVolume $name failed"
    if [[ "$kind" == "apfs" ]]; then
        [[ "$(info "$P" Content)" == "Apple_APFS" ]] || fail "$P is not an APFS store"
    else
        [[ "$(info "$P" FilesystemType)" == "$kind" ]] || fail "$P is not $kind"
    fi
    diskutil unmount /Volumes/NFMTEST >/dev/null
done

step "Whole-disk NTFS on MBR (eraseDisk, then ntfs-format)"
ours "$MBR"
diskutil eraseDisk ExFAT NTFS MBR "$MBR" >/dev/null || fail "eraseDisk failed"
diskutil unmount "/dev/${MBR}s1" >/dev/null
expect_format 0 "${MBR}s1" --label "Whole Disk" --quick
[[ "$(mbr_type "$MBR")" == "07" ]] || fail "MBR type is not NTFS after a whole-disk format"
check_ntfs "${MBR}s1"

step "Whole-disk exFAT on GPT"
ours "$GPT"
diskutil eraseDisk ExFAT NFMTEST GPT "$GPT" >/dev/null || fail "eraseDisk GPT failed"
diskutil unmount /Volumes/NFMTEST >/dev/null

echo "PASS"
```

- [ ] **Step 2: Run it**

Run: `scripts/format-integration-test.sh` (the user enters their password in the macOS dialog; never type it for them).
Expected: every step prints, ending with `PASS`.

If the "APFS store back to exFAT" step fails with `eraseVolume` refusing an APFS physical store, change `FormatPlanner` for partitions whose device `content` is `DiskContent.apfsStore` to emit `.diskutil(["apfs", "deleteContainer", device.bsdName, "NFMTEMP"])` before the `eraseVolume` step, add a matching planner test (`apfsVolumeErasesItsStore` expects the extra step), and add the same `diskutil apfs deleteContainer "$P" NFMTEMP` line before `eraseVolume` in this script's loop when the previous kind was `apfs`. Rerun until `PASS`.

- [ ] **Step 3: Run the existing integration test too**

Run: `scripts/integration-test.sh` — Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/format-integration-test.sh
git commit -m "Add an integration test that formats scratch images like the app does"
```

---

### Task 13: Release 1.0.2

**Files:**
- Modify: `Config/Base.xcconfig`, `CHANGELOG.md`, `README.md`, `README.vi.md`
- Create: `docs/releases/v1.0.2.md`

- [ ] **Step 1: Bump the version**

In `Config/Base.xcconfig`: `MARKETING_VERSION = 1.0.2`, `CURRENT_PROJECT_VERSION = 3`.

- [ ] **Step 2: Changelog**

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown
## [1.0.2] - 2026-11-XX

### Added

- Main window in the style of Disk Utility: every connected drive with its partitions, details, a capacity bar and a
  partition map. Internal and macOS drives are shown but protected.
- Mount, unmount, eject and Show in Finder for any drive, not only NTFS.
- Format a partition as NTFS, exFAT, FAT32 or APFS, or erase a whole external drive with a new GPT or MBR partition
  table. A summary shows exactly what will be erased, and the drive's name must be typed to confirm. Formatting
  re-checks the drive right before it starts and stops if anything changed.
- Advanced NTFS options: cluster size and full (zero-filling) format.

### Changed

- The menu bar panel is more compact and opens the main window.
```

(Replace `XX` with the release day.)

- [ ] **Step 3: Release notes and READMEs**

Create `docs/releases/v1.0.2.md` with the same Added/Changed lists plus install instructions copied from `docs/releases/v1.0.1.md`. In `README.md` and `README.vi.md`, add a "Drive manager and formatting" / "Quản lý ổ và định dạng" section describing the main window and format safety, with a screenshot `docs/images/main-window.png` taken with `screencapture -l <windowID>` of the main window showing "New Volume" (no other personal drive names visible besides the user's SSD).

- [ ] **Step 4: Full verification**

Run, in order, and confirm each passes:
- `swift test --package-path Core`
- App tests command
- `scripts/build-local.sh` (produces `build/NTFS-for-Mac.dmg`)
- Install cycle (Task 4, Step 6), then `scripts/integration-test.sh` and `scripts/format-integration-test.sh`
- Manual: "New Volume" mounts read-write; write a test file in Finder, read it back, delete it; `du -sk` of New Volume returns to its baseline. Nothing else touched.

- [ ] **Step 5: Commit**

```bash
git add Config/Base.xcconfig CHANGELOG.md README.md README.vi.md docs/releases/v1.0.2.md docs/images
git commit -m "Release 1.0.2"
```

- [ ] **Step 6: Ask the user before publishing**

Ask the user to confirm merging `release-1.0.2` into `main`, tagging `v1.0.2`, pushing, and creating the GitHub release with `build/NTFS-for-Mac.dmg`. Only after they confirm:

```bash
git checkout main && git merge --no-ff release-1.0.2 -m "Merge release 1.0.2"
git tag v1.0.2 && git push origin main v1.0.2
cp build/NTFS-for-Mac.dmg build/NTFS-for-Mac-1.0.2.dmg
gh release create v1.0.2 build/NTFS-for-Mac-1.0.2.dmg --title "NTFS for Mac 1.0.2" --notes-file docs/releases/v1.0.2.md
```
