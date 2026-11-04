import Darwin
import Foundation
import os
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

final class EventLog: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [TransferEvent]())
    func add(_ event: TransferEvent) { storage.withLock { $0.append(event) } }
    var events: [TransferEvent] { storage.withLock { $0 } }
}

/// Holds a background thread at a chosen point until the test lets it go.
final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let arrived = Counter()
    var hasArrived: Bool { arrived.value > 0 }
    /// Called on the thread that must wait.
    func arriveAndWait() {
        arrived.increment()
        semaphore.wait()
    }
    func open() { semaphore.signal() }
}

final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    func increment() { storage.withLock { $0 += 1 } }
    func set(_ value: Int) { storage.withLock { $0 = value } }
    var value: Int { storage.withLock { $0 } }
}

/// The real file system with chosen failures added, keyed by the file's own name.
final class Flaky: FileAccess, @unchecked Sendable {
    struct Rules {
        var failReading: Set<String> = []
        var failWriting: [String: POSIXErrorCode] = [:]
        var corrupt: Set<String> = []
        /// Errors thrown by `sync` / `close` of the writer, keyed by the file's own name.
        var failSync: [String: POSIXErrorCode] = [:]
        var failClose: [String: POSIXErrorCode] = [:]
        /// Folders (by name) that cannot be created.
        var failMakingDirectory: [String: POSIXErrorCode] = [:]
        /// Runs before every read of a temporary copy, which is how verification re-reads the file.
        var onTemporaryRead: (@Sendable () throws -> Void)?
        /// Runs before every read of a source file; throwing makes the read fail.
        var onSourceRead: (@Sendable () throws -> Void)?
        /// Runs before `attributes(of:)` answers.
        var beforeAttributes: (@Sendable (URL) -> Void)?
        /// Makes every `exists` answer false, as if the drives were gone.
        var vanished = false
    }

    private let base = PosixFileAccess()
    private let rules = OSAllocatedUnfairLock(initialState: Rules())

    func update(_ change: (inout Rules) -> Void) {
        var copy = rules.withLock { $0 }
        change(&copy)
        let updated = copy
        rules.withLock { $0 = updated }
    }

    private func original(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".ntfs-part") {
            // .<name>.ntfs-part → <name>
            name = String(name.dropFirst().dropLast(".ntfs-part".count))
        } else if name.hasPrefix(".ntfs-part-") {
            // Short form .ntfs-part-<id> – no original name recoverable; return as-is for rule lookup
            // (rules key on original name, so this form won't match any injection rule, which is fine)
        }
        return name
    }

    func attributes(of url: URL) throws -> FileAttributes {
        let hook = rules.withLock { $0.beforeAttributes }
        hook?(url)
        return try base.attributes(of: url)
    }
    func children(of url: URL) throws -> [URL] { try base.children(of: url) }
    func exists(_ url: URL) -> Bool { rules.withLock { $0.vanished } ? false : base.exists(url) }
    func makeDirectory(_ url: URL) throws {
        if let error = rules.withLock({ $0.failMakingDirectory[url.lastPathComponent] }) { throw POSIXError(error) }
        try base.makeDirectory(url)
    }
    func readLink(_ url: URL) throws -> String { try base.readLink(url) }
    func makeLink(at url: URL, target: String) throws { try base.makeLink(at: url, target: target) }
    func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func copyMetadata(from: URL, to: URL) { base.copyMetadata(from: from, to: to) }
    func volumeInfo(at url: URL) throws -> VolumeInfo { try base.volumeInfo(at: url) }

    func openForReading(_ url: URL) throws -> any FileReading {
        let reader = try base.openForReading(url)
        let isTemporary = url.lastPathComponent.hasSuffix(".ntfs-part")
        let state = rules.withLock {
            (fails: $0.failReading.contains(original(of: url)), hook: isTemporary ? $0.onTemporaryRead : $0.onSourceRead)
        }
        if state.fails { return FailingReader(wrapping: reader) }
        if let hook = state.hook { return HookedReader(wrapping: reader, before: hook) }
        return reader
    }

    func createForWriting(_ url: URL) throws -> any FileWriting {
        let writer = try base.createForWriting(url)
        let name = original(of: url)
        let rule = rules.withLock {
            (error: $0.failWriting[name], corrupt: $0.corrupt.contains(name), sync: $0.failSync[name], close: $0.failClose[name])
        }
        return FlakyWriter(
            wrapping: writer, error: rule.error, corrupt: rule.corrupt, syncError: rule.sync, closeError: rule.close)
    }
}

