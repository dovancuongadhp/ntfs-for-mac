import Foundation

public struct DestinationRules: Sendable, Equatable {
    public var rejectsWindowsNames: Bool
    public var maxFileSize: Int64?

    public init(rejectsWindowsNames: Bool, maxFileSize: Int64?) {
        self.rejectsWindowsNames = rejectsWindowsNames
        self.maxFileSize = maxFileSize
    }

    public static let unrestricted = DestinationRules(rejectsWindowsNames: false, maxFileSize: nil)
    public static let exFAT = DestinationRules(rejectsWindowsNames: true, maxFileSize: nil)
    public static let fat32 = DestinationRules(rejectsWindowsNames: true, maxFileSize: 4_294_967_295)

    /// `fileSystemType` is the `f_fstypename` macOS reports. NTFS is unrestricted because the
    /// file system extension stores names Windows rejects in a form Windows accepts.
    public static func forFileSystem(_ fileSystemType: String) -> DestinationRules {
        switch fileSystemType.lowercased() {
        case "exfat": .exFAT
        case "msdos": .fat32
        default: .unrestricted
        }
    }
}

public enum WindowsNames {
    private static let forbidden = Set("\\/:*?\"<>|")
    private static let reserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for number in 1...9 {
            names.insert("COM\(number)")
            names.insert("LPT\(number)")
        }
        return names
    }()

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        if name.contains(where: { forbidden.contains($0) || ($0.asciiValue ?? 255) < 32 }) { return false }
        if name.hasSuffix(" ") || name.hasSuffix(".") { return false }
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return !reserved.contains(stem.trimmingCharacters(in: .whitespaces).uppercased())
    }
}

public enum TransferProblem: Sendable, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case invalidName(job: Int, name: String)
    case fileTooLarge(job: Int, name: String)

    /// A blocking problem means nothing should be copied; the others can be skipped.
    public var isBlocking: Bool {
        if case .notEnoughSpace = self { true } else { false }
    }

    public var jobID: Int? {
        switch self {
        case .notEnoughSpace: nil
        case .invalidName(let job, _), .fileTooLarge(let job, _): job
        }
    }
}

public enum TransferPreflight {
    public static func check(jobs: [TransferJob], rules: DestinationRules, freeBytes: Int64) -> [TransferProblem] {
        var problems: [TransferProblem] = []
        let needed = jobs.reduce(Int64(0)) { $0 + ($1.kind == .file ? $1.size : 0) }
        if needed > freeBytes {
            problems.append(.notEnoughSpace(needed: needed, available: freeBytes))
        }
        for job in jobs {
            if rules.rejectsWindowsNames, !WindowsNames.isValid(job.name) {
                problems.append(.invalidName(job: job.id, name: job.name))
            }
            if let limit = rules.maxFileSize, job.kind == .file, job.size > limit {
                problems.append(.fileTooLarge(job: job.id, name: job.name))
            }
        }
        return problems
    }

    /// The jobs left after dropping every job named in `problems` and everything inside it.
    public static func jobs(_ jobs: [TransferJob], without problems: [TransferProblem]) -> [TransferJob] {
        let excluded = Set(problems.compactMap(\.jobID))
        let blocked = jobs.filter { excluded.contains($0.id) }.map { $0.destination.path }
        return jobs.filter { job in
            !blocked.contains { job.destination.path == $0 || job.destination.path.hasPrefix($0 + "/") }
        }
    }
}
