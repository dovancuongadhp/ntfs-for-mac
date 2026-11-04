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
            control.clearSkip()
            emit(.started(job: job.id))
            let step = await perform(job, control: control, prompts: prompts, conflictMemo: &conflictMemo, emit: emit)
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
        _ job: TransferJob, control: TransferControl, prompts: TransferPrompts,
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
                return .failed(adjusted(.classify(error, reading: false), for: job))
            }
        case .file, .symlink:
            let destination: URL
            switch await resolveConflict(job, prompts: prompts, memo: &conflictMemo) {
            case .proceed(let url): destination = url
            case .skip: return .skipped
            case .failed(let failure): return .failed(failure)
            }
            if case .symlink(let target) = job.kind {
                do {
                    if access.exists(destination) { try access.remove(destination) }
                    try access.makeLink(at: destination, target: target)
                    return .done(0)
                } catch {
                    return .failed(adjusted(.classify(error, reading: false), for: job))
                }
            }
            return await copy(job, to: destination, control: control, emit: emit)
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
        case .replaceIfNewer: return job.modified > existing.modified ? .proceed(job.destination) : .skip
        }
    }

    private func copy(
        _ job: TransferJob, to destination: URL, control: TransferControl,
        emit: @Sendable (TransferEvent) -> Void
    ) async -> Step {
        let temp = destination.deletingLastPathComponent().appending(component: ".\(destination.lastPathComponent).ntfs-part")
        var reader: (any FileReading)?
        var writer: (any FileWriting)?
        var reading = true

        func cleanUp() {
            reader?.close()
            reader = nil
            try? writer?.close()
            writer = nil
            try? access.remove(temp)
        }

        do {
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
                await control.waitWhilePaused()
                if control.isCancelled { continue }

                reading = true
                let readStart = clock.now
                let chunk = try reader!.read(upTo: options.chunkSize)
                meter.addRead(bytes: chunk.count, seconds: Self.seconds(clock.now - readStart))
                if chunk.isEmpty { break }
                if options.verify { hasher.update(data: chunk) }

                reading = false
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
            if options.verify, try hash(of: temp) != Data(hasher.finalize()) {
                throw TransferFailure(.checksumMismatch)
            }
            try access.rename(temp, to: destination)
            access.copyMetadata(from: job.source, to: destination)
            return .done(done)
        } catch let failure as TransferFailure {
            cleanUp()
            return .failed(failure)
        } catch {
            cleanUp()
            return .failed(adjusted(.classify(error, reading: reading), for: job, destination: destination))
        }
    }

    private func hash(of url: URL) throws -> Data {
        let reader = try access.openForReading(url)
        defer { reader.close() }
        var hasher = SHA256()
        while true {
            let chunk = try reader.read(upTo: options.chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// An I/O error on a folder that has vanished means a drive was pulled out.
    private func adjusted(_ failure: TransferFailure, for job: TransferJob, destination: URL? = nil) -> TransferFailure {
        switch failure.reason {
        case .unreadable, .writeFailed, .sourceMissing:
            let destinationFolder = (destination ?? job.destination).deletingLastPathComponent()
            if !access.exists(job.source.deletingLastPathComponent()) || !access.exists(destinationFolder) {
                return TransferFailure(.driveRemoved, detail: failure.detail)
            }
            return failure
        default:
            return failure
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
