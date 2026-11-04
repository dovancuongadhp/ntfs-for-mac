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
    var hasSpaceWarning: Bool {
        problems.contains { if case .notEnoughSpace = $0 { true } else { false } }
    }
    /// True when the sheet should offer "Copy anyway": the whole plan may be started despite the space warning.
    var proceedAnyway: Bool { hasSpaceWarning }
    var restOfJobs: [TransferJob] { TransferPreflight.jobs(jobs, without: problems) }

    /// What the alert offers besides Cancel.
    enum Choice: Equatable {
        /// "Copy anyway": start despite the space warning (files with unusable names are still left out).
        case copyAnyway
        /// "Copy the Rest": start without the files that can't be stored.
        case copyTheRest
    }

    /// Nil when there is nothing left that could be copied, so only Cancel makes sense.
    var choice: Choice? {
        guard !restOfJobs.isEmpty else { return nil }
        return proceedAnyway ? .copyAnyway : .copyTheRest
    }
}

/// Owns everything behind the File Transfer page: the two panes, the queue, and the app-level extras.
@MainActor
@Observable
final class TransferSession {
    static let verifyKey = "TransferVerify"
    static let askOnErrorKey = "TransferAskOnError"
    static let preventSleepKey = "TransferPreventSleep"

    let queue: TransferQueue
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
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let beginActivity: @MainActor () -> NSObjectProtocol
    @ObservationIgnored private let endActivityHandler: @MainActor (NSObjectProtocol) -> Void
    @ObservationIgnored private let requestAttention: @MainActor () -> Void
    @ObservationIgnored private let isForeground: @MainActor () -> Bool
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastBadgePercent = -1

