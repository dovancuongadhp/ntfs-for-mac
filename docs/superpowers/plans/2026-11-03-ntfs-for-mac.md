# NTFS for Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A drag-to-install macOS app whose embedded FSKit extension mounts NTFS volumes read-write in Finder, backed by libntfs-3g.

**Architecture:** `Core/` is a Swift package: a C target compiling the pinned `ntfs-3g` library plus a thin bridge (`ntfs_bridge.c`) that exposes an inode-number based API and pluggable device I/O. A Swift wrapper (`NTFSVolumeHandle`) turns it into throwing Swift calls and is fully tested against disk images produced by a bundled `mkntfs`. The FSKit extension and the menu-bar app (XcodeGen project) consume the package.

**Tech Stack:** Swift 6 / SwiftUI, FSKit (`FSUnaryFileSystem`, `FSVolume.Operations`), DiskArbitration, ServiceManagement, C (libntfs-3g 2026.9.28), Swift Testing, XcodeGen.

## Global Constraints

- Minimum OS: macOS 26.0. Architectures: arm64 + x86_64.
- License: GPL-2.0-or-later (inherits from ntfs-3g).
- ntfs-3g pinned to tag `2026.9.28` as git submodule at `Core/vendor/ntfs-3g`; never patch vendored files — all adaptation lives in `Core/Sources/CNTFS/bridge` and `Core/Sources/CNTFS/config`.
- Bundle IDs: app `com.docuong.ntfsformac`, extension `com.docuong.ntfsformac.fsmodule`. FSKit short name: `ntfsrw`.
- On-disk names are written in NFC; lookups normalize the incoming name to NFC.
- Read-only fallback rules (spec §4.2): hibernated Windows, unclean `$LogFile`, `VOLUME_IS_DIRTY`, user preference, any write-path I/O error.
- UI strings live in `Localizable.xcstrings`, development language `en`, plus `vi`.
- Nothing may require an installer, kernel extension, or macFUSE.

## Deviation From Template

The plan lists exact files, interfaces, and verification commands per task. Full source is in the commits rather than duplicated here; the codebase is the source of truth once a task lands.

---

### Task 1: Core package builds libntfs-3g and mkntfs

**Files:**
- Create: `Core/Package.swift`
- Create: `Core/Sources/CNTFS/config/config.h` (hand-written autoconf result for Darwin)
- Create: `Core/Sources/CNTFS/vendor` → symlink to `../../vendor/ntfs-3g`
- Create: `Core/Sources/CNTFS/include/ntfs_bridge.h`, `Core/Sources/CNTFS/bridge/ntfs_bridge.c` (stub)
- Create: `Core/Sources/ntfs-mkfs/` executable target compiling `ntfsprogs/mkntfs.c` + helpers

**Interfaces:**
- Produces: library product `NTFSCore`, executable `ntfs-mkfs` (same CLI as `mkntfs`).

- [ ] `swift build` succeeds with no errors.
- [ ] `swift run ntfs-mkfs -F -f -q -L Test /tmp/t.img` on a 64 MiB file exits 0 and the file starts with `\xEB\x52\x90NTFS    `.
- [ ] Commit.

### Task 2: Device I/O and mount/unmount with status

**Files:**
- Modify: `Core/Sources/CNTFS/include/ntfs_bridge.h`, `Core/Sources/CNTFS/bridge/ntfs_bridge.c`
- Create: `Core/Sources/CNTFS/bridge/bridge_device.c` (callback-backed `ntfs_device_operations`, sector alignment bounce buffer)
- Create: `Core/Sources/NTFSCore/NTFSVolumeHandle.swift`, `NTFSError.swift`, `BlockDevice.swift`
- Create: `Core/Tests/NTFSCoreTests/TestImage.swift`, `MountTests.swift`

**Interfaces:**
- `protocol BlockDevice: AnyObject { var size: UInt64 {get}; var sectorSize: Int {get}; var isWritable: Bool {get}; func read(into: UnsafeMutableRawBufferPointer, at: UInt64) throws -> Int; func write(_ : UnsafeRawBufferPointer, at: UInt64) throws -> Int; func flush() throws }`
- `final class FileBlockDevice: BlockDevice` (`init(path:writable:) throws`)
- `enum ReadOnlyReason: Sendable { case requested, hibernated, uncleanJournal, dirty }`
- `final class NTFSVolumeHandle { init(device: BlockDevice, readOnly: Bool) throws; var readOnlyReason: ReadOnlyReason? ; var label: String; var info: VolumeInfo; func unmount() throws }`
- `struct NTFSError: Error { let code: Int32 }` (POSIX errno), `enum NTFSMountError: Error { case notNTFS, bitLocker, corrupt(Int32) }`

- [ ] Tests: fresh image mounts RW with label "Test"; `readOnly: true` gives `.requested`; image with `VOLUME_IS_DIRTY` gives `.dirty`; image with root `hiberfil.sys` starting `hibr` gives `.hibernated`; random bytes → `.notNTFS`; BitLocker signature `-FVE-FS-` → `.bitLocker`.
- [ ] `swift test` passes. Commit.

### Task 3: Inode operations

**Files:**
- Modify: bridge header/source; Create: `Core/Sources/NTFSCore/NTFSVolumeHandle+Items.swift`, `ItemAttributes.swift`
- Create: `Core/Tests/NTFSCoreTests/ItemTests.swift`, `RenameTests.swift`, `DataTests.swift`

