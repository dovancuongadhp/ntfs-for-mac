import Foundation
import Observation

/// A question from the engine waiting for the person using the app.
@MainActor
public final class ConflictRequest: Identifiable {
    public let id = UUID()
    public let info: ConflictInfo
    private var completion: ((ConflictDecision) -> Void)?

    init(info: ConflictInfo, completion: @escaping (ConflictDecision) -> Void) {
        self.info = info
        self.completion = completion
    }

    func resolve(_ decision: ConflictDecision) {
        completion?(decision)
        completion = nil
    }
}

@MainActor
public final class ErrorRequest: Identifiable {
    public let id = UUID()
    public let info: ErrorInfo
    private var completion: ((ErrorDecision) -> Void)?

    init(info: ErrorInfo, completion: @escaping (ErrorDecision) -> Void) {
        self.info = info
        self.completion = completion
    }

    func resolve(_ decision: ErrorDecision) {
        completion?(decision)
        completion = nil
    }
}

/// Runs batches of jobs one after another and holds everything the progress panel shows.
@MainActor
@Observable
public final class TransferQueue {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case paused
        /// Out of space or a drive was removed: waiting for `resume()`.
        case stopped(TransferStop)
        case finished
    }

    public private(set) var progress = TransferProgress()
    public private(set) var phase: Phase = .idle
    public private(set) var summary: TransferSummary?
    public private(set) var conflict: ConflictRequest?
    public private(set) var errorPrompt: ErrorRequest?
    /// Read when a batch starts, so changes apply to the next batch.
    public var options = TransferOptions()

    @ObservationIgnored public var onProgress: (@MainActor (TransferProgress) -> Void)?
    @ObservationIgnored public var onFinish: (@MainActor (TransferSummary, TransferStop) -> Void)?

    @ObservationIgnored private let access: any FileAccess
    @ObservationIgnored private var control = TransferControl()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var batches: [[TransferJob]] = []
    @ObservationIgnored private var nextID = 0

    public init(access: any FileAccess = PosixFileAccess()) {
        self.access = access
    }

    public var isBusy: Bool { phase == .running || phase == .paused }

    private var isHalted: Bool {
        if case .stopped = phase { true } else { false }
    }

    // MARK: Commands

    public func enqueue(_ jobs: [TransferJob]) {
        guard !jobs.isEmpty else { return }
        if phase == .finished || phase == .idle {
            progress = TransferProgress()
            summary = nil
        }
        let numbered = jobs.map { job -> TransferJob in
            var job = job
            job.id = nextID
            nextID += 1
            return job
        }
        progress.append(numbered)
        batches.append(numbered)
        if task == nil, !isHalted { startNext() }
    }

    public func pause() {
        guard phase == .running else { return }
        control.pause()
        phase = .paused
    }

    public func resume() {
        switch phase {
        case .paused:
            control.resume()
            phase = .running
        case .stopped:
            summary = nil
            startNext()
        default:
            break
        }
    }

    public func skipCurrent() { control.skipCurrent() }

    public func cancel() {
        guard isBusy || isHalted else { return }
        control.cancel()
        answer(ConflictDecision(choice: .skip))
        answerError(ErrorDecision(choice: .skip))
        if task == nil {
            if isHalted { removeLeftoverTemporaryFiles() }
            batches.removeAll()
            progress.cancelRemaining()
            finish(.cancelled)
        }
    }

    /// Best effort: a stopped run leaves nothing behind for files that never started, but a
    /// half-written copy may have been left by a drive that was pulled out.
    private func removeLeftoverTemporaryFiles() {
        for job in batches.joined() where job.kind == .file {
            let folder = job.destination.deletingLastPathComponent()
            let temp = folder.appending(component: ".\(job.destination.lastPathComponent).ntfs-part")
            if access.exists(temp) { try? access.remove(temp) }
        }
    }

    public func cancelAndWait() async {
        cancel()
        await task?.value
    }

    /// Runs the failed files again.
    public func retryFailed() {
        let jobs = progress.resetFailed()
        guard !jobs.isEmpty else { return }
        summary = nil
        batches.append(jobs)
        if task == nil, !isHalted { startNext() }
    }

    /// Empties a finished list.
    public func clear() {
        guard !isBusy, !isHalted else { return }
        progress = TransferProgress()
        summary = nil
        phase = .idle
    }

    public func answer(_ decision: ConflictDecision) {
        let request = conflict
        conflict = nil
        request?.resolve(decision)
    }

    public func answerError(_ decision: ErrorDecision) {
        let request = errorPrompt
        errorPrompt = nil
        request?.resolve(decision)
    }

    // MARK: Running

    private func startNext() {
        guard task == nil, !batches.isEmpty else { return }
        let jobs = batches.removeFirst()
        control = TransferControl()
        let control = control
        phase = .running
        let engine = TransferEngine(access: access, options: options)
        let prompts = TransferPrompts(
            conflict: { [weak self] info in
                await self?.askConflict(info, control: control) ?? ConflictDecision(choice: .skip)
            },
            error: { [weak self] info in
                await self?.askError(info, control: control) ?? ErrorDecision(choice: .skip)
            })
        task = Task { [weak self] in
            let (events, continuation) = AsyncStream<TransferEvent>.makeStream()
            let runner = Task.detached(priority: .utility) {
                let outcome = await engine.run(jobs: jobs, control: control, prompts: prompts) { continuation.yield($0) }
                continuation.finish()
                return outcome
            }
            for await event in events {
                self?.apply(event)
            }
            let outcome = await runner.value
            self?.runEnded(outcome)
        }
    }

    private func apply(_ event: TransferEvent) {
        progress.apply(event, at: Date())
        onProgress?(progress)
    }

    /// A prompt that reaches the main actor after `cancel()` has nobody left to answer it.
    private func askConflict(_ info: ConflictInfo, control: TransferControl) async -> ConflictDecision {
        if control.isCancelled { return ConflictDecision(choice: .skip) }
        return await withCheckedContinuation { continuation in
            conflict = ConflictRequest(info: info) { continuation.resume(returning: $0) }
        }
    }

    private func askError(_ info: ErrorInfo, control: TransferControl) async -> ErrorDecision {
        if control.isCancelled { return ErrorDecision(choice: .skip) }
        return await withCheckedContinuation { continuation in
            errorPrompt = ErrorRequest(info: info) { continuation.resume(returning: $0) }
        }
    }

    private func runEnded(_ outcome: TransferOutcome) {
        task = nil
        progress.interrupted()
        switch outcome.stop {
        case .finished:
            if batches.isEmpty { finish(.finished) } else { startNext() }
        case .cancelled, .userStopped:
            batches.removeAll()
            progress.cancelRemaining()
            finish(outcome.stop)
        case .noSpace, .driveRemoved:
            batches.insert(outcome.remaining, at: 0)
            phase = .stopped(outcome.stop)
            let summary = progress.summary()
            self.summary = summary
            onProgress?(progress)
            onFinish?(summary, outcome.stop)
        }
    }

    private func finish(_ stop: TransferStop) {
        phase = .finished
        let summary = progress.summary()
        self.summary = summary
        onProgress?(progress)
        onFinish?(summary, stop)
    }
}
