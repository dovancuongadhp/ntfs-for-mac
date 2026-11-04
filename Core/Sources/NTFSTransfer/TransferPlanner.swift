import Foundation

public enum TransferPlanner {
    public enum PlanError: Error, Equatable {
        case destinationInsideSource(String)
    }

    /// Lists, in copy order, everything needed to put `sources` inside `folder`.
    ///
    /// When `duplicate` is true (Copy button, Paste), a source whose planned destination
    /// is the same path as the source itself is renamed to a unique name beside it –
    /// "Photos" becomes "Photos 2", matching Finder behaviour. When false (Drop), sources
    /// that land in the same folder they already live in are left out by the caller.
    public static func plan(
        sources: [URL], into folder: URL, access: any FileAccess, duplicate: Bool = false
    ) throws -> [TransferJob] {
        var jobs: [TransferJob] = []
        let target = folder.standardizedFileURL.path
        for source in sources {
            let attributes = try access.attributes(of: source)
            let sourcePath = source.standardizedFileURL.path
            if attributes.kind == .directory, target == sourcePath || target.hasPrefix(sourcePath + "/") {
                throw PlanError.destinationInsideSource(source.lastPathComponent)
            }
            var destination = folder.appending(component: source.lastPathComponent)
            // Finder-style duplicate: when the planned destination IS the source, pick a
            // unique name next to it so the whole item is copied rather than merged.
            if duplicate, destination.standardizedFileURL.path == sourcePath {
                destination = UniqueName.make(for: destination, exists: access.exists)
            }
            try add(source, attributes: attributes, destination: destination, access: access, jobs: &jobs)
        }
        return jobs
    }

    private static func add(
        _ source: URL, attributes: FileAttributes, destination: URL,
        access: any FileAccess, jobs: inout [TransferJob]
    ) throws {
        func job(_ kind: TransferJob.Kind) -> TransferJob {
            TransferJob(
                id: jobs.count, kind: kind, source: source, destination: destination,
                size: kind == .file ? attributes.size : 0, modified: attributes.modified)
        }
        switch attributes.kind {
        case .directory:
            jobs.append(job(.directory))
            for child in try access.children(of: source) {
                let childAttributes = try access.attributes(of: child)
                try add(
                    child, attributes: childAttributes,
                    destination: destination.appending(component: child.lastPathComponent),
                    access: access, jobs: &jobs)
            }
        case .file:
            jobs.append(job(.file))
        case .symlink:
            jobs.append(job(.symlink(target: try access.readLink(source))))
        case .other:
            break
        }
    }
}

public enum UniqueName {
    /// "a.txt" becomes "a 2.txt", then "a 3.txt", until a name is free.
    public static func make(for url: URL, exists: (URL) -> Bool) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appending(component: name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}
