import AppKit
import DiskArbitration
import NTFSShared

struct DiskOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    func mountWithExtension(bsdName: String, volumeName: String, readOnly: Bool) async throws {
        let disk = try diskObject(bsdName)
        if mountPath(disk) != nil {
            try await unmount(disk, options: DADiskUnmountOptions(kDADiskUnmountOptionDefault))
        }

        // DiskArbitration probes file systems in FSProbeOrder, so with the
        // extension enabled it should pick ours ahead of Apple's driver.
        do {
            try await mount(disk, arguments: readOnly ? ["rdonly"] : [])
        } catch {
            appLog.notice("DiskArbitration mount of \(bsdName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        if let path = mountPath(disk), Self.fileSystemType(at: path) != Identifiers.systemDriverTypeName {
            return
        }

        // macOS chose its own driver (or none): mount explicitly with mount(8),
        // which needs administrator rights to create the mount point.
        if mountPath(disk) != nil {
            try await unmount(disk, options: DADiskUnmountOptions(kDADiskUnmountOptionDefault))
        }
        try runPrivilegedMount(bsdName: bsdName, volumeName: volumeName, readOnly: readOnly)
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

    private func runPrivilegedMount(bsdName: String, volumeName: String, readOnly: Bool) throws {
        let mountPoint = Self.freeMountPoint(for: volumeName)
        let options = readOnly ? "-o rdonly " : ""
        let command = "/bin/mkdir -p \(Self.shellQuoted(mountPoint)) && "
            + "/sbin/mount -F -t \(Identifiers.fileSystemShortName) \(options)/dev/\(bsdName) \(Self.shellQuoted(mountPoint))"
            + " || { /bin/rmdir \(Self.shellQuoted(mountPoint)); exit 1; }"
        let source = "do shell script \(Self.appleScriptQuoted(command)) with administrator privileges"

        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            throw DiskOperationError(message: message ?? String(localized: "The disk could not be mounted."))
        }
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
                message: text ?? String(localized: "The operation failed (code \(status)).")))
        } else {
            box.continuation.resume()
        }
    }
}