    /// Everything after `notify` exists so tests can stand in for the real queue, home folder, settings and
    /// the system's sleep assertion; the app uses the defaults.
    init(
        notify: @escaping @MainActor (String, String) -> Void,
        queue: TransferQueue = TransferQueue(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        beginActivity: @escaping @MainActor () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: String(localized: "Copying files"))
        },
        endActivity: @escaping @MainActor (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) },
        requestAttention: @escaping @MainActor () -> Void = { NSApp?.requestUserAttention(.criticalRequest) },
        isForeground: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? true }
    ) {
        self.queue = queue
        self.home = home
        self.defaults = defaults
        self.beginActivity = beginActivity
        endActivityHandler = endActivity
        self.requestAttention = requestAttention
        self.isForeground = isForeground
        left = FileBrowserModel(folder: home)
        right = FileBrowserModel(folder: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home)
        self.notify = notify
        defaults.register(defaults: [Self.preventSleepKey: true])
        queue.onProgress = { [weak self] progress in self?.progressChanged(progress) }
        queue.onFinish = { [weak self] summary, stop in self?.finished(summary, stop) }
        queue.onPrompt = { [weak self] in self?.promptAppeared() }
    }

    func model(for pane: TransferPane) -> FileBrowserModel { pane == .left ? left : right }
    var activeModel: FileBrowserModel { model(for: activePane) }
    var otherModel: FileBrowserModel { model(for: activePane.other) }

    func refreshLocations() { locations = Locations.available() }

    /// A drive was mounted or unmounted: the places menu, the panes and their free space follow.
    func volumesChanged() {
        refreshLocations()
        Task {
            await recoverPanes()
            await left.reload()
            await right.reload()
        }
    }

    /// Lists a pane again, and the places in its menu.
    func refresh(_ pane: TransferPane) async {
        refreshLocations()
        await recoverPanes()
        await model(for: pane).reload()
    }

    /// Moves a pane whose folder is gone (a drive was unmounted, a folder deleted) somewhere that exists.
    /// The file system is asked off the main actor, so a slow or half-gone volume can't freeze the window.
    func recoverPanes() async {
        let panes = [left, right]
        let asked = panes.map(\.folder)
        let home = home
        let targets = await Task.detached(priority: .userInitiated) {
            asked.map { Self.recoveredFolder(for: $0, home: home) }
        }.value
        for (pane, (folder, target)) in zip(panes, zip(asked, targets)) {
            // The person may have opened another folder while we were asking.
            if let target, pane.folder == folder { pane.open(target) }
        }
    }

    /// Nil while the folder exists. Otherwise the closest enclosing folder that does, or the home folder
    /// when that is as far as a missing volume leaves us (`/Volumes` itself, the root, or the empty folder
    /// the system leaves behind where a volume was mounted).
    nonisolated static func recoveredFolder(
        for folder: URL, home: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isVolumeStub: (URL) -> Bool = TransferSession.isUnmountedVolumeFolder
    ) -> URL? {
        guard !exists(folder) else { return nil }
        var candidate = folder.standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/", !exists(candidate) {
            candidate = candidate.deletingLastPathComponent()
        }
        if candidate.path == "/" || candidate.path == "/Volumes" || isVolumeStub(candidate) { return home }
        return candidate
    }

    /// A folder directly inside /Volumes that nothing is mounted on: it belongs to the volume the pane was
    /// showing, not to anything the person can use.
    nonisolated static func isUnmountedVolumeFolder(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == "/Volumes" else { return false }
        guard let mountPoint = try? resolved.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return mountPoint.resolvingSymlinksInPath().path != resolved.path
    }

    /// Set by the page while it is on screen, so a question that comes up elsewhere can ask for attention.
    @ObservationIgnored var pageVisible = false

    /// A conflict or error question is waiting for an answer.
    var waitingForAnswer: Bool { queue.conflict != nil || queue.errorPrompt != nil }

    /// What the File Transfer row in the sidebar shows.
    enum SidebarStatus: Equatable {
        case none
        /// Copying, or paused by the user.
        case working
        /// The copy can't go on until the person acts: a question is open, or it halted (drive full or removed).
        case needsAnswer
    }

    var sidebarStatus: SidebarStatus {
        if waitingForAnswer { return .needsAnswer }
        switch queue.phase {
        case .stopped: return .needsAnswer
        case .running, .paused: return .working
        case .idle, .finished: return .none
        }
    }

    // MARK: Toolbar state

    var canCopy: Bool { !activeModel.selection.isEmpty }
    /// Delete and Rename refuse volume roots, system folders and the home folder; copying is never restricted.
    var canRename: Bool {
        let selection = activeModel.selection
        return selection.count == 1 && !ProtectedFolders.containsProtected(selection, home: home)
    }
    var canDelete: Bool {
        let selection = activeModel.selection
        return !selection.isEmpty && !ProtectedFolders.containsProtected(selection, home: home)
    }
    var canPreview: Bool { !activeModel.selection.isEmpty }

    // MARK: Copying

    func copyActiveToOther() {
        copy(activeModel.selectedEntries.map(\.url), into: otherModel.folder)
    }

    /// Dropping one row of a multi-selection brings the whole selection along.
    @discardableResult
    func drop(_ urls: [URL], onto pane: TransferPane) -> Bool {
        // A web address or text dragged in has no file to copy.
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        var sources = files
        let origin = model(for: pane.other)
        if files.count == 1, origin.selection.contains(files[0]) {
            sources = origin.selectedEntries.map(\.url)
        }
        let destination = model(for: pane).folder
        // Items dropped on the folder they already sit in would only be copied next to themselves.
        let moving = Self.leavingOut(itemsIn: destination, from: sources)
        guard !moving.isEmpty else { return false }
        copy(moving, into: destination)
        return true
    }

    /// `sources` without the ones whose enclosing folder is `folder`.
    static func leavingOut(itemsIn folder: URL, from sources: [URL]) -> [URL] {
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var memo: [String: Bool] = [:]
        return sources.filter { source in
            let parent = source.deletingLastPathComponent()
            let inside: Bool
            if let known = memo[parent.path] {
                inside = known
            } else {
                inside = parent.resolvingSymlinksInPath().standardizedFileURL.path == target
                memo[parent.path] = inside
            }
            return !inside
        }
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
        guard !jobs.isEmpty else { return }
        queue.options = TransferOptions(
            verify: defaults.bool(forKey: Self.verifyKey),
            askOnError: defaults.bool(forKey: Self.askOnErrorKey))
        queue.enqueue(jobs)
        syncActivity()
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

    /// A copy stops at a question until it is answered. If nobody is looking at the page, say so: a
    /// notification, and the Dock icon bounces.
    private func promptAppeared() {
        guard !pageVisible || !isForeground() else { return }
        let notice = TransferText.promptNotice()
        notify(notice.title, notice.body)
        requestAttention()
    }

    private func progressChanged(_ progress: TransferProgress) {
        syncActivity()
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

    /// Keeps the Mac awake exactly while the queue is busy (running or paused). A queue that is idle,
    /// finished or stopped on a full or removed drive holds nothing; resuming makes it busy again, and the
    /// next progress report takes the hold back.
    private func syncActivity() {
        if queue.isBusy {
            if activity == nil, defaults.bool(forKey: Self.preventSleepKey) { activity = beginActivity() }
        } else {
            endActivity()
        }
    }

    private func endActivity() {
        if let activity { endActivityHandler(activity) }
        activity = nil
    }

    /// The name the save panel starts with; the extension is not part of the translated text.
    static var exportFileName: String { String(localized: "Transfer errors") + ".txt" }

    func exportFailures() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportFileName
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
