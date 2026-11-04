import AppKit
import NTFSTransfer
import Observation

enum TransferPane {
    case left, right

    var other: TransferPane { self == .left ? .right : .left }
}

struct NamePrompt: Identifiable {
    enum Kind { case newFolder, rename(URL) }

    let id = UUID()
    let kind: Kind
}

/// A plan that has problems the person must decide about before anything is copied.
struct PendingTransfer: Identifiable {
    let id = UUID()
    let jobs: [TransferJob]
    let problems: [TransferProblem]

    /// Not enough room is a warning, not a stop: the copy can still be started and may run until the drive fills.
    var hasSpaceWarning: Bool { problems.contains { $0.isBlocking } }
    /// True when the sheet should offer "Copy anyway": the whole plan may be started despite the space warning.
    var proceedAnyway: Bool { hasSpaceWarning }
    var restOfJobs: [TransferJob] { TransferPreflight.jobs(jobs, without: problems) }
}

/// Owns everything behind the File Transfer page: the two panes, the queue, and the app-level extras.
@MainActor
@Observable
final class TransferSession {
    static let verifyKey = "TransferVerify"
    static let askOnErrorKey = "TransferAskOnError"
    static let preventSleepKey = "TransferPreventSleep"

    let queue = TransferQueue()
    let left: FileBrowserModel
    let right: FileBrowserModel
    var activePane: TransferPane = .left
    private(set) var locations = Locations.available()

    var namePrompt: NamePrompt?
    var promptText = ""
    var deleteRequest: [URL]?
    var pendingTransfer: PendingTransfer?
    var previewURL: URL?
    var alertMessage: String?

    @ObservationIgnored private let notify: @MainActor (String, String) -> Void
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastBadgePercent = -1

    init(notify: @escaping @MainActor (String, String) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        left = FileBrowserModel(folder: home)
        right = FileBrowserModel(folder: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home)
        self.notify = notify
        UserDefaults.standard.register(defaults: [Self.preventSleepKey: true])
        queue.onProgress = { [weak self] progress in self?.progressChanged(progress) }
        queue.onFinish = { [weak self] summary, stop in self?.finished(summary, stop) }
    }

    func model(for pane: TransferPane) -> FileBrowserModel { pane == .left ? left : right }
    var activeModel: FileBrowserModel { model(for: activePane) }
    var otherModel: FileBrowserModel { model(for: activePane.other) }

    func refreshLocations() { locations = Locations.available() }

    // MARK: Toolbar state

    var canCopy: Bool { !activeModel.selection.isEmpty }
    /// Delete and Rename refuse volume roots, system folders and the home folder; copying is never restricted.
    var canRename: Bool {
        let selection = activeModel.selection
        return selection.count == 1 && !selection.contains { ProtectedFolders.isProtected($0) }
    }
    var canDelete: Bool {
        let selection = activeModel.selection
        return !selection.isEmpty && !selection.contains { ProtectedFolders.isProtected($0) }
    }
    var canPreview: Bool { !activeModel.selection.isEmpty }

    // MARK: Copying

    func copyActiveToOther() {
        copy(activeModel.selectedEntries.map(\.url), into: otherModel.folder)
    }

    /// Dropping one row of a multi-selection brings the whole selection along.
    func drop(_ urls: [URL], onto pane: TransferPane) {
        var sources = urls
        let origin = model(for: pane.other)
        if urls.count == 1, origin.selection.contains(urls[0]) {
            sources = origin.selectedEntries.map(\.url)
        }
        copy(sources, into: model(for: pane).folder)
    }

