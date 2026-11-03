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
    /// Waits briefly for DiskArbitration to catch up.
    func pause() async
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
        guard let info = environment.freshInfo(job.fingerprint.bsdName),
              DiskFingerprint(info: info, children: info.isWhole ? environment.childNames(ofWhole: info.bsdName) : [])
                == job.fingerprint
        else { throw FormatError.diskChanged }

        var erased = false
        for step in job.steps {
            switch step {
            case .unmount(let name, let whole):
                progress(.unmounting)
                try await unmount(name, whole: whole)
            case .diskutil(let arguments):
                progress(.formatting)
                try await environment.runDiskutil(arguments)
                erased = true
            case .ntfsFormat(let request):
                progress(.formatting)
                try await formatNTFS(request, afterErase: erased)
            case .ntfsFormatNewPartition(let whole, let label, let clusterSize, let quick):
                progress(.formatting)
                let partition = try await newDataPartition(onWhole: whole)
                if partition.mount != nil {
                    try await unmount(partition.bsdName, whole: false)
                }
                guard let offset = partition.offset else { throw FormatError.unexpectedLayout }
                try await formatNTFS(
                    FormatRequest(device: partition.bsdName, size: partition.size, offset: offset,
                                  label: label, clusterSize: clusterSize, quick: quick),
                    afterErase: true)
            }
        }
        progress(.finishing)
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

    private func formatNTFS(_ request: FormatRequest, afterErase: Bool) async throws {
        do {
            try await environment.runNTFSFormat(request)
        } catch {
            if afterErase {
                throw FormatError.ntfsFailedAfterErase(error.localizedDescription)
            }
            throw error
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
            await environment.pause()
        }
        throw FormatError.unexpectedLayout
    }
}
