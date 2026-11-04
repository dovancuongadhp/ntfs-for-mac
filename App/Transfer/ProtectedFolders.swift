import Foundation
import os

/// Places Delete and Rename refuse to touch. Copying from, into and within them is never restricted,
/// and neither is anything inside them.
enum ProtectedFolders {
    private static let systemPaths = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var",
        "/Applications", "/Users", "/Volumes",
    ]
    /// The Data volume: `/Users` and `/Applications` are also reachable under it.
    private static let dataVolume = "/System/Volumes/Data"

    /// The protected paths for one home folder, lowercased, in every form they can be reached by.
    /// Building it resolves about a dozen links on disk, so it is built once and shared.
    final class Rules: Sendable {
        let paths: Set<String>

        init(home: URL) {
            var protected = Set<String>()
            for path in systemPaths + [home.path] {
                let url = URL(fileURLWithPath: path)
                for form in ProtectedFolders.forms(of: url) { protected.insert(form.lowercased()) }
                protected.insert(url.resolvingSymlinksInPath().path.lowercased())
                if path != "/" { protected.insert((dataVolume + path).lowercased()) }
            }
            protected.insert(dataVolume.lowercased())
            paths = protected
        }
    }

    private static let cachedRules = OSAllocatedUnfairLock<[String: Rules]>(initialState: [:])

    /// The rules for `home`, kept per home folder: the app asks for one home only, and a second one
    /// (a test, a sandbox) must not make the first be rebuilt.
    static func rules(for home: URL) -> Rules {
        let key = home.standardizedFileURL.path
        if let cached = cachedRules.withLock({ $0[key] }) { return cached }
        let built = Rules(home: home)
        return cachedRules.withLock { cache in
            if let existing = cache[key] { return existing }
            cache[key] = built
            return built
        }
    }

    /// Answers for many items at once. The folders above an item are resolved once per folder rather
    /// than once per item, so a selection of thousands of files in one folder costs a single lookup.
    struct Checker {
        private let rules: Rules
        private var resolvedParents: [String: URL] = [:]
        /// How many folders had to be resolved on disk so far.
        private(set) var parentLookups = 0

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            rules = ProtectedFolders.rules(for: home)
        }

        mutating func isProtected(_ url: URL) -> Bool {
            let standard = url.standardizedFileURL
            let path = standard.path
            if path == "/" { return true }
            let name = standard.lastPathComponent
            let parent = standard.deletingLastPathComponent()
            let resolvedParent: URL
            if let known = resolvedParents[parent.path] {
                resolvedParent = known
            } else {
                resolvedParent = parent.resolvingSymlinksInPath()
                parentLookups += 1
                resolvedParents[parent.path] = resolvedParent
            }
            let resolved = resolvedParent.appending(component: name).path
            for candidate in resolved == path ? [path] : [path, resolved] {
                let lowered = candidate.lowercased()
                if rules.paths.contains(lowered) || ProtectedFolders.isVolumeRoot(lowered) { return true }
            }
            return ProtectedFolders.isMountPoint(resolved)
        }
    }

    /// Whether `url` is a volume root, one of the system folders, or the home folder itself.
    ///
    /// Links in the parent path are followed (`/etc` really is `/private/etc`), but the item itself is
    /// not: a shortcut to `/System` is a small file that can be removed.
    static func isProtected(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        var checker = Checker(home: home)
        return checker.isProtected(url)
    }

    /// Whether any of `urls` is protected.
    static func containsProtected(
        _ urls: some Sequence<URL>,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        var checker = Checker(home: home)
        return urls.contains { checker.isProtected($0) }
    }

    /// A folder that is a direct child of /Volumes or /System/Volumes (case-insensitive).
    /// These are volume roots: Trash operations on them are refused; their contents are reachable.
    fileprivate static func isVolumeRoot(_ lowered: String) -> Bool {
        for prefix in ["/volumes/", "/system/volumes/"] {
            guard lowered.hasPrefix(prefix) else { continue }
            let rest = lowered.dropFirst(prefix.count)
            if !rest.isEmpty && !rest.contains("/") { return true }
        }
        return false
    }

    /// Whether a volume is mounted exactly at `path`, wherever that is. A link is not a mount point.
    fileprivate static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }

    /// The standardized path, and the same path with the folders above the item resolved.
    fileprivate static func forms(of url: URL) -> [String] {
        let standard = url.standardizedFileURL
        let path = standard.path
        guard path != "/" else { return ["/"] }
        let parent = standard.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appending(component: standard.lastPathComponent).path
        return resolved == path ? [path] : [path, resolved]
    }
}
