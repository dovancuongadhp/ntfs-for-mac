import AppKit
import Foundation
import NTFSTransfer
import Testing
import os
@testable import NTFS_for_Mac

@MainActor
struct TransferSessionTests {
    private func session() -> TransferSession {
        TransferSession(notify: { _, _ in })
    }

    private func job(_ id: Int, _ name: String, size: Int64 = 100) -> TransferJob {
        TransferJob(
            id: id, kind: .file, source: URL(fileURLWithPath: "/src/\(name)"),
            destination: URL(fileURLWithPath: "/dst/\(name)"), size: size)
    }

    @Test func theCopyLogIsSavedReadBackOnTheNextLaunchAndOnlyClearEmptiesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src"), destination = root.appending(path: "dst")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appending(path: "a.txt"))
        let logURL = root.appending(path: "TransferLog.json")

        let first = TransferSession(notify: { _, _ in }, logURL: logURL)
        first.queue.enqueue(try TransferPlanner.plan(
            sources: [source.appending(path: "a.txt")], into: destination, access: PosixFileAccess()))
        #expect(await waitFor { first.queue.phase == .finished })
        await first.logSaved()

        let relaunched = TransferSession(notify: { _, _ in }, logURL: logURL)
        #expect(relaunched.queue.groups.map { $0.progress.items.map(\.job.name) } == [["a.txt"]])

