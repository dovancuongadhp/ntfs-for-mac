import Foundation

/// What the address field offers while a path is being typed, and where Return takes it.
public enum PathCompletion {
    /// Most suggestions shown at once; more would only scroll.
    static let limit = 20

    /// The sub-folders of the typed parent whose names start with the last typed part, ignoring case.
    /// Hidden folders only once that part starts with ".".
    public static func suggestions(
        for text: String, home: URL, fileManager: FileManager = .default
    ) -> [URL] {
        guard !text.isEmpty else { return [] }
        let path = expanded(text, home: home)
        let parent: String
        let typed: String
        if path.hasSuffix("/") {
            parent = path
            typed = ""
        } else {
            parent = (path as NSString).deletingLastPathComponent
            typed = (path as NSString).lastPathComponent
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent) else { return [] }
        let folder = URL(fileURLWithPath: parent, isDirectory: true)
        return names
            .filter { name in
                (typed.hasPrefix(".") || !name.hasPrefix("."))
                    && (typed.isEmpty || name.range(of: typed, options: [.caseInsensitive, .anchored]) != nil)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .lazy
            .map { folder.appending(component: $0, directoryHint: .isDirectory) }
            .filter { isFolder($0, fileManager: fileManager) }
            .prefix(limit)
            .map { $0 }
    }

    /// The folder the text names, or nil when it names nothing or a file.
    public static func folder(for text: String, home: URL, fileManager: FileManager = .default) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: expanded(trimmed, home: home), isDirectory: true).standardizedFileURL
        return isFolder(url, fileManager: fileManager) ? url : nil
    }

    private static func expanded(_ text: String, home: URL) -> String {
        if text == "~" { return home.path }
        if text.hasPrefix("~/") { return home.path + text.dropFirst() }
        return text
    }

    /// True for a folder, or a link to one.
    private static func isFolder(_ url: URL, fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// The suggestions under the address field and the one the arrow keys have picked, if any.
public struct PathSuggestions: Equatable, Sendable {
    public let folders: [URL]
    public private(set) var highlighted: Int?

    public init(_ folders: [URL] = []) {
        self.folders = folders
    }

    public mutating func moveDown() {
        guard !folders.isEmpty else { return }
        highlighted = min((highlighted ?? -1) + 1, folders.count - 1)
    }

    /// Up from the first suggestion goes back to the typed text.
    public mutating func moveUp() {
        guard let index = highlighted else { return }
        highlighted = index == 0 ? nil : index - 1
    }

    /// What Tab puts in the field: the picked folder, else the first, ending in "/" so its own sub-folders
    /// are suggested next.
    public var completion: String? {
        guard !folders.isEmpty else { return nil }
        return folders[highlighted ?? 0].path + "/"
    }

    /// The folder Return opens instead of the typed text.
    public var picked: URL? {
        highlighted.map { folders[$0] }
    }
}
