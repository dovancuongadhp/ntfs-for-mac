import Darwin
import Foundation
@testable import NTFSTransfer

/// A throwaway folder, removed when the test ends.
final class TempFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(component: "ntfs-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appending(path: relative) }

    @discardableResult
    func file(_ relative: String, _ text: String = "x") throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    @discardableResult
    func data(_ relative: String, count: Int) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        try Data(bytes).write(to: target)
        return target
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func text(_ relative: String) throws -> String {
        String(decoding: try Data(contentsOf: path(relative)), as: UTF8.self)
    }

    func has(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative).path, &info) == 0
    }

    /// Names of everything directly inside `relative`, sorted.
    func names(_ relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(relative).path).sorted()
    }

    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative).path)
    }
}

/// Convenience wrapper used by planner tests: plans with the real POSIX file system.
func plan(_ sources: [URL], into folder: URL) throws -> [TransferJob] {
    try TransferPlanner.plan(sources: sources, into: folder, access: PosixFileAccess())
}