final class FailingReader: FileReading, @unchecked Sendable {
    private let inner: any FileReading
    init(wrapping inner: any FileReading) { self.inner = inner }
    func read(upTo count: Int) throws -> Data { throw POSIXError(.EIO) }
    func close() { inner.close() }
}

final class HookedReader: FileReading, @unchecked Sendable {
    private let inner: any FileReading
    private let before: @Sendable () throws -> Void
    init(wrapping inner: any FileReading, before: @escaping @Sendable () throws -> Void) {
        self.inner = inner
        self.before = before
    }
    func read(upTo count: Int) throws -> Data {
        try before()
        return try inner.read(upTo: count)
    }
    func close() { inner.close() }
}

final class FlakyWriter: FileWriting, @unchecked Sendable {
    private let inner: any FileWriting
    private let error: POSIXErrorCode?
    private let corrupt: Bool
    private let syncError: POSIXErrorCode?
    private let closeError: POSIXErrorCode?

    init(
        wrapping inner: any FileWriting, error: POSIXErrorCode?, corrupt: Bool,
        syncError: POSIXErrorCode? = nil, closeError: POSIXErrorCode? = nil
    ) {
        self.inner = inner
        self.error = error
        self.corrupt = corrupt
        self.syncError = syncError
        self.closeError = closeError
    }

    func write(_ data: Data) throws {
        if let error { throw POSIXError(error) }
        guard corrupt, !data.isEmpty else { return try inner.write(data) }
        var changed = data
        changed[0] ^= 0xFF
        try inner.write(changed)
    }

    func sync() throws {
        if let syncError { throw POSIXError(syncError) }
        try inner.sync()
    }

    func close() throws {
        try inner.close()
        if let closeError { throw POSIXError(closeError) }
    }
}

/// A FileAccess that delegates everything to POSIX but refuses to create symbolic links (like exFAT/FAT32).
struct NoLinks: FileAccess, @unchecked Sendable {
    private let base = PosixFileAccess()
    func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
    func children(of url: URL) throws -> [URL] { try base.children(of: url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func makeDirectory(_ url: URL) throws { try base.makeDirectory(url) }
    func readLink(_ url: URL) throws -> String { try base.readLink(url) }
    func makeLink(at url: URL, target: String) throws { throw POSIXError(.ENOTSUP) }
    func openForReading(_ url: URL) throws -> any FileReading { try base.openForReading(url) }
    func createForWriting(_ url: URL) throws -> any FileWriting { try base.createForWriting(url) }
    func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func copyMetadata(from: URL, to: URL) { base.copyMetadata(from: from, to: to) }
    func volumeInfo(at url: URL) throws -> VolumeInfo { try base.volumeInfo(at: url) }
}

struct EngineRun {
    var outcome: TransferOutcome
    var events: [TransferEvent]
}

func run(
    _ jobs: [TransferJob],
    access: any FileAccess = PosixFileAccess(),
    verify: Bool = false,
    askOnError: Bool = false,
    chunk: Int = 1024,
    control: TransferControl = TransferControl(),
    prompts: TransferPrompts = .automatic,
    onEvent: (@Sendable (TransferEvent) -> Void)? = nil
) async -> EngineRun {
    let log = EventLog()
    let engine = TransferEngine(
        access: access,
        options: TransferOptions(verify: verify, askOnError: askOnError, chunkSize: chunk, progressInterval: .zero))
    let outcome = await engine.run(jobs: jobs, control: control, prompts: prompts) { event in
        log.add(event)
        onEvent?(event)
    }
    return EngineRun(outcome: outcome, events: log.events)
}
