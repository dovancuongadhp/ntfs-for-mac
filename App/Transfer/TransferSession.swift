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

/// Items waiting for the person to confirm that they are deleted for good.
struct DeleteRequest: Equatable {
    enum Reason: Equatable {
        /// They were sent to the Trash, but their volume has none.
        case noTrash
        /// The person asked to delete them immediately (Shift-Delete, Option-Command-Delete).
        case chosen
    }

    let urls: [URL]
    let reason: Reason
}

/// A copied folder whose name is already taken in the destination, waiting for Keep Both, Merge or Skip.
struct FolderClash: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// The folder it would be copied into.
    let destinationName: String
    /// No other clash follows, so "Apply to all" has nothing to apply to.
    let isLast: Bool
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
    var restOfJobs: [TransferJob] {
        // A blocking problem (read-only destination) means nothing can be copied.
        guard !problems.contains(where: \.isBlocking) else { return [] }
        return TransferPreflight.jobs(jobs, without: problems)
    }

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
    var deleteRequest: DeleteRequest?
    var pendingTransfer: PendingTransfer?
    private(set) var folderClash: FolderClash?
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
    @ObservationIgnored private var lastPaneReload = Date.distantPast
    @ObservationIgnored private var lastCopyRequest: (paths: [String], at: Date) = ([], .distantPast)
    @ObservationIgnored private var folderClashReply: CheckedContinuation<(TransferPlanner.FolderChoice, Bool)?, Never>?
    @ObservationIgnored private let logURL: URL?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSave: Task<Void, Never>?

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
        isForeground: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? true },
        logURL: URL? = nil
    ) {
        self.queue = queue
        self.logURL = logURL
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
        if let logURL, let log = TransferLog.load(from: logURL) { queue.restore(log) }
        if logURL != nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLog(waiting: true) }
            }
        }
    }

    /// Where the app keeps the copy log between launches.
    static var defaultLogURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: Bundle.main.bundleIdentifier ?? "NTFS for Mac").appending(path: "TransferLog.json")
    }

    /// Empties the progress list and the saved log; nothing else forgets it.
    func clearLog() {
        queue.clear()
        saveLog()
    }

    /// Writes the log off the main actor, one write after another so an older log never lands last, or
    /// right away when the app is quitting.
    private func saveLog(waiting: Bool = false) {
        guard let logURL else { return }
        let log = queue.log
        if waiting {
            try? TransferLog.save(log, to: logURL)
            return
        }
        let previous = lastSave
        lastSave = Task.detached(priority: .utility) {
            await previous?.value
            try? TransferLog.save(log, to: logURL)
        }
    }

    /// The latest write of the log; tests wait for it.
    func logSaved() async { await lastSave?.value }

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

    /// The side whose file list has keyboard focus; nil while typing in a field or anywhere else.
    @ObservationIgnored var focusedList: TransferPane?

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

    /// What the menu bar panel shows about the copy.
    enum MenuStatus: Equatable {
        case none
        case copying
        case paused
        /// A question is open, or the copy halted: the person has to act.
        case waiting
    }

    static func menuStatus(phase: TransferQueue.Phase, waitingForAnswer: Bool) -> MenuStatus {
        switch phase {
        case .stopped: .waiting
        case .running, .paused:
            if waitingForAnswer { .waiting } else { phase == .paused ? .paused : .copying }
        case .idle, .finished: .none
        }
    }

    var menuStatus: MenuStatus { Self.menuStatus(phase: queue.phase, waitingForAnswer: waitingForAnswer) }

    // MARK: Toolbar state

    var canCopy: Bool { !activeModel.actionableSelection.isEmpty }
    /// Delete and Rename refuse volume roots, system folders and the home folder; copying is never restricted.
    var canRename: Bool {
        let selection = activeModel.actionableSelection
        return selection.count == 1 && !ProtectedFolders.containsProtected(selection, home: home)
    }
    var canDelete: Bool {
        let selection = activeModel.actionableSelection
        return !selection.isEmpty && !ProtectedFolders.containsProtected(selection, home: home)
    }
    var canPreview: Bool { !activeModel.actionableSelection.isEmpty }

    // MARK: Copying

    func copyActiveToOther() {
        copy(activeModel.selectedEntries.map(\.url), into: otherModel.folder, duplicate: true)
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

    func copy(_ sources: [URL], into destination: URL, duplicate: Bool = false) {
        guard !sources.isEmpty else { return }
        // SwiftUI can deliver one drop or paste twice; the second would copy everything again.
        let request = ([destination] + sources).map(\.standardizedFileURL.path)
        if request == lastCopyRequest.paths, Date.now.timeIntervalSince(lastCopyRequest.at) < 1 { return }
        lastCopyRequest = (request, .now)
        Task {
            let access = PosixFileAccess()
            do {
                let clashes = try await Task.detached(priority: .userInitiated) {
                    try TransferPlanner.clashingFolders(sources: sources, into: destination, access: access)
                }.value
                guard let choices = await askAboutFolders(clashes, in: destination) else { return }
                let planned = try await Task.detached(priority: .userInitiated) { () throws -> ([TransferJob], VolumeInfo) in
                    let jobs = try TransferPlanner.plan(
                        sources: sources, into: destination, access: access, duplicate: duplicate, folderChoices: choices)
                    return (jobs, try access.volumeInfo(at: destination))
                }.value
                let rules = DestinationRules.forFileSystem(planned.1.fileSystemType)
                if let pending = Self.review(
                    jobs: planned.0, rules: rules, freeBytes: planned.1.freeBytes,
                    destinationReadOnly: planned.1.isReadOnly) {
                    pendingTransfer = pending
                } else {
                    start(planned.0)
                }
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    /// Asks about each folder that is already there, one at a time, until "Apply to all". Nil when cancelled.
    private func askAboutFolders(_ clashes: [URL], in destination: URL) async -> [String: TransferPlanner.FolderChoice]? {
        var choices: [String: TransferPlanner.FolderChoice] = [:]
        var forAll: TransferPlanner.FolderChoice?
        for (index, folder) in clashes.enumerated() {
            let choice: TransferPlanner.FolderChoice
            if let forAll {
                choice = forAll
            } else {
                let clash = FolderClash(
                    name: folder.lastPathComponent, destinationName: destination.lastPathComponent,
                    isLast: index == clashes.count - 1)
                // A copy started while an earlier one is still asking replaces it: the earlier one is cancelled.
                answerFolderClash(nil)
                let reply = await withCheckedContinuation { continuation in
                    folderClashReply = continuation
                    folderClash = clash
                }
                guard let (answer, applyToAll) = reply else { return nil }
                choice = answer
                if applyToAll { forAll = answer }
            }
            choices[folder.standardizedFileURL.path] = choice
        }
        return choices
    }

    /// Nil cancels the whole copy.
    func answerFolderClash(_ choice: TransferPlanner.FolderChoice?, applyToAll: Bool = false) {
        guard let reply = folderClashReply else { return }
        folderClashReply = nil
        folderClash = nil
        reply.resume(returning: choice.map { ($0, applyToAll) })
    }

    /// Nil when the copy can start straight away; otherwise the plan with what the person must decide.
    static func review(
        jobs: [TransferJob], rules: DestinationRules, freeBytes: Int64,
        destinationReadOnly: Bool = false
    ) -> PendingTransfer? {
        let problems = TransferPreflight.check(
            jobs: jobs, rules: rules, freeBytes: freeBytes, destinationReadOnly: destinationReadOnly)
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
        copy(urls, into: model(for: pane).folder, duplicate: true)
    }

    /// Puts the selected items on the clipboard, so they can be pasted in a pane or in Finder.
    func copyToPasteboard(from pane: TransferPane) {
        let urls = model(for: pane).selectedEntries.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    var pasteboardHasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
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

    /// True when the person is looking at the page, in the app that is in front.
    static func finishNoticeIsRedundant(pageVisible: Bool, isForeground: Bool) -> Bool {
        pageVisible && isForeground
    }

    private func progressChanged(_ progress: TransferProgress) {
        syncActivity()
        if queue.isBusy, Date.now.timeIntervalSince(lastPaneReload) >= 2 {
            lastPaneReload = .now
            Task {
                await left.reload()
                await right.reload()
            }
        }
        let percent = Int(progress.fraction * 100)
        guard percent != lastBadgePercent else { return }
        lastBadgePercent = percent
        NSApp?.dockTile.badgeLabel = queue.isBusy ? "\(percent)%" : nil
    }

    private func finished(_ summary: TransferSummary, _ stop: TransferStop) {
        saveLog()
        endActivity()
        lastBadgePercent = -1
        NSApp?.dockTile.badgeLabel = nil
        // The page shows the result itself: a banner and a beep on top of that only startle.
        if !Self.finishNoticeIsRedundant(pageVisible: pageVisible, isForeground: isForeground()) {
            let notice = TransferText.notice(for: summary, stop: stop)
            notify(notice.title, notice.body)
        }
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
        let lines = queue.failedItems.map { item in
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
        let text = promptText
        let folder = model.folder          // capture off-actor-safe value type
        Task {
            do {
                let created = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    switch prompt.kind {
                    case .newFolder: return try FileOperations.makeFolder(named: text, in: folder)
                    case .rename(let url): return try FileOperations.rename(url, to: text)
                    }
                }.value
                await model.reload()
                model.selection = [created]
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    func requestDelete() {
        let model = activeModel
        let urls = model.selectedEntries.map(\.url)
        guard canDelete, !urls.isEmpty else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FileOperations.trash(urls)
            }.value
            await model.reload()
            if let error = result.error { alertMessage = error.localizedDescription }
            if !result.stuck.isEmpty { deleteRequest = DeleteRequest(urls: result.stuck, reason: .noTrash) }
        }
    }

    enum DeleteKey: Equatable {
        case trash, immediately
    }

    /// Finder's keys: ⌘⌫ moves to the Trash; ⌥⌘⌫, and Shift with ⌫ or ⌦, delete immediately.
    nonisolated static func deleteKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> DeleteKey? {
        let backspace: UInt16 = 51, forwardDelete: UInt16 = 117
        guard keyCode == backspace || keyCode == forwardDelete else { return nil }
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        if modifiers == .shift { return .immediately }
        guard keyCode == backspace else { return nil }
        if modifiers == .command { return .trash }
        if modifiers == [.option, .command] { return .immediately }
        return nil
    }

    /// Asks before deleting the selection for good, skipping the Trash.
    func requestPermanentDelete() {
        let urls = activeModel.selectedEntries.map(\.url)
        guard canDelete, !urls.isEmpty else { return }
        deleteRequest = DeleteRequest(urls: urls, reason: .chosen)
    }

    func confirmDelete() {
        guard let urls = deleteRequest?.urls else { return }
        deleteRequest = nil
        let model = activeModel
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileOperations.deletePermanently(urls)
                }.value
            } catch {
                alertMessage = error.localizedDescription
            }
            await model.reload()
        }
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

    // MARK: Pending-transfer alert

    /// Title for the preflight alert: "Not enough space" when only space is the problem,
    /// "Can't copy everything" when names or file sizes also need attention.
    var pendingTransferTitle: String {
        guard let pending = pendingTransfer else { return "" }
        let spaceOnly = pending.problems.allSatisfy { if case .notEnoughSpace = $0 { true } else { false } }
        return spaceOnly
            ? String(localized: "Not enough space")
            : String(localized: "Can't copy everything")
    }
}

/// What happens when the person quits the app while File Transfer may be copying.
///
/// AppKit may ask more than once while an answer is pending (a second ⌘Q), so the flow is guarded: it asks at
/// most once, and tells AppKit it may go on exactly once, even if the cancel never finishes.
@MainActor
final class QuitCoordinator {
    enum Decision: Equatable {
        /// Nothing is copying: quit at once.
        case quitNow
        /// A copy is running, paused or halted (drive full or removed): ask first.
        case askFirst
    }

    enum Reply: Equatable { case terminateNow, terminateCancel, terminateLater }

    static func decision(for phase: TransferQueue.Phase) -> Decision {
        switch phase {
        case .running, .paused, .stopped: .askFirst
        case .idle, .finished: .quitNow
        }
    }

    private let phase: @MainActor () -> TransferQueue.Phase
    private let activate: @MainActor () -> Void
    private let confirmQuit: @MainActor () -> Bool
    private let cancelAndWait: @MainActor () async -> Void
    private let reply: @MainActor (Bool) -> Void
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var isTerminating = false
    private var hasReplied = false

    /// - Parameters:
    ///   - activate: brings the app to the front, so the alert cannot open behind other windows.
    ///   - confirmQuit: shows the alert; true when the person chose Quit.
    ///   - cancelAndWait: cancels the copy and returns once its leftovers are gone.
    ///   - reply: tells AppKit it may quit. Called once.
    ///   - timeout: the longest the quit waits for `cancelAndWait` (a stalled drive can hold it up).
    init(
        phase: @escaping @MainActor () -> TransferQueue.Phase,
        activate: @escaping @MainActor () -> Void,
        confirmQuit: @escaping @MainActor () -> Bool,
        cancelAndWait: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (Bool) -> Void,
        timeout: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.phase = phase
        self.activate = activate
        self.confirmQuit = confirmQuit
        self.cancelAndWait = cancelAndWait
        self.reply = reply
        self.timeout = timeout
        self.sleep = sleep
    }

    func shouldTerminate() -> Reply {
        // The first request is already being carried out; this one only has to wait with it.
        if isTerminating { return .terminateLater }
        guard Self.decision(for: phase()) == .askFirst else { return .terminateNow }
        activate()
        if !confirmQuit() { return .terminateCancel }
        isTerminating = true
        let timeout = timeout
        let sleep = sleep
        // Held strongly on purpose: the reply must come even if nothing else keeps the coordinator alive.
        Task {
            await cancelAndWait()
            replyOnce()
        }
        Task {
            await sleep(timeout)
            replyOnce()
        }
        return .terminateLater
    }

    private func replyOnce() {
        guard !hasReplied else { return }
        hasReplied = true
        reply(true)
    }
}
