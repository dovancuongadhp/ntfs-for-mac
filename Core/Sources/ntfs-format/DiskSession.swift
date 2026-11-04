import Darwin
import NTFSAuthOpen
import NTFSFormat

/// Administrator authorization for the partition and its whole disk, then
/// file descriptors obtained from `authopen`. A plain `open` of a removable
/// disk is refused by macOS even for root.
final class DiskSession {
    private var session: OpaquePointer?

    init(partition: String, whole: String) throws {
        var error: Int32 = 0
        guard let session = ntfs_disk_session_begin(partition, whole, &error) else {
            throw Self.failure(error)
        }
        self.session = session
    }

    func open(_ path: String) throws -> Int32 {
        let fd = ntfs_disk_session_open(session, path)
        guard fd >= 0 else { throw Self.failure(ntfs_disk_session_error(session)) }
        return fd
    }

    func close() {
        ntfs_disk_session_end(session)
        session = nil
    }

    deinit { close() }

    private static func failure(_ code: Int32) -> FormatToolError {
        switch code {
        case Int32(ntfs_auth_cancelled): .authorizationCancelled
        case Int32(ntfs_auth_denied): .notAuthorized
        default: .ioError
        }
    }
}

enum MkntfsLauncher {
    /// `arguments` are the mkntfs flags, without argv0. `fd` is an authopen
    /// descriptor for `diskPath` and must stay open until this returns.
    static func run(executable: String, arguments: [String], diskPath: String, fd: Int32) throws {
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        let status = argv.withUnsafeMutableBufferPointer { buffer in
            ntfs_spawn_with_disk_fd(executable, buffer.baseAddress, diskPath, fd)
        }
        guard status == 0 else { throw FormatToolError.mkntfsFailed }
    }
}
