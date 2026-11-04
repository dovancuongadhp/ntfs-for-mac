import Foundation

/// Places Delete and Rename refuse to touch. Copying from, into and within them is never restricted,
/// and neither is anything inside them.
enum ProtectedFolders {
    private static let systemPaths = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var",
        "/Applications", "/Users", "/Volumes",
    ]

    /// Whether `url` is a volume root, one of the system folders, or the home folder itself.
    ///
    /// Links in the parent path are followed (`/etc` really is `/private/etc`), but the item itself is
    /// not: a shortcut to `/System` is a small file that can be removed.
    static func isProtected(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let candidates = forms(of: url)
        if candidates.contains(where: { $0.hasPrefix("/Volumes/") && !$0.dropFirst(9).contains("/") && $0.count > 9 }) {
            return true
        }
        var protected = Set<String>()
        for path in systemPaths + [home.path] {
            for form in forms(of: URL(fileURLWithPath: path)) { protected.insert(form.lowercased()) }
            protected.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased())
        }
        return candidates.contains { protected.contains($0.lowercased()) }
    }

    /// The standardized path, and the same path with the folders above the item resolved.
    private static func forms(of url: URL) -> [String] {
        let standard = url.standardizedFileURL
        let path = standard.path
        guard path != "/" else { return ["/"] }
        let parent = standard.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appending(component: standard.lastPathComponent).path
        return resolved == path ? [path] : [path, resolved]
    }
}