        relaunched.clearLog()
        await relaunched.logSaved()
        #expect(relaunched.queue.groups.isEmpty)
        #expect(TransferSession(notify: { _, _ in }, logURL: logURL).queue.groups.isEmpty)
    }

    @Test func nothingSelectedMeansNoDestructiveActions() {
        let session = session()
        session.activeModel.selection = []
        #expect(!session.canDelete)
        #expect(!session.canRename)
        #expect(session.canCopy == false)
    }

    @Test func ordinaryItemsCanBeDeletedAndRenamed() {
        let session = session()
        session.activeModel.selection = [URL(fileURLWithPath: "/Users/tester/Documents/a.txt")]
        #expect(session.canDelete)
        #expect(session.canRename)
        #expect(session.canCopy)
    }

    @Test func protectedItemsRefuseDeleteAndRenameButStayCopyable() {
        let session = session()
        for path in ["/System", "/Applications", "/Volumes/Backup", FileManager.default.homeDirectoryForCurrentUser.path] {
            session.activeModel.selection = [URL(fileURLWithPath: path)]
            #expect(!session.canDelete, "\(path)")
            #expect(!session.canRename, "\(path)")
            #expect(session.canCopy, "\(path)")
        }
    }

    @Test func oneProtectedItemInASelectionBlocksDelete() {
        let session = session()
        session.activeModel.selection = [
            URL(fileURLWithPath: "/Users/tester/Documents/a.txt"), URL(fileURLWithPath: "/Library"),
        ]
        #expect(!session.canDelete)
    }

    @Test func aFullDestinationIsAWarningTheUserCanOverride() {
        let jobs = [job(1, "a.bin", size: 2_000), job(2, "b.bin", size: 2_000)]
        let pending = TransferSession.review(jobs: jobs, rules: .unrestricted, freeBytes: 1_000)
        #expect(pending != nil)
        #expect(pending?.hasSpaceWarning == true)
        #expect(pending?.proceedAnyway == true)
        #expect(pending?.restOfJobs == jobs)
    }

    @Test func aFitCopyStartsWithoutAsking() {
        #expect(TransferSession.review(jobs: [job(1, "a.bin")], rules: .unrestricted, freeBytes: 1_000_000) == nil)
    }

    // MARK: I5 – read-only destination is a blocking preflight problem

    @Test func readOnlyDestinationIsBlockingAndOffersNoChoice() {
        let jobs = [job(1, "a.bin", size: 10)]
        let pending = TransferSession.review(jobs: jobs, rules: .unrestricted, freeBytes: 1_000_000, destinationReadOnly: true)
        #expect(pending != nil, "Read-only destination must trigger a preflight")
        #expect(pending?.problems == [.destinationReadOnly])
        #expect(pending?.restOfJobs.isEmpty == true, "Nothing can be copied to a read-only volume")
        #expect(pending?.choice == nil, "No copy action must be offered")
    }

    @Test func writableDestinationDoesNotBlock() {
        let jobs = [job(1, "a.bin", size: 10)]
        #expect(TransferSession.review(jobs: jobs, rules: .unrestricted, freeBytes: 1_000_000, destinationReadOnly: false) == nil)
    }

    @Test func badNamesAreLeftOutButSpaceNeverHidesTheRest() {
        let jobs = [job(1, "ok.txt", size: 10), job(2, "bad:name.txt", size: 10)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 1_000_000)
        #expect(pending?.hasSpaceWarning == false)
        #expect(pending?.proceedAnyway == false)
        #expect(pending?.restOfJobs.map(\.id) == [1])
    }

    @Test func spaceAndNameProblemsTogetherKeepBothChoices() {
        let jobs = [job(1, "ok.txt", size: 5_000), job(2, "bad:name.txt", size: 5_000)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 100)
        #expect(pending?.hasSpaceWarning == true)
        #expect(pending?.proceedAnyway == true)
        #expect(pending?.restOfJobs.map(\.id) == [1])
    }

    @Test func spaceWarningOffersCopyAnywayWithTheRestOfTheFiles() {
        let jobs = [job(1, "ok.txt", size: 5_000), job(2, "bad:name.txt", size: 5_000)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 100)
        #expect(pending?.choice == .copyAnyway)
        #expect(pending?.restOfJobs.map(\.id) == [1])
    }

    @Test func nameProblemsOnlyOfferCopyTheRest() {
        let jobs = [job(1, "ok.txt", size: 10), job(2, "bad:name.txt", size: 10)]
        let pending = TransferSession.review(jobs: jobs, rules: .exFAT, freeBytes: 1_000_000)
        #expect(pending?.choice == .copyTheRest)
    }

    @Test func nothingToCopyOffersOnlyCancel() {
        let pending = TransferSession.review(jobs: [job(1, "bad:name.txt")], rules: .exFAT, freeBytes: 1_000_000)
        #expect(pending?.choice == nil)
        let full = TransferSession.review(jobs: [job(1, "bad:name.txt", size: 5_000)], rules: .exFAT, freeBytes: 10)
        #expect(full?.choice == nil)
    }

    // MARK: Keeping the Mac awake

    /// Writes fail with "disk full" while `isFull` is set; everything else is the real file system.
    private final class FullDisk: FileAccess, @unchecked Sendable {
        private let base = PosixFileAccess()
        private let full = OSAllocatedUnfairLock(initialState: true)
        private let unreadable = OSAllocatedUnfairLock(initialState: false)
        var isFull: Bool {
            get { full.withLock { $0 } }
            set { full.withLock { $0 = newValue } }
        }
        /// Reading any file fails with an I/O error: a failure of one file that does not stop the queue.
        var cannotRead: Bool {
            get { unreadable.withLock { $0 } }
            set { unreadable.withLock { $0 = newValue } }
        }

        func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
        func children(of url: URL) throws -> [URL] { try base.children(of: url) }
        func exists(_ url: URL) -> Bool { base.exists(url) }
        func makeDirectory(_ url: URL) throws { try base.makeDirectory(url) }
        func readLink(_ url: URL) throws -> String { try base.readLink(url) }
        func makeLink(at url: URL, target: String) throws { try base.makeLink(at: url, target: target) }
        func openForReading(_ url: URL) throws -> any FileReading {
            if cannotRead { throw POSIXError(.EIO) }
            return try base.openForReading(url)
        }
        func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
        func remove(_ url: URL) throws { try base.remove(url) }
        func copyMetadata(from: URL, to: URL) { base.copyMetadata(from: from, to: to) }
        func volumeInfo(at url: URL) throws -> VolumeInfo { try base.volumeInfo(at: url) }
        func createForWriting(_ url: URL) throws -> any FileWriting {
            if isFull { throw POSIXError(.ENOSPC) }
            return try base.createForWriting(url)
        }
    }

    /// Records every sleep hold the session takes or gives back, with whether the queue was busy at that moment.
    @MainActor
    private final class SleepLog {
        private(set) var events: [String] = []
        private(set) var held = 0
        var queue: TransferQueue?

        func begin() -> NSObjectProtocol {
            held += 1
            events.append("begin:\(queue?.isBusy == true ? "busy" : "idle")")
            return NSObject()
        }

        func end(_ token: NSObjectProtocol) {
            held -= 1
            events.append("end:\(queue?.isBusy == true ? "busy" : "idle")")
        }
    }

    private func waitFor(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private struct Rig {
        let session: TransferSession
        let log: SleepLog
        let queue: TransferQueue
        let disk: FullDisk
        let folder: URL
        let defaults: UserDefaults
    }

    private func makeRig(preventSleep: Bool = true) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appending(component: "session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TransferSessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(preventSleep, forKey: TransferSession.preventSleepKey)
        let disk = FullDisk()
        let queue = TransferQueue(access: disk)
        let log = SleepLog()
        log.queue = queue
        let session = TransferSession(
            notify: { _, _ in }, queue: queue, home: folder, defaults: defaults,
            beginActivity: { log.begin() }, endActivity: { log.end($0) })
        return Rig(session: session, log: log, queue: queue, disk: disk, folder: folder, defaults: defaults)
    }

    private func sourceFile(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appending(component: name)
        try Data("payload".utf8).write(to: url)
        return url
    }

    private func jobs(_ names: [String], from source: URL, into destination: URL) throws -> [TransferJob] {
        try TransferPlanner.plan(sources: names.map { source.appending(component: $0) }, into: destination, access: PosixFileAccess())
    }

    private func wait(_ condition: () -> Bool) async -> Bool { await waitFor(condition) }

    @Test func theMacStaysAwakeOnlyWhileACopyRunsAndIsReleasedAtTheEnd() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.disk.isFull = false
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)

        rig.session.start(try jobs(["a.txt"], from: source, into: destination))

        #expect(await wait { rig.queue.phase == .finished })
        #expect(rig.log.events == ["begin:busy", "end:idle"])
        #expect(rig.log.held == 0)
    }

    @Test func aStoppedQueueHoldsNothingAndResumingTakesTheHoldBack() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)

        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .stopped(.noSpace) })
        #expect(rig.log.held == 0, "a queue waiting for Resume must not keep the Mac awake")

        rig.disk.isFull = false
        rig.queue.resume()
        #expect(await wait { rig.queue.phase == .finished })

        #expect(rig.log.events == ["begin:busy", "end:idle", "begin:busy", "end:idle"])
        #expect(rig.log.held == 0)
    }

    @Test func retryingFailedFilesHoldsTheMacAwakeAgain() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)
        rig.disk.isFull = false
        rig.disk.cannotRead = true
        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .finished })
        #expect(rig.queue.progress.failedItems.count == 1)
        #expect(rig.log.events == ["begin:busy", "end:idle"])
        rig.disk.cannotRead = false

        rig.queue.retryFailed()
        #expect(await wait { rig.queue.phase == .finished && rig.log.events.count == 4 })

        #expect(rig.log.events.filter { $0.hasPrefix("begin") }.count == 2)
        #expect(!rig.log.events.contains("begin:idle"))
        #expect(rig.log.held == 0)
    }

    @Test func startingWithNothingToCopyNeverHoldsTheMacAwake() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.session.start([])
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.log.events.isEmpty)
        #expect(!rig.queue.isBusy)
    }

    @Test func theSleepSettingTurnedOffMeansNoHold() async throws {
        let rig = try makeRig(preventSleep: false)
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.disk.isFull = false
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)
        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .finished })
        #expect(rig.log.events.isEmpty)
    }

    // MARK: Protected items are refused by the actions themselves

    /// A session whose home folder is `me` inside a throwaway folder, with the left pane showing the folder
    /// above it, so the home folder is a row that can be selected.
    private func sessionBesideHome() async throws -> (session: TransferSession, root: URL, home: URL, docs: URL) {
        let root = FileManager.default.temporaryDirectory.appending(component: "home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(component: "me", directoryHint: .isDirectory)
        let docs = home.appending(component: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let session = TransferSession(notify: { _, _ in }, home: home)
        session.left.open(root)
        _ = await waitFor { session.left.entries.contains { $0.name == "me" } }
        return (session, root, home, docs)
    }

    @Test func renameRefusesAProtectedItem() async throws {
        let (session, root, _, _) = try await sessionBesideHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try #require(session.left.entries.first { $0.name == "me" })
        session.left.selection = [entry.url]

        session.beginRename()

        #expect(session.namePrompt == nil)
        #expect(session.promptText.isEmpty)
    }

    @Test func renameOffersAnOrdinaryItem() async throws {
        let (session, root, home, _) = try await sessionBesideHome()
        defer { try? FileManager.default.removeItem(at: root) }
        session.left.open(home)
        _ = await waitFor { session.left.entries.contains { $0.name == "Documents" } }
        let entry = try #require(session.left.entries.first { $0.name == "Documents" })
        session.left.selection = [entry.url]

        session.beginRename()

        #expect(session.namePrompt != nil)
        #expect(session.promptText == "Documents")
    }

    @Test func onlyTheUpRowSelectedMeansNothingToActOn() throws {
        let session = session()
        session.activeModel.selection = [try #require(session.activeModel.parentURL)]
        #expect(!session.canCopy)
        #expect(!session.canRename)
        #expect(!session.canDelete)
        #expect(!session.canPreview)
    }

    @Test func deletingImmediatelyAsksFirstAndDeletesOnlyAfterConfirming() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = rig.src.appending(component: "old.txt")
        try Data("bye".utf8).write(to: file)
        rig.session.activeModel.open(rig.src)
        #expect(await waitFor { rig.session.activeModel.entries.contains { $0.url == file } })
        rig.session.activeModel.selection = [file]

        rig.session.requestPermanentDelete()
        #expect(rig.session.deleteRequest == DeleteRequest(urls: [file], reason: .chosen))
        #expect(FileManager.default.fileExists(atPath: file.path))

        rig.session.confirmDelete()
        #expect(await waitFor { !FileManager.default.fileExists(atPath: file.path) })
    }

    @Test func deletingImmediatelyRefusesAProtectedItem() async throws {
        let (session, root, home, _) = try await sessionBesideHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try #require(session.left.entries.first { $0.name == "me" })
        session.left.selection = [entry.url]

        session.requestPermanentDelete()

        #expect(session.deleteRequest == nil)
        #expect(FileManager.default.fileExists(atPath: home.path))
    }

    @Test func commandDeleteTrashesAndShiftOrOptionCommandDeleteDeletesImmediately() {
        let delete: UInt16 = 51, forwardDelete: UInt16 = 117
        #expect(TransferSession.deleteKey(keyCode: delete, flags: .command) == .trash)
        #expect(TransferSession.deleteKey(keyCode: delete, flags: .shift) == .immediately)
        #expect(TransferSession.deleteKey(keyCode: forwardDelete, flags: [.shift, .function]) == .immediately)
        #expect(TransferSession.deleteKey(keyCode: delete, flags: [.option, .command]) == .immediately)
        #expect(TransferSession.deleteKey(keyCode: delete, flags: []) == nil)
        #expect(TransferSession.deleteKey(keyCode: delete, flags: [.control, .command]) == nil)
        #expect(TransferSession.deleteKey(keyCode: 0, flags: .command) == nil)
    }

    // MARK: A folder that is already there

    private func clashRig(_ names: [String]) throws -> (DropRig, [URL]) {
        let rig = try makeDropRig()
        let folders = try names.map { name in
            let folder = try rig.src.appending(component: name, directoryHint: .isDirectory).creatingFolder()
            try Data("x".utf8).write(to: folder.appending(component: "a.jpg"))
            _ = try rig.dst.appending(component: name, directoryHint: .isDirectory).creatingFolder()
            return folder
        }
        return (rig, folders)
    }

    @Test func aFolderThatIsAlreadyThereIsAskedAboutAndCanBeKeptBoth() async throws {
        let (rig, folders) = try clashRig(["Photos"])
        defer { try? FileManager.default.removeItem(at: rig.root) }

        rig.session.copy(folders, into: rig.dst)
        #expect(await waitFor { rig.session.folderClash != nil })
        #expect(rig.session.folderClash?.name == "Photos")
        #expect(rig.session.folderClash?.isLast == true)

        rig.session.answerFolderClash(.keepBoth)
        let copied = rig.dst.appending(path: "Photos 2/a.jpg").path
        #expect(await waitFor { FileManager.default.fileExists(atPath: copied) })
        #expect(rig.session.folderClash == nil)
    }

    @Test func cancellingTheFolderQuestionCopiesNothing() async throws {
        let (rig, folders) = try clashRig(["Photos"])
        defer { try? FileManager.default.removeItem(at: rig.root) }

        rig.session.copy(folders, into: rig.dst)
        #expect(await waitFor { rig.session.folderClash != nil })
        rig.session.answerFolderClash(nil)

        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.session.folderClash == nil)
        #expect(rig.session.queue.phase == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.dst.path).sorted() == ["Photos"])
    }

    @Test func applyToAllAnswersTheOtherFoldersToo() async throws {
        let (rig, folders) = try clashRig(["Music", "Photos"])
        defer { try? FileManager.default.removeItem(at: rig.root) }

        rig.session.copy(folders, into: rig.dst)
        #expect(await waitFor { rig.session.folderClash != nil })
        #expect(rig.session.folderClash?.isLast == false)
        rig.session.answerFolderClash(.keepBoth, applyToAll: true)

        let both = ["Music 2/a.jpg", "Photos 2/a.jpg"].map { rig.dst.appending(path: $0).path }
        #expect(await waitFor { both.allSatisfy { FileManager.default.fileExists(atPath: $0) } })
        #expect(rig.session.folderClash == nil)
    }

    @Test func deleteRefusesAProtectedItemAndLeavesItAlone() async throws {
        let (session, root, home, _) = try await sessionBesideHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try #require(session.left.entries.first { $0.name == "me" })
        session.left.selection = [entry.url]

        session.requestDelete()
        try await Task.sleep(for: .milliseconds(100))

        #expect(FileManager.default.fileExists(atPath: home.path))
        #expect(session.deleteRequest == nil)
        #expect(session.alertMessage == nil)
    }

    // MARK: Drops

    /// Folders `src` and `dst` in a throwaway folder; the right pane shows `dst`, so nothing is ever copied
    /// into a real folder.
    private struct DropRig {
        let session: TransferSession
        let root: URL
        let src: URL
        let dst: URL
        let notices: Notices
        let attention: Counter
    }

    @MainActor
    private final class Notices {
        private(set) var titles: [String] = []
        func add(_ title: String) { titles.append(title) }
    }

    @MainActor
    private final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private func makeDropRig(foreground: Bool = true) throws -> DropRig {
        let root = FileManager.default.temporaryDirectory.appending(component: "drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let src = try root.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let dst = try root.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        let suite = "TransferSessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let notices = Notices()
        let attention = Counter()
        let session = TransferSession(
            notify: { title, _ in notices.add(title) }, home: root, defaults: defaults,
            beginActivity: { NSObject() }, endActivity: { _ in },
            requestAttention: { attention.increment() }, isForeground: { foreground })
        session.right.open(dst)
        return DropRig(session: session, root: root, src: src, dst: dst, notices: notices, attention: attention)
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func aDroppedWebAddressOrAnEmptyDropIsRefused() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }

        #expect(rig.session.drop([URL(string: "https://example.com/some/page")!], onto: .right) == false)
        #expect(rig.session.drop([URL(string: "https://example.com")!], onto: .right) == false)
        #expect(rig.session.drop([], onto: .right) == false)
        try await Task.sleep(for: .milliseconds(300))

        #expect(rig.session.queue.phase == .idle)
        #expect(rig.session.pendingTransfer == nil)
        #expect(rig.session.alertMessage == nil)
        #expect(names(in: rig.dst).isEmpty)
    }

    @Test func webAddressesAreLeftOutOfADropThatAlsoHasFiles() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = try sourceFile("a.txt", in: rig.src)

        #expect(rig.session.drop([URL(string: "https://example.com/x")!, file], onto: .right) == true)
        #expect(await wait { rig.session.queue.phase == .finished })

        #expect(names(in: rig.dst) == ["a.txt"])
        #expect(rig.session.queue.progress.items.count == 1)
    }

    @Test func aFileDroppedFromAnotherFolderIsCopied() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = try sourceFile("a.txt", in: rig.src)

        #expect(rig.session.drop([file], onto: .right) == true)
        #expect(await wait { rig.session.queue.phase == .finished })
        #expect(names(in: rig.dst) == ["a.txt"])
    }

    @Test func theSameDropDeliveredTwiceCopiesOnce() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = try sourceFile("a.txt", in: rig.src)

        #expect(rig.session.drop([file], onto: .right) == true)
        rig.session.drop([file], onto: .right)
        #expect(await wait { rig.session.queue.phase == .finished })
        try await Task.sleep(for: .milliseconds(300))

        #expect(rig.session.queue.progress.items.count == 1)
        #expect(names(in: rig.dst) == ["a.txt"])
    }

    @Test func droppingItemsOntoTheFolderTheyAreAlreadyInDoesNothing() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = try sourceFile("a.txt", in: rig.dst)
        let folder = try rig.dst.appending(component: "sub", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("inner.txt", in: folder)

        #expect(rig.session.drop([file], onto: .right) == false)
        #expect(rig.session.drop([folder], onto: .right) == false)
        #expect(rig.session.drop([file, folder], onto: .right) == false)
        try await Task.sleep(for: .milliseconds(300))

        #expect(rig.session.queue.phase == .idle)
        #expect(names(in: rig.dst) == ["a.txt", "sub"])
        #expect(names(in: folder) == ["inner.txt"])
    }

    @Test func aDropMixingItemsAlreadyThereAndNewOnesCopiesOnlyTheNewOnes() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let there = try sourceFile("a.txt", in: rig.dst)
        let fresh = try sourceFile("b.txt", in: rig.src)

        #expect(rig.session.drop([there, fresh], onto: .right) == true)
        #expect(await wait { rig.session.queue.phase == .finished })

        #expect(names(in: rig.dst) == ["a.txt", "b.txt"])
        #expect(rig.session.queue.progress.items.count == 1)
    }

    // MARK: A question the person may not see

    private func conflictingCopy(_ rig: DropRig) throws -> [TransferJob] {
        _ = try sourceFile("a.txt", in: rig.src)
        _ = try sourceFile("a.txt", in: rig.dst)
        return try jobs(["a.txt"], from: rig.src, into: rig.dst)
    }

    @Test func aQuestionWhileThePageIsHiddenPostsANoticeAndAsksForAttention() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.pageVisible = false

        rig.session.start(try conflictingCopy(rig))
        #expect(await wait { rig.session.queue.conflict != nil })

        #expect(rig.notices.titles == [TransferText.promptNotice().title])
        #expect(rig.attention.value == 1)
        #expect(rig.session.waitingForAnswer)
        rig.session.queue.answer(ConflictDecision(choice: .skip))
        #expect(await wait { rig.session.queue.phase == .finished })
        #expect(!rig.session.waitingForAnswer)
    }

    @Test func aQuestionWhileThePageIsOnScreenDoesNotInterrupt() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.pageVisible = true

        rig.session.start(try conflictingCopy(rig))
        #expect(await wait { rig.session.queue.conflict != nil })
        try await Task.sleep(for: .milliseconds(100))

        #expect(rig.notices.titles.isEmpty)
        #expect(rig.attention.value == 0)
        rig.session.queue.answer(ConflictDecision(choice: .skip))
        #expect(await wait { rig.session.queue.phase == .finished })
    }

    @Test func aQuestionWhileTheAppIsInTheBackgroundAsksEvenIfThePageIsShowing() async throws {
        let rig = try makeDropRig(foreground: false)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.pageVisible = true

        rig.session.start(try conflictingCopy(rig))
        #expect(await wait { rig.session.queue.conflict != nil })

        #expect(rig.notices.titles == [TransferText.promptNotice().title])
        #expect(rig.attention.value == 1)
        rig.session.queue.answer(ConflictDecision(choice: .skip))
        #expect(await wait { rig.session.queue.phase == .finished })
    }

    @Test func anErrorQuestionWhileThePageIsHiddenAsksToo() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.pageVisible = false
        let disk = FullDisk()
        disk.isFull = false
        disk.cannotRead = true
        let queue = TransferQueue(access: disk)
        let notices = Notices()
        let attention = Counter()
        let suite = "TransferSessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: TransferSession.askOnErrorKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TransferSession(
            notify: { title, _ in notices.add(title) }, queue: queue, home: rig.root, defaults: defaults,
            beginActivity: { NSObject() }, endActivity: { _ in },
            requestAttention: { attention.increment() }, isForeground: { true })
        _ = try sourceFile("a.txt", in: rig.src)

        session.start(try jobs(["a.txt"], from: rig.src, into: rig.dst))
        #expect(await wait { queue.errorPrompt != nil })

        #expect(notices.titles == [TransferText.promptNotice().title])
        #expect(attention.value == 1)
        queue.answerError(ErrorDecision(choice: .skip))
        #expect(await wait { queue.phase == .finished })
    }


    // MARK: The sidebar row while a copy needs the person

    @Test func theSidebarRowIsQuietWhenNothingIsCopying() throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        #expect(rig.session.sidebarStatus == .none)
    }

    @Test func aCopyThatIsRunningOrPausedShowsAsWorkingNotAsNeedingAnAnswer() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = try sourceFile("a.txt", in: rig.src)

        rig.session.start(try jobs(["a.txt"], from: rig.src, into: rig.dst))
        #expect(rig.session.sidebarStatus == .working)
        rig.session.queue.pause()
        #expect(rig.session.sidebarStatus == .working)
        rig.session.queue.resume()
        #expect(await wait { rig.session.queue.phase == .finished })
        #expect(rig.session.sidebarStatus == .none)
    }

    @Test func anOpenQuestionMarksTheSidebarRowEvenWhileThePageIsHiddenOrTheAppIsActive() async throws {
        for foreground in [true, false] {
            let rig = try makeDropRig(foreground: foreground)
            defer { try? FileManager.default.removeItem(at: rig.root) }
            rig.session.pageVisible = false

            rig.session.start(try conflictingCopy(rig))
            #expect(await wait { rig.session.queue.conflict != nil })
            #expect(rig.session.sidebarStatus == .needsAnswer, "foreground: \(foreground)")

            rig.session.queue.answer(ConflictDecision(choice: .skip))
            #expect(await wait { rig.session.queue.phase == .finished })
            #expect(rig.session.sidebarStatus == .none)
        }
    }

    @Test func theMarkGoesAwayAsSoonAsTheQuestionIsAnswered() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.start(try conflictingCopy(rig))
        #expect(await wait { rig.session.queue.conflict != nil })
        #expect(rig.session.sidebarStatus == .needsAnswer)

        rig.session.queue.answer(ConflictDecision(choice: .skip))

        #expect(rig.session.queue.conflict == nil)
        #expect(rig.session.sidebarStatus != .needsAnswer)
        #expect(await wait { rig.session.queue.phase == .finished })
    }

    @Test func aHaltedCopyMarksTheSidebarRowUntilItIsResumed() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)

        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .stopped(.noSpace) })
        #expect(rig.session.sidebarStatus == .needsAnswer)

        rig.disk.isFull = false
        rig.queue.resume()
        #expect(rig.session.sidebarStatus == .working)
        #expect(await wait { rig.queue.phase == .finished })
        #expect(rig.session.sidebarStatus == .none)
    }

    @Test func aCancelledHaltedCopyClearsTheMark() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)
        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .stopped(.noSpace) })

        rig.queue.cancel()

        #expect(rig.session.sidebarStatus == .none)
    }

    // MARK: Notifications while the app is active

    @Test func aNotificationIsShownEvenWhenTheAppIsTheActiveOne() {
        #expect(NotificationPresenter.foregroundOptions == [.banner, .sound])
    }

    // MARK: The default name of the exported error list

    @Test func theExportedListKeepsATxtExtensionWhateverTheLanguage() {
        let name = TransferSession.exportFileName
        #expect(name.hasSuffix(".txt"))
        #expect(name == String(localized: "Transfer errors") + ".txt")
    }

    // MARK: Quitting

    /// Lets a test hold a task until it decides to let it go.
    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// Stands in for the alert, the queue and AppKit's reply, and writes down what happened in which order.
    @MainActor
    private final class QuitProbe {
        var phase: TransferQueue.Phase = .running
        var answer = true
        private(set) var events: [String] = []
        let cancelGate = Gate()
        let timeoutGate = Gate()
        var cancelStalls = false

        func coordinator(timeout: Duration = .seconds(10)) -> QuitCoordinator {
            let timeoutGate = timeoutGate
            return QuitCoordinator(
                phase: { self.phase },
                activate: { self.events.append("activate") },
                confirmQuit: { self.events.append("confirm"); return self.answer },
                cancelAndWait: {
                    self.events.append("cancel")
                    if self.cancelStalls { await self.cancelGate.wait() }
                    self.events.append("cancelled")
                },
                reply: { self.events.append("reply:\($0)") },
                timeout: timeout,
                sleep: { _ in await timeoutGate.wait() })
        }

        func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    }

    @Test func onlyACopyThatIsRunningPausedOrHaltedAsksBeforeQuitting() {
        let decisions = [
            (TransferQueue.Phase.idle, QuitCoordinator.Decision.quitNow),
            (.finished, .quitNow),
            (.running, .askFirst),
            (.paused, .askFirst),
            (.stopped(.noSpace), .askFirst),
            (.stopped(.driveRemoved), .askFirst),
        ]
        for (phase, expected) in decisions {
            #expect(QuitCoordinator.decision(for: phase) == expected, "\(phase)")
        }
    }

    @Test func quittingWithNothingCopyingJustQuitsWithoutAnAlert() {
        let probe = QuitProbe()
        probe.phase = .finished
        #expect(probe.coordinator().shouldTerminate() == .terminateNow)
        #expect(probe.events.isEmpty)
    }

    @Test func theAppComesToTheFrontBeforeTheQuitAlertSoItCannotOpenBehindOtherWindows() {
        let probe = QuitProbe()
        probe.answer = false
        _ = probe.coordinator().shouldTerminate()
        #expect(probe.events == ["activate", "confirm"])
    }

    @Test func keepCopyingCancelsTheQuitAndLeavesTheCopyAlone() async {
        let probe = QuitProbe()
        probe.answer = false
        let coordinator = probe.coordinator()
        #expect(coordinator.shouldTerminate() == .terminateCancel)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!probe.events.contains("cancel"))
        #expect(probe.count("reply:true") == 0)
        // Asking again later asks again.
        #expect(coordinator.shouldTerminate() == .terminateCancel)
        #expect(probe.count("confirm") == 2)
    }

    @Test func quitCancelsTheCopyAndRepliesOnlyWhenThatIsDone() async {
        let probe = QuitProbe()
        probe.cancelStalls = true
        #expect(probe.coordinator().shouldTerminate() == .terminateLater)
        #expect(await waitFor { probe.events.contains("cancel") })
        #expect(probe.count("reply:true") == 0)

        probe.cancelGate.open()

        #expect(await waitFor { probe.count("reply:true") == 1 })
        #expect(probe.events.firstIndex(of: "cancelled")! < probe.events.firstIndex(of: "reply:true")!)
    }

    @Test func aHaltedCopyAsksAndQuitCancelsItToo() async {
        let probe = QuitProbe()
        probe.phase = .stopped(.noSpace)
        #expect(probe.coordinator().shouldTerminate() == .terminateLater)
        #expect(await waitFor { probe.count("reply:true") == 1 })
        #expect(probe.events.contains("confirm"))
        #expect(probe.events.contains("cancel"))
    }

    @Test func aSecondQuitWhileTheFirstIsFinishingShowsNoAlertAndRepliesOnce() async {
        let probe = QuitProbe()
        probe.cancelStalls = true
        let coordinator = probe.coordinator()
        #expect(coordinator.shouldTerminate() == .terminateLater)
        #expect(await waitFor { probe.events.contains("cancel") })

        #expect(coordinator.shouldTerminate() == .terminateLater)
        #expect(coordinator.shouldTerminate() == .terminateLater)
        #expect(probe.count("confirm") == 1)
        #expect(probe.count("cancel") == 1)

        probe.cancelGate.open()
        #expect(await waitFor { probe.count("reply:true") >= 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.count("reply:true") == 1)
    }

    @Test func aStalledDriveCannotHoldTheQuitForever() async {
        let probe = QuitProbe()
        probe.cancelStalls = true
        #expect(probe.coordinator().shouldTerminate() == .terminateLater)
        #expect(await waitFor { probe.events.contains("cancel") })
        #expect(probe.count("reply:true") == 0)

        probe.timeoutGate.open()

        #expect(await waitFor { probe.count("reply:true") == 1 })
        #expect(!probe.events.contains("cancelled"))
        // The cancel finishing later must not reply a second time.
        probe.cancelGate.open()
        #expect(await waitFor { probe.events.contains("cancelled") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.count("reply:true") == 1)
    }

    @Test func quitOnAHaltedRealQueueCancelsItAndClearsWhatItLeftBehind() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let source = try rig.folder.appending(component: "src", directoryHint: .isDirectory).creatingFolder()
        let destination = try rig.folder.appending(component: "dst", directoryHint: .isDirectory).creatingFolder()
        _ = try sourceFile("a.txt", in: source)
        let leftover = destination.appending(component: ".a.txt.ntfs-part")
        rig.session.start(try jobs(["a.txt"], from: source, into: destination))
        #expect(await wait { rig.queue.phase == .stopped(.noSpace) })
        try Data("half".utf8).write(to: leftover)
        let replies = Counter()
        let queue = rig.queue
        let coordinator = QuitCoordinator(
            phase: { queue.phase }, activate: {}, confirmQuit: { true },
            cancelAndWait: { await queue.cancelAndWait() }, reply: { _ in replies.increment() })

        #expect(coordinator.shouldTerminate() == .terminateLater)

        #expect(await wait { replies.value == 1 })
        #expect(rig.queue.phase == .finished)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: The menu bar line

    @Test func theMenuBarLineSaysWhatTheCopyIsDoing() {
        let cases: [(TransferQueue.Phase, Bool, TransferSession.MenuStatus)] = [
            (.idle, false, .none),
            (.finished, false, .none),
            (.running, false, .copying),
            (.paused, false, .paused),
            (.running, true, .waiting),
            (.paused, true, .waiting),
            (.stopped(.noSpace), false, .waiting),
            (.stopped(.driveRemoved), false, .waiting),
        ]
        for (phase, waiting, expected) in cases {
            #expect(
                TransferSession.menuStatus(phase: phase, waitingForAnswer: waiting) == expected,
                "\(phase), waiting: \(waiting)")
        }
    }

    // MARK: The finish notice while the page is in front

    @Test func aFinishedCopyDoesNotBannerWhileThePageIsShownAndTheAppIsInFront() async throws {
        let rig = try makeDropRig(foreground: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.pageVisible = true
        _ = try sourceFile("a.txt", in: rig.src)

        rig.session.start(try jobs(["a.txt"], from: rig.src, into: rig.dst))
        #expect(await wait { rig.session.queue.phase == .finished })

        #expect(rig.notices.titles.isEmpty)
    }

    @Test func aFinishedCopyStillBannersWhenNobodyIsLooking() async throws {
        for (visible, foreground) in [(false, true), (true, false), (false, false)] {
            let rig = try makeDropRig(foreground: foreground)
            defer { try? FileManager.default.removeItem(at: rig.root) }
            rig.session.pageVisible = visible
            _ = try sourceFile("a.txt", in: rig.src)

            rig.session.start(try jobs(["a.txt"], from: rig.src, into: rig.dst))
            #expect(await wait { rig.session.queue.phase == .finished })

            #expect(rig.notices.titles.count == 1, "visible: \(visible), foreground: \(foreground)")
        }
    }

    // MARK: Items already in the destination folder

    @Test func aFolderNameInTheOtherCaseIsStillTheSameFolderOnACaseInsensitiveVolume() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: "case-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = try root.appending(component: "Photos", directoryHint: .isDirectory).creatingFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try sourceFile("a.txt", in: folder)
        let shouty = root.appending(component: "PHOTOS", directoryHint: .isDirectory)
        // On a case-sensitive volume the two names are different folders and there is nothing to check.
        guard FileManager.default.fileExists(atPath: shouty.path) else { return }

        #expect(TransferSession.leavingOut(itemsIn: shouty, from: [file]).isEmpty)
        #expect(TransferSession.leavingOut(itemsIn: folder, from: [shouty.appending(component: "a.txt")]).isEmpty)
        let other = try root.appending(component: "Other", directoryHint: .isDirectory).creatingFolder()
        #expect(TransferSession.leavingOut(itemsIn: other, from: [file]) == [file])
    }

    // MARK: Panes after a drive goes away (stubs left behind by the system)

    @Test func anEmptyStubLeftByAnUnmountedVolumeIsNotAPlaceToRecoverTo() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Photos/2025")
        // The mount point folder is still there, but nothing is mounted on it any more.
        let exists: (URL) -> Bool = { ["/", "/Volumes", "/Volumes/Backup"].contains($0.path) }
        let stub: (URL) -> Bool = { $0.path == "/Volumes/Backup" }
        #expect(TransferSession.recoveredFolder(for: folder, home: home, exists: exists, isVolumeStub: stub) == home)
    }

    @Test func aMountedVolumeIsStillARecoveryPlace() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Photos/2025")
        let exists: (URL) -> Bool = { ["/", "/Volumes", "/Volumes/Backup"].contains($0.path) }
        let result = TransferSession.recoveredFolder(for: folder, home: home, exists: exists, isVolumeStub: { _ in false })
        #expect(result?.path == "/Volumes/Backup")
    }

    @Test func onlyAFolderDirectlyInVolumesCanBeAnUnmountedVolumeStub() {
        #expect(!TransferSession.isUnmountedVolumeFolder(URL(fileURLWithPath: "/")))
        #expect(!TransferSession.isUnmountedVolumeFolder(URL(fileURLWithPath: "/Volumes")))
        #expect(!TransferSession.isUnmountedVolumeFolder(FileManager.default.temporaryDirectory))
        #expect(!TransferSession.isUnmountedVolumeFolder(URL(fileURLWithPath: "/Volumes/does-not-exist-\(UUID().uuidString)")))
    }

    @Test func recoveringPanesDoesNotTouchAFolderThePersonOpenedMeanwhile() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let there = try rig.root.appending(component: "there", directoryHint: .isDirectory).creatingFolder()
        rig.session.right.open(there)
        await rig.session.recoverPanes()
        #expect(rig.session.right.folder.standardizedFileURL == there.standardizedFileURL)
    }

    // MARK: Panes after a drive goes away

    @Test func aFolderThatStillExistsStaysWhereItIs() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = URL(fileURLWithPath: "/Users/me/Documents")
        #expect(TransferSession.recoveredFolder(for: folder, home: home, exists: { _ in true }) == nil)
    }

    @Test func aFolderOnAnUnmountedVolumeFallsBackToHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Photos/2025")
        let exists: (URL) -> Bool = { $0.path == "/" || $0.path == "/Volumes" }
        #expect(TransferSession.recoveredFolder(for: folder, home: home, exists: exists) == home)
    }

    @Test func aDeletedFolderFallsBackToTheNearestOneThatExists() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = URL(fileURLWithPath: "/Users/me/Documents/Old/Deep")
        let exists: (URL) -> Bool = { ["/", "/Users", "/Users/me", "/Users/me/Documents"].contains($0.path) }
        #expect(TransferSession.recoveredFolder(for: folder, home: home, exists: exists)?.path == "/Users/me/Documents")
    }

    @Test func aPaneWhoseFolderVanishedMovesToTheHomeFolder() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let gone = try rig.root.appending(component: "stick", directoryHint: .isDirectory).creatingFolder()
        rig.session.right.open(gone)
        await rig.session.right.reload()
        try FileManager.default.removeItem(at: gone)

        await rig.session.recoverPanes()
        // Listing the new folder is a task of its own; reloading here waits for it and the one before it.
        await rig.session.right.reload()

        #expect(rig.session.right.folder.standardizedFileURL == rig.root.standardizedFileURL)
        #expect(rig.session.right.errorMessage == nil)
        #expect(rig.session.left.folder.standardizedFileURL == rig.root.standardizedFileURL)
    }

    @Test func aFavoriteFolderIsStillPinnedAfterRelaunch() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let folder = rig.folder.appending(component: "Keep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        rig.session.toggleFavorite(folder)
        #expect(rig.session.favorites.contains(folder))

        let relaunched = TransferSession(notify: { _, _ in }, home: rig.folder, defaults: rig.defaults)
        #expect(relaunched.favorites.contains(folder))
        relaunched.toggleFavorite(folder)

        let cleared = TransferSession(notify: { _, _ in }, home: rig.folder, defaults: rig.defaults)
        #expect(!cleared.favorites.contains(folder))
    }

    @Test func refreshingAPaneShowsWhatChangedBehindItsBack() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        await rig.session.right.reload()
        #expect(rig.session.right.entries.isEmpty)

        _ = try sourceFile("new.txt", in: rig.dst)
        await rig.session.refresh(.right)

        #expect(rig.session.right.entries.map(\.name) == ["new.txt"])
    }

    // MARK: I3 – file operations run off the main actor and refresh the pane

    @Test func newFolderRefreshesPaneAfterCompletion() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.session.activeModel.open(rig.root)
        await rig.session.activeModel.reload()
        let countBefore = rig.session.activeModel.entries.count

        rig.session.promptText = "async-folder"
        rig.session.namePrompt = NamePrompt(kind: .newFolder)
        rig.session.commitNamePrompt()

        // The operation is async; wait for the pane to reflect the new folder
        let appeared = await waitFor { rig.session.activeModel.entries.map(\.name).contains("async-folder") }
        #expect(appeared, "Pane must refresh after async new-folder creation")
        #expect(rig.session.activeModel.entries.count == countBefore + 1)
    }

    @Test func deleteRequestRunsOffMainActorAndRefreshes() async throws {
        let rig = try makeDropRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let file = rig.root.appending(component: "toDelete.txt")
        try Data("bye".utf8).write(to: file)
        rig.session.activeModel.open(rig.root)
        await rig.session.activeModel.reload()
        rig.session.activeModel.selection = [file]

        rig.session.requestDelete()

        // Wait for async trash + reload to complete (file moved to Trash successfully on APFS)
        let gone = await waitFor { !rig.session.activeModel.entries.map(\.name).contains("toDelete.txt") }
        #expect(gone, "File must be gone from pane after trash via async requestDelete")
    }
}

private extension URL {
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
