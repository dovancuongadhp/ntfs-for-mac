import Darwin
import Foundation

public protocol FileReading: AnyObject, Sendable {
    /// Returns up to `count` bytes, or empty data at the end of the file.
    func read(upTo count: Int) throws -> Data
    func close()
}

public protocol FileWriting: AnyObject, Sendable {
    func write(_ data: Data) throws
    func sync() throws
    func close() throws
}

public struct VolumeInfo: Sendable, Equatable {
    public var fileSystemType: String
    public var freeBytes: Int64

    public init(fileSystemType: String, freeBytes: Int64) {
        self.fileSystemType = fileSystemType
        self.freeBytes = freeBytes
    }
}

/// Everything the engine needs from a file system. Tests wrap the real one to inject failures.
public protocol FileAccess: Sendable {
    func attributes(of url: URL) throws -> FileAttributes
    func children(of url: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func makeDirectory(_ url: URL) throws
    func readLink(_ url: URL) throws -> String
    func makeLink(at url: URL, target: String) throws
    func openForReading(_ url: URL) throws -> any FileReading
    func createForWriting(_ url: URL) throws -> any FileWriting
    /// Renames, replacing a file already at `to`.
    func rename(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    /// Best effort: dates and permissions the destination may refuse are ignored.
    func copyMetadata(from: URL, to: URL)
    func volumeInfo(at url: URL) throws -> VolumeInfo
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

public struct PosixFileAccess: FileAccess {
    public init() {}

    public func attributes(of url: URL) throws -> FileAttributes {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        let kind: FileKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileAttributes(kind: kind, size: Int64(info.st_size), modified: Date(timeIntervalSince1970: seconds))
    }

    public func children(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map { url.appending(component: $0) }
    }

    public func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o777) == 0 else { throw posixError() }
    }

    public func readLink(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public func makeLink(at url: URL, target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    public func openForReading(_ url: URL) throws -> any FileReading {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        // Skip the page cache so speeds reflect the drive and a checksum reads what was stored.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return PosixReader(descriptor: descriptor)
    }

    public func createForWriting(_ url: URL) throws -> any FileWriting {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard descriptor >= 0 else { throw posixError() }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return PosixWriter(descriptor: descriptor)
    }

    public func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw posixError() }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func copyMetadata(from: URL, to: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: from.path) else { return }
        var wanted: [FileAttributeKey: Any] = [:]
        if let date = attributes[.modificationDate] { wanted[.modificationDate] = date }
        if let permissions = attributes[.posixPermissions] { wanted[.posixPermissions] = permissions }
        try? FileManager.default.setAttributes(wanted, ofItemAtPath: to.path)
    }

    public func volumeInfo(at url: URL) throws -> VolumeInfo {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw posixError() }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return VolumeInfo(fileSystemType: type, freeBytes: Int64(info.f_bavail) * Int64(info.f_bsize))
    }
}

private final class PosixReader: FileReading, @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    func read(upTo count: Int) throws -> Data {
        var data = Data(count: count)
        while true {
            let descriptor = descriptor
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            if received < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            data.removeSubrange(received..<data.count)
            return data
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private final class PosixWriter: FileWriting, @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let descriptor = descriptor
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    func sync() throws {
        if fsync(descriptor) != 0, errno != ENOTSUP, errno != EINVAL { throw posixError() }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let result = Darwin.close(descriptor)
        let code = errno
        descriptor = -1
        if result != 0, code != EINTR { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
