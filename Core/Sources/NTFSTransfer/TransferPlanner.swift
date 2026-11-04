import Foundation

public enum TransferPlanner {
    public enum PlanError: Error, Equatable {
        case destinationInsideSource(String)
    }

    /// What to do with a copied folder whose name is already taken in the destination.
    public enum FolderChoice: Sendable, Equatable {
        /// Copy it under the next free name: "Photos 2".
        case keepBoth
        /// Copy its contents into the folder that is there; files with the same name are asked about one by one.
        case merge
        case skip
    }

    /// The copied folders, at the top level of `sources`, whose name is already taken in `folder`.
    public static func clashingFolders(sources: [URL], into folder: URL, access: any FileAccess) throws -> [URL] {
        try distinctTopLevel(sources).filter { source in
            let destination = folder.appending(component: source.lastPathComponent)
            guard destination.standardizedFileURL.path != source.standardizedFileURL.path else { return false }
            return try access.attributes(of: source).kind == .directory && access.exists(destination)
        }
    }

    /// Lists, in copy order, everything needed to put `sources` inside `folder`.
    ///
    /// When `duplicate` is true (Copy button, Paste), a source whose planned destination
    /// is the same path as the source itself is renamed to a unique name beside it –
    /// "Photos" becomes "Photos 2", matching Finder behaviour. When false (Drop), sources
    /// that land in the same folder they already live in are left out by the caller.
    ///
    /// `folderChoices`, keyed by the standardized path of a source, says what to do with a folder from
    /// `clashingFolders`; one without an answer is merged.
    public static func plan(
        sources: [URL], into folder: URL, access: any FileAccess, duplicate: Bool = false,
        folderChoices: [String: FolderChoice] = [:]
    ) throws -> [TransferJob] {
        var jobs: [TransferJob] = []
        let target = folder.standardizedFileURL.path
        for source in distinctTopLevel(sources) {
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
            } else if attributes.kind == .directory, access.exists(destination) {
                switch folderChoices[sourcePath] {
                case .keepBoth: destination = UniqueName.make(for: destination, exists: access.exists)
                case .skip: continue
                case .merge, nil: break
                }
            }
            try add(source, attributes: attributes, destination: destination, access: access, jobs: &jobs)
        }
        return jobs
    }

    /// `sources` in order, without repeats and without items that sit inside another source,
    /// so a pasteboard or drop listing the same thing twice copies it once.
    static func distinctTopLevel(_ sources: [URL]) -> [URL] {
        let paths = sources.map { $0.standardizedFileURL.path }
        let all = Set(paths)
        var seen: Set<String> = []
        return zip(sources, paths).compactMap { source, path in
            guard seen.insert(path).inserted else { return nil }
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if all.contains(parent) { return nil }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return source
        }
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
