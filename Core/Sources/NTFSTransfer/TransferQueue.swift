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

    /// Always current when read. Observers hear about changes at most `progressInterval` apart, and at once
    /// when the queue's phase changes or it finishes, so a long list is not redrawn on every event.
    public var progress: TransferProgress {
        _$observationRegistrar.access(self, keyPath: \.progress)
        return current
    }
    public private(set) var phase: Phase = .idle
    public private(set) var summary: TransferSummary?
    /// Why the queue last ended or halted; nil while a copy is under way or after `clear()`.
    public private(set) var lastStop: TransferStop?
    /// The least time between two reports of progress to observers and `onProgress`.
    public var progressInterval: Duration = .milliseconds(125)
    public private(set) var conflict: ConflictRequest?
    public private(set) var errorPrompt: ErrorRequest?
    /// Read when a batch starts, so changes apply to the next batch.
    public var options = TransferOptions()

    @ObservationIgnored public var onProgress: (@MainActor (TransferProgress) -> Void)?
    @ObservationIgnored public var onPrompt: (@MainActor () -> Void)?
    @ObservationIgnored public var onFinish: (@MainActor (TransferSummary, TransferStop) -> Void)?

    @ObservationIgnored private var current = TransferProgress()
    @ObservationIgnored private var lastReport: ContinuousClock.Instant?
    @ObservationIgnored private var reportOwed = false
    @ObservationIgnored private var reportTask: Task<Void, Never>?
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
            current = TransferProgress()
            summary = nil
            lastStop = nil
        }
        let numbered = jobs.map { job -> TransferJob in
            var job = job
            job.id = nextID
            nextID += 1
            return job
        }
        current.append(numbered)
        batches.append(numbered)
        if task == nil, !isHalted { startNext() }
        reportProgress()
    }

    public func pause() {
        guard phase == .running else { return }
        control.pause()
        phase = .paused
        reportProgress()
    }

    public func resume() {
        switch phase {
        case .paused:
            control.resume()
            phase = .running
            reportProgress()
        case .stopped:
            summary = nil
            lastStop = nil
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
            current.cancelRemaining()
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
        let jobs = current.resetFailed()
        guard !jobs.isEmpty else { return }
        summary = nil
        lastStop = nil
        batches.append(jobs)
        if task == nil, !isHalted { startNext() }
        reportProgress()
    }

    /// Empties a finished list.
    public func clear() {
        guard !isBusy, !isHalted else { return }
        current = TransferProgress()
        summary = nil
        lastStop = nil
        phase = .idle
        reportProgress()
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

    /// Answers `request` only while it is still the question being asked. A click that reaches a sheet after
    /// its question was answered (or replaced by the next one) is ignored, so it cannot answer a question
    /// the person has not seen.
    public func answer(_ decision: ConflictDecision, for request: ConflictRequest) {
        guard conflict === request else { return }
        answer(decision)
    }

    public func answerError(_ decision: ErrorDecision, for request: ErrorRequest) {
        guard errorPrompt === request else { return }
        answerError(decision)
    }

    // MARK: Running

    private func startNext() {
        guard task == nil, !batches.isEmpty else { return }
        let jobs = batches.removeFirst()
        control = TransferControl()
        let control = control
        phase = .running
        reportProgress()
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
        current.apply(event, at: Date())
        reportProgressSoon()
    }

    /// Tells observers and `onProgress` now, whatever was reported last.
    private func reportProgress() {
        reportTask?.cancel()
        reportTask = nil
        reportOwed = false
        lastReport = .now
        _$observationRegistrar.withMutation(of: self, keyPath: \.progress) {}
        onProgress?(current)
    }

    /// Tells them now if the last report is old enough; otherwise once, when it will be.
    private func reportProgressSoon() {
        let now = ContinuousClock.now
        guard let last = lastReport, now - last < progressInterval else {
            reportProgress()
            return
        }
        reportOwed = true
        guard reportTask == nil else { return }
        let wait = progressInterval - (now - last)
        reportTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            reportTask = nil
            if reportOwed { reportProgress() }
        }
    }

    /// A prompt that reaches the main actor after `cancel()` has nobody left to answer it.
    private func askConflict(_ info: ConflictInfo, control: TransferControl) async -> ConflictDecision {
        if control.isCancelled { return ConflictDecision(choice: .skip) }
        return await withCheckedContinuation { continuation in
            conflict = ConflictRequest(info: info) { continuation.resume(returning: $0) }
            reportProgress()
            onPrompt?()
        }
    }

    private func askError(_ info: ErrorInfo, control: TransferControl) async -> ErrorDecision {
        if control.isCancelled { return ErrorDecision(choice: .skip) }
        return await withCheckedContinuation { continuation in
            errorPrompt = ErrorRequest(info: info) { continuation.resume(returning: $0) }
            reportProgress()
            onPrompt?()
        }
    }

    private func runEnded(_ outcome: TransferOutcome) {
        task = nil
        current.interrupted()
        // The engine has nothing left to notice a cancel that came during its last file, and says it finished.
        let stop = outcome.stop == .finished && control.isCancelled ? TransferStop.cancelled : outcome.stop
        switch stop {
        case .finished:
            if batches.isEmpty { finish(.finished) } else { startNext() }
        case .cancelled, .userStopped:
            batches.removeAll()
            current.cancelRemaining()
            finish(stop)
        case .noSpace, .driveRemoved:
            batches.insert(outcome.remaining, at: 0)
            phase = .stopped(outcome.stop)
            lastStop = outcome.stop
            let summary = current.summary()
            self.summary = summary
            reportProgress()
            onFinish?(summary, outcome.stop)
        }
    }

    private func finish(_ stop: TransferStop) {
        phase = .finished
        lastStop = stop
        let summary = current.summary()
        self.summary = summary
        reportProgress()
        onFinish?(summary, stop)
    }
}
