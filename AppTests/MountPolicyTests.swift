import Foundation
import Testing
@testable import NTFS_for_Mac

@MainActor
struct MountPolicyTests {
    private func disk(fileSystem: String? = nil, readOnly: Bool = false, recognized: Bool = true) -> NTFSDisk {
        NTFSDisk(
            bsdName: "disk4s1",
            name: "Data",
            preferenceKey: "key",
            isRecognized: recognized,
            isWritableMedia: true,
            mount: fileSystem.map {
                NTFSDisk.Mount(
                    path: URL(fileURLWithPath: "/Volumes/Data"), fileSystemType: $0,
                    isReadOnly: readOnly, totalBytes: 100, freeBytes: 40)
            }
        )
    }

    @Test func systemMountIsReplacedWhenWritingIsAllowed() {
        let action = MountPolicy.action(for: disk(fileSystem: "ntfs", readOnly: true), writeEnabled: true, alreadyHandled: false)
        #expect(action == .mountWithExtension(readOnly: false))
    }

    @Test func systemMountIsKeptWhenWritingIsOff() {
        let action = MountPolicy.action(for: disk(fileSystem: "ntfs", readOnly: true), writeEnabled: false, alreadyHandled: false)
        #expect(action == .none)
    }

    @Test func unmountedDiskIsMountedByExtension() {
        #expect(MountPolicy.action(for: disk(), writeEnabled: true, alreadyHandled: false) == .mountWithExtension(readOnly: false))
        #expect(MountPolicy.action(for: disk(), writeEnabled: false, alreadyHandled: false) == .mountWithExtension(readOnly: true))
    }

    @Test func extensionMountIsLeftAlone() {
        #expect(MountPolicy.action(for: disk(fileSystem: "ntfsrw"), writeEnabled: true, alreadyHandled: false) == .none)
        // Read-only for a reason the extension found (e.g. hibernation): remounting won't help.
        #expect(MountPolicy.action(for: disk(fileSystem: "ntfsrw", readOnly: true), writeEnabled: true, alreadyHandled: false) == .none)
    }

    @Test func writableExtensionMountIsRemountedWhenWritingIsOff() {
        let action = MountPolicy.action(for: disk(fileSystem: "ntfsrw"), writeEnabled: false, alreadyHandled: false)
        #expect(action == .mountWithExtension(readOnly: true))
    }

    @Test func nothingHappensTwiceOrForUnrecognizedDisks() {
        #expect(MountPolicy.action(for: disk(), writeEnabled: true, alreadyHandled: true) == .none)
        #expect(MountPolicy.action(for: disk(recognized: false), writeEnabled: true, alreadyHandled: false) == .none)
    }

    @Test func stateDescribesTheMount() {
        #expect(disk(fileSystem: "ntfsrw").state(reason: nil, writeEnabled: true) == .readWrite)
        #expect(disk(fileSystem: "ntfs", readOnly: true).state(reason: nil, writeEnabled: true) == .systemReadOnly)
        #expect(disk(fileSystem: "ntfsrw", readOnly: true).state(reason: .hibernated, writeEnabled: true) == .readOnly(.hibernated))
        #expect(disk(fileSystem: "ntfsrw", readOnly: true).state(reason: nil, writeEnabled: false) == .readOnly(.requested))
        #expect(disk().state(reason: nil, writeEnabled: true) == .notMounted)
        #expect(disk(recognized: false).state(reason: nil, writeEnabled: true) == .unrecognized)
    }

    @Test func candidates() {
        #expect(NTFSDisk.isCandidate(content: "Windows_NTFS", volumeKind: nil))
        #expect(NTFSDisk.isCandidate(content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", volumeKind: "ntfs"))
        #expect(!NTFSDisk.isCandidate(content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", volumeKind: "exfat"))
        #expect(!NTFSDisk.isCandidate(content: "Apple_APFS", volumeKind: nil))
    }
}

@MainActor
struct VolumePreferencesTests {
    @Test func writingDefaultsToOnAndPersists() throws {
        let suite = "VolumePreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = VolumePreferences(defaults: defaults)
        #expect(preferences.isWriteEnabled("A"))
        preferences.setWriteEnabled(false, for: "A")
        #expect(!preferences.isWriteEnabled("A"))
        #expect(preferences.isWriteEnabled("B"))

        #expect(!VolumePreferences(defaults: defaults).isWriteEnabled("A"))
        preferences.setWriteEnabled(true, for: "A")
        #expect(VolumePreferences(defaults: defaults).isWriteEnabled("A"))
    }
}

struct MountPointTests {
    @Test func quotingSurvivesHostileNames() {
        #expect(MountController.shellQuoted("it's") == "'it'\\''s'")
        #expect(MountController.appleScriptQuoted("say \"hi\" \\") == "\"say \\\"hi\\\" \\\\\"")
    }

    @Test @MainActor func mountPointAvoidsExistingPaths() {
        #expect(MountController.freeMountPoint(for: "a/b:c") == "/Volumes/a-b-c")
        #expect(MountController.freeMountPoint(for: "  ") == "/Volumes/NTFS")
        #expect(MountController.freeMountPoint(for: "..") == "/Volumes/NTFS")
    }
}
