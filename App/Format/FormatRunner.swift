import Foundation
import NTFSFormat

/// The side effects formatting needs, so the runner can be tested with a fake.
@MainActor
protocol FormatEnvironment {
    func freshInfo(_ bsdName: String) -> DiskInfo?
    func childNames(ofWhole bsdName: String) -> [String]
    /// Every partition the APFS container stored on `store` spans, read again
    /// now; `nil` unless exactly one container is stored on it.
    func apfsPhysicalStores(ofStore store: String) -> [String]?
    func unmount(_ bsdName: String, whole: Bool) async throws
    func runDiskutil(_ arguments: [String]) async throws
    func runNTFSFormat(_ request: FormatRequest) async throws
    /// Waits for DiskArbitration to catch up, even if the task is cancelled.
    func pause(_ duration: Duration) async
}

/// Executes a format job, re-checking the drive before anything is erased.
@MainActor
final class FormatRunner {
    private let environment: any FormatEnvironment

    init(environment: any FormatEnvironment) {
        self.environment = environment
    }

    func run(_ job: FormatJob, progress: @MainActor (FormatStage) -> Void) async throws {
        progress(.checking)
        try checkFingerprint(job.fingerprint)

        let formatsNTFS = job.steps.contains {
            switch $0 {
            case .ntfsFormat, .ntfsFormatNewPartition: true
            default: false
            }
        }
        var erased = false
        /// The last erase made the exFAT placeholder that NTFS replaces.
        var placeholderCreated = false
        for step in job.steps {
            do {
                try await run(step, job: job, erased: erased, progress: progress)
            } catch {
                guard erased else { throw error }
                let detail = Self.detail(of: error)
                let partition = job.fingerprint.isPartition
                throw placeholderCreated
                    ? FormatError.ntfsFailedAfterErase(detail, partition: partition)
                    : FormatError.failedAfterErase(detail, partition: partition)
            }
            if case .diskutil(let arguments) = step {
                erased = true
                placeholderCreated = formatsNTFS && FormatPlanner.isNTFSPlaceholder(arguments)
            }
        }
        progress(.finishing)
    }

    private func run(
        _ step: FormatStep, job: FormatJob, erased: Bool, progress: @MainActor (FormatStage) -> Void
    ) async throws {
        switch step {
        case .unmount(let name, let whole):
            progress(.unmounting)
            try await unmount(name, whole: whole)
        case .unmountErased(let name):
            progress(.unmounting)
            try await unmountNewPartition(name)
        case .diskutil(let arguments):
            progress(.formatting)
            try checkFingerprint(job.fingerprint, erased: erased)
            if let store = FormatPlanner.deletedContainerStore(arguments) {
                // Deleting a container spread over other partitions would erase them too.
                guard environment.apfsPhysicalStores(ofStore: store) == [store] else { throw FormatError.diskChanged }
            }
            try await environment.runDiskutil(arguments)
        case .ntfsFormat(let request):
            progress(.formatting)
            // Also after diskutil re-typed the partition: it must still be the confirmed one.
            try checkFingerprint(job.fingerprint, erased: erased)
            try await environment.runNTFSFormat(request)
        case .ntfsFormatNewPartition(let whole, let label, let clusterSize, let quick):
            progress(.formatting)
            // The partitions are new, so only the drive itself can be compared.
            try checkDrive(job.fingerprint)
            let partition = try await newDataPartition(onWhole: whole)
            try await unmountNewPartition(partition.bsdName)
            guard let offset = partition.offset else { throw FormatError.unexpectedLayout }
            try checkDrive(job.fingerprint)
            try await environment.runNTFSFormat(
                FormatRequest(device: partition.bsdName, size: partition.size, offset: offset,
                              label: label, clusterSize: clusterSize, quick: quick))
        }
    }

    private func checkFingerprint(_ fingerprint: DiskFingerprint, erased: Bool = false) throws {
        let environment = environment
        let current = DiskFingerprint.read(
            fingerprint.bsdName,
            freshInfo: { environment.freshInfo($0) },
            childNames: { environment.childNames(ofWhole: $0) })
        guard let current else { throw FormatError.diskChanged }
        let matches = erased ? fingerprint.matchesErased(current) : current == fingerprint
        guard matches else { throw FormatError.diskChanged }
    }

    private func checkDrive(_ fingerprint: DiskFingerprint) throws {
        guard let info = environment.freshInfo(fingerprint.wholeBSDName), info.isWhole,
              fingerprint.matchesDrive(DiskFingerprint(info: info, whole: nil, children: []))
        else { throw FormatError.diskChanged }
    }

    private func unmount(_ name: String, whole: Bool) async throws {
        let names = whole ? [name] + environment.childNames(ofWhole: name) : [name]
        guard names.contains(where: { environment.freshInfo($0)?.mount != nil }) else { return }
        do {
            try await environment.unmount(name, whole: whole)
        } catch {
            throw FormatError.busy(error.localizedDescription)
        }
    }

    /// macOS mounts a partition diskutil just formatted, and Spotlight or Finder may hold it for a moment.
    private func unmountNewPartition(_ name: String) async throws {
        var attempt = 1
        while true {
            do {
                try await unmount(name, whole: false)
                return
            } catch where attempt < 5 {
                attempt += 1
                await environment.pause(.seconds(1))
            }
        }
    }

    private func newDataPartition(onWhole whole: String) async throws -> DiskInfo {
        for _ in 0..<20 {
            let data = environment.childNames(ofWhole: whole)
                .compactMap(environment.freshInfo)
                .filter { !DiskContent.hidden.contains($0.content ?? "") }
            if data.count == 1 {
                return data[0]
            }
            await environment.pause(.milliseconds(500))
        }
        throw FormatError.unexpectedLayout
    }

    private static func detail(of error: any Error) -> String {
        switch error {
        case let error as FormatError: error.shortDetail
        case let error as FormatToolError: error.shortMessage
        default: error.localizedDescription
        }
    }
}