**Interfaces (all on `NTFSVolumeHandle`, `ItemID = UInt64` MFT number, root = 5):**
- `func attributes(of: ItemID) throws -> ItemAttributes`
- `func lookup(_ name: String, in dir: ItemID) throws -> ItemID`
- `func contents(of dir: ItemID, from cookie: UInt64, body: (DirectoryEntry) -> Bool) throws -> UInt64?`
- `func create(_ name: String, in dir: ItemID, type: ItemType) throws -> ItemID` (`.file`, `.directory`)
- `func read(_ id: ItemID, at: UInt64, into: UnsafeMutableRawBufferPointer) throws -> Int`
- `func write(_ id: ItemID, at: UInt64, from: UnsafeRawBufferPointer) throws -> Int`
- `func truncate(_ id: ItemID, to: UInt64) throws`
- `func remove(_ name: String, in dir: ItemID) throws` (ENOTEMPTY for non-empty dirs)
- `func rename(_ name: String, in src: ItemID, to newName: String, in dst: ItemID) throws` (replaces existing file/empty dir)
- `func readLink(_ id: ItemID) throws -> String`
- `func setTimes(_ id: ItemID, access: timespec?, modify: timespec?, birth: timespec?) throws`
- `func setFlags(_ id: ItemID, hidden: Bool) throws`
- `func statistics() throws -> VolumeStatistics`; `func setLabel(_:) throws`; `func sync() throws`
- `ItemAttributes { id, parentID?, type, size, allocSize, linkCount, isHidden, isSystem, isReadOnly, isCompressed, isEncrypted, access/modify/change/birth: timespec }`

- [ ] Tests: create/read/write round-trip (1 byte, 1 MiB random, sparse 5 GiB write at offset 4.5 GiB), truncate grow/shrink, Vietnamese NFC + NFD lookup hit the same file, 2,000 files enumerate exactly once with resumable cookies, rename across directories, rename over existing file, remove non-empty dir fails with ENOTEMPTY, remount after unmount preserves data.
- [ ] Commit.

### Task 4: FSKit extension

**Files:**
- Create: `project.yml` (XcodeGen; targets `NTFSForMac` app and `NTFSExtension` appex; local package `Core`)
- Create: `Extension/NTFSExtensionMain.swift` (`@main struct: UnaryFileSystemExtension`)
- Create: `Extension/NTFSFileSystem.swift` (`FSUnaryFileSystem & FSUnaryFileSystemOperations & FSManageableResourceMaintenanceOperations`)
- Create: `Extension/NTFSVolume.swift` (+ `NTFSVolume+Operations.swift`, `NTFSVolume+ReadWrite.swift`), `Extension/NTFSItem.swift`, `Extension/FSBlockDeviceAdapter.swift`, `Extension/ErrnoMapping.swift`
- Create: `Extension/Info.plist`, `Extension/NTFSExtension.entitlements`

**Interfaces:**
- Consumes all of Task 2–3. `FSBlockDeviceAdapter: BlockDevice` wraps `FSBlockDeviceResource`.
- All calls into `NTFSVolumeHandle` go through one serial `DispatchQueue` per volume.
- Write failure with EIO → handle switches to read-only, posts Darwin notification `com.docuong.ntfsformac.readonly-fallback`.

- [ ] `xcodegen generate && xcodebuild -scheme NTFSForMac -configuration Debug CODE_SIGNING_ALLOWED=NO build` succeeds.
- [ ] Commit.

### Task 5: Menu bar app

**Files:**
- Create: `App/NTFSForMacApp.swift`, `App/Disks/DiskMonitor.swift`, `App/Disks/NTFSDisk.swift`, `App/Disks/BootSectorProbe.swift`, `App/Disks/MountController.swift`, `App/Settings/VolumePreferences.swift`, `App/Settings/LaunchAtLogin.swift`, `App/Views/MenuContentView.swift`, `App/Views/DiskRowView.swift`, `App/Views/WelcomeView.swift`, `App/Views/SettingsView.swift`, `App/Support/ExtensionStatus.swift`, `App/Support/Notifier.swift`, `App/Resources/Localizable.xcstrings`
- Create: `AppTests/BootSectorProbeTests.swift`, `AppTests/VolumePreferencesTests.swift`

**Interfaces:**
- `BootSectorProbe.classify(_ sector: Data) -> FileSystemKind` (`.ntfs`, `.bitLocker`, `.other`)
- `VolumePreferences.isWriteEnabled(volumeUUID:) -> Bool` (default true), `setWriteEnabled(_:for:)`
- `MountController.remountReadWrite(_ disk: NTFSDisk) async throws`, `eject(_:) async throws`

- [ ] Unit tests pass via `xcodebuild test -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO`.
- [ ] Commit.

### Task 6: Icon, packaging, docs

**Files:**
- Create: `scripts/make-icon.swift` (renders 1024px icon with CoreGraphics), `App/Resources/Assets.xcassets/AppIcon.appiconset/*`, menu bar template image
- Create: `scripts/release.sh` (build, sign Developer ID, notarize, staple, create DMG), `scripts/make-dmg.sh`, `scripts/dmg-background.swift`
- Create: `scripts/integration-test.sh` (hdiutil + mount + checksum compare; needs signed build)
- Create: `README.md` (vi + en), `LICENSE` (GPL-2.0 text), `.gitignore`

- [x] `scripts/make-dmg.sh` on an unsigned Release build produces `build/NTFS-for-Mac.dmg` containing the app and an `Applications` alias.
- [x] Commit.
