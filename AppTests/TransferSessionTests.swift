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
}

private extension URL {
    func creatingFolder() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
