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
    /// The items of earlier copies, newest copy first, kept until `clear()`. `progress` covers the latest copy only.
    public private(set) var history: [TransferItem] = []
    public private(set) var summary: TransferSummary?
    /// Why the queue last ended or halted; nil while a copy is under way or after `clear()`.
    public private(set) var lastStop: TransferStop?
    /// The least time between two reports of progress to observers and `onProgress`.
    public var progressInterval: Duration = .milliseconds(125)
    public private(set) var conflict: ConflictRequest?
    public private(set) var errorPrompt: ErrorRequest?
    /// How the queue waits before a held-back report; tests replace it.
    @ObservationIgnored package var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
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

    @ObservationIgnored private var historyFailures = 0

    /// Where each copy starts among the job numbers, which only grow, so a job belongs to the last copy
    /// that starts at or before it, retried or not.
    public struct CopyRecord: Sendable, Equatable, Codable {
        let firstJobID: Int
        let started: Date
        let from: URL
        let to: URL
    }

    private var copies: [CopyRecord] = []

    /// Every copy and file still kept, to be saved and given back to `restore(_:)` after the app restarts.
    public struct Log: Sendable, Equatable, Codable {
        var copies: [CopyRecord]
        var items: [TransferItem]
    }

    public var log: Log {
        Log(copies: copies, items: progress.items + history)
    }

    /// Takes back a saved log into a queue that has not copied anything yet. Files that were under way
    /// when the app quit did not finish, so they come back skipped.
    public func restore(_ log: Log) {
        guard phase == .idle, copies.isEmpty, current.items.isEmpty else { return }
        history = log.items.map { item in
            guard item.state == .waiting || item.state == .copying else { return item }
            var item = item
            item.state = .skipped
            item.bytesDone = 0
            return item
        }
        historyFailures = history.count { $0.failure != nil }
        copies = log.copies.sorted { $0.firstJobID < $1.firstJobID }
        let lastID = max(log.items.map(\.id).max() ?? -1, copies.last?.firstJobID ?? -1)
        nextID = max(nextID, lastID + 1)
        reportProgress()
    }

    /// Every copy still kept, newest first, each with its own files and totals.
    public var groups: [TransferGroup] {
        guard !copies.isEmpty else { return [] }
        var buckets = [[TransferItem]](repeating: [], count: copies.count)
        for item in progress.items + history {
            guard let index = copyIndex(of: item.id) else { continue }
            buckets[index].append(item)
        }
        return zip(copies, buckets).reversed().compactMap { record, items in
            items.isEmpty ? nil : TransferGroup(record: record, items: items.sorted { $0.id < $1.id })
        }
    }

    private func copyIndex(of jobID: Int) -> Int? {
        var low = 0
        var high = copies.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if copies[middle].firstJobID <= jobID {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// The folders of the items picked, the top of what the copy creates, rather than of the files inside them.
    private static func record(of jobs: [TransferJob], firstJobID: Int) -> CopyRecord {
        let top = jobs.min { $0.source.pathComponents.count < $1.source.pathComponents.count } ?? jobs[0]
        return CopyRecord(
            firstJobID: firstJobID, started: Date(),
            from: top.source.deletingLastPathComponent(), to: top.destination.deletingLastPathComponent())
    }

    public var isBusy: Bool { phase == .running || phase == .paused }

    /// Failures in the latest copy and in the history.
    public var failedCount: Int { progress.failedCount + historyFailures }

    public var failedItems: [TransferItem] {
        progress.failedItems + (historyFailures > 0 ? history.filter { $0.failure != nil } : [])
    }

    private var isHalted: Bool {
        if case .stopped = phase { true } else { false }
    }

    // MARK: Commands

    public func enqueue(_ jobs: [TransferJob]) {
        guard !jobs.isEmpty else { return }
        if phase == .finished || phase == .idle {
            history = current.items + history
            historyFailures += current.failedCount
            current = TransferProgress()
            summary = nil
            lastStop = nil
        }
        copies.append(Self.record(of: jobs, firstJobID: nextID))
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
            let temp = job.tempURL
            if access.exists(temp) { try? access.remove(temp) }
        }
    }

    public func cancelAndWait() async {
        cancel()
        await task?.value
    }

    /// Runs the failed files again, those of earlier copies too: they move from the history into the latest copy.
    public func retryFailed() {
        var jobs = current.resetFailed()
        if historyFailures > 0 {
            let earlier = history.filter { $0.failure != nil }.map(\.job)
            history.removeAll { $0.failure != nil }
            historyFailures = 0
            current.append(earlier)
            jobs += earlier
        }
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
        history = []
        copies = []
        historyFailures = 0
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
        // Carry the paused state across batches so a pause issued during one batch
        // also holds the next batch until the person explicitly resumes.
        if phase == .paused { control.pause() }
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
        let sleep = sleep
        reportTask = Task { [weak self] in
            await sleep(wait)
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