    func copy(_ sources: [URL], into destination: URL) {
        guard !sources.isEmpty else { return }
        Task {
            let access = PosixFileAccess()
            do {
                let planned = try await Task.detached(priority: .userInitiated) { () throws -> ([TransferJob], VolumeInfo) in
                    let jobs = try TransferPlanner.plan(sources: sources, into: destination, access: access)
                    return (jobs, try access.volumeInfo(at: destination))
                }.value
                let rules = DestinationRules.forFileSystem(planned.1.fileSystemType)
                if let pending = Self.review(jobs: planned.0, rules: rules, freeBytes: planned.1.freeBytes) {
                    pendingTransfer = pending
                } else {
                    start(planned.0)
                }
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    /// Nil when the copy can start straight away; otherwise the plan with what the person must decide.
    static func review(jobs: [TransferJob], rules: DestinationRules, freeBytes: Int64) -> PendingTransfer? {
        let problems = TransferPreflight.check(jobs: jobs, rules: rules, freeBytes: freeBytes)
        return problems.isEmpty ? nil : PendingTransfer(jobs: jobs, problems: problems)
    }

    func start(_ jobs: [TransferJob]) {
        let defaults = UserDefaults.standard
        queue.options = TransferOptions(
            verify: defaults.bool(forKey: Self.verifyKey),
            askOnError: defaults.bool(forKey: Self.askOnErrorKey))
        if activity == nil, defaults.bool(forKey: Self.preventSleepKey) {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Copying files")
        }
        queue.enqueue(jobs)
    }

    func pasteFromPasteboard(into pane: TransferPane) {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        copy(urls, into: model(for: pane).folder)
    }

    func copyProviders(for pane: TransferPane) -> [NSItemProvider] {
        model(for: pane).selectedEntries.map { NSItemProvider(object: $0.url as NSURL) }
    }

    // MARK: Progress and finish

    private func progressChanged(_ progress: TransferProgress) {
        let percent = Int(progress.fraction * 100)
        guard percent != lastBadgePercent else { return }
        lastBadgePercent = percent
        NSApp?.dockTile.badgeLabel = queue.isBusy ? "\(percent)%" : nil
    }

    private func finished(_ summary: TransferSummary, _ stop: TransferStop) {
        endActivity()
        lastBadgePercent = -1
        NSApp?.dockTile.badgeLabel = nil
        let notice = TransferText.notice(for: summary, stop: stop)
        notify(notice.title, notice.body)
        Task {
            await left.reload()
            await right.reload()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func exportFailures() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Transfer errors.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = queue.progress.failedItems.map { item in
            let reason = item.failure.map { TransferText.failure($0.reason) } ?? ""
            let detail = item.failure?.detail ?? ""
            return "\(item.job.source.path)\t\(reason)\t\(detail)"
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Files

    func beginNewFolder() {
        promptText = String(localized: "untitled folder")
        namePrompt = NamePrompt(kind: .newFolder)
    }

    func beginRename() {
        guard canRename, let entry = activeModel.selectedEntries.first else { return }
        promptText = entry.name
        namePrompt = NamePrompt(kind: .rename(entry.url))
    }

    func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        let model = activeModel
        do {
            let created: URL
            switch prompt.kind {
            case .newFolder: created = try FileOperations.makeFolder(named: promptText, in: model.folder)
            case .rename(let url): created = try FileOperations.rename(url, to: promptText)
            }
            Task {
                await model.reload()
                model.selection = [created]
            }
        } catch {
            alertMessage = Self.message(for: error)
        }
    }

    func requestDelete() {
        let model = activeModel
        let urls = model.selectedEntries.map(\.url)
        guard canDelete, !urls.isEmpty else { return }
        let stuck = FileOperations.trash(urls)
        Task { await model.reload() }
        if !stuck.isEmpty { deleteRequest = stuck }
    }

    func confirmDelete() {
        guard let urls = deleteRequest else { return }
        deleteRequest = nil
        let model = activeModel
        do {
            try FileOperations.deletePermanently(urls)
        } catch {
            alertMessage = error.localizedDescription
        }
        Task { await model.reload() }
    }

    func preview() {
        previewURL = activeModel.selectedEntries.first?.url
    }

    func revealInFinder() {
        let urls = activeModel.selectedEntries.map(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([activeModel.folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case TransferPlanner.PlanError.destinationInsideSource:
            String(localized: "A folder can't be copied into itself.")
        case FileOperationError.invalidName:
            String(localized: "That name can't be used.")
        case FileOperationError.alreadyExists(let name):
            String(localized: "An item named “\(name)” already exists.")
        default:
            error.localizedDescription
        }
    }
}
