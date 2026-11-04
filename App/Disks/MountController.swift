import AppKit
import DiskArbitration
import NTFSShared

struct DiskOperationError: LocalizedError {
    let message: String
    /// DiskArbitration status, when this error came from a dissenter.
    var status: Int32? = nil
    var errorDescription: String? { message }

    /// `kDAReturnBusy` (0xF8DA0002): a mount is already underway or finished.
    var isBusy: Bool { status == Int32(bitPattern: 0xF8DA0002) }
}

/// How to mount with the extension when DiskArbitration picked another driver.
/// The directory is created as an administrator; `mount` itself must run as the
/// logged-in user or FSKit answers "Unable to invoke task".
struct ExtensionMountCommand: Equatable {
    var prepareScript: String
    var arguments: [String]
}

/// Mounts, remounts and ejects disks through DiskArbitration.
@MainActor
final class MountController {
    private let session: DASession

    init(session: DASession) {
        self.session = session
    }

    /// Mounts the partition with the NTFS for Mac extension, replacing any
    /// existing mount (including macOS's read-only one).
    /// With `resetJournal`, the extension discards an unclean journal first.
    func mountWithExtension(bsdName: String, volumeName: String, readOnly: Bool, resetJournal: Bool = false) async throws {
        let request = resetJournal ? JournalResetRequest(bsdName: bsdName) : nil
        defer { request?.cancel() }
        let disk = try diskObject(bsdName)
        if mountPath(disk) != nil {
            try await unmount(disk, options: DADiskUnmountOptions(kDADiskUnmountOptionDefault))
        }

        // DiskArbitration probes file systems in FSProbeOrder, so with the
        // extension enabled it should pick ours ahead of Apple's driver.
        do {
            try await mount(disk, arguments: readOnly ? ["rdonly"] : [])
        } catch let error as DiskOperationError where error.isBusy {
            // The volume is already being mounted. Starting `mount -F` now makes
            // FSKit fail with "Unable to invoke task". Wait, then keep a mount
            // that is not Apple's read-only NTFS driver.
            if await waitUntilForeignMountSettles(disk) { return }
        } catch {
            appLog.notice("DiskArbitration mount of \(bsdName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        if let path = mountPath(disk), Self.fileSystemType(at: path) != Identifiers.systemDriverTypeName {
            return
        }

        // macOS chose its own NTFS driver, or nothing mounted. Create the
        // directory as an administrator, then mount as this user.
        if mountPath(disk) != nil {
            try await unmount(disk, options: DADiskUnmountOptions(kDADiskUnmountOptionDefault))
        }
        try await runExtensionMount(bsdName: bsdName, volumeName: volumeName, readOnly: readOnly)
    }

    /// `true` when the in-progress mount is exFAT, APFS, or this extension, so it
    /// must be left alone. Apple's read-only NTFS mount returns `false`.
    private func waitUntilForeignMountSettles(_ disk: DADisk) async -> Bool {
        for _ in 0..<12 {
            if let path = mountPath(disk) {
                return Self.fileSystemType(at: path) != Identifiers.systemDriverTypeName
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Unmounts every volume on the physical disk and ejects it.
    func eject(bsdName: String) async throws {
        let disk = try diskObject(bsdName)
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        try await unmount(whole, options: DADiskUnmountOptions(kDADiskUnmountOptionWhole))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                CallbackBox.resume(context, dissenter)
            }, CallbackBox.retain(continuation))
        }
    }

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

    private func diskObject(_ bsdName: String) throws -> DADisk {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DiskOperationError(message: String(localized: "The disk is no longer connected."))
        }
        return disk
    }

    private func mountPath(_ disk: DADisk) -> URL? {
        let description = DADiskCopyDescription(disk) as? [String: Any]
        return description?[kDADiskDescriptionVolumePathKey as String] as? URL
    }

    private func unmount(_ disk: DADisk, options: DADiskUnmountOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DADiskUnmount(disk, options, { _, dissenter, context in
                CallbackBox.resume(context, dissenter)
            }, CallbackBox.retain(continuation))
        }
    }

    private func mount(_ disk: DADisk, arguments: [String]) async throws {
        // DADiskMountWithArguments takes a NULL-terminated C array of CFStrings.
        var array: [Unmanaged<CFString>?] = arguments.map { Unmanaged.passRetained($0 as CFString) } + [nil]
        defer { array.forEach { $0?.release() } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, context in
                CallbackBox.resume(context, dissenter)
            }, CallbackBox.retain(continuation), &array)
        }
    }

    private func runExtensionMount(bsdName: String, volumeName: String, readOnly: Bool) async throws {
        let mountPoint = Self.freeMountPoint(for: volumeName)
        let command = Self.extensionMountCommand(
            bsdName: bsdName, mountPoint: mountPoint, readOnly: readOnly, uid: getuid(), gid: getgid())
        try runAdministrator(command.prepareScript)
        let result = try await CommandLineTool.run("/sbin/mount", command.arguments)
        guard result.status == 0 else {
            _ = try? await CommandLineTool.run("/bin/rmdir", [mountPoint])
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskOperationError(message: output.isEmpty
                ? String(localized: "The disk could not be mounted.")
                : output)
        }
    }

    private func runAdministrator(_ script: String) throws {
        let source = "do shell script \(Self.appleScriptQuoted(script)) with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            throw DiskOperationError(message: message ?? String(localized: "The disk could not be mounted."))
        }
    }

    nonisolated static func extensionMountCommand(
        bsdName: String, mountPoint: String, readOnly: Bool, uid: uid_t, gid: gid_t
    ) -> ExtensionMountCommand {
        let quoted = shellQuoted(mountPoint)
        var arguments = ["-F", "-t", Identifiers.fileSystemShortName]
        if readOnly {
            arguments += ["-o", "rdonly"]
        }
        arguments += ["/dev/\(bsdName)", mountPoint]
        return ExtensionMountCommand(
            prepareScript: "/bin/mkdir -p \(quoted) && /usr/sbin/chown \(uid):\(gid) \(quoted)",
            arguments: arguments)
    }

    private nonisolated static func fileSystemType(at path: URL) -> String? {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    nonisolated static func freeMountPoint(for volumeName: String, fileManager: FileManager = .default) -> String {
        let cleaned = volumeName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = "/Volumes/" + (cleaned.isEmpty || cleaned.hasPrefix(".") ? "NTFS" : cleaned)
        var candidate = base
        var counter = 1
        while fileManager.fileExists(atPath: candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    nonisolated static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Carries a continuation through DiskArbitration's C callbacks.
private final class CallbackBox {
    let continuation: CheckedContinuation<Void, any Error>

    private init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    static func retain(_ continuation: CheckedContinuation<Void, any Error>) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(CallbackBox(continuation)).toOpaque()
    }

    static func resume(_ context: UnsafeMutableRawPointer?, _ dissenter: DADissenter?) {
        let box = Unmanaged<CallbackBox>.fromOpaque(context!).takeRetainedValue()
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let text = DADissenterGetStatusString(dissenter) as String?
            box.continuation.resume(throwing: DiskOperationError(
                message: text ?? String(localized: "The operation failed (code \(status))."),
                status: status))
        } else {
            box.continuation.resume()
        }
    }
}
