import CryptoKit
import Foundation

public struct TransferOptions: Sendable, Equatable {
    public var verify: Bool
    public var askOnError: Bool
    public var chunkSize: Int
    /// How often progress events are sent while a file is copying.
    public var progressInterval: Duration

    public init(
        verify: Bool = false, askOnError: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024, progressInterval: Duration = .milliseconds(150)
    ) {
        self.verify = verify
        self.askOnError = askOnError
        self.chunkSize = chunkSize
        self.progressInterval = progressInterval
    }
}

public enum ConflictChoice: Sendable, Equatable {
    case replace, keepBoth, skip, replaceIfNewer
}

public struct ConflictDecision: Sendable, Equatable {
    public var choice: ConflictChoice
    public var applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct ConflictInfo: Sendable, Equatable {
    public var name: String
    public var source: FileAttributes
    public var existing: FileAttributes

    public init(name: String, source: FileAttributes, existing: FileAttributes) {
        self.name = name
        self.source = source
        self.existing = existing
    }
}

public enum ErrorChoice: Sendable, Equatable {
    case skip, retry, stop
}

public struct ErrorDecision: Sendable, Equatable {
    public var choice: ErrorChoice
    public var applyToAll: Bool

    public init(choice: ErrorChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct ErrorInfo: Sendable, Equatable {
    public var name: String
    public var failure: TransferFailure

    public init(name: String, failure: TransferFailure) {
        self.name = name
        self.failure = failure
    }
}

/// How the engine asks the person using the app what to do.
public struct TransferPrompts: Sendable {
    public var conflict: @Sendable (ConflictInfo) async -> ConflictDecision
    public var error: @Sendable (ErrorInfo) async -> ErrorDecision

    public init(
        conflict: @escaping @Sendable (ConflictInfo) async -> ConflictDecision,
        error: @escaping @Sendable (ErrorInfo) async -> ErrorDecision
    ) {
        self.conflict = conflict
        self.error = error
    }

    /// Never asks: skips files that already exist and failed files.
    public static let automatic = TransferPrompts(
        conflict: { _ in ConflictDecision(choice: .skip, applyToAll: true) },
        error: { _ in ErrorDecision(choice: .skip, applyToAll: true) })
}

public enum TransferEvent: Sendable, Equatable {
    case started(job: Int)
    case progress(job: Int, bytes: Int64, readRate: Double, writeRate: Double)
    case finished(job: Int, bytes: Int64)
    case skipped(job: Int)
    case failed(job: Int, TransferFailure)
}

public enum TransferStop: Sendable, Equatable {
    case finished, cancelled, noSpace, driveRemoved, userStopped
}

public struct TransferOutcome: Sendable, Equatable {
    public var stop: TransferStop = .finished
    /// Files and links created; folders are not counted.
    public var copied = 0
    public var failed = 0
    public var skipped = 0
    public var bytes: Int64 = 0
    /// Jobs not attempted, including the one that was interrupted when the run stopped.
    public var remaining: [TransferJob] = []

    public init() {}
}

public struct TransferEngine: Sendable {
    public let access: any FileAccess
    public let options: TransferOptions

    public init(access: any FileAccess, options: TransferOptions = TransferOptions()) {
        self.access = access
        self.options = options
    }

    private enum Step {
        case done(Int64)
        case skipped
        case failed(TransferFailure)
        case cancelled
    }

    private enum Resolution {
        case proceed(URL)
        case skip
        case failed(TransferFailure)
    }

    /// Copies the jobs one after another, sending events as it goes, and says why it stopped.
    public func run(
        jobs: [TransferJob], control: TransferControl, prompts: TransferPrompts,
        emit: @Sendable (TransferEvent) -> Void
    ) async -> TransferOutcome {
        var outcome = TransferOutcome()
        var conflictMemo: ConflictChoice?
        var errorMemo: ErrorChoice?
        var failedFolders: [(path: String, failure: TransferFailure)] = []
        let roots = Roots(jobs)
        var index = 0
        while index < jobs.count {
            if control.isCancelled {
                outcome.stop = .cancelled
                outcome.remaining = Array(jobs[index...])
                return outcome
            }
            await control.waitWhilePaused()
            if control.isCancelled { continue }

            let job = jobs[index]
            if let inherited = failure(inheritedBy: job, from: failedFolders) {
                // The folder this belongs in was never created, so there is nothing to try.
                emit(.failed(job: job.id, inherited))
                outcome.failed += 1
                if job.isDirectory { failedFolders.append((Self.path(of: job.destination), inherited)) }
                index += 1
                continue
            }
            control.clearSkip()
            emit(.started(job: job.id))
            let step = await perform(job, roots: roots, control: control, prompts: prompts, conflictMemo: &conflictMemo, emit: emit)
            switch step {
            case .done(let bytes):
                emit(.finished(job: job.id, bytes: bytes))
                if !job.isDirectory {
                    outcome.copied += 1
                    outcome.bytes += bytes
                }
            case .skipped:
                emit(.skipped(job: job.id))
                outcome.skipped += 1
            case .cancelled:
                outcome.stop = .cancelled
                outcome.remaining = Array(jobs[index...])
                return outcome
            case .failed(let failure):
                if failure.reason.stopsTransfer {
                    outcome.stop = failure.reason == .noSpace ? .noSpace : .driveRemoved
                    outcome.remaining = Array(jobs[index...])
                    return outcome
                }
                var choice = ErrorChoice.skip
                if options.askOnError {
                    if let errorMemo {
                        choice = errorMemo
                    } else {
                        let decision = await prompts.error(ErrorInfo(name: job.name, failure: failure))
                        choice = decision.choice
                        if decision.applyToAll, decision.choice != .retry { errorMemo = decision.choice }
                    }
                }
                switch choice {
                case .retry:
                    continue
                case .skip:
                    emit(.failed(job: job.id, failure))
                    outcome.failed += 1
                    if job.isDirectory { failedFolders.append((Self.path(of: job.destination), failure)) }
                case .stop:
                    emit(.failed(job: job.id, failure))
                    outcome.failed += 1
                    outcome.stop = .userStopped
                    outcome.remaining = Array(jobs[(index + 1)...])
                    return outcome
                }
            }
            index += 1
        }
        return outcome
    }

    // MARK: One job

    private func perform(
        _ job: TransferJob, roots: Roots, control: TransferControl, prompts: TransferPrompts,
        conflictMemo: inout ConflictChoice?, emit: @Sendable (TransferEvent) -> Void
    ) async -> Step {
        switch job.kind {
        case .directory:
            do {
                if let existing = try? access.attributes(of: job.destination) {
                    return existing.kind == .directory ? .done(0) : .failed(TransferFailure(.conflictingKind))
                }
                try access.makeDirectory(job.destination)
                return .done(0)
            } catch {
                return .failed(adjusted(.classify(error, reading: false), roots: roots))
            }
        case .file, .symlink:
            let destination: URL
            switch await resolveConflict(job, prompts: prompts, memo: &conflictMemo) {
            case .proceed(let url): destination = url
            case .skip: return .skipped
            case .failed(let failure): return .failed(failure)
            }
            if case .symlink(let target) = job.kind {
                // Create the link under a temporary name first, then atomically rename it
                // over the destination. This way, if makeLink fails (e.g. ENOTSUP on
                // exFAT/FAT32), the existing destination file is never touched.
                let temp = destination.deletingLastPathComponent()
                    .appending(component: ".ntfs-link-\(job.id)")
                do {
                    try access.makeLink(at: temp, target: target)
                    try access.rename(temp, to: destination)
                    return .done(0)
                } catch {
                    try? access.remove(temp)
                    return .failed(adjusted(.classify(error, reading: false), roots: roots))
                }
            }
            return await copy(job, to: destination, roots: roots, control: control, emit: emit)
        }
    }

    private func resolveConflict(
        _ job: TransferJob, prompts: TransferPrompts, memo: inout ConflictChoice?
    ) async -> Resolution {
        guard let existing = try? access.attributes(of: job.destination) else { return .proceed(job.destination) }
        if existing.kind == .directory { return .failed(TransferFailure(.conflictingKind)) }
        if job.source.standardizedFileURL.path == job.destination.standardizedFileURL.path {
            return .proceed(UniqueName.make(for: job.destination, exists: access.exists))
        }
        let choice: ConflictChoice
        if let memo {
            choice = memo
        } else {
            let info = ConflictInfo(
                name: job.name,
                source: FileAttributes(kind: .file, size: job.size, modified: job.modified),
                existing: existing)
            let decision = await prompts.conflict(info)
            choice = decision.choice
            if decision.applyToAll { memo = decision.choice }
        }
        switch choice {
        case .replace: return .proceed(job.destination)
        case .keepBoth: return .proceed(UniqueName.make(for: job.destination, exists: access.exists))
        case .skip: return .skip
        case .replaceIfNewer:
            // FAT and exFAT keep dates to two seconds, so a smaller difference means the same date.
            return job.modified.timeIntervalSince(existing.modified) > Self.dateTolerance ? .proceed(job.destination) : .skip
        }
    }

    private func copy(
        _ job: TransferJob, to destination: URL, roots: Roots, control: TransferControl,
        emit: @Sendable (TransferEvent) -> Void
    ) async -> Step {
        let temp = job.tempURL
        var reader: (any FileReading)?
        var writer: (any FileWriting)?
        // Only true while the source is being opened or read, so everything else counts as a write error.
        var reading = false

        func cleanUp() {
            reader?.close()
            reader = nil
            try? writer?.close()
            writer = nil
            try? access.remove(temp)
        }

        do {
            reading = true
            reader = try access.openForReading(job.source)
            reading = false
            writer = try access.createForWriting(temp)
            var hasher = SHA256()
            var done: Int64 = 0
            var meter = RateMeter()
            let clock = ContinuousClock()
            var lastEmit = clock.now

            while true {
                if control.isCancelled {
                    cleanUp()
                    return .cancelled
                }
                if control.takeSkip() {
                    cleanUp()
                    return .skipped
                }
                await control.waitWhilePaused(interruptedBySkip: true)
                if control.isCancelled { continue }
                if control.takeSkip() {
                    cleanUp()
                    return .skipped
                }

                reading = true
                let readStart = clock.now
                let chunk = try reader!.read(upTo: options.chunkSize)
                reading = false
                meter.addRead(bytes: chunk.count, seconds: Self.seconds(clock.now - readStart))
                if chunk.isEmpty { break }
                if options.verify { hasher.update(data: chunk) }

                let writeStart = clock.now
                try writer!.write(chunk)
                meter.addWrite(bytes: chunk.count, seconds: Self.seconds(clock.now - writeStart))
                done += Int64(chunk.count)

                if clock.now - lastEmit >= options.progressInterval {
                    let rates = meter.takeRates()
                    emit(.progress(job: job.id, bytes: done, readRate: rates.read, writeRate: rates.write))
                    lastEmit = clock.now
                }
            }

            try writer?.sync()
            try writer?.close()
            writer = nil
            reader?.close()
            reader = nil
            if done != job.size { throw TransferFailure(.sizeMismatch) }
            if options.verify {
                let copied = try await hash(of: temp, job: job, size: done, control: control, emit: emit)
                if copied != Data(hasher.finalize()) { throw TransferFailure(.checksumMismatch) }
            }
            try access.rename(temp, to: destination)
            access.copyMetadata(from: job.source, to: destination)
            return .done(done)
        } catch let interruption as Interruption {
            cleanUp()
            return interruption == .cancelled ? .cancelled : .skipped
        } catch let failure as TransferFailure {
            cleanUp()
            return .failed(failure)
        } catch {
            cleanUp()
            return .failed(adjusted(.classify(error, reading: reading), roots: roots))
        }
    }

    private enum Interruption: Error { case cancelled, skipped }

    /// Reads the finished copy back from the destination. It answers to Pause, Skip and Cancel like the copy does.
    private func hash(
        of url: URL, job: TransferJob, size: Int64, control: TransferControl,
        emit: @Sendable (TransferEvent) -> Void
    ) async throws -> Data {
        let reader = try access.openForReading(url)
        defer { reader.close() }
        var hasher = SHA256()
        var meter = RateMeter()
        let clock = ContinuousClock()
        var lastEmit = clock.now
        while true {
            try checkInterruption(control)
            await control.waitWhilePaused(interruptedBySkip: true)
            try checkInterruption(control)

            let readStart = clock.now
            let chunk = try reader.read(upTo: options.chunkSize)
            meter.addRead(bytes: chunk.count, seconds: Self.seconds(clock.now - readStart))
            if chunk.isEmpty { break }
            hasher.update(data: chunk)

            if clock.now - lastEmit >= options.progressInterval {
                // The file is already fully written; only the read rate says something here.
                let rates = meter.takeRates()
                emit(.progress(job: job.id, bytes: size, readRate: rates.read, writeRate: 0))
                lastEmit = clock.now
            }
        }
        return Data(hasher.finalize())
    }

    private func checkInterruption(_ control: TransferControl) throws {
        if control.isCancelled { throw Interruption.cancelled }
        if control.takeSkip() { throw Interruption.skipped }
    }

    /// Folders that failed are remembered so what they should have held fails with them.
    private func failure(
        inheritedBy job: TransferJob, from folders: [(path: String, failure: TransferFailure)]
    ) -> TransferFailure? {
        guard !folders.isEmpty else { return nil }
        let path = Self.path(of: job.destination)
        return folders.first { path.hasPrefix($0.path + "/") }?.failure
    }

    private static func path(of url: URL) -> String { url.standardizedFileURL.path }

    /// The folders every job sits in, source side and destination side.
    private struct Roots {
        let source: URL?
        let destination: URL?

        init(_ jobs: [TransferJob]) {
            source = Self.commonAncestor(jobs.map { $0.source.deletingLastPathComponent() })
            destination = Self.commonAncestor(jobs.map { $0.destination.deletingLastPathComponent() })
        }

        private static func commonAncestor(_ urls: [URL]) -> URL? {
            guard let first = urls.first else { return nil }
            var shared = first.standardizedFileURL.pathComponents
            for url in urls.dropFirst() {
                let parts = url.standardizedFileURL.pathComponents
                let length = zip(shared, parts).prefix { $0 == $1 }.count
                shared = Array(shared.prefix(length))
            }
            guard !shared.isEmpty else { return nil }
            return URL(fileURLWithPath: NSString.path(withComponents: shared), isDirectory: true)
        }
    }

    /// An I/O error that comes with the drive's folder gone means the drive was pulled out. A folder that
    /// only some jobs sit in does not count: those are handled when the folder itself fails.
    private func adjusted(_ failure: TransferFailure, roots: Roots) -> TransferFailure {
        switch failure.reason {
        case .unreadable, .writeFailed, .sourceMissing:
            let gone = [roots.source, roots.destination].contains { root in
                if let root { !access.exists(root) } else { false }
            }
            return gone ? TransferFailure(.driveRemoved, detail: failure.detail) : failure
        default:
            return failure
        }
    }

    private static let dateTolerance: TimeInterval = 2

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
