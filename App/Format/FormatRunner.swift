import Foundation
import NTFSFormat

/// The side effects formatting needs, so the runner can be tested with a fake.
@MainActor
protocol FormatEnvironment {
    func freshInfo(_ bsdName: String) -> DiskInfo?
    func childNames(ofWhole bsdName: String) -> [String]
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

        var erased = false
        for step in job.steps {
            do {
                try await run(step, job: job, erased: erased, progress: progress)
            } catch {
                guard erased else { throw error }
                throw FormatError.ntfsFailedAfterErase(Self.detail(of: error))
            }
            if case .diskutil = step {
                erased = true
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
        case .diskutil(let arguments):
            progress(.formatting)
            if !erased {
                try checkFingerprint(job.fingerprint)
            }
            try await environment.runDiskutil(arguments)
        case .ntfsFormat(let request):
            progress(.formatting)
            if !erased {
                try checkFingerprint(job.fingerprint)
            }
            try await environment.runNTFSFormat(request)
        case .ntfsFormatNewPartition(let whole, let label, let clusterSize, let quick):
            progress(.formatting)
            let partition = try await newDataPartition(onWhole: whole)
            try await unmountNewPartition(partition.bsdName)
            guard let offset = partition.offset else { throw FormatError.unexpectedLayout }
            try await environment.runNTFSFormat(
                FormatRequest(device: partition.bsdName, size: partition.size, offset: offset,
                              label: label, clusterSize: clusterSize, quick: quick))
        }
    }

    private func checkFingerprint(_ fingerprint: DiskFingerprint) throws {
        guard let info = environment.freshInfo(fingerprint.bsdName),
              DiskFingerprint(info: info, children: info.isWhole ? environment.childNames(ofWhole: info.bsdName) : [])
                == fingerprint
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

    /// macOS mounts the new partition and Spotlight or Finder may hold it for a moment.
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
